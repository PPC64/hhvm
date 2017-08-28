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

#include "hphp/compiler/analysis/constant_table.h"
#include <vector>
#include "hphp/compiler/analysis/analysis_result.h"
#include "hphp/compiler/analysis/code_error.h"
#include "hphp/compiler/code_generator.h"
#include "hphp/compiler/expression/expression.h"
#include "hphp/compiler/expression/scalar_expression.h"
#include "hphp/compiler/option.h"
#include "hphp/util/hash.h"
#include "hphp/compiler/analysis/class_scope.h"

using namespace HPHP;

///////////////////////////////////////////////////////////////////////////////

ConstantTable::ConstantTable(BlockScope &blockScope)
    : SymbolTable(blockScope)
    , m_hasDynamic(false)
    , m_hasDependencies(false) {
}

///////////////////////////////////////////////////////////////////////////////

void ConstantTable::add(const std::string& name, ExpressionPtr exp,
                        AnalysisResultConstRawPtr, ConstructPtr construct) {

  if (name == "true" || name == "false") {
    return;
  }

  Symbol *sym = genSymbol(name, true);
  if (!sym->declarationSet()) {
    assert(!sym->valueSet());
    sym->setDeclaration(construct);
    sym->setValue(exp);
    return;
  }
  assert(sym->declarationSet() && sym->valueSet());

  if (m_blockScope.isFirstPass()) {
    if (construct) {
      if (exp != sym->getValue()) {
        Compiler::Error(Compiler::DeclaredConstantTwice, construct,
                        sym->getDeclaration());
        if (!sym->isDynamic()) {
          sym->setDynamic();
          m_hasDynamic = true;
        }
      }
    } else if (exp) {
      sym->setValue(exp);
    }
  }
}

void ConstantTable::setDynamic(AnalysisResultConstRawPtr /*ar*/, Symbol* sym) {
  if (!sym->isDynamic()) {
    Lock lock(BlockScope::s_constMutex);
    sym->setDynamic();
    if (sym->getDeclaration()) {
      sym->getDeclaration()->getScope()->
        addUpdates(BlockScope::UseKindConstRef);
    }
    m_hasDynamic = true;
  }
}

void ConstantTable::setDynamic(AnalysisResultConstRawPtr ar,
                               const std::string &name) {
  setDynamic(ar, genSymbol(name, true));
}

void ConstantTable::setValue(AnalysisResultConstRawPtr /*ar*/,
                             const std::string& name, ExpressionPtr value) {
  Symbol *sym = getSymbol(name);
  assert(sym && sym->isPresent());
  sym->setValue(value);
}

bool ConstantTable::isRecursivelyDeclared(AnalysisResultConstRawPtr ar,
                                          const std::string &name) const {
  if (const Symbol *sym ATTRIBUTE_UNUSED = getSymbol(name)) {
    assert(sym->isPresent() && sym->valueSet());
    return true;
  }
  ClassScopePtr parent = findParent(ar, name);
  if (parent) {
    return parent->getConstants()->isRecursivelyDeclared(ar, name);
  }
  return false;
}

ConstructPtr ConstantTable::getValueRecur(AnalysisResultConstRawPtr ar,
                                          const std::string &name,
                                          ClassScopePtr &defClass) const {
  if (const Symbol *sym = getSymbol(name)) {
    assert(sym->isPresent() && sym->valueSet());
    if (sym->isDynamic()) return ConstructPtr();
    if (auto val = sym->getValue()) return val;
  }
  ClassScopePtr parent = findParent(ar, name);
  if (parent) {
    defClass = parent;
    return parent->getConstants()->getValueRecur(ar, name, defClass);
  }
  return ConstructPtr();
}

ConstructPtr ConstantTable::getDeclarationRecur(AnalysisResultConstRawPtr ar,
                                                const std::string &name,
                                                ClassScopePtr &defClass)
const {
  if (const Symbol *sym = getSymbol(name)) {
    assert(sym->isPresent() && sym->valueSet());
    if (sym->getDeclaration()) return sym->getDeclaration();
  }
  ClassScopePtr parent = findParent(ar, name);
  if (parent) {
    defClass = parent;
    return parent->getConstants()->getDeclarationRecur(ar, name, defClass);
  }
  return ConstructPtr();
}

void ConstantTable::recordDependency(Symbol* sym,
                                     ClassScopePtr cls, std::string name) {
  auto& set = m_dependencies[sym];
  set.emplace(cls, name);
  m_hasDependencies = true;
}

const ConstantTable::ClassConstantSet& ConstantTable::lookupDependencies(
  const std::string& name) {

  if (m_hasDependencies) {
    if (auto const sym = getSymbol(name)) {
      auto iter = m_dependencies.find(sym);
      if (iter != m_dependencies.end()) {
        return iter->second;
      }
    }
  }
  static ClassConstantSet empty;
  return empty;
}

void ConstantTable::cleanupForError(AnalysisResultConstRawPtr ar) {
  AnalysisResult::Locker lock(ar);

  for (auto& ent : m_symbolMap) {
    auto sym = &ent.second;
    if (!sym->isDynamic()) {
      sym->setDynamic();
      sym->setDeclaration(ConstructPtr());
      sym->setValue(ConstructPtr());
    }
  }
}

ClassScopePtr ConstantTable::findParent(AnalysisResultConstRawPtr ar,
                                        const std::string &name) const {
  for (ClassScopePtr parent = m_blockScope.getParentScope(ar);
       parent && !parent->isRedeclaring();
       parent = parent->getParentScope(ar)) {
    if (parent->hasConst(name)) {
      return parent;
    }
  }
  return ClassScopePtr();
}

ClassScopeRawPtr ConstantTable::findBase(
  AnalysisResultConstRawPtr ar, const std::string &name,
  const std::vector<std::string> &bases) const {
  for (int i = bases.size(); i--; ) {
    ClassScopeRawPtr p = ar->findClass(bases[i]);
    if (!p || p->isRedeclaring()) continue;
    if (p->hasConst(name)) return p;
    ConstantTablePtr constants = p->getConstants();
    p = constants->findBase(ar, name, p->getBases());
    if (p) return p;
  }
  return ClassScopeRawPtr();
}

///////////////////////////////////////////////////////////////////////////////

void ConstantTable::outputPHP(CodeGenerator& /*cg*/, AnalysisResultPtr /*ar*/) {
}
