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

#pragma once

#include "hphp/runtime/vm/unit-emitter.h"

#include <boost/variant.hpp>

namespace HPHP {

struct MD5;

enum class HackcMode {
  kNever,
  kFallback,
  kFatal
};

HackcMode hackc_mode();

void hackc_init();
void hackc_shutdown();

// On success return a verified unit, and on failure return a string stating the
// type of error encountered
using HackcResult = boost::variant<std::unique_ptr<Unit>,std::string>;

HackcResult hackc_compile(const char* code, int len,
                          const char* filename, const MD5& md5);

}
