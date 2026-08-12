//! zval 类型安全包装
//!
//! 对底层 *T.Zval 指针的类型安全封装。Zval 按值传递，不持有所有权。

const c = @import("php_c.zig");
const T = @import("php_types.zig");
const Array = @import("array.zig").Array;

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

    /// 转换为 PHP 数组包装（仅当 IS_ARRAY 时有效）
    pub fn toArray(self: Zval) ?Array {
        if (!self.isArray()) return null;
        return Array.fromZval(self);
    }

    // ＝＝ 设值 ＝＝

    pub fn setLong(self: Zval, v: T.zend_long) void { c.phpglue_zval_set_long(self.ptr, v); }
    pub fn setDouble(self: Zval, v: f64) void        { c.phpglue_zval_set_double(self.ptr, v); }
    pub fn setString(self: Zval, s: []const u8) void { c.phpglue_zval_set_stringl(self.ptr, s.ptr, s.len); }
    pub fn setBool(self: Zval, v: bool) void         { c.phpglue_zval_set_bool(self.ptr, v); }
    pub fn setNull(self: Zval) void                  { c.phpglue_zval_set_null(self.ptr); }

    // ＝＝ 比较运算符（纯 Zig，不依赖 C glue） ＝＝

    /// 相等判断 — 按 PHP 类型值比较（long 比数值，double 比浮点，string 比字节）
    pub fn eql(self: Zval, other: Zval) bool {
        const ta = self.getType();
        const tb = other.getType();
        // Null
        if (ta == T.IS_NULL and tb == T.IS_NULL) return true;
        // Bool: IS_TRUE / IS_FALSE 等价为 true/false
        if (self.isBool() and other.isBool()) return self.toBool() == other.toBool();
        // Long
        if (ta == T.IS_LONG and tb == T.IS_LONG) return self.toLong() == other.toLong();
        // Double
        if (ta == T.IS_DOUBLE and tb == T.IS_DOUBLE) return self.toDouble() == other.toDouble();
        // String — 长度与内容逐字节对比
        if (ta == T.IS_STRING and tb == T.IS_STRING) {
            const sa = self.toStringVal();
            const sb = other.toStringVal();
            if (sa.len != sb.len) return false;
            for (sa, sb) |a, b| { if (a != b) return false; }
            return true;
        }
        // 不同类型之间永不相等
        return false;
    }

    /// 不等判断 — eql 的反义
    pub fn neq(self: Zval, other: Zval) bool {
        return !self.eql(other);
    }

    // ＝＝ 引用计数与复制 ＝＝

    pub fn addRef(self: Zval) void { c.phpglue_zval_add_ref(self.ptr); }
    pub fn decRef(self: Zval) void { c.phpglue_zval_del_ref(self.ptr); }
    pub fn copy(self: Zval, dst: Zval) void { c.phpglue_zval_copy(dst.ptr, self.ptr); }
};
