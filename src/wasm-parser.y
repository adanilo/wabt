%{
#include <assert.h>
#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <memory.h>

#include "wasm.h"
#include "wasm-internal.h"

#define ZEROMEM(var) memset(&(var), 0, sizeof(var));
#define DUPTEXT(dst, src)                           \
  (dst).start = strndup((src).start, (src).length); \
  (dst).length = (src).length
#define DUPQUOTEDTEXT(dst, src)                             \
  (dst).start = strndup((src).start + 1, (src).length - 2); \
  (dst).length = (src).length - 2

#define YYLLOC_DEFAULT(Current, Rhs, N)                                        \
  do                                                                           \
    if (N) {                                                                   \
      (Current).filename = YYRHSLOC(Rhs, 1).filename;                          \
      (Current).first_line = YYRHSLOC(Rhs, 1).first_line;                      \
      (Current).first_column = YYRHSLOC(Rhs, 1).first_column;                  \
      (Current).last_line = YYRHSLOC(Rhs, N).last_line;                        \
      (Current).last_column = YYRHSLOC(Rhs, N).last_column;                    \
    } else {                                                                   \
      (Current).filename = NULL;                                               \
      (Current).first_line = (Current).last_line = YYRHSLOC(Rhs, 0).last_line; \
      (Current).first_column = (Current).last_column =                         \
          YYRHSLOC(Rhs, 0).last_column;                                        \
    }                                                                          \
  while (0)

static WasmExprPtr wasm_new_expr(WasmExprType type) {
  WasmExprPtr result = calloc(1, sizeof(WasmExpr));
  result->type = type;
  return result;
}

static int read_int32(const char* s, const char* end, uint32_t* out,
                      int allow_signed);
static int read_int64(const char* s, const char* end, uint64_t* out);
static int read_uint64(const char* s, const char* end, uint64_t* out);
static int read_float(const char* s, const char* end, float* out);
static int read_double(const char* s, const char* end, double* out);
static int read_const(WasmType type, const char* s, const char* end,
                      WasmConst* out);
static void dup_string_contents(WasmStringSlice * text, void** out_data,
                                size_t* out_size);

%}

%define api.pure true
%define api.value.type {WasmToken}
%define api.token.prefix {WASM_TOKEN_TYPE_}
%define parse.error verbose
%lex-param {WasmScanner scanner} {WasmParser* parser}
%parse-param {WasmScanner scanner} {WasmParser* parser}
%locations

%token LPAR "("
%token RPAR ")"
%token INT FLOAT TEXT VAR VALUE_TYPE
%token NOP BLOCK IF IF_ELSE LOOP LABEL BR BR_IF TABLESWITCH CASE
%token CALL CALL_IMPORT CALL_INDIRECT RETURN
%token GET_LOCAL SET_LOCAL LOAD STORE LOAD_EXTEND STORE_WRAP OFFSET ALIGN
%token CONST UNARY BINARY COMPARE CONVERT CAST SELECT
%token FUNC TYPE PARAM RESULT LOCAL
%token MODULE MEMORY SEGMENT IMPORT EXPORT TABLE
%token UNREACHABLE MEMORY_SIZE GROW_MEMORY HAS_FEATURE
%token ASSERT_INVALID ASSERT_RETURN ASSERT_RETURN_NAN ASSERT_TRAP INVOKE
%token GLOBAL LOAD_GLOBAL STORE_GLOBAL PAGE_SIZE
%token EOF 0 "EOF"

%type<binary> BINARY
%type<cast> CAST
%type<compare> COMPARE
%type<convert> CONVERT
%type<mem> LOAD STORE LOAD_EXTEND STORE_WRAP
%type<text> ALIGN FLOAT INT OFFSET TEXT VAR
%type<type> SELECT
%type<type> CONST VALUE_TYPE
%type<unary> UNARY

%type<case_> case
%type<cases> case_list
%type<command> cmd
%type<commands> cmd_list
%type<const_> const const_opt
%type<consts> const_list
%type<export> export
%type<expr> expr expr1 expr_opt
%type<exprs> expr_list non_empty_expr_list
%type<func> func func_info
%type<func_sig> func_type
%type<func_type> type_def
%type<import> import
%type<memory> memory
%type<module> module
%type<module_fields> module_fields
%type<script> script
%type<segment> segment string_contents
%type<segments> segment_list
%type<type_bindings> global local_list param_list
%type<targets> target_list
%type<target> target
%type<text> bind_var labeling literal quoted_text text
%type<type> result
%type<types> value_type_list
%type<u32> align offset
%type<vars> table var_list
%type<var> type_use var

/*
%destructor { wasm_destroy_type_vector($$); } value_type_list
*/

%nonassoc LOW
%nonassoc VAR

%start script

%%

/* Types */

value_type_list :
    /* empty */ { ZEROMEM($$); }
  | value_type_list VALUE_TYPE { $$ = $1; *wasm_append_type(&$$) = $2; }
;
func_type :
    /* empty */ { ZEROMEM($$); }
  | LPAR PARAM value_type_list RPAR {
      $$.result_type = WASM_TYPE_VOID;
      $$.param_types = $3;
    }
  | LPAR PARAM value_type_list RPAR LPAR RESULT VALUE_TYPE RPAR {
      $$.result_type = $7;
      $$.param_types = $3;
    }
  | LPAR RESULT VALUE_TYPE RPAR { $$.result_type = $3; }
;


/* Expressions */

literal :
    INT { DUPTEXT($$, $1); }
  | FLOAT { DUPTEXT($$, $1); }
;

var :
    INT {
      $$.loc = @1;
      $$.type = WASM_VAR_TYPE_INDEX;
      uint32_t index;
      if (!read_int32($1.start, $1.start + $1.length, &index, 0))
        yyerror(&@1, scanner, parser, "invalid int %.*s", $1.length, $1.start);
      $$.index = index;
    }
  | VAR {
      $$.loc = @1;
      $$.type = WASM_VAR_TYPE_NAME;
      DUPTEXT($$.name, $1);
    }
;
var_list :
    /* empty */ { ZEROMEM($$); }
  | var_list var { $$ = $1; *wasm_append_var(&$$) = $2; }
;
bind_var :
    VAR { DUPTEXT($$, $1); }
;

text :
    TEXT { DUPTEXT($$, $1); }
;

quoted_text :
    TEXT { DUPQUOTEDTEXT($$, $1); }
;

string_contents :
    TEXT { dup_string_contents(&$1, &$$.data, &$$.size); }
;

labeling :
    /* empty */ %prec LOW { ZEROMEM($$); }
  | bind_var { DUPTEXT($$, $1); }
;

offset :
    /* empty */ { $$ = 0; }
  | OFFSET {
      if (!read_int32($1.start, $1.start + $1.length, &$$, 0))
        yyerror(&@1, scanner, parser, "invalid offset \"%.*s\"", $1.length,
                $1.start);
    }
;
align :
    /* empty */ { $$ = WASM_USE_NATURAL_ALIGNMENT; }
  | ALIGN {
      if (!read_int32($1.start, $1.start + $1.length, &$$, 0))
        yyerror(&@1, scanner, parser, "invalid alignment \"%.*s\"", $1.length,
                $1.start);
    }
;

expr :
    LPAR expr1 RPAR { $$ = $2; $$->loc = @1; }
;
expr1 :
    NOP { $$ = wasm_new_expr(WASM_EXPR_TYPE_NOP); }
  | BLOCK labeling {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_BLOCK);
      $$->block.label = $2;
    }
  | BLOCK labeling non_empty_expr_list {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_BLOCK);
      $$->block.label = $2;
      $$->block.exprs = $3;
    }
  | IF_ELSE expr expr expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_IF_ELSE);
      $$->if_else.cond = $2;
      $$->if_else.true_ = $3;
      $$->if_else.false_ = $4;
    }
  | IF expr expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_IF);
      $$->if_else.cond = $2;
      $$->if_else.true_ = $3;
    }
  | BR_IF var expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_BR_IF);
      $$->br_if.var = $2;
      $$->br_if.cond = $3;
    }
  | LOOP labeling expr_list {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_LOOP);
      ZEROMEM($$->loop.outer);
      $$->loop.inner = $2;
      $$->loop.exprs = $3;
    }
  | LOOP bind_var bind_var expr_list {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_LOOP);
      $$->loop.outer = $2;
      $$->loop.inner = $3;
      $$->loop.exprs = $4;
    }
  | LABEL labeling expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_LABEL);
      $$->label.label = $2;
      $$->label.expr = $3;
    }
  | BR expr_opt {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_BR);
      $$->br.var.loc = @1;
      $$->br.var.type = WASM_VAR_TYPE_INDEX;
      $$->br.var.index = 0;
      $$->br.expr = $2;
    }
  | BR var expr_opt {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_BR);
      $$->br.var = $2;
      $$->br.expr = $3;
    }
  | RETURN expr_opt {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_RETURN);
      $$->return_.expr = $2;
    }
  | TABLESWITCH labeling expr LPAR TABLE target_list RPAR target case_list {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_TABLESWITCH);
      $$->tableswitch.label = $2;
      $$->tableswitch.expr = $3;
      $$->tableswitch.targets = $6;
      $$->tableswitch.default_target = $8;
      $$->tableswitch.cases = $9;

      int i;
      for (i = 0; i < $$->tableswitch.cases.size; ++i) {
        WasmCase* case_ = &$$->tableswitch.cases.data[i];
        if (case_->label.start) {
          WasmBinding* binding =
              wasm_append_binding(&$$->tableswitch.case_bindings);
          binding->loc = case_->loc;
          binding->name = case_->label;
          binding->index = i;
        }
      }
    }
  | CALL var expr_list {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_CALL);
      $$->call.var = $2;
      $$->call.args = $3;
    }
  | CALL_IMPORT var expr_list {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_CALL_IMPORT);
      $$->call.var = $2;
      $$->call.args = $3;
    }
  | CALL_INDIRECT var expr expr_list {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_CALL_INDIRECT);
      $$->call_indirect.var = $2;
      $$->call_indirect.expr = $3;
      $$->call_indirect.args = $4;
    }
  | GET_LOCAL var {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_GET_LOCAL);
      $$->get_local.var = $2;
    }
  | SET_LOCAL var expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_SET_LOCAL);
      $$->set_local.var = $2;
      $$->set_local.expr = $3;
    }
  | LOAD offset align expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_LOAD);
      $$->load.op = $1;
      $$->load.offset = $2;
      $$->load.align = $3;
      $$->load.addr = $4;
    }
  | STORE offset align expr expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_STORE);
      $$->store.op = $1;
      $$->store.offset = $2;
      $$->store.align = $3;
      $$->store.addr = $4;
      $$->store.value = $5;
    }
  | LOAD_EXTEND offset align expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_LOAD_EXTEND);
      $$->load.op = $1;
      $$->load.offset = $2;
      $$->load.align = $3;
      $$->load.addr = $4;
    }
  | STORE_WRAP offset align expr expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_STORE_WRAP);
      $$->store.op = $1;
      $$->store.offset = $2;
      $$->store.align = $3;
      $$->store.addr = $4;
      $$->store.value = $5;
    }
  | CONST literal {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_CONST);
      $$->const_.loc = @1;
      if (!read_const($1, $2.start, $2.start + $2.length, &$$->const_))
        yyerror(&@2, scanner, parser, "invalid literal \"%.*s\"", $2.length,
                $2.start);
      free((char*)$2.start);
    }
  | UNARY expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_UNARY);
      $$->unary.op = $1;
      $$->unary.expr = $2;
    }
  | BINARY expr expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_BINARY);
      $$->binary.op = $1;
      $$->binary.left = $2;
      $$->binary.right = $3;
    }
  | SELECT expr expr expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_SELECT);
      $$->select.type = $1;
      $$->select.cond = $2;
      $$->select.true_ = $3;
      $$->select.false_ = $4;
    }
  | COMPARE expr expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_COMPARE);
      $$->compare.op = $1;
      $$->compare.left = $2;
      $$->compare.right = $3;
    }
  | CONVERT expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_CONVERT);
      $$->convert.op = $1;
      $$->convert.expr = $2;
    }
  | CAST expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_CAST);
      $$->cast.op = $1;
      $$->cast.expr = $2;
    }
  | UNREACHABLE { $$ = wasm_new_expr(WASM_EXPR_TYPE_UNREACHABLE); }
  | MEMORY_SIZE { $$ = wasm_new_expr(WASM_EXPR_TYPE_MEMORY_SIZE); }
  | GROW_MEMORY expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_GROW_MEMORY);
      $$->grow_memory.expr = $2;
    }
  | HAS_FEATURE text {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_HAS_FEATURE);
      $$->has_feature.text = $2;
    }
  | LOAD_GLOBAL var {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_LOAD_GLOBAL);
      $$->load_global.var = $2;
    }
  | STORE_GLOBAL var expr {
      $$ = wasm_new_expr(WASM_EXPR_TYPE_STORE_GLOBAL);
      $$->store_global.var = $2;
      $$->store_global.expr = $3;
    }
  | PAGE_SIZE { $$ = wasm_new_expr(WASM_EXPR_TYPE_PAGE_SIZE); }
;
expr_opt :
    /* empty */ { $$ = NULL; }
  | expr
;
non_empty_expr_list :
    expr { ZEROMEM($$); *wasm_append_expr_ptr(&$$) = $1; }
  | non_empty_expr_list expr { $$ = $1; *wasm_append_expr_ptr(&$$) = $2; }
;
expr_list :
    /* empty */ { ZEROMEM($$); }
  | non_empty_expr_list
;

target :
    LPAR CASE var RPAR {
      $$.type = WASM_TARGET_TYPE_CASE;
      $$.var = $3;
    }
  | LPAR BR var RPAR {
      $$.type = WASM_TARGET_TYPE_BR;
      $$.var = $3;
    }
;
target_list :
    /* empty */ { ZEROMEM($$); }
  | target_list target { $$ = $1; *wasm_append_target(&$$) = $2; }
;
case :
    LPAR CASE expr_list RPAR { ZEROMEM($$.label); $$.exprs = $3; }
  | LPAR CASE bind_var expr_list RPAR { $$.label = $3; $$.exprs = $4; }
;
case_list :
    /* empty */ { ZEROMEM($$); }
  | case_list case { $$ = $1; *wasm_append_case(&$$) = $2; }
;


/* Functions */

param_list :
    LPAR PARAM value_type_list RPAR {
      ZEROMEM($$);
      wasm_extend_types(&$$.types, &$3);
      wasm_destroy_type_vector(&$3);
    }
  | LPAR PARAM bind_var VALUE_TYPE RPAR {
      ZEROMEM($$);
      WasmBinding* binding = wasm_append_binding(&$$.bindings);
      binding->loc = @2;
      binding->name = $3;
      binding->index = $$.types.size;
      *wasm_append_type(&$$.types) = $4;
    }
  | param_list LPAR PARAM value_type_list RPAR {
      $$ = $1;
      wasm_extend_types(&$$.types, &$4);
      wasm_destroy_type_vector(&$4);
    }
  | param_list LPAR PARAM bind_var VALUE_TYPE RPAR {
      $$ = $1;
      WasmBinding* binding = wasm_append_binding(&$$.bindings);
      binding->loc = @3;
      binding->name = $4;
      binding->index = $$.types.size;
      *wasm_append_type(&$$.types) = $5;
    }
;
result :
    LPAR RESULT VALUE_TYPE RPAR { $$ = $3; }
;
local_list :
    LPAR LOCAL value_type_list RPAR {
      ZEROMEM($$);
      wasm_extend_types(&$$.types, &$3);
      wasm_destroy_type_vector(&$3);
    }
  | LPAR LOCAL bind_var VALUE_TYPE RPAR {
      ZEROMEM($$);
      WasmBinding* binding = wasm_append_binding(&$$.bindings);
      binding->loc = @2;
      binding->name = $3;
      binding->index = $$.types.size;
      *wasm_append_type(&$$.types) = $4;
    }
  | local_list LPAR LOCAL value_type_list RPAR {
      $$ = $1;
      wasm_extend_types(&$$.types, &$4);
      wasm_destroy_type_vector(&$4);
    }
  | local_list LPAR LOCAL bind_var VALUE_TYPE RPAR {
      $$ = $1;
      WasmBinding* binding = wasm_append_binding(&$$.bindings);
      binding->loc = @3;
      binding->name = $4;
      binding->index = $$.types.size;
      *wasm_append_type(&$$.types) = $5;
    }
;
type_use :
    LPAR TYPE var RPAR { $$ = $3; }
;
func_info :
    /* empty */ {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
    }
  | bind_var {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
    }
  | bind_var type_use {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE;
      $$.name = $1;
      $$.type_var = $2;
    }
  | bind_var type_use param_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.type_var = $2;
      $$.params = $3;
    }
  | bind_var type_use param_list result {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.type_var = $2;
      $$.params = $3;
      $$.result_type = $4;
    }
  | bind_var type_use param_list result local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.type_var = $2;
      $$.params = $3;
      $$.result_type = $4;
      $$.locals = $5;
    }
  | bind_var type_use param_list result local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.type_var = $2;
      $$.params = $3;
      $$.result_type = $4;
      $$.locals = $5;
      $$.exprs = $6;
    }
  | bind_var type_use param_list result non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.type_var = $2;
      $$.params = $3;
      $$.result_type = $4;
      $$.exprs = $5;
    }
  | bind_var type_use param_list local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.type_var = $2;
      $$.params = $3;
      $$.locals = $4;
    }
  | bind_var type_use param_list local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.type_var = $2;
      $$.params = $3;
      $$.locals = $4;
    }
  | bind_var type_use param_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.type_var = $2;
      $$.params = $3;
      $$.exprs = $4;
    }
  | bind_var type_use result {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.type_var = $2;
      $$.result_type = $3;
    }
  | bind_var type_use result local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.type_var = $2;
      $$.result_type = $3;
      $$.locals = $4;
    }
  | bind_var type_use result local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.type_var = $2;
      $$.result_type = $3;
      $$.locals = $4;
      $$.exprs = $5;
    }
  | bind_var type_use result non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.type_var = $2;
      $$.result_type = $3;
      $$.exprs = $4;
    }
  | bind_var type_use local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE;
      $$.name = $1;
      $$.type_var = $2;
      $$.locals = $3;
    }
  | bind_var type_use local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE;
      $$.name = $1;
      $$.type_var = $2;
      $$.locals = $3;
      $$.exprs = $4;
    }
  | bind_var type_use non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE;
      $$.name = $1;
      $$.type_var = $2;
      $$.exprs = $3;
    }
  | bind_var local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.locals = $2;
    }
  | bind_var local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.locals = $2;
      $$.exprs = $3;
    }
  | bind_var param_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.params = $2;
    }
  | bind_var param_list result {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.params = $2;
      $$.result_type = $3;
    }
  | bind_var param_list result local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.params = $2;
      $$.result_type = $3;
      $$.locals = $4;
    }
  | bind_var param_list result local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.params = $2;
      $$.result_type = $3;
      $$.locals = $4;
      $$.exprs = $5;
    }
  | bind_var param_list result non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.params = $2;
      $$.result_type = $3;
      $$.exprs = $4;
    }
  | bind_var param_list local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.params = $2;
      $$.locals = $3;
    }
  | bind_var param_list local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.params = $2;
      $$.locals = $3;
      $$.exprs = $4;
    }
  | bind_var param_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.params = $2;
      $$.exprs = $3;
    }
  | bind_var result {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.result_type = $2;
    }
  | bind_var result local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.result_type = $2;
      $$.locals = $3;
    }
  | bind_var result local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.result_type = $2;
      $$.locals = $3;
      $$.exprs = $4;
    }
  | bind_var result non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.result_type = $2;
      $$.exprs = $3;
    }
  | bind_var non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.name = $1;
      $$.exprs = $2;
    }
  | type_use {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE;
      $$.type_var = $1;
    }
  | type_use param_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.type_var = $1;
      $$.params = $2;
    }
  | type_use param_list result {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.type_var = $1;
      $$.params = $2;
      $$.result_type = $3;
    }
  | type_use param_list result local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.type_var = $1;
      $$.params = $2;
      $$.result_type = $3;
      $$.locals = $4;
    }
  | type_use param_list result local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.type_var = $1;
      $$.params = $2;
      $$.result_type = $3;
      $$.locals = $4;
      $$.exprs = $5;
    }
  | type_use param_list result non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.type_var = $1;
      $$.params = $2;
      $$.result_type = $3;
      $$.exprs = $4;
    }
  | type_use param_list local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.type_var = $1;
      $$.params = $2;
      $$.locals = $3;
    }
  | type_use param_list local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.type_var = $1;
      $$.params = $2;
      $$.locals = $3;
      $$.exprs = $4;
    }
  | type_use param_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.type_var = $1;
      $$.params = $2;
      $$.exprs = $3;
    }
  | type_use result {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.type_var = $1;
      $$.result_type = $2;
    }
  | type_use result local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.type_var = $1;
      $$.result_type = $2;
      $$.locals = $3;
    }
  | type_use result local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.type_var = $1;
      $$.result_type = $2;
      $$.locals = $3;
      $$.exprs = $4;
    }
  | type_use result non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE | WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.type_var = $1;
      $$.result_type = $2;
      $$.exprs = $3;
    }
  | type_use local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE;
      $$.type_var = $1;
      $$.locals = $2;
    }
  | type_use local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE;
      $$.type_var = $1;
      $$.locals = $2;
      $$.exprs = $3;
    }
  | type_use non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_FUNC_TYPE;
      $$.type_var = $1;
      $$.exprs = $2;
    }
  | param_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.params = $1;
    }
  | param_list result {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.params = $1;
      $$.result_type = $2;
    }
  | param_list result local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.params = $1;
      $$.result_type = $2;
      $$.locals = $3;
    }
  | param_list result local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.params = $1;
      $$.result_type = $2;
      $$.locals = $3;
      $$.exprs = $4;
    }
  | param_list result non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.params = $1;
      $$.result_type = $2;
      $$.exprs = $3;
    }
  | param_list local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.params = $1;
      $$.locals = $2;
    }
  | param_list local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.params = $1;
      $$.locals = $2;
      $$.exprs = $3;
    }
  | param_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.params = $1;
      $$.exprs = $2;
    }
  | result {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.result_type = $1;
    }
  | result local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.result_type = $1;
      $$.locals = $2;
    }
  | result local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.result_type = $1;
      $$.locals = $2;
      $$.exprs = $3;
    }
  | result non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.result_type = $1;
      $$.exprs = $2;
    }
  | local_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.locals = $1;
    }
  | local_list non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.locals = $1;
      $$.exprs = $2;
    }
  | non_empty_expr_list {
      $$.flags = WASM_FUNC_FLAG_HAS_SIGNATURE;
      $$.exprs = $1;
    }
;
func :
    LPAR FUNC { ZEROMEM($<func>$); } func_info RPAR { $$ = $4; $$.loc = @2; }
;

/* Modules */

segment :
    LPAR SEGMENT INT string_contents RPAR {
      $$.loc = @2;
      $$.data = $4.data;
      $$.size = $4.size;
      if (!read_int32($3.start, $3.start + $3.length, &$$.addr, 0))
        yyerror(&@3, scanner, parser, "invalid memory segment address \"%.*s\"",
                $3.length, $3.start);
    }
;
segment_list :
    /* empty */ { ZEROMEM($$); }
  | segment_list segment { $$ = $1; *wasm_append_segment(&$$) = $2; }
;

memory :
    LPAR MEMORY INT INT segment_list RPAR {
      $$.loc = @2;
      if (!read_int32($3.start, $3.start + $3.length, &$$.initial_size, 0))
        yyerror(&@3, scanner, parser, "invalid initial memory size \"%.*s\"",
                $3.length, $3.start);
      if (!read_int32($4.start, $4.start + $4.length, &$$.max_size, 0))
        yyerror(&@4, scanner, parser, "invalid max memory size \"%.*s\"",
                $4.length, $4.start);
      $$.segments = $5;
    }
  | LPAR MEMORY INT segment_list RPAR {
      $$.loc = @2;
      if (!read_int32($3.start, $3.start + $3.length, &$$.initial_size, 0))
        yyerror(&@3, scanner, parser, "invalid initial memory size \"%.*s\"",
                $3.length, $3.start);
      $$.max_size = $$.initial_size;
      $$.segments = $4;
    }
;

type_def :
    LPAR TYPE LPAR FUNC func_type RPAR RPAR {
      ZEROMEM($$);
      $$.sig = $5;
    }
  | LPAR TYPE bind_var LPAR FUNC func_type RPAR RPAR {
      $$.name = $3;
      $$.sig = $6;
    }
;

table :
    LPAR TABLE var_list RPAR { $$ = $3; }
;

import :
    LPAR IMPORT quoted_text quoted_text type_use RPAR {
      ZEROMEM($$);
      $$.import_type = WASM_IMPORT_HAS_TYPE;
      $$.module_name = $3;
      $$.func_name = $4;
      $$.type_var = $5;
    }
  | LPAR IMPORT bind_var quoted_text quoted_text type_use RPAR /* Sugar */ {
      ZEROMEM($$);
      $$.import_type = WASM_IMPORT_HAS_TYPE;
      $$.name = $3;
      $$.module_name = $4;
      $$.func_name = $5;
      $$.type_var = $6;
    }
  | LPAR IMPORT quoted_text quoted_text func_type RPAR  /* Sugar */ {
      ZEROMEM($$);
      $$.import_type = WASM_IMPORT_HAS_FUNC_SIGNATURE;
      $$.module_name = $3;
      $$.func_name = $4;
      $$.func_sig = $5;
    }
  | LPAR IMPORT bind_var quoted_text quoted_text func_type RPAR  /* Sugar */ {
      ZEROMEM($$);
      $$.import_type = WASM_IMPORT_HAS_FUNC_SIGNATURE;
      $$.name = $3;
      $$.module_name = $4;
      $$.func_name = $5;
      $$.func_sig = $6;
    }
;

export :
    LPAR EXPORT quoted_text var RPAR {
      $$.name = $3;
      $$.var = $4;
    }
;

global :
    LPAR GLOBAL value_type_list RPAR {
      ZEROMEM($$);
      $$.types = $3;
    }
  | LPAR GLOBAL bind_var VALUE_TYPE RPAR {
      ZEROMEM($$);
      WasmBinding* binding = wasm_append_binding(&$$.bindings);
      binding->loc = @2;
      binding->name = $3;
      binding->index = 0;
      *wasm_append_type(&$$.types) = $4;
    }
;

module_fields :
    /* empty */ { ZEROMEM($$); }
  | module_fields func {
      $$ = $1;
      WasmModuleField* field = wasm_append_module_field(&$$);
      field->loc = @2;
      field->type = WASM_MODULE_FIELD_TYPE_FUNC;
      field->func = $2;
    }
  | module_fields import {
      $$ = $1;
      WasmModuleField* field = wasm_append_module_field(&$$);
      field->loc = @2;
      field->type = WASM_MODULE_FIELD_TYPE_IMPORT;
      field->import = $2;
    }
  | module_fields export {
      $$ = $1;
      WasmModuleField* field = wasm_append_module_field(&$$);
      field->loc = @2;
      field->type = WASM_MODULE_FIELD_TYPE_EXPORT;
      field->export = $2;
    }
  | module_fields table {
      $$ = $1;
      WasmModuleField* field = wasm_append_module_field(&$$);
      field->loc = @2;
      field->type = WASM_MODULE_FIELD_TYPE_TABLE;
      field->table = $2;
    }
  | module_fields type_def {
      $$ = $1;
      WasmModuleField* field = wasm_append_module_field(&$$);
      field->loc = @2;
      field->type = WASM_MODULE_FIELD_TYPE_FUNC_TYPE;
      field->func_type = $2;
    }
  | module_fields memory {
      $$ = $1;
      WasmModuleField* field = wasm_append_module_field(&$$);
      field->loc = @2;
      field->type = WASM_MODULE_FIELD_TYPE_MEMORY;
      field->memory = $2;
    }
  | module_fields global {
      $$ = $1;
      WasmModuleField* field = wasm_append_module_field(&$$);
      field->loc = @2;
      field->type = WASM_MODULE_FIELD_TYPE_GLOBAL;
      field->global = $2;
    }
;
module :
    LPAR MODULE module_fields RPAR {
      $$.loc = @2;
      $$.fields = $3;

      /* cache values */
      int i;
      for (i = 0; i < $$.fields.size; ++i) {
        WasmModuleField* field = &$$.fields.data[i];
        switch (field->type) {
          case WASM_MODULE_FIELD_TYPE_FUNC:
            *wasm_append_func_ptr(&$$.funcs) = &field->func;
            if (field->func.name.start) {
              WasmBinding* binding = wasm_append_binding(&$$.func_bindings);
              binding->loc = field->loc;
              binding->name = field->func.name;
              binding->index = $$.funcs.size - 1;
            }
            break;
          case WASM_MODULE_FIELD_TYPE_IMPORT:
            *wasm_append_import_ptr(&$$.imports) = &field->import;
            if (field->import.name.start) {
              WasmBinding* binding = wasm_append_binding(&$$.import_bindings);
              binding->loc = field->loc;
              binding->name = field->import.name;
              binding->index = $$.imports.size - 1;
            }
            break;
          case WASM_MODULE_FIELD_TYPE_EXPORT:
            *wasm_append_export_ptr(&$$.exports) = &field->export;
            if (field->export.name.start) {
              WasmBinding* binding = wasm_append_binding(&$$.export_bindings);
              binding->loc = field->loc;
              binding->name = field->export.name;
              binding->index = $$.exports.size - 1;
            }
            break;
          case WASM_MODULE_FIELD_TYPE_TABLE:
            $$.table = &field->table;
            break;
          case WASM_MODULE_FIELD_TYPE_FUNC_TYPE:
            *wasm_append_func_type_ptr(&$$.func_types) = &field->func_type;
            if (field->func_type.name.start) {
              WasmBinding* binding =
                  wasm_append_binding(&$$.func_type_bindings);
              binding->loc = field->loc;
              binding->name = field->func_type.name;
              binding->index = $$.func_types.size - 1;
            }
            break;
          case WASM_MODULE_FIELD_TYPE_MEMORY:
            $$.memory = &field->memory;
            break;
          case WASM_MODULE_FIELD_TYPE_GLOBAL:
            wasm_extend_type_bindings(&$$.globals, &field->global);
            break;
        }
      }
    }
;


/* Scripts */

cmd :
    module { $$.type = WASM_COMMAND_TYPE_MODULE; $$.module = $1; }
  | LPAR INVOKE quoted_text const_list RPAR {
      $$.type = WASM_COMMAND_TYPE_INVOKE;
      $$.invoke.loc = @2;
      $$.invoke.name = $3;
      $$.invoke.args = $4;
    }
  | LPAR ASSERT_INVALID module quoted_text RPAR {
      $$.type = WASM_COMMAND_TYPE_ASSERT_INVALID;
      $$.assert_invalid.module = $3;
      $$.assert_invalid.text = $4;
    }
  | LPAR ASSERT_RETURN LPAR INVOKE quoted_text const_list RPAR const_opt RPAR {
      $$.type = WASM_COMMAND_TYPE_ASSERT_RETURN;
      $$.assert_return.invoke.loc = @4;
      $$.assert_return.invoke.name = $5;
      $$.assert_return.invoke.args = $6;
      $$.assert_return.expected = $8;
    }
  | LPAR ASSERT_RETURN_NAN LPAR INVOKE quoted_text const_list RPAR RPAR {
      $$.type = WASM_COMMAND_TYPE_ASSERT_RETURN_NAN;
      $$.assert_return_nan.invoke.loc = @4;
      $$.assert_return_nan.invoke.name = $5;
      $$.assert_return_nan.invoke.args = $6;
    }
  | LPAR ASSERT_TRAP LPAR INVOKE quoted_text const_list RPAR quoted_text RPAR {
      $$.type = WASM_COMMAND_TYPE_ASSERT_TRAP;
      $$.assert_trap.invoke.loc = @4;
      $$.assert_trap.invoke.name = $5;
      $$.assert_trap.invoke.args = $6;
      $$.assert_trap.text = $8;
    }
;
cmd_list :
    /* empty */ { ZEROMEM($$); }
  | cmd_list cmd { $$ = $1; *wasm_append_command(&$$) = $2; }
;

const :
    LPAR CONST literal RPAR {
      $$.loc = @2;
      if (!read_const($2, $3.start, $3.start + $3.length, &$$))
        yyerror(&@3, scanner, parser, "invalid literal \"%.*s\"",
                $3.length, $3.start);
      free((char*)$3.start);
    }
;
const_opt :
    /* empty */ { $$.type = WASM_TYPE_VOID; }
  | const
;
const_list :
    /* empty */ { ZEROMEM($$); }
  | const_list const { $$ = $1; *wasm_append_const(&$$) = $2; }
;

script :
    cmd_list { $$.commands = $1; parser->script = $$; }
;

%%

DEFINE_VECTOR(type, WasmType)
DEFINE_VECTOR(var, WasmVar);
DEFINE_VECTOR(expr_ptr, WasmExprPtr);
DEFINE_VECTOR(target, WasmTarget);
DEFINE_VECTOR(case, WasmCase);
DEFINE_VECTOR(binding, WasmBinding);
DEFINE_VECTOR(func_ptr, WasmFuncPtr);
DEFINE_VECTOR(segment, WasmSegment);
DEFINE_VECTOR(func_type_ptr, WasmFuncTypePtr);
DEFINE_VECTOR(import_ptr, WasmImportPtr);
DEFINE_VECTOR(export_ptr, WasmExportPtr);
DEFINE_VECTOR(module_field, WasmModuleField);
DEFINE_VECTOR(const, WasmConst);
DEFINE_VECTOR(command, WasmCommand);

void yyerror(WasmLocation* loc,
             WasmScanner scanner,
             WasmParser* parser,
             const char* fmt,
             ...) {
  va_list args;
  va_start(args, fmt);
  fprintf(stderr, "%s:%d:%d: ", loc->filename, loc->first_line,
          loc->first_column);
  vfprintf(stderr, fmt, args);
  fprintf(stderr, "\n");
  parser->errors++;
}

static int hexdigit(char c, uint32_t* out) {
  if ((unsigned int)(c - '0') <= 9) {
    *out = c - '0';
    return 1;
  } else if ((unsigned int)(c - 'a') <= 6) {
    *out = 10 + (c - 'a');
    return 1;
  } else if ((unsigned int)(c - 'A') <= 6) {
    *out = 10 + (c - 'A');
    return 1;
  }
  return 0;
}

/* return 1 if the non-NULL-terminated string starting with |start| and ending
 with |end| starts with the NULL-terminated string |prefix|. */
static int string_starts_with(const char* start,
                              const char* end,
                              const char* prefix) {
  while (start < end && *prefix) {
    if (*start != *prefix)
      return 0;
    start++;
    prefix++;
  }
  return *prefix == 0;
}

static int read_uint64(const char* s, const char* end, uint64_t* out) {
  if (s == end)
    return 0;
  uint64_t value = 0;
  if (*s == '0' && s + 1 < end && s[1] == 'x') {
    s += 2;
    if (s == end)
      return 0;
    for (; s < end; ++s) {
      uint32_t digit;
      if (!hexdigit(*s, &digit))
        return 0;
      uint64_t old_value = value;
      value = value * 16 + digit;
      /* check for overflow */
      if (old_value > value)
        return 0;
    }
  } else {
    for (; s < end; ++s) {
      uint32_t digit = (*s - '0');
      if (digit > 9)
        return 0;
      uint64_t old_value = value;
      value = value * 10 + digit;
      /* check for overflow */
      if (old_value > value)
        return 0;
    }
  }
  if (s != end)
    return 0;
  *out = value;
  return 1;
}

static int read_int64(const char* s, const char* end, uint64_t* out) {
  int has_sign = 0;
  if (*s == '-') {
    has_sign = 1;
    s++;
  }
  uint64_t value;
  int result = read_uint64(s, end, &value);
  if (has_sign) {
    if (value > (uint64_t)INT64_MAX + 1) /* abs(INT64_MIN) == INT64_MAX + 1 */
      return 0;
    value = UINT64_MAX - value + 1;
  }
  *out = value;
  return result;
}

static int read_int32(const char* s,
                      const char* end,
                      uint32_t* out,
                      int allow_signed) {
  uint64_t value;
  int has_sign = 0;
  if (*s == '-') {
    if (!allow_signed)
      return 0;
    has_sign = 1;
    s++;
  }
  if (!read_uint64(s, end, &value))
    return 0;

  if (has_sign) {
    if (value > (uint64_t)INT32_MAX + 1) /* abs(INT32_MIN) == INT32_MAX + 1 */
      return 0;
    value = UINT32_MAX - value + 1;
  } else {
    if (value > (uint64_t)UINT32_MAX)
      return 0;
  }
  *out = (uint32_t)value;
  return 1;
}

static int read_float_nan(const char* s, const char* end, float* out) {
  int is_neg = 0;
  if (*s == '-') {
    is_neg = 1;
    s++;
  } else if (*s == '+') {
    s++;
  }
  if (!string_starts_with(s, end, "nan"))
    return 0;
  s += 3;

  uint32_t tag;
  if (s != end) {
    tag = 0;
    if (!string_starts_with(s, end, ":0x"))
      return 0;
    s += 3;

    for (; s < end; ++s) {
      uint32_t digit;
      if (!hexdigit(*s, &digit))
        return 0;
      tag = tag * 16 + digit;
      /* check for overflow */
      const uint32_t max_tag = 0x7fffff;
      if (tag > max_tag)
        return 0;
    }

    /* NaN cannot have a zero tag, that is reserved for infinity */
    if (tag == 0)
      return 0;
  } else {
    /* normal quiet NaN */
    tag = 0x400000;
  }

  uint32_t bits = 0x7f800000 | tag;
  if (is_neg)
    bits |= 0x80000000U;
  memcpy(out, &bits, sizeof(*out));
  return 1;
}

static int read_float(const char* s, const char* end, float* out) {
  if (read_float_nan(s, end, out))
    return 1;

  errno = 0;
  char* endptr;
  float value;
  value = strtof(s, &endptr);
  if (endptr != end ||
      ((value == 0 || value == HUGE_VALF || value == -HUGE_VALF) && errno != 0))
    return 0;

  *out = value;
  return 1;
}

static int read_double_nan(const char* s, const char* end, double* out) {
  int is_neg = 0;
  if (*s == '-') {
    is_neg = 1;
    s++;
  } else if (*s == '+') {
    s++;
  }
  if (!string_starts_with(s, end, "nan"))
    return 0;
  s += 3;

  uint64_t tag;
  if (s != end) {
    tag = 0;
    if (!string_starts_with(s, end, ":0x"))
      return 0;
    s += 3;

    for (; s < end; ++s) {
      uint32_t digit;
      if (!hexdigit(*s, &digit))
        return 0;
      tag = tag * 16 + digit;
      /* check for overflow */
      const uint64_t max_tag = 0xfffffffffffffULL;
      if (tag > max_tag)
        return 0;
    }

    /* NaN cannot have a zero tag, that is reserved for infinity */
    if (tag == 0)
      return 0;
  } else {
    /* normal quiet NaN */
    tag = 0x8000000000000ULL;
  }

  uint64_t bits = 0x7ff0000000000000ULL | tag;
  if (is_neg)
    bits |= 0x8000000000000000ULL;
  memcpy(out, &bits, sizeof(*out));
  return 1;
}

static int read_double(const char* s, const char* end, double* out) {
  if (read_double_nan(s, end, out))
    return 1;

  errno = 0;
  char* endptr;
  double value;
  value = strtod(s, &endptr);
  if (endptr != end ||
      ((value == 0 || value == HUGE_VAL || value == -HUGE_VAL) && errno != 0))
    return 0;

  *out = value;
  return 1;
}

static int read_const(WasmType type,
                      const char* s,
                      const char* end,
                      WasmConst* out) {
  out->type = type;
  switch (type) {
    case WASM_TYPE_I32:
      return read_int32(s, end, &out->u32, 1);
    case WASM_TYPE_I64:
      return read_int64(s, end, &out->u64);
    case WASM_TYPE_F32:
      return read_float(s, end, &out->f32);
    case WASM_TYPE_F64:
      return read_double(s, end, &out->f64);
    default:
      assert(0);
      break;
  }
  return 0;
}

static size_t copy_string_contents(WasmStringSlice* text,
                                   char* dest,
                                   size_t size) {
  const char* src = text->start + 1;
  const char* end = text->start + text->length - 1;

  char* dest_start = dest;

  while (src < end) {
    if (*src == '\\') {
      src++;
      switch (*src) {
        case 'n':
          *dest++ = '\n';
          break;
        case 't':
          *dest++ = '\t';
          break;
        case '\\':
          *dest++ = '\\';
          break;
        case '\'':
          *dest++ = '\'';
          break;
        case '\"':
          *dest++ = '\"';
          break;
        default: {
          /* The string should be validated already, so we know this is a hex
           * sequence */
          uint32_t hi;
          uint32_t lo;
          if (!hexdigit(src[0], &hi) || !hexdigit(src[1], &lo))
            assert(0);
          *dest++ = (hi << 4) | lo;
          src++;
          break;
        }
      }
      src++;
    } else {
      *dest++ = *src++;
    }
  }
  /* return the data length */
  return dest - dest_start;
}

static void dup_string_contents(WasmStringSlice* text,
                                void** out_data,
                                size_t* out_size) {
  const char* src = text->start + 1;
  const char* end = text->start + text->length - 1;
  /* Always allocate enough space for the entire string including the escape
   * characters. It will only get shorter, and this way we only have to iterate
   * through the string once. */
  size_t size = end - src;
  char* result = malloc(size);
  size_t actual_size = copy_string_contents(text, result, size);
  *out_data = result;
  *out_size = actual_size;
}