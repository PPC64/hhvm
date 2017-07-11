 (**
 * Copyright (c) 2017, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
*)

(*
 * FUTURE IMPROVEMENTS:
 * - Order suggestions by how likely they are to be what the programmer
 *   wishes to do, not just what is valid
 * - Order sensitive suggestions, i.e. after public suggest the word function
 *)

module SyntaxTree = Full_fidelity_syntax_tree
module MinToken = Full_fidelity_minimal_token
module MinimalSyntax = Full_fidelity_minimal_syntax
module TokenKind = Full_fidelity_token_kind
module SyntaxKind = Full_fidelity_syntax_kind
open String_utils
open Core

module Container = struct
  (* Set of mutually exclusive contexts. *)
  type t =
  | ClassBody
  | TypeSpecifier
  | TopLevel
  | LambdaBodyExpression
  | CompoundStatement
  | BinaryExpression
  | NoContainer
end
open Container

type predecessor =
  | IfWithoutElse
  | TryWithoutFinally
  | OpenBrace
  | Statement
  | NoPredecessor

type context = {
  closest_parent_container: Container.t;
  predecessor: predecessor;
  inside_switch_body: bool;
  inside_loop_body: bool;
  inside_async_function: bool;
}

(* TODO: Do more comprehensive testing using actual Hack files *)

let class_leading_modifiers = ["abstract"; "final"; "abstract final"]
let class_leading_modifiers_context context =
  context.closest_parent_container = TopLevel

let class_trailing_modifiers = ["implements"; "extends"]
let class_trailing_modifiers_context context =
  context.closest_parent_container = ClassBody &&
  not (context.predecessor = OpenBrace)

let visibility_modifiers = ["public"; "protected"; "private"]
let visibility_modifiers_context context =
  context.closest_parent_container = ClassBody &&
  (context.predecessor = OpenBrace || context.predecessor = Statement)

(*
 * TODO: Complete these after other modifiers, i.e. "public static asy" should
 * suggest "async" as a completion.
 *)
let method_modifiers = ["abstract"; "final"; "static"; "async"]
let method_modifiers_context context =
  context.closest_parent_container = ClassBody &&
  (context.predecessor = OpenBrace || context.predecessor = Statement)

let class_body_keywords = ["function"; "const"; "use"]
let class_body_context context =
  context.closest_parent_container = ClassBody &&
  (context.predecessor = OpenBrace || context.predecessor = Statement)
(* TODO: function should be suggested after the method modifiers *)

let declaration_keywords = ["enum"; "require"; "class"; "include";
  "require_once"; "include_once"; "function"; "use"; "interface"; "namespace";
  "newtype"; "type"; "trait"]
let declaration_keywords_context context =
  context.closest_parent_container = TopLevel

let type_specifiers = ["bool"; "int"; "float"; "num"; "string"; "arraykey";
  "void"; "resource"; "this"; "classname"; "mixed"; "noreturn"]
let type_specifiers_context context =
  context.closest_parent_container = TypeSpecifier

let loop_body_keywords = ["continue"; "break"]
let loop_body_context context = context.inside_loop_body

let switch_body_keywords = ["case"; "default"; "break"]
let switch_body_context context = context.inside_switch_body

(*
 * TODO: Ideally, await will always be allowed inside a function body. Typing
 * await in a non-async function should either automatically make the function
 * async or suggest this change.
 *)
let async_func_body_keywords = ["await"]
let async_func_body_context context = context.inside_async_function &&
  context.closest_parent_container = CompoundStatement

(*
 * TODO: Figure out what exactly a postfix expression is and when one is valid
 * or more importantly, invalid.
 *)
let postfix_expressions = ["clone"; "new"]
let postfix_expressions_context context =
  context.closest_parent_container = CompoundStatement ||
  context.closest_parent_container = LambdaBodyExpression

let general_statements = ["if"; "do"; "while"; "for"; "foreach"; "try";
  "return"; "throw"; "switch"; "yield"; "echo"; "async"]
let general_statements_context context =
  context.closest_parent_container = CompoundStatement

let if_trailing_keywords = ["else"; "elseif"]
let if_trailing_context context =
  context.predecessor = IfWithoutElse

let try_trailing_keywords = ["catch"; "finally"]
let try_trailing_context context =
  context.predecessor = TryWithoutFinally

(*
 * According to the spec, vacuous expressions (a function with no side
 * effects is called then has its result discarded) are allowed.
 * TODO: Should we only complete expressions when it makes sense to do so?
 * i.e. Only suggest these keywords in a return statement, as an argument to a
 * function, or on the RHS of an assignment expression.
 *)
let primary_expressions = ["tuple"; "shape"]
let primary_expressions_context context =
  context.closest_parent_container = CompoundStatement ||
  context.closest_parent_container = LambdaBodyExpression

let scope_resolution_qualifiers = ["self"; "parent"; "static"]
let scope_resolution_context context =
  context.closest_parent_container = CompoundStatement ||
  context.closest_parent_container = LambdaBodyExpression

(*
 * An improperly formatted use body causes the parser to throw an error so we
 * cannot complete these at the moment.
 *)
let use_body_keywords = ["insteadof"; "as"]

(*
 * Each pair in this list is a list of keywords paired with a function that
 * takes a context and returns whether or not the list of keywords is valid in
 * this context.
 *)
let keyword_matches: (string list * (context -> bool)) list = [
  (class_leading_modifiers, class_leading_modifiers_context);
  (class_body_keywords, class_body_context);
  (class_trailing_modifiers, class_trailing_modifiers_context);
  (method_modifiers, method_modifiers_context);
  (visibility_modifiers, visibility_modifiers_context);
  (declaration_keywords, declaration_keywords_context);
  (type_specifiers, type_specifiers_context);
  (general_statements, general_statements_context);
  (loop_body_keywords, loop_body_context);
  (switch_body_keywords, switch_body_context);
  (postfix_expressions, postfix_expressions_context);
  (primary_expressions, primary_expressions_context);
  (scope_resolution_qualifiers, scope_resolution_context);
  (if_trailing_keywords, if_trailing_context);
  (try_trailing_keywords, try_trailing_context);
  (async_func_body_keywords, async_func_body_context);
]

let initial_context = {
  closest_parent_container = NoContainer;
  predecessor = NoPredecessor;
  inside_switch_body = false;
  inside_loop_body = false;
  inside_async_function = false;
}

let is_function_async (function_object:MinimalSyntax.t) : bool =
  let open MinimalSyntax in
  let open MinToken in
  let open TokenKind in
  match function_object.syntax with
  | FunctionDeclaration {
      function_declaration_header = { syntax = FunctionDeclarationHeader {
        function_async = { syntax = Token {
          kind = Async; _
        }; _ }; _
      }; _ }; _
    }
  | LambdaExpression {
      lambda_async = { syntax = Token {
        kind = Async; _ }; _
      }; _
    } -> true
  | _ -> false

let build_context_from_path (full_path:MinimalSyntax.t list) (predecessor:predecessor) : context =
  let open MinimalSyntax in
  let rec aux path acc = match path with
    | [] -> acc
    | { syntax = SimpleTypeSpecifier _; _} :: _ ->
      { acc with closest_parent_container = TypeSpecifier }
    | { syntax = Script _; _} :: t ->
      aux t { acc with closest_parent_container = TopLevel }
    | { syntax = ClassishBody _; _} :: t ->
      aux t { acc with closest_parent_container = ClassBody }
    | { syntax = ForStatement _; _} :: t
    | { syntax = ForeachStatement _; _} :: t
    | { syntax = WhileStatement _; _} :: t
    | { syntax = DoStatement _; _} :: t ->
      aux t { acc with inside_loop_body = true }
    | { syntax = SwitchSection _; _} :: t ->
      aux t { acc with inside_switch_body = true }
    | { syntax = FunctionDeclaration _; _}  as h :: t ->
      aux t { acc with inside_async_function = is_function_async h }
    | { syntax = LambdaExpression _; _} as h :: t ->
      (* If we see a lambda, almost all context is reset, so each field should get consideration
      on if its context flows into the lambda *)
      let acc = {
        closest_parent_container = LambdaBodyExpression;
        predecessor = predecessor;
        inside_switch_body = false;
        inside_loop_body = false;
        inside_async_function = is_function_async h;
      }
      in
      aux t acc
    | { syntax = MinimalSyntax.CompoundStatement _; _} :: t ->
      aux t { acc with closest_parent_container = Container.CompoundStatement }
    | _ :: t -> aux t acc
  in
  aux full_path { initial_context with predecessor }

let get_context_keywords (path:MinimalSyntax.t list) (predecessor:predecessor) : string list =
  let context = build_context_from_path path predecessor in
  let keywords = List.filter_map keyword_matches
    ~f:begin fun (keywords, is_valid) ->
    Option.some_if (is_valid context) keywords
  end in
  List.concat keywords

let validate_predecessor (predecessor:MinimalSyntax.t) : predecessor =
  let open MinimalSyntax in
  match syntax predecessor with
  | IfStatement { if_else_clause = {
      syntax = Missing; _
    }; _ } -> IfWithoutElse
  | TryStatement { try_finally_clause = {
      syntax = Missing; _
    }; _ } -> TryWithoutFinally
  | MethodishDeclaration _ -> Statement
  | Token { MinToken.kind = TokenKind.LeftBrace; _ } -> OpenBrace
  | _ -> NoPredecessor

(**
 * Here's an example of a (simplified) syntax tree:
 *
 * `-- Script
 *    +-- Header
 *    |   `-- ...
 *    `-- Declarations
 *        `-- FunctionDeclaration
 *            +-- Header
 *            |   +-- ...
 *            |   `-- ...
 *            `-- Body
 *                +-- MISSING
 *                `-- QualifiedName
 *
 * This function takes the root of a syntax tree and a position n which
 * corresponds to the nth character of the original file. The parentage is
 * the descent through the syntax tree to the leaf node at position n.
 *
 * The predecessor of a node is the preceding sibling of the node according to
 * the order defined by the children function in full_fidelity_syntax.ml. If a
 * node is the first child of its parent node, then its predecessor is its
 * parent's predecessor.
 *
 * TODO: Add a unit test to enforce children order
 *
 * This predecessor corresponds to the chunk of text immediately before the leaf
 * node at the position we are in. This is useful for tasks such as determining
 * if we are inside a class body or inside the class header or if we are directly
 * following an if statement.
 *
 * The width function returns the span of the current node. At each level, we
 * see if we are inside the leftmost node's width. If not, we discard the left-
 * most node and continue looking at the other nodes in the level. If we *are*
 * inside the leftmost node, then we move to the next level, which is all the
 * children of the current node. Once we have no more children, we have reached
 * a leaf node.
 *
 * In this example, if position is inside the QualifiedName at the bottom,
 * we would expect the function to return:
 * Parentage: [QualifiedName, Body, FunctionDeclaration, Declarations, Script]
 * Predecessor: Some Header
 *
 * TODO: Add a unit test that reflects this example
 **)
let get_parentage_and_predecessor (root:MinimalSyntax.t) (position:int)
 : MinimalSyntax.t list * MinimalSyntax.t option =
  let rec get_next_child ~current_level ~position ~parentage ~predecessor =
    match current_level with
    | [] -> (parentage, predecessor)
    | h :: t ->
      let width = MinimalSyntax.full_width h in
      if position < width then
        get_next_child ~current_level:(MinimalSyntax.children h) ~position
          ~parentage:(h :: parentage) ~predecessor
      else
        let prev = if MinimalSyntax.kind h = SyntaxKind.Missing
          then predecessor
          else (Some h)
        in
        get_next_child ~current_level:t ~position:(position - width) ~parentage
          ~predecessor:prev
  in
  get_next_child ~current_level:[root] ~position ~parentage:[] ~predecessor:None

let autocomplete_keyword (syntax_tree:SyntaxTree.t) (offset:int) (stub:string) : string list =
  let tree = SyntaxTree.root syntax_tree in
  let (parents, autocomplete_predecessor) =
    get_parentage_and_predecessor tree offset in
  let context = List.rev parents in
  let predecessor = match autocomplete_predecessor with
    | Some p -> validate_predecessor p
    | None -> NoPredecessor
  in
  let possibilities = get_context_keywords context predecessor in
  possibilities
    |> List.filter ~f:(fun x -> string_starts_with x stub)
    |> List.sort ~cmp:Pervasives.compare
    |> List.remove_consecutive_duplicates ~equal:(=)
