open Sll

module Ident_map = Map.Make(String)

let emit_prolog p =
  "#include \"module_prolog.c\"\n\n"

let emit_epilog p =
  "#include \"module_epilog.c\""

let mangle name =
  name ^ "_"

let emit_app name args =
  name ^ "(" ^ (String.concat ", " args) ^ ")"

let emit_decl name args =
  let typed_args = List.map (fun n -> "Object " ^ n) args in
  "Object " ^ emit_app name typed_args

let emit_fdecl fname fargs =
  emit_decl fname (List.map mangle fargs)

let emit_gdecl gname gpdefs =
  let (_, { gargs; _ }) = Ident_map.choose gpdefs in
  emit_decl gname ("ctr" :: List.map mangle gargs)

let emit_declarations { fdefs; gdefs; term; } =
  let enum = Buffer.create 16 in
  let arr = Buffer.create 16 in
  let decls = Buffer.create 16 in
  Buffer.add_string enum "enum {\n";
  Buffer.add_string arr "char const *const constructor_names[] = {\n";
  let module S = Set.Make(String) in
  let rec cnames_of_expr expr =
    let cnames_of_exprs init exprs =
      List.fold_left (fun a e ->
        S.union a (cnames_of_expr e)) init exprs
    in
    match expr with
    | Var _ -> S.empty
    | Ctr (cname, exprs) -> cnames_of_exprs (S.singleton cname) exprs
    | FCall (_, exprs) -> cnames_of_exprs S.empty exprs
    | GCall (_, ctr, exprs) -> cnames_of_exprs (cnames_of_expr ctr) exprs
  in
  let cnames_of_fdefs =
    Ident_map.fold (fun fname { fbody; fargs } a ->
      Buffer.add_string decls (emit_fdecl (mangle fname) fargs ^ ";\n");
      S.union a (cnames_of_expr fbody)) fdefs S.empty
  in
  let cnames_of_defs =
    Ident_map.fold (fun gname gpdefs a ->
      Buffer.add_string decls (emit_gdecl (mangle gname) gpdefs ^ ";\n");
      S.union a (Ident_map.fold (fun pname { gbody; _ } b ->
        S.union b (cnames_of_expr gbody)) gpdefs S.empty))
      gdefs cnames_of_fdefs
  in
  let cnames = S.union cnames_of_defs (cnames_of_expr term) in
  S.iter (fun cname ->
    Buffer.add_string enum ("  " ^ mangle cname ^ ",\n");
    Buffer.add_string arr ("  \"" ^ cname ^ "\",\n")) cnames;
  Buffer.add_string enum "};\n\n";
  Buffer.add_string arr "};\n\n";
  Buffer.add_buffer enum arr;
  Buffer.add_buffer enum decls;
  Buffer.add_string enum "\n";
  Buffer.contents enum

module Names =
  struct
    let (names : (ident, int) Hashtbl.t) = Hashtbl.create 16

    let make_name suggest =
      if Hashtbl.mem names suggest
      then begin
        let counter = Hashtbl.find names suggest in
        let result = suggest ^ "_" ^ (string_of_int counter) in
        Hashtbl.replace names suggest (counter + 1);
        result
      end else begin
        Hashtbl.add names suggest 1;
        suggest
      end

    let ctr name = "ctr_" ^ make_name name
    let fcall name = "fcall_" ^ make_name name
    let gcall name = "gcall_" ^ make_name name

    let reset () =
      Hashtbl.clear names
  end

let emit_val_def indent vname aname args =
  String.make indent ' ' ^ "Object const " ^ vname ^ " = "
    ^ emit_app aname args ^ ";\n"

let rec emit_expr indent buf env = function
  | Var name -> List.assoc name env
  | Ctr (cname, exprs) ->
      let vname = Names.ctr cname in
      let numof_args = List.length exprs in
      let aname = "create_object_" ^ (string_of_int numof_args) in
      let args = List.map (fun e -> emit_expr indent buf env e) exprs in
      let val_def = emit_val_def indent vname aname (mangle cname :: args) in
      Buffer.add_string buf val_def;
      vname
  | FCall (fname, exprs) ->
      let vname = Names.fcall fname in
      let args = List.map (fun e -> emit_expr indent buf env e) exprs in
      let val_def = emit_val_def indent vname (mangle fname) args in
      Buffer.add_string buf val_def;
      vname
  | GCall (gname, ctr, exprs) ->
      let vname = Names.gcall gname in
      let ctrval = emit_expr indent buf env ctr in
      let args = List.map (fun e -> emit_expr indent buf env e) exprs in
      let val_def = emit_val_def indent vname (mangle gname) (ctrval :: args) in
      Buffer.add_string buf val_def;
      vname

let emit_fdef fname { fargs; fbody; } =
  Names.reset ();
  let buf = Buffer.create 16 in
  Buffer.add_string buf (emit_fdecl fname fargs ^ " {\n");
  let env = List.combine fargs (List.map mangle fargs) in
  let result = emit_expr 2 buf env fbody in
  Buffer.add_string buf ("  return " ^ result ^ ";\n}\n\n");
  Buffer.contents buf

let emit_gdef gname gpdefs =
  Names.reset ();
  let buf = Buffer.create 16 in
  let emit_case pname pargs gargs gbody =
    let penv = List.mapi (fun i arg ->
      (arg, "(Object)ctr[" ^ string_of_int (i + 1) ^ "]")) pargs
    in
    let genv = List.combine gargs (List.map mangle gargs) in
    Buffer.add_string buf ("case " ^ mangle pname ^ ": {\n");
    let result = emit_expr 6 buf (penv @ genv) gbody in
    Buffer.add_string buf ("      result = " ^ result ^ ";\n"
      ^ "      break;\n"
      ^ "  } ")
  in
  Buffer.add_string buf (emit_gdecl gname gpdefs ^ " {\n"
    ^ "  Object result = NULL;\n"
    ^ "  switch (SLL_get_ctr_id(ctr[0])) {\n"
    ^ "    ");
  Ident_map.iter (fun pname { pargs; gargs; gbody; } ->
    emit_case pname pargs gargs gbody) gpdefs;
  Buffer.add_string buf ("default:\n"
    ^ "      sll_fatal_error(\"Inexhaustive pattern matching\");\n"
    ^ "  }\n"
    ^ "  return result;\n}\n\n");
  Buffer.contents buf

let emit_main { term; _ } =
  emit_fdef "create_main_term" { fargs = []; fbody = term; }

let emit_defs defs emitter =
  let buf = Buffer.create 16 in
  Ident_map.iter (fun name def ->
    Buffer.add_string buf (emitter (mangle name) def)) defs;
  Buffer.contents buf

let emit_fdefs { fdefs; _ } = emit_defs fdefs emit_fdef
let emit_gdefs { gdefs; _ } = emit_defs gdefs emit_gdef

let emit ({ fdefs; gdefs; term; } as p) =
  let buffer = Buffer.create 16 in
  List.iter (fun emitter ->
    Buffer.add_string buffer (emitter p))
    [ emit_prolog;
      emit_declarations;
      emit_gdefs;
      emit_fdefs;
      emit_main;
      emit_epilog
    ];
  Buffer.contents buffer