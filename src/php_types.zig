//! PHP Zend Engine 类型定义
//!
//! 核心决策：Zval 定义为 extern struct 以便栈上分配。
//! 其余复杂结构体保持 opaque，内部布局由 C 胶水层管理。
//!
//! zval 大小：16 字节覆盖了所有已知 PHP 版本的 64 位 zval，
//! 且兼容 32 位 zval（12 字节 + 4 字节填充）。module.zig 的 initModule()
//! 运行时会校验 phpglue_zval_size() <= @sizeOf(Zval)。
//! 对齐 align(8) 为 64 位指针对齐，在 32 位平台上会自动降为 align(4)。

// ＝＝ Zend 结构体类型 ＝＝

pub const Zval = extern struct {
    _data: [16]u8 align(8) = undefined,
};

pub const ZendExecuteData    = opaque {};
pub const ZendModuleEntry    = opaque {};
pub const ZendFunctionEntry  = opaque {};
pub const ZendClassEntry     = opaque {};
pub const ZendObject         = opaque {};
pub const ZendString         = opaque {};
pub const ZendArray          = opaque {};
pub const HashTable          = ZendArray;

// ＝＝ Zend 类型系统 typedef ＝＝

pub const zend_long  = c_long;
pub const zend_ulong = u64;

// ＝＝ Zend 类型常量（zend_types.h） ＝＝
// 值自 PHP 5.x 起稳定未变

pub const IS_UNDEF:     u8 = 0;
pub const IS_NULL:      u8 = 1;
pub const IS_FALSE:     u8 = 2;
pub const IS_TRUE:      u8 = 3;
pub const IS_LONG:      u8 = 4;
pub const IS_DOUBLE:    u8 = 5;
pub const IS_STRING:    u8 = 6;
pub const IS_ARRAY:     u8 = 7;
pub const IS_OBJECT:    u8 = 8;
pub const IS_RESOURCE:  u8 = 9;
pub const IS_REFERENCE: u8 = 10;
pub const IS_INDIRECT:  u8 = 11;

// ＝＝ 函数签名 ＝＝

/// PHP 函数处理器 — 匹配 Zend zif_handler
pub const FunctionHandler = *const fn (execute_data: *ZendExecuteData, return_value: *Zval) callconv(.c) void;

/// 模块生命周期回调 — MINIT / MSHUTDOWN / RINIT / RSHUTDOWN 共用签名。
/// 返回值：0 = SUCCESS，-1 = FAILURE
pub const ModuleLifecycleFn = *const fn (@"type": c_int, module_number: c_int) callconv(.c) c_int;
