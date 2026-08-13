//! PHP 对象属性读写与方法调用
//!
//! 对 Zval 中 IS_OBJECT 类型的属性访问与方法调用封装。
//! 提供两种形态：顶层自由函数（兼容早期 API）与 Object 结构体包装
//! （面向对象风格，供 Zval.toObject() 使用）。

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

/// 获取对象绑定的额外数据指针（extern struct 数据区）。
/// 对象须由 `ClassDesc.createObject` 注册，否则返回 null。
/// 调用方用 `@ptrCast(@alignCast(extra))` 恢复为绑定的 Zig struct 指针。
pub fn getExtra(obj: *T.Zval) ?*anyopaque {
    return c.phpglue_object_get_extra(obj);
}

/// 对象包装 — 面向对象风格的对象操作入口。
/// 由 `Zval.toObject()` 构造，方法内部直接调用 C glue，不依赖自由函数。
pub const Object = struct {
    zv: Zval,

    /// 从 Zval 构造（调用方需保证 zval 为 IS_OBJECT）
    pub fn fromZval(zv: Zval) Object {
        return .{ .zv = zv };
    }

    /// 读取字符串属性，返回 ?Zval
    pub fn readProperty(self: *const Object, name: []const u8) ?Zval {
        const result = c.phpglue_object_read_property(self.zv.ptr, name.ptr, name.len);
        if (result) |zv| return Zval.fromPtr(zv);
        return null;
    }

    /// 写入字符串属性（值会被复制到对象内部）
    pub fn writeProperty(self: *const Object, name: []const u8, val: *T.Zval) void {
        c.phpglue_object_write_property(self.zv.ptr, name.ptr, name.len, val);
    }

    /// 调用对象方法
    pub fn call(self: *const Object, name: []const u8, retval: *T.Zval, args: []const T.Zval) bool {
        return PhpFunc.callMethod(self.zv.ptr, name, retval, args);
    }

    /// instanceof 检查：对象是否属于指定类（或实现指定接口）
    pub fn instanceOf(self: *const Object, className: []const u8) bool {
        return c.phpglue_object_instanceof(self.zv.ptr, className.ptr, className.len) != 0;
    }
};
