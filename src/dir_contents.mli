(** Directories contents *)

(** This modules takes care of attaching modules and mlds files found
    in the source tree or generated by user rules to library,
    executables, tests and documentation stanzas. *)

open! Stdune
open Import

type t

val dir : t -> Path.t

(** Files in this directory. At the moment, this doesn't include all
    generated files, just the ones generated by [rule], [ocamllex],
    [ocamlyacc], [menhir] stanzas. *)
val text_files : t -> String.Set.t

module Executables_modules : sig
  type t = Module.Name_map.t
end

(** Modules attached to a library. [name] is the library best name. *)
val modules_of_library : t -> name:Lib_name.t -> Lib_modules.t

val c_sources_of_library : t -> name:Lib_name.t -> C.Sources.t

(** Modules attached to a set of executables. *)
val modules_of_executables : t -> first_exe:string -> Executables_modules.t

(** Find out what buildable a module is part of *)
val lookup_module : t -> Module.Name.t -> Dune_file.Buildable.t option

(** All mld files attached to this documentation stanza *)
val mlds : t -> Dune_file.Documentation.t -> Path.t list

(** Coq modules of library [name] is the Coq library name.  *)
val coq_modules_of_library : t -> name:string -> Coq_module.t list

type get_result =
  | Standalone_or_root of t
  | Group_part of Path.t

(** Produces rules for all group parts when it returns [Standalone_or_root].
    Does not generate any rules when it returns [Group_part]. *)
val get : Super_context.t -> dir:Path.t -> get_result

val get_without_rules : Super_context.t -> dir:Path.t -> t

type kind = private
  | Standalone
  | Group_root of t list Memo.Lazy.t (** Sub-directories part of the group *)
  | Group_part of t

val kind : t -> kind

(** All directories in this group, or just [t] if this directory is
    not part of a group.  *)
val dirs : t -> t list
