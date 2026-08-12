//! PHP 异常 / 错误抛出
//!
//! 封装 zend_throw_exception，从 Zig 侧抛出 PHP 异常。

const c = @import("php_c.zig");

/// 抛出 `\Exception` 并结束当前函数执行
///
/// 调用后应 return 退出当前 PHP 函数。
/// 与 PHP 端 `throw new Exception($msg)` 等效。
pub fn throwException(message: []const u8) void {
    c.phpglue_throw_exception(message.ptr, message.len);
}
