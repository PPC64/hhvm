(**
 * Copyright (c) 2016, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

(**
 * Main type representing a message sent from editor to server.
 * This message might have different JSON representations based on the version
 * of API established during intialization call.
 *)

type position = File_content.content_pos
type range = File_content.content_range
type text_edit = File_content.code_edit
type error = Pos.absolute Errors.error_

type file_position = {
  filename : string;
  position : position;
}

type request =
  | Init of init_params
  | Autocomplete of file_position
  | Infer_type of file_position
  | Identify_symbol of file_position
  | Outline of string
  | Did_open_file of did_open_file_params
  | Did_close_file of did_close_file_params
  | Did_change_file of did_change_file_params
  | Disconnect (* TODO: document or remove this *)
  | Subscribe_diagnostics (* Nuclide-rpc specific *)
  | Unsubscribe_call (* Nuclide-rpc specific *)
  | Sleep_for_test (* TODO: port the tests that use it to integration_ml
                      framework and remove it*)

and init_params = {
  client_name : string;
  client_api_version : int;
}

and did_open_file_params = {
  did_open_file_filename : string;
  did_open_file_text : string;
}

and did_close_file_params = {
  did_close_file_filename : string;
}

and did_change_file_params = {
  did_change_file_filename : string;
  changes : text_edit list;
}

type response =
  | Init_response of init_response
  | Autocomplete_response of autocomplete_response
  | Infer_type_response of infer_type_response
  | Identify_symbol_response of identify_symbol_response
  | Symbol_by_id_response of symbol_by_id_response
  | Outline_response of outline_response
  | Diagnostics_notification of diagnostics_notification

and init_response = {
  server_api_version : int;
}

and autocomplete_response = autocomplete_item list

and autocomplete_item = {
  autocomplete_item_text : string;
  autocomplete_item_type : string;
  callable_details : callable_details option;
}

and infer_type_response = string option

and callable_details = {
  return_type : string;
  callable_params : callable_param list;
}

and callable_param = {
  callable_param_name : string;
  callable_param_type : string;
}

and identify_symbol_response = identify_symbol_item list

and identify_symbol_item = {
  occurrence : string SymbolOccurrence.t;
  definition : string SymbolDefinition.t option;
}

and outline_response = string SymbolDefinition.t list

and symbol_by_id_response = string SymbolDefinition.t option

and diagnostics_notification = {
  subscription_id : int; (* Nuclide-rpc specific *)
  diagnostics_notification_filename : string;
  diagnostics : error list;
}
