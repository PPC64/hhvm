/*
   +----------------------------------------------------------------------+
   | HipHop for PHP                                                       |
   +----------------------------------------------------------------------+
   | Copyright (c) 2010-2016 Facebook, Inc. (http://www.facebook.com)     |
   | Copyright (c) 1997-2010 The PHP Group                                |
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

#ifndef incl_HPHP_EXT_PDO_H_
#define incl_HPHP_EXT_PDO_H_

#include "hphp/runtime/ext/extension.h"
#include "hphp/runtime/ext/pdo/pdo_driver.h"
namespace HPHP {
///////////////////////////////////////////////////////////////////////////////

Array f_pdo_drivers();
extern const int64_t q_PDO$$PARAM_BOOL;
extern const int64_t q_PDO$$PARAM_NULL;
extern const int64_t q_PDO$$PARAM_INT;
extern const int64_t q_PDO$$PARAM_STR;
extern const int64_t q_PDO$$PARAM_LOB;
extern const int64_t q_PDO$$PARAM_STMT;
extern const int64_t q_PDO$$PARAM_INPUT_OUTPUT;
extern const int64_t q_PDO$$PARAM_EVT_ALLOC;
extern const int64_t q_PDO$$PARAM_EVT_FREE;
extern const int64_t q_PDO$$PARAM_EVT_EXEC_PRE;
extern const int64_t q_PDO$$PARAM_EVT_EXEC_POST;
extern const int64_t q_PDO$$PARAM_EVT_FETCH_PRE;
extern const int64_t q_PDO$$PARAM_EVT_FETCH_POST;
extern const int64_t q_PDO$$PARAM_EVT_NORMALIZE;
extern const int64_t q_PDO$$FETCH_USE_DEFAULT;
extern const int64_t q_PDO$$FETCH_LAZY;
extern const int64_t q_PDO$$FETCH_ASSOC;
extern const int64_t q_PDO$$FETCH_NUM;
extern const int64_t q_PDO$$FETCH_BOTH;
extern const int64_t q_PDO$$FETCH_OBJ;
extern const int64_t q_PDO$$FETCH_BOUND;
extern const int64_t q_PDO$$FETCH_COLUMN;
extern const int64_t q_PDO$$FETCH_CLASS;
extern const int64_t q_PDO$$FETCH_INTO;
extern const int64_t q_PDO$$FETCH_FUNC;
extern const int64_t q_PDO$$FETCH_GROUP;
extern const int64_t q_PDO$$FETCH_UNIQUE;
extern const int64_t q_PDO$$FETCH_KEY_PAIR;
extern const int64_t q_PDO$$FETCH_CLASSTYPE;
extern const int64_t q_PDO$$FETCH_SERIALIZE;
extern const int64_t q_PDO$$FETCH_PROPS_LATE;
extern const int64_t q_PDO$$FETCH_NAMED;
extern const int64_t q_PDO$$ATTR_AUTOCOMMIT;
extern const int64_t q_PDO$$ATTR_PREFETCH;
extern const int64_t q_PDO$$ATTR_TIMEOUT;
extern const int64_t q_PDO$$ATTR_ERRMODE;
extern const int64_t q_PDO$$ATTR_SERVER_VERSION;
extern const int64_t q_PDO$$ATTR_CLIENT_VERSION;
extern const int64_t q_PDO$$ATTR_SERVER_INFO;
extern const int64_t q_PDO$$ATTR_CONNECTION_STATUS;
extern const int64_t q_PDO$$ATTR_CASE;
extern const int64_t q_PDO$$ATTR_CURSOR_NAME;
extern const int64_t q_PDO$$ATTR_CURSOR;
extern const int64_t q_PDO$$ATTR_ORACLE_NULLS;
extern const int64_t q_PDO$$ATTR_PERSISTENT;
extern const int64_t q_PDO$$ATTR_STATEMENT_CLASS;
extern const int64_t q_PDO$$ATTR_FETCH_TABLE_NAMES;
extern const int64_t q_PDO$$ATTR_FETCH_CATALOG_NAMES;
extern const int64_t q_PDO$$ATTR_DRIVER_NAME;
extern const int64_t q_PDO$$ATTR_STRINGIFY_FETCHES;
extern const int64_t q_PDO$$ATTR_MAX_COLUMN_LEN;
extern const int64_t q_PDO$$ATTR_EMULATE_PREPARES;
extern const int64_t q_PDO$$ATTR_DEFAULT_FETCH_MODE;
extern const int64_t q_PDO$$ERRMODE_SILENT;
extern const int64_t q_PDO$$ERRMODE_WARNING;
extern const int64_t q_PDO$$ERRMODE_EXCEPTION;
extern const int64_t q_PDO$$CASE_NATURAL;
extern const int64_t q_PDO$$CASE_LOWER;
extern const int64_t q_PDO$$CASE_UPPER;
extern const int64_t q_PDO$$NULL_NATURAL;
extern const int64_t q_PDO$$NULL_EMPTY_STRING;
extern const int64_t q_PDO$$NULL_TO_STRING;
extern const int64_t q_PDO$$FETCH_ORI_NEXT;
extern const int64_t q_PDO$$FETCH_ORI_PRIOR;
extern const int64_t q_PDO$$FETCH_ORI_FIRST;
extern const int64_t q_PDO$$FETCH_ORI_LAST;
extern const int64_t q_PDO$$FETCH_ORI_ABS;
extern const int64_t q_PDO$$FETCH_ORI_REL;
extern const int64_t q_PDO$$CURSOR_FWDONLY;
extern const int64_t q_PDO$$CURSOR_SCROLL;
extern const int64_t q_PDO$$MYSQL_ATTR_USE_BUFFERED_QUERY;
extern const int64_t q_PDO$$MYSQL_ATTR_LOCAL_INFILE;
extern const int64_t q_PDO$$MYSQL_ATTR_MAX_BUFFER_SIZE;
extern const int64_t q_PDO$$MYSQL_ATTR_INIT_COMMAND;
extern const int64_t q_PDO$$MYSQL_ATTR_READ_DEFAULT_FILE;
extern const int64_t q_PDO$$MYSQL_ATTR_READ_DEFAULT_GROUP;
extern const int64_t q_PDO$$MYSQL_ATTR_COMPRESS;
extern const int64_t q_PDO$$MYSQL_ATTR_DIRECT_QUERY;
extern const int64_t q_PDO$$MYSQL_ATTR_FOUND_ROWS;
extern const int64_t q_PDO$$MYSQL_ATTR_IGNORE_SPACE;
extern const StaticString q_PDO$$ERR_NONE;

const StaticString s_PARAM_BOOL("PARAM_BOOL");
const StaticString s_PARAM_NULL("PARAM_NULL");
const StaticString s_PARAM_INT("PARAM_INT");
const StaticString s_PARAM_STR("PARAM_STR");
const StaticString s_PARAM_LOB("PARAM_LOB");
const StaticString s_PARAM_STMT("PARAM_STMT");
const StaticString s_PARAM_INPUT_OUTPUT("PARAM_INPUT_OUTPUT");
const StaticString s_PARAM_EVT_ALLOC("PARAM_EVT_ALLOC");
const StaticString s_PARAM_EVT_FREE("PARAM_EVT_FREE");
const StaticString s_PARAM_EVT_EXEC_PRE("PARAM_EVT_EXEC_PRE");
const StaticString s_PARAM_EVT_EXEC_POST("PARAM_EVT_EXEC_POST");
const StaticString s_PARAM_EVT_FETCH_PRE("PARAM_EVT_FETCH_PRE");
const StaticString s_PARAM_EVT_FETCH_POST("PARAM_EVT_FETCH_POST");
const StaticString s_PARAM_EVT_NORMALIZE("PARAM_EVT_NORMALIZE");
const StaticString s_FETCH_USE_DEFAULT("FETCH_USE_DEFAULT");
const StaticString s_FETCH_LAZY("FETCH_LAZY");
const StaticString s_FETCH_ASSOC("FETCH_ASSOC");
const StaticString s_FETCH_NUM("FETCH_NUM");
const StaticString s_FETCH_BOTH("FETCH_BOTH");
const StaticString s_FETCH_OBJ("FETCH_OBJ");
const StaticString s_FETCH_BOUND("FETCH_BOUND");
const StaticString s_FETCH_COLUMN("FETCH_COLUMN");
const StaticString s_FETCH_CLASS("FETCH_CLASS");
const StaticString s_FETCH_INTO("FETCH_INTO");
const StaticString s_FETCH_FUNC("FETCH_FUNC");
const StaticString s_FETCH_GROUP("FETCH_GROUP");
const StaticString s_FETCH_UNIQUE("FETCH_UNIQUE");
const StaticString s_FETCH_KEY_PAIR("FETCH_KEY_PAIR");
const StaticString s_FETCH_CLASSTYPE("FETCH_CLASSTYPE");
const StaticString s_FETCH_SERIALIZE("FETCH_SERIALIZE");
const StaticString s_FETCH_PROPS_LATE("FETCH_PROPS_LATE");
const StaticString s_FETCH_NAMED("FETCH_NAMED");
const StaticString s_ATTR_AUTOCOMMIT("ATTR_AUTOCOMMIT");
const StaticString s_ATTR_PREFETCH("ATTR_PREFETCH");
const StaticString s_ATTR_TIMEOUT("ATTR_TIMEOUT");
const StaticString s_ATTR_ERRMODE("ATTR_ERRMODE");
const StaticString s_ATTR_SERVER_VERSION("ATTR_SERVER_VERSION");
const StaticString s_ATTR_CLIENT_VERSION("ATTR_CLIENT_VERSION");
const StaticString s_ATTR_SERVER_INFO("ATTR_SERVER_INFO");
const StaticString s_ATTR_CONNECTION_STATUS("ATTR_CONNECTION_STATUS");
const StaticString s_ATTR_CASE("ATTR_CASE");
const StaticString s_ATTR_CURSOR_NAME("ATTR_CURSOR_NAME");
const StaticString s_ATTR_CURSOR("ATTR_CURSOR");
const StaticString s_ATTR_ORACLE_NULLS("ATTR_ORACLE_NULLS");
const StaticString s_ATTR_PERSISTENT("ATTR_PERSISTENT");
const StaticString s_ATTR_STATEMENT_CLASS("ATTR_STATEMENT_CLASS");
const StaticString s_ATTR_FETCH_TABLE_NAMES("ATTR_FETCH_TABLE_NAMES");
const StaticString s_ATTR_FETCH_CATALOG_NAMES("ATTR_FETCH_CATALOG_NAMES");
const StaticString s_ATTR_DRIVER_NAME("ATTR_DRIVER_NAME");
const StaticString s_ATTR_STRINGIFY_FETCHES("ATTR_STRINGIFY_FETCHES");
const StaticString s_ATTR_MAX_COLUMN_LEN("ATTR_MAX_COLUMN_LEN");
const StaticString s_ATTR_EMULATE_PREPARES("ATTR_EMULATE_PREPARES");
const StaticString s_ATTR_DEFAULT_FETCH_MODE("ATTR_DEFAULT_FETCH_MODE");
const StaticString s_ERRMODE_SILENT("ERRMODE_SILENT");
const StaticString s_ERRMODE_WARNING("ERRMODE_WARNING");
const StaticString s_ERRMODE_EXCEPTION("ERRMODE_EXCEPTION");
const StaticString s_CASE_NATURAL("CASE_NATURAL");
const StaticString s_CASE_LOWER("CASE_LOWER");
const StaticString s_CASE_UPPER("CASE_UPPER");
const StaticString s_NULL_NATURAL("NULL_NATURAL");
const StaticString s_NULL_EMPTY_STRING("NULL_EMPTY_STRING");
const StaticString s_NULL_TO_STRING("NULL_TO_STRING");
const StaticString s_FETCH_ORI_NEXT("FETCH_ORI_NEXT");
const StaticString s_FETCH_ORI_PRIOR("FETCH_ORI_PRIOR");
const StaticString s_FETCH_ORI_FIRST("FETCH_ORI_FIRST");
const StaticString s_FETCH_ORI_LAST("FETCH_ORI_LAST");
const StaticString s_FETCH_ORI_ABS("FETCH_ORI_ABS");
const StaticString s_FETCH_ORI_REL("FETCH_ORI_REL");
const StaticString s_CURSOR_FWDONLY("CURSOR_FWDONLY");
const StaticString s_CURSOR_SCROLL("CURSOR_SCROLL");
const StaticString s_MYSQL_ATTR_USE_BUFFERED_QUERY(
  "MYSQL_ATTR_USE_BUFFERED_QUERY");
const StaticString s_MYSQL_ATTR_LOCAL_INFILE("MYSQL_ATTR_LOCAL_INFILE");
const StaticString s_MYSQL_ATTR_MAX_BUFFER_SIZE("MYSQL_ATTR_MAX_BUFFER_SIZE");
const StaticString s_MYSQL_ATTR_INIT_COMMAND("MYSQL_ATTR_INIT_COMMAND");
const StaticString s_MYSQL_ATTR_READ_DEFAULT_FILE(
  "MYSQL_ATTR_READ_DEFAULT_FILE");
const StaticString s_MYSQL_ATTR_READ_DEFAULT_GROUP(
  "MYSQL_ATTR_READ_DEFAULT_GROUP");
const StaticString s_MYSQL_ATTR_COMPRESS("MYSQL_ATTR_COMPRESS");
const StaticString s_MYSQL_ATTR_DIRECT_QUERY("MYSQL_ATTR_DIRECT_QUERY");
const StaticString s_MYSQL_ATTR_FOUND_ROWS("MYSQL_ATTR_FOUND_ROWS");
const StaticString s_MYSQL_ATTR_IGNORE_SPACE("MYSQL_ATTR_IGNORE_SPACE");
const StaticString s_ERR_NONE("ERR_NONE");


///////////////////////////////////////////////////////////////////////////////
// class PDO

struct PDOData {
  public: sp_PDOResource m_dbh;
};

///////////////////////////////////////////////////////////////////////////////
// class PDOStatement

struct PDOStatementData {
  public: PDOStatementData();
  public: ~PDOStatementData();

  public: sp_PDOStatement m_stmt;
  public: Variant m_row;
  public: int m_rowIndex;
};

///////////////////////////////////////////////////////////////////////////////
}

#endif // incl_HPHP_EXT_PDO_H_
