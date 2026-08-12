//! zval 类型安全包装
//!
//! 对底层 *T.Zval 指针的类型安全封装。Zval 按值传递，不持有所有权。

const c = @import("php_c.zig");
const T = @import("php_types.zig");

pub const Zval = struct {
    ptr: *T.Zval,

    pub fn fromPtr(ptr: *T.Zval) Zval     { return .{ .ptr = ptr }; }
    pub fn fromPtrPtr(ptr: *const *T.Zval) Zval { return .{ .ptr = @constCast(ptr).* }; }

    // ＝＝ 类型判断 ＝＝

    pub fn getType(self: Zval) u8     { return c.phpglue_zval_type(self.ptr); }
    pub fn isNull(self: Zval) bool     { return self.getType() == T.IS_NULL; }
    pub fn isLong(self: Zval) bool     { return self.getType() == T.IS_LONG; }
    pub fn isDouble(self: Zval) bool   { return self.getType() == T.IS_DOUBLE; }
    pub fn isString(self: Zval) bool   { return self.getType() == T.IS_STRING; }
    pub fn isArray(self: Zval) bool    { return self.getType() == T.IS_ARRAY; }
    pub fn isObject(self: Zval) bool   { return self.getType() == T.IS_OBJECT; }
    pub fn isResource(self: Zval) bool { return self.getType() == T.IS_RESOURCE; }
    pub fn isBool(self: Zval) bool {
        const t = self.getType();
        return t == T.IS_TRUE or t == T.IS_FALSE;
    }

    // ＝＝ 取值 ＝＝

    pub fn toLong(self: Zval) T.zend_long    { return c.phpglue_zval_get_long(self.ptr); }
    pub fn toDouble(self: Zval) f64           { return c.phpglue_zval_get_double(self.ptr); }
    pub fn toStringVal(self: Zval) []const u8 {
        const val = c.phpglue_zval_get_string_val(self.ptr);
        const len = c.phpglue_zval_get_string_len(self.ptr);
        return val[0..len];
    }
    pub fn toBool(self: Zval) bool            { return c.phpglue_zval_is_true(self.ptr) != 0; }

    // ＝＝ 设值 ＝＝

    pub fn setLong(self: Zval, v: T.zend_long) void { c.phpglue_zval_set_long(self.ptr, v); }
    pub fn setDouble(self: Zval, v: f64) void        { c.phpglue_zval_set_double(self.ptr, v); }
    pub fn setString(self: Zval, s: []const u8) void { c.phpglue_zval_set_stringl(self.ptr, s.ptr, s.len); }
    pub fn setBool(self: Zval, v: bool) void         { c.phpglue_zval_set_bool(self.ptr, v); }
    pub fn setNull(self: Zval) void                  { c.phpglue_zval_set_null(self.ptr); }

    // ＝＝ 引用计数与复制 ＝＝

    pub fn addRef(self: Zval) void { c.phpglue_zval_add_ref(self.ptr); }
    pub fn decRef(self: Zval) void { c.phpglue_zval_del_ref(self.ptr); }
    pub fn copy(self: Zval, dst: Zval) void { c.phpglue_zval_copy(dst.ptr, self.ptr); }
};
