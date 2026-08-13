//! PHP 数组操作
//!
//! 对 PHP 数组（底层 HashTable）的封装，提供三种设值方式：
//! - append   追加到数组末尾（自动索引）
//! - set      按数字索引设值
//! - setAssoc 按字符串键设值（关联数组）
//!
//! 获取：find / findIndex / exists / existsIndex / count
//! 删除：del / delIndex
//! 高级：pop / iterator / filter / map / reduce
//! 生命周期：separate（写时分离，COW）

const c = @import("php_c.zig");
const T = @import("php_types.zig");
const Zval = @import("zval.zig").Zval;
const Iterator = @import("iterator.zig").Iterator;

pub const Array = struct {
    /// 底层 zval 包装（数组本身存储在 zval 中）
    zv: Zval,

    /// 在指定 zval 上构造空数组（zval 生命周期由调用者管理）
    pub fn init(zv: *T.Zval) Array {
        c.phpglue_array_init(zv);
        return .{ .zv = Zval.fromPtr(zv) };
    }

    /// 从已有的 Zval 包装构造（要求 Zval 为 IS_ARRAY 类型）
    pub fn fromZval(zv: Zval) Array {
        return .{ .zv = zv };
    }

    fn hashTable(self: *const Array) *T.ZendArray {
        return c.phpglue_zval_get_array(self.zv.ptr);
    }

    // ＝＝ 查询 ＝＝

    pub fn count(self: *const Array) u32 {
        return c.phpglue_hash_num_elements(self.hashTable());
    }

    pub fn find(self: *const Array, key: []const u8) ?Zval {
        const result = c.phpglue_hash_str_find(self.hashTable(), key.ptr, key.len);
        if (result) |zv| return Zval.fromPtr(zv);
        return null;
    }

    pub fn findIndex(self: *const Array, idx: T.zend_ulong) ?Zval {
        const result = c.phpglue_hash_index_find(self.hashTable(), idx);
        if (result) |zv| return Zval.fromPtr(zv);
        return null;
    }

    pub fn exists(self: *const Array, key: []const u8) bool {
        return c.phpglue_hash_str_exists(self.hashTable(), key.ptr, key.len) != 0;
    }

    pub fn existsIndex(self: *const Array, idx: T.zend_ulong) bool {
        return c.phpglue_hash_index_exists(self.hashTable(), idx) != 0;
    }

    // ＝＝ 删除 ＝＝

    pub fn del(self: *Array, key: []const u8) void {
        _ = c.phpglue_hash_str_del(self.hashTable(), key.ptr, key.len);
    }
    pub fn delIndex(self: *Array, idx: T.zend_ulong) void {
        _ = c.phpglue_hash_index_del(self.hashTable(), idx);
    }

    // ＝＝ 写时分离 ＝＝

    pub fn separate(self: *Array) void {
        c.phpglue_array_separate(self.zv.ptr);
    }

    // ＝＝ 追加元素（自动索引） ＝＝

    pub fn appendLong(self: *Array, v: T.zend_long) void             { c.phpglue_add_next_index_long(self.zv.ptr, v); }
    pub fn appendDouble(self: *Array, v: f64) void                   { c.phpglue_add_next_index_double(self.zv.ptr, v); }
    pub fn appendString(self: *Array, s: []const u8) void            { c.phpglue_add_next_index_stringl(self.zv.ptr, s.ptr, s.len); }
    pub fn appendBool(self: *Array, v: bool) void                    { c.phpglue_add_next_index_bool(self.zv.ptr, v); }
    pub fn appendNull(self: *Array) void                             { c.phpglue_add_next_index_null(self.zv.ptr); }
    pub fn appendZval(self: *Array, zv: Zval) void                   { c.phpglue_add_next_index_zval(self.zv.ptr, zv.ptr); }

    // ＝＝ 按数字索引设值 ＝＝

    pub fn setLong(self: *Array, idx: T.zend_ulong, v: T.zend_long) void     { c.phpglue_add_index_long(self.zv.ptr, idx, v); }
    pub fn setString(self: *Array, idx: T.zend_ulong, s: []const u8) void     { c.phpglue_add_index_stringl(self.zv.ptr, idx, s.ptr, s.len); }
    pub fn setBool(self: *Array, idx: T.zend_ulong, v: bool) void             { c.phpglue_add_index_bool(self.zv.ptr, idx, v); }

    // ＝＝ 按字符串键设值（关联数组） ＝＝

    pub fn setAssocLong(self: *Array, key: []const u8, v: T.zend_long) void   { c.phpglue_add_assoc_long(self.zv.ptr, key.ptr, v); }
    pub fn setAssocString(self: *Array, key: []const u8, s: []const u8) void   { c.phpglue_add_assoc_stringl(self.zv.ptr, key.ptr, s.ptr, s.len); }
    pub fn setAssocBool(self: *Array, key: []const u8, v: bool) void           { c.phpglue_add_assoc_bool(self.zv.ptr, key.ptr, v); }

    // ＝＝ 高级操作 ＝＝

    pub fn pop(self: *Array) ?Zval {
        var retval: T.Zval = undefined;
        if (c.phpglue_array_pop(self.zv.ptr, &retval) == 0) return null;
        return Zval.fromPtr(&retval);
    }

    // ＝＝ 队列 / 栈操作 ＝＝

    /// 移除并返回第一个元素（等价 PHP array_shift），空数组返回 null
    pub fn shift(self: *Array) ?Zval {
        var retval: T.Zval = undefined;
        if (c.phpglue_array_shift(self.zv.ptr, &retval) == 0) return null;
        return Zval.fromPtr(&retval);
    }

    /// 头部插入元素（等价 PHP array_unshift，数字键重索引）
    pub fn unshift(self: *Array, zv: Zval) void {
        c.phpglue_array_unshift(self.zv.ptr, zv.ptr);
    }

    // ＝＝ 集合操作 ＝＝

    /// 合并另一个数组，结果写入 out_zv（等价 PHP array_merge，本数组在前）
    pub fn merge(self: *Array, other: Array, out_zv: *T.Zval) void {
        c.phpglue_array_merge(out_zv, self.zv.ptr, other.zv.ptr);
    }

    /// 收集所有键到 out_zv（等价 PHP array_keys）
    pub fn keysInto(self: *Array, out_zv: *T.Zval) void {
        c.phpglue_array_keys(self.zv.ptr, out_zv);
    }

    /// 收集所有值到 out_zv（等价 PHP array_values，数字键重索引）
    pub fn valuesInto(self: *Array, out_zv: *T.Zval) void {
        c.phpglue_array_values(self.zv.ptr, out_zv);
    }

    /// 切片：从 offset 起取 len 个元素（len<0 表示到末尾），结果写入 out_zv
    pub fn sliceInto(self: *Array, out_zv: *T.Zval, offset: T.zend_long, len: T.zend_long) void {
        c.phpglue_array_slice(self.zv.ptr, out_zv, offset, len);
    }

    /// 值排序 + 重索引（等价 PHP sort()，原地修改）
    pub fn sort(self: *Array) void {
        c.phpglue_array_sort(self.zv.ptr);
    }

    pub fn iterator(self: *Array) Iterator {
        return Iterator.init(self.hashTable());
    }

    // ＝＝ foreach 遍历 ＝＝

    /// 遍历每个元素执行回调（不修改数组）。
    /// ctx 为可选上下文指针，回调内部可 `@ptrCast` 恢复成自己的状态类型，
    /// 从而在遍历过程中累积可变状态。
    ///
    /// ```zig
    /// const Ctx = struct { sum: i64 = 0 };
    /// var ctx = Ctx{};
    /// arr.each(&ctx, struct {
    ///     fn cb(ctx: ?*anyopaque, v: Zval) void {
    ///         const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    ///         c.sum += v.toLong();
    ///     }
    /// }.cb);
    /// ```
    pub fn each(self: *Array, ctx: ?*anyopaque, cb: fn (?*anyopaque, Zval) void) void {
        var iter = self.iterator();
        if (self.count() == 0) return;
        if (iter.value()) |v| cb(ctx, v);
        while (iter.next()) {
            if (iter.value()) |v| cb(ctx, v);
        }
    }

    // ＝＝ 数组算法（纯 Zig，无 C glue，结果落入调用者提供的 zval） ＝＝

    /// 过滤数组，结果写入 out_zv
    pub fn filterInto(self: *Array, out_zv: *T.Zval, comptime predicate: fn (Zval) bool) void {
        var result = Array.init(out_zv);
        var iter = self.iterator();
        if (self.count() == 0) return;
        if (iter.value()) |v| { if (predicate(v)) result.appendZval(v); }
        while (iter.next()) {
            if (iter.value()) |v| { if (predicate(v)) result.appendZval(v); }
        }
    }

    /// 映射数组，结果写入 out_zv
    pub fn mapInto(self: *Array, out_zv: *T.Zval, comptime T2: type, comptime transform: fn (Zval) T2) void {
        var result = Array.init(out_zv);
        var iter = self.iterator();
        if (self.count() == 0) return;
        if (iter.value()) |v| appendScalar(T2, &result, transform(v));
        while (iter.next()) {
            if (iter.value()) |v| appendScalar(T2, &result, transform(v));
        }
    }

    /// 归约数组，以 init 为初始值，combine 逐步合并
    pub fn reduce(self: *Array, comptime T2: type, initial: T2, comptime combine: fn (acc: T2, val: Zval) T2) T2 {
        var acc = initial;
        var iter = self.iterator();
        if (self.count() == 0) return acc;
        if (iter.value()) |v| acc = combine(acc, v);
        while (iter.next()) {
            if (iter.value()) |v| acc = combine(acc, v);
        }
        return acc;
    }
};

/// 将标量值根据类型追加到数组
fn appendScalar(comptime T2: type, arr: *Array, val: T2) void {
    switch (T2) {
        T.zend_long => arr.appendLong(val),
        f64         => arr.appendDouble(val),
        []const u8  => arr.appendString(val),
        bool        => arr.appendBool(val),
        Zval        => arr.appendZval(val),
        else        => @compileError("unsupported map return type"),
    }
}
