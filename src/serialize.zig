//! PHP 序列化
//!
//! 等价 PHP `serialize()` / `unserialize()`，用于把 zval 转成可存储/传输的
//! 字符串，或从字符串还原。底层调用 php_var_serialize / php_var_unserialize。

const c = @import("php_c.zig");
const T = @import("php_types.zig");

/// 将 zval 序列化为 PHP serialize 格式字符串，结果写入 return_value。
/// 等价 `return_value = serialize($zv)`。
pub fn serialize(zv: *T.Zval, return_value: *T.Zval) void {
    c.phpglue_var_serialize(zv, return_value);
}

/// 将 serialize 格式字符串反序列化为 zval，结果写入 return_value。
/// 成功返回 true，失败（格式非法）返回 false 且 return_value 未定义。
pub fn unserialize(data: []const u8, return_value: *T.Zval) bool {
    return c.phpglue_var_unserialize(data.ptr, data.len, return_value) != 0;
}
