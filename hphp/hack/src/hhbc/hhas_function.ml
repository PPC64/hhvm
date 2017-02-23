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
  function_name          : Litstr.id;
  function_params        : Hhas_param.t list;
  function_return_type   : Hhas_type_info.t option;
  function_body          : Hhbc_ast.instruct list;
}

let make
  function_name
  function_params
  function_return_type
  function_body =
  {
    function_name;
    function_params;
    function_return_type;
    function_body;
  }

let name f = f.function_name
let params f = f.function_params
let return_type f = f.function_return_type
let body f = f.function_body
