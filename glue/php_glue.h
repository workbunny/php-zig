/*
 * php_glue.h — C 胶水层声明
 *
 * 将 Zend Engine 的语句级宏（Zig @cImport 无法直接使用）
 * 封装为普通 C 函数。Zig 侧通过 extern fn 声明调用。
 *
 * 设计原则：
 * - 仅包装 Zig 无法处理的 Zend 宏（ZVAL_*、RETURN_*、array_init 等）
 * - 所有函数统一 phpglue_ 前缀，避免符号冲突
 * - 返回值函数参数名固定为 return_value（RETVAL_* 宏内部引用该名）
 */

#ifndef PHP_GLUE_H
#define PHP_GLUE_H

#include "php.h"
#include "zend_types.h"
#include "zend_API.h"
#include "zend_modules.h"
#include "zend_hash.h"
#include "zend_exceptions.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ================================================================
 * 模块版本信息
 * ================================================================ */

unsigned int phpglue_module_api_no(void);
const char *phpglue_module_build_id(void);

/* ================================================================
 * 编译期常量查询 — 避免 Zig 侧硬编码 PHP 头文件值
 * ================================================================ */

/** sizeof(zend_internal_arg_info)，由编译时 PHP 头文件决定 */
size_t   phpglue_arginfo_entry_size(void);

/** 方法可见性标志 — 由编译时 PHP 头文件的 ZEND_ACC_* 决定 */
uint32_t phpglue_acc_public(void);
uint32_t phpglue_acc_protected(void);
uint32_t phpglue_acc_private(void);
uint32_t phpglue_acc_static(void);
uint32_t phpglue_acc_abstract(void);
uint32_t phpglue_acc_final(void);

/** sizeof(zval) — 由编译时 PHP 头文件 / 目标架构决定 */
size_t  phpglue_zval_size(void);

/** ZTS 模式 — 返回 COMPILE_DL_ZTS，NTS PHP 返回 0，ZTS PHP 返回 1 */
uint8_t phpglue_zts_mode(void);

/* ================================================================
 * zval 类型查询
 * ================================================================ */

uint8_t phpglue_zval_type(zval *zv);

/* ================================================================
 * zval 取值
 * ================================================================ */

zend_long   phpglue_zval_get_long(zval *zv);
double      phpglue_zval_get_double(zval *zv);
const char *phpglue_zval_get_string_val(zval *zv);
size_t      phpglue_zval_get_string_len(zval *zv);
zend_array *phpglue_zval_get_array(zval *zv);

/* ================================================================
 * zval 构造
 * ================================================================ */

void phpglue_zval_set_null(zval *zv);
void phpglue_zval_set_long(zval *zv, zend_long v);
void phpglue_zval_set_double(zval *zv, double v);
void phpglue_zval_set_string(zval *zv, const char *s);
void phpglue_zval_set_stringl(zval *zv, const char *s, size_t len);
void phpglue_zval_set_bool(zval *zv, bool v);
void phpglue_zval_set_true(zval *zv);
void phpglue_zval_set_false(zval *zv);

/* ================================================================
 * zval 引用计数
 * ================================================================ */

void phpglue_zval_add_ref(zval *zv);
void phpglue_zval_ptr_dtor(zval *zv);

/* — 引用计数与复制 — */

/** 减少引用计数 */
void phpglue_zval_del_ref(zval *zv);

/** ZVAL_COPY 副本 */
void phpglue_zval_copy(zval *dst, zval *src);

/* ================================================================
 * 数组操作 — 初始化与写时分离
 * ================================================================ */

void phpglue_array_init(zval *zv);
void phpglue_array_separate(zval *zv);

/* — 追加元素（自动索引） — */

void phpglue_add_next_index_long(zval *zv, zend_long v);
void phpglue_add_next_index_double(zval *zv, double v);
void phpglue_add_next_index_stringl(zval *zv, const char *s, size_t len);
void phpglue_add_next_index_bool(zval *zv, bool v);
void phpglue_add_next_index_null(zval *zv);
void phpglue_add_next_index_zval(zval *zv, zval *val);

/* — 按数字索引设值 — */

void phpglue_add_index_long(zval *zv, zend_ulong idx, zend_long v);
void phpglue_add_index_double(zval *zv, zend_ulong idx, double v);
void phpglue_add_index_stringl(zval *zv, zend_ulong idx, const char *s, size_t len);
void phpglue_add_index_bool(zval *zv, zend_ulong idx, bool v);
void phpglue_add_index_null(zval *zv, zend_ulong idx);
void phpglue_add_index_zval(zval *zv, zend_ulong idx, zval *val);

/* — 按字符串键设值（关联数组） — */

void phpglue_add_assoc_long(zval *zv, const char *key, zend_long v);
void phpglue_add_assoc_double(zval *zv, const char *key, double v);
void phpglue_add_assoc_stringl(zval *zv, const char *key, const char *s, size_t len);
void phpglue_add_assoc_bool(zval *zv, const char *key, bool v);
void phpglue_add_assoc_null(zval *zv, const char *key);
void phpglue_add_assoc_zval(zval *zv, const char *key, zval *val);

/* ================================================================
 * HashTable 操作 — 底层哈希表查询与遍历
 * ================================================================ */

uint32_t phpglue_hash_num_elements(zend_array *ht);
void    *phpglue_hash_str_find(zend_array *ht, const char *key, size_t len);
void    *phpglue_hash_index_find(zend_array *ht, zend_ulong idx);
int      phpglue_hash_str_exists(zend_array *ht, const char *key, size_t len);
int      phpglue_hash_index_exists(zend_array *ht, zend_ulong idx);
int      phpglue_hash_str_del(zend_array *ht, const char *key, size_t len);
int      phpglue_hash_index_del(zend_array *ht, zend_ulong idx);

/* — 遍历 — */

void   phpglue_hash_internal_pointer_reset(zend_array *ht);
int    phpglue_hash_move_forward(zend_array *ht);
zval  *phpglue_hash_get_current_data(zend_array *ht);
int    phpglue_hash_get_current_key_ex(zend_array *ht, zend_string **str_index, zend_ulong *num_index);

/* — 数组弹出 — */

int    phpglue_array_pop(zval *zv, zval *retval);

/* ================================================================
 * 对象操作
 * ================================================================ */

zval *phpglue_object_read_property(zval *obj, const char *name, size_t name_len);
void  phpglue_object_write_property(zval *obj, const char *name, size_t name_len, zval *val);
/** 创建 stdClass 对象，存入 zv */
void  phpglue_object_create_stdclass(zval *zv);

/* ================================================================
 * 资源类型
 * ================================================================ */

int   phpglue_register_resource_type(void);
void  phpglue_store_resource(zval *zv, void *ptr, int type_id);
void *phpglue_fetch_resource(zval *zv, int type_id);

/* ================================================================
 * 返回值
 * ================================================================ */

void phpglue_return_string(zval *return_value, const char *s);
void phpglue_return_stringl(zval *return_value, const char *s, size_t len);
void phpglue_return_long(zval *return_value, zend_long v);
void phpglue_return_double(zval *return_value, double v);
void phpglue_return_bool(zval *return_value, bool v);
void phpglue_return_null(zval *return_value);
void phpglue_return_true(zval *return_value);
void phpglue_return_false(zval *return_value);
void phpglue_return_zval(zval *return_value, zval *zv);

/* ================================================================
 * 调用信息
 * ================================================================ */

uint32_t phpglue_call_num_args(zend_execute_data *execute_data);
zval    *phpglue_call_arg(zend_execute_data *execute_data, uint32_t n);

/* ================================================================
 * arg_info — 函数参数元信息
 * ================================================================ */

const void *phpglue_get_empty_arg_info(void);
void phpglue_fill_arg_info(void *dst, uint32_t required_count, const char **names, size_t name_count, size_t *out_entry_count);

/* ================================================================
 * 模块常量注册
 * ================================================================ */

void phpglue_register_constant_long(const char *name, size_t name_len, zend_long val, int module_number);
void phpglue_register_constant_double(const char *name, size_t name_len, double val, int module_number);
void phpglue_register_constant_string(const char *name, size_t name_len, const char *val, size_t val_len, int module_number);
void phpglue_register_constant_bool(const char *name, size_t name_len, bool val, int module_number);
void phpglue_register_constant_null(const char *name, size_t name_len, int module_number);

/* ================================================================
 * 异常 / 错误
 * ================================================================ */

void phpglue_throw_exception(const char *message, size_t message_len);

/* ================================================================
 * 类注册
 * ================================================================ */

int phpglue_register_class(const char *name, size_t name_len, const zend_function_entry *methods);
int phpglue_register_class_ex(const char *name, size_t name_len, const zend_function_entry *methods, zend_class_entry *parent);
zend_class_entry *phpglue_lookup_class(const char *name, size_t name_len);

/** 注册类并添加常量。count 为常量个数，keys/vals 同为 arrays 长度为 count。type_ids[i]=0 表示 long，1 表示 string。 */
int phpglue_register_class_with_constants(const char *name, size_t name_len, const zend_function_entry *methods,
    int const_count, const char **const_keys, size_t *const_key_lens,
    const void **const_vals, size_t *const_val_lens, uint8_t *const_types);

/* ================================================================
 * PHP 函数调用（Facade）
 * ================================================================ */

int phpglue_call_func(const char *name, size_t name_len, zval *retval, uint32_t argc, const zval *argv);
int phpglue_call_method(zval *obj, const char *name, size_t name_len, zval *retval, uint32_t argc, const zval *argv);

/* ================================================================
 * 逻辑判断
 * ================================================================ */

int phpglue_zval_is_true(zval *zv);

#ifdef __cplusplus
}
#endif

#endif /* PHP_GLUE_H */
