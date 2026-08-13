//! PHP 函数调用 Facade
//!
//! 从 Zig 调用 PHP 内置函数或用户定义函数。
//! call_user_function 的调用约定（平铺 zval 数组 vs 指针数组）由 C glue 内部处理。

const c = @import("php_c.zig");
const T = @import("php_types.zig");

pub fn call0(name: []const u8, retval: *T.Zval) bool {
    return c.phpglue_call_func(name.ptr, name.len, retval, 0, null) != 0;
}

pub fn call(name: []const u8, retval: *T.Zval, args: []const T.Zval) bool {
    return c.phpglue_call_func(name.ptr, name.len, retval, @intCast(args.len), args.ptr) != 0;
}

pub fn call1Str(name: []const u8, retval: *T.Zval, arg: []const u8) bool {
    var zv: T.Zval = undefined;
    c.phpglue_zval_set_stringl(&zv, arg.ptr, arg.len);
    return call(name, retval, &.{zv});
}

pub fn call1Long(name: []const u8, retval: *T.Zval, arg: T.zend_long) bool {
    var zv: T.Zval = undefined;
    c.phpglue_zval_set_long(&zv, arg);
    return call(name, retval, &.{zv});
}

pub fn call2Long(name: []const u8, retval: *T.Zval, a: T.zend_long, b: T.zend_long) bool {
    var zv1: T.Zval = undefined;
    var zv2: T.Zval = undefined;
    c.phpglue_zval_set_long(&zv1, a);
    c.phpglue_zval_set_long(&zv2, b);
    return call(name, retval, &.{ zv1, zv2 });
}

pub fn call2Str(name: []const u8, retval: *T.Zval, a: []const u8, b: []const u8) bool {
    var zv1: T.Zval = undefined;
    var zv2: T.Zval = undefined;
    c.phpglue_zval_set_stringl(&zv1, a.ptr, a.len);
    c.phpglue_zval_set_stringl(&zv2, b.ptr, b.len);
    return call(name, retval, &.{ zv1, zv2 });
}

pub fn callMethod(obj: *T.Zval, name: []const u8, retval: *T.Zval, args: []const T.Zval) bool {
    return c.phpglue_call_method(obj, name.ptr, name.len, retval, @intCast(args.len), args.ptr) != 0;
}

/// 按 zval 调用可调用对象（闭包/函数名/可调用对象）
pub fn callZval(callable: *T.Zval, retval: *T.Zval, args: []const T.Zval) bool {
    return c.phpglue_call_zval(callable, retval, @intCast(args.len), args.ptr) != 0;
}
