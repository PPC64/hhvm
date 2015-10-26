/*
   +----------------------------------------------------------------------+
   | HipHop for PHP                                                       |
   +----------------------------------------------------------------------+
   | (c) Copyright IBM Corporation 2015                                   |
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

#include <ostream>

namespace ppc64 {

struct Dissasembler {
 public:
  Dissasembler()
   : print_encoding_(false)
   , print_address(false)
   , indent_level_(0)
   , color_(nullptr){}

 private:
  bool print_encoding_;
  bool print_address_;
  int indent_level_;
  std::string color_;
};

} // namespace ppc64
