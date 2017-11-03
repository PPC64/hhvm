(**
 * Copyright (c) 2017, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Hh_core
open Ast
open Ast_scope

module ULS = Unique_list_string
module SN = Naming_special_names
module SU = Hhbc_string_utils

let constant_folding () =
  Hhbc_options.constant_folding !Hhbc_options.compiler_options

type variables = {
  (* all variables declared/used in the scope*)
  all_vars: SSet.t;
  (* names of parameters if scope correspond to a function *)
  parameter_names: SSet.t
}

type env = {
  (* What is the current context? *)
  scope : Scope.t;
  variable_scopes: variables list;
  (* How many existing classes are there? *)
  defined_class_count : int;
  (* How many existing functions are there? *)
  defined_function_count : int;
}

type state = {
  (* Number of closures created in the current function *)
  per_function_count : int;
  (* Free variables computed so far *)
  captured_vars : ULS.t;
  captured_this : bool;
  (* Total number of closures created *)
  total_count : int;
  (* Closure classes and hoisted inline classes *)
  hoisted_classes : class_ list;
  (* Hoisted inline functions *)
  hoisted_functions : fun_ list;
  (* The current namespace environment *)
  namespace: Namespace_env.env;
  (* Static variables in closures have special properties with mangled names
   * defined for them *)
  static_vars : ULS.t;
  (* Set of closure names that used to have explicit 'use' language construct
    in original anonymous function *)
  explicit_use_set: SSet.t;
  (* Closures get converted into methods on a class. We need to keep
     track of the original namsepace of the closure in order to
     properly qualify things when that method's body is emitted. *)
  closure_namespaces : Namespace_env.env SMap.t;
  (* original enclosing class for closure *)
  closure_enclosing_classes: Ast.class_ SMap.t
}

let initial_state =
{
  per_function_count = 0;
  captured_vars = ULS.empty;
  captured_this = false;
  total_count = 0;
  hoisted_classes = [];
  hoisted_functions = [];
  namespace = Namespace_env.empty_with_default_popt;
  static_vars = ULS.empty;
  explicit_use_set = SSet.empty;
  closure_namespaces = SMap.empty;
  closure_enclosing_classes = SMap.empty;
}

let is_in_lambda scope =
  match scope with
  | ScopeItem.Lambda | ScopeItem.LongLambda _ -> true
  | _ -> false

let should_capture_var env var =
  let rec aux scope vars =
    match scope, vars with
    | [], [{ all_vars; _ }] -> SSet.mem var all_vars
    | x :: xs, { all_vars; parameter_names; }::vs ->
      SSet.mem var all_vars ||
      SSet.mem var parameter_names ||
      (is_in_lambda x && aux xs vs)
    | _ -> false in
  match env.scope, env.variable_scopes with
  | _ :: xs, { parameter_names; _ } :: vs ->
    (* variable used in lambda should be captured if is
    - not contained in lambda parameter list
    AND
    - it exists in one of enclosing scopes *)
    not (SSet.mem var parameter_names) && aux xs vs
  | _ ->
    false

(* Add a variable to the captured variables *)
let add_var env st var =
  (* Don't bother if it's $this, as this is captured implicitly *)
  if var = Naming_special_names.SpecialIdents.this
  then { st with captured_this = true; }
  (* If it's bound as a parameter or definite assignment, don't add it *)
  (* Also don't add the pipe variable and superglobals *)
  else if not (should_capture_var env var)
  || var = Naming_special_names.SpecialIdents.dollardollar
  || Naming_special_names.Superglobals.is_superglobal var
  then st
  else { st with captured_vars = ULS.add st.captured_vars var }

let get_vars scope ~is_closure_body params body =
  let has_this = Scope.has_this scope in
  let is_toplevel = Scope.is_toplevel scope in
  let is_in_static_method = Scope.is_in_static_method scope in
  Decl_vars.vars_from_ast
    ~is_closure_body ~has_this ~params ~is_toplevel ~is_in_static_method body

let wrap_block b = [Ast.Stmt (Ast.Block b)]

let get_parameter_names params =
  List.fold_left
    ~init:SSet.empty
    ~f:(fun s p -> SSet.add (snd p.Ast.param_id) s)
    params

let env_with_function_like_ env e ~is_closure_body params body =
  let scope = e :: env.scope in
  let all_vars =
    (get_vars scope
      ~is_closure_body
      params
      (wrap_block body)) in
  let parameter_names = get_parameter_names params in
  { env with
      scope;
      variable_scopes = { all_vars; parameter_names } :: env.variable_scopes }

let env_with_function_like env e ~is_closure_body fd =
  env_with_function_like_ env e ~is_closure_body fd.Ast.f_params fd.Ast.f_body

let env_with_lambda env fd =
  env_with_function_like env ScopeItem.Lambda ~is_closure_body:true fd

let env_with_longlambda env is_static fd =
  env_with_function_like env (ScopeItem.LongLambda is_static) ~is_closure_body:true fd

let strip_id id = SU.strip_global_ns (snd id)

let rec make_scope_name ns scope =
  match scope with
  | [] ->
    begin match ns.Namespace_env.ns_name with
    | None -> ""
    | Some n -> n ^ "\\"
    end
  | ScopeItem.Function fd :: _ -> strip_id fd.f_name
  | ScopeItem.Method md :: scope ->
    make_scope_name ns scope ^ "::" ^ strip_id md.m_name
  | ScopeItem.Class cd :: _ ->
    SU.Xhp.mangle_id (strip_id cd.c_name)
  | _ :: scope -> make_scope_name ns scope

let env_with_function env fd =
  env_with_function_like env (ScopeItem.Function fd) ~is_closure_body:false fd

let env_toplevel class_count function_count defs =
  let scope = Scope.toplevel in
  let all_vars =
    get_vars scope
      ~is_closure_body:false
      []
      defs in
  { scope = scope;
    variable_scopes = [{ all_vars; parameter_names = SSet.empty }];
    defined_class_count = class_count;
    defined_function_count = function_count; }

let env_with_method env md =
  env_with_function_like_
    env
    (ScopeItem.Method md)
    ~is_closure_body:false
    md.Ast.m_params
    md.Ast.m_body

let env_with_class env cd =
  { env with
      scope = [ScopeItem.Class cd];
      variable_scopes = env.variable_scopes; }

(* Clear the variables, upon entering a lambda *)
let enter_lambda st =
  { st with
    captured_vars = ULS.empty;
    captured_this = false;
    static_vars = ULS.empty;
   }

let add_static_var st var =
  { st with static_vars = ULS.add st.static_vars var }

let set_namespace st ns =
  { st with namespace = ns }

let reset_function_count st =
  { st with per_function_count = 0; }

let add_function env st fd =
  let n = env.defined_function_count + List.length st.hoisted_functions in
  { st with hoisted_functions = fd :: st.hoisted_functions },
  { fd with f_body = []; f_name = (fst fd.f_name, string_of_int n) }

(* Make a stub class purely for the purpose of emitting the DefCls instruction
 *)
let make_defcls cd n =
{ cd with
  c_body = [];
  c_name = (fst cd.c_name, string_of_int n) }

let add_class env st cd =
  let n = env.defined_class_count + List.length st.hoisted_classes in
  { st with hoisted_classes = cd :: st.hoisted_classes },
  make_defcls cd n

let make_closure_name total_count env st =
  SU.Closures.mangle_closure
    (make_scope_name st.namespace env.scope) st.per_function_count total_count

let make_closure ~class_num
  p total_count env st lambda_vars tparams fd body =
  let rec is_scope_static scope =
    match scope with
    | ScopeItem.LongLambda is_static :: scope ->
      is_static || is_scope_static scope
    | ScopeItem.Function _ :: _ -> false
    | ScopeItem.Method md :: _ ->
      List.mem md.m_kind Static
    | ScopeItem.Lambda :: scope ->
      not st.captured_this || is_scope_static scope
    | _ -> false in
  let is_static = fd.f_static || is_scope_static env.scope in
  let md = {
    m_kind = [Public] @ (if is_static then [Static] else []);
    m_tparams = fd.f_tparams;
    m_constrs = [];
    m_name = (fst fd.f_name, "__invoke");
    m_params = fd.f_params;
    m_body = body;
    m_user_attributes = fd.f_user_attributes;
    m_ret = fd.f_ret;
    m_ret_by_ref = fd.f_ret_by_ref;
    m_fun_kind = fd.f_fun_kind;
    m_span = fd.f_span;
    m_doc_comment = fd.f_doc_comment;
  } in
  let cvl =
    List.map lambda_vars
    (fun name -> (p, (p, Hhbc_string_utils.Locals.strip_dollar name), None)) in
  let cvl = cvl @ (List.map (ULS.items st.static_vars)
    (fun name -> (p, (p,
     "86static_" ^ (Hhbc_string_utils.Locals.strip_dollar name)), None))) in
  let cd = {
    c_mode = fd.f_mode;
    c_user_attributes = [];
    c_final = false;
    c_kind = Cnormal;
    c_is_xhp = false;
    c_name = (p, make_closure_name total_count env st);
    c_tparams = tparams;
    c_extends = [(p, Happly((p, "Closure"), []))];
    c_implements = [];
    c_body = [ClassVars ([Private], None, cvl, None); Method md];
    c_namespace = Namespace_env.empty_with_default_popt;
    c_enum = None;
    c_span = p;
    c_doc_comment = None;
  } in
  let inline_fundef =
    { fd with f_body = body;
              f_static = is_static;
              f_name = (p, string_of_int class_num) } in
  inline_fundef, cd

let inline_class_name_if_possible env ~trait ~fallback_to_empty_string p pe =
  let get_class_call =
    p, Call ((pe, Id (pe, "get_class")), [], [], [])
  in
  let name c = p, String (pe, SU.Xhp.mangle @@ strip_id c.c_name) in
  let empty_str = p, String (pe, "") in
  match Scope.get_class env.scope with
  | Some c when trait ->
    if c.c_kind = Ctrait then name c else empty_str
  | Some c ->
    if c.c_kind = Ctrait then get_class_call else name c
  | None ->
    if fallback_to_empty_string then p, String (pe, "")
    else get_class_call

(* Translate special identifiers __CLASS__, __METHOD__ and __FUNCTION__ into
 * literal strings. It's necessary to do this before closure conversion
 * because the enclosing class will be changed. *)
let convert_id (env:env) p (pid, str as id) =
  let str = String.uppercase_ascii str in
  let return newstr = (p, String (pid, newstr)) in
  match str with
  | "__CLASS__" | "__TRAIT__"->
    inline_class_name_if_possible
      ~trait:(str = "__TRAIT__")
      ~fallback_to_empty_string:true
      env p pid
  | "__METHOD__" ->
    let prefix =
      match Scope.get_class env.scope with
      | None -> ""
      | Some cd -> strip_id cd.c_name ^ "::" in
    begin match env.scope with
      | ScopeItem.Function fd :: _ -> return (prefix ^ strip_id fd.f_name)
      | ScopeItem.Method md :: _ -> return (prefix ^ strip_id md.m_name)
      | (ScopeItem.Lambda | ScopeItem.LongLambda _) :: _ ->
        return (prefix ^ "{closure}")
      (* PHP weirdness: __METHOD__ inside a class outside a method
       * returns class name *)
      | ScopeItem.Class cd :: _ -> return @@ strip_id cd.c_name
      | _ -> return ""
    end
  | "__FUNCTION__" ->
    begin match env.scope with
    | ScopeItem.Function fd :: _ -> return (strip_id fd.f_name)
    | ScopeItem.Method md :: _ -> return (strip_id md.m_name)
    | (ScopeItem.Lambda | ScopeItem.LongLambda _) :: _ -> return "{closure}"
    | _ -> return ""
    end
  | "__LINE__" ->
    (* If the expression goes on multi lines, we return the last line *)
    let _, line, _, _ = Pos.info_pos_extended pid in
    p, Int (pid, string_of_int line)
  | _ ->
    (p, Id id)

let check_if_in_async_context { scope; _ } =
  let p = Pos.none in
  let check_valid_fun_kind (_, name) =
    function | FAsync | FAsyncGenerator -> ()
             | _ -> Emit_fatal.raise_fatal_parse p @@
    "Function '"
    ^ (SU.strip_global_ns name)
    ^ "' contains 'await' but is not declared as async."
  in
  match scope with
  | [] -> Emit_fatal.raise_fatal_parse p
            "'await' can only be used inside a function"
  | ScopeItem.Lambda :: _
  | ScopeItem.LongLambda _ :: _ ->
   (* TODO: In a lambda, we dont see whether there is a
    * async keyword in front or not >.> so assume this is fine, for now. *)
    ()
  | ScopeItem.Class _ :: _ -> () (* Syntax error, wont get here *)
  | ScopeItem.Function fd :: _ ->
    check_valid_fun_kind fd.f_name fd.f_fun_kind
  | ScopeItem.Method md :: _ ->
    check_valid_fun_kind md.m_name md.m_fun_kind

let rec convert_expr env st (p, expr_ as expr) =
  match expr_ with
  | Varray es ->
    let st, es = List.map_env st es (convert_expr env) in
    st, (p, Varray es)
  | Darray es ->
    let convert_pair st (e1, e2) = begin
      let st, e1 = convert_expr env st e1 in
      let st, e2 = convert_expr env st e2 in
      st, (e1, e2)
    end in
    let st, es =  List.map_env st es convert_pair in
    st, (p, Darray es)
  | Array afl ->
    let st, afl = List.map_env st afl (convert_afield env) in
    st, (p, Array afl)
  | Shape pairs ->
    let st, pairs = List.map_env st pairs (fun st (n, e) ->
      let st, e = convert_expr env st e in
      st, (n, e)) in
    st, (p, Shape pairs)
  | Collection (id, afl) ->
    let st, afl = List.map_env st afl (convert_afield env) in
    st, (p, Collection (id, afl))
  | Lvar id ->
    let st = add_var env st (snd id) in
    st, (p, Lvar id)
  | Clone e ->
    let st, e = convert_expr env st e in
    st, (p, Clone e)
  | Obj_get (e1, e2, flavor) ->
    let st, e1 = convert_expr env st e1 in
    let st, e2 = convert_expr env st e2 in
    st, (p, Obj_get (e1, e2, flavor))
  | Array_get(e1, opt_e2) ->
    let st, e1 = convert_expr env st e1 in
    let st, opt_e2 = convert_opt_expr env st opt_e2 in
    st, (p, Array_get (e1, opt_e2))
  | Call ((_, Id (pe, "get_class")), _, [], []) ->
    st, inline_class_name_if_possible
      ~trait:false
      ~fallback_to_empty_string:false
      env p pe
  | Call ((_, (Class_const ((_, Id (_, cid)), _) | Class_get ((_, Id (_, cid)), _))) as e,
    el1, el2, el3)
  when cid = "parent" ->
    let st = add_var env st "$this" in
    let st, e = convert_expr env st e in
    let st, el2 = convert_exprs env st el2 in
    let st, el3 = convert_exprs env st el3 in
    st, (p, Call(e, el1, el2, el3))
  | Call (e, el1, el2, el3) ->
    let st, e = convert_expr env st e in
    let st, el2 = convert_exprs env st el2 in
    let st, el3 = convert_exprs env st el3 in
    st, (p, Call(e, el1, el2, el3))
  | String2 el ->
    let st, el = convert_exprs env st el in
    st, (p, String2 el)
  | Yield af ->
    let st, af = convert_afield env st af in
    st, (p, Yield af)
  | Await e ->
    check_if_in_async_context env;
    let st, e = convert_expr env st e in
    st, (p, Await e)
  | List el ->
    let st, el = convert_exprs env st el in
    st, (p, List el)
  | Expr_list el ->
    let st, el = convert_exprs env st el in
    st, (p, Expr_list el)
  | Cast (h, e) ->
    let st, e = convert_expr env st e in
    st, (p, Cast (h, e))
  | Unop (op, e) ->
    let st, e = convert_expr env st e in
    st, (p, Unop (op, e))
  | Binop (op, e1, e2) ->
    let st, e1 = convert_expr env st e1 in
    let st, e2 = convert_expr env st e2 in
    st, (p, Binop (op, e1, e2))
  | Pipe (e1, e2) ->
    let st, e1 = convert_expr env st e1 in
    let st, e2 = convert_expr env st e2 in
    st, (p, Pipe (e1, e2))
  | Eif (e1, opt_e2, e3) ->
    let st, e1 = convert_expr env st e1 in
    let st, opt_e2 = convert_opt_expr env st opt_e2 in
    let st, e3 = convert_expr env st e3 in
    st, (p, Eif(e1, opt_e2, e3))
  | NullCoalesce (e1, e2) ->
    let st, e1 = convert_expr env st e1 in
    let st, e2 = convert_expr env st e2 in
    st, (p, NullCoalesce (e1, e2))
  | InstanceOf (e1, e2) ->
    let st, e1 = convert_expr env st e1 in
    let st, e2 = convert_expr env st e2 in
    st, (p, InstanceOf (e1, e2))
  | New (e, el1, el2) ->
    let st, e = convert_expr env st e in
    let st, el1 = convert_exprs env st el1 in
    let st, el2 = convert_exprs env st el2 in
    st, (p, New(e, el1, el2))
  | Efun (fd, use_vars) ->
    convert_lambda env st p fd (Some use_vars)
  | Lfun fd ->
    convert_lambda env st p fd None
  | Xml(id, pairs, el) ->
    let st, pairs = List.map_env st pairs
      (fun st (id, e) ->
        let st, e = convert_expr env st e in
        st, (id, e)) in
    let st, el = convert_exprs env st el in
    st, (p, Xml(id, pairs, el))
  | Unsafeexpr e ->
    (* remove unsafe expressions from the AST, they are not used during codegen *)
    convert_expr env st e
  | BracedExpr e ->
    let st, e = convert_expr env st e in
    st, (p, BracedExpr e)
  | Import(flavor, e) ->
    let st, e = convert_expr env st e in
    st, (p, Import(flavor, e))
  | Id (_, id) as ast_id when String_utils.string_starts_with id "$" ->
    let st = add_var env st id in
    st, (p, ast_id)
  | Id id ->
    st, convert_id env p id
  | Class_get (cid, n) ->
    let st, e = convert_expr env st cid in
    let st, n = convert_expr env st n in
    st, (p, Class_get (e, n))
  | Class_const (cid, n) ->
    let st, e = convert_expr env st cid in
    st, (p, Class_const (e, n))
  | _ ->
    st, expr

(* Closure-convert a lambda expression, with use_vars_opt = Some vars
 * if there is an explicit `use` clause.
 *)
and convert_lambda env st p fd use_vars_opt =
  (* Remember the current capture and defined set across the lambda *)
  let captured_vars = st.captured_vars in
  let captured_this = st.captured_this in
  let total_count = st.total_count in
  let static_vars = st.static_vars in
  let st = { st with total_count = total_count + 1; } in
  let st = enter_lambda st in
  let old_env = env in
  Option.iter use_vars_opt
    ~f:(List.iter ~f:(fun ((p, id), _) ->
      if id = SN.SpecialIdents.this
      then Emit_fatal.raise_fatal_parse p "Cannot use $this as lexical variable"));
  let env = if Option.is_some use_vars_opt
            then env_with_longlambda env false fd
            else env_with_lambda env fd in
  let st, block = convert_block env st fd.f_body in
  let st = { st with per_function_count = st.per_function_count + 1 } in
  (* HHVM lists lambda vars in descending order - do the same *)
  let lambda_vars = List.sort ~cmp:(fun a b -> compare b a) @@ ULS.items st.captured_vars in
  (* For lambdas without explicit `use` variables, we ignore the computed
   * capture set and instead use the explicit set *)
  let lambda_vars, use_vars =
    match use_vars_opt with
    | None ->
      lambda_vars, List.map lambda_vars (fun var -> (p, var), false)
    | Some use_vars ->
      (* Remove duplicates (not efficient, but unlikely to be large),
       * remove variables that are actually just parameters *)
      let use_vars =
         (List.fold_right use_vars ~init:[]
          ~f:(fun ((_, name), _ as use_var) use_vars ->
            if List.exists use_vars (fun ((_, name'), _) -> name = name')
            || List.exists fd.f_params (fun p -> name = snd p.param_id)
            then use_vars else use_var :: use_vars))
      in
        List.map use_vars (fun ((_, var), _ref) -> var), use_vars in
  let tparams = Scope.get_tparams env.scope in
  let class_num = List.length st.hoisted_classes + env.defined_class_count in
  let inline_fundef, cd =
      make_closure
      ~class_num
      p total_count env st lambda_vars tparams fd block in
  let explicit_use_set =
    if Option.is_some use_vars_opt
    then SSet.add (snd inline_fundef.f_name) st.explicit_use_set
    else st.explicit_use_set in

  let closure_class_name = snd cd.c_name in

  let closure_enclosing_classes =
    match Scope.get_class env.scope with
    | Some cd -> SMap.add closure_class_name cd st.closure_enclosing_classes
    | None -> st.closure_enclosing_classes in

  (* Restore capture and defined set *)
  let st = { st with captured_vars = captured_vars;
                     captured_this = captured_this || st.captured_this;
                     static_vars = static_vars;
                     explicit_use_set;
                     closure_enclosing_classes;
                     closure_namespaces = SMap.add
                       closure_class_name st.namespace st.closure_namespaces;
           } in
  let env = old_env in
  (* Add lambda captured vars to current captured vars *)
  let st = List.fold_left lambda_vars ~init:st ~f:(add_var env) in
  let st = { st with hoisted_classes = cd :: st.hoisted_classes } in
  st, (p, Efun (inline_fundef, use_vars))

and convert_exprs env st el =
  List.map_env st el (convert_expr env)

and convert_opt_expr env st oe =
  match oe with
  | None -> st, None
  | Some e ->
    let st, e = convert_expr env st e in
    st, Some e

and convert_stmt env st stmt =
  match stmt with
  | Expr e ->
    let st, e = convert_expr env st e in
    st, Expr e
  | Block b ->
    let st, b = convert_block env st b in
    st, Block b
  | Throw e ->
    let st, e = convert_expr env st e in
    st, Throw e
  | Return (p, opt_e) ->
    let st, opt_e = convert_opt_expr env st opt_e in
    st, Return (p, opt_e)
  | Static_var el ->
    let visit_static_var st e =
      begin match snd e with
      | Lvar (_, name)
      | Binop (Eq None, (_, Lvar (_, name)), _) -> add_static_var st name
      | _ -> failwith "Static var - impossible"
      end in
    let st = List.fold_left el ~init:st ~f:visit_static_var in
    let st, el = convert_exprs env st el in
    st, Static_var el
  | If (e, b1, b2) ->
    let st, e = convert_expr env st e in
    let st, b1 = convert_block env st b1 in
    let st, b2 = convert_block env st b2 in
    st, If(e, b1, b2)
  | Do (b, e) ->
    let st, b = convert_block env st b in
    let st, e = convert_expr env st e in
    st, Do (b, e)
  | While (e, b) ->
    let st, e = convert_expr env st e in
    let st, b = convert_block env st b in
    st, While (e, b)
  | For (e1, e2, e3, b) ->
    let st, e1 = convert_expr env st e1 in
    let st, e2 = convert_expr env st e2 in
    let st, e3 = convert_expr env st e3 in
    let st, b = convert_block env st b in
    st, For(e1, e2, e3, b)
  | Switch (e, cl) ->
    let st, e = convert_expr env st e in
    let st, cl = List.map_env st cl (convert_case env) in
    st, Switch (e, cl)
  | Foreach (e, p, ae, b) ->
    if p <> None then check_if_in_async_context env;
    let st, e = convert_expr env st e in
    let st, ae = convert_as_expr env st ae in
    let st, b = convert_block env st b in
    st, Foreach (e, p, ae, b)
  | Try (b1, cl, b2) ->
    let st, b1 = convert_block env st b1 in
    let st, cl = List.map_env st cl (convert_catch env) in
    let st, b2 = convert_block env st b2 in
    st, Try (b1, cl, b2)
  | Using (has_await, e, b) ->
    if has_await then check_if_in_async_context env;
    let st, e = convert_expr env st e in
    let st, b = convert_block env st b in
    st, Using (has_await, e, b)
  | Def_inline ((Class _) as d) ->
    let cd =
      (* propagate namespace information to nested classes *)
      match Namespaces.elaborate_def st.namespace d with
      | _, [Class cd] -> cd
      | _ -> failwith "expected single class declaration" in
    let st, cd = convert_class env st cd in
    let st, stub_cd = add_class env st cd in
    st, Def_inline (Class stub_cd)
  | Def_inline ((Fun _) as d) ->
    let fd =
      (* propagate namespace information to nested functions *)
      match Namespaces.elaborate_def st.namespace d with
      | _, [Fun fd] -> fd
      | _ -> failwith "expected single function declaration" in
    let st, fd = convert_fun env st fd in
    let st, stub_fd = add_function env st fd in
    st, Def_inline (Fun stub_fd)
  | _ ->
    st, stmt

and convert_block env st stmts =
  List.map_env st stmts (convert_stmt env)

and convert_catch env st (id1, id2, b) =
  let st, b = convert_block env st b in
  st, (id1, id2, b)

and convert_case env st case =
  match case with
  | Default b ->
    let st, b = convert_block env st b in
    st, Default b
  | Case (e, b) ->
    let st, e = convert_expr env st e in
    let st, b = convert_block env st b in
    st, Case (e, b)

and convert_lvalue_expr env st (p, expr_ as expr) =
  match expr_ with
  | Lvar _ ->
    st, expr
  | List exprs ->
    let st, exprs = List.map_env st exprs (convert_lvalue_expr env) in
    st, (p, List exprs)
  | _ ->
    convert_expr env st expr

(* Everything here is an l-value *)
and convert_as_expr env st aexpr =
  match aexpr with
  | As_v e ->
    let st, e = convert_lvalue_expr env st e in
    st, As_v e
  | As_kv (e1, e2) ->
    let st, e1 = convert_lvalue_expr env st e1 in
    let st, e2 = convert_lvalue_expr env st e2 in
    st, As_kv (e1, e2)

and convert_afield env st afield =
  match afield with
  | AFvalue e ->
    let st, e = convert_expr env st e in
    st, AFvalue e
  | AFkvalue (e1, e2) ->
    let st, e1 = convert_expr env st e1 in
    let st, e2 = convert_expr env st e2 in
    st, AFkvalue (e1, e2)

and convert_params env st param_list =
  let convert_param env st param = match param.param_expr with
    | None -> st, param
    | Some e ->
      let st, e = convert_expr env st e in
      st, { param with param_expr = Some e }
  in
  List.map_env st param_list (convert_param env)

and convert_fun env st fd =
  let env = env_with_function env fd in
  let st = reset_function_count st in
  let st, block = convert_block env st fd.f_body in
  let st, params = convert_params env st fd.f_params in
  st, { fd with f_body = block; f_params = params }

and convert_class env st cd =
  let env = env_with_class env cd in
  let st = reset_function_count st in
  let st, c_body = List.map_env st cd.c_body (convert_class_elt env) in
  st, { cd with c_body = c_body }

and convert_class_var env st (pos, id, expr_opt) =
  match expr_opt with
  | None ->
    st, (pos, id, expr_opt)
  | Some expr ->
    let st, expr = convert_expr env st expr in
    st, (pos, id, Some expr)

and convert_class_const env st (id, expr) =
  let st, expr = convert_expr env st expr in
  st, (id, expr)

and convert_class_elt env st ce =
  match ce with
  | Method md ->
    let env = env_with_method env md in
    let st = reset_function_count st in
    let st, block = convert_block env st md.m_body in
    let st, params = convert_params env st md.m_params in
    st, Method { md with m_body = block; m_params = params }

  | ClassVars (kinds, hint, cvl, doc_comment_opt) ->
    let st, cvl = List.map_env st cvl (convert_class_var env) in
    st, ClassVars (kinds, hint, cvl, doc_comment_opt)

  | Const (ho, iel) ->
    let st, iel = List.map_env st iel (convert_class_const env) in
    st, Const (ho, iel)

  | XhpAttr (h, c, v, es) ->
    let st, c = convert_class_var env st c in
    let st, es =
      match es with
      | None -> st, es
      | Some (p, es) ->
        let st, es = convert_exprs env st es in
        st, Some (p, es) in
    st, XhpAttr (h, c, v, es)
  | _ ->
    st, ce

and convert_gconst env st gconst =
  let st, expr = convert_expr env st gconst.Ast.cst_value in
  st, { gconst with Ast.cst_value = expr }

and convert_defs env class_count typedef_count st dl =
  match dl with
  | [] -> st, []
  | Fun fd :: dl ->
    let st, fd = convert_fun env st fd in
    let st, dl = convert_defs env class_count typedef_count st dl in
    st, (true, Fun fd) :: dl
    (* Convert a top-level class definition into a true class definition and
     * a stub class that just corresponds to the DefCls instruction *)
  | Class cd :: dl ->
    let st, cd = convert_class env st cd in
    let stub_class = make_defcls cd class_count in
    let st, dl = convert_defs env (class_count + 1) typedef_count st dl in
    st, (true, Class cd) :: (true, Stmt (Def_inline (Class stub_class))) :: dl
  | Stmt stmt :: dl ->
    let st, stmt = convert_stmt env st stmt in
    let st, dl = convert_defs env class_count typedef_count st dl in
    st, (true, Stmt stmt) :: dl
  | Typedef td :: dl ->
    let st, dl = convert_defs env class_count (typedef_count + 1) st dl in
    let stub_td = { td with t_id =
      (fst td.t_id, string_of_int (typedef_count)) } in
    st, (true, Typedef td) :: (true, Stmt (Def_inline (Typedef stub_td))) :: dl
  | Constant c :: dl ->
    let st, c = convert_gconst env st c in
    let st, dl = convert_defs env class_count typedef_count st dl in
    st, (true, Constant c) :: dl
  | Namespace(_id, dl) :: dl' ->
    convert_defs env class_count typedef_count st (dl @ dl')
  | NamespaceUse x :: dl ->
    let st, dl = convert_defs env class_count typedef_count st dl in
    st, (true, NamespaceUse x) :: dl
  | SetNamespaceEnv ns :: dl ->
    let st = set_namespace st ns in
    let st, dl = convert_defs env class_count typedef_count st dl in
    st, (true, SetNamespaceEnv ns) :: dl

let count_classes defs =
  List.count defs ~f:(function Class _ -> true | _ -> false)

let hoist_toplevel_functions all_defs =
  let funs, nonfuns =
    List.partition_tf all_defs ~f:(function _, Fun _ -> true | _ -> false) in
  funs @ nonfuns

(* For all the definitions in a file unit, convert lambdas into classes with
 * invoke methods, and hoist inline class and function definitions to top
 * level.
 * The closure classes and hoisted definitions are placed after the existing
 * definitions.
 *)
let convert_toplevel_prog defs =
  let defs =
    if constant_folding ()
    then Ast_constant_folder.fold_program defs else defs in
  (* First compute the number of explicit classes in order to generate correct
   * integer identifiers for the generated classes. .main counts as a top-level
   * function and we place hoisted functions just after that *)
  let env = env_toplevel (count_classes defs) 1 defs in
  let st, original_defs = convert_defs env 0 0 initial_state defs in
  (* Reorder the functions so that they appear first. This matches the
   * behaviour of HHVM. *)
  let original_defs = hoist_toplevel_functions original_defs in
  let fun_defs = List.rev_map st.hoisted_functions (fun fd -> false, Fun fd) in
  let class_defs = List.rev_map st.hoisted_classes (fun cd -> false, Class cd) in
  (fun_defs @ original_defs @ class_defs,
    Emit_env.(
      { global_explicit_use_set = st.explicit_use_set
      ; global_closure_namespaces = st.closure_namespaces
      ; global_closure_enclosing_classes = st.closure_enclosing_classes})
  )
