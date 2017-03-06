(**
 * Copyright (c) 2017, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Core
open String_utils
open Sys_utils

(*****************************************************************************)
(* Types, constants *)
(*****************************************************************************)

type options = {
  filename : string;
}

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let die str =
  let oc = stderr in
  output_string oc str;
  close_out oc;
  exit 2

let parse_options () =
  let fn_ref = ref None in
  let usage = Printf.sprintf "Usage: %s filename\n" Sys.argv.(0) in
  Arg.parse [] (fun fn -> fn_ref := Some fn) usage;
  let fn = match !fn_ref with
    | Some fn -> fn
    | None -> die usage in
  { filename = fn
  }

(* This allows one to fake having multiple files in one file. This
 * is used only in unit test files.
 * Indeed, there are some features that require mutliple files to be tested.
 * For example, newtype has a different meaning depending on the file.
 *)
let rec make_files = function
  | [] -> []
  | Str.Delim header :: Str.Text content :: rl ->
      let pattern = Str.regexp "////" in
      let header = Str.global_replace pattern "" header in
      let pattern = Str.regexp "[ ]*" in
      let filename = Str.global_replace pattern "" header in
      (filename, content) :: make_files rl
  | _ -> assert false

(* We have some hacky "syntax extensions" to have one file contain multiple
 * files, which can be located at arbitrary paths. This is useful e.g. for
 * testing lint rules, some of which activate only on certain paths. It's also
 * useful for testing abstract types, since the abstraction is enforced at the
 * file boundary.
 * Takes the path to a single file, returns a map of filenames to file contents.
 *)
let file_to_files file =
  let abs_fn = Relative_path.to_absolute file in
  let content = cat abs_fn in
  let delim = Str.regexp "////.*" in
  if Str.string_match delim content 0
  then
    let contentl = Str.full_split delim content in
    let files = make_files contentl in
    List.fold_left ~f: begin fun acc (sub_fn, content) ->
      let file =
        Relative_path.create Relative_path.Dummy (abs_fn^"--"^sub_fn) in
      Relative_path.Map.add acc ~key:file ~data:content
    end ~init: Relative_path.Map.empty files
  else if string_starts_with content "// @directory " then
    let contentl = Str.split (Str.regexp "\n") content in
    let first_line = List.hd_exn contentl in
    let regexp = Str.regexp ("^// @directory *\\([^ ]*\\) \
      *\\(@file *\\([^ ]*\\)*\\)?") in
    let has_match = Str.string_match regexp first_line 0 in
    assert has_match;
    let dir = Str.matched_group 1 first_line in
    let file_name =
      try
        Str.matched_group 3 first_line
      with
        Not_found -> abs_fn in
    let file = Relative_path.create Relative_path.Dummy (dir ^ file_name) in
    let content = String.concat "\n" (List.tl_exn contentl) in
    Relative_path.Map.singleton file content
  else
    Relative_path.Map.singleton file content

let parse_name popt files_contents =
  Errors.do_ begin fun () ->
    let parsed_files =
      Relative_path.Map.mapi
       (Parser_hack.program popt) files_contents in

    let files_info =
      Relative_path.Map.mapi begin fun fn parsed_file ->
        let {Parser_hack.file_mode; comments; ast; _} = parsed_file in
        Parser_heap.ParserHeap.add fn (ast, Parser_heap.Full);
        let funs, classes, typedefs, consts = Ast_utils.get_defs ast in
        { FileInfo.
          file_mode; funs; classes; typedefs; consts; comments = Some comments;
          consider_names_just_for_autoload = false }
      end parsed_files in

    files_info
  end

let do_compile opts files_info = begin
  let get_nast_from_fileinfo tcopt fn fileinfo =
    let funs = fileinfo.FileInfo.funs in
    let parse_function (_, fun_) =
        Parser_heap.find_fun_in_file ~full:true tcopt fn fun_ in
    let parsed_functions = List.filter_map funs parse_function in
    let classes = fileinfo.FileInfo.classes in
    let parse_class (_, class_) =
        Parser_heap.find_class_in_file ~full:true tcopt fn class_ in
    let parsed_classes = List.filter_map classes parse_class in
    let parsed_typedefs = [] in (* TODO typedefs *)
    let parsed_consts = [] in (* TODO consts *)
    (parsed_functions, parsed_classes, parsed_typedefs, parsed_consts) in
  let f_fold fn fileinfo text = begin
    let hhas_text = if (Relative_path.S.to_string fn) = "|builtins.hhi" then
      ""
    else
      let (parsed_functions, parsed_classes, _parsed_typedefs, _parsed_consts) =
        get_nast_from_fileinfo opts fn fileinfo in
      let compiled_funs = Hhbc_from_nast.from_functions parsed_functions in
      let compiled_classes = Hhbc_from_nast.from_classes parsed_classes in
      let _compiled_typedefs = [] in (* TODO *)
      let _compiled_consts = [] in (* TODO *)
      let hhas_prog = Hhas_program.make compiled_funs compiled_classes in
      Hhbc_hhas.to_string hhas_prog in
    text ^ hhas_text
  end in
  let hhas_text = Relative_path.Map.fold files_info ~f:f_fold ~init:"" in
  Printf.printf "%s" hhas_text
end

(*****************************************************************************)
(* Main entry point *)
(*****************************************************************************)

let decl_and_run_mode {filename} popt tcopt =
  Local_id.track_names := true;
  Ident.track_names := true;
  let filename = Relative_path.create Relative_path.Dummy filename in
  let files_contents = file_to_files filename in
  let _, files_info, _ = parse_name popt files_contents in
  do_compile tcopt files_info

let main_hack opts =
  let popt = ParserOptions.default in
  let tcopt = TypecheckerOptions.default in
  EventLogger.init EventLogger.Event_logger_fake 0.0;
  let _handle = SharedMem.init GlobalConfig.default_sharedmem_config in
  let tmp_hhi = Path.concat (Path.make Sys_utils.temp_dir_name) "hhi" in
  Hhi.set_hhi_root_for_unit_test tmp_hhi;
  decl_and_run_mode opts popt tcopt

(* command line driver *)
let _ =
  if ! Sys.interactive
  then ()
  else
    (* On windows, setting 'binary mode' avoids to output CRLF on
       stdout.  The 'text mode' would not hurt the user in general, but
       it breaks the testsuite where the output is compared to the
       expected one (i.e. in given file without CRLF). *)
    set_binary_mode_out stdout true;
    let options = parse_options () in
    Unix.handle_unix_error main_hack options
