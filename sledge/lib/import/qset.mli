(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** Qset - Set with (signed) rational multiplicity for each element *)

open Import0
include module type of Qset_intf
module Make (Elt : OrderedType) : S with type elt = Elt.t
