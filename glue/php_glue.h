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
 *
 * 全部返回 zval 内部持有的指针，**不产生副本、不转移所有权**：
 * 调用方不得释放，且指针有效期与 zval 一致——zval 被改写或释放后即失效。
 * 需要独立于 zval 存活的数据必须自行复制。
 * ================================================================ */

/** 读 long 值。实现为 Z_LVAL_P（直接读字段），不做类型转换。
 *  已是 Z_LVAL_P 语义，无需再提供 unchecked 变体。 */
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
/** 按 NUL 结尾取长度（内部走 strlen），s 含二进制数据或需指定长度时用
 *  set_stringl。s 被复制，调用方可立即释放。 */
void phpglue_zval_set_string(zval *zv, const char *s);
void phpglue_zval_set_stringl(zval *zv, const char *s, size_t len);
void phpglue_zval_set_bool(zval *zv, bool v);
void phpglue_zval_set_true(zval *zv);
void phpglue_zval_set_false(zval *zv);

/* ================================================================
 * zval 引用计数
 *
 * 约定：add_ref 与 ptr_dtor 必须成对。ptr_dtor 是「减引用并在归零时释放」，
 * 不是无条件释放——漏调则泄漏，多调则 double-free。
 * ================================================================ */

void phpglue_zval_add_ref(zval *zv);
void phpglue_zval_ptr_dtor(zval *zv);

/* — 引用计数与复制 — */

/** 减少引用计数 */
void phpglue_zval_del_ref(zval *zv);

/** ZVAL_COPY 副本：dst 增加 src 的引用计数，两者共享底层值 */
void phpglue_zval_copy(zval *dst, zval *src);

/** 写时分离（SEPARATE_ZVAL）：引用计数 > 1 或引用类型时复制独立副本。
 *  会就地改写 zv，故传入的 zval 必须是可写的左值而非临时值。 */
void phpglue_zval_separate(zval *zv);

/* ================================================================
 * 数组操作 — 初始化与写时分离
 *
 * 全部 add_* 系列都**复制**传入的值（*_zval 版本会增加引用计数），
 * 故调用方可安全复用或立即释放自己的 zval。
 * array_init 会覆盖 zv 原有值且不释放——写入前确保 zv 是 IS_UNDEF 或已
 * 处理过旧值，否则泄漏。
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

/* — 按字符串键设值（关联数组） —
 *
 * key 必须带长度：Zig 侧的 []const u8 不保证 NUL 结尾（std.fmt.bufPrint 的
 * 返回值即如此），一旦内部走 strlen 就会越过切片末尾读到残留字节，
 * 症状为键名错乱而非稳定报错。
 */

void phpglue_add_assoc_long(zval *zv, const char *key, size_t key_len, zend_long v);
void phpglue_add_assoc_double(zval *zv, const char *key, size_t key_len, double v);
void phpglue_add_assoc_stringl(zval *zv, const char *key, size_t key_len, const char *s, size_t len);
void phpglue_add_assoc_bool(zval *zv, const char *key, size_t key_len, bool v);
void phpglue_add_assoc_null(zval *zv, const char *key, size_t key_len);
void phpglue_add_assoc_zval(zval *zv, const char *key, size_t key_len, zval *val);

/* ================================================================
 * HashTable 操作 — 底层哈希表查询与遍历
 *
 * find 系列返回的是**桶内元素的地址**（非副本），读取后若要把 zval 存到
 * 别处须自行 add_ref；delete 系列会使此前取到的指针立即失效。
 * ================================================================ */

uint32_t phpglue_hash_num_elements(zend_array *ht);
void    *phpglue_hash_str_find(zend_array *ht, const char *key, size_t len);
void    *phpglue_hash_index_find(zend_array *ht, zend_ulong idx);
/** 存在返回 1，不存在返回 0 */
int      phpglue_hash_str_exists(zend_array *ht, const char *key, size_t len);
int      phpglue_hash_index_exists(zend_array *ht, zend_ulong idx);
/** 删除成功返回 1，键不存在返回 0 */
int      phpglue_hash_str_del(zend_array *ht, const char *key, size_t len);
int      phpglue_hash_index_del(zend_array *ht, zend_ulong idx);

/* — 遍历 —
 *
 * 内部指针（internal pointer）是**数组自身的**状态，不是迭代器对象：
 * 嵌套遍历同一个数组会互相干扰，遍历中增删元素也会使指针失效。
 * 需要嵌套或可变遍历时应改用外部迭代器。 */

void   phpglue_hash_internal_pointer_reset(zend_array *ht);
int    phpglue_hash_move_forward(zend_array *ht);
zval  *phpglue_hash_get_current_data(zend_array *ht);
/** 取当前键，字符串键写入 str_index、数字键写入 num_index；到末尾返回 0 */
int    phpglue_hash_get_current_key_ex(zend_array *ht, zend_string **str_index, zend_ulong *num_index);

/* — 数组弹出 — */

/** 弹出末尾元素写入 retval（带走引用计数，用后须 ptr_dtor）；空数组返回 0 */
int    phpglue_array_pop(zval *zv, zval *retval);

/* — 数组高级操作 — */

/** 移除并返回第一个元素（遍历顺序），空数组返回 0 */
int    phpglue_array_shift(zval *zv, zval *retval);
/** 头部插入元素（数字键重索引） */
void   phpglue_array_unshift(zval *zv, zval *val);
/** 合并两个数组，结果写入 dst。dst 会被覆盖，须为 IS_UNDEF 或已处理旧值。
 *  merge 与 PHP array_merge 同语义：字符串键后者覆盖前者，数字键重索引。 */
void   phpglue_array_merge(zval *dst, zval *src1, zval *src2);
/** 收集所有键到 dst */
void   phpglue_array_keys(zval *src, zval *dst);
/** 收集所有值到 dst */
void   phpglue_array_values(zval *src, zval *dst);
/** 切片：从 offset 起取 len 个元素（len<0 表示到末尾），结果写入 dst */
void   phpglue_array_slice(zval *src, zval *dst, zend_long offset, zend_long len);
/** 值排序 + 重索引（等价 PHP sort()）：就地修改 zv，数字键被重新编号 */
void   phpglue_array_sort(zval *zv);

/* ================================================================
 * 对象操作
 *
 * 属性读写绕过魔术方法（__get/__set），直查 HashTable——要触发魔术方法
 * 需走 PHP 函数调用。另：PHP 8.4 起不再接受 NULL scope，故内部统一用
 * Z_OBJCE_P 取 scope 后再查表。
 * ================================================================ */

/** 读属性。返回属性槽内指针（非副本），不增加引用计数，不得缓存。
 *  属性不存在返回 NULL */
zval *phpglue_object_read_property(zval *obj, const char *name, size_t name_len);
/** 写属性。val 被复制（增加引用计数），调用方可安全复用自己的 zval */
void  phpglue_object_write_property(zval *obj, const char *name, size_t name_len, zval *val);
/** 创建 stdClass 对象，存入 zv（覆盖原值，不释放旧值） */
void  phpglue_object_create_stdclass(zval *zv);

/* ================================================================
 * 资源类型
 *
 * 只存指针，不接管所有权：ptr 指向的内存何时释放仍由调用方决定。
 * zval 被销毁时 Zend 不会释放 ptr，配合 Cleanup 注册表兜底以免泄漏。
 * ================================================================ */

int   phpglue_register_resource_type(void);
void  phpglue_store_resource(zval *zv, void *ptr, int type_id);
/** type_id 不匹配返回 NULL */
void *phpglue_fetch_resource(zval *zv, int type_id);

/* ================================================================
 * 返回值
 *
 * C 侧一律用 RETVAL_* 而非 RETURN_*：RETURN_* 宏内部含 return 语句，
 * 会提前退出本函数并跳过 Zig 调用方的 defer。由 Zig 函数末尾自然返回。
 * 参数名固定为 return_value，因为 RETVAL_* 宏展开后直接引用该标识符。
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
 * 调用信息 — 在 Zig 扩展函数体内取自己的入参
 * ================================================================ */

/** 本次调用传入的参数个数（未传的可选参数不计入） */
uint32_t phpglue_call_num_args(zend_execute_data *execute_data);
/** 取第 n 个参数，**n 从 1 开始**。返回参数槽内指针，不增加引用计数。
 *  n 超出 num_args 时返回未传参数对应的 IS_UNDEF 槽位，读取前应先比较
 *  num_args，否则会读到未初始化内存。 */
zval    *phpglue_call_arg(zend_execute_data *execute_data, uint32_t n);

/* ================================================================
 * arg_info — 函数参数元信息
 *
 * sizeof(zend_internal_arg_info) 与 zend_type 布局跨 PHP 版本变化，故不直接
 * 在 C 侧构造结构体，而是用 PHP 官方宏生成静态模板再 memcpy——布局 100%
 * 由当前 PHP 编译器保证。
 *
 * 末尾额外写入一条 name=NULL 的哨兵条目：Zend 在 zend_API.c 读
 * arg_info[num_args] 判断 is_variadic，缺哨兵会越界读。
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
 *
 * module_number 由 MINIT 传入，必须与注册该常量的模块一致，否则
 * MSHUTDOWN 时 Zend 找不到归属，注销阶段会出问题。
 * ================================================================ */

void phpglue_register_constant_long(const char *name, size_t name_len, zend_long val, int module_number);
void phpglue_register_constant_double(const char *name, size_t name_len, double val, int module_number);
void phpglue_register_constant_string(const char *name, size_t name_len, const char *val, size_t val_len, int module_number);
void phpglue_register_constant_bool(const char *name, size_t name_len, bool val, int module_number);
void phpglue_register_constant_null(const char *name, size_t name_len, int module_number);

/* ================================================================
 * 异常 / 错误
 * ================================================================ */

/** 抛 \Exception。注意仅设置 EG(exception)，**不 longjmp**——函数会正常返回，
 *  Zig 侧 defer 照常执行。真正跳过 defer 的是 bailout（OOM/超时/fatal/exit）。 */
void phpglue_throw_exception(const char *message, size_t message_len);

/** 按类名抛出异常/错误。类须已注册（内置 Error 家族或自定义继承 Exception/Error 的类）。
 *  成功返回 1，类不存在返回 0。message 按 message_len 复制（支持非 NUL 结尾）。 */
int phpglue_throw_exception_class(const char *class_name, size_t class_len,
    const char *message, size_t message_len, zend_long code);

/* ================================================================
 * 字符串分配 / 异常状态
 * ================================================================ */

/** 用 PHP 请求池分配一个长度为 len 的 zend_string，返回其句柄。
 *  返回 NULL 表示分配失败。
 *
 *  用途：构造要交还给 PHP 的字符串。与 phpglue_return_string（内部
 *  zend_string_init，会**再分配并拷贝一次**）不同，本函数配合
 *  phpglue_return_string_ptr 可以做到零拷贝移交。
 *
 *  所有权：调用方必须在 phpglue_return_string_ptr（移交）与
 *  phpglue_string_release（放弃）中**恰好选择一个**，否则泄漏。 */
zend_string *phpglue_string_alloc(size_t len);

/** 取 zend_string 的可写数据区，长度即分配时的 len（另有结尾 NUL）。
 *  返回的指针不独立持有所有权，随 zend_string 一起移交或释放。 */
char *phpglue_string_buffer(zend_string *s);

/** 把 phpglue_string_alloc 得到的字符串**零拷贝**挂到 rv（ZVAL_STR），
 *  所有权移交给 PHP。调用后不得再访问该 zend_string。 */
void phpglue_return_string_ptr(zval *rv, zend_string *s);

/** 放弃一个未移交的 zend_string（zend_string_release）。用于分配后走错误分支的场景。 */
void phpglue_string_release(zend_string *s);

/** 当前是否存在未处理的异常（EG(exception) 非空返回 1） */
int phpglue_exception_exists(void);

/* ================================================================
 * PHP 内存池额度查询
 *
 * 供 Zig 侧计算「Zig 分配还能用多少」：RequestArena 的 backing 是
 * c_allocator（malloc），不进 PHP 内存池、不受 memory_limit 约束。若不限额，
 * 进程可在 PHP 侧完全无感知的情况下逼近容器上限并被 OOM killer 杀死。
 * 故需要在此查询 PHP 池的额度，让 Zig 侧参与统一核算。
 * ================================================================ */

/** PHP 池当前用量（字节）。real=0 为已用，real=1 为向 OS 申请的真实量 */
size_t    phpglue_memory_usage(int real);

/** memory_limit（字节）。返回 0 表示未设置/不限（PHP 用 0 与 -1 两种表达，
 *  这里统一归并为 0 = 不限，避免 Zig 侧处理负数） */
size_t    phpglue_memory_limit(void);

/** 清除当前异常（zend_clear_exception）。已有异常未清理就继续调用 Zend API
 *  可能触发二次抛出或状态错乱。 */
void phpglue_clear_exception(void);

/* ================================================================
 * 类注册
 *
 * 时序约束：类常量必须在 register 之后用 zend_declare_class_constant 声明。
 * 在此之前 ce->constants_table 尚未初始化，声明操作会 segfault。
 * 成功返回 1，失败返回 0。
 * ================================================================ */

int phpglue_register_class(const char *name, size_t name_len, const zend_function_entry *methods);
/** 带父类注册。parent 须已注册——PHP 在注册时就解析父类方法与属性，
 *  传入未注册的 ce 会 segfault。 */
int phpglue_register_class_ex(const char *name, size_t name_len, const zend_function_entry *methods, zend_class_entry *parent);
/** 按名查类，未注册返回 NULL。返回的是引擎持有的 ce 指针，勿释放。
 *  类未自动加载时本函数不会触发 autoload——只查已注册的类。 */
zend_class_entry *phpglue_lookup_class(const char *name, size_t name_len);

/** 注册类并添加常量和属性。accesses[i] 为 ZEND_ACC_* 组合，prop_types[i] 0=long 1=double 2=string 3=bool 4=null。 */
int phpglue_register_class_full(const char *name, size_t name_len, const zend_function_entry *methods,
    int const_count, const char **const_keys, size_t *const_key_lens,
    const void **const_vals, size_t *const_val_lens, uint8_t *const_types,
    int prop_count, const char **prop_keys, size_t *prop_key_lens,
    const void **prop_vals, size_t *prop_val_lens, uint32_t *prop_accesses, uint8_t *prop_types);

/** 注册接口（等价 zend_register_internal_interface），成功返回 1 */
int phpglue_register_interface(const char *name, size_t name_len, const zend_function_entry *methods);

/** 让类实现单个接口。接口须先于本类注册、本类须已注册，否则返回 0。
 *  顺序不可颠倒——PHP 在 implements 时即校验抽象方法是否已实现。 */
int phpglue_class_implements_one(const char *name, size_t name_len, const char *iface_name, size_t iface_n);

/* ================================================================
 * PHP 函数调用（Facade）
 * ================================================================ */

/** 调用 PHP 函数/方法。成功返回 1 并写入 retval（已初始化、带引用计数，
 *  用后须 ptr_dtor）；失败返回 0 且 retval 为 IS_UNDEF，不应 ptr_dtor。
 *  argv 与 C 的平铺 zval 数组布局一致，Zig 侧可直接传 []const Zval 切片。 */
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

/** 算术运算，结果写入 result（成功时已初始化并带引用计数，用后须 ptr_dtor）。
 *  返回 SUCCESS / FAILURE。除数为 0、类型不支持时返回 FAILURE，
 *  此时 result 为 IS_UNDEF，不应 ptr_dtor。 */
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

/** 从 Zig 函数处理器创建 PHP Closure，结果写入 res（已带引用计数）。
 *  handler 必须是 callconv(.c) 的 zif_handler，其生命周期须长于闭包——
 *  闭包不接管 handler 的所有权。 */
void phpglue_create_closure(zval *res, zif_handler handler, const char *name, size_t name_len);

/* ================================================================
 * 错误报告
 * ================================================================ */

/** 带 docref 前缀的错误报告（等价 php_error_docref(docref, type, "%s", msg)）。
 *  type 为 E_* 常量。可恢复错误（E_WARNING/E_NOTICE）后正常返回；
 *  E_ERROR 触发 bailout，会 longjmp 跳过 Zig 侧 defer。 */
void phpglue_error_docref(const char *docref, int type, const char *msg);

/** 按 zval 调用（闭包/可调用对象），等价 call_user_function(NULL, NULL, callable, ...)。
 *  成功返回 1 并把结果写入 retval（**已初始化且带引用计数，用后须 ptr_dtor**）；
 *  失败返回 0，此时 retval 为 IS_UNDEF，不应 ptr_dtor。 */
int phpglue_call_zval(zval *callable, zval *retval, uint32_t argc, const zval *argv);

/* ================================================================
 * 序列化 — PHP serialize/unserialize
 * ================================================================ */

/** 将 zval 序列化为 PHP serialize 格式字符串，结果写入 return_value。
 *  return_value 会被初始化并带引用计数，用后须 ptr_dtor */
void phpglue_var_serialize(zval *zv, zval *return_value);
/** 将 serialize 格式字符串反序列化为 zval，成功返回 1，失败返回 0。
 *  失败时 return_value 为 IS_UNDEF，不应 ptr_dtor。
 *  注意：反序列化可执行任意 __wakeup/__unserialize，不可信输入须先校验。 */
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
/** 读取 string 型 INI 值，未找到返回 NULL。
 *  返回 ini_entry 内部持有的字符串，勿释放；值变更时该指针即失效，
 *  故不可跨「可能触发 INI 变更」的边界缓存。 */
char *phpglue_ini_get_string(const char *name, size_t name_len);
/** 读取 bool 型 INI 值，未找到返回 dflt */
bool phpglue_ini_get_bool(const char *name, size_t name_len, bool dflt);
/** 注销当前模块全部 INI 项（MSHUTDOWN 调用；漏调则 php.ini 里残留无效项） */
void phpglue_unregister_ini_entries(int module_number);

/** 设置 INI 变更通知回调（任一 INI 项值变更时触发，name/name_len 为项名）。
 *  回调在变更**之后**触发，此时读到的已是新值。 */
void phpglue_set_ini_notify(void (*cb)(const char *name, size_t name_len));

/* ================================================================
 * 对象存储（extern struct 绑定）
 * ================================================================ */

/**
 * 注册一个带额外存储（Zig struct 数据区）的内部类。
 * extra_size：每个对象额外分配的字节数（应 >= Zig struct 大小）
 * init：对象创建时初始化额外数据（可空）
 * dtor：对象销毁时清理额外数据（可空）
 * 返回 zend_class_entry*，失败返回 NULL。
 * extra 区随对象分配、随对象释放，可跨请求存活；init/dtor 由 Zend 在
 * 对象创建/销毁时调用，二者都在持有对象锁的上下文中执行，不可回调 PHP。 */
zend_class_entry *phpglue_register_object_class(const char *name, size_t name_len,
    const zend_function_entry *methods, size_t extra_size,
    void (*init)(void *extra), void (*dtor)(void *extra));

/** 获取对象额外数据指针（对象须由 phpglue_register_object_class 创建），否则返回 NULL。
 *  指针随对象生命周期存活，可跨请求；dtor 在对象销毁时由 Zend 调用。 */
void *phpglue_object_get_extra(zval *obj);

/** 获取当前方法调用的 $this 对象（非方法调用返回 NULL）。
 *  返回的 zval 不增加引用计数，不得缓存到本次调用之外。 */
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

/** 获取当前活跃 Fiber 到 rv（ZVAL_OBJ_COPY，已增加引用计数，用后须 ptr_dtor），
 *  非 Fiber 上下文返回 0。
 *  注意：主 fiber 的 kind 为 NULL，zend_fiber_from_context 有 kind 断言，
 *  故 observer 回调里拿到的 context 不能转成 Fiber 对象——对象细节只能走本函数。 */
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
 *
 * 两类 API 的时效性不同，切勿混用：
 *  - 回调参数（execute_data 等）仅在**该回调执行期间**有效，不得缓存到回调之外。
 *  - 查询函数（phpglue_observer_func_info / call_site）同样只在 fcall
 *    begin/end 回调内调用；脱离该上下文 execute_data 已被释放，读到的
 *    是无效内存。
 * ================================================================ */

/** Zig 友好回调签名（glue 已将 Zend 类型转换为基础类型） */
typedef void (*phpglue_observer_fcall_begin_fn)(zend_execute_data *execute_data);
typedef void (*phpglue_observer_fcall_end_fn)(zend_execute_data *execute_data, zval *retval);
typedef void (*phpglue_observer_error_fn)(int type, const char *filename, size_t filename_len, uint32_t lineno, const char *message, size_t message_len);

/** handle 为不透明指针：function_declared 时是 zend_op_array*，
 *  class_linked 时是 zend_class_entry*。glue 不解释其内容，交由 Zig 侧
 *  按 opaqueness 透传——避免为两个 Zend 结构体各自维护一份 extern struct
 *  （其布局跨 PHP 版本变化）。 */
typedef void (*phpglue_observer_declared_fn)(const char *name, size_t name_len, void *handle);

typedef void (*phpglue_observer_fiber_init_fn)(int status);
typedef void (*phpglue_observer_fiber_switch_fn)(int from_status, int to_status);
typedef void (*phpglue_observer_fiber_destroy_fn)(int status);

/**
 * fcall 过滤器：决定某个函数是否被观察。
 *
 * 在每个函数**首次被执行前**调用一次，返回值被引擎缓存进该函数的
 * observer 槽位，此后该函数的调用不再触发本回调（Zend 的
 * ZEND_OBSERVER_NONE_OBSERVED 优化）。返回 0 = 不观察，非 0 = 观察。
 *
 * scope：方法所属类名，普通函数/内部函数为 NULL。
 * internal：1 = 内部函数（C 实现），0 = 用户函数（PHP 实现）。
 */
typedef int (*phpglue_observer_fcall_filter_fn)(const char *name, size_t name_len,
    const char *scope, size_t scope_len, int internal);

/** 被观察函数的自身信息（一次取全，避免多次跨 ABI 调用取到不一致快照） */
typedef struct {
    const char *func_name;   size_t func_name_len;
    const char *scope_name;  size_t scope_name_len;  /* 类名，非方法为 NULL */
    const char *filename;    size_t filename_len;    /* 定义所在文件，内部函数为 NULL */
    uint32_t    lineno;                              /* 定义行号，内部函数为 0 */
    int         internal;                            /* 1 = 内部函数 */
    int         is_method;
    uint32_t    num_args;                            /* 本次调用传入的参数个数 */
} phpglue_observer_func_info_t;

/** 一次性注册所有观察点（各回调可 NULL）。须在 MINIT 调用。 */
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
);

/** 从 execute_data 提取当前函数名（仅 fcall begin/end 回调内有效），无函数名返回 NULL */
const char *phpglue_observer_func_name(zend_execute_data *execute_data, size_t *len);

/** 提取被观察函数自身信息（仅 fcall begin/end 回调内有效），全部字段为输出参数 */
void phpglue_observer_func_info(zend_execute_data *execute_data, phpglue_observer_func_info_t *out);

/**
 * 提取调用点位置——即「谁调用了我」，而非被调函数的定义位置。
 * 取自 prev_execute_data，故顶层调用（无调用者）时 file 为 NULL、lineno 为 0。
 * 仅 fcall begin/end 回调内有效。
 */
void phpglue_observer_call_site(zend_execute_data *execute_data,
    const char **file, size_t *file_len, uint32_t *lineno);

#ifdef __cplusplus
}
#endif

#endif /* PHP_GLUE_H */
