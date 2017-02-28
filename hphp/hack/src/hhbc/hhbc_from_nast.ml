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

module A = Ast
module N = Nast
module H = Hhbc_ast
module TC = Hhas_type_constraint
module SN = Naming_special_names

(* These are the three flavors of value that can live on the stack:
 *   C = cell
 *   R = ref
 *   A = classref
 *)
type flavor =
  | Flavor_C
  | Flavor_R
  | Flavor_A

(* The various from_X functions below take some kind of AST (expression,
 * statement, etc.) and produce what is logically a sequence of instructions.
 * This could simply be represented by a list, but then we would need to
 * use an accumulator to avoid the quadratic complexity associated with
 * repeated appending to a list. Instead, we simply build a tree of
 * instructions which can easily be flattened at the end.
 *)
type instr_seq =
| Instr_list of instruct list
| Instr_concat of instr_seq list

(* Some helper constructors *)
let instr x = Instr_list [x]
let instrs x = Instr_list x
let gather x = Instr_concat x
let empty = Instr_list []

let instr_iterinit iter_id label value =
  instr (IIterator (IterInit (iter_id, label, value)))
let instr_iterinitk id label key value =
  instr (IIterator (IterInitK (id, label, key, value)))
let instr_iternext id label value =
  instr (IIterator (IterNext (id, label, value)))
let instr_iternextk id label key value =
  instr (IIterator (IterNextK (id, label, key, value)))
let instr_iterfree id =
  instr (IIterator (IterFree id))

let instr_jmp label = instr (IContFlow (Jmp label))
let instr_jmpz label = instr (IContFlow (JmpZ label))
let instr_jmpnz label = instr (IContFlow (JmpNZ label))
let instr_label label = instr (ILabel label)
let instr_label_catch label = instr (IExceptionLabel (label, CatchL))
let instr_continue level = instr (IContFlow (Continue level))
let instr_break level = instr (IContFlow (Break level))
let instr_unwind = instr (IContFlow Unwind)
let instr_false = instr (ILitConst False)
let instr_true = instr (ILitConst True)
let instr_eq = instr (IOp Eq)
let instr_retc = instr (IContFlow RetC)
let instr_null = instr (ILitConst Null)
let instr_catch = instr (IMisc Catch)
let instr_dup = instr (IBasic Dup)
let instr_instanceofd s = instr (IOp (InstanceOfD s))

let instr_setl_named local =
  instr (IMutator (SetL (Local_named local)))
let instr_setl_unnamed local =
  instr (IMutator (SetL (Local_unnamed local)))
let instr_unsetl_unnamed local =
  instr (IMutator (UnsetL (Local_unnamed local)))
let instr_cgetl2_pipe = instr (IGet (CGetL2 (Local_pipe)))
let instr_popc = instr (IBasic PopC)
let instr_throw = instr (IContFlow Throw)

let instr_add_elemc = instr (ILitConst (AddElemC))
let instr_add_new_elemc = instr (ILitConst (AddNewElemC))

(* Functions on instr_seq that correspond to existing Core.List functions *)
module InstrSeq = struct
  let rec flat_map instrseq ~f =
    let flat_map_list items ~f = Core.List.bind items f in
    match instrseq with
    | Instr_list instrl ->
      let mapper instr =
        match instr with
        | ITryFault(l, instrl1, instrl2) ->
          [ ITryFault(l, flat_map_list instrl1 f,
            flat_map_list instrl2 f) ]
        | ITryCatch(x, instrl) ->
          [ ITryCatch(x, flat_map_list instrl f) ]
        | _ ->
          f instr in
      Instr_list (flat_map_list instrl ~f:mapper)
    | Instr_concat instrseql ->
      Instr_concat (List.map instrseql (flat_map ~f))

  let rec fold_left instrseq ~f ~init =
    match instrseq with
    | Instr_list instrl ->
      List.fold_left instrl ~f:(fun init instr ->
        match instr with
        | ITryFault(_, instrl1, instrl2) ->
          List.fold_left instrl2 ~f ~init:(List.fold_left instrl1 ~f ~init)
        | ITryCatch(_, instrl) ->
          List.fold_left instrl ~f ~init
        | _ -> f init instr
        ) ~init
    | Instr_concat instrseql ->
      List.fold_left instrseql
        ~f:(fun init instrseq -> fold_left instrseq ~f ~init)
        ~init

  let rec filter_map instrseq ~f =
    match instrseq with
    | Instr_list instrl ->
      Instr_list (List.filter_map instrl ~f:(fun instr ->
        match instr with
        | ITryFault(l, instrl1, instrl2) ->
          Some (ITryFault(l, List.filter_map instrl1 f,
            List.filter_map instrl2 f))
        | ITryCatch(x, instrl) ->
          Some (ITryCatch(x, List.filter_map instrl f))
        | _ ->
          f instr
        ))
    | Instr_concat instrseql ->
      Instr_concat (List.map instrseql (filter_map ~f))

  let map instrseq ~f = filter_map instrseq ~f:(fun x -> Some (f x))

end

(* Could write this in terms of InstrSeq.fold_left *)
let rec instr_seq_to_list_aux sl result =
  match sl with
  | [] -> List.rev result
  | s::sl ->
    match s with
    | Instr_list instrl ->
      instr_seq_to_list_aux sl (List.rev_append instrl result)
    | Instr_concat sl' -> instr_seq_to_list_aux (sl' @ sl) result

let instr_seq_to_list t = instr_seq_to_list_aux [t] []

let instr_try_fault_no_catch fault_label try_body fault_body =
  let try_body = instr_seq_to_list try_body in
  let fault_body = instr_seq_to_list fault_body in
  let fl = IExceptionLabel (fault_label, FaultL) in
  instr (ITryFault (fault_label, try_body, fl :: fault_body))

let instr_try_catch catch_label try_body =
  let try_body = instr_seq_to_list try_body in
  instr (ITryCatch (catch_label, try_body))

(* Emit a comment in lieu of instructions for not-yet-implemented features *)
let emit_nyi description =
  instr (IComment ("NYI: " ^ description))

(* Strict binary operations; assumes that operands are already on stack *)
let from_binop op =
  match op with
  | A.Plus -> instr (IOp AddO)
  | A.Minus -> instr (IOp SubO)
  | A.Star -> instr (IOp MulO)
  | A.Slash -> instr (IOp Div)
  | A.Eqeq -> instr (IOp Eq)
  | A.EQeqeq -> instr (IOp Same)
  | A.Starstar -> instr (IOp Pow)
  | A.Diff -> instr (IOp Neq)
  | A.Diff2 -> instr (IOp NSame)
  | A.Lt -> instr (IOp Lt)
  | A.Lte -> instr (IOp Lte)
  | A.Gt -> instr (IOp Gt)
  | A.Gte -> instr (IOp Gte)
  | A.Dot -> instr (IOp Concat)
  | A.Amp -> instr (IOp BitAnd)
  | A.Bar -> instr (IOp BitOr)
  | A.Ltlt -> instr (IOp Shl)
  | A.Gtgt -> instr (IOp Shr)
  | A.Percent -> instr (IOp Mod)
  | A.Xor -> instr (IOp BitXor)
  | A.Eq _ -> emit_nyi "Eq"
  | A.AMpamp
  | A.BArbar ->
    failwith "short-circuiting operator cannot be generated as a simple binop"

let binop_to_eqop op =
  match op with
  | A.Plus -> Some PlusEqualO
  | A.Minus -> Some MinusEqualO
  | A.Star -> Some MulEqualO
  | A.Slash -> Some DivEqual
  | A.Starstar -> Some PowEqual
  | A.Amp -> Some AndEqual
  | A.Bar -> Some OrEqual
  | A.Xor -> Some XorEqual
  | A.Ltlt -> Some SlEqual
  | A.Gtgt -> Some SrEqual
  | A.Percent -> Some ModEqual
  | A.Dot -> Some ConcatEqual
  | _ -> None

let unop_to_incdec_op op =
  match op with
  | A.Uincr -> Some PreIncO
  | A.Udecr -> Some PreDecO
  | A.Upincr -> Some PostIncO
  | A.Updecr -> Some PostDecO
  | _ -> None

(* TODO: there are lots of ways of specifying the same type in a cast.
 * Sort this out!
 *)
let emit_cast (_, hint_) =
  match hint_ with
  | A.Happly((_, id), []) when id = SN.Typehints.int ->
    instr (IOp CastInt)
  | A.Happly((_, id), []) when id = SN.Typehints.bool ->
    instr (IOp CastBool)
  | A.Happly((_, id), []) when id = SN.Typehints.string ->
    instr (IOp CastString)
  | A.Happly((_, id), []) when id = SN.Typehints.object_cast ->
    instr (IOp CastObject)
  | A.Happly((_, id), []) when id = SN.Typehints.array ->
    instr (IOp CastArray)
  | A.Happly((_, id), []) when id = SN.Typehints.float ->
    instr (IOp CastDouble)
  | _ -> emit_nyi "cast type"

let rec from_expr expr =
  (* Note that this takes an Ast.expr, not a Nast.expr. *)
  match snd expr with
  | A.Float (_, litstr) ->
    instr (ILitConst (Double (float_of_string litstr)))
  | A.String (_, litstr) ->
    instr (ILitConst (String litstr))
  | A.Int (_, litstr) ->
    (* TODO deal with integer out of range *)
    instr (ILitConst (Int (Int64.of_string litstr)))
  | A.Null -> instr (ILitConst Null)
  | A.False -> instr (ILitConst False)
  | A.True -> instr (ILitConst True)
  | A.Lvar (_, x) when x = SN.SpecialIdents.this -> instr (IMisc This)
  | A.Lvar (_, x) -> instr (IGet (CGetL (Local_named x)))
  | A.Class_const ((_, cid), (_, id)) when id = SN.Members.mClass ->
    instr (ILitConst (String cid))
  | A.Unop (op, e) ->
    emit_unop op e
  | A.Binop (A.AMpamp, e1, e2) ->
    emit_logical_and e1 e2
  | A.Binop (A.BArbar, e1, e2) ->
    emit_logical_or e1 e2
  | A.Binop (A.Eq obop, e1, e2) ->
    emit_assignment obop e1 e2
  (* Special case to make use of CGetL2 *)
  | A.Binop (op, (_, A.Lvar (_, x)), e) ->
    gather [from_expr e; instr (IGet (CGetL2 (Local_named x))); from_binop op]
  | A.Binop (op, e1, e2) ->
    gather [from_expr e2; from_expr e1; from_binop op]
  | A.Pipe (e1, e2) ->
    emit_pipe e1 e2
  | A.Dollardollar ->
    instr_cgetl2_pipe (* This will get rewritten into a temp local *)
  | A.InstanceOf (e1, (_, A.Id (_, id))) ->
    gather [from_expr e1; instr (IOp (InstanceOfD id))]
  | A.InstanceOf (e1, e2) ->
    gather [from_expr e1; from_expr e2; instr (IOp InstanceOf)]
  | A.NullCoalesce(e1, e2) ->
    let end_label = Label.get_next_label () in
    gather [
      emit_quiet_expr e1;
      instr (IBasic Dup);
      instr (IIsset (IsTypeC OpNull));
      instr (IOp Not);
      instr (IContFlow (JmpNZ end_label));
      instr (IBasic PopC);
      from_expr e2;
      instr (ILabel end_label);
    ]
  | A.Cast(hint, e) ->
    gather [from_expr e; emit_cast hint]
  | A.Eif (etest, Some etrue, efalse) ->
    let false_label = Label.get_next_label () in
    let end_label = Label.get_next_label () in
    gather [
      from_expr etest;
      instr (IContFlow (JmpZ false_label));
      from_expr etrue;
      instr (IContFlow (Jmp end_label));
      instr (ILabel false_label);
      from_expr efalse;
      instr (ILabel end_label)
    ]
  | A.Eif (etest, None, efalse) ->
    let end_label = Label.get_next_label () in
    gather [
      from_expr etest;
      instr (IBasic Dup);
      instr (IContFlow (JmpNZ end_label));
      instr (IBasic PopC);
      from_expr efalse;
      instr (ILabel end_label)
    ]
  | A.Expr_list es -> gather @@ List.map es ~f:from_expr
  | A.Call _ ->
    let instrs, flavor = emit_flavored_expr expr in
    gather [
      instrs;
      (* If the instruction has produced a ref then unbox it *)
      if flavor = Flavor_R then instr (IBasic UnboxR) else empty
    ]

  | A.New ((_, A.Id (_, id)), args, uargs) ->
      let nargs = List.length args + List.length uargs in
      gather [
        instr (ICall (FPushCtorD (nargs, id)));
        emit_args_and_call args uargs;
        instr (IBasic PopR)
      ]
  | A.Array es ->
    (* We need to make sure everything is literal to use static construction *)
    let all_literal = List.for_all es
      ~f:(function A.AFvalue e -> is_literal e
                 | A.AFkvalue (k,v) -> is_literal k && is_literal v)
    in
    if all_literal then begin
    let a_label = Label.get_next_data_label () in
    (* Arrays can either contains values or key/value pairs *)
    let _, es =
      List.fold_left
        es
        ~init:(0, [])
        ~f:(fun (index, l) x ->
              (index + 1, match x with
              | A.AFvalue e ->
                literal_from_expr e :: Int (Int64.of_int index) :: l
              | A.AFkvalue (k,v) ->
                literal_from_expr v :: literal_from_expr k :: l)
            )
    in
    instr (ILitConst (Array (a_label, "a", List.rev es)));
    end else begin
    (* If there is at least one associative element,
     * then it will be a NewMixedArray otherwise NewPackedArray *)
    let is_mixed_array =
      List.exists es ~f:(function A.AFkvalue _ -> true | _ -> false)
    in
    let count = List.length es in
    if is_mixed_array then begin
      gather @@
        (instr @@ ILitConst (NewPackedArray count)) ::
        (List.map es
          ~f:(function A.AFvalue e ->
                        gather [from_expr e; instr_add_new_elemc]
                     | A.AFkvalue (k, v) ->
                        gather [from_expr k; from_expr v; instr_add_elemc]))
    end else begin
      gather [
        gather @@
        List.map es
          ~f:(function A.AFvalue e -> from_expr e | _ -> failwith "impossible");
        instr @@ ILitConst (NewPackedArray count);
      ]
    end
    end
  | _ ->
    emit_nyi "expression"

and emit_pipe e1 e2 =
  (* TODO: We need a local generator, like a label generator.
  For now, just use the label generator. *)
  (* TODO: Unnamed locals should be codegen'd with a leading _ *)
  let temp = Label.get_next_label () in
  let fault_label = Label.get_next_label () in
  let rewrite_dollardollar e =
    let rewriter i =
      match i with
      | IGet (CGetL2 (Local_pipe)) ->
        IGet (CGetL2 (Local_unnamed temp))
      | _ -> i in
    InstrSeq.map e ~f:rewriter in
  gather [
    from_expr e1;
    instr_setl_unnamed temp;
    instr_popc;
    instr_try_fault_no_catch
      fault_label
      (* try block *)
      (rewrite_dollardollar (from_expr e2))
      (* fault block *)
      (gather [
        instr_unsetl_unnamed temp;
        instr_unwind ]);
    instr_unsetl_unnamed temp
  ]

and emit_logical_and e1 e2 =
  let left_is_false = Label.get_next_label () in
  let right_is_true = Label.get_next_label () in
  let its_done = Label.get_next_label () in
  gather [
    from_expr e1;
    instr_jmpz left_is_false;
    from_expr e2;
    instr_jmpnz right_is_true;
    instr_label left_is_false;
    instr_false;
    instr_jmp its_done;
    instr_label right_is_true;
    instr_true;
    instr_label its_done ]

and emit_logical_or e1 e2 =
  let its_true = Label.get_next_label () in
  let its_done = Label.get_next_label () in
  gather [
    from_expr e1;
    instr_jmpnz its_true;
    from_expr e2;
    instr_jmpnz its_true;
    instr_false;
    instr_jmp its_done;
    instr_label its_true;
    instr_true;
    instr_label its_done ]

and emit_quiet_expr (_, expr_ as expr) =
  match expr_ with
  | A.Lvar (_, x) ->
    instr (IGet (CGetQuietL (Local_named x)))
  | _ ->
    from_expr expr

and emit_arg i ((_, expr_) as e) =
  match expr_ with
  | A.Lvar (_, x) ->
    instr (ICall (FPassL (Param_unnamed i, Local_named x)))
  | _ ->
    let instrs, flavor = emit_flavored_expr e in
    gather [
      instrs;
      instr (ICall (if flavor = Flavor_R then FPassR (Param_unnamed i)
                      else FPassCE (Param_unnamed i)));
    ]

and emit_pop flavor =
  match flavor with
  | Flavor_R -> instr (IBasic PopR)
  | Flavor_C -> instr (IBasic PopC)
  | Flavor_A -> instr (IBasic PopA)

and emit_ignored_expr e =
  let instrs, flavor = emit_flavored_expr e in
  gather [
    instrs;
    emit_pop flavor;
  ]

(* Emit code to construct the argument frame and then make the call *)
and emit_args_and_call args uargs =
  let all_args = args @ uargs in
  let nargs = List.length all_args in
  gather [
    gather (List.mapi all_args emit_arg);
    if uargs = []
    then instr (ICall (FCall nargs))
    else instr (ICall (FCallUnpack nargs))
  ]

and emit_call_lhs (_, expr_) nargs =
  match expr_ with
  | A.Obj_get (obj, (_, A.Id (_, id)), null_flavor) ->
    gather [
      from_expr obj;
      instr (ICall (FPushObjMethodD (nargs, id, null_flavor)));
    ]

  | A.Class_const ((_, cid), (_, id)) when cid = SN.Classes.cStatic ->
    instrs [
      ILitConst (String id);
      IMisc LateBoundCls;
      ICall (FPushClsMethod nargs);
    ]

  | A.Class_const ((_, cid), (_, id)) ->
    instr (ICall (FPushClsMethodD (nargs, id, cid)))

  | A.Id (_, id) ->
    instr (ICall (FPushFuncD (nargs, id)))

  | _ ->
    emit_nyi "call lhs expression"

and emit_call (_, expr_ as expr) args uargs =
  let nargs = List.length args + List.length uargs in
  match expr_ with
  | A.Id (_, id) when id = SN.SpecialFunctions.echo ->
    let instrs = gather @@ List.mapi args begin fun i arg ->
         gather [
           from_expr arg;
           instr (IOp Print);
           if i = nargs-1 then empty else emit_pop Flavor_C
         ] end in
    instrs, Flavor_C

  | A.Obj_get _ | A.Class_const _ | A.Id _ ->
    gather [
      emit_call_lhs expr nargs;
      emit_args_and_call args uargs;
    ], Flavor_R

  | _ ->
    emit_nyi "call expression", Flavor_C

(* Emit code for an expression that might leave a cell or reference on the
 * stack. Return which flavor it left.
 *)
and emit_flavored_expr (_, expr_ as expr) =
  match expr_ with
  | A.Call (e, args, uargs) ->
    emit_call e args uargs
  | _ ->
    from_expr expr, Flavor_C

and is_literal expr =
  match snd expr with
  | A.Float _
  | A.String _
  | A.Int _
  | A.Null
  | A.False
  | A.True -> true
  | _ -> false

and literal_from_expr expr =
  match snd expr with
  | A.Float (_, litstr) -> Double (float_of_string litstr)
  | A.String (_, litstr) -> String litstr
  | A.Int (_, litstr) -> Int (Int64.of_string litstr)
  | A.Null -> Null
  | A.False -> False
  | A.True -> True
  | _ -> failwith "literal_from_expr - NYI"

and literal_from_named_expr expr =
  match snd expr with
  | N.Float (_, litstr) -> Double (float_of_string litstr)
  | N.String (_, litstr) -> String litstr
  | N.Int (_, litstr) -> Int (Int64.of_string litstr)
  | N.Null -> Null
  | N.False -> False
  | N.True -> True
  (* TODO: HHVM does not allow <<F(2+2)>> in an attribute, but Hack does, and
   this seems reasonable to allow. Right now this will crash if given an
   expression rather than a literal in here.  In particular, see what unary
   minus does; do we allow it on a literal int? We should. *)
  | _ -> failwith (Printf.sprintf
    "Expected a literal expression in literal_from_named_expr, got %s"
    (N.expr_to_string (snd expr)))

and literals_from_named_exprs_with_index exprs =
  List.rev @@ snd @@
  List.fold_left
    exprs
    ~init:(0, [])
    ~f:(fun (index, l) e ->
      (index + 1, literal_from_named_expr e :: Int (Int64.of_int index) :: l))

(* Emit code for an l-value, returning instructions and the location that
 * must be set. For now, this is just a local. *)
and emit_lval (_, expr_) =
  match expr_ with
  | A.Lvar id -> empty, Local_named (snd id)
  | _ -> emit_nyi "lval expression", Local_unnamed 0

and emit_assignment obop e1 e2 =
  let instrs1, lval = emit_lval e1 in
  let instrs2 = from_expr e2 in
  gather [instrs1; instrs2;
    match obop with
    | None -> instr (IMutator (SetL lval))
    | Some bop ->
      match binop_to_eqop bop with
      | None -> emit_nyi "op-assignment"
      | Some eqop -> instr (IMutator (SetOpL (lval, eqop)))
    ]

and emit_unop op e =
  match op with
  | A.Utild -> gather [from_expr e; instr (IOp BitNot)]
  | A.Unot -> gather [from_expr e; instr (IOp Not)]
  | A.Uplus -> gather
    [instr (ILitConst (Int (Int64.zero)));
    from_expr e;
    instr (IOp AddO)]
  | A.Uminus -> gather
    [instr (ILitConst (Int (Int64.zero)));
    from_expr e;
    instr (IOp SubO)]
  | A.Uincr | A.Udecr | A.Upincr | A.Updecr ->
    let instrs, lval = emit_lval e in
    gather [instrs;
      match unop_to_incdec_op op with
      | None -> emit_nyi "incdec"
      | Some incdec_op -> instr (IMutator (IncDecL (lval, incdec_op)))]
  | A.Uref ->
    emit_nyi "references"

and from_exprs exprs =
  gather (List.map exprs from_expr)

and from_stmt st =
  match st with
  | A.Expr expr ->
    emit_ignored_expr expr
  | A.Return (_, None) ->
    gather [
      instr_null;
      instr_retc;
    ]
  | A.Return (_,  Some expr) ->
    gather [
      from_expr expr;
      instr_retc;
    ]
  | A.Block b -> from_stmts b
  | A.If (condition, consequence, alternative) ->
    from_if condition (A.Block consequence) (A.Block alternative)
  | A.While (e, b) ->
    from_while e (A.Block b)
  | A.Break _ ->
    instr_break 1 (* TODO: Break takes an argument *)
  | A.Continue _ ->
    instr_continue 1 (* TODO: Continue takes an argument *)
  | A.Do (b, e) ->
    from_do (A.Block b) e
  | A.For (e1, e2, e3, b) ->
    from_for e1 e2 e3 (A.Block b)
  | A.Throw e ->
    gather [
      from_expr e;
      instr (IContFlow Throw);
    ]
  | A.Try (try_block, catch_list, finally_block) ->
    if catch_list <> [] && finally_block <> [] then
      from_stmt (A.Try([A.Try (try_block, catch_list, [])], [], finally_block))
    else if catch_list <> [] then
      from_try_catch (A.Block try_block) catch_list
    else
      from_try_finally (A.Block try_block) (A.Block finally_block)

  | A.Switch (e, cl) ->
    from_switch e cl
  | A.Foreach (collection, await_pos, iterator, block) ->
    from_foreach (await_pos <> None) collection iterator
      (A.Block block)
  | A.Static_var _ ->
    emit_nyi "statement"
  (* TODO: What do we do with unsafe? *)
  | A.Unsafe
  | A.Fallthrough
  | A.Noop -> empty

and from_if condition consequence alternative =
  let alternative_label = Label.get_next_label () in
  let done_label = Label.get_next_label () in
  gather [
    from_expr condition;
    instr_jmpz alternative_label;
    from_stmt consequence;
    instr_jmp done_label;
    instr_label alternative_label;
    from_stmt alternative;
    instr_label done_label;
  ]

and rewrite_continue_break instrs cont_label break_label =
  (* PHP supports multi-level continue and break; the level must be a compile-
  time constant.

  TODO: Right now we only supports one-level continue and break, but this code
  is designed to handle multi-level continue and break.  Write tests for
  multi-level continue and break.

  TODO: This rewriting will be more complex once we support continue and break
  inside try-finally blocks.

  Suppose we are generating code for:

  do {
    do {
      if (a)
        break 2;
      if (b)
        break;
    } while (c);
    if (d) break;
  } while (e);

When we codegen the nested do-loop we will first generate the inner do loop:

L1:  a
     JmpZ L2
     Break 2
L2:  b
     JmpZ L3
     Break 1
L3:  c
     JmpNZ L1
L4:

Then we run a pass over it which changes all the Break 1 to Jmp L4, and
all the Break 2 to Break 1:

L1:  a
     JmpZ L2
     Break 1
L2:  b
     JmpZ L3
     Jmp L4
L3:  c
     JmpNZ L1
L4:

Then we keep on generating code for the outer do-loop:

L1:  a
     JmpZ L2
     Break 1
L2:  b
     JmpZ L3
     Jmp L4
L3:  c
     JmpNZ L1
L4:  d
     JmpZ L5
     Break 1
L5:  e
     JmpNZ L1
L6:

And then we run another rewriting pass over the whole thing which turns
the Break 1s into Jmp L6:

L1:  a
     JmpZ L2
     Jmp L6
L2:  b
     JmpZ L3
     Jmp L4
L3:  c
     JmpNZ L1
L4:  d
     JmpZ L5
     Jmp L6
L5:  e
     JmpNZ L1
L6:

And we're done. We've rewritten all the multi-level break and continues into
unconditional jumps to the right place. *)

  let rewriter i =
    match i with
    | IContFlow (Continue level) when level > 1 ->
      IContFlow (Continue (level - 1))
    | IContFlow (Continue _) ->
      IContFlow (Jmp cont_label)
    | IContFlow (Break level) when level > 1 ->
      IContFlow (Break (level - 1))
    | IContFlow (Break _) ->
      IContFlow (Jmp break_label)
    | _ -> i in
  InstrSeq.map instrs ~f:rewriter

and from_while e b =
  let break_label = Label.get_next_label () in
  let cont_label = Label.get_next_label () in
  let start_label = Label.get_next_label () in
  let cond = from_expr e in
  (* TODO: This is *bizarre* codegen for a while loop.
  It would be better to generate this as
  instr_label continue_label;
  from_expr e;
  instr_jmpz break_label;
  body;
  instr_jmp continue_label;
  instr_label break_label;
  *)
  let instrs = gather [
    cond;
    instr_jmpz break_label;
    instr_label start_label;
    from_stmt b;
    instr_label cont_label;
    cond;
    instr_jmpnz start_label;
    instr_label break_label;
  ] in
  rewrite_continue_break instrs cont_label break_label

and from_do b e =
  let cont_label = Label.get_next_label () in
  let break_label = Label.get_next_label () in
  let start_label = Label.get_next_label () in
  let instrs = gather [
    instr_label start_label;
    from_stmt b;
    instr_label cont_label;
    from_expr e;
    instr_jmpnz start_label;
    instr_label break_label;
  ] in
  rewrite_continue_break instrs cont_label break_label

and from_for e1 e2 e3 b =
  let break_label = Label.get_next_label () in
  let cont_label = Label.get_next_label () in
  let start_label = Label.get_next_label () in
  let cond = from_expr e2 in
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
  let instrs = gather [
    emit_ignored_expr e1;
    cond;
    instr_jmpz break_label;
    instr_label start_label;
    from_stmt b;
    instr_label cont_label;
    emit_ignored_expr e3;
    cond;
    instr_jmpnz start_label;
    instr_label break_label;
  ] in
  rewrite_continue_break instrs cont_label break_label

and from_switch e cl =
  let switched = from_expr e in
  let end_label = Label.get_next_label () in
  (* "continue" in a switch in PHP has the same semantics as break! *)
  let cl = List.map cl ~f:from_case in
  let bodies = gather @@ List.map cl ~f:snd in
  let init = gather @@ List.map cl
    ~f: begin fun x ->
          let (e_opt, l) = fst x in
          match e_opt with
          | None -> instr_jmp l
          | Some e ->
            gather [from_expr e; switched; instr_eq; instr_jmpnz l]
        end
  in
  let instrs = gather [
    init;
    bodies;
    instr_label end_label;
  ] in
  rewrite_continue_break instrs end_label end_label

and from_catch end_label ((_, id1), (_, id2), b) =
    let next_catch = Label.get_next_label () in
    gather [
      instr_dup;
      instr_instanceofd id1;
      instr_jmpz next_catch;
      instr_setl_named id2;
      instr_popc;
      from_stmt (A.Block b);
      instr_jmp end_label;
      instr_label next_catch;
    ]

and from_catches catch_list end_label =
  gather (List.map catch_list ~f:(from_catch end_label))

and from_try_catch try_block catch_list =
  let end_label = Label.get_next_label () in
  let catch_label = Label.get_next_label () in
  let try_body = gather [
    from_stmt try_block;
    instr_jmp end_label;
  ] in
  gather [
    instr_try_catch catch_label try_body;
    instr_label_catch catch_label;
    instr_catch;
    from_catches catch_list end_label;
    instr_throw;
    instr_label end_label;
  ]

and from_try_finally try_block finally_block =
  let l0 = Label.get_next_label () in
  let try_body = from_stmt try_block in
  let try_body = gather [try_body; instr_jmp l0;] in
  let try_body = rewrite_continue_break try_body l0 l0 in
  let finally_body = from_stmt finally_block in
  let fault_body = gather [
      (* TODO: What are these unnamed locals? *)
      instr_unsetl_unnamed 0;
      instr_unsetl_unnamed 0;
      finally_body;
      instr_unwind;
    ] in
  let fault_label = Label.get_next_label () in
  gather [
    instr_try_fault_no_catch fault_label try_body fault_body;
    instr_label l0;
    finally_body;
  ]

and get_foreach_lvalue e =
  match e with
  | A.Lvar (_, x) -> H.Local_named x
  | _ -> failwith "foreach codegen does not support arbitrary lvalues yet"

and get_foreach_key_value iterator =
  match iterator with
  | A.As_kv ((_, k), (_, v)) ->
    (Some (get_foreach_lvalue k)), get_foreach_lvalue v
  | A.As_v (_, v) ->
    None, get_foreach_lvalue v

and from_foreach _has_await collection iterator block =
  (* TODO: await *)
  (* TODO: generate .numiters based on maximum nesting depth *)
  (* TODO: We need an iterator generator. Use the label generator for now. *)
  (* TODO: We need to be able to process arbitrary lvalues in the key, value
     pair. This will require writing a preamble into the block, in the general
     case. For now we just support locals. *)
  let iterator_number = Label.get_next_label () in
  let fault_label = Label.get_next_label () in
  let loop_continue_label = Label.get_next_label () in
  let loop_break_label = Label.get_next_label () in
  let (k, v) = get_foreach_key_value iterator in
  let init, next = match k with
  | Some k ->
    let init = instr_iterinitk iterator_number loop_break_label k v in
    let cont = instr_iternextk iterator_number loop_continue_label k v in
    init, cont
  | None ->
    let init = instr_iterinit iterator_number loop_break_label v in
    let cont = instr_iternext iterator_number loop_continue_label v in
    init, cont in
  let body = from_stmt block in
  let instrs = gather [
    from_expr collection;
    init;
    instr_try_fault_no_catch
      fault_label
      (* try body *)
      (gather [
        instr_label loop_continue_label;
        body;
        next
      ])
      (* fault body *)
      (gather [
        instr_iterfree iterator_number;
        instr_unwind ]);
    instr_label loop_break_label
  ] in
  rewrite_continue_break instrs loop_continue_label loop_break_label

and from_stmts stl =
  let results = List.map stl from_stmt in
  gather results

and from_case c =
  let l = Label.get_next_label () in
  let b = match c with
    | A.Default b
    | A.Case (_, b) ->
        from_stmt (A.Block b)
  in
  let e = match c with
    | A.Case (e, _) -> Some e
    | _ -> None
  in
  (e, l), gather [instr_label l; b]

let fmt_prim x =
  match x with
  | N.Tvoid   -> "HH\\void"
  | N.Tint    -> "HH\\int"
  | N.Tbool   -> "HH\\bool"
  | N.Tfloat  -> "HH\\float"
  | N.Tstring -> "HH\\string"
  | N.Tnum    -> "HH\\num"
  | N.Tresource -> "HH\\resource"
  | N.Tarraykey -> "HH\\arraykey"
  | N.Tnoreturn -> "HH\\noreturn"

(* TODO *)
let fmt_name s = s

let extract_shape_fields smap =
  let get_pos =
    function A.SFlit (p, _) | A.SFclass_const ((p, _), _) -> p in
  List.sort (fun (k1, _) (k2, _) -> Pos.compare (get_pos k1) (get_pos k2))
    (Nast.ShapeMap.elements smap)

(* Produce the "userType" bit of the annotation *)
let rec fmt_hint (_, h) =
  match h with
  | N.Hany -> ""
  | N.Hmixed -> "HH\\mixed"
  | N.Hthis -> "HH\\this"
  | N.Hprim prim -> fmt_prim prim
  | N.Habstr s -> fmt_name s

  | N.Happly ((_, s), []) -> fmt_name s
  | N.Happly ((_, s), args) ->
    fmt_name s ^ "<" ^ String.concat ", " (List.map args fmt_hint) ^ ">"

  | N.Hfun (args, _, ret) ->
    "(function (" ^ String.concat ", " (List.map args fmt_hint) ^ "): " ^
      fmt_hint ret ^ ")"

  | N.Htuple hs ->
    "(" ^ String.concat ", " (List.map hs fmt_hint) ^ ")"

  | N.Haccess (h, accesses) ->
    fmt_hint h ^ "::" ^ String.concat "::" (List.map accesses snd)

  | N.Hoption t -> "?" ^ fmt_hint t

  | N.Harray (None, None) -> "array"
  | N.Harray (Some h, None) -> "array<" ^ fmt_hint h ^ ">"
  | N.Harray (Some h1, Some h2) ->
    "array<" ^ fmt_hint h1 ^ ", " ^ fmt_hint h2 ^ ">"
  | N.Harray _ -> failwith "bogus array"
  | N.Hshape smap ->
    let fmt_field = function
      | A.SFlit (_, s) -> "'" ^ s ^ "'"
      | A.SFclass_const ((_, s1), (_, s2)) -> fmt_name s1 ^ "::" ^ s2
    in
    let format_shape_field (k, { N.sfi_hint; _ }) =
      fmt_field k ^ "=>" ^ fmt_hint sfi_hint in
    let shape_fields =
      List.map ~f:format_shape_field (extract_shape_fields smap) in
    "HH\\shape(" ^ String.concat ", " shape_fields ^ ")"

let rec hint_to_type_constraint tparams (_, h) =
match h with
| N.Hany | N.Hmixed | N.Hfun (_, _, _) | N.Hthis
| N.Hprim N.Tvoid ->
  TC.make None []

| N.Hprim prim ->
  let tc_name = Some (fmt_prim prim) in
  let tc_flags = [TC.HHType] in
  TC.make tc_name tc_flags

| N.Haccess (_, _) ->
  let tc_name = Some "" in
  let tc_flags = [TC.HHType; TC.ExtendedHint; TC.TypeConstant] in
  TC.make tc_name tc_flags

(* Need to differentiate between type params and classes *)
| N.Habstr s | N.Happly ((_, s), _) ->
  if List.mem tparams s then
    let tc_name = Some "" in
    let tc_flags = [TC.HHType; TC.ExtendedHint; TC.TypeVar] in
    TC.make tc_name tc_flags
  else
    let tc_name = Some s in
    let tc_flags = [TC.HHType] in
    TC.make tc_name tc_flags

(* Shapes and tuples are just arrays *)
| N.Harray (_, _) | N.Hshape _ |  N.Htuple _ ->
  let tc_name = Some "array" in
  let tc_flags = [TC.HHType] in
  TC.make tc_name tc_flags

| N.Hoption t ->
  let tc = hint_to_type_constraint tparams t in
  let tc_name = TC.name tc in
  let tc_flags = TC.flags tc in
  let tc_flags = List.dedup
    ([TC.Nullable; TC.HHType; TC.ExtendedHint] @ tc_flags) in
  TC.make tc_name tc_flags

let hint_to_type_info ~always_extended tparams h =
  let tc = hint_to_type_constraint tparams h in
  let tc_name = TC.name tc in
  let tc_flags = TC.flags tc in
  let tc_flags =
    if always_extended && tc_name != None
    then List.dedup (TC.ExtendedHint :: tc_flags)
    else tc_flags in
  let type_info_user_type = Some (fmt_hint h) in
  let type_info_type_constraint = TC.make tc_name tc_flags in
  Hhas_type_info.make type_info_user_type type_info_type_constraint

let hints_to_type_infos ~always_extended tparams hints =
  let mapper hint = hint_to_type_info always_extended tparams hint in
  List.map hints mapper

let from_param tparams p =
  let param_name = p.N.param_name in
  let param_type_info = Option.map p.N.param_hint
    (hint_to_type_info ~always_extended:false tparams) in
  Hhas_param.make param_name param_type_info

let has_type_constraint ti =
  match ti with
  | Some ti when (Hhas_type_info.has_type_constraint ti) -> true
  | _ -> false

let emit_method_prolog params =
  gather (List.filter_map params (fun p ->
    let param_type_info = Hhas_param.type_info p in
    let param_name = Hhas_param.name p in
    if has_type_constraint param_type_info
    then Some (instr (IMisc (VerifyParamType (Param_named param_name))))
    else None))

let tparams_to_strings tparams =
  List.map tparams (fun (_, (_, s), _) -> s)

(* TODO: This function is grossly inefficient,
 * I wonder how we can do it better *)
let rec emit_fault_instructions stmt_instrs =
  let emit_fault_instruction_aux = function
    | ITryFault (_, il, fault) ->
      gather [emit_fault_instructions @@ instrs il; instrs fault;]
    | ITryCatch (_, il) -> emit_fault_instructions @@ instrs il
    | _ -> empty
  in
  let instr_list = instr_seq_to_list stmt_instrs in
  gather @@ List.map instr_list ~f:emit_fault_instruction_aux

let verify_returns body =
  let rewriter i =
    match i with
    | IContFlow RetC ->
      [ (IMisc VerifyRetTypeC); (IContFlow RetC) ]
    | _ -> [ i ] in
  InstrSeq.flat_map body ~f:rewriter

let from_body tparams params ret b =
  let params = List.map params (from_param tparams) in
  let return_type_info = Option.map ret
    (hint_to_type_info ~always_extended:true tparams) in
  let stmt_instrs = from_stmts b.N.fub_ast in
  let stmt_instrs =
    if has_type_constraint return_type_info then
      verify_returns stmt_instrs
    else
      stmt_instrs in
  let ret_instrs =
    match List.last b.N.fub_ast with Some (A.Return _) -> empty | _ ->
    gather [instr_null; instr_retc]
  in
  let fault_instrs = emit_fault_instructions stmt_instrs in
  let body_instrs = gather [
    emit_method_prolog params;
    stmt_instrs;
    ret_instrs;
    fault_instrs;
  ] in
  body_instrs, params, return_type_info

(* In order to be efficient,
 * keep around a set to check for membership and a list for order *)
let rec extract_decl_vars set l body_instrs =
  let add_if_not_exists set l s =
    if SSet.mem s set then (set, l) else (SSet.add s set, s::l)
  in
  let extract_decl_vars_aux set l = function
    | IMutator (SetL (Local_named s)) -> add_if_not_exists set l s
    | ITryFault (_, il, _)
    | ITryCatch (_, il) -> extract_decl_vars set l il
    | _ -> (set, l)
  in
  List.fold_left
    body_instrs
    ~init:(set, l)
    ~f:(fun (set, l) i -> extract_decl_vars_aux set l i)

(* Create a map from defined labels to instruction offset *)
let create_label_to_offset_map instrseq =
  snd @@
  InstrSeq.fold_left instrseq ~init:(0, IMap.empty) ~f:(fun (i, m) instr ->
    begin match instr with
    | ILabel l -> (i,     IMap.add l i m)
    | _        -> (i + 1, m)
    end)

let lookup_def l defs =
  match IMap.get l defs with
  | None -> failwith "lookup_def: label missing"
  | Some ix -> ix

(* Generate new labels for all labels referenced in instructions, in the
 * order that the instructions appear. Also record which labels are
 *)
let create_label_ref_map defs instrseq =
  snd @@
  InstrSeq.fold_left instrseq ~init:(0, (ISet.empty, IMap.empty))
    ~f:(fun acc instr ->
    let process_ref (n, (used, refs) as acc) l =
      let ix = lookup_def l defs in
      match IMap.get ix refs with
      (* This is the first time we've seen a reference to a label for
       * this instruction offset, so generate a new label *)
      | None -> (n + 1, (ISet.add l used, IMap.add ix n refs))
      (* We already have a label for this instruction offset *)
      | Some _ -> acc in
    match instr with
    | IIterator (IterInit (_, l, _))
    | IIterator (IterInitK (_, l, _, _))
    | IIterator (WIterInit (_, l, _))
    | IIterator (WIterInitK (_, l, _, _))
    | IIterator (MIterInit (_, l, _))
    | IIterator (MIterInitK (_, l, _, _))
    | IIterator (IterNext (_, l, _))
    | IIterator (IterNextK (_, l, _, _))
    | IIterator (WIterNext (_, l, _))
    | IIterator (WIterNextK (_, l, _, _))
    | IIterator (MIterNext (_, l, _))
    | IIterator (MIterNextK (_, l, _, _))
    | IContFlow (Jmp l | JmpNS l | JmpZ l | JmpNZ l) ->
      process_ref acc l
    | IContFlow (Switch (_, _, ls)) ->
      List.fold_left ls ~f:process_ref ~init:acc
    | IContFlow (SSwitch pairs) ->
      List.fold_left pairs ~f:(fun acc (_,l) -> process_ref acc l) ~init:acc
    (* TODO: other uses of rel_offset in instructions *)
    | _ -> acc)

(* Relabel the instruction sequence so that
 *   1. No instruction is preceded by more than one label
 *   2. No label is unreferenced
 *   3. References to labels occur in strict label number order, starting at 0
 *)
let relabel_instrseq instrseq =
  let defs = create_label_to_offset_map instrseq in
  let used, refs = create_label_ref_map defs instrseq in
  let relabel l =
    let ix = lookup_def l defs in
    match IMap.get ix refs with
    | None -> failwith "relabel_instrseq: offset not in refs"
    | Some l' -> l' in
  InstrSeq.filter_map instrseq ~f:(fun instr ->
    match instr with
    | IContFlow (Jmp l)   -> Some (IContFlow (Jmp (relabel l)))
    | IContFlow (JmpNS l) -> Some (IContFlow (JmpNS (relabel l)))
    | IContFlow (JmpZ l)  -> Some (IContFlow (JmpZ (relabel l)))
    | IContFlow (JmpNZ l) -> Some (IContFlow (JmpNZ (relabel l)))
    | IContFlow (Switch (k, n, ll)) ->
      Some (IContFlow (Switch (k, n, List.map ll relabel)))
    | IContFlow (SSwitch pairs) ->
      Some (IContFlow (SSwitch
        (List.map pairs (fun (id,l) -> (id, relabel l)))))
    (* TODO: other uses of rel_offset in instructions *)
    | ILabel l ->
      if ISet.mem l used then
        let ix = lookup_def l defs in
        begin match IMap.get ix refs with
        | Some l' -> Some (ILabel l')
        | None -> None
        end
      else None
    | _ -> Some instr)


let from_fun_ : Nast.fun_ -> Hhas_function.t option =
  fun nast_fun ->
  Label.reset_label ();
  let function_name = Litstr.to_string @@ snd nast_fun.Nast.f_name in
  match nast_fun.N.f_body with
  | N.NamedBody _ ->
    None
  | N.UnnamedBody b ->
    let tparams = tparams_to_strings nast_fun.N.f_tparams in
    let body_instrs, function_params, function_return_type =
      from_body tparams nast_fun.N.f_params nast_fun.N.f_ret b in
    let body_instrs = relabel_instrseq body_instrs in
    let function_body = instr_seq_to_list body_instrs in
    let (_, function_decl_vars) =
      extract_decl_vars SSet.empty [] function_body
    in
    (* In order to be efficient,
     * we cons everything, hence the need to reverse *)
    let function_decl_vars = List.rev function_decl_vars in
    Some (Hhas_function.make
      function_name
      function_params
      function_return_type
      function_body
      function_decl_vars)

let from_functions nast_functions =
  Core.List.filter_map nast_functions from_fun_

let from_attribute_base attribute_name arguments =
  let attribute_arguments = literals_from_named_exprs_with_index arguments in
  Hhas_attribute.make attribute_name attribute_arguments

let from_attribute : Nast.user_attribute -> Hhas_attribute.t =
  fun nast_attr ->
  let attribute_name = Litstr.to_string @@ snd nast_attr.Nast.ua_name in
  from_attribute_base attribute_name nast_attr.Nast.ua_params

let from_attributes nast_attributes =
  (* The list of attributes is reversed in the Nast. *)
  List.map (List.rev nast_attributes) from_attribute

let from_method : bool -> Nast.class_ -> Nast.method_ -> Hhas_method.t option =
  fun method_is_static nast_class nast_method ->
  let class_tparams = tparams_to_strings (fst nast_class.N.c_tparams) in
  let method_name = Litstr.to_string @@ snd nast_method.Nast.m_name in
  let method_is_abstract = nast_method.Nast.m_abstract in
  (* TODO: An abstract method must generate
.method [protected abstract] <"HH\\void" N  > protected_abstract_method() {
String "Cannot call abstract method AbstractClass::protected_abstract_method()"
Fatal RuntimeOmitFrame
} *)
  let method_is_final = nast_method.Nast.m_final in
  let method_is_private = nast_method.Nast.m_visibility = Nast.Private in
  let method_is_protected = nast_method.Nast.m_visibility = Nast.Protected in
  let method_is_public = nast_method.Nast.m_visibility = Nast.Public in
  let method_attributes = from_attributes nast_method.Nast.m_user_attributes in
  match nast_method.N.m_body with
  | N.NamedBody _ ->
    None
  | N.UnnamedBody b ->
    let method_tparams = tparams_to_strings nast_method.N.m_tparams in
    let tparams = class_tparams @ method_tparams in
    let body_instrs, method_params, method_return_type =
      from_body tparams nast_method.N.m_params nast_method.N.m_ret b in
    let method_body = instr_seq_to_list body_instrs in
    let m = Hhas_method.make
      method_attributes
      method_is_protected
      method_is_public
      method_is_private
      method_is_static
      method_is_final
      method_is_abstract
      method_name
      method_params
      method_return_type
      method_body in
    Some m

let from_methods method_is_static nast_class nast_methods =
  Core.List.filter_map nast_methods (from_method method_is_static nast_class)

let is_interface nast_class =
  nast_class.N.c_kind = Ast.Cinterface

let default_constructor nast_class =
  let method_attributes = [] in
  let method_name = "86ctor" in
  let method_body = instr_seq_to_list (gather [
    instr (ILitConst Null);
    instr (IContFlow RetC)
  ]) in
  let method_is_abstract = is_interface nast_class in
  let method_is_final = false in
  let method_is_private = false in
  let method_is_protected = false in
  let method_is_public = true in
  let method_is_static = false in
  let method_params = [] in
  let method_return_type = None in
  Hhas_method.make
    method_attributes
    method_is_protected
    method_is_public
    method_is_private
    method_is_static
    method_is_final
    method_is_abstract
    method_name
    method_params
    method_return_type
    method_body

let add_constructor nast_class class_methods =
  match nast_class.N.c_constructor with
  | None -> (default_constructor nast_class) :: class_methods
  | Some nast_ctor ->
    begin
      match from_method false nast_class nast_ctor with
      | None -> class_methods
      | Some m -> m :: class_methods
    end

let from_extends tparams extends =
  (* TODO: This prints out "extends <"\\Mammal" "\\Mammal" hh_type >"
  instead of "extends Mammal" -- figure out how to have it produce the
  simpler form in this clause.
  *)
  match extends with
  | [] -> None
  | h :: _ -> Some (hint_to_type_info ~always_extended:false tparams h)

let from_implements tparams implements =
  (* TODO: This prints out "implements <"\\IFoo" "\\IFoo" hh_type >"
  instead of "implements IFoo" -- figure out how to have it produce the
  simpler form in this clause.
  *)
  hints_to_type_infos ~always_extended:false tparams implements

let from_property property_is_static class_var =
  (* TODO: xhp, type, initializer *)
  (* TODO: Hack allows a property to be marked final, which is nonsensical.
  HHVM does not allow this.  Fix this in the Hack parser? *)
  let property_name = Litstr.to_string @@ snd class_var.N.cv_id in
  let property_is_private = class_var.N.cv_visibility = N.Private in
  let property_is_protected = class_var.N.cv_visibility = N.Protected in
  let property_is_public = class_var.N.cv_visibility = N.Public in
  Hhas_property.make
    property_is_private
    property_is_protected
    property_is_public
    property_is_static
    property_name

let from_properties property_is_static class_vars =
  List.map class_vars (from_property property_is_static)

let from_constant (_hint, name, const_init) =
  (* The type hint is omitted. *)
  match const_init with
  | None -> None (* Abstract constants are omitted *)
  | Some _init ->
    (* TODO: Deal with the initializer *)
    let constant_name = Litstr.to_string @@ snd name in
    Some (Hhas_constant.make constant_name)

let from_constants nast_constants =
  Core.List.filter_map nast_constants from_constant

let from_type_constant nast_type_constant =
  match nast_type_constant.N.c_tconst_type with
  | None -> None (* Abstract type constants are omitted *)
  | Some _init ->
    (* TODO: Deal with the initializer *)
    let type_constant_name = Litstr.to_string @@
      snd nast_type_constant.N.c_tconst_name in
    Some (Hhas_type_constant.make type_constant_name)

let from_type_constants nast_type_constants =
  Core.List.filter_map nast_type_constants from_type_constant

let from_class : Nast.class_ -> Hhas_class.t =
  fun nast_class ->
  let class_attributes = from_attributes nast_class.N.c_user_attributes in
  let class_name = Litstr.to_string @@ snd nast_class.N.c_name in
  let class_is_trait = nast_class.N.c_kind = Ast.Ctrait in
  let class_is_enum = nast_class.N.c_kind = Ast.Cenum in
  let class_is_interface = is_interface nast_class in
  let class_is_abstract = nast_class.N.c_kind = Ast.Cabstract in
  let class_is_final =
    nast_class.N.c_final || class_is_trait || class_is_enum in
  let tparams = tparams_to_strings (fst nast_class.N.c_tparams) in
  let class_base =
    if class_is_interface then None
    else from_extends tparams nast_class.N.c_extends in
  let implements =
    if class_is_interface then nast_class.N.c_extends
    else nast_class.N.c_implements in
  let class_implements = from_implements tparams implements in
  let instance_methods = from_methods false nast_class nast_class.N.c_methods in
  let static_methods =
    from_methods true nast_class nast_class.N.c_static_methods in
  let class_methods = instance_methods @ static_methods in
  let class_methods = add_constructor nast_class class_methods in
  let instance_properties = from_properties false nast_class.N.c_vars in
  let static_properties = from_properties true nast_class.N.c_static_vars in
  let class_properties = static_properties @ instance_properties in
  let class_constants = from_constants nast_class.N.c_consts in
  let class_type_constants = from_type_constants nast_class.N.c_typeconsts in
  (* TODO: uses, xhp attr uses, xhp category *)
  Hhas_class.make
    class_attributes
    class_base
    class_implements
    class_name
    class_is_final
    class_is_abstract
    class_is_interface
    class_is_trait
    class_is_enum
    class_methods
    class_properties
    class_constants
    class_type_constants

let from_classes nast_classes =
  Core.List.map nast_classes from_class
