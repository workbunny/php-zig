//! PHP 错误报告
//!
//! 带 docref 前缀的错误报告，等价 `php_error_docref(docref, type, "%s", msg)`。
//! 与 Throw.throwException（抛异常）互补：error 用于 WARNING/NOTICE 等非致命报告。

const c = @import("php_c.zig");

/// PHP 错误类型（与 E_* 常量对应，值由 Zend 头文件保证稳定）
pub const ErrorType = enum(c_int) {
    warning = 2,   // E_WARNING
    notice = 8,    // E_NOTICE
    deprecated = 8192, // E_DEPRECATED
    user_warning = 512, // E_USER_WARNING
    user_notice = 1024, // E_USER_NOTICE
    user_deprecated = 16384, // E_USER_DEPRECATED
};

/// 报告带 docref 前缀的错误。docref 通常传 "function_name" 或 null。
pub fn docref(doc: ?[*:0]const u8, err_type: ErrorType, msg: []const u8) void {
    c.phpglue_error_docref(doc, @intFromEnum(err_type), msg.ptr);
}

/// 报告 E_WARNING（无 docref）
pub fn warning(msg: []const u8) void {
    docref(null, .warning, msg);
}

/// 报告 E_NOTICE（无 docref）
pub fn notice(msg: []const u8) void {
    docref(null, .notice, msg);
}
