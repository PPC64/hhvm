(**
 * Copyright (c) 2016, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Ide_message
open Ide_message_parser_test_utils
open Ide_rpc_protocol_parser_types

(* Test suite for Nuclide-rpc version of the API responses  *)

let test_response response expected =
  (* "Canonicalize" expected string, by parsing and unparsing it *)
  let expected = Hh_json.(json_to_string (json_of_string expected)) in
  let response = Hh_json.json_to_string  (
    Ide_message_printer.to_json
      ~id:(Some 4)
      ~protocol:Nuclide_rpc
      ~version:V0
      ~response
    )
  in
  assert_equal expected response;
  true

let test_autocomplete_response () =
  let response = Autocomplete_response [{
    autocomplete_item_text = "aaa";
    autocomplete_item_type = "bbb";
    callable_details = Some {
      return_type = "ccc";
      Ide_message.params = [{
          name  = "ddd";
          type_ = "eee";
      }]
    }
  }] in
  test_response response
  {|{
    "protocol": "service_framework3_rpc",
    "type": "response",
    "id": 4,
    "result": [
      {
        "name": "aaa",
        "type": "bbb",
        "pos": {"filename":"","line":0,"char_start":0,"char_end":-1},
        "expected_ty":false,
        "func_details": {
          "return_type": "ccc",
          "params": [
            {
              "name": "ddd",
              "type": "eee",
              "variadic": false
            }
          ],
          "min_arity": 0
        }
      }
    ]
  }|}

let test_diagnostics_notification () =
  let response = Diagnostics_notification {
    subscription_id = 4;
    diagnostics_notification_filename = "foo.php";
    diagnostics = []
  } in
  test_response response
  {|{
    "protocol": "service_framework3_rpc",
    "type": "next",
    "id": 4,
    "value": {
      "filename": "foo.php",
      "errors": []
    }
  }|}

let tests = [
  "test_autocomplete_response", test_autocomplete_response;
  "test_diagnostics_notification", test_diagnostics_notification;
]

let () =
  Unit_test.run_all tests
