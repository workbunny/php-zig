/*
 * php_glue.c — C 胶水层实现
 *
 * 将 Zend Engine 的语句级宏封装为普通 C 函数，供 Zig extern fn 直接调用。
 *
 * 阅读约定：本文件多数函数是「单行宏转发」，其语义由函数名自解释，
 * 不加注释。注释只出现在存在非显然约束处——版本差异处理、指针有效期、
 * 时序要求、以及为避免踩坑而刻意采取的写法。
 *
 * 对外契约（所有权、返回值语义、前置条件）统一写在 php_glue.h，
 * 那边是调用方唯一需要读的文档；本文件只解释「为什么这样写」。
 */

#include "php_glue.h"
#include <stdlib.h>
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
void phpglue_zval_separate(zval *zv) { SEPARATE_ZVAL(zv); }

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

/* key 一律带长度：无长度的 add_assoc_long(key) 等变体内部走 strlen(key)，
 * 而 Zig 侧持有的是 []const u8 切片，不保证 NUL 结尾（典型如
 * std.fmt.bufPrint 的返回值），strlen 会越过切片末尾读到残留字节——
 * 症状是键名错乱、偶发失效，而非稳定报错。显式传长度是唯一安全做法。 */
void phpglue_add_assoc_long(zval *zv, const char *key, size_t key_len, zend_long v)      { add_assoc_long_ex(zv, key, key_len, v); }
void phpglue_add_assoc_double(zval *zv, const char *key, size_t key_len, double v)       { add_assoc_double_ex(zv, key, key_len, v); }
void phpglue_add_assoc_stringl(zval *zv, const char *key, size_t key_len, const char *s, size_t l) { add_assoc_stringl_ex(zv, key, key_len, s, l); }
void phpglue_add_assoc_bool(zval *zv, const char *key, size_t key_len, bool v)           { add_assoc_bool_ex(zv, key, key_len, v); }
void phpglue_add_assoc_null(zval *zv, const char *key, size_t key_len)                   { add_assoc_null_ex(zv, key, key_len); }
void phpglue_add_assoc_zval(zval *zv, const char *key, size_t key_len, zval *val)        { add_assoc_zval_ex(zv, key, key_len, val); }

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
/* 空表时 zend_hash_get_current_data 仍可能返回末次残留的指针，
 * 故显式判空后再取——否则调用方会读到已删除元素的位置。 */
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

/* array_shift 复用哈希表的内部指针来定位首元素（PHP 官方实现同此做法）。
 * 内部指针是数组自身状态，故嵌套遍历同一数组时调用本函数会打乱外层遍历。 */
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
 * 字符串分配 / 异常状态
 * ================================================================ */

zend_string *phpglue_string_alloc(size_t len) {
    return zend_string_alloc(len, 0);
}

char *phpglue_string_buffer(zend_string *s) {
    return ZSTR_VAL(s);
}

/* 零拷贝：ZVAL_STR 直接接管已分配的 zend_string，不做二次分配/拷贝。
 * 对比 phpglue_return_string 的 RETVAL_STRING——那是 zend_string_init，
 * 会再分配一次并 memcpy，字符串拼接类热路径上能差出近一倍。 */
void phpglue_return_string_ptr(zval *rv, zend_string *s) {
    ZVAL_STR(rv, s);
}

void phpglue_string_release(zend_string *s) {
    zend_string_release(s);
}

int phpglue_exception_exists(void) {
    return EG(exception) ? 1 : 0;
}

void phpglue_clear_exception(void) {
    zend_clear_exception();
}

size_t phpglue_memory_usage(int real) {
    return zend_memory_usage(real);
}

/* PHP 的 memory_limit 有两种「不限」表达：ini 值 0 与 -1（未设置时为 -1）。
 * 统一归并为 0 = 不限，让 Zig 侧不必处理负数，避免符号转换出错。 */
size_t phpglue_memory_limit(void) {
    zend_long limit = PG(memory_limit);
    if (limit <= 0) return 0;
    return (size_t) limit;
}

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
/* 方法名走 interned string：方法名几乎都是字面量，intern 后重复调用直接命中
 * 缓存，省掉每次 ZVAL_STRINGL 的 emalloc + 释放。原实现每次调用都分配一个
 * zend_string，在循环调用场景下（实测 method 用例慢 25%）是纯浪费。
 *
 * interned string 由 PHP 在请求结束时统一释放，无需逐次 ptr_dtor。 */
int phpglue_call_method(zval *obj, const char *name, size_t n, zval *retval, uint32_t argc, const zval *argv) {
    zval mname;
    ZVAL_STR(&mname, zend_string_init_interned(name, n, 1));
    return call_user_function(NULL, obj, &mname, retval, argc, (zval *)argv) == SUCCESS ? 1 : 0;
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
    /* Zend 对 INI 项个数不设上限，故按实际数量动态分配，与 Zend 能力保持一致
       （此前固定 65 是本项目自造的限制，已移除）。
       zend_register_ini_entries() 内部会拷贝 name/value，故 defs 用完即可释放。 */
    zend_ini_entry_def *defs =
        (zend_ini_entry_def *)malloc(sizeof(zend_ini_entry_def) * (count + 1));
    if (!defs) return 0;
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
    int ret = zend_register_ini_entries(defs, module_number) == SUCCESS ? 1 : 0;
    free(defs);
    return ret;
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

/* Zend 对类数量不设上限，故对象类信息表按需动态扩容
   （此前固定 64 是本项目自造的限制，超过时静默返回 NULL 导致类注册不上）。 */
static phpglue_object_class_info *phpglue_obj_infos = NULL;
static int phpglue_obj_info_count = 0;
static int phpglue_obj_info_cap = 0;
static zend_object_handlers phpglue_object_handlers;
static bool phpglue_handlers_ready = false;

/* 预留一个表项并递增计数；容量不足时倍增扩容。失败返回 NULL。
   注意：扩容可能移动缓冲区，故调用方不得长期持有返回的指针。 */
static phpglue_object_class_info *phpglue_reserve_obj_info(void) {
    if (phpglue_obj_info_count >= phpglue_obj_info_cap) {
        int new_cap = phpglue_obj_info_cap > 0 ? phpglue_obj_info_cap * 2 : 8;
        phpglue_object_class_info *p =
            (phpglue_object_class_info *)realloc(phpglue_obj_infos,
                                                 sizeof(phpglue_object_class_info) * (size_t)new_cap);
        if (!p) return NULL;
        phpglue_obj_infos = p;
        phpglue_obj_info_cap = new_cap;
    }
    return &phpglue_obj_infos[phpglue_obj_info_count++];
}

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

    phpglue_object_class_info *info = phpglue_reserve_obj_info();
    if (!info) return NULL;
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

/* ================================================================
 * Fiber — 只读查询 + 构造
 * ================================================================ */

int phpglue_zval_is_fiber(zval *zv) {
    if (Z_TYPE_P(zv) != IS_OBJECT) return 0;
    return instanceof_function(Z_OBJCE_P(zv), zend_ce_fiber);
}

int phpglue_fiber_status(zval *zv) {
    if (Z_TYPE_P(zv) != IS_OBJECT) return -1;
    zend_object *obj = Z_OBJ_P(zv);
    if (!instanceof_function(obj->ce, zend_ce_fiber)) return -1;
    zend_fiber *fiber = (zend_fiber *) obj;
    return (int) fiber->context.status;
}

int phpglue_fiber_get_current(zval *rv) {
    zend_fiber *fiber = EG(active_fiber);
    if (fiber == NULL) return 0;
    ZVAL_OBJ_COPY(rv, &fiber->std);
    return 1;
}

int phpglue_fiber_get_return(zval *zv, zval *rv) {
    if (Z_TYPE_P(zv) != IS_OBJECT) return 0;
    zend_object *obj = Z_OBJ_P(zv);
    if (!instanceof_function(obj->ce, zend_ce_fiber)) return 0;
    zend_fiber *fiber = (zend_fiber *) obj;
    if (fiber->context.status != ZEND_FIBER_STATUS_DEAD) return 0;
    if (fiber->flags & ZEND_FIBER_FLAG_THREW) return 0;
    ZVAL_COPY(rv, &fiber->result);
    return 1;
}

int phpglue_fiber_create(zval *callable, zval *rv) {
    zend_fcall_info fci;
    zend_fcall_info_cache fcc;
    if (zend_fcall_info_init(callable, 0, &fci, &fcc, NULL, NULL) != SUCCESS) {
        return 0;
    }

    object_init_ex(rv, zend_ce_fiber);
    zend_fiber *fiber = (zend_fiber *) Z_OBJ_P(rv);

    /* 复刻 Fiber::__construct 逻辑：设置 fci/fci_cache 并持有 callable 引用 */
    fiber->fci = fci;
    fiber->fci_cache = fcc;
    Z_TRY_ADDREF(fiber->fci.function_name);
    return 1;
}

/* ================================================================
 * Observer — 集中式观察代理（静态注册）
 * ================================================================ */

/* Zig 侧注册的回调（全局单例，MINIT 一次性设置） */
static phpglue_observer_fcall_begin_fn  g_obs_fcall_begin = NULL;
static phpglue_observer_fcall_end_fn    g_obs_fcall_end = NULL;
static phpglue_observer_error_fn        g_obs_error = NULL;
static phpglue_observer_declared_fn     g_obs_function_declared = NULL;
static phpglue_observer_declared_fn     g_obs_class_linked = NULL;
static phpglue_observer_fiber_init_fn   g_obs_fiber_init = NULL;
static phpglue_observer_fiber_switch_fn g_obs_fiber_switch = NULL;
static phpglue_observer_fiber_destroy_fn g_obs_fiber_destroy = NULL;
static phpglue_observer_fcall_filter_fn  g_obs_fcall_filter = NULL;

/* —— fcall begin/end trampoline —— */

static void phpglue_observer_fcall_begin_trampoline(zend_execute_data *execute_data) {
    if (g_obs_fcall_begin) g_obs_fcall_begin(execute_data);
}

static void phpglue_observer_fcall_end_trampoline(zend_execute_data *execute_data, zval *retval) {
    if (g_obs_fcall_end) g_obs_fcall_end(execute_data, retval);
}

/* fcall init：每个函数首次执行前调用一次，返回值被引擎缓存。
 *
 * 返回 {NULL, NULL} 时引擎写入 ZEND_OBSERVER_NONE_OBSERVED 到该函数
 * 的 observer 槽位，此后调用完全不进入 observer —— 这是 Zend 官方的
 * 过滤机制，把「观察哪些函数」的判定从每次调用降为每函数一次。
 * 故未注册 filter 时保持无条件观察（向后兼容），注册后则按 filter 结果。 */
static zend_observer_fcall_handlers phpglue_observer_fcall_init(zend_execute_data *execute_data) {
    zend_observer_fcall_handlers handlers = {NULL, NULL};

    if (g_obs_fcall_filter) {
        zend_function *func = execute_data ? execute_data->func : NULL;
        const char *name = NULL;
        size_t name_len = 0;
        const char *scope = NULL;
        size_t scope_len = 0;

        if (func) {
            if (func->common.function_name) {
                name = ZSTR_VAL(func->common.function_name);
                name_len = ZSTR_LEN(func->common.function_name);
            }
            if (func->common.scope && func->common.scope->name) {
                scope = ZSTR_VAL(func->common.scope->name);
                scope_len = ZSTR_LEN(func->common.scope->name);
            }
        }
        /* 匿名函数无 function_name，交给 filter 以空名判定，不在此处替它决定 */
        if (!g_obs_fcall_filter(name ? name : "", name_len,
                                scope, scope ? scope_len : 0,
                                func && !ZEND_USER_CODE(func->type))) {
            return handlers;
        }
    }

    if (g_obs_fcall_begin) handlers.begin = phpglue_observer_fcall_begin_trampoline;
    if (g_obs_fcall_end)   handlers.end   = phpglue_observer_fcall_end_trampoline;
    return handlers;
}

/* —— error trampoline：zend_string* → char* + len —— */

static void phpglue_observer_error_trampoline(int type, zend_string *error_filename, uint32_t error_lineno, zend_string *message) {
    if (!g_obs_error) return;
    g_obs_error(type,
        error_filename ? ZSTR_VAL(error_filename) : "",
        error_filename ? ZSTR_LEN(error_filename) : 0,
        error_lineno,
        message ? ZSTR_VAL(message) : "",
        message ? ZSTR_LEN(message) : 0);
}

/* —— function_declared / class_linked trampoline —— */

static void phpglue_observer_function_declared_trampoline(zend_op_array *op_array, zend_string *name) {
    if (g_obs_function_declared) g_obs_function_declared(ZSTR_VAL(name), ZSTR_LEN(name), (void *) op_array);
}

static void phpglue_observer_class_linked_trampoline(zend_class_entry *ce, zend_string *name) {
    if (g_obs_class_linked) g_obs_class_linked(ZSTR_VAL(name), ZSTR_LEN(name), (void *) ce);
}

/* —— fiber init/switch/destroy trampoline：context → status —— */

static void phpglue_observer_fiber_init_trampoline(zend_fiber_context *initializing) {
    if (g_obs_fiber_init) g_obs_fiber_init((int) initializing->status);
}

static void phpglue_observer_fiber_switch_trampoline(zend_fiber_context *from, zend_fiber_context *to) {
    if (g_obs_fiber_switch) g_obs_fiber_switch((int) from->status, (int) to->status);
}

static void phpglue_observer_fiber_destroy_trampoline(zend_fiber_context *destroying) {
    if (g_obs_fiber_destroy) g_obs_fiber_destroy((int) destroying->status);
}

/* —— 一次性注册全部观察点（MINIT） —— */

void phpglue_observer_register(
    phpglue_observer_fcall_begin_fn fcall_begin,
    phpglue_observer_fcall_end_fn fcall_end,
    phpglue_observer_error_fn error,
    phpglue_observer_declared_fn function_declared,
    phpglue_observer_declared_fn class_linked,
    phpglue_observer_fiber_init_fn fiber_init,
    phpglue_observer_fiber_switch_fn fiber_switch,
    phpglue_observer_fiber_destroy_fn fiber_destroy,
    phpglue_observer_fcall_filter_fn fcall_filter
) {
    g_obs_fcall_begin = fcall_begin;
    g_obs_fcall_end = fcall_end;
    g_obs_error = error;
    g_obs_function_declared = function_declared;
    g_obs_class_linked = class_linked;
    g_obs_fiber_init = fiber_init;
    g_obs_fiber_switch = fiber_switch;
    g_obs_fiber_destroy = fiber_destroy;
    g_obs_fcall_filter = fcall_filter;

    if (fcall_begin || fcall_end) {
        zend_observer_fcall_register(phpglue_observer_fcall_init);
    }
    if (error) {
        zend_observer_error_register(phpglue_observer_error_trampoline);
    }
    if (function_declared) {
        zend_observer_function_declared_register(phpglue_observer_function_declared_trampoline);
    }
    if (class_linked) {
        zend_observer_class_linked_register(phpglue_observer_class_linked_trampoline);
    }
    if (fiber_init) {
        zend_observer_fiber_init_register(phpglue_observer_fiber_init_trampoline);
    }
    if (fiber_switch) {
        zend_observer_fiber_switch_register(phpglue_observer_fiber_switch_trampoline);
    }
    if (fiber_destroy) {
        zend_observer_fiber_destroy_register(phpglue_observer_fiber_destroy_trampoline);
    }
}

/* —— 从 execute_data 提取当前函数名 —— */

const char *phpglue_observer_func_name(zend_execute_data *execute_data, size_t *len) {
    zend_function *func = execute_data ? execute_data->func : NULL;
    if (!func || !func->common.function_name) {
        if (len) *len = 0;
        return NULL;
    }
    if (len) *len = ZSTR_LEN(func->common.function_name);
    return ZSTR_VAL(func->common.function_name);
}

/* —— 被观察函数的自身信息 —— */

void phpglue_observer_func_info(zend_execute_data *execute_data, phpglue_observer_func_info_t *out) {
    out->func_name = NULL;  out->func_name_len = 0;
    out->scope_name = NULL; out->scope_name_len = 0;
    out->filename = NULL;   out->filename_len = 0;
    out->lineno = 0;
    out->internal = 0;
    out->is_method = 0;
    out->num_args = 0;

    zend_function *func = execute_data ? execute_data->func : NULL;
    if (!func) return;

    if (func->common.function_name) {
        out->func_name = ZSTR_VAL(func->common.function_name);
        out->func_name_len = ZSTR_LEN(func->common.function_name);
    }
    if (func->common.scope) {
        out->is_method = 1;
        if (func->common.scope->name) {
            out->scope_name = ZSTR_VAL(func->common.scope->name);
            out->scope_name_len = ZSTR_LEN(func->common.scope->name);
        }
    }
    /* 内部函数没有 op_array，filename/line_start 对其无意义 */
    if (ZEND_USER_CODE(func->type)) {
        if (func->op_array.filename) {
            out->filename = ZSTR_VAL(func->op_array.filename);
            out->filename_len = ZSTR_LEN(func->op_array.filename);
        }
        out->lineno = func->op_array.line_start;
    } else {
        out->internal = 1;
    }
    /* num_args 的存放位置跨版本变过（PHP 7 编码在 call_info 低 16 位，
     * 8.x 改为 This.u2.num_args），必须用宏而非直接位运算 */
    out->num_args = ZEND_CALL_NUM_ARGS(execute_data);
}

/* —— 调用点位置（取自 prev_execute_data，即「谁调用了我」）—— */

void phpglue_observer_call_site(zend_execute_data *execute_data,
    const char **file, size_t *file_len, uint32_t *lineno) {
    *file = NULL;
    if (file_len) *file_len = 0;
    *lineno = 0;

    zend_execute_data *prev = execute_data ? execute_data->prev_execute_data : NULL;
    if (!prev || !prev->func) return;

    /* 调用者是内部函数时无 op_array，取不到 PHP 源码位置 */
    if (!ZEND_USER_CODE(prev->func->type)) return;

    if (prev->func->op_array.filename) {
        *file = ZSTR_VAL(prev->func->op_array.filename);
        if (file_len) *file_len = ZSTR_LEN(prev->func->op_array.filename);
    }
    /* prev->opline 在调用发生时指向发起调用的指令（DO_FCALL 等），
     * 其 lineno 即调用点行号 */
    if (prev->opline) *lineno = prev->opline->lineno;
}
