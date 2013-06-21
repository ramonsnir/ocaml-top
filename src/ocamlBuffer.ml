open Tools.Ops

module GSourceView_params = struct
  let syntax =
    let mgr = GSourceView2.source_language_manager ~default:true in
    mgr#set_search_path ((Sys.getcwd() ^ "/data") :: mgr#search_path);
    let syn = mgr#language "ocp-edit-ocaml" in
    if syn = None then Tools.debug "WARNING: ocaml language def not found";
    syn
  let style =
    let mgr = GSourceView2.source_style_scheme_manager ~default:true in
    mgr#set_search_path ["data"];
    let sty = mgr#style_scheme "cobalt" in
    if sty = None then Tools.debug "WARNING: style def not found";
    sty
end

type reindent_needed = No_reindent
                     | Reindent_delayed of int
                     | Reindent_line of int
                     | Reindent_after of int
                     | Reindent_full

type t = {
  mutable filename: string option;
  gbuffer: GSourceView2.source_buffer;
  view: GSourceView2.source_view;
  mutable need_reindent: reindent_needed;
  eval_mark: GSourceView2.source_mark;
  eval_mark_end: GSourceView2.source_mark;
 (* ordered from bottom to top *)
  mutable block_marks: GSourceView2.source_mark list;
  mutable on_reindent: unit -> unit;
}

let is_modified buf = buf.gbuffer#modified

let unmodify buf = buf.gbuffer#set_modified false

let filename buf = buf.filename

let filename_default ?(default="<unnamed.ml>") buf =
  match buf.filename with
  | Some f -> Filename.basename f
  | None -> default

let set_filename buf name =
  buf.filename <- Some name

module Tags = struct
  let phrase =
    let t = GText.tag ~name:"phrase" () in
    t#set_property (`FOREGROUND "grey60");
    (* t#set_property (`BACKGROUND "black"); *)
    (* property paragraph-background colors entire line, but it
       was introduced in gtk 2.8 and isn't yet in lablgtk... *)
    t#set_property (`INDENT 16); (* fixme: 2*font-width *)
    t

  let stdout =
    let t = GText.tag ~name:"stdout" () in
    t#set_property (`FOREGROUND "#dd0");
    t

  let ocamltop =
    let t = GText.tag ~name:"ocamltop" () in
    t#set_property (`FOREGROUND "white");
    t

  let ocamltop_err =
    let t = GText.tag ~name:"ocamltop_err" () in
    t#set_property (`FOREGROUND "#e44");
    t

  let ocamltop_warn =
    let t = GText.tag ~name:"ocamltop_warn" () in
    t#set_property (`FOREGROUND "orange");
    t

  let invisible =
    let t = GText.tag ~name:"invisible" () in
    t#set_property (`INVISIBLE true);
    t

  let error =
    let t = GText.tag ~name:"error" () in
    t#set_property (`UNDERLINE `SINGLE); (* BACKGROUND "red" *)
    t

  let table =
    let table = GText.tag_table () in
    table#add phrase#as_tag;
    table#add stdout#as_tag;
    table#add ocamltop#as_tag;
    table#add ocamltop_err#as_tag;
    table#add ocamltop_warn#as_tag;
    table#add invisible#as_tag;
    table#add error#as_tag;
    table

  let get_indent, indent =
    let indent_tags = Hashtbl.create 64 in
    let reverse = Hashtbl.create 64 in
    (fun t ->
      try Some (Hashtbl.find reverse t#get_oid) with
      | Not_found -> None),
    fun obuf n ->
      try Hashtbl.find indent_tags n with
      | Not_found ->
          let name = Printf.sprintf "indent-%d" n in
          let t = GText.tag ~name () in
          let char_width =
            (obuf.view#misc#pango_context#get_metrics ())#approx_char_width
            / Pango.scale
          in
          t#set_property (`INDENT (n*char_width));
          Hashtbl.add indent_tags n t;
          Hashtbl.add reverse t#get_oid n;
          table#add t#as_tag;
          t
end

let skip_space_backwards buf ?(limit=buf.gbuffer#start_iter) (iter:GText.iter) =
  let limit = limit#backward_char in
  let it =
    iter#backward_find_char ~limit (fun c -> not (Glib.Unichar.isspace c))
  in
  it#forward_char

let skip_space_forwards buf ?limit (iter:GText.iter) =
  iter#forward_find_char ?limit (fun c -> not (Glib.Unichar.isspace c))


let next_beg_of_phrase buf (iter: GText.iter) =
  (* we got buf.gbuffer#forward/backward_iter_to_source_mark, but it uses
     side-effects on the iters, aughh. *)
  let offset = iter#offset in
  List.fold_left
    (fun acc mark ->
       let it = buf.gbuffer#get_iter_at_mark mark#coerce in
       if it#offset < acc#offset && it#offset > offset then it else acc)
    buf.gbuffer#end_iter
    buf.block_marks

let last_beg_of_phrase buf
    ?(default  = fun buf -> buf.gbuffer#start_iter)
    (iter: GText.iter) =
  let offset = iter#offset in
  let it_opt =
    List.fold_left
      (fun acc mark ->
         let it = buf.gbuffer#get_iter_at_mark mark#coerce in
         if acc = None && it#offset <= offset then Some it else acc)
      None
      buf.block_marks
  in
  match it_opt with Some it -> it | None -> default buf

let first_beg_of_phrase buf =
  let rec last = function [x] -> x | x::y -> last y | [] -> raise Not_found in
  try buf.gbuffer#get_iter_at_mark (last buf.block_marks)#coerce
  with Not_found -> buf.gbuffer#start_iter

let reindent_max r1 r2 = match r1, r2 with
  | No_reindent, r | r, No_reindent -> r
  | Reindent_full, _ | _, Reindent_full -> Reindent_full
  | Reindent_delayed l1, Reindent_delayed l2 when l1 = l2 -> Reindent_delayed l1
  | (Reindent_line l1 | Reindent_delayed l1),
    (Reindent_line l2 | Reindent_delayed l2)
    when l1 = l2
    -> Reindent_line l1
  | (Reindent_line l1 | Reindent_after l1 | Reindent_delayed l1),
    (Reindent_line l2 | Reindent_after l2 | Reindent_delayed l2)
    -> Reindent_after (min l1 l2)

let reindent t =
  let buf = t.gbuffer in
  (* ensure buffer ends with a newline *)
  if buf#end_iter#line_offset > 0 then (
    let cursor = buf#create_mark (buf#get_iter_at_mark `INSERT) in
    buf#insert ~iter:buf#end_iter "\n";
    buf#place_cursor ~where:(buf#get_iter_at_mark (`MARK cursor))
  );
  let in_lines = match t.need_reindent with
    | No_reindent | Reindent_delayed _ -> assert false
    (* l is a gtk line, starting at 0. n is an ocp-indent line starting at 1 *)
    | Reindent_line l -> (fun n -> n = l + 1)
    | Reindent_after l -> (fun n -> n >= l + 1)
    | Reindent_full -> (fun _ -> true)
  in
  let buf_indent block elt (last,line,col,block_marks) =
    match elt with
    | IndentPrinter.Whitespace w ->
      last, line, col + String.length w, block_marks
    | IndentPrinter.Text txt ->
      if IndentBlock.is_in_comment block then
        last, line, col + String.length txt, block_marks
      else
        let block_marks =
          if IndentBlock.is_at_top block && block <> IndentBlock.empty ||
             last = ";;"
          then
            buf#create_source_mark
              ~name:("block."^string_of_int (List.length block_marks))
              ~category:"block_mark"
              ((buf#get_iter (`LINE (line - 1)))#forward_chars col)
            :: block_marks
          else block_marks
        in
        txt, line, col + String.length txt, block_marks
    | IndentPrinter.Newline ->
      last, line + 1, 0, block_marks
    | IndentPrinter.Indent indent ->
      if in_lines line then
        let start = buf#get_iter (`LINE (line - 1)) in
        if start#char = int_of_char ' ' then (
          (* cleanup whitespace (todo: except in comments) *)
          let stop =
            start#forward_find_char
              ~limit:start#forward_to_line_end
              (fun c -> not (Glib.Unichar.isspace c))
          in
          buf#delete ~start ~stop
        );
        let stop =
          if start#ends_line then start#forward_char
          else start#forward_to_line_end
        in
        (* fixme: might leave tags when deleting a line break *)
        List.iter (fun tag -> match Tags.get_indent tag with
            | Some n when n <> indent ->
              buf#remove_tag tag ~start ~stop
            | Some _ | None -> ())
          start#tags;
        buf#apply_tag (Tags.indent t indent) ~start:start#backward_char ~stop;
        last, line, col, block_marks
      else
        last, line, col, block_marks
  in
  let input =
    Nstream.of_string
      (buf#get_text ~start:buf#start_iter ~stop:buf#end_iter ())
  in
  let output = {
    IndentPrinter.
    debug = false;
    config =
      IndentConfig.update_from_string IndentConfig.default "apprentice";
    in_lines;
    indent_empty = true;
    adaptive = false;
    kind = IndentPrinter.Extended buf_indent;
  }
  in
  (* Don't use remove_source_marks, it can segfault *)
  let _ = List.iter (fun mark -> buf#delete_mark mark#coerce) t.block_marks in
  let block_marks = []
    (* [buf#create_source_mark ~name:("block.0") ~category:"block_mark" (buf#start_iter)] *)
  in
  let _last, _line, _col, block_marks =
    IndentPrinter.proceed output input IndentBlock.empty (";;",1,0,block_marks)
  in
  t.block_marks <- block_marks

let trigger_reindent ?cont t reindent_needed =
  (match cont with
   | None -> ()
   | Some ct -> t.on_reindent <- fun () -> t.on_reindent (); ct ());
  match t.need_reindent with
  | No_reindent | Reindent_delayed _ ->
    t.need_reindent <- reindent_max t.need_reindent reindent_needed;
    ignore @@ GMain.Idle.add @@ fun () ->
      ignore @@ reindent t;
      t.need_reindent <-
        (match reindent_needed with
         | Reindent_line l -> Reindent_delayed l
         | _ -> No_reindent);
      let ct = t.on_reindent in
      t.on_reindent <- (fun () -> ());
      ct ();
      false
  | current ->
    t.need_reindent <- reindent_max current reindent_needed

let raw_contents buf = buf.gbuffer#get_text ()

let get_indented_text ~start ~stop buf =
  let indent_at it =
    List.fold_left (fun indent tag ->
        match Tags.get_indent tag with
        | None -> indent
        | Some n -> n
    ) 0 it#tags
  in
  let out = Buffer.create 256 in
  let rec get_lines start =
    if start#offset >= stop#offset then ()
    else
      let stop =
        let s =
          if start#ends_line then start#forward_char
          else start#forward_line
        in
        if s#offset >= stop#offset then stop else s
      in
      if not start#ends_line then
        (let indent = indent_at start in
         for i = 1 to indent do Buffer.add_char out ' ' done);
      Buffer.add_string out (buf.gbuffer#get_text ~start ~stop ());
      get_lines stop
  in
  get_lines start;
  Buffer.contents out

(* re-indented contents *)
let contents buf =
  get_indented_text
    ~start:buf.gbuffer#start_iter ~stop:buf.gbuffer#end_iter
    buf

(* WORK IN PROGRESS: this works but can trigger SEGFAULTS ! *)
let setup_completion buf =
  let lib_index =
    (* temporary *)
    let rec subdirs acc path =
      Array.fold_left
        (fun acc p ->
          let path = Filename.concat path p in
          if Sys.is_directory path then subdirs acc path else acc)
        (path::acc)
        (Sys.readdir path)
    in
    let ocaml_dirs =
      let ic = Unix.open_process_in "ocamlc -where" in
      let dir = input_line ic in
      ignore (Unix.close_process_in ic);
      subdirs [] dir
    in
    LibIndex.load ocaml_dirs
  in
  let ocaml_completion_provider =
    (* ref needed for bootstrap (!) *)
    let provider_ref = ref None in
    let is_prefix_char =
      let chars = List.map int_of_char ['.';'_';'\''] in
      fun gchar ->
        Glib.Unichar.isalnum gchar ||
        List.mem gchar chars
    in
    let completion_start_iter (iter:GText.iter) : GText.iter =
      let limit = iter#set_line_offset 0 in
      let iter =
        iter#backward_find_char ~limit (fun c -> not (is_prefix_char c))
      in
      if iter#equal limit then iter else iter#forward_char
    in
    let custom_provider : GSourceView2.custom_completion_provider =
      object (self)
        method name = Tools.debug "name";
          "Available library values"
        method icon =  Tools.debug "icon"; None
        method populate : GSourceView2.source_completion_context -> unit =
          fun context ->
            Tools.debug "populate";
            let candidates =
              let stop = context#iter in
              let start = completion_start_iter stop in
              let word = buf.gbuffer#get_text ~start ~stop () in
              Tools.debug "Completing on %S" word;
              LibIndex.complete lib_index word
            in
            let propals =
              List.map (fun info ->
                  (GSourceView2.source_completion_item
                     ~label:(LibIndex.Print.name info)
                     ~text:(LibIndex.Print.path info)
                     ?icon:None
                     ~info:(LibIndex.Print.ty info)
                     ()
                   :> GSourceView2.source_completion_proposal)
                ) candidates
            in
            context#add_proposals
              (match !provider_ref with Some p -> p | None -> assert false)
              propals
              true;
        method matched context = Tools.debug "matched";
          is_prefix_char context#iter#backward_char#char
        method activation = [`USER_REQUESTED] (* `INTERACTIVE *)
        method info_widget _propal = None
        method update_info _propal _info = ()
        method start_iter context _propal iter =
          let start = completion_start_iter (buf.gbuffer#get_iter `INSERT) in
          (* ouch, answers by side effect on iter... *)
          iter#nocopy#assign start#nocopy;
          true
        method activate_proposal propal iter =
          let pfxlen = iter#offset - (completion_start_iter iter)#offset in
          let text = propal#text in
          let text = String.sub text pfxlen (String.length text - pfxlen) in
          buf.gbuffer#insert ~iter:(buf.gbuffer#get_iter `INSERT) text;
          true
        method interactive_delay = 2
        method priority = 2
      end
    in
    let provider =
      GSourceView2.source_completion_provider custom_provider
    in
    provider_ref := Some provider;
    provider
  in
  let compl = buf.view#completion in
  compl#set_remember_info_visibility true;
  compl#set_show_headers false;
  ignore (compl#add_provider ocaml_completion_provider);
  (* let compl_visible = ref false in *)
  ignore (buf.view#event#connect#key_press ~callback:(fun ev ->
    if GdkEvent.Key.keyval ev = GdkKeysyms._Tab then
      (* trigger compl; *)
      (ignore (compl#show [ocaml_completion_provider]
                 (compl#create_context (buf.gbuffer#get_iter `INSERT)));
       true)
    else false
  ));
  ()

let create ?name ?(contents="")
    (mkview: GSourceView2.source_buffer -> GSourceView2.source_view) =
  let gbuffer =
    if not (Glib.Utf8.validate contents) then
      Tools.recover_error
        "Could not open file %s because it contains invalid utf-8 \
         characters. Please fix it or choose another file"
        (match name with Some n -> n | None -> "<unnamed>");
    GSourceView2.source_buffer
      ~text:contents
      ?language:GSourceView_params.syntax
      ?style_scheme:GSourceView_params.style
      ~highlight_matching_brackets:true
      ~highlight_syntax:true
      ~tag_table:Tags.table
      ()
  in
  (* workaround: if we don't do this, loading of the file can be undone *)
  gbuffer#begin_not_undoable_action ();
  gbuffer#place_cursor ~where:gbuffer#start_iter;
  let view = mkview gbuffer in
  (* set_priority has no effect. Just declare higher prios last... *)
  view#set_mark_category_pixbuf ~category:"block_mark"
    (Some (GdkPixbuf.from_file "data/icons/block_marker.png"));
  view#set_mark_category_priority ~category:"error" 1;
  view#set_mark_category_pixbuf ~category:"eval_next"
    (if Tools.debug_enabled then
       Some (GdkPixbuf.from_file "data/icons/eval_marker_next.png")
     else None);
  view#set_mark_category_priority ~category:"error" 3;
  view#set_mark_category_pixbuf ~category:"eval"
    (Some (GdkPixbuf.from_file "data/icons/eval_marker.png"));
  view#set_mark_category_priority ~category:"eval" 4;
  view#set_mark_category_pixbuf ~category:"error"
    (Some (GdkPixbuf.from_file "data/icons/err_marker.png"));
  view#set_mark_category_priority ~category:"error" 5;
  let eval_mark =
    gbuffer#create_source_mark ~name:"eval" ~category:"eval" gbuffer#start_iter
  in
  let eval_mark_end =
    gbuffer#create_source_mark ~name:"eval_next" ~category:"eval_next"
      gbuffer#start_iter
  in
  let t =
    { filename = name; need_reindent = Reindent_full; gbuffer; view;
      eval_mark; eval_mark_end; block_marks = []; on_reindent = (fun () -> ()) }
  in
  ignore @@ gbuffer#connect#insert_text ~callback:(fun iter text ->
      let rec contains_sp i =
        if i >= String.length text then false
        else match text.[i] with
          | 'a'..'z' | 'A'..'Z' | '0'..'9' | '\'' | '`' |'_' ->
              contains_sp (i+1)
          | _ -> true
      in
      if contains_sp 0 then
        trigger_reindent t (if String.contains text '\n'
                            then Reindent_after iter#line
                            else Reindent_line iter#line)
      else
        t.need_reindent <- reindent_max t.need_reindent
            (Reindent_delayed iter#line)
    );
  ignore @@ gbuffer#connect#notify_cursor_position ~callback:(fun pos ->
      match t.need_reindent with
      | Reindent_delayed l | Reindent_line l ->
        if (gbuffer#get_iter (`OFFSET pos))#line <> l then
            trigger_reindent t (Reindent_after l)
      | _ -> ()
    );
  setup_completion t;
  ignore @@ reindent t;
  t.need_reindent <- No_reindent;
  ignore @@ gbuffer#connect#modified_changed ~callback:(fun () ->
      Gui.set_window_title "%s%s" (filename_default t) @@
        if gbuffer#modified then "*" else "");
  unmodify t;
  ignore @@ gbuffer#connect#delete_range ~callback:(fun ~start ~stop ->
      let line = start#line in
      trigger_reindent t (if line = stop#line then Reindent_line line
                          else Reindent_after line)
    );
  ignore @@ gbuffer#connect#changed
      ~callback:(fun () ->
          let it = gbuffer#get_iter `INSERT in
          let replace_before_cursor mark =
            let iter = gbuffer#get_iter_at_mark mark#coerce in
            if it#offset < iter#offset then
              gbuffer#move_mark mark#coerce ~where:(last_beg_of_phrase t it)
          in
          replace_before_cursor eval_mark;
          replace_before_cursor eval_mark_end);
  (* TODO:
     - forbid pasting of styled text from the top to the text buffer
     (discard style) ; lablgtk doesn't seem to bind the functions needed to do
     this :/
  *)
  gbuffer#end_not_undoable_action ();
  t

let get_selection buf =
  let gbuf = buf.gbuffer in
  if gbuf#has_selection then
    let start,stop = gbuf#selection_bounds in
    Some (get_indented_text buf ~start ~stop)
  else
    None
