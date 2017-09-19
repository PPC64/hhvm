(**
 * Copyright (c) 2016, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

module PositionedSyntax = Full_fidelity_positioned_syntax
module PositionedToken = Full_fidelity_positioned_token
module SyntaxUtilities =
  Full_fidelity_syntax_utilities.WithSyntax(PositionedSyntax)
module SyntaxError = Full_fidelity_syntax_error
module TokenKind = Full_fidelity_token_kind

open PositionedSyntax

type namespace_type =
  | Unspecified
  | Bracketed of { start_offset : int; end_offset : int }
  | Unbracketed of { start_offset : int; end_offset : int }

type accumulator = {
  errors : SyntaxError.t list;
  namespace_type : namespace_type;
}

(* Turns a syntax node into a list of nodes; if it is a separated syntax
   list then the separators are filtered from the resulting list. *)
let syntax_to_list include_separators node  =
  let rec aux acc syntax_list =
    match syntax_list with
    | [] -> acc
    | h :: t ->
      begin
        match syntax h with
        | ListItem { list_item; list_separator } ->
          let acc = list_item :: acc in
          let acc =
            if include_separators then (list_separator :: acc ) else acc in
          aux acc t
        | _ -> aux (h :: acc) t
      end in
  match syntax node with
  | Missing -> [ ]
  | SyntaxList s -> List.rev (aux [] s)
  | ListItem { list_item; list_separator } ->
    if include_separators then [ list_item; list_separator ] else [ list_item ]
  | _ -> [ node ]

let syntax_to_list_no_separators = syntax_to_list false
let syntax_to_list_with_separators = syntax_to_list true

let assert_last_in_list assert_fun node =
  let rec aux lst =
    match lst with
    | []
    | _ :: [] -> None
    | h :: _ when assert_fun h -> Some h
    | _ :: t -> aux t in
  aux (syntax_to_list_no_separators node)

let is_variadic_expression node =
  begin match syntax node with
    | DecoratedExpression { decorated_expression_decorator; _; } ->
      is_ellipsis decorated_expression_decorator
    | _ -> false
  end

let is_variadic_parameter_variable node =
  (* TODO: This shouldn't be a decorated *expression* because we are not
  expecting an expression at all. We're expecting a declaration. *)
  is_variadic_expression node

let is_variadic_parameter_declaration node =
  begin match syntax node with
  | VariadicParameter _ -> true
  | ParameterDeclaration { parameter_name; _ } ->
      is_variadic_parameter_variable parameter_name
  | _ -> false
  end

let misplaced_variadic_param params =
  assert_last_in_list is_variadic_parameter_declaration params

let misplaced_variadic_arg args =
  assert_last_in_list is_variadic_expression args

(* If a list ends with a variadic parameter followed by a comma, return it *)
let ends_with_variadic_comma params =
  let rec aux params =
    match params with
    | [] -> None
    | x :: y :: [] when is_variadic_parameter_declaration x && is_comma y ->
      Some y
    | _ :: t -> aux t in
  aux (syntax_to_list_with_separators params)

(* True or false: the first item in this list matches the predicate? *)
let matches_first f items =
  match items with
  | h :: _ when f h -> true
  | _ -> false

(* test a node is a syntaxlist and that the list contains an element
 * satisfying a given predicate *)
let list_contains_predicate p node =
  match syntax node with
  | SyntaxList lst ->
    List.exists p lst
  | _ -> false

(* test a node is a syntaxlist and that the list contains multiple elements
 * satisfying a given predicate *)
let list_contains_multiple_predicate p node =
  match syntax node with
  | SyntaxList lst ->
    let count_fun acc el = if p el then acc + 1 else acc in
    (List.fold_left count_fun 0 lst) > 1
  | _ -> false

let list_contains_duplicate node =
  let module SyntaxMap = Map.Make (
    struct
      type t = PositionedSyntax.t
      let compare a b = match syntax a, syntax b with
      | Token x, Token y ->
        Full_fidelity_positioned_token.(compare (kind x) (kind y))
      | _, _ -> Pervasives.compare a b
    end
  ) in
  match syntax node with
  | SyntaxList lst ->
    let check_fun (tbl, acc) el =
      if SyntaxMap.mem el tbl then (tbl, true)
      else (SyntaxMap.add el () tbl, acc)
    in
    let (_, result) = List.fold_left check_fun (SyntaxMap.empty, false) lst in
    result
  | _ ->  false

let token_kind node =
  match syntax node with
  | Token t -> Some (PositionedToken.kind t)
  | _ -> None

(* Helper function for common code pattern *)
let is_token_kind node kind =
  (token_kind node) = Some kind

let rec containing_classish_kind parents =
  match parents with
  | [] -> None
  | h :: t ->
    begin
      match syntax h with
      | ClassishDeclaration c -> token_kind c.classish_keyword
      | _ -> containing_classish_kind t
    end

(* tests whether the methodish contains a modifier that satisfies [p] *)
let methodish_modifier_contains_helper p node =
  match syntax node with
  | MethodishDeclaration syntax ->
    let node = syntax.methodish_modifiers in
    list_contains_predicate p node
  | _ -> false

(* tests whether the methodish contains > 1 modifier that satisfies [p] *)
let methodish_modifier_multiple_helper p node =
  match syntax node with
  | MethodishDeclaration syntax ->
    let node = syntax.methodish_modifiers in
    list_contains_multiple_predicate p node
  | _ -> false

(* test the methodish node contains the Final keyword *)
let methodish_contains_final node =
  methodish_modifier_contains_helper is_final node

(* test the methodish node contains the Abstract keyword *)
let methodish_contains_abstract node =
  methodish_modifier_contains_helper is_abstract node

(* test the methodish node contains the Static keyword *)
let methodish_contains_static node =
  methodish_modifier_contains_helper is_static node

(* test the methodish node contains the Private keyword *)
let methodish_contains_private node =
  methodish_modifier_contains_helper is_private node

let is_visibility x =
  is_public x || is_private x || is_protected x

(* test the methodish node contains any non-visibility modifiers *)
let methodish_contains_non_visibility node =
  let is_non_visibility x = not (is_visibility x) in
  methodish_modifier_contains_helper is_non_visibility node

(* checks if a methodish decl has multiple visibility modifiers *)
let methodish_multiple_visibility node =
  methodish_modifier_multiple_helper is_visibility node

(* Given a function declaration header, confirm that it is a constructor
 * and that the methodish containing it has a static keyword *)
let class_constructor_has_static node parents =
  let label = node.function_name in
  (is_construct label) && (matches_first methodish_contains_static parents)

(* Given a function declaration header, confirm that it is NOT a constructor
 * and that the header containing it has visibility modifiers in parameters
 *)
let class_non_constructor_has_visibility_param node parents =
  let has_visibility node =
    match syntax node with
    | ParameterDeclaration { parameter_visibility; _ } ->
      parameter_visibility |> is_missing |> not
    | _ -> false
  in
  let label = node.function_name in
  let params = syntax_to_list_no_separators node.function_parameter_list in
  (not (is_construct label)) && (List.exists has_visibility params)

(* Given a function declaration header, confirm that it is a destructor
 * and that the methodish containing it has non-empty parameters *)
let class_destructor_has_param node parents =
  let label = node.function_name in
  let param = node.function_parameter_list in
  (is_destruct label) && not (is_missing param)

(* Given a function declaration header, confirm that it is a destructor
 * and that the methodish containing it has non-visibility modifiers *)
let class_destructor_has_non_visibility_modifier node parents =
  let label = node.function_name in
  (is_destruct label) &&
  (matches_first methodish_contains_non_visibility parents)

(* check that a constructor or a destructor is type annotated *)
let class_constructor_destructor_has_non_void_type node parents =
  let label = node.function_name in
  let type_ano = node.function_type in
  let function_colon = node.function_colon in
  let is_missing = is_missing type_ano && is_missing function_colon in
  let is_void = match syntax type_ano with
    | SimpleTypeSpecifier spec ->
      is_void spec.simple_type_specifier
    | _ -> false
  in
  (is_construct label || is_destruct label) &&
  not (is_missing || is_void)

(* whether a methodish has duplicate modifiers *)
let methodish_duplicate_modifier node =
  match syntax node with
  | MethodishDeclaration syntax ->
    let modifiers = syntax.methodish_modifiers in
    list_contains_duplicate modifiers
  | _ -> false

(* whether a methodish decl has body *)
let methodish_has_body node =
  match syntax node with
  | MethodishDeclaration syntax ->
    let body = syntax.methodish_function_body in
    not (is_missing body)
  | _ -> false

(* By checking the third parent of a methodish node, tests whether the methodish
 * node is inside an interface. *)
let methodish_inside_interface parents =
  match parents with
  | _ :: _ :: p3 :: _ ->
    begin match syntax p3 with
    | ClassishDeclaration { classish_keyword; _ } ->
      is_token_kind classish_keyword TokenKind.Interface
    | _ -> false
    end
  | _ -> false

(* Test whether node is an abstract method with a body.
 * Here node is the methodish node *)
let methodish_abstract_with_body node =
  let is_abstract = methodish_contains_abstract node in
  let has_body = methodish_has_body node in
  is_abstract && has_body

(* Test whether node is a non-abstract method without a body.
 * Here node is the methodish node
 * And methods inside interfaces are inherently considered abstract *)
let methodish_non_abstract_without_body node parents =
  let non_abstract = not (methodish_contains_abstract node
      || methodish_inside_interface parents) in
  let not_has_body = not (methodish_has_body node) in
  non_abstract && not_has_body

let methodish_in_interface_has_body node parents =
  methodish_inside_interface parents && methodish_has_body node

(* Test whether node is a method that is both abstract and private
 *)
let methodish_abstract_conflict_with_private node =
  let is_abstract = methodish_contains_abstract node in
  let has_private = methodish_contains_private node in
  is_abstract && has_private

(* Test whether node is a method that is both abstract and final
 *)
let methodish_abstract_conflict_with_final node =
  let is_abstract = methodish_contains_abstract node in
  let has_final = methodish_contains_final node in
  is_abstract && has_final

let rec parameter_type_is_required parents =
  match parents with
  | h :: _ when is_function_declaration h -> true
  | h :: _ when is_anonymous_function h -> false (* TODO: Lambda? *)
  | _ :: t -> parameter_type_is_required t
  | [] -> false

let rec break_is_legal parents =
  match parents with
  | h :: _ when is_anonymous_function h -> false
  | h :: _ when is_switch_statement h -> true
  | h :: _ when is_loop_statement h -> true
  | _ :: t -> break_is_legal t
  | [] -> false

let rec continue_is_legal parents =
  match parents with
  | h :: _ when is_anonymous_function h -> false
  | h :: _ when is_loop_statement h -> true
  | _ :: t -> continue_is_legal t
  | [] -> false

let is_bad_xhp_attribute_name name =
  (String.contains name ':') || (String.contains name '-')

let make_error_from_nodes start_node end_node error =
  let s = start_offset start_node in
  let e = end_offset end_node in
  SyntaxError.make s e error

let make_error_from_node node error =
  make_error_from_nodes node node error

let is_invalid_xhp_attr_enum_item_literal literal_expression =
  match syntax literal_expression with
  | Token t -> begin
      Full_fidelity_token_kind.(match PositionedToken.kind t with
      | DecimalLiteral | SingleQuotedStringLiteral
      | DoubleQuotedStringLiteral -> false
      | _ -> true)
    end
  | _ -> true

let is_invalid_xhp_attr_enum_item node =
  match syntax node with
  | LiteralExpression {literal_expression} ->
      is_invalid_xhp_attr_enum_item_literal literal_expression
  | _ -> true

let xhp_errors node _parents =
(* An attribute name cannot contain - or :, but we allow this in the lexer
   because it's easier to have one rule for tokenizing both attribute and
   element names. *)
  match syntax node with
  |  XHPAttribute attr when
    (is_bad_xhp_attribute_name
    (PositionedSyntax.text attr.xhp_attribute_name)) ->
      [ make_error_from_node attr.xhp_attribute_name SyntaxError.error2002 ]
  |  XHPEnumType enumType when
    (is_missing enumType.xhp_enum_values) ->
      [ make_error_from_node enumType.xhp_enum_values SyntaxError.error2055 ]
  |  XHPEnumType enumType ->
    let invalid_enum_items = List.filter is_invalid_xhp_attr_enum_item
      (syntax_to_list_no_separators enumType.xhp_enum_values) in
    let mapper item = make_error_from_node item SyntaxError.error2063 in
    List.map mapper invalid_enum_items
  | _ -> [ ]

let classish_duplicate_modifiers node =
  list_contains_duplicate node

let type_contains_array_in_strict is_strict node =
  is_array node && is_strict

(* helper since there are so many kinds of errors *)
let produce_error acc check node error error_node =
  if check node then
    (make_error_from_node error_node error) :: acc
  else acc

let produce_error_parents acc check node parents error error_node =
  if check node parents then
    (make_error_from_node error_node error) :: acc
  else acc

(* use [check] to check properties of function *)
let function_header_check_helper check node parents =
  match syntax node with
  | FunctionDeclarationHeader node -> check node parents
  | _ -> false

let produce_error_for_header acc check node error error_node =
  produce_error_parents acc (function_header_check_helper check) node
    error error_node

(* Given a ClassishDeclaration node, test whether or not it contains
 * an invalid use of 'implements'. *)
let classish_invalid_implements_keyword cd_node =
  (* Invalid if uses 'implements' and isn't a class. *)
  token_kind cd_node.classish_implements_keyword = Some TokenKind.Implements &&
    token_kind cd_node.classish_keyword <> Some TokenKind.Class

(* Given a ClassishDeclaration node, test whether or not it's a trait
 * invoking the 'extends' keyword. *)
let classish_invalid_extends_keyword cd_node =
  (* Invalid if uses 'extends' and is a trait. *)
  token_kind cd_node.classish_extends_keyword = Some TokenKind.Extends &&
    token_kind cd_node.classish_keyword = Some TokenKind.Trait

(* Given a ClassishDeclaration node, test whether or not length of
 * extends_list is appropriate for the classish_keyword. *)
let classish_invalid_extends_list cd_node =
  (* Invalid if is a class and has list of length greater than one. *)
  token_kind cd_node.classish_keyword = Some TokenKind.Class &&
    token_kind cd_node.classish_extends_keyword = Some TokenKind.Extends &&
    match syntax_to_list_no_separators cd_node.classish_extends_list with
    | [x1] -> false
    | _ -> true (* General bc empty list case is already caught by error1007 *)

(* Given a particular TokenKind.(Trait/Interface/Class), tests if a given
 * classish_declaration node is both of that kind and declared abstract. *)
let is_classish_kind_declared_abstract classish_kind cd_node =
  match syntax cd_node with
  | ClassishDeclaration { classish_keyword; classish_modifiers; _ }
    when is_token_kind classish_keyword classish_kind ->
      list_contains_predicate is_abstract classish_modifiers
  | _ -> false

(* Given a function_declaration_header node, returns its function_name
 * as a string opt. *)
let extract_function_name header_node =
  (* The '_' arm of this match will never be reached, but the type checker
   * doesn't allow a direct extraction of function_name from
   * function_declaration_header. *)
   match syntax header_node with
   | FunctionDeclarationHeader fdh ->
     Some (PositionedSyntax.text fdh.function_name)
   | _ -> None

(* Return, as a string opt, the name of the function with the earliest
 * declaration node in the list of parents. *)
let first_parent_function_name parents =
  Core.List.find_map parents ~f:begin fun node ->
    match syntax node with
    | FunctionDeclaration {function_declaration_header = header; _ }
    | MethodishDeclaration {methodish_function_decl_header = header; _ } ->
      extract_function_name header
    | _ -> None
  end

(* Returns the first ClassishDeclaration node in the list of parents,
 * or None if there isn't one. *)
let first_parent_classish_node classish_kind parents =
  Core.List.find_map parents ~f:begin fun node ->
  match syntax node with
  | ClassishDeclaration cd
    when is_token_kind cd.classish_keyword classish_kind -> Some node
  | _ -> None
  end

(* Return, as a string opt, the name of the earliest Class in the list of
 * parents. *)
let first_parent_class_name parents =
  let parent_class_decl = first_parent_classish_node TokenKind.Class parents in
  Option.value_map parent_class_decl ~default:None ~f:begin fun node ->
    match syntax node with
    | ClassishDeclaration cd -> Some (PositionedSyntax.text cd.classish_name)
    | _ -> None (* This arm is never reached  *)
  end

(* Given a classish_ or methodish_ declaration node, returns the modifier node
   from its list of modifiers, or None if there isn't one. *)
let extract_keyword modifier declaration_node =
  match syntax declaration_node with
  | ClassishDeclaration { classish_modifiers = modifiers_list ; _ }
  | MethodishDeclaration { methodish_modifiers = modifiers_list ; _ } ->
    Core.List.find ~f:modifier
        (syntax_to_list_no_separators modifiers_list)
  | _ -> None

(* Wrapper function that uses above extract_keyword function to test if node
   contains is_abstract keyword *)
let is_abstract_declaration declaration_node =
  not (Option.is_none (extract_keyword is_abstract declaration_node))

(* Wrapper function that uses above extract_keyword function to test if node
   contains is_final keyword *)
let is_final_declaration declaration_node =
  not (Option.is_none (extract_keyword is_final declaration_node))

(* Given a methodish_declaration node and a list of parents, tests if that
 * node declares an abstract method inside of a no-nabstract class. *)
let abstract_method_in_nonabstract_class md_node parents =
  let is_abstract_method = is_abstract_declaration md_node in
  let parent_class_node = first_parent_classish_node TokenKind.Class parents in
  let is_in_nonabstract_class =
    match parent_class_node with
    | None -> false
    | Some node -> not (is_abstract_declaration node) in
  is_abstract_method && is_in_nonabstract_class

(* Given a list of parents, tests if the immediate classish parent is an
 * interface. *)
let is_inside_interface parents =
  Option.is_some (first_parent_classish_node TokenKind.Interface parents)

(* Given a methodish_declaration node and a list of parents, tests if that
 * node declares an abstract method inside of an interface. *)
let abstract_method_in_interface md_node parents =
  is_abstract_declaration md_node && is_inside_interface parents

(* Tests if md_node is either explicitly declared abstract or is
 * defined inside an interface *)
let is_generalized_abstract_method md_node parents =
  is_abstract_declaration md_node || is_inside_interface parents

(* Returns the 'async'-annotation syntax node from the methodish_declaration
 * node. The returned node may have syntax kind 'Missing', but it will only be
 * None if something other than a methodish_declaration node was provided as
 * input. *)
let extract_async_node md_node =
  match syntax md_node with
  | MethodishDeclaration { methodish_function_decl_header; _ } -> begin
    match syntax methodish_function_decl_header with
    | FunctionDeclarationHeader { function_async ; _ } -> Some function_async
    | _ ->
      failwith("Encountered an improperly defined methodish_function_decl_" ^
      "header: expected it to match FunctionDeclarationHeader with field " ^
      "function_async.")
    end
  | _ -> None (* Only method declarations have async nodes *)

(* Given a node and its parents, tests if the node declares a method that is
 * both abstract and async. *)
let is_abstract_and_async_method md_node parents =
  let async_node = extract_async_node md_node in
  match async_node with
  | None -> false
  | Some async_node ->
    is_generalized_abstract_method md_node parents
        && not (is_missing async_node)

(* Returns the visibility modifier node from a list, or None if the
 * list doesn't contain one. *)
let extract_visibility_node modifiers_list =
  let is_visibility_modifier modifier =
    match token_kind modifier with
    | Some TokenKind.Public
    | Some TokenKind.Private
    | Some TokenKind.Protected -> true
    | _ -> false in
  Core.List.find ~f:is_visibility_modifier (syntax_to_list_no_separators
    modifiers_list)

(* Tests if visibility modifiers of the node are allowed on
 * methods inside an interface. *)
let has_valid_interface_visibility node =
  match syntax node with
  | MethodishDeclaration { methodish_modifiers; _ } ->
    let visibility_kind = extract_visibility_node methodish_modifiers in
    let is_valid_methodish_visibility kind =
      (is_token_kind kind TokenKind.Public) in
    (* Defaulting to 'true' allows omitting visibility in method_declarations *)
    Option.value_map visibility_kind
      ~f:is_valid_methodish_visibility ~default:true
  | _ -> true (* If not a methodish declaration, is vacuously valid *)

(* Tests if a given node is a method definition (inside an interface) with
 * either private or protected visibility. *)
let invalid_methodish_visibility_inside_interface node parents =
  is_inside_interface parents && not (has_valid_interface_visibility node)

(* Test if (a list_expression is the left child of a binary_expression,
 * and the operator is '=') *)
let is_left_of_simple_assignment le_node p1 =
  match syntax p1 with
  | BinaryExpression { binary_left_operand; binary_operator; _ } ->
    le_node == binary_left_operand  &&
        is_token_kind binary_operator TokenKind.Equal
  | _ -> false

(* Test if a list_expression is the value clause of a foreach_statement *)
let is_value_of_foreach le_node p1 =
  match syntax p1 with
  | ForeachStatement { foreach_value; _ } -> le_node == foreach_value
  | _ -> false

let is_invalid_list_expression le_node parents =
  match parents with
  | p1 :: _ when is_left_of_simple_assignment le_node p1 -> false
  | p1 :: _ when is_value_of_foreach le_node p1 -> false
  (* checking p3 is sufficient to test if le_node is a nested list_expression *)
  | _ :: _ :: p3 :: _ when is_list_expression p3 -> false
  | _ -> true (* All other deployments of list_expression are invalid *)

(* Given a node, checks if it is a concrete ConstDeclaration *)
let is_concrete_const declaration =
  match syntax declaration with
  | ConstDeclaration x -> is_missing x.const_abstract
  | _ -> false

(* Given a node, checks if it is a abstract ConstDeclaration *)
let is_abstract_const declaration =
  match syntax declaration with
  | ConstDeclaration x -> not (is_missing x.const_abstract)
  | _ -> false

(* Given a ConstDeclarator node, test whether it is concrete, but has no
   initializer. *)
let concrete_no_initializer cd_node parents =
  let is_concrete =
    match parents with
    | _ :: _ :: p3 :: _ when is_concrete_const p3 -> true
    | _ -> false
    in
  let has_no_initializer =
    is_missing cd_node.constant_declarator_initializer in
  is_concrete && has_no_initializer

(* Given a ConstDeclarator node, test whether it is abstract, but has an
   initializer. *)
let abstract_with_initializer cd_node parents =
  let is_abstract =
    match parents with
    | _ :: _ :: p3 :: _ when is_abstract_const p3 -> true
    | _ -> false
    in
  let has_initializer =
    not (is_missing cd_node.constant_declarator_initializer) in
  is_abstract && has_initializer

(* Tests if Property contains a modifier p *)
let property_modifier_contains_helper p node =
  match syntax node with
  | PropertyDeclaration syntax ->
    let node = syntax.property_modifiers in
    list_contains_predicate p node
  | _ -> false

(* Tests if parent class is both abstract and final *)
let abstract_final_parent_class parents =
  let parent = first_parent_classish_node TokenKind.Class parents in
    match parent with
    | None -> false
    | Some node -> (is_abstract_declaration node) && (is_final_declaration node)

(* Given a PropertyDeclaration node, tests whether parent class is abstract
  final but child variable is non-static *)
let abstract_final_with_inst_var cd parents =
  (abstract_final_parent_class parents) &&
    not (property_modifier_contains_helper is_static cd)

(* Given a MethodishDeclaration, tests whether parent class is abstract final
    but child method is non-static *)
let astract_final_with_method cd parents =
  (abstract_final_parent_class parents) && not (methodish_contains_static cd)

let methodish_errors node parents is_hack =
  match syntax node with
  (* TODO how to narrow the range of error *)
  | FunctionDeclarationHeader { function_parameter_list; function_type; _} ->
    let errors = [] in
    let errors =
      produce_error_for_header errors class_destructor_has_param node parents
      SyntaxError.error2011 function_parameter_list in
    let errors =
      produce_error_for_header errors
      class_constructor_destructor_has_non_void_type
      node parents SyntaxError.error2018 function_type in
    let errors =
      produce_error_for_header errors class_non_constructor_has_visibility_param
      node parents SyntaxError.error2010 function_parameter_list in
    errors
  | MethodishDeclaration md ->
    let header_node = md.methodish_function_decl_header in
    let modifiers = md.methodish_modifiers in
    let errors = [] in
    let errors =
      produce_error_for_header errors class_constructor_has_static header_node
      [node] SyntaxError.error2009 modifiers in
    let errors =
      let missing_modifier is_hack modifiers = is_hack && is_missing modifiers in
      produce_error errors (missing_modifier is_hack) modifiers
      SyntaxError.error2054 header_node in
    let errors =
      produce_error_for_header errors
      class_destructor_has_non_visibility_modifier header_node [node]
      SyntaxError.error2012 modifiers in
    let errors =
      produce_error errors methodish_multiple_visibility node
      SyntaxError.error2017 modifiers in
    let errors =
      produce_error errors methodish_duplicate_modifier node
      SyntaxError.error2013 modifiers in
    let fun_body = md.methodish_function_body in
    let errors =
      produce_error errors methodish_abstract_with_body node
      SyntaxError.error2014 fun_body in
    let fun_semicolon = md.methodish_semicolon in
    let errors =
      produce_error errors (methodish_non_abstract_without_body node) parents
      SyntaxError.error2015 fun_semicolon in
    let errors =
      produce_error errors methodish_abstract_conflict_with_private
      node SyntaxError.error2016 modifiers in
    let errors =
      produce_error errors methodish_abstract_conflict_with_final
      node SyntaxError.error2019 modifiers in
    let errors =
      produce_error errors (methodish_in_interface_has_body node) parents
      SyntaxError.error2041 md.methodish_function_body in
    let errors =
      let class_name = Option.value (first_parent_class_name parents)
        ~default:"" in
      let method_name = Option.value (extract_function_name
        md.methodish_function_decl_header) ~default:"" in
      (* default will never be used, since existence of abstract_keyword is a
       * necessary condition for the production of an error. *)
      let abstract_keyword = Option.value (extract_keyword is_abstract node)
        ~default:node in
      produce_error errors (abstract_method_in_nonabstract_class node) parents
      (SyntaxError.error2044 class_name method_name) abstract_keyword in
    let errors =
      let abstract_keyword = Option.value (extract_keyword is_abstract node)
        ~default:node in
      produce_error errors (abstract_method_in_interface node) parents
      SyntaxError.error2045 abstract_keyword in
    let errors =
      let async_annotation = Option.value (extract_async_node node)
        ~default:node in
      produce_error errors (is_abstract_and_async_method node) parents
      SyntaxError.error2046 async_annotation in
    let errors =
      let visibility_node = Option.value (extract_visibility_node modifiers)
        ~default:node in
      let visibility_text = PositionedSyntax.text visibility_node in (* is this option? *)
      produce_error errors (invalid_methodish_visibility_inside_interface node)
      parents (SyntaxError.error2047 visibility_text) visibility_node in
    errors
  | _ -> [ ]

let params_errors params =
  let errors =
    match ends_with_variadic_comma params with
    | None -> []
    | Some comma ->
      [ make_error_from_node comma SyntaxError.error2022 ]
  in
    match misplaced_variadic_param params with
    | None -> errors
    | Some param ->
      ( make_error_from_node param SyntaxError.error2021 ) :: errors

let parameter_errors node parents is_strict =
  match syntax node with
  | ParameterDeclaration { parameter_type; _}
    when is_strict && (is_missing parameter_type) &&
    (parameter_type_is_required parents) ->
      [ make_error_from_node node SyntaxError.error2001 ]
  | FunctionDeclarationHeader { function_parameter_list; _ } ->
    params_errors function_parameter_list
  | AnonymousFunction { anonymous_parameters; _ } ->
    params_errors anonymous_parameters
  | _ -> []


let missing_type_annot_check is_strict f =
  let label = f.function_name in
  let is_function = not (is_construct label) && not (is_destruct label) in
  is_strict && is_missing f.function_type && is_function

let function_reference_check is_strict f =
  is_strict && not (is_missing f.function_ampersand)

let function_errors node _parents is_strict =
  match syntax node with
  | FunctionDeclarationHeader f ->
    let errors = [] in
    let errors = produce_error errors (missing_type_annot_check is_strict) f
                 SyntaxError.error2001 f.function_right_paren in
    let errors = produce_error errors (function_reference_check is_strict) f
                 SyntaxError.error2064 f.function_ampersand in
    errors
  | _ -> [ ]

let statement_errors node parents =
  let result = match syntax node with
  | BreakStatement _
    when not (break_is_legal parents) ->
    Some (node, SyntaxError.error2005)
  | ContinueStatement _
    when not (continue_is_legal parents) ->
    Some (node, SyntaxError.error2006)
  | TryStatement { try_catch_clauses; try_finally_clause; _ }
    when (is_missing try_catch_clauses) && (is_missing try_finally_clause) ->
    Some (node, SyntaxError.error2007)
  | _ -> None in
  match result with
  | None -> [ ]
  | Some (error_node, error_message) ->
    [ make_error_from_node error_node error_message ]

let missing_property_check is_strict p = is_strict && is_missing (p.property_type)

let invalid_var_check is_hack p = is_hack && (is_var p.property_modifiers)

let property_errors node is_strict is_hack =
  match syntax node with
  | PropertyDeclaration p ->
      let errors = [] in
      let errors = produce_error errors (missing_property_check is_strict) p
                   SyntaxError.error2001 node in
      let errors = produce_error errors (invalid_var_check is_hack) p
                   SyntaxError.error2053 p.property_modifiers in
      errors
  | _ -> [ ]

let string_starts_with_int s =
  if String.length s = 0 then false else
  try let _ = int_of_string (String.make 1 s.[0]) in true with _ -> false

let invalid_shape_initializer_name node =
  match syntax node with
  | LiteralExpression { literal_expression = expr } ->
    let is_str =
      begin match token_kind expr with
      | Some TokenKind.SingleQuotedStringLiteral -> true
      (* TODO: Double quoted string are only legal
       * if they contain no encapsulated expressions. *)
      | Some TokenKind.DoubleQuotedStringLiteral -> true
      | _ -> false
      end
    in
    if not is_str
    then [make_error_from_node node SyntaxError.error2059] else begin
      let str = text expr in
      if string_starts_with_int str
      then [make_error_from_node node SyntaxError.error2060] else []
    end
  | QualifiedNameExpression _
  | ScopeResolutionExpression _ -> []
  | _ -> [make_error_from_node node SyntaxError.error2059]

let invalid_shape_field_check node =
  match syntax node with
  | FieldInitializer { field_initializer_name; _} ->
    invalid_shape_initializer_name field_initializer_name
  | _ -> [make_error_from_node node SyntaxError.error2059]

let expression_errors node parents is_hack =
  match syntax node with
  | SubscriptExpression { subscript_left_bracket; _}
    when is_left_brace subscript_left_bracket ->
    [ make_error_from_node node SyntaxError.error2020 ]
  | FunctionCallExpression { function_call_argument_list; _} ->
    begin match misplaced_variadic_arg function_call_argument_list with
      | Some h ->
        [ make_error_from_node h SyntaxError.error2033 ]
      | None -> [ ]
    end
  | ObjectCreationExpression oce when is_hack ->
    if is_missing oce.object_creation_left_paren &&
        is_missing oce.object_creation_right_paren
    then
      let start_node = oce.object_creation_new_keyword in
      let end_node = oce.object_creation_type in
      let constructor_name = PositionedSyntax.text oce.object_creation_type in
      [ make_error_from_nodes start_node end_node
        (SyntaxError.error2038 constructor_name)]
    else
      [ ]
  | ListExpression le
    when (is_invalid_list_expression node parents) ->
    [ make_error_from_node node SyntaxError.error2040 ]
  | ShapeExpression { shape_expression_fields; _} ->
    List.fold_right (fun fl acc -> (invalid_shape_field_check fl) @ acc)
      (syntax_to_list_no_separators shape_expression_fields) []
  | _ -> [ ] (* Other kinds of expressions currently produce no expr errors. *)

let require_errors node parents =
  match syntax node with
  | RequireClause p ->
    begin
      match (containing_classish_kind parents, token_kind p.require_kind) with
      | (Some TokenKind.Class, Some TokenKind.Extends) ->
        [ make_error_from_node node SyntaxError.error2029 ]
      | (Some TokenKind.Interface, Some TokenKind.Implements)
      | (Some TokenKind.Class, Some TokenKind.Implements) ->
        [ make_error_from_node node SyntaxError.error2030 ]
      | _ -> []
    end
  | _ -> [ ]

let classish_errors node parents =
  match syntax node with
  | ClassishDeclaration cd ->
    let errors = [] in
    let errors =
      produce_error errors classish_duplicate_modifiers cd.classish_modifiers
      SyntaxError.error2031 cd.classish_modifiers in
    let errors =
      produce_error errors classish_invalid_implements_keyword cd
      SyntaxError.error2035 cd.classish_implements_keyword in
    let errors =
      produce_error errors classish_invalid_extends_keyword cd
      SyntaxError.error2036 cd.classish_extends_keyword in
    let errors =
      produce_error errors classish_invalid_extends_list cd
      SyntaxError.error2037 cd.classish_extends_list in
    let errors =
      (* Extra setup for the the customized error message. *)
      let keyword_str = Option.value_map (token_kind cd.classish_keyword)
        ~default:"" ~f:TokenKind.to_string in
      let declared_name_str = PositionedSyntax.text cd.classish_name in
      let function_str = Option.value (first_parent_function_name parents)
        ~default:"" in
      (* To avoid iterating through the whole parents list again, do a simple
       * check on function_str rather than a harder one on cd or parents. *)
      produce_error errors (fun str -> String.length str != 0) function_str
      (SyntaxError.error2039 keyword_str declared_name_str function_str)
      cd.classish_keyword in
    let errors =
      (* default will never be used, since existence of abstract_keyword is a
       * necessary condition for the production of an error. *)
      let abstract_keyword = Option.value (extract_keyword is_abstract node)
        ~default:node in
      produce_error errors (is_classish_kind_declared_abstract TokenKind.Interface)
      node SyntaxError.error2042 abstract_keyword in
    let errors =
      (* default will never be used, since existence of abstract_keyword is a
       * necessary condition for the production of an error. *)
      let abstract_keyword = Option.value (extract_keyword is_abstract node)
        ~default:node in
      produce_error errors (is_classish_kind_declared_abstract TokenKind.Trait)
      node SyntaxError.error2043 abstract_keyword in
    errors
  | _ -> [ ]

let type_errors node parents is_strict =
  match syntax node with
  | SimpleTypeSpecifier t ->
    let acc = [ ] in
      produce_error acc (type_contains_array_in_strict is_strict)
      t.simple_type_specifier SyntaxError.error2032 t.simple_type_specifier
  | _ -> [ ]

let alias_errors node =
  match syntax node with
  | AliasDeclaration {alias_keyword; alias_constraint; _} when
    token_kind alias_keyword = Some TokenKind.Type &&
    not (is_missing alias_constraint) ->
      [ make_error_from_node alias_keyword SyntaxError.error2034 ]
  | _ -> [ ]

let is_invalid_group_use_clause clause =
  match syntax clause with
  | NamespaceUseClause { namespace_use_clause_kind = kind; _ } ->
    not (is_missing kind)
  | _ -> false

let is_invalid_group_use_prefix prefix =
  token_kind prefix <> Some TokenKind.NamespacePrefix

let group_use_errors node =
  match syntax node with
  | NamespaceGroupUseDeclaration
    { namespace_group_use_prefix = prefix
    ; namespace_group_use_clauses = clauses
    ; _} ->
      let invalid_clauses = List.filter is_invalid_group_use_clause
        (syntax_to_list_no_separators clauses) in
      let mapper clause = make_error_from_node clause SyntaxError.error2049 in
      let invalid_clause_errors = List.map mapper invalid_clauses in
      produce_error invalid_clause_errors is_invalid_group_use_prefix prefix
        SyntaxError.error2048 prefix
  | _ -> [ ]

let const_decl_errors node parents =
  match syntax node with
  | ConstantDeclarator cd ->
    let errors = [ ] in
    let errors =
      produce_error_parents errors concrete_no_initializer cd parents
      SyntaxError.error2050 cd.constant_declarator_initializer in
    let errors =
      produce_error_parents errors abstract_with_initializer cd parents
      SyntaxError.error2051 cd.constant_declarator_initializer in
    errors
  | _ -> [ ]

  let abstract_final_class_nonstatic_var_error node parents =
  match syntax node with
  | PropertyDeclaration cd ->
    let errors = [ ] in
      produce_error_parents errors abstract_final_with_inst_var node parents
      SyntaxError.error2061 cd.property_modifiers
  | _ -> [ ]

  let abstract_final_class_nonstatic_method_error node parents =
  match syntax node with
  | MethodishDeclaration cd ->
    let errors = [ ] in
      produce_error_parents errors astract_final_with_method node parents
      SyntaxError.error2062 cd.methodish_function_decl_header
  | _ -> [ ]

let mixed_namespace_errors node namespace_type =
  match syntax node with
  | NamespaceBody { namespace_left_brace; namespace_right_brace; _ } ->
    let s = start_offset namespace_left_brace in
    let e = end_offset namespace_right_brace in
    let errors =
      match namespace_type with
      | Unbracketed { start_offset; end_offset } ->
        let child = Some
          (SyntaxError.make start_offset end_offset SyntaxError.error2057) in
        [ SyntaxError.make ~child s e SyntaxError.error2052 ]
      | _ -> [ ] in
    let namespace_type =
      if namespace_type = Unspecified
      then Bracketed { start_offset = s; end_offset = e }
      else namespace_type
    in
    { errors; namespace_type }
  | NamespaceEmptyBody { namespace_semicolon; _ } ->
    let s = start_offset namespace_semicolon in
    let e = end_offset namespace_semicolon in
    let errors =
      match namespace_type with
      | Bracketed { start_offset; end_offset } ->
        let child = Some
          (SyntaxError.make start_offset end_offset SyntaxError.error2056) in
        [ SyntaxError.make ~child s e SyntaxError.error2052 ]
      | _ -> [ ] in
    let namespace_type =
      if namespace_type = Unspecified
      then Unbracketed { start_offset = s; end_offset = e }
      else namespace_type
    in
    { errors; namespace_type }
  | _ -> { errors = [ ]; namespace_type }

let find_syntax_errors syntax_tree =
  let is_strict = SyntaxTree.is_strict syntax_tree in
  let is_hack = (SyntaxTree.language syntax_tree = "hh") in
  let folder acc node parents =
    let param_errs = parameter_errors node parents is_strict in
    let func_errs = function_errors node parents is_strict in
    let xhp_errs = xhp_errors node parents in
    let statement_errs = statement_errors node parents in
    let methodish_errs = methodish_errors node parents is_hack in
    let property_errs = property_errors node is_strict is_hack in
    let expr_errs = expression_errors node parents is_hack in
    let require_errs = require_errors node parents in
    let classish_errors = classish_errors node parents in
    let type_errors = type_errors node parents is_strict in
    let alias_errors = alias_errors node in
    let group_use_errors = group_use_errors node in
    let const_decl_errors = const_decl_errors node parents in
    let abstract_final_class_nonstatic_var_error =
        abstract_final_class_nonstatic_var_error node parents in
    let abstract_final_class_nonstatic_method_error =
        abstract_final_class_nonstatic_method_error node parents in
    let mixed_namespace_acc =
      mixed_namespace_errors node acc.namespace_type in
    let errors = acc.errors @ param_errs @ func_errs @
      xhp_errs @ statement_errs @ methodish_errs @ property_errs @
      expr_errs @ require_errs @ classish_errors @ type_errors @ alias_errors @
      group_use_errors @ const_decl_errors @
      abstract_final_class_nonstatic_var_error @
      abstract_final_class_nonstatic_method_error @
      mixed_namespace_acc.errors in
    { errors; namespace_type = mixed_namespace_acc.namespace_type } in
  let node = PositionedSyntax.from_tree syntax_tree in
  let acc = SyntaxUtilities.parented_fold_pre folder
    { errors = []; namespace_type = Unspecified } node in
  acc.errors

type error_level = Minimum | Typical | Maximum

let parse_errors ?(level=Typical) syntax_tree =
  (*
  Minimum: suppress cascading errors; no second-pass errors if there are
  any first-pass errors.
  Typical: suppress cascading errors; give second pass errors always.
  Maximum: all errors
  *)
  let errors1 = match level with
  | Maximum -> SyntaxTree.all_errors syntax_tree
  | _ -> SyntaxTree.errors syntax_tree in
  let errors2 =
    if level = Minimum && errors1 <> [] then []
    else find_syntax_errors syntax_tree in
  List.sort SyntaxError.compare (errors1 @ errors2)
