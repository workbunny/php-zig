/*
 * php_glue.c — C 胶水层实现
 *
 * 将 Zend Engine 的语句级宏封装为普通 C 函数，
 * 供 Zig extern fn 直接调用。
 */

#include "php_glue.h"
#include <string.h>
#include <strings.h>

/* ================================================================
 * 模块版本信息
 * ================================================================ */

unsigned int phpglue_module_api_no(void) { return ZEND_MODULE_API_NO; }
const char *phpglue_module_build_id(void) { return ZEND_MODULE_BUILD_ID; }

/* ================================================================
 * 编译期常量查询 — 由编译时 PHP 头文件决定
 * ================================================================ */

size_t   phpglue_arginfo_entry_size(void) { return sizeof(zend_internal_arg_info); }
uint32_t phpglue_acc_public(void)         { return ZEND_ACC_PUBLIC; }
uint32_t phpglue_acc_protected(void)      { return ZEND_ACC_PROTECTED; }
uint32_t phpglue_acc_private(void)        { return ZEND_ACC_PRIVATE; }
uint32_t phpglue_acc_static(void)         { return ZEND_ACC_STATIC; }
uint32_t phpglue_acc_abstract(void)       { return ZEND_ACC_ABSTRACT; }
uint32_t phpglue_acc_final(void)          { return ZEND_ACC_FINAL; }
size_t  phpglue_zval_size(void)           { return sizeof(zval); }
uint8_t phpglue_zts_mode(void)            { return USING_ZTS; }

/* ================================================================
 * zval 类型查询与取值
 * ================================================================ */

uint8_t     phpglue_zval_type(zval *zv)              { return Z_TYPE_P(zv); }
zend_long   phpglue_zval_get_long(zval *zv)          { return Z_LVAL_P(zv); }
double      phpglue_zval_get_double(zval *zv)        { return Z_DVAL_P(zv); }
const char *phpglue_zval_get_string_val(zval *zv)    { return Z_STRVAL_P(zv); }
size_t      phpglue_zval_get_string_len(zval *zv)    { return Z_STRLEN_P(zv); }
zend_array *phpglue_zval_get_array(zval *zv)         { return Z_ARRVAL_P(zv); }

/* ================================================================
 * zval 构造
 * ================================================================ */

void phpglue_zval_set_null(zval *zv)                         { ZVAL_NULL(zv); }
void phpglue_zval_set_long(zval *zv, zend_long v)            { ZVAL_LONG(zv, v); }
void phpglue_zval_set_double(zval *zv, double v)             { ZVAL_DOUBLE(zv, v); }
void phpglue_zval_set_string(zval *zv, const char *s)        { ZVAL_STRING(zv, s); }
void phpglue_zval_set_stringl(zval *zv, const char *s, size_t l) { ZVAL_STRINGL(zv, s, l); }
void phpglue_zval_set_bool(zval *zv, bool v)                 { ZVAL_BOOL(zv, v); }
void phpglue_zval_set_true(zval *zv)                         { ZVAL_TRUE(zv); }
void phpglue_zval_set_false(zval *zv)                        { ZVAL_FALSE(zv); }

/* ================================================================
 * zval 引用计数
 * ================================================================ */

void phpglue_zval_add_ref(zval *zv)  { Z_ADDREF_P(zv); }
void phpglue_zval_ptr_dtor(zval *zv) { zval_ptr_dtor(zv); }

void phpglue_zval_del_ref(zval *zv)  { Z_DELREF_P(zv); }
void phpglue_zval_copy(zval *dst, zval *src) { ZVAL_COPY(dst, src); }

/* ================================================================
 * 数组操作 — 初始化与写时分离
 * ================================================================ */

void phpglue_array_init(zval *zv)     { array_init(zv); }
void phpglue_array_separate(zval *zv) { SEPARATE_ARRAY(zv); }

/* — 追加元素（自动索引） — */

void phpglue_add_next_index_long(zval *zv, zend_long v)                  { add_next_index_long(zv, v); }
void phpglue_add_next_index_double(zval *zv, double v)                   { add_next_index_double(zv, v); }
void phpglue_add_next_index_stringl(zval *zv, const char *s, size_t l)   { add_next_index_stringl(zv, s, l); }
void phpglue_add_next_index_bool(zval *zv, bool v)                       { add_next_index_bool(zv, v); }
void phpglue_add_next_index_null(zval *zv)                               { add_next_index_null(zv); }
void phpglue_add_next_index_zval(zval *zv, zval *val)                    { add_next_index_zval(zv, val); }

/* — 按数字索引设值 — */

void phpglue_add_index_long(zval *zv, zend_ulong idx, zend_long v)                 { add_index_long(zv, idx, v); }
void phpglue_add_index_double(zval *zv, zend_ulong idx, double v)                  { add_index_double(zv, idx, v); }
void phpglue_add_index_stringl(zval *zv, zend_ulong idx, const char *s, size_t l)  { add_index_stringl(zv, idx, s, l); }
void phpglue_add_index_bool(zval *zv, zend_ulong idx, bool v)                      { add_index_bool(zv, idx, v); }
void phpglue_add_index_null(zval *zv, zend_ulong idx)                              { add_index_null(zv, idx); }
void phpglue_add_index_zval(zval *zv, zend_ulong idx, zval *val)                   { add_index_zval(zv, idx, val); }

/* — 按字符串键设值（关联数组） — */

void phpglue_add_assoc_long(zval *zv, const char *key, zend_long v)                     { add_assoc_long(zv, key, v); }
void phpglue_add_assoc_double(zval *zv, const char *key, double v)                       { add_assoc_double(zv, key, v); }
void phpglue_add_assoc_stringl(zval *zv, const char *key, const char *s, size_t l)       { add_assoc_stringl(zv, key, s, l); }
void phpglue_add_assoc_bool(zval *zv, const char *key, bool v)                           { add_assoc_bool(zv, key, v); }
void phpglue_add_assoc_null(zval *zv, const char *key)                                   { add_assoc_null(zv, key); }
void phpglue_add_assoc_zval(zval *zv, const char *key, zval *val)                        { add_assoc_zval(zv, key, val); }

/* ================================================================
 * HashTable 操作
 * ================================================================ */

uint32_t phpglue_hash_num_elements(zend_array *ht) { return zend_hash_num_elements(ht); }
void *phpglue_hash_str_find(zend_array *ht, const char *key, size_t len) { return zend_hash_str_find(ht, key, len); }
void *phpglue_hash_index_find(zend_array *ht, zend_ulong idx) { return zend_hash_index_find(ht, idx); }
int phpglue_hash_str_exists(zend_array *ht, const char *key, size_t len) { return zend_hash_str_exists(ht, key, len) ? 1 : 0; }
int phpglue_hash_index_exists(zend_array *ht, zend_ulong idx) { return zend_hash_index_exists(ht, idx) ? 1 : 0; }
int phpglue_hash_str_del(zend_array *ht, const char *key, size_t len) { return zend_hash_str_del(ht, key, len); }
int phpglue_hash_index_del(zend_array *ht, zend_ulong idx) { return zend_hash_index_del(ht, idx); }

/* — 遍历 — */

void phpglue_hash_internal_pointer_reset(zend_array *ht) { zend_hash_internal_pointer_reset(ht); }
int  phpglue_hash_move_forward(zend_array *ht)           { return zend_hash_move_forward(ht); }
zval *phpglue_hash_get_current_data(zend_array *ht)      {
    if (zend_hash_num_elements(ht) == 0) return NULL;
    return zend_hash_get_current_data(ht);
}
int phpglue_hash_get_current_key_ex(zend_array *ht, zend_string **str_index, zend_ulong *num_index) {
    return zend_hash_get_current_key(ht, str_index, num_index);
}

/* — 弹出末尾元素 — */
int phpglue_array_pop(zval *zv, zval *retval) {
    HashTable *ht = Z_ARRVAL_P(zv);
    zval *data = zend_hash_index_find(ht, zend_hash_num_elements(ht) - 1);
    if (data == NULL) return 0;
    ZVAL_COPY(retval, data);
    zend_hash_index_del(ht, zend_hash_num_elements(ht) - 1);
    return 1;
}

/* — 数组高级操作 — */

int phpglue_array_shift(zval *zv, zval *retval) {
    HashTable *ht = Z_ARRVAL_P(zv);
    if (zend_hash_num_elements(ht) == 0) return 0;
    zend_hash_internal_pointer_reset(ht);
    zval *data = zend_hash_get_current_data(ht);
    if (data == NULL) return 0;

    zend_string *str_key = NULL;
    zend_ulong num_key = 0;
    int key_type = zend_hash_get_current_key(ht, &str_key, &num_key);

    ZVAL_COPY(retval, data);

    if (key_type == HASH_KEY_IS_STRING) {
        zend_hash_del(ht, str_key);
    } else {
        zend_hash_index_del(ht, num_key);
    }
    return 1;
}

void phpglue_array_unshift(zval *zv, zval *val) {
    HashTable *ht = Z_ARRVAL_P(zv);
    zval new_arr;
    array_init(&new_arr);

    /* 新元素放最前 */
    add_next_index_zval(&new_arr, val);

    /* 遍历旧数组按顺序追加（数字键重索引，等价 PHP array_unshift） */
    zval *data;
    ZEND_HASH_FOREACH_VAL(ht, data) {
        add_next_index_zval(&new_arr, data);
    } ZEND_HASH_FOREACH_END();

    /* 替换原数组 */
    zval_ptr_dtor(zv);
    ZVAL_COPY_VALUE(zv, &new_arr);
}

void phpglue_array_merge(zval *dst, zval *src1, zval *src2) {
    /* 手动遍历合并，模拟 PHP array_merge 语义：
     *   数字键 → 追加（重新索引）；字符串键 → 覆盖/新增 */
    array_init_size(dst, zend_hash_num_elements(Z_ARRVAL_P(src1)) + zend_hash_num_elements(Z_ARRVAL_P(src2)));

    zend_string *str_key;
    zend_ulong num_key;
    zval *data;

    ZEND_HASH_FOREACH_KEY_VAL(Z_ARRVAL_P(src1), num_key, str_key, data) {
        if (str_key) {
            add_assoc_zval(dst, ZSTR_VAL(str_key), data);
        } else {
            add_next_index_zval(dst, data);
        }
    } ZEND_HASH_FOREACH_END();

    ZEND_HASH_FOREACH_KEY_VAL(Z_ARRVAL_P(src2), num_key, str_key, data) {
        if (str_key) {
            add_assoc_zval(dst, ZSTR_VAL(str_key), data);
        } else {
            add_next_index_zval(dst, data);
        }
    } ZEND_HASH_FOREACH_END();
}

void phpglue_array_keys(zval *src, zval *dst) {
    array_init(dst);
    HashTable *ht = Z_ARRVAL_P(src);
    zend_string *str_key;
    zend_ulong num_key;
    ZEND_HASH_FOREACH_KEY(ht, num_key, str_key) {
        if (str_key) {
            add_next_index_str(dst, zend_string_copy(str_key));
        } else {
            add_next_index_long(dst, (zend_long)num_key);
        }
    } ZEND_HASH_FOREACH_END();
}

void phpglue_array_values(zval *src, zval *dst) {
    array_init(dst);
    HashTable *ht = Z_ARRVAL_P(src);
    zval *data;
    ZEND_HASH_FOREACH_VAL(ht, data) {
        add_next_index_zval(dst, data);
    } ZEND_HASH_FOREACH_END();
}

void phpglue_array_slice(zval *src, zval *dst, zend_long offset, zend_long len) {
    array_init(dst);
    HashTable *ht = Z_ARRVAL_P(src);
    zend_long count = 0;
    zval *data;
    ZEND_HASH_FOREACH_VAL(ht, data) {
        if (count >= offset && (len < 0 || count < offset + len)) {
            add_next_index_zval(dst, data);
        }
        count++;
    } ZEND_HASH_FOREACH_END();
}

static int phpglue_bucket_compare(Bucket *a, Bucket *b) {
    zval result;
    compare_function(&result, &a->val, &b->val);
    return (int)Z_LVAL(result);
}

void phpglue_array_sort(zval *zv) {
    zend_hash_sort(Z_ARRVAL_P(zv), phpglue_bucket_compare, 1);
}

/* ================================================================
 * 对象操作
 *
 * 注意：zend_read_property 可能返回栈上 rv，此时返回 NULL
 * 表示调用者需要自行处理（如通过读取后立即复制到本地 zval）。
 * ================================================================ */

zval *phpglue_object_read_property(zval *obj, const char *name, size_t name_len) {
    zend_object *zobj = Z_OBJ_P(obj);
    if (zobj == NULL || zobj->properties == NULL) return NULL;
    zend_string *key = zend_string_init(name, name_len, 0);
    zval *result = zend_hash_find(zobj->properties, key);
    zend_string_release(key);
    return result;
}

void phpglue_object_write_property(zval *obj, const char *name, size_t name_len, zval *val) {
    zend_update_property(Z_OBJCE_P(obj), Z_OBJ_P(obj), name, name_len, val);
}

void phpglue_object_create_stdclass(zval *zv) {
    object_init(zv);
}

/* ================================================================
 * 资源类型
 *
 * 无自定义析构器：资源生命周期由 phpglue_zval_ptr_dtor 统一管理。
 * zend_register_list_destructors_ex 传入 NULL/NULL 表示析构由调用者负责。
 * ================================================================ */

int phpglue_register_resource_type(void) {
    return zend_register_list_destructors_ex(NULL, NULL, "php-zig-resource", 0);
}

void phpglue_store_resource(zval *zv, void *ptr, int type_id) {
    ZVAL_RES(zv, zend_register_resource(ptr, type_id));
}

void *phpglue_fetch_resource(zval *zv, int type_id) {
    return zend_fetch_resource(Z_RES_P(zv), "php-zig-resource", type_id);
}

/* ================================================================
 * 返回值
 * ================================================================ */

void phpglue_return_string(zval *return_value, const char *s)               { RETVAL_STRING(s); }
void phpglue_return_stringl(zval *return_value, const char *s, size_t l)    { RETVAL_STRINGL(s, l); }
void phpglue_return_long(zval *return_value, zend_long v)                   { RETVAL_LONG(v); }
void phpglue_return_double(zval *return_value, double v)                    { RETVAL_DOUBLE(v); }
void phpglue_return_bool(zval *return_value, bool v)                        { RETVAL_BOOL(v); }
void phpglue_return_null(zval *return_value)                                { RETVAL_NULL(); }
void phpglue_return_true(zval *return_value)                                { RETVAL_TRUE; }
void phpglue_return_false(zval *return_value)                               { RETVAL_FALSE; }
void phpglue_return_zval(zval *return_value, zval *zv)                      { RETVAL_ZVAL(zv, 1, 0); }

/* ================================================================
 * 调用信息
 * ================================================================ */

uint32_t phpglue_call_num_args(zend_execute_data *execute_data) { return ZEND_CALL_NUM_ARGS(execute_data); }
zval *phpglue_call_arg(zend_execute_data *execute_data, uint32_t n) { return ZEND_CALL_ARG(execute_data, n); }

/* ================================================================
 * arg_info
 * ================================================================ */

ZEND_BEGIN_ARG_INFO_EX(phpglue_arginfo_empty, 0, 0, 0)
ZEND_END_ARG_INFO()

const void *phpglue_get_empty_arg_info(void) { return phpglue_arginfo_empty; }

/* 由 PHP 宏生成的静态模板 — 布局由编译器保证 */
ZEND_BEGIN_ARG_INFO_EX(__phpglue_arg_header_template, 0, 0, 0)
ZEND_END_ARG_INFO()

static const zend_internal_arg_info __phpglue_arg_param_template[] = {
    ZEND_ARG_INFO(0, _placeholder)
};

void phpglue_fill_arg_info(void *dst, uint32_t required_count, const char **names, size_t name_count, size_t *out_entry_count) {
    zend_internal_arg_info *entries = (zend_internal_arg_info *)dst;

    memcpy(&entries[0], &__phpglue_arg_header_template[0], sizeof(zend_internal_arg_info));
    entries[0].name = (const char *)(uintptr_t)(required_count);

    for (size_t i = 0; i < name_count; i++) {
        memcpy(&entries[i + 1], &__phpglue_arg_param_template[0], sizeof(zend_internal_arg_info));
        entries[i + 1].name = names[i];
    }

    // 末尾哨兵 — Zend Engine 在 zend_API.c:3015 读 arg_info[num_args] 判断 is_variadic
    memcpy(&entries[name_count + 1], &__phpglue_arg_param_template[0], sizeof(zend_internal_arg_info));
    entries[name_count + 1].name = NULL;

    // num_args = 参数个数（不含 header）。
    // zend_API.c:3004 中 internal_function->arg_info 跳过 header，
    // Reflection 据此迭代 num_args 个参数。
    *out_entry_count = name_count;
}

/* — 类型化版本：逐参数设置 PHP 类型标注 — */

static void fill_typed_param_entry(zend_internal_arg_info *entry, const char *name,
    uint8_t php_type, uint8_t allow_null_flag, uint8_t variadic_flag, const char *default_value)
{
    /* 从无类型模板起步（正确的 zend_type 初始化状态） */
    memcpy(entry, &__phpglue_arg_param_template[0], sizeof(zend_internal_arg_info));
    entry->name = name;

    /* ZEND_TYPE_INIT_CODE 在各 PHP 8.x 版本中处理了 allow_null 的位编码差异。
     * extra_flags 通过 _ZEND_ARG_INFO_FLAGS 携带 is_variadic 位 */
    const uint32_t extra_flags = (uint32_t)_ZEND_ARG_INFO_FLAGS(0, variadic_flag, 0);
    switch (php_type) {
        case 0: /* mixed — 保留模板默认（无类型提示），可变参数仍需写入 variadic 位 */
            if (variadic_flag) {
                entry->type = (zend_type)ZEND_TYPE_INIT_NONE(extra_flags);
            }
            break;
        case 1: entry->type = (zend_type)ZEND_TYPE_INIT_CODE(IS_LONG,   allow_null_flag, extra_flags); break;
        case 2: entry->type = (zend_type)ZEND_TYPE_INIT_CODE(IS_DOUBLE, allow_null_flag, extra_flags); break;
        case 3: entry->type = (zend_type)ZEND_TYPE_INIT_CODE(IS_STRING, allow_null_flag, extra_flags); break;
        case 4: entry->type = (zend_type)ZEND_TYPE_INIT_CODE(_IS_BOOL,  allow_null_flag, extra_flags); break;
        case 5: entry->type = (zend_type)ZEND_TYPE_INIT_CODE(IS_ARRAY,  allow_null_flag, extra_flags); break;
        case 6: entry->type = (zend_type)ZEND_TYPE_INIT_CODE(IS_OBJECT, allow_null_flag, extra_flags); break;
        default: break;
    }

    if (default_value != NULL) {
        entry->default_value = default_value;
    }
}

void phpglue_fill_arg_info_typed(void *dst, uint32_t required_count,
    const char **names, const uint8_t *types, const uint8_t *allow_null,
    size_t name_count, size_t *out_entry_count)
{
    zend_internal_arg_info *entries = (zend_internal_arg_info *)dst;

    /* Header — 同无类型版本 */
    memcpy(&entries[0], &__phpglue_arg_header_template[0], sizeof(zend_internal_arg_info));
    entries[0].name = (const char *)(uintptr_t)(required_count);

    /* 按类型逐参数填充 */
    for (size_t i = 0; i < name_count; i++) {
        fill_typed_param_entry(&entries[i + 1], names[i],
            types ? types[i] : 0,
            allow_null ? allow_null[i] : 0,
            0, NULL);
    }

    /* 末尾哨兵 */
    memcpy(&entries[name_count + 1], &__phpglue_arg_param_template[0], sizeof(zend_internal_arg_info));
    entries[name_count + 1].name = NULL;

    *out_entry_count = name_count;
}

void phpglue_fill_arg_info_full(void *dst, uint32_t required_count,
    const char **names, const uint8_t *types, const uint8_t *allow_null,
    const uint8_t *variadic, const char **default_values,
    size_t name_count, size_t *out_entry_count)
{
    zend_internal_arg_info *entries = (zend_internal_arg_info *)dst;

    /* Header — 同 typed 版本 */
    memcpy(&entries[0], &__phpglue_arg_header_template[0], sizeof(zend_internal_arg_info));
    entries[0].name = (const char *)(uintptr_t)(required_count);

    /* 逐参数填充：类型 + allow_null + variadic + default_value */
    for (size_t i = 0; i < name_count; i++) {
        fill_typed_param_entry(&entries[i + 1], names[i],
            types ? types[i] : 0,
            allow_null ? allow_null[i] : 0,
            variadic ? variadic[i] : 0,
            default_values ? default_values[i] : NULL);
    }

    /* 末尾哨兵 */
    memcpy(&entries[name_count + 1], &__phpglue_arg_param_template[0], sizeof(zend_internal_arg_info));
    entries[name_count + 1].name = NULL;

    *out_entry_count = name_count;
}

/* ================================================================
 * 异常
 * ================================================================ */

void phpglue_throw_exception(const char *message, size_t message_len) {
    /* zend_throw_exception 内部按 strlen 取长度，故先复制为 NUL 结尾的 zend_string，
     * 以支持非 NUL 结尾的 message（message_len 精确控制）。 */
    zend_string *msg = zend_string_init(message, message_len, 0);
    zend_throw_exception(zend_ce_exception, ZSTR_VAL(msg), 0);
    zend_string_release(msg);
}

int phpglue_throw_exception_class(const char *class_name, size_t class_len,
    const char *message, size_t message_len, zend_long code)
{
    zend_class_entry *ce = phpglue_lookup_class(class_name, class_len);
    if (ce == NULL) return 0;
    zend_string *msg = zend_string_init(message, message_len, 0);
    zend_throw_exception(ce, ZSTR_VAL(msg), code);
    zend_string_release(msg);
    return 1;
}

/* ================================================================
 * 模块常量注册
 * ================================================================ */

void phpglue_register_constant_long(const char *name, size_t n, zend_long val, int mn)   { zend_register_long_constant(name, n, val, CONST_CS | CONST_PERSISTENT, mn); }
void phpglue_register_constant_double(const char *name, size_t n, double val, int mn)     { zend_register_double_constant(name, n, val, CONST_CS | CONST_PERSISTENT, mn); }
void phpglue_register_constant_string(const char *name, size_t n, const char *v, size_t vl, int mn) { zend_register_stringl_constant(name, n, v, vl, CONST_CS | CONST_PERSISTENT, mn); }
void phpglue_register_constant_bool(const char *name, size_t n, bool val, int mn)         { zend_register_bool_constant(name, n, val, CONST_CS | CONST_PERSISTENT, mn); }
void phpglue_register_constant_null(const char *name, size_t n, int mn)                   { zend_register_null_constant(name, n, CONST_CS | CONST_PERSISTENT, mn); }

/* ================================================================
 * 类注册
 * ================================================================ */

int phpglue_register_class(const char *name, size_t n, const zend_function_entry *methods) {
    zend_class_entry ce;
    INIT_CLASS_ENTRY_EX(ce, name, n, methods);
    return zend_register_internal_class(&ce) != NULL ? 1 : 0;
}
int phpglue_register_class_ex(const char *name, size_t n, const zend_function_entry *methods, zend_class_entry *parent) {
    zend_class_entry ce;
    INIT_CLASS_ENTRY_EX(ce, name, n, methods);
    return zend_register_internal_class_ex(&ce, parent) != NULL ? 1 : 0;
}
zend_class_entry *phpglue_lookup_class(const char *name, size_t n) {
    /* CG(class_table) 键是小写，手动 tolower 后查找 */
    char buf[128];
    size_t len = n < sizeof(buf) ? n : sizeof(buf) - 1;
    for (size_t i = 0; i < len; i++) buf[i] = (char)((unsigned char)name[i] >= 'A' && (unsigned char)name[i] <= 'Z' ? name[i] + 32 : name[i]);
    return zend_hash_str_find_ptr(CG(class_table), buf, len);
}

/* — 接口注册与实现 — */

int phpglue_register_interface(const char *name, size_t n, const zend_function_entry *methods) {
    zend_class_entry ce;
    INIT_CLASS_ENTRY_EX(ce, name, n, methods);
    return zend_register_internal_interface(&ce) != NULL ? 1 : 0;
}

int phpglue_class_implements_one(const char *name, size_t n, const char *iface_name, size_t iface_n) {
    zend_class_entry *ce = phpglue_lookup_class(name, n);
    if (ce == NULL) return 0;
    zend_class_entry *iface = phpglue_lookup_class(iface_name, iface_n);
    if (iface == NULL) return 0;
    zend_class_implements(ce, 1, iface);
    return 1;
}

/* — 完整注册：方法 + 常量 + 属性 — */

static void declare_one_property(zend_class_entry *ce_ptr,
    const char *name, size_t name_len, const void *val, size_t val_len,
    uint32_t access, uint8_t prop_type)
{
    // 委托 Zend 高层 API 处理类型生命周期，避免手动管理 zval/zend_string refcount
    switch (prop_type) {
        case 0: /* long   */
            zend_declare_property_long(ce_ptr, name, name_len, *(const zend_long *)val, access);
            break;
        case 1: /* double */
            zend_declare_property_double(ce_ptr, name, name_len, *(const double *)val, access);
            break;
        case 2: /* string */
            zend_declare_property_stringl(ce_ptr, name, name_len, (const char *)val, val_len, access);
            break;
        case 3: /* bool   */
            zend_declare_property_bool(ce_ptr, name, name_len, *(const uint8_t *)val, access);
            break;
        case 4: /* null   */
        default:
            zend_declare_property_null(ce_ptr, name, name_len, access);
            break;
    }
}

int phpglue_register_class_full(const char *name, size_t name_len, const zend_function_entry *methods,
    int const_count, const char **const_keys, size_t *const_key_lens,
    const void **const_vals, size_t *const_val_lens, uint8_t *const_types,
    int prop_count, const char **prop_keys, size_t *prop_key_lens,
    const void **prop_vals, size_t *prop_val_lens, uint32_t *prop_accesses, uint8_t *prop_types)
{
    zend_class_entry ce;
    INIT_CLASS_ENTRY_EX(ce, name, name_len, methods);
    zend_class_entry *ce_ptr = zend_register_internal_class(&ce);
    if (ce_ptr == NULL) return 0;

    /* 类常量 */
    for (int i = 0; i < const_count; i++) {
        zval zv;
        if (const_types[i] == 0) {
            ZVAL_LONG(&zv, *(const zend_long *)const_vals[i]);
        } else {
            ZVAL_STRINGL(&zv, (const char *)const_vals[i], const_val_lens[i]);
        }
        zend_declare_class_constant(ce_ptr, const_keys[i], const_key_lens[i], &zv);
        zval_ptr_dtor(&zv);
    }

    /* 类属性 */
    for (int i = 0; i < prop_count; i++) {
        declare_one_property(ce_ptr, prop_keys[i], prop_key_lens[i],
            prop_vals[i], prop_val_lens[i], prop_accesses[i], prop_types[i]);
    }

    return 1;
}

/* ================================================================
 * PHP 函数调用（Facade）
 * ================================================================ */

int phpglue_call_func(const char *name, size_t n, zval *retval, uint32_t argc, const zval *argv) {
    zval fname;
    ZVAL_STRINGL(&fname, name, n);
    if (call_user_function(NULL, NULL, &fname, retval, argc, (zval *)argv) == SUCCESS) { zval_ptr_dtor(&fname); return 1; }
    zval_ptr_dtor(&fname); return 0;
}
int phpglue_call_method(zval *obj, const char *name, size_t n, zval *retval, uint32_t argc, const zval *argv) {
    zval mname;
    ZVAL_STRINGL(&mname, name, n);
    if (call_user_function(NULL, obj, &mname, retval, argc, (zval *)argv) == SUCCESS) { zval_ptr_dtor(&mname); return 1; }
    zval_ptr_dtor(&mname); return 0;
}
int phpglue_call_zval(zval *callable, zval *retval, uint32_t argc, const zval *argv) {
    return call_user_function(NULL, NULL, callable, retval, argc, (zval *)argv) == SUCCESS ? 1 : 0;
}

/* ================================================================
 * 逻辑判断
 * ================================================================ */

int phpglue_zval_is_true(zval *zv) { return zend_is_true(zv) ? 1 : 0; }

/* ================================================================
 * zval 算术运算符
 * ================================================================ */

int phpglue_zval_add(zval *result, zval *op1, zval *op2) { return add_function(result, op1, op2) == SUCCESS ? 1 : 0; }
int phpglue_zval_sub(zval *result, zval *op1, zval *op2) { return sub_function(result, op1, op2) == SUCCESS ? 1 : 0; }
int phpglue_zval_mul(zval *result, zval *op1, zval *op2) { return mul_function(result, op1, op2) == SUCCESS ? 1 : 0; }
int phpglue_zval_div(zval *result, zval *op1, zval *op2) { return div_function(result, op1, op2) == SUCCESS ? 1 : 0; }
int phpglue_zval_mod(zval *result, zval *op1, zval *op2) { return mod_function(result, op1, op2) == SUCCESS ? 1 : 0; }

int phpglue_zval_compare(zval *op1, zval *op2) {
    zval result;
    compare_function(&result, op1, op2);
    return (int)Z_LVAL(result);
}

/* ================================================================
 * zval 语义类型判断
 * ================================================================ */

int phpglue_zval_is_callable(zval *zv) { return zend_is_callable(zv, 0, NULL) ? 1 : 0; }
int phpglue_zval_is_iterable(zval *zv) { return zend_is_iterable(zv) ? 1 : 0; }
int phpglue_zval_is_scalar(zval *zv) {
    uint8_t t = Z_TYPE_P(zv);
    return (t == IS_LONG || t == IS_DOUBLE || t == IS_STRING || t == IS_TRUE || t == IS_FALSE) ? 1 : 0;
}
int phpglue_zval_is_empty(zval *zv) { return zend_is_true(zv) ? 0 : 1; }
int phpglue_zval_is_numeric(zval *zv) {
    uint8_t t = Z_TYPE_P(zv);
    if (t == IS_LONG || t == IS_DOUBLE) return 1;
    if (t == IS_STRING) {
        zend_long lval;
        double dval;
        return is_numeric_str_function(Z_STR_P(zv), &lval, &dval) != 0;
    }
    return 0;
}

/* ================================================================
 * 对象 instanceof
 * ================================================================ */

int phpglue_object_instanceof(zval *obj, const char *name, size_t name_len) {
    if (Z_TYPE_P(obj) != IS_OBJECT) return 0;
    zend_class_entry *ce = phpglue_lookup_class(name, name_len);
    if (ce == NULL) return 0;
    return instanceof_function(Z_OBJCE_P(obj), ce) ? 1 : 0;
}

/* ================================================================
 * 闭包创建
 * ================================================================ */

void phpglue_create_closure(zval *res, zif_handler handler, const char *name, size_t name_len) {
    zend_internal_function func;
    memset(&func, 0, sizeof(func));
    func.type = ZEND_INTERNAL_FUNCTION;
    func.function_name = zend_string_init(name, name_len, 0);
    func.fn_flags = 0;
    func.handler = handler;
    func.num_args = 0;
    func.required_num_args = 0;
    func.arg_info = NULL;
    /* zend_create_closure 会对 function_name zend_string_addref，
     * 闭包析构时 zend_string_release，故此处释放我们持有的这一份 */
    zend_create_closure(res, (zend_function *)&func, NULL, NULL, NULL);
    zend_string_release(func.function_name);
}

/* ================================================================
 * 错误报告
 * ================================================================ */

void phpglue_error_docref(const char *docref, int type, const char *msg) {
    php_error_docref(docref, type, "%s", msg);
}

/* ================================================================
 * 序列化 — PHP serialize/unserialize
 * ================================================================ */

void phpglue_var_serialize(zval *zv, zval *return_value) {
    smart_str buf = {0};
    php_serialize_data_t var_hash;
    PHP_VAR_SERIALIZE_INIT(var_hash);
    php_var_serialize(&buf, zv, &var_hash);
    PHP_VAR_SERIALIZE_DESTROY(var_hash);
    smart_str_0(&buf);
    if (buf.s != NULL) {
        RETVAL_STRINGL(ZSTR_VAL(buf.s), ZSTR_LEN(buf.s));
    } else {
        RETVAL_EMPTY_STRING();
    }
    smart_str_free(&buf);
}

int phpglue_var_unserialize(const char *s, size_t len, zval *return_value) {
    const unsigned char *p = (const unsigned char *)s;
    const unsigned char *max = p + len;
    php_unserialize_data_t var_hash;
    PHP_VAR_UNSERIALIZE_INIT(var_hash);
    if (php_var_unserialize(return_value, &p, max, &var_hash)) {
        PHP_VAR_UNSERIALIZE_DESTROY(var_hash);
        return 1;
    }
    PHP_VAR_UNSERIALIZE_DESTROY(var_hash);
    return 0;
}

/* ================================================================
 * INI 配置
 *
 * 采用「无 globals」方案：INI 值由 Zend 的 ini_entry->value 存储，
 * on_modify 仅负责触发变更通知（mh_arg 不使用，因为无需更新 globals）。
 * 读取通过 zend_ini_string_ex 直接读 ini_entry->value。
 * ================================================================ */

static void (*phpglue_ini_notify)(const char *name, size_t name_len) = NULL;

void phpglue_set_ini_notify(void (*cb)(const char *name, size_t name_len)) {
    phpglue_ini_notify = cb;
}

static ZEND_INI_MH(phpglue_ini_on_modify) {
    (void)mh_arg1;
    (void)mh_arg2;
    (void)mh_arg3;
    (void)stage;
    if (phpglue_ini_notify != NULL) {
        phpglue_ini_notify(ZSTR_VAL(entry->name), ZSTR_LEN(entry->name));
    }
    return SUCCESS;
}

int phpglue_register_ini_entries(const char **names, size_t *name_lens,
    const char **default_values, const uint8_t *types, const uint8_t *modifiables,
    size_t count, int module_number)
{
    zend_ini_entry_def defs[65];
    if (count > 64) return 0;
    (void)types; /* 值类型不影响注册，读取时再解析 */
    for (size_t i = 0; i < count; i++) {
        defs[i].name = names[i];
        defs[i].name_length = (uint16_t)name_lens[i];
        defs[i].value = default_values[i];
        defs[i].value_length = (uint32_t)strlen(default_values[i]);
        defs[i].modifiable = modifiables[i];
        defs[i].on_modify = phpglue_ini_on_modify;
        defs[i].mh_arg1 = NULL;
        defs[i].mh_arg2 = NULL;
        defs[i].mh_arg3 = NULL;
        defs[i].displayer = NULL;
    }
    /* 数组以 name=NULL 哨兵结尾 */
    memset(&defs[count], 0, sizeof(zend_ini_entry_def));
    return zend_register_ini_entries(defs, module_number) == SUCCESS ? 1 : 0;
}

zend_long phpglue_ini_get_long(const char *name, size_t name_len, zend_long dflt) {
    bool exists = false;
    char *v = zend_ini_string_ex(name, name_len, 0, &exists);
    if (!exists || v == NULL) return dflt;
    return ZEND_STRTOL(v, NULL, 10);
}

char *phpglue_ini_get_string(const char *name, size_t name_len) {
    return zend_ini_string(name, name_len, 0);
}

bool phpglue_ini_get_bool(const char *name, size_t name_len, bool dflt) {
    bool exists = false;
    char *v = zend_ini_string_ex(name, name_len, 0, &exists);
    if (!exists || v == NULL) return dflt;
    if (strcasecmp(v, "on") == 0 || strcasecmp(v, "yes") == 0 ||
        strcasecmp(v, "true") == 0 || strcasecmp(v, "1") == 0) {
        return true;
    }
    if (strcasecmp(v, "off") == 0 || strcasecmp(v, "no") == 0 ||
        strcasecmp(v, "false") == 0 || strcasecmp(v, "0") == 0 || v[0] == '\0') {
        return false;
    }
    return ZEND_STRTOL(v, NULL, 10) != 0;
}

void phpglue_unregister_ini_entries(int module_number) {
    zend_unregister_ini_entries(module_number);
}

/* ================================================================
 * 对象存储（extern struct 绑定）
 *
 * 自定义 create_object 分配 zend_object + 额外数据区（Zig struct），
 * free_obj 时调用 dtor 清理额外数据。通过 handler 指针判断对象归属。
 * ================================================================ */

#define PHPGLUE_MAX_OBJECT_CLASSES 64

typedef struct {
    zend_object std;
    void *extra;
} phpglue_object;

typedef struct {
    zend_class_entry *ce;
    size_t extra_size;
    void (*init)(void *extra);
    void (*dtor)(void *extra);
} phpglue_object_class_info;

static phpglue_object_class_info phpglue_obj_infos[PHPGLUE_MAX_OBJECT_CLASSES];
static int phpglue_obj_info_count = 0;
static zend_object_handlers phpglue_object_handlers;
static bool phpglue_handlers_ready = false;

static phpglue_object_class_info *phpglue_find_obj_info(zend_class_entry *ce) {
    for (int i = 0; i < phpglue_obj_info_count; i++) {
        if (phpglue_obj_infos[i].ce == ce) return &phpglue_obj_infos[i];
    }
    return NULL;
}

static zend_object *phpglue_object_create(zend_class_entry *ce) {
    phpglue_object_class_info *info = phpglue_find_obj_info(ce);
    size_t extra_size = info ? info->extra_size : 0;
    phpglue_object *obj = emalloc(sizeof(phpglue_object) + extra_size);
    zend_object_std_init(&obj->std, ce);
    object_properties_init(&obj->std, ce);
    obj->std.handlers = &phpglue_object_handlers;
    obj->extra = (extra_size > 0) ? (void *)(obj + 1) : NULL;
    if (info != NULL && info->init != NULL && obj->extra != NULL) {
        info->init(obj->extra);
    }
    return &obj->std;
}

static void phpglue_object_free(zend_object *object) {
    phpglue_object *obj = (phpglue_object *)((char *)object - XtOffsetOf(phpglue_object, std));
    phpglue_object_class_info *info = phpglue_find_obj_info(object->ce);
    if (info != NULL && info->dtor != NULL && obj->extra != NULL) {
        info->dtor(obj->extra);
    }
    zend_object_std_dtor(object);
}

zend_class_entry *phpglue_register_object_class(const char *name, size_t name_len,
    const zend_function_entry *methods, size_t extra_size,
    void (*init)(void *extra), void (*dtor)(void *extra))
{
    if (phpglue_obj_info_count >= PHPGLUE_MAX_OBJECT_CLASSES) return NULL;

    if (!phpglue_handlers_ready) {
        memcpy(&phpglue_object_handlers, zend_get_std_object_handlers(), sizeof(zend_object_handlers));
        phpglue_object_handlers.offset = XtOffsetOf(phpglue_object, std);
        phpglue_object_handlers.free_obj = phpglue_object_free;
        phpglue_handlers_ready = true;
    }

    zend_class_entry ce;
    INIT_CLASS_ENTRY_EX(ce, name, name_len, methods);
    ce.create_object = phpglue_object_create;
    zend_class_entry *ce_ptr = zend_register_internal_class(&ce);
    if (ce_ptr == NULL) return NULL;

    phpglue_object_class_info *info = &phpglue_obj_infos[phpglue_obj_info_count++];
    info->ce = ce_ptr;
    info->extra_size = extra_size;
    info->init = init;
    info->dtor = dtor;
    return ce_ptr;
}

void *phpglue_object_get_extra(zval *obj) {
    if (Z_TYPE_P(obj) != IS_OBJECT) return NULL;
    zend_object *zobj = Z_OBJ_P(obj);
    if (zobj->handlers != &phpglue_object_handlers) return NULL;
    phpglue_object *pobj = (phpglue_object *)((char *)zobj - XtOffsetOf(phpglue_object, std));
    return pobj->extra;
}

zval *phpglue_get_this(zend_execute_data *execute_data) {
    return getThis();
}
