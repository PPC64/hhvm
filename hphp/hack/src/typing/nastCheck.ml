(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)


(* This module performs checks after the naming has been done.
   Basically any check that doesn't fall in the typing category. *)
(* Check of type application arity *)
(* Check no `new AbstractClass` (or trait, or interface) *)
(* Check no top-level break / continue *)

(* NOTE: since the typing environment does not generally contain
   information about non-Hack code, some of these checks can
   only be done in strict (i.e. "everything is Hack") mode. Use
   `if Env.is_strict env.tenv` style checks accordingly.
*)


open Autocomplete
open Hh_core
open Nast
open String_utils
open Typing_defs
open Utils
open Typing_subtype

module Env = Typing_env
module Inst = Decl_instantiate
module Phase = Typing_phase
module SN = Naming_special_names
module TGenConstraint = Typing_generic_constraint
module Subst = Decl_subst
module TUtils = Typing_utils


type control_context =
  | Toplevel
  | LoopContext
  | SwitchContext

type env = {
  t_is_finally: bool;
  class_name: string option;
  class_kind: Ast.class_kind option;
  imm_ctrl_ctx: control_context;
  typedef_tparams : Nast.tparam list;
  tenv: Env.env;
}

let coroutines_enabled env =
  TypecheckerOptions.experimental_feature_enabled
    (Env.get_options env.tenv)
    TypecheckerOptions.experimental_coroutines

let report_coroutines_not_enabled p =
  Errors.experimental_feature p "coroutines"

let check_coroutines_enabled condition env p =
  if condition && not (coroutines_enabled env)
  then report_coroutines_not_enabled p

module CheckFunctionBody = struct
  let rec stmt f_type env st = match f_type, st with
    | Ast.FSync, Return (_, None)
    | Ast.FAsync, Return (_, None) -> ()
    | Ast.FSync, Return (_, Some e)
    | Ast.FAsync, Return (_, Some e) ->
        expr_allow_await f_type env e;
        ()
    | (Ast.FGenerator | Ast.FAsyncGenerator), Return (p, e) ->
        (match e with
        None -> ()
        | Some _ -> Errors.return_in_gen p);
        ()
    | Ast.FCoroutine, Return (_, e) ->
        Option.iter e ~f:(expr f_type env)
    | _, Throw (_, e) ->
        expr f_type env e
    | _, Expr e ->
        expr_allow_await f_type env e;
        ()
    | _, ( Noop | Fallthrough | GotoLabel _ | Goto _ | Break _ | Continue _
         | Static_var _ | Global_var _ ) -> ()
    | _, If (cond, b1, b2) ->
        expr f_type env cond;
        block f_type env b1;
        block f_type env b2;
        ()
    | _, Do (b, e) ->
        block f_type env b;
        expr f_type env e;
        ()
    | _, While (e, b) ->
        expr f_type env e;
        block f_type env b;
        ()
    | _, Using (_has_await, e, b) ->
        expr_allow_await_list f_type env e;
        block f_type env b;
        ()
    | _, For (init, cond, incr, b) ->
        expr f_type env init;
        expr f_type env cond;
        expr f_type env incr;
        block f_type env b;
        ()
    | _, Switch (e, cl) ->
        expr f_type env e;
        List.iter cl (case f_type env);
        ()
    | Ast.FCoroutine, Foreach (_, (Await_as_v (p, _) | Await_as_kv (p, _, _)), _) ->
        Errors.await_in_coroutine p;

    | (Ast.FSync | Ast.FGenerator), Foreach (_, (Await_as_v (p, _) | Await_as_kv (p, _, _)), _) ->
        Errors.await_in_sync_function p;
        ()
    | _, Foreach (v, _, b) ->
        expr f_type env v;
        block f_type env b;
        ()
    | _, Try (b, cl, fb) ->
        block f_type env b;
        List.iter cl (catch f_type env);
        block f_type { env with t_is_finally = true } fb;
        ()

  and block f_type env stl =
    List.iter stl (stmt f_type env)

  and case f_type env = function
    | Default b -> block f_type env b
    | Case (cond, b) ->
        expr f_type env cond;
        block f_type env b;
        ()

  and catch f_type env (_, _, b) = block f_type env b

  and afield f_type env = function
    | AFvalue e -> expr f_type env e
    | AFkvalue (e1, e2) -> expr2 f_type env (e1, e2)

  and expr f_type env (p, e) =
    expr_ p f_type env e

  and expr_allow_await_list f_type env ((_, exp) as e) =
    match exp with
    | Expr_list el ->
      List.iter el (expr_allow_await f_type env)
    | _ ->
      expr_allow_await f_type env e

  and expr_allow_await f_type env (p, exp) = match f_type, exp with
    | Ast.FAsync, Await e
    | Ast.FAsyncGenerator, Await e -> expr f_type env e; ()
    | Ast.FAsync, Binop (Ast.Eq None, e1, (_, Await e))
    | Ast.FAsyncGenerator, Binop (Ast.Eq None, e1, (_, Await e)) ->
      expr f_type env e1;
      expr f_type env e;
      ()
    | _ -> expr_ p f_type env exp; ()

  and expr2 f_type env (e1, e2) =
    expr f_type env e1;
    expr f_type env e2;
    ()

  and expr_ p f_type env exp = match f_type, exp with
    | _, Any -> ()
    | _, Fun_id _
    | _, Method_id _
    | _, Smethod_id _
    | _, Method_caller _
    | _, This
    | _, Id _
    | _, Class_get _
    | _, Class_const _
    | _, Typename _
    | _, Lvar _
    | _, Lvarvar _
    | _, Lplaceholder _
    | _, Dollardollar _ -> ()
    | _, Pipe (_, l, r) ->
        expr f_type env l;
        expr f_type env r;
    | _, Array afl ->
        List.iter afl (afield f_type env);
        ()
    | _, Darray afl ->
        List.iter afl (expr2 f_type env);
        ()
    | _, Varray afl ->
        List.iter afl (expr f_type env);
        ()
    | _, ValCollection (_, el) ->
        List.iter el (expr f_type env);
        ()
    | _, KeyValCollection (_, fdl) ->
        List.iter fdl (expr2 f_type env);
        ()
    | _, Clone e -> expr f_type env e; ()
    | _, Obj_get (e, (_, Id _s), _) ->
        expr f_type env e;
        ()
    | _, Obj_get (e1, e2, _) ->
        expr2 f_type env (e1, e2);
        ()
    | _, Array_get (e, eopt) ->
        expr f_type env e;
        maybe (expr f_type) env eopt;
        ()
    | _, Call (_, e, _, el, uel) ->
        expr f_type env e;
        List.iter el (expr f_type env);
        List.iter uel (expr f_type env);
        ()
    | _, True | _, False | _, Int _
    | _, Float _ | _, Null | _, String _ -> ()
    | _, String2 el ->
        List.iter el (expr f_type env);
        ()
    | _, List el ->
        List.iter el (expr f_type env);
        ()
    | _, Pair (e1, e2) ->
        expr2 f_type env (e1, e2);
        ()
    | _, Expr_list el ->
        List.iter el (expr f_type env);
        ()
    | _, Unop (_, e) -> expr f_type env e
    | _, Binop (_, e1, e2) ->
        expr2 f_type env (e1, e2);
        ()
    | _, Eif (e1, None, e3) ->
        expr2 f_type env (e1, e3);
        ()
    | _, Eif (e1, Some e2, e3) ->
        List.iter [e1; e2; e3] (expr f_type env);
        ()
    | _, NullCoalesce (e1, e2) ->
        List.iter [e1; e2] (expr f_type env);
        ()
    | _, New (_, el, uel) ->
      List.iter el (expr f_type env);
      List.iter uel (expr f_type env);
      ()
    | _, InstanceOf (e, _) ->
        expr f_type env e;
        ()
    | _, Is (e, _) ->
        expr f_type env e;
        ()
    | _, Cast (_, e) ->
        expr f_type env e;
        ()
    | _, Efun _ -> ()

    | Ast.FGenerator, Yield_break
    | Ast.FAsyncGenerator, Yield_break -> ()
    | Ast.FGenerator, Yield af
    | Ast.FAsyncGenerator, Yield af -> afield f_type env af; ()

    (* Should never happen -- presence of yield should make us FGenerator or
     * FAsyncGenerator. *)
    | Ast.FSync, Yield_break
    | Ast.FAsync, Yield_break
    | Ast.FSync, Yield _
    | Ast.FAsync, Yield _ -> assert false

    | Ast.FGenerator, Await _
    | Ast.FSync, Await _ -> Errors.await_in_sync_function p

    | Ast.FAsync, Await _
    | Ast.FAsyncGenerator, Await _ -> Errors.await_not_allowed p

    | Ast.FCoroutine, Await _ ->
      Errors.await_in_coroutine p
    | Ast.FCoroutine, (Yield _ | Yield_break) ->
      Errors.yield_in_coroutine p
    | (Ast.FSync | Ast.FAsync | Ast.FGenerator | Ast.FAsyncGenerator), Suspend _ ->
      if not (coroutines_enabled env)
      then report_coroutines_not_enabled p
      else Errors.suspend_outside_of_coroutine p
    | Ast.FCoroutine, Suspend _ ->
      if not (coroutines_enabled env)
      then report_coroutines_not_enabled p
      else if env.t_is_finally
      then Errors.suspend_in_finally p;
    | _, Special_func func ->
        (match func with
          | Gena e
          | Gen_array_rec e -> expr f_type env e
          | Genva el -> List.iter el (expr f_type env));
        ()
    | _, Xml (_, attrl, el) ->
        List.iter attrl (fun (_, e) -> expr f_type env e);
        List.iter el (expr f_type env);
        ()
    | _, Callconv (_, e) ->
        expr f_type env e;
        ()
    | _, Assert (AE_assert e) ->
        expr f_type env e;
        ()
    | _, Shape fdm ->
        ShapeMap.iter (fun _ v -> expr f_type env v) fdm;
        ()

end

let is_magic =
  let h = Hashtbl.create 23 in
  let a x = Hashtbl.add h x true in
  a SN.Members.__set;
  a SN.Members.__isset;
  a SN.Members.__get;
  a SN.Members.__unset;
  a SN.Members.__call;
  a SN.Members.__callStatic;
  fun (_, s) ->
    Hashtbl.mem h s

let rec fun_ tenv f named_body =
  if !auto_complete then ()
  else begin
    let env = { t_is_finally = false;
                class_name = None; class_kind = None;
                imm_ctrl_ctx = Toplevel;
                typedef_tparams = [];
                tenv = tenv } in
    func env f named_body
  end

and func env f named_body =
  let p, fname = f.f_name in
  if String.lowercase (strip_ns fname) = SN.Members.__construct
  then Errors.illegal_function_name p fname;
  check_coroutines_enabled (f.f_fun_kind = Ast.FCoroutine) env p;
  (* Add type parameters to typing environment and localize the bounds *)
  let tenv, constraints =
    Phase.localize_generic_parameters_with_bounds env.tenv f.f_tparams
       ~ety_env:(Phase.env_with_self env.tenv) in
  let tenv = add_constraints p tenv constraints in
  let env = { env with
    tenv = Env.set_mode tenv f.f_mode;
    t_is_finally = false;
  } in
  maybe hint env f.f_ret;
  List.iter f.f_tparams (tparam env);
  let byref = List.find f.f_params ~f:(fun x -> x.param_is_reference) in
  List.iter f.f_params (fun_param env f.f_name f.f_fun_kind byref);
  let inout = List.find f.f_params ~f:(
    fun x -> x.param_callconv = Some Ast.Pinout) in
  (match inout with
    | Some param ->
      if Attributes.mem SN.UserAttributes.uaMemoize f.f_user_attributes
      then Errors.inout_params_memoize p param.param_pos;
      if f.f_ret_by_ref then Errors.inout_params_ret_by_ref p param.param_pos;
      ()
    | _ -> ()
  );
  block env named_body.fnb_nast;
  CheckFunctionBody.block
    f.f_fun_kind
    env
    named_body.fnb_nast

and tparam env (_, _, cstrl) =
  List.iter cstrl (fun (_, h) -> hint env h)

and hint env (p, h) =
  hint_ env p h

and hint_ env p = function
  | Hany  | Hmixed  | Hprim _  | Hthis | Haccess _ | Habstr _ ->
      ()
  | Harray (ty1, ty2) ->
      maybe hint env ty1;
      maybe hint env ty2
  | Hdarray (ty1, ty2) ->
      hint env ty1;
      hint env ty2
  | Hvarray_or_darray ty
  | Hvarray ty ->
      hint env ty
  | Htuple hl -> List.iter hl (hint env)
  | Hoption h ->
      hint env h; ()
  | Hfun (is_coroutine, hl,_, h) ->
      check_coroutines_enabled is_coroutine env p;
      List.iter hl (hint env);
      hint env h;
      ()
  | Happly ((_, x), hl) as h when Env.is_typedef x ->
    begin match Typing_lazy_heap.get_typedef (Env.get_options env.tenv) x with
      | Some {td_tparams; _} ->
        check_happly env.typedef_tparams env.tenv (p, h);
        check_tparams env p x td_tparams hl
      | None -> ()
    end
  | Happly ((_, x), hl) as h ->
      (match Env.get_class env.tenv x with
      | None -> ()
      | Some class_ ->
          check_happly env.typedef_tparams env.tenv (p, h);
          check_tparams env p x class_.tc_tparams hl
      );
      ()
  | Hshape { nsi_allows_unknown_fields=_; nsi_field_map } ->
      let compute_hint_for_shape_field_info _ { sfi_hint; _; } =
        hint env sfi_hint in

      ShapeMap.iter compute_hint_for_shape_field_info nsi_field_map

and check_tparams env p x tparams hl =
  let arity = List.length tparams in
  check_arity env p x arity (List.length hl);
  List.iter hl (hint env);

and check_arity env p tname arity size =
  if size = arity then () else
  if size = 0 && not (Typing_env.is_strict env.tenv)
  && not (TypecheckerOptions.experimental_feature_enabled (Env.get_options env.tenv)
    TypecheckerOptions.experimental_generics_arity)
  then ()
  else
    let nargs = soi arity in
    Errors.type_arity p tname nargs

and check_happly unchecked_tparams env h =
  let env = { env with Env.pos = (fst h) } in
  let decl_ty = Decl_hint.hint env.Env.decl_env h in
  let unchecked_tparams =
    List.map unchecked_tparams begin fun (v, sid, cstrl) ->
      let cstrl = List.map cstrl (fun (ck, cstr) ->
            let cstr = Decl_hint.hint env.Env.decl_env cstr in
            (ck, cstr)) in
      (v, sid, cstrl)
    end in
  let tyl =
    List.map
      unchecked_tparams
      (fun (_, (p, _), _) -> Reason.Rwitness p, Tany) in
  let subst = Inst.make_subst unchecked_tparams tyl in
  let decl_ty = Inst.instantiate subst decl_ty in
  match decl_ty with
  | _, Tapply (_, tyl) when tyl <> [] ->
      let env, locl_ty = Phase.localize_with_self env decl_ty in
      begin match TUtils.get_base_type env locl_ty with
        | _, Tclass (cls, tyl) ->
          (match Env.get_class env (snd cls) with
            | Some { tc_tparams; _ } ->
                (* We want to instantiate the class type parameters with the
                 * type list of the class we are localizing. We do not want to
                 * add any more constraints when we localize the constraints
                 * stored in the class_type since it may lead to infinite
                 * recursion
                 *)
                let ety_env =
                  { (Phase.env_with_self env) with
                    substs = Subst.make tc_tparams tyl;
                  } in
                iter2_shortest begin fun (_, (p, x), cstrl) ty ->
                  List.iter cstrl (fun (ck, cstr_ty) ->
                      let r = Reason.Rwitness p in
                      let env, cstr_ty = Phase.localize ~ety_env env cstr_ty in
                      ignore @@ Errors.try_
                        (fun () ->
                           TGenConstraint.check_constraint env ck cstr_ty ty
                        )
                        (fun l ->
                          Reason.explain_generic_constraint env.Env.pos r x l;
                          env
                        ))
                end tc_tparams tyl
            | _ -> ()
            )
        | _ -> ()
      end
  | _ -> ()

and class_ tenv c =
  if !auto_complete then () else begin
  let cname = Some (snd c.c_name) in
  let env = { t_is_finally = false;
              class_name = cname;
              class_kind = Some c.c_kind;
              imm_ctrl_ctx = Toplevel;
              typedef_tparams = [];
              tenv = tenv } in
  (* Add type parameters to typing environment and localize the bounds *)
  let tenv, constraints = Phase.localize_generic_parameters_with_bounds
               tenv (fst c.c_tparams)
               ~ety_env:(Phase.env_with_self tenv) in
  let tenv = add_constraints (fst c.c_name) tenv constraints in
  let env = { env with tenv = Env.set_mode tenv c.c_mode } in
  if c.c_kind = Ast.Cinterface then begin
    interface c;
  end
  else begin
    maybe method_ (env, true) c.c_constructor;
  end;
  List.iter (fst c.c_tparams) (tparam env);
  List.iter c.c_extends (hint env);
  List.iter c.c_implements (hint env);
  List.iter c.c_consts (class_const env);
  List.iter c.c_typeconsts (typeconst (env, (fst c.c_tparams)));
  List.iter c.c_static_vars (class_var env);
  List.iter c.c_vars (class_var env);
  List.iter c.c_static_methods (method_ (env, true));
  List.iter c.c_methods (method_ (env, false));
  List.iter c.c_implements (check_is_interface (env, "implement"));
  List.iter c.c_req_implements
    (check_is_interface (env, "require implementation of"));
  List.iter c.c_req_extends (check_is_class env);
  List.iter c.c_uses (check_is_trait env);
  let disallow_static_memoized = TypecheckerOptions.experimental_feature_enabled
    (Env.get_options env.tenv)
    TypecheckerOptions.experimental_disallow_static_memoized in
  if disallow_static_memoized && not c.c_final then
    begin
    List.iter c.c_static_methods (check_static_memoized_function);
    maybe (fun _ m -> check_static_memoized_function m) () c.c_constructor
    end
  end;
  ()

(** Make sure that the given hint points to an interface *)
and check_is_interface (env, error_verb) (x : hint) =
  match (snd x) with
    | Happly (id, _) ->
      (match Env.get_class env.tenv (snd id) with
        | None ->
          (* in partial mode, we can fail to find the class if it's
             defined in PHP. *)
          (* in strict mode, we catch the unknown class error before
             even reaching here. *)
          ()
        | Some { tc_kind = Ast.Cinterface; _ } -> ()
        | Some { tc_name; _ } ->
          Errors.non_interface (fst x) tc_name error_verb
      )
    | Habstr _ ->
      Errors.non_interface (fst x) "generic" error_verb
    | _ ->
      Errors.non_interface (fst x) "invalid type hint" error_verb

(** Make sure that the given hint points to a non-final class *)
and check_is_class env (x : hint) =
  match (snd x) with
    | Happly (id, _) ->
      (match Env.get_class env.tenv (snd id) with
        | None ->
          (* in partial mode, we can fail to find the class if it's
             defined in PHP. *)
          (* in strict mode, we catch the unknown class error before
             even reaching here. *)
          ()
        | Some { tc_kind = Ast.Cabstract; _ } -> ()
        | Some { tc_kind = Ast.Cnormal; _ } -> ()
        | Some { tc_kind; tc_name; _ } ->
          Errors.requires_non_class (fst x) tc_name (Ast.string_of_class_kind tc_kind)
      )
    | Habstr name ->
      Errors.requires_non_class (fst x) name "a generic"
    | _ ->
      Errors.requires_non_class (fst x) "This" "an invalid type hint"

(**
   * Make sure that all "use"s are with traits, and not
   * classes, interfaces, etc.
*)
and check_is_trait env (h : hint) =
  (* Second part of a hint contains Happly information *)
  (match (snd h) with
  (* An Happly contains identifying info (sid) and hint list (which we *)
  (* do not care about at this time *)
  | Happly (pos_and_name, _) ->
    (* Env.get_class will get the type info associated with the name *)
    let type_info = Env.get_class env.tenv (snd pos_and_name) in
    (match type_info with
      (* in partial mode, it's possible to not find the trait, because the *)
      (* trait may live in PHP land. In strict mode, we catch the unknown *)
      (* trait error before even reaching here. so it's ok to just return *)
      (* unit. *)
      | None -> ()
      (* tc_kind is part of the type_info. If we are a trait, all is good *)
      | Some { tc_kind = Ast.Ctrait; _ } -> ()
      (* Anything other than a trait we are going to throw an error *)
      (* using the tc_kind and tc_name fields of our type_info *)
      | Some { tc_kind; tc_name; _ } ->
        Errors.uses_non_trait (fst h) tc_name (Ast.string_of_class_kind tc_kind)
    )
  | _ -> failwith "assertion failure: trait isn't an Happly"
  )

(* Class properties can only be initialized with a static literal expression. *)
and check_class_property_initialization prop =
  (* Only do the check if property is initialized. *)
  Option.iter prop.cv_expr ~f:begin fun e ->
    let rec rec_assert_static_literal e =
      match (snd e) with
      | Any | Shape _ | Typename _
      | Id _ | Class_const _ | True | False | Int _ | Float _
      | Null | String _ | Pipe _ ->
        ()
      | Array field_list ->
        List.iter field_list begin function
          | AFvalue expr -> rec_assert_static_literal expr
          | AFkvalue (expr1, expr2) ->
              rec_assert_static_literal expr1;
              rec_assert_static_literal expr2;
        end
      | Darray fl -> List.iter fl assert_static_literal_for_field_list
      | Varray el -> List.iter el rec_assert_static_literal
      | List el
      | Expr_list el
      | String2 el
      | ValCollection (_, el) -> List.iter el rec_assert_static_literal
      | Pair (expr1, expr2)
      | Binop (_, expr1, expr2) ->
        rec_assert_static_literal expr1;
        rec_assert_static_literal expr2;
      | KeyValCollection (_, field_list) ->
        List.iter field_list assert_static_literal_for_field_list
      | Cast (_, e)
      | Unop (_, e) ->
        rec_assert_static_literal e;
      | Eif (expr1, optional_expr, expr2) ->
        rec_assert_static_literal expr1;
        Option.iter optional_expr rec_assert_static_literal;
        rec_assert_static_literal expr2;
      | NullCoalesce (expr1, expr2) ->
        rec_assert_static_literal expr1;
        rec_assert_static_literal expr2;
      | This | Lvar _ | Lvarvar _ | Lplaceholder _ | Dollardollar _ | Fun_id _
      | Method_id _
      | Method_caller _ | Smethod_id _ | Obj_get _ | Array_get _ | Class_get _
      | Call _ | Special_func _ | Yield_break | Yield _ | Suspend _
      | Await _ | InstanceOf _ | Is _ | New _ | Efun _ | Xml _ | Callconv _
      | Assert _ | Clone _ ->
        Errors.class_property_only_static_literal (fst e)
    and assert_static_literal_for_field_list (expr1, expr2) =
      rec_assert_static_literal expr1;
      rec_assert_static_literal expr2
    in
    rec_assert_static_literal e;
  end

and interface c =
  let enforce_no_body = begin fun m ->
    match m.m_body with
    | UnnamedBody { fub_ast = [] ; _}
    | NamedBody { fnb_nast = [] ; _} ->
      if m.m_visibility <> Public
      then Errors.not_public_interface (fst m.m_name)
      else ()
    | _ -> Errors.abstract_body (fst m.m_name)
  end in
  (* make sure that interface methods are not async, in line with HHVM *)
  let enforce_not_async = begin fun m ->
    match m.m_fun_kind with
    | Ast.FAsync -> Errors.async_in_interface (fst m.m_name)
    | Ast.FAsyncGenerator -> Errors.async_in_interface (fst m.m_name)
    | _ -> ()
  end in
  (* make sure that interfaces only have empty public methods *)
  List.iter (c.c_static_methods @ c.c_methods) enforce_no_body;
  List.iter (c.c_static_methods @ c.c_methods) enforce_not_async;
  (* make sure constructor has no body *)
  Option.iter c.c_constructor enforce_no_body;
  Option.iter c.c_constructor enforce_not_async;
  (* make sure that interfaces don't have any member variables *)
  match c.c_vars with
  | hd::_ ->
    let pos = fst (hd.cv_id) in
    Errors.interface_with_member_variable pos
  | _ -> ();
  (* make sure that interfaces don't have static variables *)
  match c.c_static_vars with
  | hd::_ ->
    let pos = fst (hd.cv_id) in
    Errors.interface_with_static_member_variable pos
  | _ -> ();
  (* make sure interfaces do not contain partially abstract type constants *)
  List.iter c.c_typeconsts begin fun tc ->
    if tc.c_tconst_constraint <> None && tc.c_tconst_type <> None then
      Errors.interface_with_partial_typeconst (fst tc.c_tconst_name)
  end

and class_const env (h, _, e) =
  maybe hint env h;
  maybe expr env e;
  ()

and typeconst (env, class_tparams) tconst =
  maybe hint env tconst.c_tconst_type;
  maybe hint env tconst.c_tconst_constraint;
  (* need to ensure that tconst.c_tconst_type is not Habstr *)
  maybe check_no_class_tparams class_tparams tconst.c_tconst_type;
  maybe check_no_class_tparams class_tparams tconst.c_tconst_constraint

(* Check to make sure we are not using class type params for type const decls *)
and check_no_class_tparams class_tparams (pos, ty)  =
  let check_tparams = check_no_class_tparams class_tparams in
  let maybe_check_tparams = maybe check_no_class_tparams class_tparams in
  let matches_class_tparam tp_name =
    List.iter class_tparams begin fun (_, (c_tp_pos, c_tp_name), _) ->
      if c_tp_name = tp_name
      then Errors.typeconst_depends_on_external_tparam pos c_tp_pos c_tp_name
    end in
  match ty with
    | Hany | Hmixed | Hprim _ | Hthis -> ()
    (* We have found a type parameter. Make sure its name does not match
     * a name in class_tparams *)
    | Habstr tparam_name ->
        matches_class_tparam tparam_name
    | Harray (ty1, ty2) ->
        maybe_check_tparams ty1;
        maybe_check_tparams ty2
    | Hdarray (ty1, ty2) ->
        check_tparams ty1;
        check_tparams ty2
    | Hvarray_or_darray ty
    | Hvarray ty ->
        check_tparams ty
    | Htuple tyl -> List.iter tyl check_tparams
    | Hoption ty_ -> check_tparams ty_
    | Hfun (_, tyl, _, ty_) ->
        List.iter tyl check_tparams;
        check_tparams ty_
    | Happly (_, tyl) -> List.iter tyl check_tparams
    | Hshape { nsi_allows_unknown_fields=_; nsi_field_map } ->
        ShapeMap.iter (fun _ v -> check_tparams v.sfi_hint) nsi_field_map
    | Haccess (root_ty, _) ->
        check_tparams root_ty

and class_var env cv =
  check_class_property_initialization cv;
  let hint_env =
    (* If this is an XHP attribute and we're in strict mode,
       relax to partial mode to allow the use of generic
       classes without specifying type parameters. This is
       a temporary hack to support existing code for now. *)
    (* Task #5815945: Get rid of this Hack *)
    if cv.cv_is_xhp && (Typing_env.is_strict env.tenv)
      then { env with tenv = Typing_env.set_mode env.tenv FileInfo.Mpartial }
      else env in
  maybe hint hint_env cv.cv_type;
  maybe expr env cv.cv_expr;
  ()

and check__toString m is_static =
  if snd m.m_name = SN.Members.__toString
  then begin
    if m.m_visibility <> Public || is_static
    then Errors.toString_visibility (fst m.m_name);
    match m.m_ret with
      | Some (_, Hprim Tstring) -> ()
      | Some (p, _) -> Errors.toString_returns_string p
      | None -> ()
  end

and add_constraint pos tenv (ty1, ck, ty2) =
  Typing_subtype.add_constraint pos tenv ck ty1 ty2

and add_constraints pos tenv (cstrs: locl where_constraint list) =
  List.fold_left cstrs ~init:tenv ~f:(add_constraint pos)

and check_static_memoized_function m =
  if Attributes.mem SN.UserAttributes.uaMemoize m.m_user_attributes then
    Errors.static_memoized_function (fst m.m_name);
  ()

and method_ (env, is_static) m =
  let named_body = assert_named_body m.m_body in
  check__toString m is_static;

  let p, _ = m.m_name in
  check_coroutines_enabled (m.m_fun_kind = Ast.FCoroutine) env p;
  (* Add method type parameters to environment and localize the bounds *)
  let tenv, constraints =
    Phase.localize_generic_parameters_with_bounds env.tenv m.m_tparams
               ~ety_env:(Phase.env_with_self env.tenv) in
  let tenv = add_constraints (fst m.m_name) tenv constraints in
  let env = { env with tenv = tenv } in
  let byref = List.find m.m_params ~f:(fun x -> x.param_is_reference) in
  List.iter m.m_params (fun_param env m.m_name m.m_fun_kind byref);
  let inout = List.find m.m_params ~f:(
    fun x -> x.param_callconv = Some Ast.Pinout) in
  (match inout with
    | Some param ->
      if Attributes.mem SN.UserAttributes.uaMemoize m.m_user_attributes
      then Errors.inout_params_memoize p param.param_pos;
      if m.m_ret_by_ref then Errors.inout_params_ret_by_ref p param.param_pos;
      ()
    | _ -> ()
  );
  List.iter m.m_tparams (tparam env);
  block env named_body.fnb_nast;
  maybe hint env m.m_ret;
  CheckFunctionBody.block
    m.m_fun_kind
    env
    named_body.fnb_nast;
  if m.m_abstract && named_body.fnb_nast <> []
  then Errors.abstract_with_body m.m_name;
  if not (Env.is_decl env.tenv) && not m.m_abstract && named_body.fnb_nast = []
  then Errors.not_abstract_without_body m.m_name;
  (match env.class_name with
  | Some cname ->
      let p, mname = m.m_name in
      if String.lowercase (strip_ns cname) = String.lowercase mname
          && env.class_kind <> Some Ast.Ctrait
      then Errors.dangerous_method_name p
      else ()
  | None -> assert false);
  ()

and inout_params_enabled env =
  TypecheckerOptions.experimental_feature_enabled
    (Env.get_options env.tenv)
    TypecheckerOptions.experimental_inout_params

and require_inout_params_enabled env p =
  let enabled = inout_params_enabled env in
  if not enabled then Errors.experimental_feature p "inout parameters";
  enabled

and fun_param env (_, name) f_type byref param =
  maybe hint env param.param_hint;
  maybe expr env param.param_expr;
  match param.param_callconv with
  | None -> ()
  | Some Ast.Pinout ->
    let pos = param.param_pos in
    if require_inout_params_enabled env pos
    then begin
      if f_type <> Ast.FSync then Errors.inout_params_outside_of_sync pos;
      if SSet.mem name SN.Members.as_set then Errors.inout_params_special pos;
      Option.iter byref ~f:(fun param ->
        Errors.inout_params_mix_byref pos param.param_pos)
    end

and stmt env = function
  | Return (p, _) when env.t_is_finally ->
    Errors.return_in_finally p; ()
  | Return (_, None)
  | GotoLabel _
  | Goto _
  | Noop
  | Fallthrough -> ()
  | Break p -> begin
    match env.imm_ctrl_ctx with
      | Toplevel -> Errors.toplevel_break p
      | _ -> ()
    end
  | Continue p -> begin
    match env.imm_ctrl_ctx with
      | Toplevel -> Errors.toplevel_continue p
      | SwitchContext -> Errors.continue_in_switch p
      | LoopContext -> ()
    end
  | Return (_, Some e)
  | Expr e | Throw (_, e) ->
    expr env e
  | Static_var el
  | Global_var el
    -> List.iter el (expr env)
  | If (e, b1, b2) ->
    expr env e;
    block env b1;
    block env b2;
    ()
  | Do (b, e) ->
    block { env with imm_ctrl_ctx = LoopContext } b;
    expr env e;
    ()
  | While (e, b) ->
      expr env e;
      block { env with imm_ctrl_ctx = LoopContext } b;
      ()
  | Using (_has_await, e, b) ->
      expr env e;
      block env b;
      ()
  | For (e1, e2, e3, b) ->
      expr env e1;
      expr env e2;
      expr env e3;
      block { env with imm_ctrl_ctx = LoopContext } b;
      ()
  | Switch (e, cl) ->
      expr env e;
      List.iter cl (case { env with imm_ctrl_ctx = SwitchContext });
      ()
  | Foreach (e1, ae, b) ->
      expr env e1;
      as_expr env ae;
      block { env with imm_ctrl_ctx = LoopContext } b;
      ()
  | Try (b, cl, fb) ->
      block env b;
      List.iter cl (catch env);
      block { env with t_is_finally = true } fb;
      ()

and as_expr env = function
  | As_v e
  | Await_as_v (_, e) -> expr env e
  | As_kv (e1, e2)
  | Await_as_kv (_, e1, e2) ->
      expr env e1;
      expr env e2;
      ()

and afield env = function
  | AFvalue e -> expr env e
  | AFkvalue (e1, e2) -> expr env e1; expr env e2;

and block env stl =
  List.iter stl (stmt env)

and expr env (p, e) =
  expr_ env p e

and expr_ env p = function
  | Any
  | Fun_id _
  | Method_id _
  | Smethod_id _
  | Method_caller _
  | This
  | Class_get _
  | Class_const _
  | Typename _
  | Lvar _
  | Lvarvar _
  | Lplaceholder _ | Dollardollar _ -> ()
  | Pipe (_, e1, e2) ->
      expr env e1;
      expr env e2
  (* Check that __CLASS__ and __TRAIT__ are used appropriately *)
  | Id (pos, const) ->
      if SN.PseudoConsts.is_pseudo_const const then
        if const = SN.PseudoConsts.g__CLASS__ then
          (match env.class_kind with
            | Some _ -> ()
            | _ -> Errors.illegal_CLASS pos)
        else if const = SN.PseudoConsts.g__TRAIT__ then
          (match env.class_kind with
            | Some Ast.Ctrait -> ()
            | _ -> Errors.illegal_TRAIT pos);
      ()
  | Array afl ->
      List.iter afl (afield env);
      ()
  | Darray fdl ->
      List.iter fdl (field env);
      ()
  | Varray el ->
      List.iter el (expr env);
      ()
  | ValCollection (_, el) ->
      List.iter el (expr env);
      ()
  | KeyValCollection (_, fdl) ->
      List.iter fdl (field env);
      ()
  | Clone e -> expr env e; ()
  | Obj_get (e, (_, Id s), _) ->
      if is_magic s && Env.is_strict env.tenv
      then Errors.magic s;
      expr env e;
      ()
  | Obj_get (e1, e2, _) ->
      expr env e1;
      expr env e2;
      ()
  | Array_get (e, eopt) ->
      expr env e;
      maybe expr env eopt;
      ()
  | Call (_, e, _, el, uel) ->
      expr env e;
      List.iter el (expr env);
      List.iter uel (expr env);
      ()
  | True | False | Int _
  | Float _ | Null | String _ -> ()
  | String2 el ->
      List.iter el (expr env);
      ()
  | Unop (_, e) -> expr env e
  | Yield_break -> ()
  | Special_func func ->
      (match func with
        | Gena e
        | Gen_array_rec e ->
          expr env e
        | Genva el ->
          List.iter el (expr env));
      ()
  | Yield e ->
      afield env e;
      ()
  | Await e ->
      expr env e;
      ()
  | Suspend e ->
      expr env e;
      ()
  | List el ->
      List.iter el (expr env);
      ()
  | Pair (e1, e2) ->
    expr env e1;
    expr env e2;
    ()
  | Expr_list el ->
      List.iter el (expr env);
      ()
  | Cast (h, e) ->
      hint env h;
      expr env e;
      ()
  | Binop (_, e1, e2) ->
      expr env e1;
      expr env e2;
      ()
  | Eif (e1, None, e3) ->
      expr env e1;
      expr env e3;
      ()
  | Eif (e1, Some e2, e3) ->
      expr env e1;
      expr env e2;
      expr env e3;
      ()
  | NullCoalesce (e1, e2) ->
      expr env e1;
      expr env e2;
      ()
  | Assert (AE_assert e)
  | InstanceOf (e, _) ->
      expr env e;
      ()
  | Is (e, h) ->
      expr env e;
      hint env h;
      ()
  | New (_, el, uel) ->
      List.iter el (expr env);
      List.iter uel (expr env);
      ()
  | Efun (f, _) ->
      check_coroutines_enabled (f.f_fun_kind = Ast.FCoroutine) env p;
      let env = { env with imm_ctrl_ctx = Toplevel } in
      let body = Nast.assert_named_body f.f_body in
      func env f body; ()
  | Xml (_, attrl, el) ->
      List.iter attrl (attribute env);
      List.iter el (expr env);
      ()
  | Callconv (_, e) ->
      let _ = require_inout_params_enabled env p in
      expr env e;
      ()
  | Shape fdm ->
      ShapeMap.iter (fun _ v -> expr env v) fdm

and case env = function
  | Default b -> block env b
  | Case (e, b) ->
      expr env e;
      block env b;
      ()

and catch env (_, _, b) = block env b
and field env (e1, e2) =
  expr env e1;
  expr env e2;
  ()

and attribute env (_, e) =
  expr env e;
  ()

let typedef tenv t =
  let env = { t_is_finally = false;
              class_name = None; class_kind = None;
              imm_ctrl_ctx = Toplevel;
              (* Since typedefs cannot have constraints we shouldn't check
               * if its type params satisfy the constraints of any tapply it
               * references.
               *)
              typedef_tparams = t.t_tparams;
              tenv = tenv } in
  maybe hint env t.t_constraint;
  hint env t.t_kind
