(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

type t [@@deriving compare, equal]

module Map : Caml.Map.S with type key = t

val make : package:string option -> classname:string -> t

val from_string : string -> t

val to_string : t -> string

val pp : Format.formatter -> t -> unit

val pp_with_verbosity : verbose:bool -> Format.formatter -> t -> unit
(** if [verbose] then print package if present, otherwise only print class *)

val package : t -> string option

val classname : t -> string

val is_external_via_config : t -> bool
(** Considered external based on config flags. *)

val is_anonymous_inner_class_name : t -> bool
(** True if it is anonymous Java class:
    https://docs.oracle.com/javase/tutorial/java/javaOO/anonymousclasses.html *)

val get_user_defined_class_if_anonymous_inner : t -> t option
(** If the current class is anonymous ([is_anonymous_inner_class_name] is true), Return the
    corresponding user defined (not anonymous) class this anonymous class belongs to.

    In general case, BOTH anonymous classes and user-defined classes can be nested, so the most
    general example looks like So in general case anonymous class name looks something like
    Class$NestedClass$1$17$5. This function should return Class$NestedClass for this case.

    If this is not an anonymous class, returns [None]. *)
