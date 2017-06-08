(**
 * Copyright (c) 2017, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
*)

type t = {
  hhas_adata   : Hhas_adata.t list;
  hhas_fun     : Hhas_function.t list;
  hhas_classes : Hhas_class.t list;
  hhas_typedefs: Hhas_typedef.t list;
  hhas_main    : Hhas_body.t;
}

let make hhas_adata hhas_fun hhas_classes hhas_typedefs hhas_main =
  { hhas_adata; hhas_fun; hhas_classes; hhas_typedefs; hhas_main }

let functions hhas_prog =
  hhas_prog.hhas_fun

let classes hhas_prog =
  hhas_prog.hhas_classes

let typedefs hhas_prog =
  hhas_prog.hhas_typedefs

let main hhas_prog =
  hhas_prog.hhas_main

let adata hhas_prog =
  hhas_prog.hhas_adata

open Instruction_sequence

let emit_main defs =
  let body, _is_generator, _is_pair_generator =
    Emit_body.emit_body
      ~namespace:Namespace_env.empty_with_default_popt
      ~is_closure_body:false
      ~is_memoize:false
      ~skipawaitable:false
      ~is_return_by_ref:false
      ~scope:Ast_scope.Scope.toplevel
      ~return_value:(instr_int 1)
      ~default_dropthrough:None
      [] None defs
  in
    body

open Closure_convert

let from_ast ast =
  let closed_ast = convert_toplevel_prog ast in
  try
    let compiled_defs = emit_main closed_ast in
    let compiled_funs = Emit_function.emit_functions_from_program closed_ast in
    let compiled_classes = Emit_class.emit_classes_from_program closed_ast in
    let compiled_typedefs = Emit_typedef.emit_typedefs_from_program closed_ast in
    let adata = Emit_adata.get_adata () in
    make adata compiled_funs compiled_classes compiled_typedefs compiled_defs
  with Emit_fatal.IncludeTimeFatalException (op, message) ->
    Iterator.reset_iterator ();
    let body = Emit_body.make_body (Emit_fatal.emit_fatal op message)
      [] (* decl_vars *)
      false (*is_memoize_wrapper*)
      [] (* params *)
      None (* return_type_info *)
    in
      make [] [] [] [] body
