/*
   +----------------------------------------------------------------------+
   | HipHop for PHP                                                       |
   +----------------------------------------------------------------------+
   | Copyright (c) 2010- Facebook, Inc. (http://www.facebook.com)         |
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

#ifndef incl_HPHP_PHP7_COMPILER_H_
#define incl_HPHP_PHP7_COMPILER_H_

#include "hphp/php7/zend/zend.h"
#include "hphp/php7/ast_info.h"
#include "hphp/php7/bytecode.h"
#include "hphp/php7/unit.h"

#include <string>
#include <exception>

namespace HPHP { namespace php7 {

struct CompilerException : public std::logic_error {
  explicit CompilerException(const std::string& what)
    : std::logic_error(what) {}
};

struct Compiler {
  explicit Compiler();

  static std::unique_ptr<Unit> compile(const zend_ast* ast) {
    Compiler compiler;
    compiler.compileProgram(ast);
    return std::move(compiler.unit);
  }

 private:
  void compileProgram(const zend_ast* ast);
  void compileStatement(const zend_ast* ast);
  void compileExpression(const zend_ast* ast);

  void compileZvalLiteral(const zval* ast);
  void compileConstant(const zend_ast* ast);
  void compileIf(const zend_ast* ast);

  Bytecode opForBinaryOp(const zend_ast* op);
  void compileUnaryOp(const zend_ast* op);

  [[noreturn]]
  void panic(const std::string& msg);

  std::unique_ptr<Unit> unit;

  Function* activeFunction;
  Block* activeBlock;
};

}} // HPHP::php7


#endif // incl_HPHP_PHP7_COMPILER_H_
