(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Core
open Coverage_level

type result = ((int * int) * Coverage_level.level) list

let to_json input =
  let entries = List.map input begin fun (clr, text) ->
    let color_string = match clr with
      | Some lvl -> string_of_level lvl
      | None -> "default"
    in Hh_json.JSON_Object [
      "color", Hh_json.JSON_String color_string;
      "text",  Hh_json.JSON_String text;
    ]
  end in
  Hh_json.JSON_Array entries

let get_level_list check =
  let type_acc = Hashtbl.create 0 in
  let fn = Typing.with_expr_hook
    (fun (p, _) ty -> Hashtbl.replace type_acc p ty) check in
  let level_of_type x = snd (Coverage_level.level_of_type_mapper fn x) in
  let result = Hashtbl.fold (fun p ty xs ->
    (Pos.info_raw p, level_of_type (p, ty)) :: xs) type_acc [] in
  result

let go env f_in =
  get_level_list begin fun () ->
    ServerIdeUtils.check_file_input
      env.ServerEnv.tcopt env.ServerEnv.files_info f_in
  end
