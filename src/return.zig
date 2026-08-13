//! PHP 返回值工具 + 调用参数
//!
//! 封装 PHP 函数返回值设置和参数获取。
//!
//! 返回值使用 RETVAL_* 系列宏（仅设值，不 return），
//! Zig 侧 callconv(.c) void 函数末尾自然返回。
//! 不使用 RETURN_* 的原因：其内含 return 语句会破坏 Zig 栈帧。

const c = @import("php_c.zig");
const T = @import("php_types.zig");

const Zval = @import("zval.zig").Zval;

// ＝＝＝＝ 返回值 ＝＝＝＝

/// 返回字符串（内部复制）
pub fn returnString(return_value: *T.Zval, s: []const u8) void {
    c.phpglue_return_stringl(return_value, s.ptr, s.len);
}

/// 返回 long 整数
pub fn returnLong(return_value: *T.Zval, v: T.zend_long) void {
    c.phpglue_return_long(return_value, v);
}

/// 返回 double 浮点数
pub fn returnDouble(return_value: *T.Zval, v: f64) void {
    c.phpglue_return_double(return_value, v);
}

/// 返回 bool
pub fn returnBool(return_value: *T.Zval, v: bool) void {
    c.phpglue_return_bool(return_value, v);
}

/// 返回 null
pub fn returnNull(return_value: *T.Zval) void {
    c.phpglue_return_null(return_value);
}

/// 返回 true
pub fn returnTrue(return_value: *T.Zval) void {
    c.phpglue_return_true(return_value);
}

/// 返回 false
pub fn returnFalse(return_value: *T.Zval) void {
    c.phpglue_return_false(return_value);
}

/// 返回另一个 zval（增加引用计数）
pub fn returnZval(return_value: *T.Zval, zv: *T.Zval) void {
    c.phpglue_return_zval(return_value, zv);
}

// ＝＝＝＝ 调用参数 ＝＝＝＝

/// 获取当前调用接收到的实际参数个数
pub fn callNumArgs(execute_data: *T.ZendExecuteData) u32 {
    return c.phpglue_call_num_args(execute_data);
}

/// 按位置获取参数，n 为 1-based（1 = 第一个参数）
pub fn callArg(execute_data: *T.ZendExecuteData, n: u32) Zval {
    const ptr = c.phpglue_call_arg(execute_data, n);
    return Zval.fromPtr(ptr);
}

/// 获取当前方法调用的 $this 对象，非方法调用（模块级函数）返回 null
pub fn getThis(execute_data: *T.ZendExecuteData) ?Zval {
    const ptr = c.phpglue_get_this(execute_data);
    if (ptr) |p| return Zval.fromPtr(p);
    return null;
}
