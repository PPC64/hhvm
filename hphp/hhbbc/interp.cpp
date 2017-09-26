/*
   +----------------------------------------------------------------------+
   | HipHop for PHP                                                       |
   +----------------------------------------------------------------------+
   | Copyright (c) 2010-present Facebook, Inc. (http://www.facebook.com)  |
   +----------------------------------------------------------------------+
   | This source file is subject to version 3.01 of the PHP license,      |
   | that is bundled with this package in the file LICENSE, and is        |
   | available through the world-wide-web at the following url:           |
   | http://www.php.net/license/3_01.txt                                  |
   | If you did not receive a copy of the PHP license and are unable to   |
   | obtain it through the world-wide-web, please send a note to          |
   | license@php.net so we can mail you a copy immediately.               |
   +----------------------------------------------------------------------+
*/
#include "hphp/hhbbc/interp.h"

#include <algorithm>
#include <vector>
#include <string>
#include <iterator>

#include <folly/Optional.h>

#include "hphp/util/trace.h"
#include "hphp/runtime/base/array-init.h"
#include "hphp/runtime/base/collections.h"
#include "hphp/runtime/base/static-string-table.h"
#include "hphp/runtime/base/tv-arith.h"
#include "hphp/runtime/base/tv-comparisons.h"
#include "hphp/runtime/base/tv-conversions.h"
#include "hphp/runtime/vm/runtime.h"
#include "hphp/runtime/vm/unit-util.h"

#include "hphp/runtime/ext/hh/ext_hh.h"

#include "hphp/hhbbc/analyze.h"
#include "hphp/hhbbc/bc.h"
#include "hphp/hhbbc/cfg.h"
#include "hphp/hhbbc/class-util.h"
#include "hphp/hhbbc/eval-cell.h"
#include "hphp/hhbbc/index.h"
#include "hphp/hhbbc/interp-state.h"
#include "hphp/hhbbc/optimize.h"
#include "hphp/hhbbc/representation.h"
#include "hphp/hhbbc/type-builtins.h"
#include "hphp/hhbbc/type-ops.h"
#include "hphp/hhbbc/type-system.h"
#include "hphp/hhbbc/unit-util.h"

#include "hphp/hhbbc/interp-internal.h"

namespace HPHP { namespace HHBBC {

//////////////////////////////////////////////////////////////////////

namespace {

const StaticString s_Throwable("__SystemLib\\Throwable");
const StaticString s_empty("");
const StaticString s_construct("__construct");
const StaticString s_86ctor("86ctor");
const StaticString s_PHP_Incomplete_Class("__PHP_Incomplete_Class");
const StaticString s_IMemoizeParam("HH\\IMemoizeParam");
const StaticString s_getInstanceKey("getInstanceKey");
const StaticString s_Closure("Closure");
const StaticString s_byRefWarn("Only variables should be passed by reference");
const StaticString s_byRefError("Only variables can be passed by reference");
const StaticString s_trigger_error("trigger_error");
}

//////////////////////////////////////////////////////////////////////

void impl_vec(ISS& env, bool reduce, std::vector<Bytecode>&& bcs) {
  std::vector<Bytecode> currentReduction;
  if (!options.StrengthReduce) reduce = false;

  env.flags.wasPEI          = false;
  env.flags.canConstProp    = true;
  env.flags.effectFree      = true;

  for (auto it = begin(bcs); it != end(bcs); ++it) {
    assert(env.flags.jmpDest == NoBlockId &&
           "you can't use impl with branching opcodes before last position");

    auto const wasPEI = env.flags.wasPEI;
    auto const canConstProp = env.flags.canConstProp;
    auto const effectFree = env.flags.effectFree;

    FTRACE(3, "    (impl {}\n", show(env.ctx.func, *it));
    env.flags.wasPEI          = true;
    env.flags.canConstProp    = false;
    env.flags.effectFree      = false;
    env.flags.strengthReduced = folly::none;
    default_dispatch(env, *it);

    if (env.flags.strengthReduced) {
      if (instrFlags(env.flags.strengthReduced->back().op) & TF) {
        unreachable(env);
      }
      if (reduce) {
        std::move(begin(*env.flags.strengthReduced),
                  end(*env.flags.strengthReduced),
                  std::back_inserter(currentReduction));
      }
    } else {
      if (instrFlags(it->op) & TF) {
        unreachable(env);
      }
      auto applyConstProp = [&] {
        if (env.flags.effectFree && !env.flags.wasPEI) return;
        auto stk = env.state.stack.end();
        for (auto i = it->numPush(); i--; ) {
          --stk;
          if (!is_scalar(stk->type)) return;
        }
        env.flags.effectFree = true;
        env.flags.wasPEI = false;
      };
      if (reduce) {
        auto added = false;
        if (env.flags.canConstProp) {
          if (env.collect.propagate_constants) {
            if (env.collect.propagate_constants(*it, env.state,
                                                currentReduction)) {
              added = true;
              env.flags.canConstProp = false;
              env.flags.wasPEI = false;
              env.flags.effectFree = true;
            }
          } else {
            applyConstProp();
          }
        }
        if (!added) currentReduction.push_back(std::move(*it));
      } else if (env.flags.canConstProp) {
        applyConstProp();
      }
    }

    // If any of the opcodes in the impl list said they could throw,
    // then the whole thing could throw.
    env.flags.wasPEI = env.flags.wasPEI || wasPEI;
    env.flags.canConstProp = env.flags.canConstProp && canConstProp;
    env.flags.effectFree = env.flags.effectFree && effectFree;
    if (env.state.unreachable) break;
  }

  if (reduce) {
    env.flags.strengthReduced = std::move(currentReduction);
  } else {
    env.flags.strengthReduced = folly::none;
  }
}

namespace interp_step {

void in(ISS& env, const bc::Nop&)  { effect_free(env); }
void in(ISS& env, const bc::DiscardClsRef& op) {
  nothrow(env);
  takeClsRefSlot(env, op.slot);
}
void in(ISS& env, const bc::PopC&) {
  nothrow(env);
  if (!could_run_destructor(popC(env))) effect_free(env);
}
void in(ISS& env, const bc::PopU&) { effect_free(env); popU(env); }
void in(ISS& env, const bc::PopV&) { nothrow(env); popV(env); }
void in(ISS& env, const bc::PopR&) {
  auto t = topT(env, 0);
  if (t.subtypeOf(TCell)) {
    return reduce(env, bc::UnboxRNop {}, bc::PopC {});
  }
  nothrow(env);
  popR(env);
}

void in(ISS& env, const bc::EntryNop&) { effect_free(env); }

void in(ISS& env, const bc::Dup& /*op*/) {
  effect_free(env);
  auto equiv = topStkEquiv(env);
  auto val = popC(env);
  push(env, val, equiv);
  push(env, std::move(val), StackDupId);
}

void in(ISS& env, const bc::AssertRATL& op) {
  mayReadLocal(env, op.loc1);
  effect_free(env);
}

void in(ISS& env, const bc::AssertRATStk&) {
  effect_free(env);
}

void in(ISS& env, const bc::BreakTraceHint&) { effect_free(env); }

void in(ISS& env, const bc::Box&) {
  effect_free(env);
  popC(env);
  push(env, TRef);
}

void in(ISS& env, const bc::BoxR&) {
  effect_free(env);
  if (topR(env).subtypeOf(TRef)) {
    return reduce(env, bc::BoxRNop {});
  }
  popR(env);
  push(env, TRef);
}

void in(ISS& env, const bc::Unbox&) {
  effect_free(env);
  popV(env);
  push(env, TInitCell);
}

void in(ISS& env, const bc::UnboxR&) {
  auto const t = topR(env);
  if (t.subtypeOf(TInitCell)) return reduce(env, bc::UnboxRNop {});
  nothrow(env);
  popT(env);
  push(env, TInitCell);
}

void in(ISS& env, const bc::RGetCNop&) { effect_free(env); }

void in(ISS& env, const bc::CGetCUNop&) {
  effect_free(env);
  auto const t = popCU(env);
  push(env, remove_uninit(t));
}

void in(ISS& env, const bc::UGetCUNop&) {
  effect_free(env);
  popCU(env);
  push(env, TUninit);
}

void in(ISS& env, const bc::UnboxRNop&) {
  effect_free(env);
  constprop(env);
  auto t = popR(env);
  if (!t.subtypeOf(TInitCell)) t = TInitCell;
  push(env, std::move(t));
}

void in(ISS& env, const bc::BoxRNop&) {
  effect_free(env);
  auto t = popR(env);
  if (!t.subtypeOf(TRef)) t = TRef;
  push(env, std::move(t));
}

void in(ISS& env, const bc::Null&) {
  effect_free(env);
  push(env, TInitNull);
}

void in(ISS& env, const bc::NullUninit&) {
  effect_free(env);
  push(env, TUninit);
}

void in(ISS& env, const bc::True&) {
  effect_free(env);
  push(env, TTrue);
}

void in(ISS& env, const bc::False&) {
  effect_free(env);
  push(env, TFalse);
}

void in(ISS& env, const bc::Int& op) {
  effect_free(env);
  push(env, ival(op.arg1));
}

void in(ISS& env, const bc::Double& op) {
  effect_free(env);
  push(env, dval(op.dbl1));
}

void in(ISS& env, const bc::String& op) {
  effect_free(env);
  push(env, sval(op.str1));
}

void in(ISS& env, const bc::Array& op) {
  assert(op.arr1->isPHPArray());
  effect_free(env);
  push(env, aval(op.arr1));
}

void in(ISS& env, const bc::Vec& op) {
  assert(op.arr1->isVecArray());
  effect_free(env);
  push(env, vec_val(op.arr1));
}

void in(ISS& env, const bc::Dict& op) {
  assert(op.arr1->isDict());
  effect_free(env);
  push(env, dict_val(op.arr1));
}

void in(ISS& env, const bc::Keyset& op) {
  assert(op.arr1->isKeyset());
  effect_free(env);
  push(env, keyset_val(op.arr1));
}

void in(ISS& env, const bc::NewArray& op) {
  push(env, op.arg1 == 0 ?
       effect_free(env), aempty() : counted_aempty());
}

void in(ISS& env, const bc::NewDictArray& op) {
  push(env, op.arg1 == 0 ?
       effect_free(env), dict_empty() : counted_dict_empty());
}

void in(ISS& env, const bc::NewMixedArray& op) {
  push(env, op.arg1 == 0 ?
       effect_free(env), aempty() : counted_aempty());
}

void in(ISS& env, const bc::NewPackedArray& op) {
  auto elems = std::vector<Type>{};
  elems.reserve(op.arg1);
  for (auto i = uint32_t{0}; i < op.arg1; ++i) {
    elems.push_back(std::move(topC(env, op.arg1 - i - 1)));
  }
  discard(env, op.arg1);
  push(env, arr_packed(std::move(elems)));
  constprop(env);
}

void in(ISS& env, const bc::NewStructArray& op) {
  auto map = MapElems{};
  for (auto it = op.keys.end(); it != op.keys.begin(); ) {
    map.emplace_front(make_tv<KindOfPersistentString>(*--it), popC(env));
  }
  push(env, arr_map(std::move(map)));
  constprop(env);
}

void in(ISS& env, const bc::NewVecArray& op) {
  auto elems = std::vector<Type>{};
  elems.reserve(op.arg1);
  for (auto i = uint32_t{0}; i < op.arg1; ++i) {
    elems.push_back(std::move(topC(env, op.arg1 - i - 1)));
  }
  discard(env, op.arg1);
  constprop(env);
  push(env, vec(std::move(elems)));
}

void in(ISS& env, const bc::NewKeysetArray& op) {
  assert(op.arg1 > 0);
  auto map = MapElems{};
  auto ty = TBottom;
  auto useMap = true;
  auto bad = false;
  for (auto i = uint32_t{0}; i < op.arg1; ++i) {
    auto k = disect_strict_key(popC(env));
    if (k.type == TBottom) {
      bad = true;
      useMap = false;
    }
    if (useMap) {
      if (auto const v = k.tv()) {
        map.emplace_front(*v, k.type);
      } else {
        useMap = false;
      }
    }
    ty |= std::move(k.type);
  }
  if (useMap) {
    push(env, keyset_map(std::move(map)));
    constprop(env);
  } else if (!bad) {
    push(env, keyset_n(ty));
  } else {
    unreachable(env);
    push(env, TBottom);
  }
}

void in(ISS& env, const bc::NewLikeArrayL& op) {
  locAsCell(env, op.loc1);
  push(env, counted_aempty());
}

void in(ISS& env, const bc::AddElemC& /*op*/) {
  auto const v = popC(env);
  auto const k = popC(env);

  auto const outTy = [&] (Type ty) ->
    folly::Optional<std::pair<Type,ThrowMode>> {
    if (ty.subtypeOf(TArr)) {
      return array_set(std::move(ty), k, v);
    }
    if (ty.subtypeOf(TDict)) {
      return dict_set(std::move(ty), k, v);
    }
    return folly::none;
  }(popC(env));

  if (!outTy) {
    return push(env, union_of(TArr, TDict));
  }

  if (outTy->first.subtypeOf(TBottom)) {
    unreachable(env);
  } else if (outTy->second == ThrowMode::None) {
    nothrow(env);
    if (any(env.collect.opts & CollectionOpts::TrackConstantArrays)) {
      constprop(env);
    }
  }
  push(env, std::move(outTy->first));
}

void in(ISS& env, const bc::AddElemV& /*op*/) {
  popV(env); popC(env);
  auto const ty = popC(env);
  auto const outTy =
    ty.subtypeOf(TArr) ? TArr
    : ty.subtypeOf(TDict) ? TDict
    : union_of(TArr, TDict);
  push(env, outTy);
}

void in(ISS& env, const bc::AddNewElemC&) {
  auto v = popC(env);

  auto const outTy = [&] (Type ty) -> folly::Optional<Type> {
    if (ty.subtypeOf(TArr)) {
      return array_newelem(std::move(ty), std::move(v)).first;
    }
    if (ty.subtypeOf(TVec)) {
      return vec_newelem(std::move(ty), std::move(v)).first;
    }
    if (ty.subtypeOf(TKeyset)) {
      return keyset_newelem(std::move(ty), std::move(v)).first;
    }
    return folly::none;
  }(popC(env));

  if (!outTy) {
    return push(env, TInitCell);
  }

  if (outTy->subtypeOf(TBottom)) {
    unreachable(env);
  } else {
    if (any(env.collect.opts & CollectionOpts::TrackConstantArrays)) {
      constprop(env);
    }
  }
  push(env, std::move(*outTy));
}

void in(ISS& env, const bc::AddNewElemV&) {
  popV(env);
  popC(env);
  push(env, TArr);
}

void in(ISS& env, const bc::NewCol& op) {
  auto const type = static_cast<CollectionType>(op.subop1);
  auto const name = collections::typeToString(type);
  push(env, objExact(env.index.builtin_class(name)));
}

void in(ISS& env, const bc::NewPair& /*op*/) {
  popC(env); popC(env);
  auto const name = collections::typeToString(CollectionType::Pair);
  push(env, objExact(env.index.builtin_class(name)));
}

void in(ISS& env, const bc::ColFromArray& op) {
  popC(env);
  auto const type = static_cast<CollectionType>(op.subop1);
  auto const name = collections::typeToString(type);
  push(env, objExact(env.index.builtin_class(name)));
}

void doCns(ISS& env, SString str, SString fallback)  {
  if (!options.HardConstProp) return push(env, TInitCell);

  auto t = env.index.lookup_constant(env.ctx, str, fallback);
  if (!t) {
    // There's no entry for this constant in the index. It must be
    // the first iteration, so we'll add a dummy entry to make sure
    // there /is/ something next time around.
    Cell val;
    val.m_type = kReadOnlyConstant;
    env.collect.cnsMap.emplace(str, val);
    t = TInitCell;
    // make sure we're re-analyzed
    env.collect.readsUntrackedConstants = true;
  } else if (t->strictSubtypeOf(TInitCell)) {
    // constprop will take care of nothrow *if* its a constant; and if
    // its not, we might trigger autoload.
    constprop(env);
  }
  push(env, std::move(*t));
}

void in(ISS& env, const bc::Cns& op)  { doCns(env, op.str1, nullptr); }
void in(ISS& env, const bc::CnsE& op) { doCns(env, op.str1, nullptr); }
void in(ISS& env, const bc::CnsU& op) { doCns(env, op.str1, op.str2); }

void in(ISS& env, const bc::ClsCns& op) {
  auto const& t1 = peekClsRefSlot(env, op.slot);
  if (is_specialized_cls(t1)) {
    auto const dcls = dcls_of(t1);
    if (dcls.type == DCls::Exact) {
      return reduce(env, bc::DiscardClsRef { op.slot },
                         bc::ClsCnsD { op.str1, dcls.cls.name() });
    }
  }
  takeClsRefSlot(env, op.slot);
  push(env, TInitCell);
}

void in(ISS& env, const bc::ClsCnsD& op) {
  if (auto const rcls = env.index.resolve_class(env.ctx, op.str2)) {
    auto t = env.index.lookup_class_constant(env.ctx, *rcls, op.str1);
    if (options.HardConstProp) constprop(env);
    push(env, std::move(t));
    return;
  }
  push(env, TInitCell);
}

void in(ISS& env, const bc::File&)   { effect_free(env); push(env, TSStr); }
void in(ISS& env, const bc::Dir&)    { effect_free(env); push(env, TSStr); }
void in(ISS& env, const bc::Method&) { effect_free(env); push(env, TSStr); }

void in(ISS& env, const bc::ClsRefName& op) {
  nothrow(env);
  takeClsRefSlot(env, op.slot);
  push(env, TSStr);
}

void concatHelper(ISS& env, uint32_t n) {
  uint32_t i = 0;
  StringData* result = nullptr;
  while (i < n) {
    auto const t = topC(env, i);
    auto const v = tv(t);
    if (!v) break;
    if (!isStringType(v->m_type)   &&
        v->m_type != KindOfNull    &&
        v->m_type != KindOfBoolean &&
        v->m_type != KindOfInt64   &&
        v->m_type != KindOfDouble) {
      break;
    }
    auto const cell = eval_cell_value([&] {
        auto const s = makeStaticString(
          result ?
          StringData::Make(tvAsCVarRef(&*v).toString().get(), result) :
          tvAsCVarRef(&*v).toString().get());
        return make_tv<KindOfString>(s);
      });
    if (!cell) break;
    result = cell->m_data.pstr;
    i++;
  }
  if (result && i >= 2) {
    std::vector<Bytecode> bcs(i, bc::PopC {});
    bcs.push_back(gen_constant(make_tv<KindOfString>(result)));
    if (i < n) {
      bcs.push_back(bc::ConcatN { n - i + 1 });
    }
    return reduce(env, std::move(bcs));
  }
  discard(env, n);
  push(env, TStr);
}

void in(ISS& env, const bc::Concat& /*op*/) {
  concatHelper(env, 2);
}

void in(ISS& env, const bc::ConcatN& op) {
  if (op.arg1 == 2) return reduce(env, bc::Concat {});
  concatHelper(env, op.arg1);
}

template <class Op, class Fun>
void arithImpl(ISS& env, const Op& /*op*/, Fun fun) {
  constprop(env);
  auto const t1 = popC(env);
  auto const t2 = popC(env);
  push(env, fun(t2, t1));
}

void in(ISS& env, const bc::Add& op)    { arithImpl(env, op, typeAdd); }
void in(ISS& env, const bc::Sub& op)    { arithImpl(env, op, typeSub); }
void in(ISS& env, const bc::Mul& op)    { arithImpl(env, op, typeMul); }
void in(ISS& env, const bc::Div& op)    { arithImpl(env, op, typeDiv); }
void in(ISS& env, const bc::Mod& op)    { arithImpl(env, op, typeMod); }
void in(ISS& env, const bc::Pow& op)    { arithImpl(env, op, typePow); }
void in(ISS& env, const bc::BitAnd& op) { arithImpl(env, op, typeBitAnd); }
void in(ISS& env, const bc::BitOr& op)  { arithImpl(env, op, typeBitOr); }
void in(ISS& env, const bc::BitXor& op) { arithImpl(env, op, typeBitXor); }
void in(ISS& env, const bc::AddO& op)   { arithImpl(env, op, typeAddO); }
void in(ISS& env, const bc::SubO& op)   { arithImpl(env, op, typeSubO); }
void in(ISS& env, const bc::MulO& op)   { arithImpl(env, op, typeMulO); }
void in(ISS& env, const bc::Shl& op)    { arithImpl(env, op, typeShl); }
void in(ISS& env, const bc::Shr& op)    { arithImpl(env, op, typeShr); }

void in(ISS& env, const bc::BitNot& /*op*/) {
  auto const t = popC(env);
  auto const v = tv(t);
  if (v) {
    constprop(env);
    auto cell = eval_cell([&] {
      auto c = *v;
      cellBitNot(c);
      return c;
    });
    if (cell) return push(env, std::move(*cell));
  }
  push(env, TInitCell);
}

namespace {

bool couldBeHackArr(Type t) {
  return t.couldBe(TVec) || t.couldBe(TDict) || t.couldBe(TKeyset);
}

template<bool NSame>
std::pair<Type,bool> resolveSame(ISS& env) {
  auto const l1 = topStkEquiv(env, 0);
  auto const t1 = topC(env, 0);
  auto const l2 = topStkEquiv(env, 1);
  auto const t2 = topC(env, 1);

  auto const mightWarn = [&] {
    // EvalHackArrCompatNotices will notice on === and !== between PHP arrays
    // and Hack arrays.
    if (!RuntimeOption::EvalHackArrCompatNotices) return false;
    if (t1.couldBe(TArr) && couldBeHackArr(t2)) return true;
    if (couldBeHackArr(t1) && t2.couldBe(TArr)) return true;
    return false;
  };

  auto const result = [&] {
    auto const v1 = tv(t1);
    auto const v2 = tv(t2);

    if (l1 == StackDupId ||
        (l1 <= MaxLocalId && l2 <= MaxLocalId &&
         (l1 == l2 || locsAreEquiv(env, l1, l2)))) {
      if (!t1.couldBe(TDbl) || !t2.couldBe(TDbl) ||
          (v1 && (v1->m_type != KindOfDouble || !std::isnan(v1->m_data.dbl))) ||
          (v2 && (v2->m_type != KindOfDouble || !std::isnan(v2->m_data.dbl)))) {
        return NSame ? TFalse : TTrue;
      }
    }

    if (v1 && v2) {
      if (auto r = eval_cell_value([&]{ return cellSame(*v2, *v1); })) {
        return r != NSame ? TTrue : TFalse;
      }
    }

    return NSame ? typeNSame(t1, t2) : typeSame(t1, t2);
  };

  return { result(), mightWarn() };
}

template<bool Negate>
void sameImpl(ISS& env) {
  auto pair = resolveSame<Negate>(env);
  discard(env, 2);

  if (!pair.second) {
    nothrow(env);
    constprop(env);
  }

  push(env, std::move(pair.first));
}

}

template<class Same, class JmpOp>
void group(ISS& env, const Same& same, const JmpOp& jmp) {

  auto bail = [&] { impl(env, same, jmp); };

  constexpr auto NSame = Same::op == Op::NSame;

  if (resolveSame<NSame>(env).first != TBool) return bail();

  auto const loc0 = topStkEquiv(env, 0);
  auto const loc1 = topStkEquiv(env, 1);
  if (loc0 == NoLocalId && loc1 == NoLocalId) return bail();

  auto const ty0 = topC(env, 0);
  auto const ty1 = topC(env, 1);
  auto const val0 = tv(ty0);
  auto const val1 = tv(ty1);

  if ((val0 && val1) ||
      (loc0 == NoLocalId && !val0 && ty1.subtypeOf(ty0)) ||
      (loc1 == NoLocalId && !val1 && ty0.subtypeOf(ty1))) {
    return bail();
  }

  auto isect = intersection_of(ty0, ty1);
  discard(env, 2);

  auto handle_same = [&] {
    // Currently dce uses equivalency to prove that something isn't
    // the last reference - so we can only assert equivalency here if
    // we know that won't be affected. Its irrelevant for uncounted
    // things, and for TObj and TRes, $x === $y iff $x and $y refer to
    // the same thing.
    if (loc0 <= MaxLocalId && loc1 <= MaxLocalId &&
        (ty0.subtypeOfAny(TOptObj, TOptRes) ||
         ty1.subtypeOfAny(TOptObj, TOptRes) ||
         (ty0.subtypeOf(TUnc) && ty1.subtypeOf(TUnc)))) {
      if (loc1 == StackDupId) {
        setStkLocal(env, loc0);
      } else {
        assertx(loc0 != loc1 && !locsAreEquiv(env, loc0, loc1));
        auto loc = loc0;
        while (true) {
          auto const other = findLocEquiv(env, loc);
          if (other == NoLocalId) break;
          killLocEquiv(env, loc);
          addLocEquiv(env, loc, loc1);
          loc = other;
        }
        addLocEquiv(env, loc, loc1);
      }
    }
    refineLocation(env, loc1 != NoLocalId ? loc1 : loc0, [&] (Type ty) {
      if (!ty.couldBe(TUninit) || !isect.couldBe(TNull)) {
        auto ret = intersection_of(std::move(ty), isect);
        return ty.subtypeOf(TUnc) ? ret : loosen_staticness(ret);
      }

      if (isect.subtypeOf(TNull)) {
        return ty.couldBe(TInitNull) ? TNull : TUninit;
      }

      return ty;
    });
  };

  auto handle_differ_side = [&] (LocalId location, const Type& ty) {
    if (ty.subtypeOf(TInitNull) || ty.strictSubtypeOf(TBool)) {
      refineLocation(env, location, [&] (Type t) {
          if (ty.subtypeOf(TNull)) {
            t = remove_uninit(std::move(t));
            if (is_opt(t)) t = unopt(std::move(t));
            return t;
          } else if (ty.strictSubtypeOf(TBool) && t.subtypeOf(TBool)) {
            return ty == TFalse ? TTrue : TFalse;
          }
          return t;
        });
    }
  };

  auto handle_differ = [&] {
    if (loc0 != NoLocalId) handle_differ_side(loc0, ty1);
    if (loc1 != NoLocalId) handle_differ_side(loc1, ty0);
  };

  auto const sameIsJmpTarget =
    (Same::op == Op::Same) == (JmpOp::op == Op::JmpNZ);

  auto save = env.state;
  sameIsJmpTarget ? handle_same() : handle_differ();
  env.propagate(jmp.target, &env.state);
  env.state = std::move(save);
  sameIsJmpTarget ? handle_differ() : handle_same();
}

void in(ISS& env, const bc::Same&)  { sameImpl<false>(env); }
void in(ISS& env, const bc::NSame&) { sameImpl<true>(env); }

template<class Fun>
void binOpBoolImpl(ISS& env, Fun fun) {
  auto const t1 = popC(env);
  auto const t2 = popC(env);
  auto const v1 = tv(t1);
  auto const v2 = tv(t2);
  if (v1 && v2) {
    if (auto r = eval_cell_value([&]{ return fun(*v2, *v1); })) {
      constprop(env);
      return push(env, *r ? TTrue : TFalse);
    }
  }
  // TODO_4: evaluate when these can throw, non-constant type stuff.
  push(env, TBool);
}

template<class Fun>
void binOpInt64Impl(ISS& env, Fun fun) {
  auto const t1 = popC(env);
  auto const t2 = popC(env);
  auto const v1 = tv(t1);
  auto const v2 = tv(t2);
  if (v1 && v2) {
    if (auto r = eval_cell_value([&]{ return ival(fun(*v2, *v1)); })) {
      constprop(env);
      return push(env, std::move(*r));
    }
  }
  // TODO_4: evaluate when these can throw, non-constant type stuff.
  push(env, TInt);
}

void in(ISS& env, const bc::Eq&) {
  auto rs = resolveSame<false>(env);
  if (rs.first == TTrue) {
    if (!rs.second) constprop(env);
    discard(env, 2);
    return push(env, TTrue);
  }
  binOpBoolImpl(env, [&] (Cell c1, Cell c2) { return cellEqual(c1, c2); });
}
void in(ISS& env, const bc::Neq&) {
  auto rs = resolveSame<false>(env);
  if (rs.first == TTrue) {
    if (!rs.second) constprop(env);
    discard(env, 2);
    return push(env, TFalse);
  }
  binOpBoolImpl(env, [&] (Cell c1, Cell c2) { return !cellEqual(c1, c2); });
}
void in(ISS& env, const bc::Lt&) {
  binOpBoolImpl(env, [&] (Cell c1, Cell c2) { return cellLess(c1, c2); });
}
void in(ISS& env, const bc::Gt&) {
  binOpBoolImpl(env, [&] (Cell c1, Cell c2) { return cellGreater(c1, c2); });
}
void in(ISS& env, const bc::Lte&) { binOpBoolImpl(env, cellLessOrEqual); }
void in(ISS& env, const bc::Gte&) { binOpBoolImpl(env, cellGreaterOrEqual); }

void in(ISS& env, const bc::Cmp&) {
  binOpInt64Impl(env, [&] (Cell c1, Cell c2) { return cellCompare(c1, c2); });
}

void in(ISS& env, const bc::Xor&) {
  binOpBoolImpl(env, [&] (Cell c1, Cell c2) {
    return cellToBool(c1) ^ cellToBool(c2);
  });
}

void castBoolImpl(ISS& env, const Type& t, bool negate) {
  nothrow(env);
  constprop(env);

  auto const e = emptiness(t);
  switch (e) {
    case Emptiness::Empty:
    case Emptiness::NonEmpty:
      return push(env, (e == Emptiness::Empty) == negate ? TTrue : TFalse);
    case Emptiness::Maybe:
      break;
  }

  push(env, TBool);
}

void in(ISS& env, const bc::Not&) {
  castBoolImpl(env, popC(env), true);
}

void in(ISS& env, const bc::CastBool&) {
  auto const t = topC(env);
  if (t.subtypeOf(TBool)) return reduce(env, bc::Nop {});
  castBoolImpl(env, popC(env), false);
}

void in(ISS& env, const bc::CastInt&) {
  constprop(env);
  auto const t = topC(env);
  if (t.subtypeOf(TInt)) return reduce(env, bc::Nop {});
  popC(env);
  // Objects can raise a warning about converting to int.
  if (!t.couldBe(TObj)) nothrow(env);
  if (auto const v = tv(t)) {
    auto cell = eval_cell([&] {
      return make_tv<KindOfInt64>(cellToInt(*v));
    });
    if (cell) return push(env, std::move(*cell));
  }
  push(env, TInt);
}

void castImpl(ISS& env, Type target, void(*fn)(TypedValue*)) {
  auto const t = topC(env);
  if (t.subtypeOf(target)) return reduce(env, bc::Nop {});
  popC(env);
  if (fn) {
    if (auto val = tv(t)) {
      if (auto result = eval_cell([&] { fn(&*val); return *val; })) {
        constprop(env);
        target = *result;
      }
    }
  }
  push(env, std::move(target));
}

void in(ISS& env, const bc::CastDouble&) {
  castImpl(env, TDbl, tvCastToDoubleInPlace);
}

void in(ISS& env, const bc::CastString&) {
  castImpl(env, TStr, tvCastToStringInPlace);
}

void in(ISS& env, const bc::CastArray&)  {
  castImpl(env, TArr, tvCastToArrayInPlace);
}

void in(ISS& env, const bc::CastObject&) { castImpl(env, TObj, nullptr); }

void in(ISS& env, const bc::CastDict&)   {
  castImpl(env, TDict, tvCastToDictInPlace);
}

void in(ISS& env, const bc::CastVec&)    {
  castImpl(env, TVec, tvCastToVecInPlace);
}

void in(ISS& env, const bc::CastKeyset&) {
  castImpl(env, TKeyset, tvCastToKeysetInPlace);
}

void in(ISS& env, const bc::CastVArray&)  {
  auto const t = popC(env);
  if (auto val = tv(t)) {
    auto result = eval_cell(
      [&] {
        tvCastToVArrayInPlace(&*val);
        return *val;
      }
    );
    if (result) {
      constprop(env);
      return push(env, std::move(*result));
    }
  }
  push(env, TArr);
}

void in(ISS& env, const bc::CastDArray&)  {
  castImpl(env, TArr, tvCastToDArrayInPlace);
}

void in(ISS& env, const bc::Print& /*op*/) {
  popC(env);
  push(env, ival(1));
}

void in(ISS& env, const bc::Clone& /*op*/) {
  auto val = popC(env);
  if (!val.subtypeOf(TObj)) {
    val = is_opt(val) ? unopt(std::move(val)) : TObj;
  }
  push(env, std::move(val));
}

void in(ISS& env, const bc::Exit&)  { popC(env); push(env, TInitNull); }
void in(ISS& env, const bc::Fatal&) { popC(env); }

void in(ISS& /*env*/, const bc::JmpNS&) {
  always_assert(0 && "blocks should not contain JmpNS instructions");
}

void in(ISS& /*env*/, const bc::Jmp&) {
  always_assert(0 && "blocks should not contain Jmp instructions");
}

template<bool Negate, class JmpOp>
void jmpImpl(ISS& env, const JmpOp& op) {
  nothrow(env);
  auto const location = topStkEquiv(env);
  auto const e = emptiness(popC(env));
  if (e == (Negate ? Emptiness::NonEmpty : Emptiness::Empty)) {
    jmp_setdest(env, op.target);
    env.propagate(op.target, &env.state);
    return;
  }

  if (e == (Negate ? Emptiness::Empty : Emptiness::NonEmpty)) {
    jmp_nevertaken(env);
    return;
  }

  if (next_real_block(*env.ctx.func, env.blk.fallthrough) ==
      next_real_block(*env.ctx.func, op.target)) {
    jmp_nevertaken(env);
    return;
  }

  if (location == NoLocalId) return env.propagate(op.target, &env.state);

  auto val = peekLocation(env, location);
  assertx(!val.couldBe(TRef)); // we shouldn't have an equivLoc if it was

  refineLocation(env, location,
                 Negate ? assert_nonemptiness : assert_emptiness,
                 op.target,
                 Negate ? assert_emptiness : assert_nonemptiness);
}

void in(ISS& env, const bc::JmpNZ& op) { jmpImpl<true>(env, op); }
void in(ISS& env, const bc::JmpZ& op)  { jmpImpl<false>(env, op); }

namespace {

template<class IsType, class JmpOp>
void isTypeHelper(ISS& env,
                  IsTypeOp typeOp, LocalId location,
                  const IsType& istype, const JmpOp& jmp) {

  if (typeOp == IsTypeOp::Scalar) return impl(env, istype, jmp);

  auto const val = istype.op == Op::IsTypeC ?
    topT(env) : locRaw(env, location);
  auto const testTy = type_of_istype(typeOp);
  if (!val.subtypeOf(TCell) || val.subtypeOf(testTy) || !val.couldBe(testTy)) {
    return impl(env, istype, jmp);
  }

  if (istype.op == Op::IsTypeC) {
    nothrow(env);
    popT(env);
  } else if (!locCouldBeUninit(env, location)) {
    nothrow(env);
  }

  auto const negate = jmp.op == Op::JmpNZ;
  auto const was_true = [&] (Type t) {
    if (testTy.subtypeOf(TUninit)) {
      return TUninit;
    }
    if (testTy.subtypeOf(TNull)) {
      return t.couldBe(TUninit) ?
        t.couldBe(TInitNull) ? TNull : TUninit : TInitNull;
    }
    if (is_opt(t)) {
      auto const unopted = unopt(t);
      if (unopted.subtypeOf(testTy)) return unopted;
    }
    return testTy;
  };
  auto const was_false = [&] (Type t) {
    if (testTy.subtypeOf(TUninit)) {
      return remove_uninit(t);
    }
    if (testTy.subtypeOf(TNull)) {
      t = remove_uninit(std::move(t));
      return is_opt(t) ? unopt(t) : t;
    }
    if (is_opt(t)) {
      if (unopt(t).subtypeOf(testTy)) return TInitNull;
    }
    return t;
  };

  auto const pre = [&] (Type t) {
    return negate ? was_true(std::move(t)) : was_false(std::move(t));
  };

  auto const post = [&] (Type t) {
    return negate ? was_false(std::move(t)) : was_true(std::move(t));
  };

  refineLocation(env, location, pre, jmp.target, post);
}

folly::Optional<Cell> staticLocHelper(ISS& env, LocalId l, Type init) {
  if (is_volatile_local(env.ctx.func, l)) return folly::none;
  unbindLocalStatic(env, l);
  setLocRaw(env, l, TRef);
  bindLocalStatic(env, l, std::move(init));
  if (!env.ctx.func->isMemoizeWrapper &&
      !env.ctx.func->isClosureBody &&
      env.collect.localStaticTypes.size() > l) {
    auto t = env.collect.localStaticTypes[l];
    if (auto v = tv(t)) {
      useLocalStatic(env, l);
      setLocRaw(env, l, t);
      return v;
    }
  }
  useLocalStatic(env, l);
  return folly::none;
}

// If the current function is a memoize wrapper, return the inferred return type
// of the function being wrapped.
Type memoizeImplRetType(ISS& env) {
  always_assert(env.ctx.func->isMemoizeWrapper);

  // Lookup the wrapped function. This should always resolve to a precise
  // function but we don't rely on it.
  auto const memo_impl_func = [&]{
    if (env.ctx.func->cls) {
      auto const clsTy = selfClsExact(env);
      return env.index.resolve_method(
        env.ctx,
        clsTy ? *clsTy : TCls,
        memoize_impl_name(env.ctx.func)
      );
    }
    return env.index.resolve_func(env.ctx, memoize_impl_name(env.ctx.func));
  }();

  // Infer the return type of the wrapped function, taking into account the
  // types of the parameters for context sensitive types.
  auto const numArgs = env.ctx.func->params.size();
  std::vector<Type> args{numArgs};
  for (auto i = LocalId{0}; i < numArgs; ++i) {
    args[i] = locAsCell(env, i);
  }

  auto retTy = env.index.lookup_return_type(
    CallContext { env.ctx, args },
    memo_impl_func
  );
  // Regardless of anything we know the return type will be an InitCell (this is
  // a requirement of memoize functions).
  if (!retTy.subtypeOf(TInitCell)) return TInitCell;
  return retTy;
}

/*
 * Propagate a more specific type to the taken/fall-through branches of a jmp
 * operation when the jmp is done because of a type test. Given a type `valTy`,
 * being tested against the type `testTy`, propagate `failTy` to the branch
 * representing test failure, and `testTy` to the branch representing test
 * success.
 */
template<class JmpOp>
void typeTestPropagate(ISS& env, Type valTy, Type testTy,
                       Type failTy, const JmpOp& jmp) {
  nothrow(env);
  auto const takenOnSuccess = jmp.op == Op::JmpNZ;

  if (valTy.subtypeOf(testTy) || failTy.subtypeOf(TBottom)) {
    push(env, std::move(valTy));
    if (takenOnSuccess) {
      jmp_setdest(env, jmp.target);
      env.propagate(jmp.target, &env.state);
    } else {
      jmp_nevertaken(env);
    }
    return;
  }
  if (!valTy.couldBe(testTy)) {
    push(env, failTy);
    if (takenOnSuccess) {
      jmp_nevertaken(env);
    } else {
      jmp_setdest(env, jmp.target);
      env.propagate(jmp.target, &env.state);
    }
    return;
  }

  push(env, std::move(takenOnSuccess ? testTy : failTy));
  env.propagate(jmp.target, &env.state);
  discard(env, 1);
  push(env, std::move(takenOnSuccess ? failTy : testTy));
}

}

// After a StaticLocCheck, we know the local is bound on the true path,
// and not changed on the false path.
template<class JmpOp>
void group(ISS& env, const bc::StaticLocCheck& slc, const JmpOp& jmp) {
  auto const takenOnInit = jmp.op == Op::JmpNZ;
  auto save = env.state;

  if (auto const v = staticLocHelper(env, slc.loc1, TBottom)) {
    return impl(env, slc, jmp);
  }

  if (env.collect.localStaticTypes.size() > slc.loc1 &&
      env.collect.localStaticTypes[slc.loc1].subtypeOf(TBottom)) {
    if (takenOnInit) {
      env.state = std::move(save);
      jmp_nevertaken(env);
    } else {
      env.propagate(jmp.target, &save);
      jmp_setdest(env, jmp.target);
    }
    return;
  }

  if (takenOnInit) {
    env.propagate(jmp.target, &env.state);
    env.state = std::move(save);
  } else {
    env.propagate(jmp.target, &save);
  }
}

template<class JmpOp>
void group(ISS& env, const bc::IsTypeL& istype, const JmpOp& jmp) {
  isTypeHelper(env, istype.subop2, istype.loc1, istype, jmp);
}

// If we duplicate a value, and then test its type and Jmp based on that result,
// we can narrow the type of the top of the stack. Only do this for null checks
// right now (because its useful in memoize wrappers).
template<class JmpOp>
void group(ISS& env, const bc::IsTypeC& istype, const JmpOp& jmp) {
  auto const location = topStkEquiv(env);
  if (location == NoLocalId) return impl(env, istype, jmp);
  isTypeHelper(env, istype.subop1, location, istype, jmp);
}

// If we do an IsUninit check and then Jmp based on the check, one branch will
// be the original type minus the Uninit, and the other will be
// Uninit. (IsUninit does not pop the value).
template<class JmpOp>
void group(ISS& env, const bc::IsUninit&, const JmpOp& jmp) {
  auto const valTy = popCU(env);
  typeTestPropagate(env, valTy, TUninit, remove_uninit(valTy), jmp);
}

// A MemoGet, followed by an IsUninit, followed by a Jmp, can have the type of
// the stack inferred very well. The IsUninit success path will be Uninit and
// the failure path will be the inferred return type of the wrapped
// function. This has to be done as a group and not via individual interp()
// calls is because of limitations in HHBBC's type-system. The type that MemoGet
// pushes is the inferred return type of the wrapper function with Uninit added
// in. Unfortunately HHBBC's type-system cannot exactly represent this
// combination, so it gets forced to Cell. By analyzing this triplet as a group,
// we can avoid this loss of type precision.
template <class JmpOp>
void group(ISS& env, const bc::MemoGet& get, const bc::IsUninit& /*isuninit*/,
           const JmpOp& jmp) {
  impl(env, get);
  typeTestPropagate(env, popCU(env), TUninit, memoizeImplRetType(env), jmp);
}

template<class JmpOp>
void group(ISS& env,
           const bc::InstanceOfD& inst,
           const JmpOp& jmp) {
  auto bail = [&] { impl(env, inst, jmp); };

  auto const locId = topStkEquiv(env);
  if (locId == NoLocalId || interface_supports_non_objects(inst.str1)) {
    return bail();
  }
  auto const val = peekLocation(env, locId, 1);
  assertx(!val.couldBe(TRef)); // we shouldn't have an equivLoc if it was
  auto const rcls = env.index.resolve_class(env.ctx, inst.str1);
  if (!rcls) return bail();

  auto const instTy = subObj(*rcls);
  if (val.subtypeOf(instTy) || !val.couldBe(instTy)) {
    return bail();
  }

  popC(env);
  auto const negate    = jmp.op == Op::JmpNZ;
  auto const pre  = [&] (Type t) { return negate ? instTy : t; };
  auto const post = [&] (Type t) { return negate ? t : instTy; };
  refineLocation(env, locId, pre, jmp.target, post);
}

void in(ISS& env, const bc::Switch& op) {
  auto v = tv(popC(env));

  if (v) {
    auto go = [&] (BlockId blk) {
      effect_free(env);
      env.propagate(blk, &env.state);
      jmp_setdest(env, blk);
    };
    auto num_elems = op.targets.size();
    if (op.subop1 == SwitchKind::Bounded) {
      if (v->m_type == KindOfInt64 &&
          v->m_data.num >= 0 && v->m_data.num < num_elems) {
        return go(op.targets[v->m_data.num]);
      }
    } else {
      assertx(num_elems > 2);
      num_elems -= 2;
      for (auto i = size_t{}; ; i++) {
        if (i == num_elems) {
          return go(op.targets.back());
        }
        auto match = eval_cell_value([&] {
            return cellEqual(*v, static_cast<int64_t>(op.arg2 + i));
        });
        if (!match) break;
        if (*match) {
          return go(op.targets[i]);
        }
      }
    }
  }

  forEachTakenEdge(op, [&] (BlockId id) {
      env.propagate(id, &env.state);
  });
}

void in(ISS& env, const bc::SSwitch& op) {
  auto v = tv(popC(env));

  if (v) {
    for (auto& kv : op.targets) {
      auto match = eval_cell_value([&] {
        return !kv.first || cellEqual(*v, kv.first);
      });
      if (!match) break;
      if (*match) {
        effect_free(env);
        env.propagate(kv.second, &env.state);
        jmp_setdest(env, kv.second);
        return;
      }
    }
  }

  forEachTakenEdge(op, [&] (BlockId id) {
      env.propagate(id, &env.state);
  });
}

void in(ISS& env, const bc::RetC& /*op*/) {
  doRet(env, popC(env), false);
}
void in(ISS& env, const bc::RetV& /*op*/) {
  doRet(env, popV(env), false);
}
void in(ISS& /*env*/, const bc::Unwind& /*op*/) {}
void in(ISS& env, const bc::Throw& /*op*/) {
  popC(env);
}

void in(ISS& env, const bc::Catch&) {
  nothrow(env);
  return push(env, subObj(env.index.builtin_class(s_Throwable.get())));
}

void in(ISS& env, const bc::NativeImpl&) {
  killLocals(env);
  mayUseVV(env);

  if (is_collection_method_returning_this(env.ctx.cls, env.ctx.func)) {
    assert(env.ctx.func->attrs & AttrParamCoerceModeNull);
    assert(!(env.ctx.func->attrs & AttrReference));
    auto const resCls = env.index.builtin_class(env.ctx.cls->name);
    // Can still return null if parameter coercion fails
    return doRet(env, union_of(objExact(resCls), TInitNull), true);
  }

  if (env.ctx.func->nativeInfo) {
    return doRet(env, native_function_return_type(env.ctx.func), true);
  }
  doRet(env, TInitGen, true);
}

void in(ISS& env, const bc::CGetL& op) {
  if (!locCouldBeUninit(env, op.loc1)) {
    nothrow(env);
    constprop(env);
  }
  push(env, locAsCell(env, op.loc1), op.loc1);
}

void in(ISS& env, const bc::CGetQuietL& op) {
  nothrow(env);
  constprop(env);
  push(env, locAsCell(env, op.loc1), op.loc1);
}

void in(ISS& env, const bc::CUGetL& op) {
  auto ty = locRaw(env, op.loc1);
  if (ty.subtypeOf(TUninit)) {
    return reduce(env, bc::NullUninit {});
  }
  nothrow(env);
  if (!ty.couldBe(TUninit)) constprop(env);
  if (!ty.subtypeOf(TCell)) ty = TCell;
  push(env, std::move(ty), op.loc1);
}

void in(ISS& env, const bc::PushL& op) {
  if (auto val = tv(locRaw(env, op.loc1))) {
    return reduce(env, gen_constant(*val), bc::UnsetL { op.loc1 });
  }
  impl(env, bc::CGetL { op.loc1 }, bc::UnsetL { op.loc1 });
}

void in(ISS& env, const bc::CGetL2& op) {
  // Can't constprop yet because of no INS_1 support in bc.h
  if (!locCouldBeUninit(env, op.loc1)) effect_free(env);
  auto loc = locAsCell(env, op.loc1);
  auto topEquiv = topStkLocal(env);
  auto top = popT(env);
  push(env, std::move(loc), op.loc1);
  push(env, std::move(top), topEquiv);
}

namespace {

template <typename Op> void common_cgetn(ISS& env) {
  auto const t1 = topC(env);
  auto const v1 = tv(t1);
  if (v1 && v1->m_type == KindOfPersistentString) {
    auto const loc = findLocal(env, v1->m_data.pstr);
    if (loc != NoLocalId) {
      return reduce(env, bc::PopC {}, Op { loc });
    }
  }
  readUnknownLocals(env);
  mayUseVV(env);
  popC(env); // conversion to string can throw
  push(env, TInitCell);
}

}

void in(ISS& env, const bc::CGetN&) { common_cgetn<bc::CGetL>(env); }
void in(ISS& env, const bc::CGetQuietN&) { common_cgetn<bc::CGetQuietL>(env); }

void in(ISS& env, const bc::CGetG&) { popC(env); push(env, TInitCell); }
void in(ISS& env, const bc::CGetQuietG&) { popC(env); push(env, TInitCell); }

void in(ISS& env, const bc::CGetS& op) {
  auto const tcls  = takeClsRefSlot(env, op.slot);
  auto const tname = popC(env);
  auto const vname = tv(tname);
  auto const self  = selfCls(env);

  if (vname && vname->m_type == KindOfPersistentString &&
      self && tcls.subtypeOf(*self)) {
    if (auto ty = selfPropAsCell(env, vname->m_data.pstr)) {
      // Only nothrow when we know it's a private declared property
      // (and thus accessible here).
      nothrow(env);

      // We can only constprop here if we know for sure this is exactly the
      // correct class.  The reason for this is that you could have a LSB class
      // attempting to access a private static in a derived class with the same
      // name as a private static in this class, which is supposed to fatal at
      // runtime (for an example see test/quick/static_sprop2.php).
      auto const selfExact = selfClsExact(env);
      if (selfExact && tcls.subtypeOf(*selfExact)) {
        constprop(env);
      }

      return push(env, std::move(*ty));
    }
  }

  auto indexTy = env.index.lookup_public_static(tcls, tname);
  if (indexTy.subtypeOf(TInitCell)) {
    /*
     * Constant propagation here can change when we invoke autoload, so it's
     * considered HardConstProp.  It's safe not to check anything about private
     * or protected static properties, because you can't override a public
     * static property with a private or protected one---if the index gave us
     * back a constant type, it's because it found a public static and it must
     * be the property this would have read dynamically.
     */
    if (options.HardConstProp) constprop(env);
    return push(env, std::move(indexTy));
  }

  push(env, TInitCell);
}

void in(ISS& env, const bc::VGetL& op) {
  nothrow(env);
  setLocRaw(env, op.loc1, TRef);
  push(env, TRef);
}

void in(ISS& env, const bc::VGetN&) {
  auto const t1 = topC(env);
  auto const v1 = tv(t1);
  if (v1 && v1->m_type == KindOfPersistentString) {
    auto const loc = findLocal(env, v1->m_data.pstr);
    if (loc != NoLocalId) {
      return reduce(env, bc::PopC {},
                         bc::VGetL { loc });
    }
  }
  modifyLocalStatic(env, NoLocalId, TRef);
  popC(env);
  boxUnknownLocal(env);
  mayUseVV(env);
  push(env, TRef);
}

void in(ISS& env, const bc::VGetG&) { popC(env); push(env, TRef); }

void in(ISS& env, const bc::VGetS& op) {
  auto const tcls  = takeClsRefSlot(env, op.slot);
  auto const tname = popC(env);
  auto const vname = tv(tname);
  auto const self  = selfCls(env);

  if (!self || tcls.couldBe(*self)) {
    if (vname && vname->m_type == KindOfPersistentString) {
      boxSelfProp(env, vname->m_data.pstr);
    } else {
      killSelfProps(env);
    }
  }

  if (auto c = env.collect.publicStatics) {
    c->merge(env.ctx, tcls, tname, TRef);
  }

  push(env, TRef);
}

void clsRefGetImpl(ISS& env, Type t1, ClsRefSlotId slot) {
  auto cls = [&]{
    if (t1.subtypeOf(TObj)) {
      nothrow(env);
      return objcls(t1);
    }
    auto const v1 = tv(t1);
    if (v1 && v1->m_type == KindOfPersistentString) {
      if (auto const rcls = env.index.resolve_class(env.ctx, v1->m_data.pstr)) {
        return clsExact(*rcls);
      }
    }
    return TCls;
  }();
  putClsRefSlot(env, slot, std::move(cls));
}

void in(ISS& env, const bc::ClsRefGetL& op) {
  clsRefGetImpl(env, locAsCell(env, op.loc1), op.slot);
}
void in(ISS& env, const bc::ClsRefGetC& op) {
  clsRefGetImpl(env, popC(env), op.slot);
}

void in(ISS& env, const bc::AKExists& /*op*/) {
  auto const t1   = popC(env);
  auto const t2   = popC(env);

  auto const mayThrow = [&]{
    if (!t1.subtypeOfAny(TObj, TArr, TVec, TDict, TKeyset)) return true;
    if (t2.subtypeOfAny(TStr, TNull)) {
      return t1.subtypeOfAny(TObj, TArr) &&
        RuntimeOption::EvalHackArrCompatNotices;
    }
    if (t2.subtypeOf(TInt)) return false;
    return true;
  }();

  if (!mayThrow) nothrow(env);
  push(env, TBool);
}

void in(ISS& env, const bc::GetMemoKeyL& op) {
  always_assert(env.ctx.func->isMemoizeWrapper);

  auto const tyIMemoizeParam =
    subObj(env.index.builtin_class(s_IMemoizeParam.get()));

  auto const inTy = locAsCell(env, op.loc1);

  // If the local could be uninit, we might raise a warning (as
  // usual). Converting an object to a memo key might invoke PHP code if it has
  // the IMemoizeParam interface, and if it doesn't, we'll throw.
  if (!locCouldBeUninit(env, op.loc1) && !inTy.couldBe(TObj)) {
    nothrow(env); constprop(env);
  }

  // If type constraints are being enforced and the local being turned into a
  // memo key is a parameter, then we can possibly using the type constraint to
  // perform a more efficient memoization scheme. Note that this all needs to
  // stay in sync with the interpreter and JIT.
  using MK = MemoKeyConstraint;
  auto const mkc = [&] {
    if (!RuntimeOption::EvalHardTypeHints) return MK::None;
    if (op.loc1 >= env.ctx.func->params.size()) return MK::None;
    auto tc = env.ctx.func->params[op.loc1].typeConstraint;
    if (tc.type() == AnnotType::Object) {
      auto res = env.index.resolve_type_name(tc.typeName());
      if (res.type != AnnotType::Object) {
        tc.resolveType(res.type, res.nullable || tc.isNullable());
      }
    }
    return memoKeyConstraintFromTC(tc);
  }();

  switch (mkc) {
    case MK::Null:
      // Always null, so the key can always just be 0
      always_assert(inTy.subtypeOf(TNull));
      return push(env, ival(0));
    case MK::Int:
      // Always an int, so the key is always an identity mapping
      always_assert(inTy.subtypeOf(TInt));
      return reduce(env, bc::CGetL { op.loc1 });
    case MK::Bool:
      // Always a bool, so the key is the bool cast to an int
      always_assert(inTy.subtypeOf(TBool));
      return reduce(env, bc::CGetL { op.loc1 }, bc::CastInt {});
    case MK::Str:
      // Always a string, so the key is always an identity mapping
      always_assert(inTy.subtypeOf(TStr));
      return reduce(env, bc::CGetL { op.loc1 });
    case MK::IntOrStr:
      // Either an int or string, so the key can be an identity mapping
      return reduce(env, bc::CGetL { op.loc1 });
    case MK::StrOrNull:
    case MK::IntOrNull:
      // A nullable string or int. For strings the key will always be 0 or the
      // string. For ints the key will be the int or a static string. We can't
      // reduce either without introducing control flow.
      return push(env, union_of(TInt, TStr));
    case MK::BoolOrNull:
      // A nullable bool. The key will always be an int (null will be 2), but we
      // can't reduce that without introducing control flow.
      return push(env, TInt);
    case MK::None:
      break;
  }

  // No type constraint, or one that isn't usuable. Use the generic memoization
  // scheme which can handle any type:

  // Integer keys are always mapped to themselves
  if (inTy.subtypeOf(TInt)) return reduce(env, bc::CGetL { op.loc1 });

  if (inTy.subtypeOf(tyIMemoizeParam)) {
    return reduce(
      env,
      bc::CGetL { op.loc1 },
      bc::FPushObjMethodD {
        0,
        s_getInstanceKey.get(),
        ObjMethodOp::NullThrows,
        false
      },
      bc::FCall { 0 },
      bc::UnboxR {}
    );
  }

  // A memo key can be an integer if the input might be an integer, and is a
  // string otherwise. Booleans are always static strings.
  auto keyTy = [&]{
    if (auto const val = tv(inTy)) {
      auto const key = eval_cell(
        [&]{ return HHVM_FN(serialize_memoize_param)(*val); }
      );
      if (key) return *key;
    }
    if (inTy.subtypeOf(TBool)) return TSStr;
    if (inTy.couldBe(TInt)) return union_of(TInt, TStr);
    return TStr;
  }();
  push(env, std::move(keyTy));
}

void in(ISS& env, const bc::IssetL& op) {
  nothrow(env);
  constprop(env);
  auto const loc = locAsCell(env, op.loc1);
  if (loc.subtypeOf(TNull))  return push(env, TFalse);
  if (!loc.couldBe(TNull))   return push(env, TTrue);
  push(env, TBool);
}

void in(ISS& env, const bc::EmptyL& op) {
  nothrow(env);
  constprop(env);
  castBoolImpl(env, locAsCell(env, op.loc1), true);
}

void in(ISS& env, const bc::EmptyS& op) {
  takeClsRefSlot(env, op.slot);
  popC(env);
  push(env, TBool);
}

void in(ISS& env, const bc::IssetS& op) {
  auto const tcls  = takeClsRefSlot(env, op.slot);
  auto const tname = popC(env);
  auto const vname = tv(tname);
  auto const self  = selfCls(env);

  if (self && tcls.subtypeOf(*self) &&
      vname && vname->m_type == KindOfPersistentString) {
    if (auto const t = selfPropAsCell(env, vname->m_data.pstr)) {
      if (t->subtypeOf(TNull))  { constprop(env); return push(env, TFalse); }
      if (!t->couldBe(TNull))   { constprop(env); return push(env, TTrue); }
    }
  }

  auto const indexTy = env.index.lookup_public_static(tcls, tname);
  if (indexTy.subtypeOf(TInitCell)) {
    // See the comments in CGetS about constprop for public statics.
    if (options.HardConstProp) constprop(env);
    if (indexTy.subtypeOf(TNull))  { return push(env, TFalse); }
    if (!indexTy.couldBe(TNull))   { return push(env, TTrue); }
  }

  push(env, TBool);
}

template<class ReduceOp>
void issetEmptyNImpl(ISS& env) {
  auto const t1 = topC(env);
  auto const v1 = tv(t1);
  if (v1 && v1->m_type == KindOfPersistentString) {
    auto const loc = findLocal(env, v1->m_data.pstr);
    if (loc != NoLocalId) {
      return reduce(env, bc::PopC {}, ReduceOp { loc });
    }
    // Can't push true in the non env.findLocal case unless we know
    // whether this function can have a VarEnv.
  }
  readUnknownLocals(env);
  mayUseVV(env);
  popC(env);
  push(env, TBool);
}

void in(ISS& env, const bc::IssetN&) { issetEmptyNImpl<bc::IssetL>(env); }
void in(ISS& env, const bc::EmptyN&) { issetEmptyNImpl<bc::EmptyL>(env); }
void in(ISS& env, const bc::EmptyG&) { popC(env); push(env, TBool); }
void in(ISS& env, const bc::IssetG&) { popC(env); push(env, TBool); }

void isTypeImpl(ISS& env, const Type& locOrCell, const Type& test) {
  constprop(env);
  if (locOrCell.subtypeOf(test))  return push(env, TTrue);
  if (!locOrCell.couldBe(test))   return push(env, TFalse);
  push(env, TBool);
}

void isTypeObj(ISS& env, const Type& ty) {
  if (!ty.couldBe(TObj)) return push(env, TFalse);
  if (ty.subtypeOf(TObj)) {
    auto const incompl = objExact(
      env.index.builtin_class(s_PHP_Incomplete_Class.get()));
    if (!ty.couldBe(incompl))  return push(env, TTrue);
    if (ty.subtypeOf(incompl)) return push(env, TFalse);
  }
  push(env, TBool);
}

template<class Op>
void isTypeLImpl(ISS& env, const Op& op) {
  if (!locCouldBeUninit(env, op.loc1)) { nothrow(env); constprop(env); }
  auto const loc = locAsCell(env, op.loc1);
  switch (op.subop2) {
  case IsTypeOp::Scalar: return push(env, TBool);
  case IsTypeOp::Obj: return isTypeObj(env, loc);
  default: return isTypeImpl(env, loc, type_of_istype(op.subop2));
  }
}

template<class Op>
void isTypeCImpl(ISS& env, const Op& op) {
  nothrow(env);
  auto const t1 = popC(env);
  switch (op.subop1) {
  case IsTypeOp::Scalar: return push(env, TBool);
  case IsTypeOp::Obj: return isTypeObj(env, t1);
  default: return isTypeImpl(env, t1, type_of_istype(op.subop1));
  }
}

void in(ISS& env, const bc::IsTypeC& op) { isTypeCImpl(env, op); }
void in(ISS& env, const bc::IsTypeL& op) { isTypeLImpl(env, op); }

void in(ISS& env, const bc::IsUninit& /*op*/) {
  nothrow(env);
  push(env, popCU(env));
  isTypeImpl(env, topT(env), TUninit);
}

void in(ISS& env, const bc::MaybeMemoType& /*op*/) {
  always_assert(env.ctx.func->isMemoizeWrapper);
  nothrow(env);
  constprop(env);
  auto const memoTy = memoizeImplRetType(env);
  auto const ty = popC(env);
  push(env, ty.couldBe(memoTy) ? TTrue : TFalse);
}

void in(ISS& env, const bc::IsMemoType& /*op*/) {
  always_assert(env.ctx.func->isMemoizeWrapper);
  nothrow(env);
  constprop(env);
  auto const memoTy = memoizeImplRetType(env);
  auto const ty = popC(env);
  push(env, memoTy.subtypeOf(ty) ? TTrue : TFalse);
}

void in(ISS& env, const bc::InstanceOfD& op) {
  auto const t1 = popC(env);
  // Note: InstanceOfD can do autoload if the type might be a type
  // alias, so it's not nothrow unless we know it's an object type.
  if (auto const rcls = env.index.resolve_class(env.ctx, op.str1)) {
    nothrow(env);
    if (!interface_supports_non_objects(rcls->name())) {
      isTypeImpl(env, t1, subObj(*rcls));
      return;
    }
  }
  push(env, TBool);
}

void in(ISS& env, const bc::InstanceOf& /*op*/) {
  auto const t1 = topC(env);
  auto const v1 = tv(t1);
  if (v1 && v1->m_type == KindOfPersistentString) {
    return reduce(env, bc::PopC {},
                       bc::InstanceOfD { v1->m_data.pstr });
  }

  if (t1.subtypeOf(TObj) && is_specialized_obj(t1)) {
    auto const dobj = dobj_of(t1);
    switch (dobj.type) {
    case DObj::Sub:
      break;
    case DObj::Exact:
      return reduce(env, bc::PopC {},
                         bc::InstanceOfD { dobj.cls.name() });
    }
  }

  popC(env);
  popC(env);
  push(env, TBool);
}

namespace {

/*
 * If the value on the top of the stack is known to be equivalent to the local
 * its being moved/copied to, return folly::none without modifying any
 * state. Otherwise, pop the stack value, perform the set, and return a pair
 * giving the value's type, and any other local its known to be equivalent to.
 */
template <typename Op>
folly::Optional<std::pair<Type, LocalId>> moveToLocImpl(ISS& env,
                                                        const Op& op) {
  nothrow(env);
  auto equivLoc = topStkLocal(env);
  // If the local could be a Ref, don't record equality because the stack
  // element and the local won't actually have the same type.
  if (!locCouldBeRef(env, op.loc1)) {
    assertx(!is_volatile_local(env.ctx.func, op.loc1));
    if (equivLoc != NoLocalId) {
      if (equivLoc == op.loc1 ||
          locsAreEquiv(env, equivLoc, op.loc1)) {
        // We allow equivalency to ignore Uninit, so we need to check
        // the types here.
        if (peekLocRaw(env, op.loc1) == topC(env)) {
          return folly::none;
        }
      }
    } else {
      equivLoc = op.loc1;
    }
  }
  auto val = popC(env);
  setLoc(env, op.loc1, val);
  if (equivLoc != op.loc1 && equivLoc != NoLocalId) {
    addLocEquiv(env, op.loc1, equivLoc);
  }
  return { std::make_pair(std::move(val), equivLoc) };
}

}

void in(ISS& env, const bc::PopL& op) {
  // If the same value is already in the local, do nothing but pop
  // it. Otherwise, the set has been done by moveToLocImpl.
  if (!moveToLocImpl(env, op)) return reduce(env, bc::PopC {});
}

void in(ISS& env, const bc::SetL& op) {
  // If the same value is already in the local, do nothing because SetL keeps
  // the value on the stack. If it isn't, we need to push it back onto the stack
  // because moveToLocImpl popped it.
  if (auto p = moveToLocImpl(env, op)) {
    push(env, std::move(p->first), p->second);
  } else {
    reduce(env, bc::Nop {});
  }
}

void in(ISS& env, const bc::SetN&) {
  // This isn't trivial to strength reduce, without a "flip two top
  // elements of stack" opcode.
  auto t1 = popC(env);
  auto const t2 = popC(env);
  auto const v2 = tv(t2);
  // TODO(#3653110): could nothrow if t2 can't be an Obj or Res

  auto const knownLoc = v2 && v2->m_type == KindOfPersistentString
    ? findLocal(env, v2->m_data.pstr)
    : NoLocalId;
  if (knownLoc != NoLocalId) {
    setLoc(env, knownLoc, t1);
  } else {
    // We could be changing the value of any local, but we won't
    // change whether or not they are boxed or initialized.
    loseNonRefLocalTypes(env);
  }
  mayUseVV(env);
  push(env, std::move(t1));
}

void in(ISS& env, const bc::SetG&) {
  auto t1 = popC(env);
  popC(env);
  push(env, std::move(t1));
}

void in(ISS& env, const bc::SetS& op) {
  auto const t1    = popC(env);
  auto const tcls  = takeClsRefSlot(env, op.slot);
  auto const tname = popC(env);
  auto const vname = tv(tname);
  auto const self  = selfCls(env);

  if (!self || tcls.couldBe(*self)) {
    if (vname && vname->m_type == KindOfPersistentString) {
      nothrow(env);
      mergeSelfProp(env, vname->m_data.pstr, t1);
    } else {
      mergeEachSelfPropRaw(env, [&] (Type) { return t1; });
    }
  }

  if (auto c = env.collect.publicStatics) {
    c->merge(env.ctx, tcls, tname, t1);
  }

  push(env, std::move(t1));
}

void in(ISS& env, const bc::SetOpL& op) {
  auto const t1     = popC(env);
  auto const v1     = tv(t1);
  auto const loc    = locAsCell(env, op.loc1);
  auto const locVal = tv(loc);
  if (v1 && locVal) {
    // Can't constprop at this eval_cell, because of the effects on
    // locals.
    auto resultTy = eval_cell([&] {
      Cell c = *locVal;
      Cell rhs = *v1;
      setopBody(&c, op.subop2, &rhs);
      return c;
    });
    if (!resultTy) resultTy = TInitCell;

    // We may have inferred a TSStr or TSArr with a value here, but
    // at runtime it will not be static.  For now just throw that
    // away.  TODO(#3696042): should be able to loosen_staticness here.
    if (resultTy->subtypeOf(TStr)) resultTy = TStr;
    else if (resultTy->subtypeOf(TArr)) resultTy = TArr;
    else if (resultTy->subtypeOf(TVec)) resultTy = TVec;
    else if (resultTy->subtypeOf(TDict)) resultTy = TDict;
    else if (resultTy->subtypeOf(TKeyset)) resultTy = TKeyset;

    setLoc(env, op.loc1, *resultTy);
    push(env, *resultTy);
    return;
  }

  auto resultTy = typeSetOp(op.subop2, loc, t1);
  setLoc(env, op.loc1, resultTy);
  push(env, std::move(resultTy));
}

void in(ISS& env, const bc::SetOpN&) {
  popC(env);
  popC(env);
  loseNonRefLocalTypes(env);
  mayUseVV(env);
  push(env, TInitCell);
}

void in(ISS& env, const bc::SetOpG&) {
  popC(env); popC(env);
  push(env, TInitCell);
}

void in(ISS& env, const bc::SetOpS& op) {
  popC(env);
  auto const tcls  = takeClsRefSlot(env, op.slot);
  auto const tname = popC(env);
  auto const vname = tv(tname);
  auto const self  = selfCls(env);

  if (!self || tcls.couldBe(*self)) {
    if (vname && vname->m_type == KindOfPersistentString) {
      mergeSelfProp(env, vname->m_data.pstr, TInitCell);
    } else {
      loseNonRefSelfPropTypes(env);
    }
  }

  if (auto c = env.collect.publicStatics) {
    c->merge(env.ctx, tcls, tname, TInitCell);
  }

  push(env, TInitCell);
}

void in(ISS& env, const bc::IncDecL& op) {
  auto loc = locAsCell(env, op.loc1);
  auto newT = typeIncDec(op.subop2, loc);
  auto const pre = isPre(op.subop2);

  // If it's a non-numeric string, this may cause it to exceed the max length.
  if (!locCouldBeUninit(env, op.loc1) &&
      !loc.couldBe(TStr)) {
    nothrow(env);
  }

  if (!pre) push(env, std::move(loc));
  setLoc(env, op.loc1, newT);
  if (pre)  push(env, std::move(newT));
}

void in(ISS& env, const bc::IncDecN& op) {
  auto const t1 = topC(env);
  auto const v1 = tv(t1);
  auto const knownLoc = v1 && v1->m_type == KindOfPersistentString
    ? findLocal(env, v1->m_data.pstr)
    : NoLocalId;
  if (knownLoc != NoLocalId) {
    return reduce(env, bc::PopC {},
                       bc::IncDecL { knownLoc, op.subop1 });
  }
  popC(env);
  loseNonRefLocalTypes(env);
  mayUseVV(env);
  push(env, TInitCell);
}

void in(ISS& env, const bc::IncDecG&) { popC(env); push(env, TInitCell); }

void in(ISS& env, const bc::IncDecS& op) {
  auto const tcls  = takeClsRefSlot(env, op.slot);
  auto const tname = popC(env);
  auto const vname = tv(tname);
  auto const self  = selfCls(env);

  if (!self || tcls.couldBe(*self)) {
    if (vname && vname->m_type == KindOfPersistentString) {
      mergeSelfProp(env, vname->m_data.pstr, TInitCell);
    } else {
      loseNonRefSelfPropTypes(env);
    }
  }

  if (auto c = env.collect.publicStatics) {
    c->merge(env.ctx, tcls, tname, TInitCell);
  }

  push(env, TInitCell);
}

void in(ISS& env, const bc::BindL& op) {
  // If the op.loc1 was bound to a local static, its going to be
  // unbound from it. If the thing its being bound /to/ is a local
  // static, we've already marked it as modified via the VGetL, so
  // there's nothing more to track.
  // Unbind it before any updates.
  modifyLocalStatic(env, op.loc1, TUninit);
  nothrow(env);
  auto t1 = popV(env);
  setLocRaw(env, op.loc1, t1);
  push(env, std::move(t1));
}

void in(ISS& env, const bc::BindN&) {
  // TODO(#3653110): could nothrow if t2 can't be an Obj or Res
  auto t1 = popV(env);
  auto const t2 = popC(env);
  auto const v2 = tv(t2);
  auto const knownLoc = v2 && v2->m_type == KindOfPersistentString
    ? findLocal(env, v2->m_data.pstr)
    : NoLocalId;
  unbindLocalStatic(env, knownLoc);
  if (knownLoc != NoLocalId) {
    setLocRaw(env, knownLoc, t1);
  } else {
    boxUnknownLocal(env);
  }
  mayUseVV(env);
  push(env, std::move(t1));
}

void in(ISS& env, const bc::BindG&) {
  auto t1 = popV(env);
  popC(env);
  push(env, std::move(t1));
}

void in(ISS& env, const bc::BindS& op) {
  popV(env);
  auto const tcls  = takeClsRefSlot(env, op.slot);
  auto const tname = popC(env);
  auto const vname = tv(tname);
  auto const self  = selfCls(env);

  if (!self || tcls.couldBe(*self)) {
    if (vname && vname->m_type == KindOfPersistentString) {
      boxSelfProp(env, vname->m_data.pstr);
    } else {
      killSelfProps(env);
    }
  }

  if (auto c = env.collect.publicStatics) {
    c->merge(env.ctx, tcls, tname, TRef);
  }

  push(env, TRef);
}

void in(ISS& env, const bc::UnsetL& op) {
  nothrow(env);
  setLocRaw(env, op.loc1, TUninit);
}

void in(ISS& env, const bc::UnsetN& /*op*/) {
  auto const t1 = topC(env);
  auto const v1 = tv(t1);
  if (v1 && v1->m_type == KindOfPersistentString) {
    auto const loc = findLocal(env, v1->m_data.pstr);
    if (loc != NoLocalId) {
      return reduce(env, bc::PopC {},
                         bc::UnsetL { loc });
    }
  }
  popC(env);
  if (!t1.couldBe(TObj) && !t1.couldBe(TRes)) nothrow(env);
  unsetUnknownLocal(env);
  mayUseVV(env);
}

void in(ISS& env, const bc::UnsetG& /*op*/) {
  auto const t1 = popC(env);
  if (!t1.couldBe(TObj) && !t1.couldBe(TRes)) nothrow(env);
}

void in(ISS& env, const bc::FPushFuncD& op) {
  auto const rfunc = env.index.resolve_func(env.ctx, op.str2);
  if (auto const func = rfunc.exactFunc()) {
    if (can_emit_builtin(func, op.arg1, op.has_unpack)) {
      fpiPush(env, ActRec { FPIKind::Builtin, folly::none, rfunc }, op.arg1);
      return reduce(env, bc::Nop {});
    }
  }
  fpiPush(env, ActRec { FPIKind::Func, folly::none, rfunc }, op.arg1);
}

void in(ISS& env, const bc::FPushFunc& op) {
  auto const t1 = topC(env);
  auto const v1 = tv(t1);
  if (v1 && v1->m_type == KindOfPersistentString) {
    auto const name = normalizeNS(v1->m_data.pstr);
    // FPushFuncD doesn't support class-method pair strings yet.
    if (isNSNormalized(name) && notClassMethodPair(name)) {
      auto const rfunc = env.index.resolve_func(env.ctx, name);
      // Don't turn dynamic calls to caller frame affecting functions into
      // static calls, because they might fatal (whereas the static one won't).
      if (!rfunc.mightAccessCallerFrame()) {
        return reduce(env, bc::PopC {},
                      bc::FPushFuncD { op.arg1, name, op.has_unpack });
      }
    }
  }
  popC(env);
  if (t1.subtypeOf(TObj)) return fpiPush(env, ActRec { FPIKind::ObjInvoke });
  if (t1.subtypeOf(TArr)) return fpiPush(env, ActRec { FPIKind::CallableArr });
  if (t1.subtypeOf(TStr)) return fpiPush(env, ActRec { FPIKind::Func });
  fpiPush(env, ActRec { FPIKind::Unknown });
}

void in(ISS& env, const bc::FPushFuncU& op) {
  auto const rfuncPair =
    env.index.resolve_func_fallback(env.ctx, op.str2, op.str3);
  if (options.ElideAutoloadInvokes && !rfuncPair.second) {
    return reduce(
      env,
      bc::FPushFuncD { op.arg1, rfuncPair.first.name(), op.has_unpack }
    );
  }
  fpiPush(
    env,
    ActRec { FPIKind::Func, folly::none, rfuncPair.first, rfuncPair.second }
  );
}

void in(ISS& env, const bc::FPushObjMethodD& op) {
  auto location = topStkEquiv(env);
  auto t1 = popC(env);
  if (op.subop3 == ObjMethodOp::NullThrows) {
    if (!t1.couldBe(TObj)) {
      fpiPush(env, ActRec { FPIKind::ObjMeth });
      return unreachable(env);
    }
    if (is_opt(t1)) {
      t1 = unopt(std::move(t1));
    }
  } else if (!t1.couldBe(TOptObj)) {
    fpiPush(env, ActRec { FPIKind::ObjMeth });
    return unreachable(env);
  }
  auto const clsTy = objcls(t1);
  auto const rcls = [&]() -> folly::Optional<res::Class> {
    if (is_specialized_cls(clsTy)) return dcls_of(clsTy).cls;
    return folly::none;
  }();

  fpiPush(
    env,
    ActRec {
      FPIKind::ObjMeth,
      rcls,
      env.index.resolve_method(env.ctx, clsTy, op.str2)
    },
    op.arg1
  );
  if (location != NoLocalId) {
    auto ty = peekLocation(env, location);
    if (ty.subtypeOf(TCell)) {
      refineLocation(env, location,
                     [&] (Type t) {
                       if (!is_specialized_obj(t)) {
                         return op.subop3 == ObjMethodOp::NullThrows ?
                           TObj : TOptObj;
                       }
                       if (is_opt(t) && op.subop3 == ObjMethodOp::NullThrows) {
                         return unopt(t);
                       }
                       return t;
                     });
    }
  }
}

void in(ISS& env, const bc::FPushObjMethod& op) {
  auto const t1 = topC(env);
  auto const v1 = tv(t1);
  if (v1 && v1->m_type == KindOfPersistentString) {
    return reduce(
      env,
      bc::PopC {},
      bc::FPushObjMethodD { op.arg1, v1->m_data.pstr, op.subop2, op.has_unpack }
    );
  }
  popC(env);
  popC(env);
  fpiPush(env, ActRec { FPIKind::ObjMeth });
}

void in(ISS& env, const bc::FPushClsMethodD& op) {
  auto const rcls = env.index.resolve_class(env.ctx, op.str3);
  auto const rfun = env.index.resolve_method(
    env.ctx,
    rcls ? clsExact(*rcls) : TCls,
    op.str2
  );
  fpiPush(env, ActRec { FPIKind::ClsMeth, rcls, rfun }, op.arg1);
}

template<typename PushOp>
void pushClsHelper(ISS& env, const PushOp& op) {
  auto const t1 = peekClsRefSlot(env, op.slot);
  auto const t2 = topC(env);
  auto const v2 = tv(t2);

  folly::Optional<res::Class> rcls;
  auto exactCls = false;
  if (is_specialized_cls(t1)) {
    auto dcls = dcls_of(t1);
    rcls = dcls.cls;
    exactCls = dcls.type == DCls::Exact;
  }
  folly::Optional<res::Func> rfunc;
  if (v2 && v2->m_type == KindOfPersistentString) {
    if (std::is_same<PushOp, bc::FPushClsMethod>::value &&
        exactCls && rcls) {
      return reduce(
        env,
        bc::DiscardClsRef { op.slot },
        bc::PopC {},
        bc::FPushClsMethodD {
          op.arg1, v2->m_data.pstr, rcls->name(), op.has_unpack
        }
      );
    }
    rfunc = env.index.resolve_method(env.ctx, t1, v2->m_data.pstr);
  }
  fpiPush(env, ActRec { FPIKind::ClsMeth, rcls, rfunc }, op.arg1);
  takeClsRefSlot(env, op.slot);
  popC(env);
}

void in(ISS& env, const bc::FPushClsMethod& op) {
  pushClsHelper(env, op);
}

void in(ISS& env, const bc::FPushClsMethodF& op) {
  pushClsHelper(env, op);
}

void ctorHelper(ISS& env, SString name) {
  auto const rcls = env.index.resolve_class(env.ctx, name);
  push(env, rcls ? objExact(*rcls) : TObj);
  auto const rfunc =
    rcls ? env.index.resolve_ctor(env.ctx, *rcls) : folly::none;
  fpiPush(env, ActRec { FPIKind::Ctor, rcls, rfunc });
}

void in(ISS& env, const bc::FPushCtorD& op) {
  ctorHelper(env, op.str2);
}

void in(ISS& env, const bc::FPushCtorI& op) {
  auto const name = env.ctx.unit->classes[op.arg2]->name;
  ctorHelper(env, name);
}

void in(ISS& env, const bc::FPushCtor& op) {
  auto const& t1 = peekClsRefSlot(env, op.slot);
  if (is_specialized_cls(t1)) {
    auto const dcls = dcls_of(t1);
    if (dcls.type == DCls::Exact) {
      return reduce(env, bc::DiscardClsRef { op.slot },
                    bc::FPushCtorD { op.arg1, dcls.cls.name(), op.has_unpack });
    }
  }
  takeClsRefSlot(env, op.slot);
  push(env, TObj);
  fpiPush(env, ActRec { FPIKind::Ctor });
}

void in(ISS& env, const bc::FPushCufIter&) {
  nothrow(env);
  fpiPush(env, ActRec { FPIKind::Unknown });
}

void in(ISS& env, const bc::FPushCuf&) {
  popC(env);
  fpiPush(env, ActRec { FPIKind::Unknown });
}
void in(ISS& env, const bc::FPushCufF&) {
  popC(env);
  fpiPush(env, ActRec { FPIKind::Unknown });
}

void in(ISS& env, const bc::FPushCufSafe&) {
  auto t1 = popC(env);
  popC(env);
  push(env, std::move(t1));
  fpiPush(env, ActRec { FPIKind::Unknown });
  push(env, TBool);
}

void in(ISS& env, const bc::RaiseFPassWarning& op) {
}

void in(ISS& env, const bc::FPassL& op) {
  switch (prepKind(env, op.arg1)) {
  case PrepKind::Unknown:
    if (!locCouldBeUninit(env, op.loc2) && op.subop3 == FPassHint::Any) {
      nothrow(env);
    }
    // This might box the local, we can't tell.  Note: if the local
    // is already TRef, we could try to leave it alone, but not for
    // now.
    setLocRaw(env, op.loc2, TGen);
    return push(env, TInitGen);
  case PrepKind::Val:
    return reduce_fpass_arg(env, bc::CGetL { op.loc2 }, op.arg1, false,
                            op.subop3);
  case PrepKind::Ref:
    return reduce_fpass_arg(env, bc::VGetL { op.loc2 }, op.arg1, true,
                            op.subop3);
  }
}

void in(ISS& env, const bc::FPassN& op) {
  switch (prepKind(env, op.arg1)) {
  case PrepKind::Unknown:
    // This could change the type of any local.
    popC(env);
    killLocals(env);
    mayUseVV(env);
    return push(env, TInitGen);
  case PrepKind::Val: return reduce_fpass_arg(env,
                                              bc::CGetN {},
                                              op.arg1,
                                              false,
                                              op.subop2);
  case PrepKind::Ref: return reduce_fpass_arg(env,
                                              bc::VGetN {},
                                              op.arg1,
                                              true,
                                              op.subop2);
  }
}

void in(ISS& env, const bc::FPassG& op) {
  switch (prepKind(env, op.arg1)) {
  case PrepKind::Unknown: popC(env); return push(env, TInitGen);
  case PrepKind::Val:     return reduce_fpass_arg(env,
                                                  bc::CGetG {},
                                                  op.arg1,
                                                  false,
                                                  op.subop2);
  case PrepKind::Ref:     return reduce_fpass_arg(env,
                                                  bc::VGetG {},
                                                  op.arg1,
                                                  true,
                                                  op.subop2);
  }
}

void in(ISS& env, const bc::FPassS& op) {
  switch (prepKind(env, op.arg1)) {
  case PrepKind::Unknown:
    {
      auto tcls        = takeClsRefSlot(env, op.slot);
      auto const self  = selfCls(env);
      auto const tname = popC(env);
      auto const vname = tv(tname);
      if (!self || tcls.couldBe(*self)) {
        if (vname && vname->m_type == KindOfPersistentString) {
          // May or may not be boxing it, depending on the refiness.
          mergeSelfProp(env, vname->m_data.pstr, TInitGen);
        } else {
          killSelfProps(env);
        }
      }
      if (auto c = env.collect.publicStatics) {
        c->merge(env.ctx, std::move(tcls), tname, TInitGen);
      }
    }
    return push(env, TInitGen);
  case PrepKind::Val:
    return reduce_fpass_arg(env, bc::CGetS { op.slot }, op.arg1, false,
                            op.subop3);
  case PrepKind::Ref:
    return reduce_fpass_arg(env, bc::VGetS { op.slot }, op.arg1, true,
                            op.subop3);
  }
}

void in(ISS& env, const bc::FPassV& op) {
  auto const kind = prepKind(env, op.arg1);
  if (!fpassCanThrow(env, kind, op.subop2)) nothrow(env);
  switch (kind) {
  case PrepKind::Unknown:
    popV(env);
    return push(env, TInitGen);
  case PrepKind::Val:
    return reduce_fpass_arg(env, bc::Unbox {}, op.arg1, false, op.subop2);
  case PrepKind::Ref:
    return reduce_fpass_arg(env, bc::Nop {}, op.arg1, true, op.subop2);
  }
}

void in(ISS& env, const bc::FPassR& op) {
  auto const kind = prepKind(env, op.arg1);
  if (!fpassCanThrow(env, kind, op.subop2)) nothrow(env);
  if (fpiTop(env).kind == FPIKind::Builtin) {
    switch (kind) {
    case PrepKind::Unknown:
      not_reached();
    case PrepKind::Val:
      return reduceFPassBuiltin(env, kind, op.subop2, op.arg1, bc::UnboxR {});
    case PrepKind::Ref:
      return reduceFPassBuiltin(env, kind, op.subop2, op.arg1, bc::BoxR {});
    }
  }

  auto const t1 = topT(env);
  if (t1.subtypeOf(TCell)) {
    return reduce_fpass_arg(env, bc::UnboxRNop {}, op.arg1, false, op.subop2);
  }

  // If it's known to be a ref, this behaves like FPassV, except we need to do
  // it slightly differently to keep stack flavors correct.
  if (t1.subtypeOf(TRef)) {
    switch (kind) {
    case PrepKind::Unknown:
      popV(env);
      return push(env, TInitGen);
    case PrepKind::Val:
      return reduce_fpass_arg(env, bc::UnboxR {}, op.arg1, false, op.subop2);
    case PrepKind::Ref:
      return reduce_fpass_arg(env, bc::BoxRNop {}, op.arg1, true, op.subop2);
    }
    not_reached();
  }

  // Here we don't know if it is going to be a cell or a ref.
  switch (kind) {
  case PrepKind::Unknown:      popR(env); return push(env, TInitGen);
  case PrepKind::Val:          popR(env); return push(env, TInitCell);
  case PrepKind::Ref:          popR(env); return push(env, TRef);
  }
}

void in(ISS& env, const bc::FPassVNop& op) {
  push(env, popV(env));
  if (fpiTop(env).kind == FPIKind::Builtin) {
    return reduceFPassBuiltin(env, prepKind(env, op.arg1), op.subop2, op.arg1,
                              bc::Nop {});
  }
  if (op.subop2 != FPassHint::Cell) nothrow(env);
}

void in(ISS& env, const bc::FPassC& op) {
  auto& ar = fpiTop(env);
  if (ar.kind == FPIKind::Builtin) {
    return reduceFPassBuiltin(env, prepKind(env, op.arg1), op.subop2, op.arg1,
                              bc::Nop {});
  }
  if (ar.foldable) {
    auto const ok = [&] {
      if (!is_scalar(topT(env))) return false;
      auto const callee = ar.func->exactFunc();
      if (op.arg1 >= callee->params.size() ||
          (op.arg1 + 1 == callee->params.size() &&
           callee->params.back().isVariadic)) {
        return true;
      }
      auto const constraint = callee->params[op.arg1].typeConstraint;
      if (!constraint.hasConstraint() ||
          constraint.isTypeVar() ||
          constraint.isTypeConstant()) {
        return true;
      }
      return env.index.satisfies_constraint(
        Context { callee->unit, const_cast<php::Func*>(callee), callee->cls },
        topC(env), constraint);
    }();
    if (!ok) {
      auto const func = ar.func->exactFunc();
      assertx(func);
      env.collect.unfoldableFuncs.emplace(func);
      env.propagate(ar.pushBlk, nullptr);
      ar.foldable = false;
      FTRACE(2, "     fpi: not foldable\n");
    }
  }
  if (op.subop2 != FPassHint::Ref) effect_free(env);
}

void fpassCXHelper(ISS& env, uint32_t param, bool error, FPassHint hint) {
  auto const& fpi = fpiTop(env);
  auto const kind = prepKind(env, param);
  if (fpi.kind == FPIKind::Builtin) {
    switch (kind) {
      case PrepKind::Unknown:
        not_reached();
      case PrepKind::Ref:
      {
        auto const& params = fpi.func->exactFunc()->params;
        if (param >= params.size() || params[param].mustBeRef) {
          if (error) {
            return reduceFPassBuiltin(
              env,
              kind,
              hint,
              param,
              bc::String { s_byRefError.get() },
              bc::Fatal { FatalOp::Runtime }
            );
          } else {
            return reduceFPassBuiltin(
              env,
              kind,
              hint,
              param,
              bc::String { s_byRefWarn.get() },
              bc::Int { (int)ErrorMode::STRICT },
              bc::FCallBuiltin { 2, 2, s_trigger_error.get() },
              bc::PopC {}
            );
          }
        }
        // fall through
      }
      case PrepKind::Val:
        return reduce(env, bc::Nop {});
    }
    not_reached();
  }
  switch (kind) {
    case PrepKind::Unknown: return;
    case PrepKind::Val:     return reduce(env, bc::FPassC { param, hint });
    case PrepKind::Ref:     /* will warn/fatal at runtime */ return;
  }
}

void in(ISS& env, const bc::FPassCW& op) {
  fpassCXHelper(env, op.arg1, false, op.subop2);
}

void in(ISS& env, const bc::FPassCE& op) {
  fpassCXHelper(env, op.arg1, true, op.subop2);
}

void pushCallReturnType(ISS& env, Type&& ty) {
  if (ty == TBottom) {
    // The callee function never returns.  It might throw, or loop forever.
    unreachable(env);
  }
  return push(env, std::move(ty));
}

const StaticString s_defined { "defined" };
const StaticString s_function_exists { "function_exists" };

void fcallKnownImpl(ISS& env, uint32_t numArgs) {
  auto const ar = fpiPop(env);
  always_assert(ar.func.hasValue());

  if (options.ConstantFoldBuiltins && ar.foldable) {
    auto ty = [&] () -> folly::Optional<Type> {
      if (ar.func->isFoldable()) {
        return const_fold(env, numArgs, *ar.func);
      }
      auto const func = ar.func->exactFunc();
      assertx(func);
      std::vector<Type> args(numArgs);
      for (auto i = uint32_t{0}; i < numArgs; ++i) {
        args[numArgs - i - 1] = topT(env, i);
      }

      auto const ret = env.index.lookup_foldable_return_type(
        env.ctx, func, std::move(args));
      if (ret == TTop) {
        env.collect.unfoldableFuncs.emplace(func);
        env.propagate(ar.pushBlk, nullptr);
        return folly::none;
      }
      discard(env, numArgs);
      return ret;
    }();
    if (ty) return push(env, std::move(*ty));
  }

  specialFunctionEffects(env, ar);

  if (ar.func->name()->isame(s_function_exists.get())) {
    handle_function_exists(env, numArgs, false);
  }

  std::vector<Type> args(numArgs);
  for (auto i = uint32_t{0}; i < numArgs; ++i) {
    args[numArgs - i - 1] = popF(env);
  }

  if (options.HardConstProp &&
      numArgs == 1 &&
      ar.func->name()->isame(s_defined.get())) {
    // If someone calls defined('foo') they probably want foo to be
    // defined normally; ie not a persistent constant.
    if (auto const v = tv(args[0])) {
      if (isStringType(v->m_type) &&
          !env.index.lookup_constant(env.ctx, v->m_data.pstr)) {
        env.collect.cnsMap[v->m_data.pstr].m_type = kDynamicConstant;
      }
    }
  }

  auto ty = env.index.lookup_return_type(
    CallContext { env.ctx, args },
    *ar.func
  );
  if (!ar.fallbackFunc) {
    pushCallReturnType(env, std::move(ty));
    return;
  }
  auto ty2 = env.index.lookup_return_type(
    CallContext { env.ctx, args },
    *ar.fallbackFunc
  );
  pushCallReturnType(env, union_of(std::move(ty), std::move(ty2)));
}

void in(ISS& env, const bc::FCall& op) {
  auto const ar = fpiTop(env);
  if (ar.func && !ar.fallbackFunc) {
    switch (ar.kind) {
    case FPIKind::Unknown:
    case FPIKind::CallableArr:
    case FPIKind::ObjInvoke:
      not_reached();
    case FPIKind::Func:
      // Don't turn dynamic calls into static calls with functions that can
      // potentially touch the caller's frame. Such functions will fatal if
      // called dynamically and we want to preserve that behavior.
      if (!ar.func->mightAccessCallerFrame()) {
        return reduce(
          env,
          bc::FCallD { op.arg1, s_empty.get(), ar.func->name() }
        );
      }
      break;
    case FPIKind::Builtin:
      return finish_builtin(env, ar.func->exactFunc(), op.arg1, false);
    case FPIKind::Ctor:
      /*
       * Need to be wary of old-style ctors. We could get into the situation
       * where we're constructing class D extends B, and B has an old-style
       * ctor but D::B also exists.  (So in this case we'll skip the
       * fcallKnownImpl stuff.)
       */
      if (!ar.func->name()->isame(s_construct.get()) &&
          !ar.func->name()->isame(s_86ctor.get())) {
        break;
      }
      // fallthrough
    case FPIKind::ObjMeth:
    case FPIKind::ClsMeth:
      if (ar.cls.hasValue() && ar.func->cantBeMagicCall()) {
        return reduce(
          env,
          bc::FCallD { op.arg1, ar.cls->name(), ar.func->name() }
        );
      }

      // If we didn't return a reduce above, we still can compute a
      // partially-known FCall effect with our res::Func.
      return fcallKnownImpl(env, op.arg1);
    }
  }

  for (auto i = uint32_t{0}; i < op.arg1; ++i) popF(env);
  fpiPop(env);
  specialFunctionEffects(env, ar);
  push(env, TInitGen);
}

void in(ISS& env, const bc::FCallD& op) {
  auto const ar = fpiTop(env);
  if ((ar.func && ar.func->name() != op.str3) ||
      (ar.cls && ar.cls->name() != op.str2)) {
    // We've found a more precise type for the call, so update it
    return reduce(
      env,
      bc::FCallD {
        op.arg1, ar.cls ? ar.cls->name() : s_empty.get(), ar.func->name()
      }
    );
  }
  if (ar.kind == FPIKind::Builtin) {
    return finish_builtin(env, ar.func->exactFunc(), op.arg1, false);
  }
  if (ar.func) return fcallKnownImpl(env, op.arg1);
  specialFunctionEffects(env, ar);
  for (auto i = uint32_t{0}; i < op.arg1; ++i) popF(env);
  push(env, TInitGen);
}

void in(ISS& env, const bc::FCallAwait& op) {
  auto const ar = fpiTop(env);
  if ((ar.func && ar.func->name() != op.str3) ||
      (ar.cls && ar.cls->name() != op.str2)) {
    // We've found a more precise type for the call, so update it
    return reduce(
      env,
      bc::FCallAwait {
        op.arg1, ar.cls ? ar.cls->name() : s_empty.get(), ar.func->name()
      }
    );
  }
  impl(env,
       bc::FCallD { op.arg1, op.str2, op.str3 },
       bc::UnboxRNop {},
       bc::Await {});
}

void fcallArrayImpl(ISS& env, int arg) {
  auto const ar = fpiTop(env);
  if (ar.kind == FPIKind::Builtin) {
    return finish_builtin(env, ar.func->exactFunc(), arg, true);
  }

  for (auto i = uint32_t{0}; i < arg; ++i) { popF(env); }
  fpiPop(env);
  specialFunctionEffects(env, ar);
  if (ar.func) {
    auto ty = env.index.lookup_return_type(env.ctx, *ar.func);
    if (!ar.fallbackFunc) {
      pushCallReturnType(env, std::move(ty));
      return;
    }
    auto ty2 = env.index.lookup_return_type(env.ctx, *ar.fallbackFunc);
    pushCallReturnType(env, union_of(std::move(ty), std::move(ty2)));
    return;
  }
  return push(env, TInitGen);
}

void in(ISS& env, const bc::FCallArray& /*op*/) {
  fcallArrayImpl(env, 1);
}

void in(ISS& env, const bc::FCallUnpack& op) {
  fcallArrayImpl(env, op.arg1);
}

void in(ISS& env, const bc::CufSafeArray&) {
  popR(env); popC(env); popC(env);
  push(env, TArr);
}

void in(ISS& env, const bc::CufSafeReturn&) {
  popR(env); popC(env); popC(env);
  push(env, TInitCell);
}

void in(ISS& env, const bc::DecodeCufIter& op) {
  popC(env); // func
  env.propagate(op.target, &env.state); // before iter is modifed
}

void in(ISS& env, const bc::IterInit& op) {
  auto const t1 = popC(env);
  auto ity = iter_types(t1);
  if (!ity.mayThrowOnInit) nothrow(env);

  auto const taken = [&]{
    // Take the branch before setting locals if the iter is already
    // empty, but after popping.  Similar for the other IterInits
    // below.
    freeIter(env, op.iter1);
    env.propagate(op.target, &env.state);
  };

  auto const fallthrough = [&]{
    setLoc(env, op.loc3, ity.value);
    setIter(env, op.iter1, TrackedIter { std::move(ity) });
  };

  switch (ity.count) {
    case IterTypes::Count::Empty:
      taken();
      mayReadLocal(env, op.loc3);
      jmp_setdest(env, op.target);
      break;
    case IterTypes::Count::Single:
    case IterTypes::Count::NonEmpty:
      fallthrough();
      jmp_nevertaken(env);
      break;
    case IterTypes::Count::ZeroOrOne:
    case IterTypes::Count::Any:
      taken();
      fallthrough();
      break;
  }
}

void in(ISS& env, const bc::MIterInit& op) {
  popV(env);
  env.propagate(op.target, &env.state);
  unbindLocalStatic(env, op.loc3);
  setLocRaw(env, op.loc3, TRef);
}

void in(ISS& env, const bc::IterInitK& op) {
  auto const t1 = popC(env);
  auto ity = iter_types(t1);
  if (!ity.mayThrowOnInit) nothrow(env);

  auto const taken = [&]{
    freeIter(env, op.iter1);
    env.propagate(op.target, &env.state);
  };

  auto const fallthrough = [&]{
    setLoc(env, op.loc3, ity.value);
    setLoc(env, op.loc4, ity.key);
    setIter(env, op.iter1, TrackedIter { std::move(ity) });
  };

  switch (ity.count) {
    case IterTypes::Count::Empty:
      taken();
      mayReadLocal(env, op.loc3);
      mayReadLocal(env, op.loc4);
      jmp_setdest(env, op.target);
      break;
    case IterTypes::Count::Single:
    case IterTypes::Count::NonEmpty:
      fallthrough();
      jmp_nevertaken(env);
      break;
    case IterTypes::Count::ZeroOrOne:
    case IterTypes::Count::Any:
      taken();
      fallthrough();
      break;
  }
}

void in(ISS& env, const bc::MIterInitK& op) {
  popV(env);
  env.propagate(op.target, &env.state);
  unbindLocalStatic(env, op.loc3);
  setLocRaw(env, op.loc3, TRef);
  setLoc(env, op.loc4, TInitCell);
}

void in(ISS& env, const bc::WIterInit& op) {
  popC(env);
  env.propagate(op.target, &env.state);
  // WIter* instructions may leave the value locals as either refs
  // or cells, depending whether the rhs of the assignment was a
  // ref.
  setLocRaw(env, op.loc3, TInitGen);
}

void in(ISS& env, const bc::WIterInitK& op) {
  popC(env);
  env.propagate(op.target, &env.state);
  setLocRaw(env, op.loc3, TInitGen);
  setLoc(env, op.loc4, TInitCell);
}

void in(ISS& env, const bc::IterNext& op) {
  auto const curLoc3 = locRaw(env, op.loc3);

  auto const noTaken = match<bool>(
    env.state.iters[op.iter1],
    [&] (UnknownIter)           {
      setLoc(env, op.loc3, TInitCell);
      return false;
    },
    [&] (const TrackedIter& ti) {
      if (!ti.types.mayThrowOnNext) nothrow(env);
      switch (ti.types.count) {
        case IterTypes::Count::Single:
        case IterTypes::Count::ZeroOrOne:
          return true;
        case IterTypes::Count::NonEmpty:
        case IterTypes::Count::Any:
          setLoc(env, op.loc3, ti.types.value);
          return false;
        case IterTypes::Count::Empty:
          always_assert(false);
      }
      not_reached();
    }
  );
  if (noTaken) {
    jmp_nevertaken(env);
    freeIter(env, op.iter1);
    return;
  }

  env.propagate(op.target, &env.state);

  freeIter(env, op.iter1);
  setLocRaw(env, op.loc3, curLoc3);
}

void in(ISS& env, const bc::MIterNext& op) {
  env.propagate(op.target, &env.state);
  unbindLocalStatic(env, op.loc3);
  setLocRaw(env, op.loc3, TRef);
}

void in(ISS& env, const bc::IterNextK& op) {
  auto const curLoc3 = locRaw(env, op.loc3);
  auto const curLoc4 = locRaw(env, op.loc4);

  auto const noTaken = match<bool>(
    env.state.iters[op.iter1],
    [&] (UnknownIter)           {
      setLoc(env, op.loc3, TInitCell);
      setLoc(env, op.loc4, TInitCell);
      return false;
    },
    [&] (const TrackedIter& ti) {
      if (!ti.types.mayThrowOnNext) nothrow(env);
      switch (ti.types.count) {
        case IterTypes::Count::Single:
        case IterTypes::Count::ZeroOrOne:
          return true;
        case IterTypes::Count::NonEmpty:
        case IterTypes::Count::Any:
          setLoc(env, op.loc3, ti.types.value);
          setLoc(env, op.loc4, ti.types.key);
          return false;
        case IterTypes::Count::Empty:
          always_assert(false);
      }
      not_reached();
    }
  );
  if (noTaken) {
    jmp_nevertaken(env);
    freeIter(env, op.iter1);
    return;
  }

  env.propagate(op.target, &env.state);

  freeIter(env, op.iter1);
  setLocRaw(env, op.loc3, curLoc3);
  setLocRaw(env, op.loc4, curLoc4);
}

void in(ISS& env, const bc::MIterNextK& op) {
  env.propagate(op.target, &env.state);
  unbindLocalStatic(env, op.loc3);
  setLocRaw(env, op.loc3, TRef);
  setLoc(env, op.loc4, TInitCell);
}

void in(ISS& env, const bc::WIterNext& op) {
  env.propagate(op.target, &env.state);
  setLocRaw(env, op.loc3, TInitGen);
}

void in(ISS& env, const bc::WIterNextK& op) {
  env.propagate(op.target, &env.state);
  setLocRaw(env, op.loc3, TInitGen);
  setLoc(env, op.loc4, TInitCell);
}

void in(ISS& env, const bc::IterFree& op) {
  nothrow(env);
  freeIter(env, op.iter1);
}
void in(ISS& env, const bc::MIterFree& op) {
  nothrow(env);
  freeIter(env, op.iter1);
}
void in(ISS& env, const bc::CIterFree& op) {
  nothrow(env);
  freeIter(env, op.iter1);
}

void in(ISS& env, const bc::IterBreak& op) {
  for (auto& kv : op.iterTab) freeIter(env, kv.second);
  env.propagate(op.target, &env.state);
}

/*
 * Any include/require (or eval) op kills all locals, and private properties.
 *
 * We don't need to do anything for collect.publicStatics because we'll analyze
 * the included pseudo-main separately and see any effects it may have on
 * public statics.
 */
void inclOpImpl(ISS& env) {
  popC(env);
  killLocals(env);
  killThisProps(env);
  killSelfProps(env);
  mayUseVV(env);
  push(env, TInitCell);
}

void in(ISS& env, const bc::Incl&)      { inclOpImpl(env); }
void in(ISS& env, const bc::InclOnce&)  { inclOpImpl(env); }
void in(ISS& env, const bc::Req&)       { inclOpImpl(env); }
void in(ISS& env, const bc::ReqOnce&)   { inclOpImpl(env); }
void in(ISS& env, const bc::ReqDoc&)    { inclOpImpl(env); }
void in(ISS& env, const bc::Eval&)      { inclOpImpl(env); }

void in(ISS& /*env*/, const bc::DefFunc&) {}
void in(ISS& /*env*/, const bc::DefCls&) {}
void in(ISS& /*env*/, const bc::DefClsNop&) {}
void in(ISS& env, const bc::AliasCls&) {
  popC(env);
  push(env, TBool);
}

void in(ISS& env, const bc::DefCns& op) {
  auto const t = popC(env);
  if (options.HardConstProp) {
    auto const v = tv(t);
    auto const val = v && tvAsCVarRef(&*v).isAllowedAsConstantValue() ?
      *v : make_tv<KindOfUninit>();
    auto const res = env.collect.cnsMap.emplace(op.str1, val);
    if (!res.second) {
      if (res.first->second.m_type == kReadOnlyConstant) {
        // we only saw a read of this constant
        res.first->second = val;
      } else {
        // more than one definition in this function
        res.first->second.m_type = kDynamicConstant;
      }
    }
  }
  push(env, TBool);
}

void in(ISS& /*env*/, const bc::DefTypeAlias&) {}

void in(ISS& env, const bc::This&) {
  if (thisAvailable(env)) {
    return reduce(env, bc::BareThis { BareThisOp::NeverNull });
  }
  auto const ty = thisType(env);
  push(env, ty ? *ty : TObj);
  setThisAvailable(env);
}

void in(ISS& env, const bc::LateBoundCls& op) {
  auto const ty = selfCls(env);
  putClsRefSlot(env, op.slot, ty ? *ty : TCls);
}

void in(ISS& env, const bc::CheckThis&) {
  if (thisAvailable(env)) {
    reduce(env, bc::Nop {});
  }
  setThisAvailable(env);
}

void in(ISS& env, const bc::BareThis& op) {
  if (thisAvailable(env)) {
    if (op.subop1 != BareThisOp::NeverNull) {
      return reduce(env, bc::BareThis { BareThisOp::NeverNull });
    }
  }

  auto const ty = thisType(env);
  switch (op.subop1) {
  case BareThisOp::Notice:
    break;
  case BareThisOp::NoNotice:
    nothrow(env);
    break;
  case BareThisOp::NeverNull:
    nothrow(env);
    setThisAvailable(env);
    return push(env, ty ? *ty : TObj);
  }

  push(env, ty ? opt(*ty) : TOptObj);
}

void in(ISS& env, const bc::InitThisLoc& op) {
  setLocRaw(env, op.loc1, TCell);
}

void in(ISS& env, const bc::StaticLocDef& op) {
  if (staticLocHelper(env, op.loc1, topC(env))) {
    return reduce(env, bc::SetL { op.loc1 }, bc::PopC {});
  }
  popC(env);
}

void in(ISS& env, const bc::StaticLocCheck& op) {
  auto const l = op.loc1;
  if (!env.ctx.func->isMemoizeWrapper &&
      !env.ctx.func->isClosureBody &&
      env.collect.localStaticTypes.size() > l) {
    auto t = env.collect.localStaticTypes[l];
    if (auto v = tv(t)) {
      useLocalStatic(env, l);
      setLocRaw(env, l, t);
      return reduce(env,
                    gen_constant(*v),
                    bc::SetL { op.loc1 }, bc::PopC {},
                    bc::True {});
    }
  }
  setLocRaw(env, l, TGen);
  maybeBindLocalStatic(env, l);
  push(env, TBool);
}

void in(ISS& env, const bc::StaticLocInit& op) {
  if (staticLocHelper(env, op.loc1, topC(env))) {
    return reduce(env, bc::SetL { op.loc1 }, bc::PopC {});
  }
  popC(env);
}

/*
 * Amongst other things, we use this to mark units non-persistent.
 */
void in(ISS& env, const bc::OODeclExists& op) {
  auto flag = popC(env);
  auto name = popC(env);
  push(env, [&] {
      if (!name.strictSubtypeOf(TStr)) return TBool;
      auto const v = tv(name);
      if (!v) return TBool;
      auto rcls = env.index.resolve_class(env.ctx, v->m_data.pstr);
      if (!rcls || !rcls->cls()) return TBool;
      auto const mayExist = [&] () -> bool {
        switch (op.subop1) {
          case OODeclExistsOp::Class:
            return !(rcls->cls()->attrs & (AttrInterface | AttrTrait));
          case OODeclExistsOp::Interface:
            return rcls->cls()->attrs & AttrInterface;
          case OODeclExistsOp::Trait:
            return rcls->cls()->attrs & AttrTrait;
        }
        not_reached();
      }();
      auto unit = rcls->cls()->unit;
      auto canConstProp = [&] {
        // Its generally not safe to constprop this, because of
        // autoload. We're safe if its part of systemlib, or a
        // superclass of the current context.
        if (is_systemlib_part(*unit)) return true;
        if (!env.ctx.cls) return false;
        auto thisClass = env.index.resolve_class(env.ctx.cls);
        return thisClass.subtypeOf(*rcls);
      };
      if (canConstProp()) {
        constprop(env);
        return mayExist ? TTrue : TFalse;
      }
      if (!any(env.collect.opts & CollectionOpts::Inlining)) {
        unit->persistent.store(false, std::memory_order_relaxed);
      }
      // At this point, if it mayExist, we still don't know that it
      // *does* exist, but if not we know that it either doesn't
      // exist, or it doesn't have the right type.
      return mayExist ? TBool : TFalse;
    } ());
}

void in(ISS& env, const bc::VerifyParamType& op) {
  if (env.ctx.func->isMemoizeImpl &&
      !locCouldBeRef(env, op.loc1) &&
      RuntimeOption::EvalHardTypeHints) {
    // a MemoizeImpl's params have already been checked by the wrapper
    return reduce(env, bc::Nop {});
  }

  // Generally we won't know anything about the params, but
  // analyze_func_inline does - and this can help with effect-free analysis
  auto const constraint = env.ctx.func->params[op.loc1].typeConstraint;
  if (env.index.satisfies_constraint(env.ctx,
                                     locAsCell(env, op.loc1),
                                     constraint)) {
    reduce(env, bc::Nop {});
    return;
  }

  if (!RuntimeOption::EvalHardTypeHints) return;

  /*
   * In HardTypeHints mode, we assume that if this opcode doesn't
   * throw, the parameter was of the specified type (although it may
   * have been a Ref if the parameter was by reference).
   *
   * The env.setLoc here handles dealing with a parameter that was
   * already known to be a reference.
   *
   * NB: VerifyParamType of a reference parameter can kill any
   * references if it re-enters, even if Option::HardTypeHints is
   * on.
   */
  if (!RuntimeOption::EvalCheckThisTypeHints && constraint.isThis()) {
    return;
  }
  if (constraint.hasConstraint() && !constraint.isTypeVar() &&
      !constraint.isTypeConstant()) {
    auto t = env.index.lookup_constraint(env.ctx, constraint);
    if (t.subtypeOf(TBottom)) unreachable(env);
    FTRACE(2, "     {} ({})\n", constraint.fullName(), show(t));
    setLoc(env, op.loc1, std::move(t));
  }
}

void in(ISS& /*env*/, const bc::VerifyRetTypeV& /*op*/) {}

void in(ISS& env, const bc::VerifyRetTypeC& /*op*/) {
  auto const constraint = env.ctx.func->retTypeConstraint;
  auto stackT = topC(env);

  // If there is no return type constraint, or if the return type
  // constraint is a typevar, or if the top of stack is the same
  // or a subtype of the type constraint, then this is a no-op.
  if (env.index.satisfies_constraint(env.ctx, stackT, constraint)) {
    reduce(env, bc::Nop {});
    return;
  }

  // If CheckReturnTypeHints < 3 OR if the constraint is soft,
  // then there are no optimizations we can safely do here, so
  // just leave the top of stack as is.
  if (RuntimeOption::EvalCheckReturnTypeHints < 3 || constraint.isSoft()
      || (!RuntimeOption::EvalCheckThisTypeHints && constraint.isThis())) {
    return;
  }

  // If we reach here, then CheckReturnTypeHints >= 3 AND the constraint
  // is not soft.  We can safely assume that either VerifyRetTypeC will
  // throw or it will produce a value whose type is compatible with the
  // return type constraint.
  auto tcT =
    remove_uninit(env.index.lookup_constraint(env.ctx, constraint));

  // If tcT could be an interface or trait, we upcast it to TObj/TOptObj.
  // Why?  Because we want uphold the invariant that we only refine return
  // types and never widen them, and if we allow tcT to be an interface then
  // it's possible for violations of this invariant to arise.  For an example,
  // see "hphp/test/slow/hhbbc/return-type-opt-bug.php".
  // Note: It's safe to use TObj/TOptObj because lookup_constraint() only
  // returns classes or interfaces or traits (it never returns something that
  // could be an enum or type alias) and it never returns anything that could
  // be a "magic" interface that supports non-objects.  (For traits the return
  // typehint will always throw at run time, so it's safe to use TObj/TOptObj.)
  if (is_specialized_obj(tcT) && dobj_of(tcT).cls.couldBeInterfaceOrTrait()) {
    tcT = is_opt(tcT) ? TOptObj : TObj;
  }

  auto retT = intersection_of(std::move(tcT), std::move(stackT));
  if (retT.subtypeOf(TBottom)) {
    unreachable(env);
    return;
  }

  popC(env);
  push(env, std::move(retT));
}

void in(ISS& env, const bc::Self& op) {
  auto self = selfClsExact(env);
  putClsRefSlot(env, op.slot, self ? *self : TCls);
}

void in(ISS& env, const bc::Parent& op) {
  auto parent = parentClsExact(env);
  putClsRefSlot(env, op.slot, parent ? *parent : TCls);
}

void in(ISS& env, const bc::CreateCl& op) {
  auto const nargs   = op.arg1;
  auto const clsPair = env.index.resolve_closure_class(env.ctx, op.arg2);

  /*
   * Every closure should have a unique allocation site, but we may see it
   * multiple times in a given round of analyzing this function.  Each time we
   * may have more information about the used variables; the types should only
   * possibly grow.  If it's already there we need to merge the used vars in
   * with what we saw last time.
   */
  if (nargs) {
    std::vector<Type> usedVars(nargs);
    for (auto i = uint32_t{0}; i < nargs; ++i) {
      usedVars[nargs - i - 1] = popT(env);
    }
    merge_closure_use_vars_into(
      env.collect.closureUseTypes,
      clsPair.second,
      usedVars
    );
  }

  // Closure classes can be cloned and rescoped at runtime, so it's not safe to
  // assert the exact type of closure objects. The best we can do is assert
  // that it's a subclass of Closure.
  auto const closure = env.index.builtin_class(s_Closure.get());

  return push(env, subObj(closure));
}

void in(ISS& env, const bc::CreateCont& /*op*/) {
  // First resume is always next() which pushes null.
  push(env, TInitNull);
}

void in(ISS& env, const bc::ContEnter&) { popC(env); push(env, TInitCell); }
void in(ISS& env, const bc::ContRaise&) { popC(env); push(env, TInitCell); }

void in(ISS& env, const bc::Yield&) {
  popC(env);
  push(env, TInitCell);
}

void in(ISS& env, const bc::YieldK&) {
  popC(env);
  popC(env);
  push(env, TInitCell);
}

void in(ISS& env, const bc::ContAssignDelegate&) {
  popC(env);
}

void in(ISS& env, const bc::ContEnterDelegate&) {
  popC(env);
}

void in(ISS& env, const bc::YieldFromDelegate&) {
  push(env, TInitCell);
}

void in(ISS& /*env*/, const bc::ContUnsetDelegate&) {}

void in(ISS& /*env*/, const bc::ContCheck&) {}
void in(ISS& env, const bc::ContValid&)   { push(env, TBool); }
void in(ISS& env, const bc::ContStarted&) { push(env, TBool); }
void in(ISS& env, const bc::ContKey&)     { push(env, TInitCell); }
void in(ISS& env, const bc::ContCurrent&) { push(env, TInitCell); }
void in(ISS& env, const bc::ContGetReturn&) { push(env, TInitCell); }

void pushTypeFromWH(ISS& env, const Type t) {
  if (!t.couldBe(TObj)) {
    // These opcodes require an object descending from WaitHandle.
    // Exceptions will be thrown for any non-object.
    push(env, TBottom);
    unreachable(env);
    return;
  }
  // If we aren't even sure this is a wait handle, there's nothing we can
  // infer here.  (This can happen if a user declares a class with a
  // getWaitHandle method that returns non-WaitHandle garbage.)
  if (!t.subtypeOf(TObj) || !is_specialized_wait_handle(t)) {
    return push(env, TInitCell);
  }

  auto inner = wait_handle_inner(t);
  if (inner.subtypeOf(TBottom)) {
    // If it's a WaitH<Bottom>, we know it's going to throw an exception, and
    // the fallthrough code is not reachable.
    push(env, TBottom);
    unreachable(env);
    return;
  }

  push(env, std::move(inner));
}

void in(ISS& env, const bc::WHResult&) {
  pushTypeFromWH(env, popC(env));
}

void in(ISS& env, const bc::Await&) {
  pushTypeFromWH(env, popC(env));
}

void in(ISS& /*env*/, const bc::IncStat&) {}

void in(ISS& env, const bc::Idx&) {
  popC(env); popC(env); popC(env);
  push(env, TInitCell);
}

void in(ISS& env, const bc::ArrayIdx&) {
  popC(env); popC(env); popC(env);
  push(env, TInitCell);
}

void in(ISS& env, const bc::CheckProp&) {
  if (env.ctx.cls->attrs & AttrNoOverride) {
    return reduce(env, bc::False {});
  }
  nothrow(env);
  push(env, TBool);
}

void in(ISS& env, const bc::InitProp& op) {
  auto const t = topC(env);
  switch (op.subop2) {
    case InitPropOp::Static:
      mergeSelfProp(env, op.str1, t);
      if (auto c = env.collect.publicStatics) {
        auto const cls = selfClsExact(env);
        always_assert(!!cls);
        c->merge(env.ctx, *cls, sval(op.str1), t);
      }
      break;
    case InitPropOp::NonStatic:
      mergeThisProp(env, op.str1, t);
      break;
  }
  auto const v = tv(t);
  if (v || !could_run_destructor(t)) {
    for (auto& prop : env.ctx.func->cls->properties) {
      if (prop.name == op.str1) {
        ITRACE(1, "InitProp: {} = {}\n", op.str1, show(t));
        prop.attrs = (Attr)(prop.attrs & ~AttrDeepInit);
        if (!v) break;
        prop.val = *v;
        if (op.subop2 == InitPropOp::Static &&
            !env.collect.publicStatics &&
            !env.index.frozen()) {
          env.index.fixup_public_static(env.ctx.func->cls, prop.name, t);
        }
        return reduce(env, bc::PopC {});
      }
    }
  }
  popC(env);
}

void in(ISS& env, const bc::Silence& op) {
  nothrow(env);
  switch (op.subop2) {
    case SilenceOp::Start:
      setLoc(env, op.loc1, TInt);
      break;
    case SilenceOp::End:
      break;
  }
}

void in(ISS& /*emv*/, const bc::VarEnvDynCall&) {}
}

//////////////////////////////////////////////////////////////////////

void dispatch(ISS& env, const Bytecode& op) {
#define O(opcode, ...) case Op::opcode: interp_step::in(env, op.opcode); return;
  switch (op.op) { OPCODES }
#undef O
  not_reached();
}

//////////////////////////////////////////////////////////////////////

template<class Iterator, class... Args>
void group(ISS& env, Iterator& it, Args&&... args) {
  FTRACE(2, " {}\n", [&]() -> std::string {
    auto ret = std::string{};
    for (auto i = size_t{0}; i < sizeof...(Args); ++i) {
      ret += " " + show(env.ctx.func, it[i]);
      if (i != sizeof...(Args) - 1) ret += ';';
    }
    return ret;
  }());
  it += sizeof...(Args);
  return interp_step::group(env, std::forward<Args>(args)...);
}

template<class Iterator>
void interpStep(ISS& env, Iterator& it, Iterator stop) {
  /*
   * During the analysis phase, we analyze some common bytecode
   * patterns involving conditional jumps as groups to be able to
   * add additional information to the type environment depending on
   * whether the branch is taken or not.
   */
  auto const o1 = it->op;
  auto const o2 = it + 1 != stop ? it[1].op : Op::Nop;
  auto const o3 = it + 1 != stop &&
                  it + 2 != stop ? it[2].op : Op::Nop;

  switch (o1) {
  case Op::InstanceOfD:
    switch (o2) {
    case Op::JmpZ:
      return group(env, it, it[0].InstanceOfD, it[1].JmpZ);
    case Op::JmpNZ:
      return group(env, it, it[0].InstanceOfD, it[1].JmpNZ);
    default: break;
    }
    break;
  case Op::IsTypeL:
    switch (o2) {
    case Op::JmpZ:   return group(env, it, it[0].IsTypeL, it[1].JmpZ);
    case Op::JmpNZ:  return group(env, it, it[0].IsTypeL, it[1].JmpNZ);
    default: break;
    }
    break;
  case Op::IsUninit:
    switch (o2) {
    case Op::JmpZ:   return group(env, it, it[0].IsUninit, it[1].JmpZ);
    case Op::JmpNZ:  return group(env, it, it[0].IsUninit, it[1].JmpNZ);
    default: break;
    }
    break;
  case Op::IsTypeC:
    switch (o2) {
    case Op::JmpZ:
      return group(env, it, it[0].IsTypeC, it[1].JmpZ);
    case Op::JmpNZ:
      return group(env, it, it[0].IsTypeC, it[1].JmpNZ);
    default: break;
    }
    break;
  case Op::MemoGet:
    switch (o2) {
    case Op::IsUninit:
      switch (o3) {
      case Op::JmpZ:
        return group(env, it, it[0].MemoGet, it[1].IsUninit, it[2].JmpZ);
      case Op::JmpNZ:
        return group(env, it, it[0].MemoGet, it[1].IsUninit, it[2].JmpNZ);
      default: break;
      }
      break;
    default: break;
    }
    break;
  case Op::StaticLocCheck:
    switch (o2) {
    case Op::JmpZ:
      return group(env, it, it[0].StaticLocCheck, it[1].JmpZ);
    case Op::JmpNZ:
      return group(env, it, it[0].StaticLocCheck, it[1].JmpNZ);
    default: break;
    }
    break;
  case Op::Same:
    switch (o2) {
    case Op::JmpZ:
      return group(env, it, it[0].Same, it[1].JmpZ);
    case Op::JmpNZ:
      return group(env, it, it[0].Same, it[1].JmpNZ);
    default: break;
    }
    break;
  case Op::NSame:
    switch (o2) {
    case Op::JmpZ:
      return group(env, it, it[0].NSame, it[1].JmpZ);
    case Op::JmpNZ:
      return group(env, it, it[0].NSame, it[1].JmpNZ);
    default: break;
    }
    break;
  default: break;
  }

  FTRACE(2, "  {}\n", show(env.ctx.func, *it));
  dispatch(env, *it++);
}

template<class Iterator>
StepFlags interpOps(Interp& interp,
                    Iterator& iter, Iterator stop,
                    PropagateFn propagate) {
  auto flags = StepFlags{};
  ISS env { interp, flags, propagate };

  // If there are factored edges, make a copy of the state (except
  // stacks) in case we need to propagate across factored exits (if
  // it's a PEI).
  auto const stateBefore = interp.blk->factoredExits.empty()
    ? State{}
    : without_stacks(interp.state);

  auto const numPushed   = iter->numPush();
  interpStep(env, iter, stop);

  auto fix_const_outputs = [&] {
    auto elems = &interp.state.stack.back();
    constexpr auto numCells = 4;
    Cell cells[numCells];

    auto i = size_t{0};
    while (i < numPushed) {
      if (i < numCells) {
        auto const v = tv(elems->type);
        if (!v) return false;
        cells[i] = *v;
      } else if (!is_scalar(elems->type)) {
        return false;
      }
      ++i;
      --elems;
    }
    while (++elems, i--) {
      elems->type = from_cell(i < numCells ?
                              cells[i] : *tv(elems->type));
    }
    return true;
  };

  if (options.ConstantProp && flags.canConstProp && fix_const_outputs()) {
    if (flags.wasPEI) {
      FTRACE(2, "   nothrow (due to constprop)\n");
      flags.wasPEI = false;
    }
    if (!flags.effectFree) {
      FTRACE(2, "   effect_free (due to constprop)\n");
      flags.effectFree = true;
    }
  }

  assertx(!flags.effectFree || !flags.wasPEI);
  if (flags.wasPEI) {
    FTRACE(2, "   PEI.\n");
    for (auto factored : interp.blk->factoredExits) {
      propagate(factored, &stateBefore);
    }
  }
  return flags;
}

//////////////////////////////////////////////////////////////////////

RunFlags run(Interp& interp, PropagateFn propagate) {
  SCOPE_EXIT {
    FTRACE(2, "out {}{}\n",
           state_string(*interp.ctx.func, interp.state, interp.collect),
           property_state_string(interp.collect.props));
  };

  auto ret = RunFlags {};
  auto const stop = end(interp.blk->hhbcs);
  auto iter       = begin(interp.blk->hhbcs);
  while (iter != stop) {
    auto const flags = interpOps(interp, iter, stop, propagate);
    if (interp.collect.effectFree && !flags.effectFree) {
      interp.collect.effectFree = false;
      if (any(interp.collect.opts & CollectionOpts::EffectFreeOnly)) {
        FTRACE(2, "  Bailing because not effect free\n");
        return ret;
      }
    }

    if (flags.usedLocalStatics) {
      if (!ret.usedLocalStatics) {
        ret.usedLocalStatics = std::move(flags.usedLocalStatics);
      } else {
        for (auto& elm : *flags.usedLocalStatics) {
          ret.usedLocalStatics->insert(std::move(elm));
        }
      }
    }

    if (interp.state.unreachable) {
      FTRACE(2, "  <bytecode fallthrough is unreachable>\n");
      return ret;
    }

    if (flags.jmpDest != NoBlockId &&
        flags.jmpDest != interp.blk->fallthrough) {
      FTRACE(2, "  <took branch; no fallthrough>\n");
      return ret;
    }

    if (flags.returned) {
      FTRACE(2, "  returned {}\n", show(*flags.returned));
      always_assert(iter == stop);
      always_assert(interp.blk->fallthrough == NoBlockId);
      ret.returned = flags.returned;
      return ret;
    }
  }

  FTRACE(2, "  <end block>\n");
  if (interp.blk->fallthrough != NoBlockId) {
    propagate(interp.blk->fallthrough, &interp.state);
  }
  return ret;
}

StepFlags step(Interp& interp, const Bytecode& op) {
  auto flags   = StepFlags{};
  auto noop    = [] (BlockId, const State*) {};
  ISS env { interp, flags, noop };
  dispatch(env, op);
  return flags;
}

void default_dispatch(ISS& env, const Bytecode& op) {
  dispatch(env, op);
}

//////////////////////////////////////////////////////////////////////

}}
