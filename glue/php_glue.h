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
#include "zend_closures.h"
#include "zend_compile.h"
#include "zend_operators.h"
#include "zend_ini.h"
#include "zend_smart_str.h"
#include "zend_objects.h"
#include "zend_fibers.h"
#include "zend_observer.h"
#include "ext/standard/php_var.h"

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

/** 写时分离（SEPARATE_ZVAL）：引用计数 > 1 或引用类型时复制独立副本 */
void phpglue_zval_separate(zval *zv);

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

/* — 数组高级操作 — */

/** 移除并返回第一个元素（遍历顺序），空数组返回 0 */
int    phpglue_array_shift(zval *zv, zval *retval);
/** 头部插入元素（数字键重索引） */
void   phpglue_array_unshift(zval *zv, zval *val);
/** 合并两个数组，结果写入 dst */
void   phpglue_array_merge(zval *dst, zval *src1, zval *src2);
/** 收集所有键到 dst */
void   phpglue_array_keys(zval *src, zval *dst);
/** 收集所有值到 dst */
void   phpglue_array_values(zval *src, zval *dst);
/** 切片：从 offset 起取 len 个元素（len<0 表示到末尾），结果写入 dst */
void   phpglue_array_slice(zval *src, zval *dst, zend_long offset, zend_long len);
/** 值排序 + 重索引（等价 PHP sort()） */
void   phpglue_array_sort(zval *zv);

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

/* 类型化版本 — 每个参数带 PHP 类型标注。
 * types[i] 含义：
 *   0 = mixed（无类型提示），1 = long，2 = double，
 *   3 = string，4 = bool，5 = array，6 = object
 * allow_null[i]：非零表示 ?Type（nullable）  */
void phpglue_fill_arg_info_typed(void *dst, uint32_t required_count,
    const char **names, const uint8_t *types, const uint8_t *allow_null,
    size_t name_count, size_t *out_entry_count);

/* 完整版 — 在 typed 基础上增加可变参数与默认值。
 * variadic[i]：非零表示该参数为可变参数（...$args），仅对最后一个参数有意义
 * default_values[i]：默认值源码字符串（如 "NULL"、"0"、"[]"），可传 NULL 表示无默认值  */
void phpglue_fill_arg_info_full(void *dst, uint32_t required_count,
    const char **names, const uint8_t *types, const uint8_t *allow_null,
    const uint8_t *variadic, const char **default_values,
    size_t name_count, size_t *out_entry_count);

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

/** 按类名抛出异常/错误。类须已注册（内置 Error 家族或自定义继承 Exception/Error 的类）。
 *  成功返回 1，类不存在返回 0。message 按 message_len 复制（支持非 NUL 结尾）。 */
int phpglue_throw_exception_class(const char *class_name, size_t class_len,
    const char *message, size_t message_len, zend_long code);

/* ================================================================
 * 类注册
 * ================================================================ */

int phpglue_register_class(const char *name, size_t name_len, const zend_function_entry *methods);
int phpglue_register_class_ex(const char *name, size_t name_len, const zend_function_entry *methods, zend_class_entry *parent);
zend_class_entry *phpglue_lookup_class(const char *name, size_t name_len);

/** 注册类并添加常量和属性。accesses[i] 为 ZEND_ACC_* 组合，prop_types[i] 0=long 1=double 2=string 3=bool 4=null。 */
int phpglue_register_class_full(const char *name, size_t name_len, const zend_function_entry *methods,
    int const_count, const char **const_keys, size_t *const_key_lens,
    const void **const_vals, size_t *const_val_lens, uint8_t *const_types,
    int prop_count, const char **prop_keys, size_t *prop_key_lens,
    const void **prop_vals, size_t *prop_val_lens, uint32_t *prop_accesses, uint8_t *prop_types);

/** 注册接口（等价 zend_register_internal_interface） */
int phpglue_register_interface(const char *name, size_t name_len, const zend_function_entry *methods);

/** 让类实现单个接口（接口须已注册） */
int phpglue_class_implements_one(const char *name, size_t name_len, const char *iface_name, size_t iface_n);

/* ================================================================
 * PHP 函数调用（Facade）
 * ================================================================ */

int phpglue_call_func(const char *name, size_t name_len, zval *retval, uint32_t argc, const zval *argv);
int phpglue_call_method(zval *obj, const char *name, size_t name_len, zval *retval, uint32_t argc, const zval *argv);

/* ================================================================
 * 逻辑判断
 * ================================================================ */

int phpglue_zval_is_true(zval *zv);

/* ================================================================
 * zval 算术运算符
 * 返回值：SUCCESS / FAILURE
 * ================================================================ */

int phpglue_zval_add(zval *result, zval *op1, zval *op2);
int phpglue_zval_sub(zval *result, zval *op1, zval *op2);
int phpglue_zval_mul(zval *result, zval *op1, zval *op2);
int phpglue_zval_div(zval *result, zval *op1, zval *op2);
int phpglue_zval_mod(zval *result, zval *op1, zval *op2);

/** 三值比较：返回 -1 / 0 / 1（等价 PHP <=> 飞船运算符） */
int phpglue_zval_compare(zval *op1, zval *op2);

/* ================================================================
 * zval 语义类型判断
 * ================================================================ */

int phpglue_zval_is_callable(zval *zv);
int phpglue_zval_is_iterable(zval *zv);
int phpglue_zval_is_scalar(zval *zv);
int phpglue_zval_is_empty(zval *zv);
int phpglue_zval_is_numeric(zval *zv);

/* ================================================================
 * 对象 instanceof
 * ================================================================ */

/** 判断对象是否属于指定类（或实现指定接口），非对象或类不存在返回 0 */
int phpglue_object_instanceof(zval *obj, const char *name, size_t name_len);

/* ================================================================
 * 闭包创建
 * ================================================================ */

/** 从 Zig 函数处理器创建 PHP Closure，结果写入 res */
void phpglue_create_closure(zval *res, zif_handler handler, const char *name, size_t name_len);

/* ================================================================
 * 错误报告
 * ================================================================ */

/** 带 docref 前缀的错误报告（等价 php_error_docref(docref, type, "%s", msg)） */
void phpglue_error_docref(const char *docref, int type, const char *msg);

/** 按 zval 调用（闭包/可调用对象），等价 call_user_function(NULL, NULL, callable, ...) */
int phpglue_call_zval(zval *callable, zval *retval, uint32_t argc, const zval *argv);

/* ================================================================
 * 序列化 — PHP serialize/unserialize
 * ================================================================ */

/** 将 zval 序列化为 PHP serialize 格式字符串，结果写入 return_value */
void phpglue_var_serialize(zval *zv, zval *return_value);
/** 将 serialize 格式字符串反序列化为 zval，成功返回 1，失败返回 0 */
int  phpglue_var_unserialize(const char *s, size_t len, zval *return_value);

/* ================================================================
 * INI 配置
 * ================================================================ */

/** INI 项类型：0=long 1=string 2=bool */
typedef enum {
    PHPGLUE_INI_LONG = 0,
    PHPGLUE_INI_STRING = 1,
    PHPGLUE_INI_BOOL = 2,
} phpglue_ini_type;

/**
 * 注册一组 INI 项。
 * names/name_lens：项名及长度
 * default_values：默认值字符串（long/bool 用十进制，string 用原文）
 * types：phpglue_ini_type 数组
 * modifiables：PHP_INI_* 位组合（ZEND_INI_USER/PERDIR/SYSTEM/ALL）
 * 成功返回 1，失败返回 0。 */
int phpglue_register_ini_entries(const char **names, size_t *name_lens,
    const char **default_values, const uint8_t *types, const uint8_t *modifiables,
    size_t count, int module_number);

/** 读取 long 型 INI 值，未找到返回 dflt */
zend_long phpglue_ini_get_long(const char *name, size_t name_len, zend_long dflt);
/** 读取 string 型 INI 值（返回内部字符串，勿释放），未找到返回 NULL */
char *phpglue_ini_get_string(const char *name, size_t name_len);
/** 读取 bool 型 INI 值，未找到返回 dflt */
bool phpglue_ini_get_bool(const char *name, size_t name_len, bool dflt);
/** 注销当前模块全部 INI 项 */
void phpglue_unregister_ini_entries(int module_number);

/** 设置 INI 变更通知回调（任一 INI 项值变更时触发，name/name_len 为项名） */
void phpglue_set_ini_notify(void (*cb)(const char *name, size_t name_len));

/* ================================================================
 * 对象存储（extern struct 绑定）
 * ================================================================ */

/**
 * 注册一个带额外存储（Zig struct 数据区）的内部类。
 * extra_size：每个对象额外分配的字节数（应 >= Zig struct 大小）
 * init：对象创建时初始化额外数据（可空）
 * dtor：对象销毁时清理额外数据（可空）
 * 返回 zend_class_entry*，失败返回 NULL。 */
zend_class_entry *phpglue_register_object_class(const char *name, size_t name_len,
    const zend_function_entry *methods, size_t extra_size,
    void (*init)(void *extra), void (*dtor)(void *extra));

/** 获取对象额外数据指针（对象须由 phpglue_register_object_class 创建），否则返回 NULL */
void *phpglue_object_get_extra(zval *obj);

/** 获取当前方法调用的 $this 对象（非方法调用返回 NULL） */
zval *phpglue_get_this(zend_execute_data *execute_data);

/* ================================================================
 * Fiber — 只读查询 + 构造（控制操作 suspend/resume/start/throw 由
 * Zig 侧通过 PhpFunc 调用 PHP 原生 Fiber 方法完成，复用其校验与
 * FiberError 抛出，避免直接包装 zend_fiber_* 内含 return 的陷阱）
 * ================================================================ */

/** 判断 zval 是否为 Fiber 实例（IS_OBJECT && instanceof zend_ce_fiber） */
int phpglue_zval_is_fiber(zval *zv);

/** 读取 Fiber 状态：0=INIT 1=RUNNING 2=SUSPENDED 3=DEAD；非 Fiber 返回 -1 */
int phpglue_fiber_status(zval *zv);

/** 获取当前活跃 Fiber 到 rv（ZVAL_OBJ_COPY），非 Fiber 上下文返回 0 */
int phpglue_fiber_get_current(zval *rv);

/** 读取 Fiber 返回值到 rv（仅 DEAD 且未抛异常），成功返回 1 */
int phpglue_fiber_get_return(zval *zv, zval *rv);

/** 用 callable 构造 Fiber 对象（等价 new Fiber($callable)），成功返回 1 */
int phpglue_fiber_create(zval *callable, zval *rv);

/* ================================================================
 * Observer — 集中式观察代理（静态注册，MINIT 一次性）
 *
 * 观察点五类：fcall begin/end、error、function_declared、
 * class_linked、fiber init/switch/destroy。
 * glue 提供 C trampoline 将 Zend 类型转换为基础类型后转发给
 * Zig 侧注册的回调（各回调可独立为 NULL，NULL 表示不观察该类）。
 * ================================================================ */

/** Zig 友好回调签名（glue 已将 Zend 类型转换为基础类型） */
typedef void (*phpglue_observer_fcall_begin_fn)(zend_execute_data *execute_data);
typedef void (*phpglue_observer_fcall_end_fn)(zend_execute_data *execute_data, zval *retval);
typedef void (*phpglue_observer_error_fn)(int type, const char *filename, size_t filename_len, uint32_t lineno, const char *message, size_t message_len);
typedef void (*phpglue_observer_declared_fn)(const char *name, size_t name_len);
typedef void (*phpglue_observer_fiber_init_fn)(int status);
typedef void (*phpglue_observer_fiber_switch_fn)(int from_status, int to_status);
typedef void (*phpglue_observer_fiber_destroy_fn)(int status);

/** 一次性注册所有观察点（各回调可 NULL）。须在 MINIT 调用。 */
void phpglue_observer_register(
    phpglue_observer_fcall_begin_fn fcall_begin,
    phpglue_observer_fcall_end_fn fcall_end,
    phpglue_observer_error_fn error,
    phpglue_observer_declared_fn function_declared,
    phpglue_observer_declared_fn class_linked,
    phpglue_observer_fiber_init_fn fiber_init,
    phpglue_observer_fiber_switch_fn fiber_switch,
    phpglue_observer_fiber_destroy_fn fiber_destroy
);

/** 从 execute_data 提取当前函数名（仅 fcall begin/end 回调内有效），无函数名返回 NULL */
const char *phpglue_observer_func_name(zend_execute_data *execute_data, size_t *len);

#ifdef __cplusplus
}
#endif

#endif /* PHP_GLUE_H */
