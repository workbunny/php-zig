//! PHP 对象属性读写与方法调用
//!
//! 对 Zval 中 IS_OBJECT 类型的属性访问与方法调用封装。

const c = @import("php_c.zig");
const T = @import("php_types.zig");
const Zval = @import("zval.zig").Zval;
const PhpFunc = @import("php_func.zig");

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

/// 创建一个 stdClass 空对象
pub fn createStdClass(zv: *T.Zval) void {
    c.phpglue_object_create_stdclass(zv);
}

/// 调用对象方法
pub fn call(obj: *T.Zval, name: []const u8, retval: *T.Zval, args: []const T.Zval) bool {
    return PhpFunc.callMethod(obj, name, retval, args);
}

/// instanceof 检查：对象是否属于指定类（或实现指定接口）
pub fn instanceOf(obj: *T.Zval, className: []const u8) bool {
    return c.phpglue_object_instanceof(obj, className.ptr, className.len) != 0;
}
