//! PHP 异常 / 错误抛出
//!
//! 封装 zend_throw_exception，从 Zig 侧抛出 PHP 异常或错误对象。
//!
//! - `throwException`：抛出 `\Exception`
//! - `throwClass`：按类名抛出任意异常/错误（自定义异常类或 Error 家族）
//! - `throwError` / `typeError` / `valueError` 等：内置 Error 家族快捷方法
//!
//! 注意：PHP 的 `warning`/`notice` 是错误报告（`php_error_docref`），
//! 不中断执行、也不属于异常/错误对象体系，见 `Error` 模块，勿混淆。

const c = @import("php_c.zig");
const T = @import("php_types.zig");

/// 抛出 `\Exception` 并结束当前函数执行。
/// 与 PHP 端 `throw new Exception($msg)` 等效。
pub fn throwException(message: []const u8) void {
    c.phpglue_throw_exception(message.ptr, message.len);
}

/// 按类名抛出异常/错误（类须已注册，内置 Error 家族或自定义继承
/// Exception/Error 的类）。与 PHP 端 `throw new $className($msg)` 等效。
///
/// 类不存在时静默返回（不抛出），调用方应确保类名正确。
pub fn throwClass(className: []const u8, message: []const u8) void {
    _ = c.phpglue_throw_exception_class(className.ptr, className.len, message.ptr, message.len, 0);
}

/// 按类名 + code 抛出异常/错误。
pub fn throwClassCode(className: []const u8, message: []const u8, code: T.zend_long) void {
    _ = c.phpglue_throw_exception_class(className.ptr, className.len, message.ptr, message.len, code);
}

/// 抛出 `\Error`
pub fn throwError(message: []const u8) void {
    throwClass("Error", message);
}

/// 抛出 `\TypeError`
pub fn typeError(message: []const u8) void {
    throwClass("TypeError", message);
}

/// 抛出 `\ValueError`
pub fn valueError(message: []const u8) void {
    throwClass("ValueError", message);
}

/// 抛出 `\ArgumentCountError`
pub fn argumentCountError(message: []const u8) void {
    throwClass("ArgumentCountError", message);
}

/// 抛出 `\ArithmeticError`
pub fn arithmeticError(message: []const u8) void {
    throwClass("ArithmeticError", message);
}

/// 抛出 `\DivisionByZeroError`
pub fn divisionByZeroError(message: []const u8) void {
    throwClass("DivisionByZeroError", message);
}
