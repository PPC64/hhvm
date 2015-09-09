/*
   +----------------------------------------------------------------------+
   | HipHop for PHP                                                       |
   +----------------------------------------------------------------------+
   | Copyright (c) 2010-2013 Facebook, Inc. (http://www.facebook.com)     |
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

#include "hphp/runtime/vm/jit/vasm-emit.h"

#include "hphp/runtime/base/arch.h"
#include "hphp/runtime/vm/jit/abi-ppc64.h"
#include "hphp/runtime/vm/jit/back-end-ppc64.h"
#include "hphp/runtime/vm/jit/block.h"
#include "hphp/runtime/vm/jit/code-gen-helpers-ppc64.h"
#include "hphp/runtime/vm/jit/code-gen.h"
#include "hphp/runtime/vm/jit/func-guard-ppc64.h"
#include "hphp/runtime/vm/jit/mc-generator.h"
#include "hphp/runtime/vm/jit/print.h"
#include "hphp/runtime/vm/jit/prof-data.h"
#include "hphp/runtime/vm/jit/service-requests.h"
#include "hphp/runtime/vm/jit/smashable-instr-ppc64.h"
#include "hphp/runtime/vm/jit/target-cache.h"
#include "hphp/runtime/vm/jit/timer.h"
#include "hphp/runtime/vm/jit/vasm.h"
#include "hphp/runtime/vm/jit/vasm-instr.h"
#include "hphp/runtime/vm/jit/vasm-internal.h"
#include "hphp/runtime/vm/jit/vasm-print.h"
#include "hphp/runtime/vm/jit/vasm-unit.h"
#include "hphp/runtime/vm/jit/vasm-util.h"
#include "hphp/runtime/vm/jit/vasm-visit.h"

#include <algorithm>
#include <tuple>

TRACE_SET_MOD(vasm);

namespace HPHP { namespace jit {

///////////////////////////////////////////////////////////////////////////////

using namespace ppc64;
using namespace ppc64_asm;

namespace ppc64 { struct ImmFolder; }

namespace {
///////////////////////////////////////////////////////////////////////////////

struct Vgen {
  explicit Vgen(Venv& env)
    : text(env.text)
    , assem(*env.cb)
    , a(&assem)
    , current(env.current)
    , next(env.next)
    , jmps(env.jmps)
    , jccs(env.jccs)
    , catches(env.catches)
  {}

  static void patch(Venv& env);
  static void pad(CodeBlock& cb);

  /////////////////////////////////////////////////////////////////////////////

  template<class Inst> void emit(const Inst& i) {
    always_assert_flog(false, "unimplemented instruction: {} in B{}\n",
                       vinst_names[Vinstr(i).op], size_t(current));
  }

  // auxiliary
  inline void pushMinCallStack(void)
  {
    a->mflr(ppc64_asm::reg::r0);
    // LR on parent call frame
    Vptr p(ppc64_asm::reg::r1, 16);
    a->std(ppc64_asm::reg::r0, p);
    // minimum call stack
    p.disp = -32;
    a->stdu(ppc64_asm::reg::r1, p);
  }

  inline void popMinCallStack(void)
  {
    // minimum call stack
    a->addi(ppc64_asm::reg::r1, ppc64_asm::reg::r1, 32);
    // LR on parent call frame
    Vptr p(ppc64_asm::reg::r1, 16);
    a->ld(ppc64_asm::reg::r0, p);
    a->mtlr(ppc64_asm::reg::r0);
  }

  /*
   * Calculates the effective address of Vptr s and stores on Register d
   */
  inline void VptrAddressToReg(Vptr s, Vreg d) {
    // TODO(rcardoso): we always have to emit a shift left? even if the scale 
    // is equal 1?
    if (s.index.isValid()) {
      // Calculate index position before adding base and displacement 
      int n = 0;
      int scale = s.scale;
      while (scale >>= 1) {
        ++n;
      }
      assert(n <= 3);
      // scale factor is always 1, 2, 4 or, 8
      // so we can performe index*scale doing a shift left
      emit(shlqi{n, s.index, d, VregSF(0)});

      if (s.base.isValid())
        emit(addq {s.base, d, d, VregSF(0)});
      emit(addqi{s.disp, d, d, VregSF(0)});

    } else {
      // Indexless
      if (s.base.isValid()) {
        // Base + Displacement
        emit(addqi{s.disp, s.base, d, VregSF(0)});
      } else {
        // Baseless
        emit(ldimmq{s.disp, d});
      }
    }
    //TODO(rcardoso): We can insert this here and get rid of VptrToReg function?
    //emit(load{*d, d});
  }

  /*
   * Stores in d the value pointed by s
   */
  inline void VptrToReg(Vptr s, Vreg d) {
    VptrAddressToReg(s, d);
    emit(load{*d, d}); //TODO(rcardoso): ??
  }

  /*
   * We can have the following address modes in X64
   *
   * - Direct Operand: displacement
   * - Indirect Operand: (base)
   * - Base + Displacement: displacement(base)
   * - (Index * Scale) + Displacement: displacement(,index,scale)
   * - Base + Index + Displacement: displacement(base,index)
   * - Base +(Index * Scale) + Displacement: displacement(base, index,scale)
   * 
   * In PPC64 we have:
   * - Direct Operand: displacement (Form-D)
   * - Indirect Operand: (Base with displacement = 0) (Form-D)
   * - Base + Index: Index(Base) (Form-X)
   * 
   *  If we have displacement > 16 bits we have to use Form-X. So if we get
   *  a Vptr with a unsupported adress mode (like Index * Scale) we need 
   *  to convert (patch) this address mode to a supported address mode.
   */
  inline void PatchMemoryOperands(Vptr s) {
    // we do nothing for supported address modes
    if(s.index.isValid() || ((s.disp >> 16) > 0)) {
      // fix index register
      VptrToReg(s, s.index);
    }
  }

  // intrinsics
  void emit(const callarray& i) { not_implemented(); } ;
  void emit(const callfaststub& i) { not_implemented(); }
  void emit(const contenter& i) { not_implemented(); }
  void emit(const copy& i) {
    if (i.s == i.d) return;
    if (i.s.isGP()) {
      if (i.d.isGP()) {                 // GP => GP
        a->mr(i.d, i.s);
      } else {                             // GP => XMM
        assertx(i.d.isSIMD());
        not_implemented();
      }
    } else {
      if (i.d.isGP()) {                 // XMM => GP
        not_implemented();
      } else {                             // XMM => XMM
        assertx(i.d.isSIMD());
        not_implemented();
      }
    }  }
  void emit(const copy2& i) {
    assertx(i.s0.isValid() && i.s1.isValid() &&
            i.d0.isValid() && i.d1.isValid());
    auto s0 = i.s0, s1 = i.s1, d0 = i.d0, d1 = i.d1;
    assertx(d0 != d1);
    if (d0 == s1) {
      if (d1 == s0) {
        a->mr(ppc64::rvasmtmp(),s1);
        a->mr(d0,s0);
        a->mr(d1,ppc64::rvasmtmp());
      } else {
        // could do this in a simplify pass
        if (s1 != d1) a->mr(d1, s1); // save s1 first; d1 != s0
        if (s0 != d0) a->mr(d0, s0);
      }
    } else {
      // could do this in a simplify pass
      if (s0 != d0) a->mr(d0, s0);
      if (s1 != d1) a->mr(d1, s1);
    }
  }
  void emit(const debugtrap& i) { not_implemented(); }
  void emit(const fallthru& i) {}
  void emit(const ldimmb& i) { not_implemented(); }
  void emit(const ldimml& i) { not_implemented(); }
  void emit(const ldimmq& i) {
    auto val = i.s.q();
    if (i.d.isGP()) {
      if (val == 0) {
        a->xor_(i.d, i.d, i.d);
      } else {
        a->li64(i.d, val);
      }
    } else {
      not_implemented();
    }
  }
  void emit(const ldimmqs& i) { not_implemented(); }
  void emit(const load& i);
  void emit(const mccall& i) { not_implemented(); }
  void emit(const mcprep& i) { not_implemented(); }
  void emit(const nothrow& i) { not_implemented(); }
  void emit(const store& i);
  void emit(const syncpoint& i) { not_implemented(); }
  void emit(const unwind& i) { not_implemented(); }
  void emit(const landingpad& i) { not_implemented(); }
  void emit(const vret& i);
  void emit(const leavetc&) { not_implemented(); }

  // instructions
  void emit(addli i) {
    /* add of immediate up to 32bits */
    if (!i.s0.fits(HPHP::sz::word)) {
      // d = (s0@h + s1@h) + (s0@l + s1@l)
      a->li32(ppc64::rvasmtmp(), i.s0.l());
      a->add(Reg64(i.d), Reg64(i.d), ppc64::rvasmtmp());
    } else {
      // d = s0@l + s1@l
      a->addi(Reg64(i.d), Reg64(i.s1), i.s0);
    }
  }
  void emit(const addlm& i) { not_implemented(); }
  void emit(addq i) { a->add(i.d, i.s0, i.s1, false); }
  void emit(addqi i) { a->addi(i.d, i.s1, i.s0); }
  void emit(const addqim& i) { not_implemented(); }
  void emit(addsd i) { not_implemented(); }
  void emit(andb i) {  a->and_(Reg64(i.d), Reg64(i.s0), Reg64(i.s1), false); }
  void emit(andbi i) { a->andi(Reg64(i.d), Reg64(i.s1), i.s0); }
  void emit(const andbim& i) { not_implemented(); }
  void emit(andl i) { a->and_(Reg64(i.d), Reg64(i.s0), Reg64(i.s1), false); }
  void emit(andli i) {
    /* and of immediate up to 32bits */
    if (!i.s0.fits(HPHP::sz::word)) {
      // d = (s0@h & s1@h) | (s0@l & s1@l)
      a->li32un(ppc64::rvasmtmp(), i.s0.l());
      a->and_(Reg64(i.d), ppc64::rvasmtmp(), Reg64(i.d));
    } else {
      // d = s0@l & s1@l
      a->andi(Reg64(i.d), Reg64(i.s1), i.s0);
    }
  }
  void emit(andq i) { a->and_(i.d, i.s0, i.s1, false); }
  void emit(andqi i) { a->andi(i.d, i.s1, i.s0); }
  void emit(const call& i) {
    // Need to create a new call stack in order to recover LR in the future
    pushMinCallStack();

    a->branchAuto(i.target, BranchConditions::Always, LinkReg::Save);
  }
  void emit(const callm& i) {
    // uses scratch register
    VptrToReg(i.target, ppc64::rvasmtmp());
    emit(callr{ppc64::rvasmtmp(), i.args});
  }
  void emit(const callr& i) {
    a->mtctr(i.target);
    a->bctrl();
  }
  void emit(const cloadq& i) { not_implemented(); }
  void emit(const cmovq& i) { not_implemented(); }
  void emit(const cmpb& i) { a->cmp(0, 0, Reg64(i.s0), Reg64(i.s1)); }
  void emit(const cmpbi& i) { a->cmpi(0, 0, Reg64(i.s1), i.s0); }
  void emit(const cmpbim& i) {
    VptrToReg(i.s1, ppc64::rvasmtmp());
    a->cmpi(0, 0, ppc64::rvasmtmp(), i.s0);
  }
  void emit(const cmpl& i) {  a->cmp(0, 0, Reg64(i.s0), Reg64(i.s1)); }
  void emit(const cmpli& i) { a->cmpi(0, 0, Reg64(i.s1), i.s0); }
  void emit(const cmplim& i) {
    VptrToReg(i.s1, ppc64::rvasmtmp());
    a->cmpi(0, 0, ppc64::rvasmtmp(), i.s0);
  }
  void emit(const cmplm& i) { not_implemented(); }
  //TODO(IBM): field 1 indicates cr (cr0) register who holds the bf result
  void emit(const cmpq& i) { a->cmp(0, 0, i.s0, i.s1); }
  //TODO(IBM): field 1 indicates cr (cr0) register who holds the bf result
  void emit(const cmpqi& i) { a->cmpi(0, 0, i.s1, i.s0); }
  void emit(const cmpqim& i) {
    VptrToReg(i.s1, ppc64::rvasmtmp());
    a->cmpdi(ppc64::rvasmtmp(), i.s0);
  }
  void emit(const cmpqm& i) {
    VptrToReg(i.s1, ppc64::rvasmtmp());
    a->cmp(0, 0, i.s0, ppc64::rvasmtmp());
  }
  void emit(cmpsd i) { not_implemented(); }
  void emit(const cqo& i) { not_implemented(); }
  void emit(const cvttsd2siq& i) { not_implemented(); }
  void emit(const cvtsi2sd& i) { not_implemented(); }
  void emit(const cvtsi2sdm& i) { not_implemented(); }
  void emit(decl i) { a->addi(Reg64(i.d), Reg64(i.s), -1); }
  void emit(const declm& i) {
    a->addi(ppc64::rvasmtmp(), ppc64::rvasmtmp(), -1);
    emit(store{ppc64::rvasmtmp() ,i.m});
  }
  void emit(decq i) { a->addi(i.d, i.s, -1); }
  void emit(const decqm& i) { not_implemented(); }
  void emit(divsd i) { not_implemented(); }
  void emit(imul i) { a->mullw(i.d, i.s1, i.s0, false); }
  void emit(const idiv& i) { not_implemented(); }
  void emit(incl i) { a->addi(Reg64(i.d), Reg64(i.s), 1); }
  void emit(const inclm& i) { not_implemented(); }
  void emit(incq i) { a->addi(i.d, i.s, 1); }
  void emit(const incqm& i) { not_implemented(); }
  void emit(const incqmlock& i) { not_implemented(); }
  void emit(const incwm& i) { a->addi(i.m.base, i.m.index, i.m.disp); }
  void emit(const jcc& i) {
    if (i.targets[1] != i.targets[0]) {
      if (next == i.targets[1]) {
        return emit(jcc{ccNegate(i.cc), i.sf, {i.targets[1], i.targets[0]}});
      }
      auto taken = i.targets[1];
      jccs.push_back({a->frontier(), taken});

      // offset to be determined by a->patchBc
      a->bc(i.cc, 0);
    }
    emit(jmp{i.targets[0]});
  }
  void emit(const jcci& i) { not_implemented(); }
  void emit(const jmp& i) {
    if (next == i.target) return;
    jmps.push_back({a->frontier(), i.target});

    // offset to be determined by a->patchBc
    BranchParams bp(BranchConditions::Always);
    a->bc(bp.bo(), bp.bi(), 0);
  }
  void emit(const jmpr& i) {
    a->mtctr(i.target);
    a->bctr();
  }
  void emit(const jmpm& i) {
    // uses scratch register
    VptrToReg(i.target, ppc64::rvasmtmp());
    emit(jmpr {ppc64::rvasmtmp(), i.args});
  }
  void emit(const jmpi& i) {
    a->branchAuto(i.target, BranchConditions::Always, LinkReg::DoNotTouch);
  }
  void emit(const lea& i) { a->addi(i.d, i.s.base, i.s.disp); }
  void emit(const leap& i) { not_implemented(); }
  void emit(const loadups& i) { not_implemented(); }
  void emit(const loadtqb& i) { not_implemented(); }
  void emit(const loadl& i) {
    PatchMemoryOperands(i.s);
    if(i.s.index.isValid()) {
      a->lwzx(Reg64(i.d), i.s);
    } else {
      a->lwz(Reg64(i.d), i.s);
    } 
  }
  void emit(const loadqp& i) { not_implemented(); }
  void emit(const loadsd& i) { not_implemented(); }
  void emit(const loadzbl& i) {
    PatchMemoryOperands(i.s); 
    if(i.s.index.isValid()) {
      a->lbzx(Reg64(i.d), i.s);
    } else {
      a->lbz(Reg64(i.d), i.s);
    } 
  } 
  void emit(const loadzbq& i) {
    PatchMemoryOperands(i.s);
    if(i.s.index.isValid()) {
      a->lbzx(i.d, i.s);
    } else {
      a->lbz(i.d, i.s);
    } 
  }
  void emit(const loadzlq& i) {
    PatchMemoryOperands(i.s);
    if(i.s.index.isValid()) {
      a->lwzx(i.d, i.s);
    } else {
      a->lwz(i.d, i.s);
    } 
  }
  void emit(movb& i) { a->ori(Reg64(i.d), Reg64(i.s), 0); }
  void emit(movl& i) { a->ori(Reg64(i.d), Reg64(i.s), 0); }
  void emit(movzbl& i) { a->ori(Reg64(i.d), Reg64(i.s), 0); }
  void emit(movzbq& i) { a->ori(i.d, Reg64(i.s), 0); }
  void emit(mulsd i) { not_implemented(); }
  void emit(neg i) { a->neg(i.d, i.s, false); }
  void emit(const nop& i) { a->ori(Reg64(0), Reg64(0), 0); } //no-op form
  void emit(not i) { a->nor(i.d, i.s, i.s, false); }
  void emit(notb i) { not_implemented(); }
  void emit(const orwim& i) { not_implemented(); }
  void emit(orq i) { a->or_(i.d, i.s0, i.s1, false); }
  void emit(orqi i) { a->ori(i.d, i.s1, i.s0); }
  void emit(const orqim& i) { not_implemented(); }
  void emit(const pop& i);
  void emit(const popm& i) { not_implemented(); }
  void emit(psllq i) { not_implemented(); }
  void emit(psrlq i) { not_implemented(); }
  void emit(const push& i);
  void emit(const roundsd& i) { not_implemented(); }
  void emit(const ret& i) {
    // recover LR from callstack
    popMinCallStack();
    a->blr();
  }
  /*Immediate-form logical (unsigned) shift operations are
    obtained by specifying appropriate masks and shift values for 
    certain Rotate instructions.
  */
  void emit(const sarq& i) { not_implemented(); }
  void emit(sarqi i) { a->srawi(i.d, i.s1, Reg64(i.s0.w()), false); }
  void emit(const setcc& i) { not_implemented(); }
  void emit(shlli i) { a->slwi(Reg64(i.d), Reg64(i.s1), i.s0.b()); }
  void emit(shlq i) { not_implemented(); }
  /*TODO Rc=1*/
  void emit(shlqi i) { a->sldi(i.d, i.s1, i.s0.b()); }
  void emit(shrli i) { a->srwi(Reg64(i.d), Reg64(i.s1), i.s0.b()); }
  void emit(shrqi i) { a->srdi(i.d, i.s1, i.s0.b()); }
  void emit(const sqrtsd& i) { not_implemented(); }
  void emit(const storeups& i) { not_implemented(); }
  void emit(const storeb& i) { 
    if(i.m.index.isValid()) {
      a->stbx(Reg64(i.s), i.m);
    } else {
      a->stb(Reg64(i.s), i.m);
    }
  }
  void emit(const storebi& i) { not_implemented(); }
  void emit(const storel& i) { 
    if(i.m.index.isValid()) {
      a->stwx(Reg64(i.s), i.m);
    } else {
      a->stw(Reg64(i.s), i.m);
    }
  }
  void emit(const storeli& i) { not_implemented(); }
  void emit(const storeqi& i) { not_implemented(); }
  void emit(const storesd& i) { not_implemented(); }
  void emit(const storew& i) { 
    if(i.m.index.isValid()) {
      a->sthx(Reg64(i.s), i.m);
    } else {
      a->sth(Reg64(i.s), i.m);
    } 
  }
  void emit(const storewi& i) { not_implemented(); }
  void emit(subbi i) { not_implemented(); }
  void emit(subl i) { a->subf(Reg64(i.d), Reg64(i.s1), Reg64(i.s0), false); }
  void emit(subli i) { a->addi(Reg64(i.s1), Reg64(i.d), i.s0); }
  void emit(subq i) { a->subf(i.d, i.s1, i.s0, false); }
  void emit(subqi i) { a->addi(i.s1, i.d, i.s0); /*addi with negative value*/ }
  void emit(subsd i) { not_implemented(); }
  void emit(const testb& i) {
    a->and_(ppc64::rvasmtmp(), Reg64(i.s0), Reg64(i.s1), true);
  }
  void emit(const testbi& i) { a->andi(ppc64::rvasmtmp(), Reg64(i.s1), i.s0); }
  void emit(const testbim& i) {
    a->lbz(ppc64::rvasmtmp(), i.s1.mr());
    emit(testbi{i.s0, ppc64::rvasmtmp(), i.sf});
  }
  void emit(const testwim& i) {
    a->lhz(ppc64::rvasmtmp(), i.s1);
    emit(testli{i.s0, ppc64::rvasmtmp(), i.sf});
  }
  void emit(const testl& i) {
    a->and_(ppc64::rvasmtmp(), Reg64(i.s0), Reg64(i.s1), true);
  }
  void emit(const testli& i) { a->andi(ppc64::rvasmtmp(), Reg64(i.s1), i.s0); }
  void emit(const testlim& i) {
    a->lwz(ppc64::rvasmtmp(), i.s1);
    emit(testli{i.s0, ppc64::rvasmtmp(), i.sf});
  }
  void emit(const testq& i) { a->and_(ppc64::rvasmtmp(), i.s0, i.s1, true); }
  void emit(const testqi& i) { a->andi(ppc64::rvasmtmp(), i.s1, i.s0); }
  void emit(const testqm& i) {
    a->ld(ppc64::rvasmtmp(), i.s1);
    emit(testq{i.s0, ppc64::rvasmtmp(), i.sf});
  }
  void emit(const testqim& i) {
    a->ld(ppc64::rvasmtmp(), i.s1);
    emit(testqi{i.s0, ppc64::rvasmtmp(), i.sf});
  }
  void emit(const ucomisd& i) { not_implemented(); }
  void emit(const ud2& i) { a->trap(); }
  void emit(unpcklpd i) { not_implemented(); }
  void emit(xorb i) { a->xor_(Reg64(i.d), Reg64(i.s0), Reg64(i.s1), false); }
  void emit(xorbi i) { a->xori(Reg64(i.d), Reg64(i.s1), i.s0); }
  void emit(xorl i) { a->xor_(Reg64(i.d), Reg64(i.s0), Reg64(i.s1), false); }
  void emit(xorq i) { a->xor_(i.d, i.s0, i.s1, false); }
  void emit(xorqi i) { a->xori(i.d, i.s1, i.s0); }

private:
  // helpers
  //void prep(Reg8 s, Reg8 d) { if (s != d) a->movb(s, d); }
  //void prep(Reg32 s, Reg32 d) { if (s != d) a->movl(s, d); }
  //void prep(Reg64 s, Reg64 d) { if (s != d) a->movq(s, d); }
  //void prep(RegXMM s, RegXMM d) { if (s != d) a->movdqa(s, d); }

  template<class Inst> void unary(Inst& i) { prep(i.s, i.d); }
  template<class Inst> void binary(Inst& i) { prep(i.s1, i.d); }
  template<class Inst> void commuteSF(Inst&);
  template<class Inst> void commute(Inst&);
  template<class Inst> void noncommute(Inst&);

  CodeBlock& frozen() { return text.frozen().code; }

private:
  Vtext& text;
  ppc64_asm::Assembler assem;
  ppc64_asm::Assembler* a;

  const Vlabel current;
  const Vlabel next;
  jit::vector<Venv::LabelPatch>& jmps;
  jit::vector<Venv::LabelPatch>& jccs;
  jit::vector<Venv::LabelPatch>& catches;
};

void Vgen::emit(const pop& i) {
  not_implemented();
  //TODO(IBM): Instruction pop. Check if this the best way to do this.
  //a->lwz r0 0(rVmSp)
  //a->addi rVmSp, rVmSp +4
}

void Vgen::emit(const push& i) {
  not_implemented();
  //TODO(IBM): Instruction push. Check if this the best way to do this.
  //a->addi rVmSp, rVmSp -4
  //a->stw r0 0(rVmSp)
}

void Vgen::emit(const vret& i) {
  not_implemented();
  //TODO(IBM): Need to be MemoryRef
  a->bclr(20,0,0); /*brl 0x4e800020*/
}
void Vgen::emit(const load& i) {
  if (i.d.isGP()) {
    a->lwz(i.d, i.s);
  } else {
    assertx(i.d.isSIMD());
    a->lfs(i.d, i.s);
  }
}

void Vgen::patch(Venv& env) {
  for (auto& p : env.jmps) {
    assertx(env.addrs[p.target]);
    ppc64_asm::Assembler::patchBc(p.instr, env.addrs[p.target]);
  }
  for (auto& p : env.jccs) {
    assertx(env.addrs[p.target]);
    ppc64_asm::Assembler::patchBc(p.instr, env.addrs[p.target]);
  }
  assertx(env.bccs.empty());
}

void Vgen::pad(CodeBlock& cb) {
  not_implemented();
}

void Vgen::emit(const store& i) {
  if (i.s.isGP()) {
    a->stw(i.s, i.d);
  } else {
    assertx(i.s.isSIMD());
    // TODO(rcardoso) : Unsupported
  }
}

///////////////////////////////////////////////////////////////////////////////

void lower(Vunit& unit) {
  Timer _t(Timer::vasm_lower);
  for (size_t b = 0; b < unit.blocks.size(); ++b) {
    auto& code = unit.blocks[b].code;
    if (code.empty()) continue;
    for (size_t i = 0; i < unit.blocks[b].code.size(); ++i) {
      auto& inst = unit.blocks[b].code[i];
      switch (inst.op) {
        case Vinstr::defvmsp:
          inst = copy{rvmsp(), inst.defvmsp_.d};
          break;
        case Vinstr::syncvmsp:
          inst = copy{inst.syncvmsp_.s, rvmsp()};
          break;
        default:
          break;
      }
    }
  }
}

/*
 * Some vasm opcodes don't have equivalent single instructions on PPC64, and the
 * equivalent instruction sequences require scratch registers.  We have to
 * lower these to PPC64-suitable vasm opcodes before register allocation.
 */
template<typename Inst>
void lower(Inst& i, Vout& v) {
  v << i;
}

/*
 Lower facilitate code generation. In some cases is used because 
 some vasm opcodes doesn't have a 1:1 mapping to machine asm code.
*/
void lowerForPPC64(Vunit& unit) {
  assertx(check(unit));

  // block order doesn't matter, but only visit reachable blocks.
  auto blocks = sortBlocks(unit);

  for (auto b : blocks) {
    auto oldCode = std::move(unit.blocks[b].code);
    Vout v{unit, b};

    for (auto& inst : oldCode) {
      v.setOrigin(inst.origin);

      switch (inst.op) {
#define O(nm, imm, use, def) \
        case Vinstr::nm: \
          lower(inst.nm##_, v); \
          break;

        VASM_OPCODES
#undef O
      }
    }
  }

  assertx(check(unit));
  // no tweeking for the moment, let's use ARM's parameter
  printUnit(kVasmARMFoldLevel, "after lower for PPC64", unit);
}
///////////////////////////////////////////////////////////////////////////////
} // anonymous namespace

void optimizePPC64(Vunit& unit, const Abi& abi) {
  optimizeExits(unit);
  lower(unit);
  simplify(unit);
  if (!unit.constToReg.empty()) {
    // TODO(gustavo): implement a foldImms for ppc64
    //foldImms<ppc64::ImmFolder>(unit);
  }
  lowerForPPC64(unit);
  if (unit.needsRegAlloc()) {
    Timer _t(Timer::vasm_xls);
    removeDeadCode(unit);
    allocateRegisters(unit, abi);
  }
  if (unit.blocks.size() > 1) {
    Timer _t(Timer::vasm_jumps);
    optimizeJmps(unit);
  }
}

void emitPPC64(const Vunit& unit, Vtext& text, AsmInfo* asmInfo) {
  Timer timer(Timer::vasm_gen);
  vasm_emit<Vgen>(unit, text, asmInfo);
}

///////////////////////////////////////////////////////////////////////////////
}}
