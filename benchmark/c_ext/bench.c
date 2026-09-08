/*
 * php-zig benchmark —— 原生 C 扩展实现（模块 bench_c）
 *
 * 用 Zend Engine 官方惯用写法（ZEND_PARSE_PARAMETERS fast ZPP），
 * 作为「理论下限 / 原生上限」参照。php-zig 的目标是无限接近它。
 *
 * 用例语义必须与 bench_zig / pure_php 严格一致，否则对比无意义。
 * 各用例测什么见 README.md 的用例表。
 */
#include "php.h"
#include "zend_exceptions.h"
#include "zend_closures.h"
#include "ext/standard/php_var.h"
#include "zend_smart_str.h"
#include <string.h>

/* — empty：纯调用分发开销 — */

PHP_FUNCTION(bench_empty)
{
    RETURN_NULL();
}

/* — add：参数读取 + 整数返回 — */

PHP_FUNCTION(bench_add)
{
    zend_long a, b;
    ZEND_PARSE_PARAMETERS_START(2, 2)
        Z_PARAM_LONG(a)
        Z_PARAM_LONG(b)
    ZEND_PARSE_PARAMETERS_END();
    RETURN_LONG(a + b);
}

/* — concat：字符串拼接。
 *   一次分配 + 两次 memcpy，无格式串解析——与 php-zig 侧同路径，
 *   避免把「格式化开销」误算进语言差异。 */

PHP_FUNCTION(bench_concat)
{
    zend_string *s1, *s2;
    ZEND_PARSE_PARAMETERS_START(2, 2)
        Z_PARAM_STR(s1)
        Z_PARAM_STR(s2)
    ZEND_PARSE_PARAMETERS_END();

    zend_string *r = zend_string_alloc(ZSTR_LEN(s1) + ZSTR_LEN(s2), 0);
    memcpy(ZSTR_VAL(r), ZSTR_VAL(s1), ZSTR_LEN(s1));
    memcpy(ZSTR_VAL(r) + ZSTR_LEN(s1), ZSTR_VAL(s2), ZSTR_LEN(s2));
    ZSTR_VAL(r)[ZSTR_LEN(r)] = '\0';
    RETVAL_STR(r);
}

/* — array_build：数组写入开销 — */

PHP_FUNCTION(bench_array_build)
{
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    zval arr;
    array_init(&arr);
    for (zend_long i = 0; i < n; i++) {
        add_next_index_long(&arr, i);
    }
    zval_ptr_dtor(&arr);
    RETURN_LONG(n);
}

/* — array_read：数组读取开销（建表 + 逐个读回求和）。
 *   与 array_build 分离：前者测写、后者测读，合并在一起时读的开销
 *   会被建表噪音掩盖。 */

PHP_FUNCTION(bench_array_read)
{
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    zval arr;
    array_init(&arr);
    for (zend_long i = 0; i < n; i++) {
        add_next_index_long(&arr, i);
    }

    zend_long sum = 0;
    for (zend_long i = 0; i < n; i++) {
        zval *v = zend_hash_index_find(Z_ARRVAL(arr), (zend_ulong) i);
        if (v) sum += Z_LVAL_P(v);
    }
    zval_ptr_dtor(&arr);
    RETURN_LONG(sum);
}

/* — assoc：关联数组写 + 读（字符串键，走哈希而非连续索引） — */

PHP_FUNCTION(bench_assoc)
{
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    zval arr;
    array_init(&arr);
    char key[32];
    for (zend_long i = 0; i < n; i++) {
        snprintf(key, sizeof(key), "k%ld", (long) i);
        add_assoc_long_ex(&arr, key, strlen(key), i);
    }
    zend_long sum = 0;
    for (zend_long i = 0; i < n; i++) {
        snprintf(key, sizeof(key), "k%ld", (long) i);
        zval *v = zend_hash_str_find(Z_ARRVAL(arr), key, strlen(key));
        if (v) sum += Z_LVAL_P(v);
    }
    zval_ptr_dtor(&arr);
    RETURN_LONG(sum);
}

/* — str_len：字符串入参读取 + 长度返回（不分配新串） — */

PHP_FUNCTION(bench_str_len)
{
    zend_string *s;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_STR(s)
    ZEND_PARSE_PARAMETERS_END();
    RETURN_LONG((zend_long) ZSTR_LEN(s));
}

/* — math：算术密集（纯计算，无 Zend 交互），测 Zig/C 代码生成质量 — */

PHP_FUNCTION(bench_math)
{
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    zend_long acc = 0;
    for (zend_long i = 0; i < n; i++) {
        acc += (i * 31 + 7) % 1009;
    }
    RETURN_LONG(acc);
}

/* — call_php：从扩展回调 PHP 函数（strlen）——扩展→PHP 的跨界开销 — */

PHP_FUNCTION(bench_call_php)
{
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    zend_long total = 0;
    for (zend_long i = 0; i < n; i++) {
        zval fname, arg, ret;
        ZVAL_STRING(&fname, "strlen");   /* 被调函数名 */
        ZVAL_STRING(&arg, "hello");      /* 实参 */

        zval params[1];
        ZVAL_COPY(&params[0], &arg);

        if (call_user_function(EG(function_table), NULL, &fname, &ret, 1, params) == SUCCESS) {
            total += zval_get_long(&ret);
            zval_ptr_dtor(&ret);
        }
        zval_ptr_dtor(&params[0]);
        zval_ptr_dtor(&fname);
        zval_ptr_dtor(&arg);
    }
    RETURN_LONG(total);
}

/* — object：stdClass 属性写 + 读 — */

PHP_FUNCTION(bench_object)
{
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    zval obj;
    object_init(&obj);
    char key[32];
    for (zend_long i = 0; i < n; i++) {
        snprintf(key, sizeof(key), "p%ld", (long) i);
        add_property_long_ex(&obj, key, strlen(key), i);
    }
    zend_long sum = 0;
    for (zend_long i = 0; i < n; i++) {
        snprintf(key, sizeof(key), "p%ld", (long) i);
        zval *v = zend_hash_str_find(Z_OBJPROP_P(&obj), key, strlen(key));
        if (v) sum += Z_LVAL_P(v);
    }
    zval_ptr_dtor(&obj);
    RETURN_LONG(sum);
}

/* — throw：抛异常 + 捕获。测错误路径开销而非正常路径 — */

PHP_FUNCTION(bench_throw)
{
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    zend_long caught = 0;
    for (zend_long i = 0; i < n; i++) {
        zend_try {
            zend_throw_exception(NULL, "bench", 0);
            if (EG(exception)) {
                zend_clear_exception();
                caught++;
            }
        } zend_end_try();
    }
    RETURN_LONG(caught);
}

/* — mixed：混合类型数组（真实业务数据的常见形态） —
 *   纯数字数组只需 Z_LVAL_P；混合类型才是常例，需按类型分派读取。 */

PHP_FUNCTION(bench_mixed)
{
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    zval arr;
    array_init(&arr);
    for (zend_long i = 0; i < n; i++) {
        /* 按 i%3 轮换 long / string / double，模拟异构数据 */
        switch (i % 3) {
            case 0: add_next_index_long(&arr, i); break;
            case 1: {
                char key[24];
                int len = snprintf(key, sizeof(key), "v%ld", (long) i);
                add_next_index_stringl(&arr, key, (size_t) len);
                break;
            }
            default: add_next_index_double(&arr, (double) i * 1.5); break;
        }
    }

    zend_long sum = 0;
    for (zend_long i = 0; i < n; i++) {
        zval *v = zend_hash_index_find(Z_ARRVAL(arr), (zend_ulong) i);
        if (!v) { continue; }
        /* zval_get_long 会按类型转换，与真实业务读法一致 */
        sum += zval_get_long(v);
    }
    zval_ptr_dtor(&arr);
    RETURN_LONG(sum);
}

/* — nested：嵌套数组（配置、JSON 类结构的常见形态） — */

PHP_FUNCTION(bench_nested)
{
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    zval arr;
    array_init(&arr);
    for (zend_long i = 0; i < n; i++) {
        zval row;
        array_init(&row);
        add_assoc_long_ex(&row, "id", 2, i * 4);
        add_next_index_zval(&arr, &row);   /* 接管所有权，不再 ptr_dtor */
    }

    zend_long sum = 0;
    for (zend_long i = 0; i < n; i++) {
        zval *row = zend_hash_index_find(Z_ARRVAL(arr), (zend_ulong) i);
        if (!row || Z_TYPE_P(row) != IS_ARRAY) { continue; }
        zval *id = zend_hash_str_find(Z_ARRVAL_P(row), "id", 2);
        if (id) { sum += zval_get_long(id); }
    }
    zval_ptr_dtor(&arr);
    RETURN_LONG(sum);
}

/* — strkey：字符串键的读密集访问（配置查找、字典场景） — */

PHP_FUNCTION(bench_strkey)
{
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    /* 键池固定为 64 个，模拟字典/枚举表的实际规模 */
    zval arr;
    array_init(&arr);
    char key[32];
    for (zend_long i = 0; i < 64; i++) {
        snprintf(key, sizeof(key), "key_%ld", (long) i);
        add_assoc_long_ex(&arr, key, strlen(key), i);
    }

    zend_long sum = 0;
    for (zend_long i = 0; i < n; i++) {
        snprintf(key, sizeof(key), "key_%ld", (long) (i % 64));
        zval *v = zend_hash_str_find(Z_ARRVAL(arr), key, strlen(key));
        if (v) { sum += zval_get_long(v); }
    }
    zval_ptr_dtor(&arr);
    RETURN_LONG(sum);
}

/* — method：类方法调用（无 __call 时失败，只测调用分发链路开销） — */

PHP_FUNCTION(bench_method)
{
    zval *obj;
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(2, 2)
        Z_PARAM_OBJECT(obj)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    zval fname;
    ZVAL_STRING(&fname, "method");

    zend_long total = 0;
    for (zend_long i = 0; i < n; i++) {
        zval ret;
        if (call_user_function(NULL, obj, &fname, &ret, 0, NULL) == SUCCESS) {
            total += zval_get_long(&ret);
            zval_ptr_dtor(&ret);
        }
    }
    zval_ptr_dtor(&fname);
    RETURN_LONG(total);
}

/* — serialize：PHP serialize — */

PHP_FUNCTION(bench_serialize)
{
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    zval arr;
    array_init(&arr);
    for (zend_long i = 0; i < 8; i++) {
        add_next_index_long(&arr, i);
    }

    php_serialize_data_t var_hash;
    smart_str buf = {0};
    zend_long total = 0;
    for (zend_long i = 0; i < n; i++) {
        PHP_VAR_SERIALIZE_INIT(var_hash);
        smart_str_setl(&buf, "", 0);
        php_var_serialize(&buf, &arr, &var_hash);
        PHP_VAR_SERIALIZE_DESTROY(var_hash);
        total += (zend_long) (buf.s ? ZSTR_LEN(buf.s) : 0);
    }
    smart_str_free(&buf);
    zval_ptr_dtor(&arr);
    RETURN_LONG(total);
}

/* — closure：创建闭包并调用 — */

static PHP_FUNCTION(bench_closure_handler)
{
    RETURN_LONG(1);
}

PHP_FUNCTION(bench_closure)
{
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    /* 与 php-zig 侧对齐：真正创建 PHP Closure 对象再调用。
     * 此前只做 fcall_info_init（解析函数名），没有创建闭包，
     * 两侧做的不是同一件事，对比无意义。 */
    zend_string *fname = zend_string_init(ZEND_STRL("bench_closure_handler"), 1);
    zend_function *func = zend_hash_find_ptr(EG(function_table), fname);
    zend_string_release(fname);
    if (!func) { RETURN_LONG(0); }

    zend_long total = 0;
    for (zend_long i = 0; i < n; i++) {
        zval cl, ret;
        zend_create_closure(&cl, func, NULL, NULL, NULL);
        if (call_user_function(NULL, NULL, &cl, &ret, 0, NULL) == SUCCESS) {
            total += zval_get_long(&ret);
            zval_ptr_dtor(&ret);
        }
        zval_ptr_dtor(&cl);
    }
    RETURN_LONG(total);
}

/* — fiber：创建 + 切换 — */

PHP_FUNCTION(bench_fiber)
{
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    /* zend_fiber_create 非公开 API，故与 php-zig 侧一致：都通过 PHP 函数
     * Fiber::__construct 创建，走同一条 Zend 路径才可比。 */
    zend_long total = 0;
    for (zend_long i = 0; i < n; i++) {
        zval fname, callable, obj, ret;
        ZVAL_STRING(&fname, "bench_make_fiber");
        ZVAL_STRING(&callable, "bench_fiber_body");

        zval params[1];
        ZVAL_COPY(&params[0], &callable);

        if (call_user_function(EG(function_table), NULL, &fname, &ret, 1, params) == SUCCESS) {
            zval_ptr_dtor(&ret);
            total++;
        }
        (void) obj;
        zval_ptr_dtor(&params[0]);
        zval_ptr_dtor(&callable);
        zval_ptr_dtor(&fname);
    }
    RETURN_LONG(total);
}

/* — arena：等价 php-zig RequestArena —— 用 PHP 请求池 emalloc/efree — */

PHP_FUNCTION(bench_arena)
{
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();

    /* 与 php-zig 的 RequestArena 对等：RequestArena 的 backing 是
     * c_allocator（真 malloc），不进 PHP 内存池——这是有意的设计（避免大块
     * 临时内存计入 memory_limit）。故此处必须用 malloc 实现同样的
     * 「连续分配、末尾一次性释放」arena，用 emalloc 会变成在比 allocator
     * 而不是比框架。 */
    void **ptrs = (void **) malloc((size_t) n * sizeof(void *));
    if (!ptrs) { RETURN_LONG(0); }

    zend_long total = 0;
    for (zend_long i = 0; i < n; i++) {
        ptrs[i] = malloc(64);
        if (!ptrs[i]) { break; }
        ((char *) ptrs[i])[0] = 1;
        total += 64;
    }
    for (zend_long i = 0; i < n; i++) {
        if (ptrs[i]) { free(ptrs[i]); }
    }
    free(ptrs);
    RETURN_LONG(total);
}

/* ================================================================
 * arg_info + 模块注册
 * ================================================================ */

ZEND_BEGIN_ARG_INFO_EX(arginfo_bench_empty, 0, 0, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_INFO_EX(arginfo_bench_add, 0, 0, 2)
    ZEND_ARG_INFO(0, a)
    ZEND_ARG_INFO(0, b)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_INFO_EX(arginfo_bench_concat, 0, 0, 2)
    ZEND_ARG_INFO(0, s1)
    ZEND_ARG_INFO(0, s2)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_INFO_EX(arginfo_one_long, 0, 0, 1)
    ZEND_ARG_INFO(0, n)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_INFO_EX(arginfo_bench_method, 0, 0, 2)
    ZEND_ARG_INFO(0, obj)
    ZEND_ARG_INFO(0, n)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_INFO_EX(arginfo_bench_str_len, 0, 0, 1)
    ZEND_ARG_INFO(0, s)
ZEND_END_ARG_INFO()

static const zend_function_entry bench_functions[] = {
    PHP_FE(bench_empty, arginfo_bench_empty)
    PHP_FE(bench_add, arginfo_bench_add)
    PHP_FE(bench_concat, arginfo_bench_concat)
    PHP_FE(bench_array_build, arginfo_one_long)
    PHP_FE(bench_array_read, arginfo_one_long)
    PHP_FE(bench_assoc, arginfo_one_long)
    PHP_FE(bench_str_len, arginfo_bench_str_len)
    PHP_FE(bench_math, arginfo_one_long)
    PHP_FE(bench_call_php, arginfo_one_long)
    PHP_FE(bench_object, arginfo_one_long)
    PHP_FE(bench_throw, arginfo_one_long)
    PHP_FE(bench_mixed, arginfo_one_long)
    PHP_FE(bench_nested, arginfo_one_long)
    PHP_FE(bench_strkey, arginfo_one_long)
    PHP_FE(bench_method, arginfo_bench_method)
    PHP_FE(bench_serialize, arginfo_one_long)
    PHP_FE(bench_closure, arginfo_one_long)
    PHP_FE(bench_fiber, arginfo_one_long)
    PHP_FE(bench_arena, arginfo_one_long)
    /* 闭包用例的被调函数：必须注册进函数表，否则 zend_hash_find_ptr 找不到
     * 它，zend_create_closure 拿到 NULL 会直接返回——测出来的是空转开销。 */
    PHP_FE(bench_closure_handler, arginfo_bench_empty)
    PHP_FE_END
};

/* 名字必须与 ZEND_GET_MODULE(bench_c) 一致：该宏展开为 bench_c_module_entry */
zend_module_entry bench_c_module_entry = {
    STANDARD_MODULE_HEADER,
    "bench_c",
    bench_functions,
    NULL, NULL, NULL, NULL, NULL,
    "1.0.0",
    STANDARD_MODULE_PROPERTIES
};

ZEND_GET_MODULE(bench_c)
