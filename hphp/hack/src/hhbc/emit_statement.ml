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
open Hhbc_ast
open Instruction_sequence
open Emit_expression

module A = Ast
module H = Hhbc_ast
module TC = Hhas_type_constraint
module SN = Naming_special_names
module CBR = Continue_break_rewriter

(* Context for code generation. It would be more elegant to pass this
 * around in an environment parameter. *)
let verify_return = ref false
let default_return_value = ref instr_null
let default_dropthrough = ref None
let return_by_ref = ref false
let set_verify_return b = verify_return := b
let set_default_return_value i = default_return_value := i
let set_default_dropthrough i = default_dropthrough := i
let set_return_by_ref b = return_by_ref := b

let emit_return ~need_ref =
  let ret_instr = if need_ref then instr_retv else instr_retc in
  let verify_instr =
    if need_ref then instr_verifyRetTypeV else instr_verifyRetTypeC in
  if !verify_return
  then gather [verify_instr; ret_instr]
  else ret_instr

let emit_def_inline = function
  | A.Fun fd ->
    instr_deffunc (int_of_string (snd fd.Ast.f_name))
  | A.Class cd ->
    instr_defcls (int_of_string (snd cd.Ast.c_name))
  | A.Typedef td ->
    instr_deftypealias (int_of_string (snd td.Ast.t_id))
  | _ ->
    failwith "Define inline: Invalid inline definition"

let emit_markup env s echo_expr_opt ~check_for_hashbang =
  let emit_ignored_call_expr f e =
    let p = Pos.none in
    let call_expr = p, A.Call ((p, A.Id (p, f)), [e], []) in
    emit_ignored_expr env call_expr
  in
  let emit_ignored_call_for_non_empty_string f s =
    if String.length s = 0 then empty
    else emit_ignored_call_expr f (Pos.none, A.String (Pos.none, s))
  in
  let markup =
    if String.length s = 0
    then empty
    else
      let hashbang, tail =
        if check_for_hashbang
        then
          (* if markup text starts with #!
          - extract a line with hashbang - it will be emitted as a call
          to print_hashbang function
          - emit remaining part of text as regular markup *)
          let r = Str.regexp "^#!.*\n" in
          if Str.string_match r s 0
          then
            let cmd = Str.matched_string s in
            let tail = String_utils.lstrip s cmd in
            cmd, tail
          else "", s
        else "", s
      in
      gather [
        emit_ignored_call_for_non_empty_string
          "__SystemLib\\print_hashbang" hashbang;
        emit_ignored_call_for_non_empty_string SN.SpecialFunctions.echo tail
      ]
  in
  let echo =
    match echo_expr_opt with
    | Some e -> emit_ignored_call_expr SN.SpecialFunctions.echo e
    | None -> empty
  in
  gather [
    markup;
    echo
  ]

let rec emit_stmt env st =
  match st with
  | A.Expr (_, A.Yield_break) ->
    gather [
      instr_null;
      emit_return ~need_ref:false;
    ]
  | A.Expr (_, A.Call ((_, A.Id (_, "unset")), exprl, [])) ->
    gather (List.map exprl (emit_unset_expr env))
  | A.Expr (_, A.Call ((_, A.Id (_, "declare")),
      [
        _, (
        A.Binop (A.Eq None, (_, A.Id(_, "ticks")), (_, A.Int(_))) |
        A.Binop (A.Eq None, (_, A.Id(_, "encoding")), (_, A.String(_))) |
        A.Binop (A.Eq None, (_, A.Id(_, "strict_types")), (_, A.Int(_)))
        )
      ], []))
      ->
    empty
  | A.Return (_, Some (_, A.Await e)) ->
    gather [
      emit_await env e;
      emit_return ~need_ref:false;
    ]
  | A.Expr (_, A.Await e) ->
    gather [
      emit_await env e;
      instr_popc;
    ]
  | A.Expr
    (_, A.Binop ((A.Eq None), ((_, A.List l) as e1), (_, A.Await e_await))) ->
    let has_elements =
      List.exists l ~f: (function
        | _, A.Omitted -> false
        | _ -> true)
    in
    if has_elements then
      Local.scope @@ fun () ->
        let temp = Local.get_unnamed_local () in
        gather [
          emit_await env e_await;
          instr_setl temp;
          instr_popc;
          with_temp_local temp
          begin fun temp _ ->
            emit_lval_op_list env (Some temp) [] e1
          end;
          instr_pushl temp;
          instr_popc;
        ]
    else
      Local.scope @@ fun () ->
        let temp = Local.get_unnamed_local () in
        gather [
          emit_await env e_await;
          instr_setl temp;
          instr_popc;
          instr_pushl temp;
          instr_popc;
        ]
  | A.Expr (_, A.Binop (A.Eq None, e_lhs, (_, A.Await e_await))) ->
    Local.scope @@ fun () ->
      let temp = Local.get_unnamed_local () in
      let rhs_instrs = instr_pushl temp in
      let (lhs, rhs, setop) =
        emit_lval_op_nonlist_steps env LValOp.Set e_lhs rhs_instrs 1 in
      gather [
        emit_await env e_await;
        instr_setl temp;
        instr_popc;
        with_temp_local temp (fun _ _ -> lhs);
        rhs;
        setop;
        instr_popc;
      ]
  | A.Expr expr ->
    emit_ignored_expr env expr
  | A.Return (_, None) ->
    gather [
      instr_null;
      emit_return ~need_ref:false;
    ]
  | A.Return (_,  Some expr) ->
    let need_ref = !return_by_ref in
    gather [
      emit_expr ~need_ref env expr;
      emit_return ~need_ref;
    ]
  | A.GotoLabel (_, label) ->
    instr_label (Label.named label)
  | A.Goto (_, label) ->
    instr_jmp (Label.named label)
  | A.Block b -> emit_stmts env b
  | A.If (condition, consequence, alternative) ->
    emit_if env condition (A.Block consequence) (A.Block alternative)
  | A.While (e, b) ->
    emit_while env e (A.Block b)
  | A.Break (_, level_opt) ->
    instr_break (Option.value level_opt ~default:1)
  | A.Continue (_, level_opt) ->
    instr_continue (Option.value level_opt ~default:1)
  | A.Do (b, e) ->
    emit_do env (A.Block b) e
  | A.For (e1, e2, e3, b) ->
    emit_for env e1 e2 e3 (A.Block b)
  | A.Throw e ->
    gather [
      emit_expr ~need_ref:false env e;
      instr (IContFlow Throw);
    ]
  | A.Try (try_block, catch_list, finally_block) ->
    if catch_list <> [] && finally_block <> [] then
      emit_stmt env (A.Try([A.Try (try_block, catch_list, [])], [], finally_block))
    else if catch_list <> [] then
      emit_try_catch env (A.Block try_block) catch_list
    else
      emit_try_finally env (A.Block try_block) (A.Block finally_block)

  | A.Switch (e, cl) ->
    emit_switch env e cl
  | A.Foreach (collection, await_pos, iterator, block) ->
    emit_foreach env (await_pos <> None) collection iterator
      (A.Block block)
  | A.Def_inline def ->
    emit_def_inline def
  | A.Static_var es ->
    emit_static_var es
  | A.Global_var es ->
    emit_global_vars env es
  | A.Markup ((_, s), echo_expr_opt) ->
    emit_markup env s echo_expr_opt ~check_for_hashbang:false
    (* TODO: What do we do with unsafe? *)
  | A.Unsafe
  | A.Fallthrough
  | A.Noop -> empty

and emit_await env e =
  let after_await = Label.next_regular () in
  gather [
    emit_expr ~need_ref:false env e;
    instr_dup;
    instr_istypec OpNull;
    instr_jmpnz after_await;
    instr_await;
    instr_label after_await;
  ]

and emit_if env condition consequence alternative =
  match alternative with
  | A.Block []
  | A.Block [A.Noop] ->
    let done_label = Label.next_regular () in
    gather [
      emit_jmpz env condition done_label;
      emit_stmt env consequence;
      instr_label done_label;
    ]
  | _ ->
    let alternative_label = Label.next_regular () in
    let done_label = Label.next_regular () in
    gather [
      emit_jmpz env condition alternative_label;
      emit_stmt env consequence;
      instr_jmp done_label;
      instr_label alternative_label;
      emit_stmt env alternative;
      instr_label done_label;
    ]

and emit_global_vars env es =
  let emit_global_var (_, e) =
    match e with
    | A.Id (_, name) when name.[0] = '$' ->
      if SN.Superglobals.is_superglobal name
      then empty
      else
        gather [
          instr_string (SU.Locals.strip_dollar name);
          instr_vgetg;
          instr_bindl @@ Local.Named name;
          instr_popv;
        ]
    | A.Lvarvar (n, (_, id)) ->
      let load_name =
        if SN.Superglobals.is_superglobal id then
          gather [
            instr_string (SU.Locals.strip_dollar id);
            instr_cgetg;
          ]
        else
          instr_cgetl (Local.Named id)
      in
      gather [
        load_name;
        gather @@ List.replicate (n - 1) instr_cgetn;
        instr_dup;
        instr_vgetg;
        instr_bindn;
        instr_popv;
      ]
    | A.BracedExpr e ->
      gather [
        emit_expr ~need_ref:false env e;
        instr_dup;
        instr_vgetg;
        instr_bindn;
        instr_popv;
      ]
    | _ ->
      emit_nyi "global expression"
  in gather (List.map es emit_global_var)

and emit_static_var es =
  let emit_static_var_single e =
    match snd e with
    | A.Lvar (_, name)
    | A.Binop (A.Eq _, (_, A.Lvar (_, name)), _) ->
      instr_static_loc_init name
    | _ -> failwith "Static var - impossible"
  in
  gather @@ List.map es ~f:emit_static_var_single

and emit_while env e b =
  let break_label = Label.next_regular () in
  let cont_label = Label.next_regular () in
  let start_label = Label.next_regular () in
  (* TODO: This is *bizarre* codegen for a while loop.
  It would be better to generate this as
  instr_label continue_label;
  emit_expr e;
  instr_jmpz break_label;
  body;
  instr_jmp continue_label;
  instr_label break_label;
  *)
  let instrs = gather [
    emit_jmpz env e break_label;
    instr_label start_label;
    emit_stmt env b;
    instr_label cont_label;
    emit_jmpnz env e start_label;
    instr_label break_label;
  ] in
  CBR.rewrite_in_loop instrs cont_label break_label None

and emit_do env b e =
  let cont_label = Label.next_regular () in
  let break_label = Label.next_regular () in
  let start_label = Label.next_regular () in
  let instrs = gather [
    instr_label start_label;
    emit_stmt env b;
    instr_label cont_label;
    emit_jmpnz env e start_label;
    instr_label break_label;
  ] in
  CBR.rewrite_in_loop instrs cont_label break_label None

and emit_for env e1 e2 e3 b =
  let break_label = Label.next_regular () in
  let cont_label = Label.next_regular () in
  let start_label = Label.next_regular () in
  (* TODO: this is bizarre codegen for a "for" loop.
     This should be codegen'd as
     emit_ignored_expr initializer;
     instr_label start_label;
     from_expr condition;
     instr_jmpz break_label;
     body;
     instr_label continue_label;
     emit_ignored_expr increment;
     instr_jmp start_label;
     instr_label break_label;
  *)
  let emit_cond ~jmpz label =
    let final cond =
      if jmpz then emit_jmpz env cond label else emit_jmpnz env cond label
    in
    let rec expr_list h tl =
      match tl with
      | [] -> [final @@ (Pos.none, A.Expr_list [h])]
      | h1 :: t1 -> emit_ignored_expr env h :: expr_list h1 t1
    in
    match e2 with
    | _, A.Expr_list [] -> empty
    | _, A.Expr_list (h::t) -> gather @@ expr_list h t
    | cond -> final cond
  in
  let instrs = gather [
    emit_ignored_expr env e1;
    emit_cond ~jmpz:true break_label;
    instr_label start_label;
    emit_stmt env b;
    instr_label cont_label;
    emit_ignored_expr env e3;
    emit_cond ~jmpz:false start_label;
    instr_label break_label;
  ] in
  CBR.rewrite_in_loop instrs cont_label break_label None

and emit_switch env scrutinee_expr cl =
  stash_in_local env scrutinee_expr
  begin fun local break_label ->
  (* If there is no default clause, add an empty one at the end *)
  let is_default c = match c with A.Default _ -> true | _ -> false in
  let cl =
    if List.exists cl is_default
    then cl
    else cl @ [A.Default []] in
  (* "continue" in a switch in PHP has the same semantics as break! *)
  let cl = List.map cl ~f:(emit_case env) in
  let bodies = gather @@ List.map cl ~f:snd in
  let init = gather @@ List.map cl
    ~f: begin fun x ->
          let (e_opt, l) = fst x in
          match e_opt with
          | None ->
            instr_jmp l
          | Some e ->
            (* Special case for simple scrutinee *)
            match scrutinee_expr with
            | _, A.Lvar _ ->
              let eq_expr = Pos.none, A.Binop (A.Eqeq, scrutinee_expr, e) in
              gather [
                emit_expr ~need_ref:false env eq_expr;
                instr_jmpnz l
              ]
            | _ ->
              gather [
                instr_cgetl local;
                emit_expr ~need_ref:false env e;
                instr_eq;
                instr_jmpnz l]
        end
  in
  let instrs = gather [
    init;
    bodies;
  ] in
CBR.rewrite_in_switch instrs break_label
  end

and emit_catch env end_label (catch_type, (_, catch_local), b) =
    (* Note that this is a "regular" label; we're not going to branch to
    it directly in the event of an exception. *)
    let next_catch = Label.next_regular () in
    let id, _ = Hhbc_id.Class.elaborate_id
      (Emit_env.get_namespace env) catch_type in
    gather [
      instr_dup;
      instr_instanceofd id;
      instr_jmpz next_catch;
      instr_setl (Local.Named catch_local);
      instr_popc;
      emit_stmt env (A.Block b);
      instr_jmp end_label;
      instr_label next_catch;
    ]

and emit_catches env catch_list end_label =
  gather (List.map catch_list ~f:(emit_catch env end_label))

and is_empty_block b =
  match b with
  | A.Block l -> List.for_all ~f:is_empty_block l
  | A.Noop -> true
  | _ -> false

and emit_try_catch env try_block catch_list =
  Local.scope @@ fun () ->
    emit_try_catch_ env try_block catch_list

and emit_try_catch_ env try_block catch_list =
  if is_empty_block try_block then empty
  else
  let end_label = Label.next_regular () in
  gather [
    instr_try_catch_begin;
    emit_stmt env try_block;
    instr_jmp end_label;
    instr_try_catch_middle;
    emit_catches env catch_list end_label;
    instr_throw;
    instr_try_catch_end;
    instr_label end_label;
  ]

and emit_try_finally env try_block finally_block =
  Local.scope @@ fun () ->
    emit_try_finally_ env try_block finally_block

and emit_try_finally_ env try_block finally_block =
  let finally_body = emit_stmt env finally_block in
  let finally_body = CBR.rewrite_in_finally finally_body in

  if is_empty_block try_block then finally_body
  else
  (*
  We need to generate four things:
  (1) the try-body, which will be followed by
  (2) the normal-continuation finally body, and
  (3) an epilogue to the finally body that deals with finally-blocked
      break and continue
  (4) the exceptional-continuation fault body.
  *)

  (* (1) Try body

  The try body might have un-rewritten continues and breaks which
  branch to a label outside of the try. This means that we must
  first run the normal-continuation finally, and then branch to the
  appropriate label.

  We do this by running a rewriter which turns continues and breaks
  inside the try body into setting temp_local to an integer which indicates
  what action the finally must perform when it is finished, followed by a
  jump directly to the finally.
  *)
  let try_body = emit_stmt env try_block in
  let temp_local = Local.get_unnamed_local () in
  let finally_start = Label.next_regular () in
  let cont_and_break = CBR.get_continues_and_breaks try_body in
  let try_body = CBR.rewrite_in_try_finally
    try_body cont_and_break temp_local finally_start in

  (* (2) Finally body

  Note that this is used both in the normal-continuation and
  exceptional-continuation cases; we generate the same code twice.

  TODO: We might consider changing the codegen so that the finally block
  is only generated once. We could do this by making the fault block set a
  temp local to -1, and then branch to the finally block. In the finally block
  epilogue it can check to see if the local is -1, and if so, issue an unwind
  instruction.

  It is illegal to have a continue or break which branches out of a finally.
  Unfortunately we at present do not detect this at parse time; rather, we
  generate an exception at run-time by rewriting continue and break
  instructions found inside finally blocks.

  TODO: If we make this illegal at parse time then we can remove this pass.
  *)
  let finally_body_for_fault =
    Label_rewriter.clone_with_fresh_regular_labels finally_body
  in
  let finally_end = Label.next_regular () in

  (* (3) Finally epilogue *)

  let finally_epilogue =
    CBR.emit_finally_epilogue cont_and_break temp_local finally_end in

  (* (4) Fault body

  We now emit the fault body; it is just cleanup code for the temp_local,
  a copy of the finally body (without the branching epilogue, since we are
  going to unwind rather than branch), and an unwind instruction.

  TODO: The HHVM emitter sometimes emits seemingly spurious
  unset-unnamed-local instructions into the fault block.  These look
  like bugs in the emitter. Investigate; if they are bugs in the HHVM
  emitter, get them fixed there. If not, get a clear explanation of
  what they are for and why they are required.
  *)

  let cleanup_local =
    if cont_and_break = [] then empty else instr_unsetl temp_local in
  let fault_body = gather [
      cleanup_local;
      finally_body_for_fault;
      instr_unwind;
    ] in
  let fault_label = Label.next_fault () in
  (* Put it all together. *)
  gather [
    instr_try_fault fault_label try_body fault_body;
    instr_label finally_start;
    finally_body;
    finally_epilogue;
    instr_label finally_end;
  ]

and is_mutable_iterator iterator =
  match iterator with
  | A.As_kv (_, (_, A.Unop(A.Uref, _)))
  | A.As_v (_, A.Unop(A.Uref, _)) -> true
  | _ -> false

and load_lvarvar n id =
  instr_cgetl (Local.Named id) ::
  List.replicate (n - 1) instr_cgetn

and get_id_of_simple_lvar_opt v =
  match v with
  | A.Lvar (_, id) | A.Unop (A.Uref, (_, A.Lvar (_, id)))
    when not (SN.Superglobals.is_superglobal id) -> Some id
  | _ -> None

and emit_load_list_elements path vs =
  let preamble, load_value =
    List.mapi ~f:(emit_load_list_element path) vs
    |> List.unzip
  in
  List.concat preamble, List.concat load_value

and emit_load_list_element path i v =
  let query_value = gather [
    gather @@ List.rev path;
    instr_querym 0 QueryOp.CGet (MemberKey.EI (Int64.of_int i));
  ]
  in
  match v with
  | _, A.Lvar (_, id) ->
    let load_value = gather [
      query_value;
      instr_setl (Local.Named id);
      instr_popc
    ]
    in
    [], [load_value]
  | _, A.Lvarvar (n, (_, id)) ->
    let local = Local.Named id in
    let preamble =
      if n = 1 then []
      else load_lvarvar n id
    in
    let load_value =
      if n = 1 then [
        query_value;
        instr_cgetl2 local;
        instr_setn;
        instr_popc
      ]
      else [
        query_value;
        instr_setn;
        instr_popc
      ]
    in
    [gather preamble], [gather load_value]
  | _, A.List exprs ->
    let dim_instr =
      instr_dim MemberOpMode.Warn (MemberKey.EI (Int64.of_int i))
    in
    emit_load_list_elements (dim_instr::path) exprs
  | _ -> failwith "impossible, expected variables or lists"

(* Assigns a location to store values for foreach-key and foreach-value and
   creates a code to populate them.
   Returns: key_local_opt * value_local * key_preamble * value_preamble
   where:
   - key_local_opt - local variable to store a foreach-key value if it is
     declared
   - value_local - local variable to store a foreach-value
   - key_preamble - list of instructions to populate foreach-key
   - value_preamble - list of instructions to populate foreach-value
   *)
and emit_iterator_key_value_storage env iterator =
  match iterator with
  | A.As_kv (((_, k) as expr_k), ((_, v) as expr_v)) ->
    begin match get_id_of_simple_lvar_opt k, get_id_of_simple_lvar_opt v with
    | Some key_id, Some value_id ->
      let key_local = Local.Named key_id in
      let value_local = Local.Named value_id in
      Some key_local, value_local, [], []
    | _ ->
      let key_local = Local.get_unnamed_local () in
      let value_local = Local.get_unnamed_local () in
      let key_preamble, key_load =
        emit_iterator_lvalue_storage env expr_k key_local in
      let value_preamble, value_load =
        emit_iterator_lvalue_storage env expr_v value_local
      in

      (* HHVM prepends code to initialize non-plain, non-list foreach-key
         to the value preamble - do the same to minimize diffs *)
      let key_preamble, value_preamble =
        match k with
        | A.List _ -> key_preamble, value_preamble
        | _ -> [], (gather key_preamble) :: value_preamble
      in
      Some key_local, value_local,
      (gather key_preamble)::key_load,
      (gather value_preamble)::value_load
    end
  | A.As_v ((_, v) as expr_v) ->
    begin match get_id_of_simple_lvar_opt v with
    | Some value_id ->
      let value_local = Local.Named value_id in
      None, value_local, [], []
    | None ->
      let value_local = Local.get_unnamed_local () in
      let value_preamble, value_load =
        emit_iterator_lvalue_storage env expr_v value_local in
      None, value_local, value_preamble, value_load
    end

(*Generates a code to initialize a given foreach-* value.
  Returns: preamble * load_code
  where:
  - preamble - preparation part that should be executed before the loading
  - load_code - instructions to actually populate the value.
  This split is necessary to reflect the way how HHVM loads values.
  as an example for the code
    list($$$a, $$b, $$$c)
  preamble part will include code that pushes cells for $$a and $$c on the stack
  load_code will be executed assuming that stack is prepopulated:
    [$aa, $$c] <- top
  *)
and emit_iterator_lvalue_storage env v local =
  match v with
  | _, A.Call _ ->
    Emit_fatal.raise_fatal_parse "Can't use return value in write context"
  | _, A.List exprs ->
    let preamble, load_values =
      emit_load_list_elements [instr_basel local MemberOpMode.Warn] exprs
    in
    let load_values = [
      gather @@ (List.rev load_values);
      instr_unsetl local
    ]
    in
    preamble, load_values
  | x ->
    match x with
    | _, A.Unop (A.Uref, e) ->
      let (lhs, rhs, set_op) =
        emit_lval_op_nonlist_steps env LValOp.SetRef e (instr_vgetl local) 1
      in
      [lhs], [
        rhs;
        set_op;
        instr_popv;
        instr_unsetl local
      ]
    | x ->
      let (lhs, rhs, set_op) =
        emit_lval_op_nonlist_steps env LValOp.Set x (instr_cgetl local) 1
      in
      [lhs], [
        rhs;
        set_op;
        instr_popc;
        instr_unsetl local
      ]

and wrap_non_empty_block_in_fault prefix block fault_block =
  match block with
  | [] -> prefix
  | block ->
    instr_try_fault
      (Label.next_fault())
      (gather @@ prefix::block)
      fault_block

and emit_foreach env has_await collection iterator block =
  Local.scope @@ fun () ->
    if not has_await then emit_foreach_ env collection iterator block
    else emit_foreach_await env collection iterator block

and emit_foreach_await env collection iterator block =
  let next_label = Label.next_regular () in
  let exit_label = Label.next_regular () in
  let iter_temp_local = Local.get_unnamed_local () in
  let collection_expr = emit_expr ~need_ref:false env collection in
  let result_temp_local = Local.get_unnamed_local () in
  let key_local_opt, value_local, key_preamble, value_preamble =
    emit_iterator_key_value_storage env iterator in
  let next_meth = Hhbc_id.Method.from_raw_string "next" in
  let fault_block_local local = gather [
    instr_unsetl local;
    instr_unwind
  ] in
  let set_from_result idx local preamble = gather [
    instr_basel result_temp_local MemberOpMode.Warn;
    instr_querym 0 QueryOp.CGet (MemberKey.EI (Int64.of_int idx));
    instr_setl local;
    instr_popc;
    wrap_non_empty_block_in_fault empty preamble (fault_block_local local)
  ] in
  let set_key = match key_local_opt with
  | Some (key_local) -> set_from_result 0 key_local key_preamble
  | None -> empty in
  let result = gather [
    collection_expr;
    instr_setl iter_temp_local;
    with_temp_local iter_temp_local begin fun _ _ -> gather [
      instr_instanceofd (Hhbc_id.Class.from_raw_string "HH\\AsyncIterator");
      instr_jmpnz next_label;
      Emit_fatal.emit_fatal_runtime
        "Unable to iterate non-AsyncIterator asynchronously";
      instr_label next_label;
      instr_cgetl iter_temp_local;
      instr_fpushobjmethodd 0 next_meth A.OG_nullthrows;
      instr_fcall 0;
      instr_unboxr;
      instr_await;
      instr_setl result_temp_local;
      instr_popc;
      instr_istypel result_temp_local OpNull;
      instr_jmpnz exit_label;
      with_temp_local result_temp_local begin fun _ _ -> gather [
        set_key;
        set_from_result 1 value_local value_preamble;
      ] end;
      instr_unsetl result_temp_local;
      emit_stmt env block;
      instr_jmp next_label;
      instr_label exit_label;
      instr_unsetl result_temp_local;
    ] end;
    instr_unsetl iter_temp_local;
  ] in
  CBR.rewrite_in_loop result next_label exit_label None

and emit_foreach_ env collection iterator block =
  let iterator_number = Iterator.get_iterator () in
  let fault_label = Label.next_fault () in
  let loop_break_label = Label.next_regular () in
  let loop_continue_label = Label.next_regular () in
  let loop_head_label = Label.next_regular () in
  let mutable_iter = is_mutable_iterator iterator in
  let key_local_opt, value_local, key_preamble, value_preamble =
    emit_iterator_key_value_storage env iterator
  in
  let fault_block_local local = gather [
    instr_unsetl local;
    instr_unwind
  ]
  in
  let init, next, preamble = match key_local_opt with
  | Some (key_local) ->
    let initf, nextf =
      if mutable_iter then instr_miterinitk, instr_miternextk
      else instr_iterinitk, instr_iternextk
    in
    let init = initf iterator_number loop_break_label value_local key_local in
    let cont = nextf iterator_number loop_head_label value_local key_local in
    let preamble =
      wrap_non_empty_block_in_fault
        (instr_label loop_head_label)
        value_preamble
        (fault_block_local value_local)
    in
    let preamble =
      wrap_non_empty_block_in_fault
        preamble
        key_preamble
        (fault_block_local key_local)
    in
    init, cont, preamble
  | None ->
    let initf, nextf =
      if mutable_iter then instr_miterinit, instr_miternext
      else instr_iterinit, instr_iternext
    in
    let init = initf iterator_number loop_break_label value_local in
    let cont = nextf iterator_number loop_head_label value_local in
    let preamble =
      wrap_non_empty_block_in_fault
        (instr_label loop_head_label)
        value_preamble
        (fault_block_local value_local)
    in
    init, cont, preamble
  in
  let body = emit_stmt env block in

  let result = gather [
    emit_expr ~need_ref:mutable_iter env collection;
    init;
    instr_try_fault
      fault_label
      (* try body *)
      (gather [
        preamble;
        body;
        instr_label loop_continue_label;
        next
      ])
      (* fault body *)
      (gather [
        if mutable_iter then instr_miterfree iterator_number
        else instr_iterfree iterator_number;

        instr_unwind ]);
    instr_label loop_break_label
  ] in
  Iterator.free_iterator ();
  CBR.rewrite_in_loop
    result loop_continue_label loop_break_label
    (Some (mutable_iter, iterator_number))

and emit_stmts env stl =
  let results = List.map stl (emit_stmt env) in
  gather results

and emit_case env c =
  let l = Label.next_regular () in
  let b = match c with
    | A.Default b
    | A.Case (_, b) ->
        emit_stmt env (A.Block b)
  in
  let e = match c with
    | A.Case (e, _) -> Some e
    | _ -> None
  in
  (e, l), gather [instr_label l; b]

let emit_dropthrough_return () =
  match !default_dropthrough with
  | Some instrs -> instrs
  | _ ->
    gather [!default_return_value; emit_return ~need_ref:false]

let rec emit_final_statement env s =
  match s with
  | A.Throw _ | A.Return _ | A.Goto _
  | A.Expr (_, A.Yield_break) ->
    emit_stmt env s
  | A.Block b ->
    emit_final_statements env b
  | _ ->
    gather [
      emit_stmt env s;
      emit_dropthrough_return ()
    ]

and emit_final_statements env b =
  match b with
  | [] -> emit_dropthrough_return ()
  | [s] -> emit_final_statement env s
  | s::b ->
    let i1 = emit_stmt env s in
    let i2 = emit_final_statements env b in
    gather [i1; i2]
