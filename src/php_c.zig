//! PHP C 胶水函数声明
//!
//! 所有函数由 glue/php_glue.c 实现，Zig 侧仅声明 extern fn。
//! 设计原则：不 @cImport PHP 头文件，C 侧将 Zend 语句级宏
//! 封装为普通函数后统一暴露。

const T = @import("php_types.zig");

// ＝＝＝＝ 模块版本信息 ＝＝＝＝

pub extern fn phpglue_module_api_no()   c_uint;
pub extern fn phpglue_module_build_id() [*c]const u8;

// ＝＝＝＝ 编译期常量查询（ZEND_ACC_* 等，值由编译时 PHP 头文件决定） ＝＝＝＝

pub extern fn phpglue_arginfo_entry_size() usize;
pub extern fn phpglue_acc_public()      u32;
pub extern fn phpglue_acc_protected()   u32;
pub extern fn phpglue_acc_private()     u32;
pub extern fn phpglue_acc_static()      u32;
pub extern fn phpglue_acc_abstract()    u32;
pub extern fn phpglue_acc_final()       u32;

pub extern fn phpglue_zval_size()       usize;
pub extern fn phpglue_zts_mode()        u8;

// ＝＝＝＝ zval 类型查询 ＝＝＝＝

pub extern fn phpglue_zval_type(zv: *T.Zval) u8;

// ＝＝＝＝ zval 取值 ＝＝＝＝

pub extern fn phpglue_zval_get_long(zv: *T.Zval)        T.zend_long;
pub extern fn phpglue_zval_get_double(zv: *T.Zval)      f64;
pub extern fn phpglue_zval_get_string_val(zv: *T.Zval)  [*c]const u8;
pub extern fn phpglue_zval_get_string_len(zv: *T.Zval)  usize;
pub extern fn phpglue_zval_get_array(zv: *T.Zval)       *T.ZendArray;

// ＝＝＝＝ zval 构造 ＝＝＝＝

pub extern fn phpglue_zval_set_null(zv: *T.Zval)                                 void;
pub extern fn phpglue_zval_set_long(zv: *T.Zval, v: T.zend_long)                 void;
pub extern fn phpglue_zval_set_double(zv: *T.Zval, v: f64)                       void;
pub extern fn phpglue_zval_set_string(zv: *T.Zval, s: [*c]const u8)              void;
pub extern fn phpglue_zval_set_stringl(zv: *T.Zval, s: [*c]const u8, len: usize) void;
pub extern fn phpglue_zval_set_bool(zv: *T.Zval, v: bool)                        void;
pub extern fn phpglue_zval_set_true(zv: *T.Zval)                                 void;
pub extern fn phpglue_zval_set_false(zv: *T.Zval)                                void;

// ＝＝＝＝ zval 引用计数 ＝＝＝＝

pub extern fn phpglue_zval_add_ref(zv: *T.Zval)    void;
pub extern fn phpglue_zval_ptr_dtor(zv: *T.Zval)   void;
pub extern fn phpglue_zval_del_ref(zv: *T.Zval)    void;
pub extern fn phpglue_zval_copy(dst: *T.Zval, src: *T.Zval) void;

// ＝＝＝＝ 数组操作 ＝＝＝＝

pub extern fn phpglue_array_init(zv: *T.Zval)       void;
pub extern fn phpglue_array_separate(zv: *T.Zval)   void;

// —— 追加元素（自动递增索引） ——

pub extern fn phpglue_add_next_index_long(zv: *T.Zval, v: T.zend_long)                     void;
pub extern fn phpglue_add_next_index_double(zv: *T.Zval, v: f64)                           void;
pub extern fn phpglue_add_next_index_stringl(zv: *T.Zval, s: [*c]const u8, len: usize)     void;
pub extern fn phpglue_add_next_index_bool(zv: *T.Zval, v: bool)                            void;
pub extern fn phpglue_add_next_index_null(zv: *T.Zval)                                     void;
pub extern fn phpglue_add_next_index_zval(zv: *T.Zval, val: *T.Zval)                       void;

// —— 按数字索引设值 ——

pub extern fn phpglue_add_index_long(zv: *T.Zval, idx: T.zend_ulong, v: T.zend_long)                      void;
pub extern fn phpglue_add_index_double(zv: *T.Zval, idx: T.zend_ulong, v: f64)                            void;
pub extern fn phpglue_add_index_stringl(zv: *T.Zval, idx: T.zend_ulong, s: [*c]const u8, len: usize)      void;
pub extern fn phpglue_add_index_bool(zv: *T.Zval, idx: T.zend_ulong, v: bool)                             void;
pub extern fn phpglue_add_index_null(zv: *T.Zval, idx: T.zend_ulong)                                      void;
pub extern fn phpglue_add_index_zval(zv: *T.Zval, idx: T.zend_ulong, val: *T.Zval)                        void;

// —— 按字符串键设值（关联数组） ——

pub extern fn phpglue_add_assoc_long(zv: *T.Zval, key: [*c]const u8, v: T.zend_long)                         void;
pub extern fn phpglue_add_assoc_double(zv: *T.Zval, key: [*c]const u8, v: f64)                               void;
pub extern fn phpglue_add_assoc_stringl(zv: *T.Zval, key: [*c]const u8, s: [*c]const u8, len: usize)         void;
pub extern fn phpglue_add_assoc_bool(zv: *T.Zval, key: [*c]const u8, v: bool)                                void;
pub extern fn phpglue_add_assoc_null(zv: *T.Zval, key: [*c]const u8)                                         void;
pub extern fn phpglue_add_assoc_zval(zv: *T.Zval, key: [*c]const u8, val: *T.Zval)                           void;

// ＝＝＝＝ HashTable 底层操作 ＝＝＝＝

pub extern fn phpglue_hash_num_elements(ht: *T.ZendArray)                                     u32;
pub extern fn phpglue_hash_str_find(ht: *T.ZendArray, key: [*c]const u8, len: usize)          ?*T.Zval;
pub extern fn phpglue_hash_index_find(ht: *T.ZendArray, idx: T.zend_ulong)                    ?*T.Zval;
pub extern fn phpglue_hash_str_exists(ht: *T.ZendArray, key: [*c]const u8, len: usize)        c_int;
pub extern fn phpglue_hash_index_exists(ht: *T.ZendArray, idx: T.zend_ulong)                  c_int;
pub extern fn phpglue_hash_str_del(ht: *T.ZendArray, key: [*c]const u8, len: usize)           c_int;
pub extern fn phpglue_hash_index_del(ht: *T.ZendArray, idx: T.zend_ulong)                     c_int;

// —— 遍历 ——
pub extern fn phpglue_hash_internal_pointer_reset(ht: *T.ZendArray)                           void;
pub extern fn phpglue_hash_move_forward(ht: *T.ZendArray)                                     c_int;
pub extern fn phpglue_hash_get_current_data(ht: *T.ZendArray)                                 ?*T.Zval;
pub extern fn phpglue_hash_get_current_key_ex(ht: *T.ZendArray, str_index: *?*T.ZendString, num_index: *T.zend_ulong) c_int;

// —— 弹出 ——
pub extern fn phpglue_array_pop(zv: *T.Zval, retval: *T.Zval)                                 c_int;

// —— 数组高级操作 ——
pub extern fn phpglue_array_shift(zv: *T.Zval, retval: *T.Zval)                               c_int;
pub extern fn phpglue_array_unshift(zv: *T.Zval, val: *T.Zval)                                void;
pub extern fn phpglue_array_merge(dst: *T.Zval, src1: *T.Zval, src2: *T.Zval)                 void;
pub extern fn phpglue_array_keys(src: *T.Zval, dst: *T.Zval)                                  void;
pub extern fn phpglue_array_values(src: *T.Zval, dst: *T.Zval)                                void;
pub extern fn phpglue_array_slice(src: *T.Zval, dst: *T.Zval, offset: T.zend_long, len: T.zend_long) void;
pub extern fn phpglue_array_sort(zv: *T.Zval)                                                 void;

// ＝＝＝＝ 对象操作 ＝＝＝＝

pub extern fn phpglue_object_read_property(obj: *T.Zval, name: [*c]const u8, name_len: usize)   ?*T.Zval;
pub extern fn phpglue_object_write_property(obj: *T.Zval, name: [*c]const u8, name_len: usize, val: *T.Zval) void;
pub extern fn phpglue_object_create_stdclass(zv: *T.Zval) void;

// ＝＝＝＝ 资源类型 ＝＝＝＝

pub extern fn phpglue_register_resource_type()                                                  c_int;
pub extern fn phpglue_store_resource(zv: *T.Zval, ptr: ?*anyopaque, type_id: c_int)             void;
pub extern fn phpglue_fetch_resource(zv: *T.Zval, type_id: c_int)                               ?*anyopaque;

// ＝＝＝＝ 返回值 ＝＝＝＝
//
// C 侧使用 RETVAL_* 而非 RETURN_*。
// 原因：RETURN_* 宏内含 return 语句，会破坏 Zig 侧调用者的栈帧。
// 参数名固定为 return_value（RETVAL_* 宏内部引用该标识符）。

pub extern fn phpglue_return_string(return_value: *T.Zval, s: [*c]const u8)                  void;
pub extern fn phpglue_return_stringl(return_value: *T.Zval, s: [*c]const u8, len: usize)     void;
pub extern fn phpglue_return_long(return_value: *T.Zval, v: T.zend_long)                     void;
pub extern fn phpglue_return_double(return_value: *T.Zval, v: f64)                           void;
pub extern fn phpglue_return_bool(return_value: *T.Zval, v: bool)                            void;
pub extern fn phpglue_return_null(return_value: *T.Zval)                                     void;
pub extern fn phpglue_return_true(return_value: *T.Zval)                                     void;
pub extern fn phpglue_return_false(return_value: *T.Zval)                                    void;
pub extern fn phpglue_return_zval(return_value: *T.Zval, zv: *T.Zval)                        void;

// ＝＝＝＝ 调用信息 ＝＝＝＝

pub extern fn phpglue_call_num_args(execute_data: *T.ZendExecuteData)        u32;
pub extern fn phpglue_call_arg(execute_data: *T.ZendExecuteData, n: u32)     *T.Zval;

// ＝＝＝＝ arg_info（参数元信息） ＝＝＝＝

pub extern fn phpglue_get_empty_arg_info()                                                                    ?*anyopaque;
pub extern fn phpglue_fill_arg_info(dst: ?*anyopaque, required_count: u32, names: [*c]const [*c]const u8, name_count: usize, out_entry_count: *usize) void;
/// 类型化版本 — types/allow_null 各为 name_count 个 u8 的数组
pub extern fn phpglue_fill_arg_info_typed(dst: ?*anyopaque, required_count: u32, names: [*c]const [*c]const u8, types: [*c]const u8, allow_null: [*c]const u8, name_count: usize, out_entry_count: *usize) void;
/// 完整版 — 在 typed 基础上增加 variadic 与 default_values（均可传 null 表示无）
pub extern fn phpglue_fill_arg_info_full(dst: ?*anyopaque, required_count: u32, names: [*c]const [*c]const u8, types: [*c]const u8, allow_null: [*c]const u8, variadic: [*c]const u8, default_values: [*c]const ?[*:0]const u8, name_count: usize, out_entry_count: *usize) void;

// ＝＝＝＝ 类注册 ＝＝＝＝

pub extern fn phpglue_register_class(name: [*c]const u8, name_len: usize, methods: ?*anyopaque)                                    c_int;
pub extern fn phpglue_register_class_ex(name: [*c]const u8, name_len: usize, methods: ?*anyopaque, parent: *T.ZendClassEntry)    c_int;
pub extern fn phpglue_lookup_class(name: [*c]const u8, name_len: usize)                                                        ?*T.ZendClassEntry;

/// 注册类 + 常量 + 属性。prop_accesses[i]=ZEND_ACC_*，prop_types[i] 0=long 1=double 2=string 3=bool 4=null
pub extern fn phpglue_register_class_full(
    name: [*c]const u8, name_len: usize, methods: ?*anyopaque,
    const_count: c_int, const_keys: [*c]const [*c]const u8, const_key_lens: [*c]usize,
    const_vals: [*c]const ?*anyopaque, const_val_lens: [*c]usize, const_types: [*c]u8,
    prop_count: c_int, prop_keys: [*c]const [*c]const u8, prop_key_lens: [*c]usize,
    prop_vals: [*c]const ?*anyopaque, prop_val_lens: [*c]usize, prop_accesses: [*c]u32, prop_types: [*c]u8,
) c_int;

// ＝＝＝＝ 接口注册与实现 ＝＝＝＝

pub extern fn phpglue_register_interface(name: [*c]const u8, name_len: usize, methods: ?*anyopaque) c_int;
pub extern fn phpglue_class_implements_one(name: [*c]const u8, name_len: usize, iface_name: [*c]const u8, iface_n: usize) c_int;

// ＝＝＝＝ 模块常量注册 ＝＝＝＝

pub extern fn phpglue_register_constant_long(name: [*c]const u8, name_len: usize, val: T.zend_long, module_number: c_int)                  void;
pub extern fn phpglue_register_constant_double(name: [*c]const u8, name_len: usize, val: f64, module_number: c_int)                       void;
pub extern fn phpglue_register_constant_string(name: [*c]const u8, name_len: usize, val: [*c]const u8, val_len: usize, module_number: c_int) void;
pub extern fn phpglue_register_constant_bool(name: [*c]const u8, name_len: usize, val: bool, module_number: c_int)                        void;
pub extern fn phpglue_register_constant_null(name: [*c]const u8, name_len: usize, module_number: c_int)                                    void;

// ＝＝＝＝ 异常 / 错误 ＝＝＝＝

pub extern fn phpglue_throw_exception(message: [*c]const u8, message_len: usize) void;
pub extern fn phpglue_throw_exception_class(class_name: [*c]const u8, class_len: usize, message: [*c]const u8, message_len: usize, code: T.zend_long) c_int;

// ＝＝＝＝ PHP 函数调用（Facade） ＝＝＝＝

pub extern fn phpglue_call_func(name: [*c]const u8, name_len: usize, retval: *T.Zval, argc: u32, argv: [*c]const T.Zval)              c_int;
pub extern fn phpglue_call_method(obj: *T.Zval, name: [*c]const u8, name_len: usize, retval: *T.Zval, argc: u32, argv: [*c]const T.Zval) c_int;
/// 按 zval 调用（闭包/可调用对象）
pub extern fn phpglue_call_zval(callable: *T.Zval, retval: *T.Zval, argc: u32, argv: [*c]const T.Zval) c_int;

// ＝＝＝＝ 逻辑判断 ＝＝＝＝

pub extern fn phpglue_zval_is_true(zv: *T.Zval) c_int;

// ＝＝＝＝ zval 算术运算符 ＝＝＝＝

pub extern fn phpglue_zval_add(result: *T.Zval, op1: *T.Zval, op2: *T.Zval) c_int;
pub extern fn phpglue_zval_sub(result: *T.Zval, op1: *T.Zval, op2: *T.Zval) c_int;
pub extern fn phpglue_zval_mul(result: *T.Zval, op1: *T.Zval, op2: *T.Zval) c_int;
pub extern fn phpglue_zval_div(result: *T.Zval, op1: *T.Zval, op2: *T.Zval) c_int;
pub extern fn phpglue_zval_mod(result: *T.Zval, op1: *T.Zval, op2: *T.Zval) c_int;

/// 三值比较：返回 -1 / 0 / 1
pub extern fn phpglue_zval_compare(op1: *T.Zval, op2: *T.Zval) c_int;

// ＝＝＝＝ zval 语义类型判断 ＝＝＝＝

pub extern fn phpglue_zval_is_callable(zv: *T.Zval) c_int;
pub extern fn phpglue_zval_is_iterable(zv: *T.Zval) c_int;
pub extern fn phpglue_zval_is_scalar(zv: *T.Zval) c_int;
pub extern fn phpglue_zval_is_empty(zv: *T.Zval) c_int;
pub extern fn phpglue_zval_is_numeric(zv: *T.Zval) c_int;

// ＝＝＝＝ 对象 instanceof ＝＝＝＝

pub extern fn phpglue_object_instanceof(obj: *T.Zval, name: [*c]const u8, name_len: usize) c_int;

// ＝＝＝＝ 闭包创建 ＝＝＝＝

pub extern fn phpglue_create_closure(res: *T.Zval, handler: T.FunctionHandler, name: [*c]const u8, name_len: usize) void;

// ＝＝＝＝ 错误报告 ＝＝＝＝

pub extern fn phpglue_error_docref(docref: ?[*:0]const u8, type: c_int, msg: [*c]const u8) void;

// ＝＝＝＝ 序列化 ＝＝＝＝

pub extern fn phpglue_var_serialize(zv: *T.Zval, return_value: *T.Zval) void;
pub extern fn phpglue_var_unserialize(s: [*c]const u8, len: usize, return_value: *T.Zval) c_int;

// ＝＝＝＝ INI 配置 ＝＝＝＝

/// INI 项类型：0=long 1=string 2=bool
pub const IniType = enum(u8) { long = 0, string = 1, bool = 2 };
/// INI 可修改级别（对应 ZEND_INI_USER/PERDIR/SYSTEM/ALL）
pub const IniModifiable = enum(u8) { user = 1, perdir = 2, system = 4, all = 7 };

pub extern fn phpglue_register_ini_entries(names: [*c]const [*c]const u8, name_lens: [*c]usize, default_values: [*c]const [*c]const u8, types: [*c]const u8, modifiables: [*c]const u8, count: usize, module_number: c_int) c_int;
pub extern fn phpglue_ini_get_long(name: [*c]const u8, name_len: usize, dflt: T.zend_long) T.zend_long;
pub extern fn phpglue_ini_get_string(name: [*c]const u8, name_len: usize) [*c]u8;
pub extern fn phpglue_ini_get_bool(name: [*c]const u8, name_len: usize, dflt: bool) bool;
pub extern fn phpglue_unregister_ini_entries(module_number: c_int) void;
pub extern fn phpglue_set_ini_notify(cb: ?*const fn (name: [*c]const u8, name_len: usize) callconv(.c) void) void;

// ＝＝＝＝ 对象存储（extern struct 绑定） ＝＝＝＝

pub extern fn phpglue_register_object_class(name: [*c]const u8, name_len: usize, methods: ?*anyopaque, extra_size: usize, init: ?*const fn (extra: ?*anyopaque) callconv(.c) void, dtor: ?*const fn (extra: ?*anyopaque) callconv(.c) void) ?*T.ZendClassEntry;
pub extern fn phpglue_object_get_extra(obj: *T.Zval) ?*anyopaque;
pub extern fn phpglue_get_this(execute_data: *T.ZendExecuteData) ?*T.Zval;
