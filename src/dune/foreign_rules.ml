open! Stdune

(* Compute command line flags for the [include_dirs] field of [Foreign.Stubs.t]
   and track all files in specified directories as [Hidden_deps] dependencies. *)
let include_dir_flags ~expander ~dir (stubs : Foreign.Stubs.t) =
  Command.Args.S
    (List.map stubs.include_dirs ~f:(fun include_dir ->
         let loc = String_with_vars.loc include_dir
         and include_dir = Expander.expand_path expander include_dir in
         match Path.extract_build_context_dir include_dir with
         | None ->
           (* TODO: Track files in external directories. *)
           User_error.raise ~loc
             [ Pp.textf
                 "%S is an external directory; dependencies in external \
                  directories are currently not tracked."
                 (Path.to_string include_dir)
             ]
             ~hints:
               [ Pp.textf
                   "You can specify %S as an untracked include directory like \
                    this:\n\n\
                   \  (flags -I %s)\n"
                   (Path.to_string include_dir)
                   (Path.to_string include_dir)
               ]
         | Some (build_dir, source_dir) -> (
           match File_tree.find_dir source_dir with
           | None ->
             User_error.raise ~loc
               [ Pp.textf "Include directory %S does not exist."
                   (Path.reach ~from:(Path.build dir) include_dir)
               ]
           | Some dir ->
             Command.Args.S
               [ A "-I"
               ; Path include_dir
               ; Command.Args.S
                   (File_tree.Dir.fold dir ~traverse:Sub_dirs.Status.Set.all
                      ~init:[] ~f:(fun t args ->
                        let dir =
                          Path.append_source build_dir (File_tree.Dir.path t)
                        in
                        let deps =
                          Dep.Set.singleton
                            (Dep.file_selector
                               (File_selector.create ~dir Predicate.true_))
                        in
                        Command.Args.Hidden_deps deps :: args))
               ] )))

let build_c_file ~sctx ~dir ~expander ~include_flags (loc, src, dst) =
  let flags = Foreign.Source.flags src in
  let ctx = Super_context.context sctx in
  let c_flags =
    Super_context.foreign_flags sctx ~dir ~expander ~flags
      ~language:Foreign.Language.C
  in
  Super_context.add_rule sctx ~loc
    ~dir
      (* With sandboxing we get errors like: bar.c:2:19: fatal error: foo.cxx:
         No such file or directory #include "foo.cxx" *)
    ~sandbox:Sandbox_config.no_sandboxing
    (let src = Path.build (Foreign.Source.path src) in
     Command.run
     (* We have to execute the rule in the library directory as the .o is
        produced in the current directory *) ~dir:(Path.build dir)
       (Ok ctx.ocamlc)
       [ A "-g"
       ; include_flags
       ; Dyn (Build.map c_flags ~f:(fun x -> Command.quote_args "-ccopt" x))
       ; A "-o"
       ; Target dst
       ; Dep src
       ]);
  dst

let build_cxx_file ~sctx ~dir ~expander ~include_flags (loc, src, dst) =
  let flags = Foreign.Source.flags src in
  let ctx = Super_context.context sctx in
  let output_param =
    if ctx.ccomp_type = "msvc" then
      [ Command.Args.Concat ("", [ A "/Fo"; Target dst ]) ]
    else
      [ A "-o"; Target dst ]
  in
  let cxx_flags =
    Super_context.foreign_flags sctx ~dir ~expander ~flags
      ~language:Foreign.Language.Cxx
  in
  Super_context.add_rule sctx ~loc
    ~dir
      (* this seems to work with sandboxing, but for symmetry with
         [build_c_file] disabling that here too *)
    ~sandbox:Sandbox_config.no_sandboxing
    (let src = Path.build (Foreign.Source.path src) in
     Command.run
     (* We have to execute the rule in the library directory as the .o is
        produced in the current directory *) ~dir:(Path.build dir)
       (Super_context.resolve_program ~loc:None ~dir sctx ctx.c_compiler)
       ( [ Command.Args.S [ A "-I"; Path ctx.stdlib_dir ]
         ; include_flags
         ; Command.Args.dyn cxx_flags
         ]
       @ output_param @ [ A "-c"; Dep src ] ));
  dst

(* TODO: [requires] is a confusing name, probably because it's too general: it
   looks like it's a list of libraries we depend on. *)
let build_o_files ~sctx ~foreign_sources ~(dir : Path.Build.t) ~expander
    ~requires ~dir_contents =
  let ctx = Super_context.context sctx in
  let all_dirs = Dir_contents.dirs dir_contents in
  let h_files =
    List.fold_left all_dirs ~init:[] ~f:(fun acc dc ->
        String.Set.fold (Dir_contents.text_files dc) ~init:acc
          ~f:(fun fn acc ->
            if String.is_suffix fn ~suffix:Foreign.header_extension then
              Path.relative (Path.build (Dir_contents.dir dc)) fn :: acc
            else
              acc))
  in
  let includes =
    Command.Args.S
      [ Hidden_deps (Dep.Set.of_files h_files)
      ; Command.of_result_map requires ~f:(fun libs ->
            S
              [ Lib.L.c_include_flags libs
              ; Hidden_deps
                  (Lib_file_deps.deps libs
                     ~groups:[ Lib_file_deps.Group.Header ])
              ])
      ]
  in
  String.Map.to_list foreign_sources
  |> List.map ~f:(fun (obj, (loc, src)) ->
         let dst = Path.Build.relative dir (obj ^ ctx.lib_config.ext_obj) in
         let stubs = src.Foreign.Source.stubs in
         let extra_flags = include_dir_flags ~expander ~dir src.stubs in
         let extra_deps =
           let open Build.O in
           let+ () =
             Super_context.Deps.interpret sctx stubs.extra_deps ~expander
           in
           Command.Args.empty
         in
         let include_flags =
           Command.Args.S [ includes; extra_flags; Dyn extra_deps ]
         in
         let build_file =
           match Foreign.Source.language src with
           | C -> build_c_file
           | Cxx -> build_cxx_file
         in
         build_file ~sctx ~dir ~expander ~include_flags (loc, src, dst))