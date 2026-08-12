//! PHP 对象属性读写
//!
//! 对 Zval 中 IS_OBJECT 类型的属性访问封装。

const c = @import("php_c.zig");
const T = @import("php_types.zig");
const Zval = @import("zval.zig").Zval;

/// 读取对象的字符串属性，返回 ?Zval
pub fn readProperty(obj: *T.Zval, name: []const u8) ?Zval {
    const result = c.phpglue_object_read_property(obj, name.ptr, name.len);
    if (result) |zv| return Zval.fromPtr(zv);
    return null;
}

/// 写入字符串属性（值会被复制到对象内部）
pub fn writeProperty(obj: *T.Zval, name: []const u8, val: *T.Zval) void {
    c.phpglue_object_write_property(obj, name.ptr, name.len, val);
}
