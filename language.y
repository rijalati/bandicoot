/*
Copyright 2008-2010 Ostap Cherkashin
Copyright 2008-2010 Julius Chrobak

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

%{
#include "config.h"
#include "array.h"
#include "system.h"
#include "memory.h"
#include "number.h"
#include "string.h"
#include "head.h"
#include "value.h"
#include "tuple.h"
#include "expression.h"
#include "summary.h"
#include "relation.h"

#include "language.h"
#include "environment.h"

extern void yyerror(const char *, ...);
extern int yylex();

static Env *genv = NULL;

static L_Attrs attr_name(const char *name);
static L_Attrs attr_rel(const char *name, Type type);
static L_Attrs attr_rename(const char *from, const char *to);
static L_Attrs attr_extend(const char *name, L_Expr *e);
static L_Attrs attr_sum(const char *name, L_Sum sum);
static L_Attrs attr_merge(L_Attrs l, L_Attrs r);
static void attr_free(L_Attrs attrs);

static Head *rel_head(L_Attrs attrs);
static Head *inline_rel(char *name, Head *head);

static L_Rel *r_load(const char *var);
static L_Rel *r_unary(L_Rel *l, L_Attrs attrs, L_Rel_Type node_type);
static L_Rel *r_binary(L_Rel *l, L_Rel *r, L_Rel_Type node_type);
static L_Rel *r_select(L_Rel *l, L_Expr *expr);
static L_Rel *r_sum(L_Rel *r, L_Rel *per, L_Attrs attrs);
static void r_free(L_Rel *r);

static L_Expr *p_attr(const char *name);
static L_Expr *p_value(L_Value val, Type t);
static L_Expr *p_op(L_Expr *l, L_Expr *r, L_Expr_Type node_type);
static void p_free(L_Expr *e);
static int is_constant(L_Expr *e);


static L_Stmts stmt_create(L_Stmt_Type type, 
                           Head *rel_type,
                           const char *name,
                           L_Rel *e);
static L_Stmts stmt_merge(L_Stmts l, L_Stmts r);
static L_Stmts stmt_empty();

static L_Sum sum_create(const char *func, const char *attr, L_Expr *def);

static void add_head(const char *name, Head *head);
static void add_relvar(const char *rel, const char *var);
static void add_func(const char *name,
                     L_Stmts params,
                     Head *res_type,
                     L_Stmts stmts);
%}

%union {
    char name[MAX_NAME];
    Head *head;

    L_Value val;
    L_Rel *rel;
    L_Expr *expr;
    L_Attrs attrs;
    L_Sum sum;
    L_Stmts stmts;
};

%token TK_REL TK_FN TK_RETURN
%token TK_INT TK_LONG TK_REAL TK_STRING
%token TK_PROJECT TK_RENAME TK_SELECT TK_EXTEND TK_SUMMARIZE
%token TK_EQ TK_NEQ TK_AND TK_OR

%token <name> TK_NAME
%token <val> TK_INT_VAL TK_LONG_VAL TK_REAL_VAL TK_STRING_VAL

%type <attrs> rel_attr rel_attrs
%type <attrs> project_attr project_attrs
%type <attrs> rename_attr rename_attrs
%type <attrs> extend_attr extend_attrs
%type <attrs> summarize_attrs summarize_attr
%type <rel> rel_prim_expr rel_unary_expr rel_binary_expr rel_mul_expr rel_expr
%type <expr> prim_const_expr prim_simple_expr prim_top_expr prim_unary_expr
%type <expr> prim_mul_expr prim_add_expr prim_bool_cmp_expr prim_expr
%type <sum> summarize_func
%type <stmts> func_params func_body stmt_return stmt_assign stmt_assigns
%type <head> rel_head func_res

%%

program:
      program rel_decl
    | program relvar_decl
    | program func_decl
    |
    ;

rel_decl:
      TK_REL TK_NAME rel_head   { add_head($2, $3); }
    ;

rel_head:
      '{' rel_attrs '}'     { $$ = rel_head($2); }
    | '{' rel_attrs ',' '}' { $$ = rel_head($2); }
    ;

rel_attrs:
      rel_attr                  { $$ = $1; }
    | rel_attrs ',' rel_attr    { $$ = attr_merge($1, $3);}
    ;

rel_attr:
      TK_NAME ':' TK_INT        { $$ = attr_rel($1, Int); }
    | TK_NAME ':' TK_LONG       { $$ = attr_rel($1, Long); }
    | TK_NAME ':' TK_REAL       { $$ = attr_rel($1, Real); }
    | TK_NAME ':' TK_STRING     { $$ = attr_rel($1, String); }
    ;

relvar_decl:
      TK_NAME ':' TK_NAME ';'   { add_relvar($3, $1); }
    ;

func_decl:
      TK_FN TK_NAME '(' func_params ')' func_res '{' func_body '}'
        { add_func($2, $4, $6, $8); }
    ;

func_res:
      ':' TK_NAME           { $$ = inline_rel($2, NULL); }
    | ':' TK_REL rel_head   { $$ = inline_rel(NULL, $3); }
    |                       { $$ = inline_rel(NULL, NULL); }
    ;

func_params:
      TK_NAME ':' TK_NAME
        { $$ = stmt_create(PARAM, inline_rel($3, NULL), $1, NULL); }
    | TK_NAME ':' TK_REL rel_head
        { $$ = stmt_create(PARAM, inline_rel(NULL, $4), $1, NULL); }
    |
        { $$ = stmt_empty(); }
    ;

func_body:
      stmt_return               { $$ = $1; }
    | stmt_assigns              { $$ = $1; }
    | stmt_assigns stmt_return  { $$ = stmt_merge($1, $2); }
    ;

stmt_return:
      TK_RETURN rel_expr ';'    { $$ = stmt_create(RETURN, NULL, "", $2); }
    ;

stmt_assigns:
      stmt_assign                   { $$ = $1; }
    | stmt_assigns stmt_assign      { $$ = stmt_merge($1, $2); }
    ;

stmt_assign:
      TK_NAME '=' rel_expr ';'      { $$ = stmt_create(ASSIGN, NULL, $1, $3); }
    | TK_NAME ':' '=' rel_expr ';'  { $$ = stmt_create(TEMP, NULL, $1, $4); }
    ;

rel_prim_expr:
      TK_NAME           { $$ = r_load($1); }
    | '(' rel_expr ')'  { $$ = $2; }
    ;

rel_unary_expr:
      rel_prim_expr
        { $$ = $1; }
    | rel_unary_expr TK_PROJECT '(' project_attrs ')'
        { $$ = r_unary($1, $4, PROJECT); }
    | rel_unary_expr TK_RENAME '(' rename_attrs ')'
        { $$ = r_unary($1, $4, RENAME); }
    | rel_unary_expr TK_SELECT '(' prim_expr ')'
        { $$ = r_select($1, $4); }
    | rel_unary_expr TK_EXTEND '(' extend_attrs ')'
        { $$ = r_unary($1, $4, EXTEND); }
    | rel_unary_expr TK_SUMMARIZE '(' summarize_attrs ')'
        { $$ = r_sum($1, NULL, $4); }
    ;

rel_binary_expr:
      rel_unary_expr
        { $$ = $1; }
    | rel_unary_expr TK_SUMMARIZE '(' summarize_attrs ')' rel_binary_expr
        { $$ = r_sum($1, $6, $4); }
    ;

rel_mul_expr:
      rel_binary_expr                   { $$ = $1; }
    | rel_mul_expr '*' rel_binary_expr  { $$ = r_binary($1, $3, JOIN); }
    ;

rel_expr:
      rel_mul_expr                      { $$ = $1; }
    | rel_expr '+' rel_mul_expr         { $$ = r_binary($1, $3, UNION); }
    | rel_expr '-' rel_mul_expr         { $$ = r_binary($1, $3, DIFF); }
    ;

project_attrs:
      project_attr                       { $$ = $1; }
    | project_attrs ',' project_attr     { $$ = attr_merge($1, $3); }
    ;

project_attr:
      TK_NAME                            { $$ = attr_name($1); }
    ;

rename_attrs:
      rename_attr                        { $$ = $1; }
    | rename_attrs ',' rename_attr       { $$ = attr_merge($1, $3); }
    ;

rename_attr:
      TK_NAME '=' TK_NAME                { $$ = attr_rename($3, $1); }
    ;

extend_attrs:
      extend_attr                        { $$ = $1; }
    | extend_attrs ',' extend_attr       { $$ = attr_merge($1, $3); }
    ;

extend_attr:
      TK_NAME '=' prim_expr              { $$ = attr_extend($1, $3); }
    ;

summarize_attrs:
      summarize_attr                     { $$ = $1; }
    | summarize_attrs ',' summarize_attr { $$ = attr_merge($1, $3); }
    ;

summarize_attr:
      TK_NAME '=' summarize_func         { $$ = attr_sum($1, $3); }
    ;

summarize_func:
      TK_NAME '(' ')'
        { $$ = sum_create($1, "", NULL); }
    | TK_NAME '(' TK_NAME ',' prim_expr ')'
        { $$ = sum_create($1, $3, $5); }
    ;

/* TODO: func calls - rounding and type conversion */
prim_const_expr:
      TK_INT_VAL                                { $$ = p_value($1, Int); }
    | TK_LONG_VAL                               { $$ = p_value($1, Long); }
    | TK_REAL_VAL                               { $$ = p_value($1, Real); }
    | TK_STRING_VAL                             { $$ = p_value($1, String); }
    ;

prim_simple_expr:
      prim_const_expr                           { $$ = $1; }
    | '(' prim_expr ')'                         { $$ = $2; }
    ;

prim_top_expr:
      prim_simple_expr                          { $$ = $1; }
    | TK_NAME                                   { $$ = p_attr($1); }
    ;

prim_unary_expr:
      prim_top_expr                             { $$ = $1; }
    | '!' prim_unary_expr                       { $$ = p_op($2, 0, NOT); }
    | '-' prim_simple_expr                      { $$ = p_op($2, 0, NEG); }
    | '+' prim_simple_expr                      { $$ = $2; }
    ;

prim_mul_expr:
      prim_unary_expr                           { $$ = $1; }
    | prim_mul_expr '*' prim_unary_expr         { $$ = p_op($1, $3, MUL); }
    | prim_mul_expr '/' prim_unary_expr         { $$ = p_op($1, $3, DIV); }
    ;

prim_add_expr:
      prim_mul_expr                             { $$ = $1; }
    | prim_add_expr '+' prim_mul_expr           { $$ = p_op($1, $3, SUM); }
    | prim_add_expr '-' prim_mul_expr           { $$ = p_op($1, $3, SUB); }
    ;

prim_bool_cmp_expr:
      prim_add_expr                             { $$ = $1; }
    | prim_bool_cmp_expr TK_EQ prim_add_expr    { $$ = p_op($1, $3, EQ); }
    | prim_bool_cmp_expr TK_NEQ prim_add_expr   { $$ = p_op($1, $3, NEQ); }
    | prim_bool_cmp_expr '>' prim_add_expr      { $$ = p_op($1, $3, GT); }
    | prim_bool_cmp_expr '<' prim_add_expr      { $$ = p_op($1, $3, LT); }
    ;

prim_expr:
      prim_bool_cmp_expr                        { $$ = $1; }
    | prim_expr TK_AND prim_bool_cmp_expr       { $$ = p_op($1, $3, AND); }
    | prim_expr TK_OR prim_bool_cmp_expr        { $$ = p_op($1, $3, OR); }
    ;

%%

extern void env_free(Env *env)
{
    for (int i = 0; i < env->vars.len; ++i)
        mem_free(env->vars.names[i]);

    for (int k = 0; k < env->types.len; ++k) {
        mem_free(env->types.names[k]);
        mem_free(env->types.heads[k]);
    }

    for (int x = 0; x < env->fns.len; ++x) {
        Func *fn = env->fns.funcs[x];
        for (int j = 0; j < fn->r.len; ++j)
            mem_free(fn->r.vars[j]);
        for (int j = 0; j < fn->w.len; ++j) {
            mem_free(fn->w.vars[j]);
            rel_free(fn->w.rels[j]);
        }
        for (int j = 0; j < fn->t.len; ++j) {
            mem_free(fn->t.names[j]);
            rel_free(fn->t.rels[j]);
        }
        for (int j = 0; j < fn->p.len; ++j) {
            mem_free(fn->p.names[j]);
            rel_free(fn->p.rels[j]);
        }
        if (fn->ret != NULL)
            rel_free(fn->ret);

        mem_free(fn);
        mem_free(env->fns.names[x]);
    }

    mem_free(env);
}

extern Env *grammar_init()
{
    genv = mem_alloc(sizeof(Env));
    genv->types.len = 0;
    genv->vars.len = 0;
    genv->fns.len = 0;

    return genv;
}

extern Head *env_head(Env *env, const char *var)
{
    int i = array_scan(env->vars.names, env->vars.len, var);
    if (i < 0)
        return NULL;

    return head_cpy(env->vars.heads[i]);
}

extern Func *env_func(Env *env, const char *name)
{
    return env->fns.funcs[array_scan(env->fns.names, env->fns.len, name)];
}

static L_Attrs attr_name(const char *name)
{
    L_Attrs res = {.len = 1,
                   .names[0] = str_dup(name),
                   .renames[0] = NULL,
                   .types[0] = -1,
                   .exprs[0] = NULL,
                   .sums[0].def = NULL};
    return res;
}

static L_Attrs attr_rel(const char *name, Type type)
{
    L_Attrs res = attr_name(name);
    res.types[0] = type;
    return res;
}

static L_Attrs attr_rename(const char *from, const char *to)
{
    L_Attrs res = attr_name(from);
    res.renames[0] = str_dup(to);
    return res;
}

static L_Attrs attr_extend(const char *name, L_Expr *e)
{
    L_Attrs res = attr_name(name);
    res.exprs[0] = e;
    return res;
}

static L_Attrs attr_sum(const char *name, L_Sum sum)
{
    L_Attrs res = attr_name(name);
    res.types[0] = sum.def->type;
    res.sums[0] = sum;
    return res;
}

static L_Attrs attr_merge(L_Attrs l, L_Attrs r)
{
    if (l.len + r.len > MAX_ATTRS)
        yyerror("number of attributes (%d) exceeds the maximum", l.len);

    for (int i = 0; i < r.len && l.len < MAX_ATTRS; ++i) {
        if (array_scan(l.names, l.len, r.names[i]) > -1)
            yyerror("attribute '%s' is already used", r.names[i]);

        l.names[l.len] = r.names[i];
        l.renames[l.len] = r.renames[i];
        l.types[l.len] = r.types[i];
        l.exprs[l.len] = r.exprs[i];
        l.sums[l.len] = r.sums[i];

        l.len++;
    }

    return l;
}

static L_Sum sum_create(const char *func, const char *attr, L_Expr *def)
{
    L_Sum res;
    if (str_cmp(func, "count") == 0)
        res.sum_type = COUNT;
    else if (str_cmp(func, "avg") == 0)
        res.sum_type = AVG;
    else if (str_cmp(func, "max") == 0)
        res.sum_type = MAX;
    else if (str_cmp(func, "min") == 0)
        res.sum_type = MIN;
    else if (str_cmp(func, "add") == 0)
        res.sum_type = ADD;
    else
        yyerror("unkown function in summarize operator %s", func);

    str_cpy(res.attr, attr);
    res.def = def;

    return res;
}

static void attr_free(L_Attrs a) {
    for (int i = 0; i < a.len; ++i) {
        mem_free(a.names[i]);
        if (a.renames[i] != NULL)
            mem_free(a.renames[i]);
        if (a.exprs[i] != NULL)
            p_free(a.exprs[i]);
        if (a.sums[i].def != NULL)
            mem_free(a.sums[i].def);
    }
}

static Head *rel_head(L_Attrs attrs)
{
    Head *res = head_new(attrs.names, attrs.types, attrs.len);
    attr_free(attrs);

    return res;
}

static void add_head(const char *name, Head *head)
{
    if (array_scan(genv->types.names, genv->types.len, name) > -1)
        yyerror("relation type '%s' is already defined", name);
    else {
        int i = genv->types.len++;
        genv->types.names[i] = str_dup(name);
        genv->types.heads[i] = head;
    }
}

static void add_relvar(const char *rel, const char *var)
{
    int i = array_scan(genv->types.names, genv->types.len, rel);

    if (i == -1)
        yyerror("relation type '%s' does not exist", rel);
    else if (array_scan(genv->vars.names, genv->vars.len, var) > -1)
        yyerror("relational variable '%s' is already defined", var);
    else if (array_scan(genv->types.names, genv->types.len, var) > -1)
        yyerror("relational type '%s' cannot be used as a variable name", var);
    else {
        int j = genv->vars.len++;
        genv->vars.names[j] = str_dup(var);
        genv->vars.heads[j] = genv->types.heads[i];
    }
}

static Expr *p_convert(Head *h, L_Expr *e, L_Expr_Type parent_type)
{
    Expr *res = NULL, *l = NULL, *r = NULL;
    L_Expr_Type t = e->node_type;

    if (e->left != NULL)
        l = p_convert(h, e->left, t);
    if (e->right != NULL)
        r = p_convert(h, e->right, t);

    if (t == ATTR) {
        int pos;
        Type type;
        if (!head_attr(h, e->name, &pos, &type))
            yyerror("unknown attribute %s", e->name);
        res = expr_attr(pos, type);
    } else if (t == VALUE && e->type == Int) {
        int i = e->val.v_int;
        if (int_overflow((parent_type == NEG ? -1 : 1), i))
            yyerror("int constant value overflow %u", i);

        res = expr_int(i);
    } else if (t == VALUE && e->type == Long) {
        long long l = e->val.v_long;
        if (long_overflow((parent_type == NEG ? -1 : 1), l))
            yyerror("long constant value overflow %llu", l);
    
        res = expr_long(l);
    } else if (t == VALUE && e->type == Real)
        res = expr_real(e->val.v_real);
    else if (t == VALUE && e->type == String)
        res = expr_str(e->val.v_str);
    else if (t == NOT) {
        if (l->type != Int)
            yyerror("expressions must be of type Int, found %d", l->type);
        res = expr_not(l);
    } else if (t == NEG) {
        if (l->type == Int)
            res = expr_mul(l, expr_int(-1));
        else if (l->type == Real)
            res = expr_mul(l, expr_real(-1));
        else if (l->type == Long)
            res = expr_mul(l, expr_long(-1));
        else
            yyerror("NEG operator does not support %d type", l->type);
    } else {
        if (l->type != r->type)
            yyerror("expressions must be of the same type, found %d and %d",
                    l->type, r->type);

        if (t == EQ) {
            res = expr_eq(l, r);
        } else if (t == NEQ) {
            res = expr_not(expr_eq(l, r));
        } else if (t == AND) {
            if (l->type != Int)
                yyerror("AND operator expects Int but got %d", l->type);
            res = expr_and(l, r);
        } else if (t == OR) {
            if (l->type != Int)
                yyerror("OR operator expects Int but got %d", l->type);
            res = expr_or(l, r);
        } else if (t == GT) {
            res = expr_gt(l, r);
        } else if (t == LT) {
            res = expr_lt(l, r);
        } else if (t == SUM) {
            if (l->type == String)
                yyerror("SUM operator does not support String type");
            res = expr_sum(l, r);
        } else if (t == SUB) {
            if (l->type == String)
                yyerror("SUB operator does not support String type");
            res = expr_sub(l, r);
        } else if (t == MUL) {
            if (l->type == String)
                yyerror("MUL operator does not support String type");
            res = expr_mul(l, r);
        } else if (t == DIV) {
            if (l->type == String)
                yyerror("DIV operator does not support String type");
            res = expr_div(l, r);
        }
    }

    return res;
}

static Rel *r_convert(L_Rel *rel,
                      L_Stmts stmts,
                      int pos,
                      Rel *clones[MAX_STMTS][MAX_RVARS])
{
    Rel *res = NULL, *l = NULL, *r = NULL;
    L_Attrs attrs;

    if (rel->left != NULL)
        l = r_convert(rel->left, stmts, pos, clones);
    if (rel->right != NULL)
        r = r_convert(rel->right, stmts, pos, clones);

    attrs = rel->attrs;
    L_Rel_Type t = rel->node_type;
    if (t == LOAD) {
        int tv_idx = array_scan(stmts.names, pos, rel->var);
        int rv_idx = array_scan(genv->vars.names, genv->vars.len, rel->var);

        if (tv_idx >= 0 && tv_idx < pos && rv_idx < 0) { /* local */
            for (int i = 0; i < MAX_RVARS; ++i) {
                if (clones[tv_idx][i] != NULL) {
                    res = clones[tv_idx][i];
                    clones[tv_idx][i] = NULL;
                    break;
                }
            }
            /* FIXME: what if (i == MAX_RVARS) */
        } else if (tv_idx < 0 && rv_idx >= 0) { /* global */
            res = rel_load(env_head(genv, rel->var), rel->var);
        } else if (rv_idx < 0) {
            yyerror("variable '%s' is not defined", rel->var);
        } else
            yyerror("variable '%s' cannot be read (it was modified by "
                    "one of the previous statements)", rel->var);
    } else if (t == PROJECT) {
        for (int i = 0; i < attrs.len; ++i)
            if (!head_find(l->head, attrs.names[i])) {
                /* TODO: print out heads when attributes not found. it is
                          helpful to see what is the actual head, especially
                          for new users which aren't that familiar with the
                          evaluation order, e.g. x sum [] y project []

                char str[MAX_ATTRS * MAX_NAME];
                char *s = str;
                for (int k = 0; k < l->head->len; ++k)
                    s += str_print(s, "%s,", l->head->names[k]);

                yyerror("unknown attribute '%s' in project, head(%d): %s",
                         attrs.names[i], l->head->len, str);
                */
                yyerror("unknown attribute '%s' in project", attrs.names[i]);
            }

        res = rel_project(l, attrs.names, attrs.len);
    } else if (t == RENAME) {
        char **renames = attrs.renames;

        for (int i = 0; i < attrs.len; ++i) {
            int j = array_scan(renames, attrs.len, renames[i]);
 
            /* TODO: below checks are too strict, we should be able to do
                      x { a, b, c } - rename(x: a => b, b => c, c => d); */
            if (!head_find(l->head, attrs.names[i]))
                yyerror("unknown attribute '%s' in rename", attrs.names[i]);
            if (head_find(l->head, renames[i]) || (j > -1 && j != i))
                yyerror("rename to '%s' overwrites existing attribute", 
                        renames[i]);
        }

        res = rel_rename(l, attrs.names, renames, attrs.len);
    } else if (t == SELECT) {
        res = rel_select(l, p_convert(l->head, rel->expr, POS));
    } else if (t == EXTEND) {
        Expr *extends[MAX_ATTRS];
        for (int i = 0; i < attrs.len; ++i) {
            if (head_find(l->head, attrs.names[i]))
                yyerror("attribute %s is already defined", attrs.names[i]);
            extends[i] = p_convert(l->head, attrs.exprs[i], POS);
        }

        res = rel_extend(l, attrs.names, extends, attrs.len);
    } else if (t == JOIN) {
        for (int i = 0; i < l->head->len; ++i) {
            char *n = l->head->names[i];
            Type t; int pos;
            if (head_attr(r->head, n, &pos, &t))
                if (t != l->head->types[i])
                    yyerror("attribute '%s' is of different types", n);
        }
        res = rel_join(l, r);
    } else if (t == UNION) {
        if (!head_eq(l->head, r->head))
            yyerror("cannot union relations of different types");
        res = rel_union(l, r);
    } else if (t == DIFF) {
        int lpos[MAX_ATTRS], rpos[MAX_ATTRS];
        if (head_common(l->head, r->head, lpos, rpos) == 0)
            yyerror("use of semidiff with no commmon attributes");
        res = rel_diff(l, r);
    } else if (t == SUMMARIZE) {
        Sum *sums[MAX_ATTRS];
        for (int i = 0; i < attrs.len; ++i) {
            L_Sum s = attrs.sums[i];

            int lpos[MAX_ATTRS], rpos[MAX_ATTRS];
            if (r != NULL) {
                if (head_common(l->head, r->head, lpos, rpos) == 0)
                    yyerror("use of summarize with no commmon attributes");

                if (head_find(r->head, attrs.names[i]))
                    yyerror("attribute %s is already defined in per relation",
                            attrs.names[i]);
            }

            if (s.sum_type == COUNT)
                sums[i] = sum_count();
            else {
                if (!is_constant(s.def))
                    yyerror("only constant expressions are allowed for "
                            "default values");
                int pos;
                Type stype;
                if (!head_attr(l->head, s.attr, &pos, &stype))
                    yyerror("attribute %s does not exist", s.attr);

                Type exp_type = stype;
                if (s.sum_type == AVG)
                    exp_type = Real;

                Expr *def = p_convert(l->head, s.def, POS);
                if (def->type != exp_type)
                    yyerror("invalid type of default value, expected %d, "
                            "got %d", exp_type, def->type);
                
                if (def->type == String || stype == String)
                    yyerror("invalid type of default value: string");
                 
                Value v = expr_new_val(def, NULL);
                if (s.sum_type == AVG)
                    sums[i] = sum_avg(pos, stype, v);
                else if (s.sum_type == MIN)
                    sums[i] = sum_min(pos, stype, v);
                else if (s.sum_type == MAX)
                    sums[i] = sum_max(pos, stype, v);
                else if (s.sum_type == ADD)
                    sums[i] = sum_add(pos, stype, v);
            }
        }

        if (r == NULL)
            res = rel_sum_unary(l, attrs.names, attrs.types, sums, attrs.len);
        else
            res = rel_sum(l, r, attrs.names, attrs.types, sums, attrs.len);
    }
    return res;
}

static void append_rvars(L_Rel *rel, char *rvars[MAX_RVARS], int *pos)
{
    if (*pos >= MAX_RVARS)
        yyerror("number of read variables exceeds maximum");

    if (rel->node_type == LOAD && array_scan(rvars, *pos, rel->var) == -1)
        rvars[(*pos)++] = str_dup(rel->var);
    if (rel->left != NULL)
        append_rvars(rel->left, rvars, pos);
    if (rel->right != NULL)
        append_rvars(rel->right, rvars, pos);
}

static void count_reads(const char *name, L_Rel *rel, int *cnt)
{
    if (rel->node_type == LOAD && str_cmp(name, rel->var) == 0)
        (*cnt)++;
    else {
        if (rel->left != NULL)
            count_reads(name, rel->left, cnt);
        if (rel->right != NULL)
            count_reads(name, rel->right, cnt);
    }
}

static L_Stmts stmt_create(L_Stmt_Type type, 
                           Head *rel_type,
                           const char *name,
                           L_Rel *e)
{
    L_Stmts res = { .len = 1,
                    .types[0] = type,
                    .heads[0] = rel_type,
                    .names[0] = str_dup(name),
                    .bodies[0] = e };
    return res;
}

static L_Stmts stmt_merge(L_Stmts l, L_Stmts r)
{
    if (l.len + r.len > MAX_STMTS)
        yyerror("maximum number of statements exceeded"); 

    for (int i = 0; i < r.len; ++i, ++l.len) {
        l.types[l.len] = r.types[i];
        l.heads[l.len] = r.heads[i];
        l.names[l.len] = r.names[i];
        l.bodies[l.len] = r.bodies[i];
    }

    return l;
}

static L_Stmts stmt_empty()
{
    L_Stmts res = { .len = 0 };
    return res;
}

static Head *inline_rel(char *name, Head *head)
{
    Head *res = NULL;
    if (name == NULL && head != NULL) {
        res = head_cpy(head);
    } else if (name != NULL) {
        int idx = array_scan(genv->types.names, genv->types.len, name);
        if (idx < 0)
            yyerror("unknown relation type '%s'", name);

        res = head_cpy(genv->types.heads[idx]);
    }

    return res;
}

static void add_func(const char *name,
                     L_Stmts params,
                     Head *res_type,
                     L_Stmts stmts)
{
    if (array_scan(genv->fns.names, genv->fns.len, name) > -1)
        yyerror("function '%s' is already declared", name);

    Func *fn = mem_alloc(sizeof(Func));
    fn->ret = NULL;
    fn->r.len = 0;
    fn->w.len = 0;
    fn->t.len = 0;
    fn->p.len = 0;

    stmts = stmt_merge(params, stmts);

    int t_cnts[MAX_STMTS];
    Rel *t_clones[MAX_STMTS][MAX_RVARS];
    for (int i = 0; i < stmts.len; ++i)
        if (stmts.types[i] == TEMP || stmts.types[i] == PARAM) {
            char *wvar = stmts.names[i];
            if (array_scan(stmts.names, i, wvar) > -1 ||
                array_scan(genv->vars.names, genv->vars.len, wvar) > -1)
                yyerror("variable '%s' is already declared", wvar);

            t_cnts[i] = 0;
            for (int j = i + 1; j < stmts.len; ++j)
                count_reads(wvar, stmts.bodies[j], &t_cnts[i]);

            for (int j = 0; j < MAX_RVARS; ++j)
                t_clones[i][j] = NULL;
        }

    for (int i = 0; i < stmts.len; ++i) { 
        Rel *body = NULL;
        char *wvar = stmts.names[i];

        if (stmts.types[i] == PARAM) {
            body = rel_param(stmts.heads[i], stmts.names[i]);
            fn->p.names[fn->p.len] = wvar;
            fn->p.rels[fn->p.len++] = rel_tmp(body, t_clones[i], t_cnts[i]);
        } else {
            append_rvars(stmts.bodies[i], fn->r.vars, &fn->r.len);

            body = r_convert(stmts.bodies[i], stmts, i, t_clones);
            r_free(stmts.bodies[i]);
        }

        if (stmts.types[i] == ASSIGN) {
            int idx = array_scan(stmts.names, stmts.len, wvar);
            if (idx != i)
                yyerror("cannot reassign variable '%s'", wvar);

            idx = array_scan(genv->vars.names, genv->vars.len, wvar);
            if (idx == -1)
                yyerror("relational variable '%s' is not declared", wvar);

            if (!head_eq(body->head, genv->vars.heads[idx]))
                yyerror("wrong types in assignment");

            fn->w.vars[fn->w.len] = wvar;
            fn->w.rels[fn->w.len++] = body; 
        } else if (stmts.types[i] == RETURN) {
            if (res_type == NULL)
                yyerror("unexpected return in function with void result type");

            /* TODO: print out the heads */
            Head *h = body->head;
            int pos;
            Type t;
            for (int i = 0; i < res_type->len; ++i)
                if (!head_attr(h, res_type->names[i], &pos, &t) ||
                    t != res_type->types[i])
                    yyerror("bad return type");

            fn->ret = rel_project(body, res_type->names, res_type->len);
            mem_free(res_type);
            mem_free(wvar);
        } else if (stmts.types[i] == TEMP) {
            fn->t.names[fn->t.len] = wvar;
            fn->t.rels[fn->t.len++] = rel_tmp(body, t_clones[i], t_cnts[i]);
        }
    }

    int len = genv->fns.len++;
    genv->fns.names[len] = str_dup(name);
    genv->fns.funcs[len] = fn;
}

static void r_free(L_Rel *r)
{
    if (r->left != NULL)
        r_free(r->left);
    if (r->right != NULL)
        r_free(r->right);

    if (r->node_type == SELECT)
        p_free(r->expr);

    attr_free(r->attrs);
    mem_free(r);
}

static L_Rel *r_alloc(L_Rel_Type node_type)
{
    L_Rel *res = mem_alloc(sizeof(L_Rel));
    res->node_type = node_type;
    res->attrs.len = 0;
    res->left = NULL;
    res->right = NULL;
    res->expr = NULL;

    return res;
}

static L_Rel *r_load(const char *var)
{
    L_Rel *res = r_alloc(LOAD);
    str_cpy(res->var, var);

    return res;
}

static L_Rel *r_binary(L_Rel *l, L_Rel *r, L_Rel_Type node_type)
{
    L_Rel *res = r_alloc(node_type);
    res->left = l;
    res->right = r;

    return res;
}

static L_Rel *r_unary(L_Rel *l, L_Attrs attrs, L_Rel_Type node_type)
{
    L_Rel *res = r_alloc(node_type);
    res->left = l;
    res->attrs = attrs;

    return res;
}

static L_Rel *r_select(L_Rel *l, L_Expr *expr)
{
    L_Rel *res = r_alloc(SELECT);
    res->left = l;
    res->expr = expr;

    return res;
}

static L_Rel *r_sum(L_Rel *r, L_Rel *per, L_Attrs attrs)
{
    L_Rel *res = r_binary(r, per, SUMMARIZE);
    res->attrs = attrs;

    return res;
}

static void p_free(L_Expr *e)
{
    if (e->left != NULL)
        p_free(e->left);
    if (e->right != NULL)
        p_free(e->right);

    mem_free(e);
}

static L_Expr *p_alloc(L_Expr_Type t)
{
    L_Expr *res = mem_alloc(sizeof(L_Expr));
    res->node_type = t;
    res->type = 0;
    res->left = NULL;
    res->right = NULL;
    res->val.v_long = 0;
    res->name[0] = '\0';
    res->is_const = 1;

    return res;
}

static L_Expr *p_attr(const char *name)
{
    L_Expr *res = p_alloc(ATTR);
    str_cpy(res->name, name);
    res->is_const = 0;

    return res;
}

static L_Expr *p_value(L_Value val, Type t)
{
    L_Expr *res = p_alloc(VALUE);
    res->type = t;
    res->val = val;

    return res;
}

static L_Expr *p_op(L_Expr *l, L_Expr *r, L_Expr_Type node_type)
{
    L_Expr *res = p_alloc(node_type);
    res->left = l;
    res->right = r;
    res->type = l->type;

    return res;
}

static int is_constant(L_Expr *e)
{
    int res = e->is_const;

    if (e->left != NULL)
        res = res && is_constant(e->left);
    if (e->right != NULL)
        res = res && is_constant(e->right);
        
    return res;    
}

extern int env_compat(Env *old, Env *new)
{
    for (int i = 0; i < old->vars.len; ++i) {
        Head *h = env_head(new, old->vars.names[i]);
        if (h != NULL && !head_eq(h, old->vars.heads[i]))
            return 0;
    }

    return 1;
}
