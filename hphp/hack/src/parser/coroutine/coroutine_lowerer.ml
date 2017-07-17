(**
 * Copyright (c) 2017, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

module CoroutineMethodLowerer = Coroutine_method_lowerer
module CoroutineStateMachineGenerator = Coroutine_state_machine_generator
module CoroutineSyntax = Coroutine_syntax
module CoroutineTypeLowerer = Coroutine_type_lowerer
module EditableSyntax = Full_fidelity_editable_syntax
module EditableToken = Full_fidelity_editable_token
module List = Core_list
module Rewriter = Full_fidelity_rewriter.WithSyntax(EditableSyntax)
module SourceText = Full_fidelity_source_text
module SyntaxTree = Full_fidelity_syntax_tree

open CoroutineSyntax
open EditableSyntax
open Coroutine_type_lowerer

(**
 * Rewrites coroutine annotations.
 *
 * The following:
 *
 *   public function returnVoidVoidCoroutineLambda(
 *   ): (coroutine function(): void) { ... }
 *
 * Will be rewritten into:
 *
 *   public function returnVoidVoidCoroutineLambda(
 *   ): (function(
 *     CoroutineContinuation<CoroutineUnit>
 *   ): CoroutineResult<CoroutineUnit>) { ... }
 *
 * The following:
 *
 *   public function returnIntIntCoroutineLambda(
 *   ): (coroutine function(int): int) { ... }
 *
 * Will be rewritten into:
 *
 *    public function returnIntIntCoroutineLambda(
 *    ): (function(
 *      CoroutineContinuation<int>,
 *      int,
 *    ): CoroutineResult<int>) { ... }
 *)
let rewrite_coroutine_annotation
    ({
      closure_parameter_types;
      closure_return_type;
      _;
    } as original_type) =
  let new_return_type =
    CoroutineTypeLowerer.rewrite_return_type closure_return_type in
  let continuation_type = make_continuation_type_syntax new_return_type in
  let new_parameter_types = prepend_to_comma_delimited_syntax_list
    continuation_type closure_parameter_types in
  let coroutine_return_type =
    make_coroutine_result_type_syntax new_return_type in
  make_syntax (
    ClosureTypeSpecifier {
      original_type with
        closure_coroutine = make_missing ();
        closure_parameter_types = new_parameter_types;
        closure_return_type = coroutine_return_type;
    }
  )

let rewrite_method_or_function
    classish_name
    classish_type_parameters
    original_header_node
    original_body =
  let new_header_node = rewrite_header_node original_header_node in
  let new_body, closure_syntax =
    CoroutineStateMachineGenerator.generate_coroutine_state_machine
      classish_name
      classish_type_parameters
      original_body
      new_header_node in
  (new_header_node, new_body, closure_syntax)

let lower_coroutine_function original_header original_body original_function =
  let (new_header_node, new_body, closure_syntax) =
    rewrite_method_or_function
      global_syntax
      (make_missing ())
      original_header
      original_body in
  let new_function_syntax =
    CoroutineMethodLowerer.rewrite_function_declaration
      original_function
      new_header_node
      new_body in
  (closure_syntax, new_function_syntax)

let lower_coroutine_functions_and_types
    parents
    current_node
    ((closures, lambda_count) as current_acc) =
  match syntax current_node with
  | FunctionDeclaration ({
      function_declaration_header = {
        syntax = FunctionDeclarationHeader ({
          function_coroutine;
          _;
        } as header_node);
        _;
      };
      function_body;
      _;
    } as function_node) when not @@ is_missing function_coroutine ->
      let (closure_syntax, new_function_syntax) =
        lower_coroutine_function header_node function_body function_node in
      ((closure_syntax :: closures, lambda_count),
        Rewriter.Result.Replace new_function_syntax)
  | LambdaExpression {
    lambda_coroutine;
    _;
    } when not @@ is_missing lambda_coroutine ->
     (* TODO: rewrite lambdas *)
     (current_acc, Rewriter.Result.Keep)
  | AnonymousFunction {
    anonymous_coroutine_keyword;
    _;
    }  when not @@ is_missing anonymous_coroutine_keyword ->
     (* TODO: rewrite anonymous functions *)
     (current_acc, Rewriter.Result.Keep)
  | MethodishDeclaration ({
      methodish_function_decl_header = {
        syntax = FunctionDeclarationHeader ({
          function_coroutine;
          _;
        } as header_node);
        _;
      };
      methodish_function_body;
      _;
    } as method_node) when not @@ is_missing function_coroutine ->
    (* TODO: Plumb the context through rather than tramping around the
    header, class name and class type parameters. *)
    let context = Coroutine_context.make_from_context parents in
    let classish_name = context.Coroutine_context.classish_name in
    let classish_type_parameters =
      context.Coroutine_context.classish_type_parameters in
    let (new_header_node, new_body, closure_syntax) =
      rewrite_method_or_function
        context.Coroutine_context.classish_name
        context.Coroutine_context.classish_type_parameters
        header_node
        methodish_function_body in
    let new_method_syntax =
      CoroutineMethodLowerer.rewrite_methodish_declaration
        classish_name
        classish_type_parameters
        method_node
        new_header_node
        new_body in
    ((closure_syntax :: closures, lambda_count),
      Rewriter.Result.Replace new_method_syntax)
  | ClosureTypeSpecifier ({ closure_coroutine; _; } as type_node)
    when not @@ is_missing closure_coroutine ->
      let new_type_node = rewrite_coroutine_annotation type_node in
      (current_acc, Rewriter.Result.Replace new_type_node)
  | _ ->
    (current_acc, Rewriter.Result.Keep)

(*
We are working around a significant shortcoming of HHVM here.  We are supposed
to have an invariant that the order in which type declarations appear in a
Hack file is irrelevant, but this is not the case:

interface I {}
class B implements I {}
new D(); // Crashes here at runtime
class D extends B {}

The crash is due to a peculiarity in how HHVM handles interfaces.

The closure classes extend the closure base, which implements an interface.
We can therefore very easily get into this situation when generating closure
classes at the end of a file.

What we do then is gather up *all* the classes in a file, sort them to the
top of the file, follow them with the closure classes, and then the rest
of the code in the file.

This unfortunate code can be removed when the bug is fixed in HHVM, and
we can simply append the closure classes to the end of the list of
declarations.
*)
let rewrite_script closures root =
  match closures with
  | [] -> root
  | _ ->
    begin match syntax root with
    | Script { script_declarations } ->
      let script_declarations = syntax_node_to_list script_declarations in
      let (types, not_types) =
        List.partition_tf script_declarations ~f:is_classish_declaration in
      begin match not_types with
      | h :: t -> make_script (make_list (h :: (types @ closures @ t)))
      | [] -> failwith "How did we get a script with no header element?"
      end
    | _ -> failwith "How did we get a root that is not a script?"
    end

let lower_coroutines syntax_tree =
  let root = from_tree syntax_tree in
  let ((closures, _), root) = Rewriter.parented_aggregating_rewrite_post
    lower_coroutine_functions_and_types root ([], 0) in
  root
    |> rewrite_script (List.rev closures)
    |> text
    |> SourceText.make
    |> SyntaxTree.make
