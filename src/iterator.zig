//! PHP 数组迭代器
//!
//! 基于 HashTable 内部指针的遍历接口。
//! 典型用法：reset → while(next) → 读取 key/value。
//!
//! 仅供 Array 内部使用，不对下游暴露裸迭代器。

const c = @import("php_c.zig");
const T = @import("php_types.zig");
const Zval = @import("zval.zig").Zval;

/// HashTable 迭代器 — 包装内部指针遍历
pub const Iterator = struct {
    ht: *T.ZendArray,

    /// 从 Array 构造迭代器（重置指针到开头）
    ///
    /// 空数组不做 reset——zend_hash_internal_pointer_reset 会置 pInternalPointer=NULL，
    /// 后续调用 zend_hash_move_forward 时 PHP 内部路径会越界。
    pub fn init(ht: *T.ZendArray) Iterator {
        if (c.phpglue_hash_num_elements(ht) > 0) {
            c.phpglue_hash_internal_pointer_reset(ht);
        }
        return .{ .ht = ht };
    }

    /// 前进到下一个元素，返回 false 表示遍历结束
    ///
    /// PHP SUCCESS = 0, FAILURE = -1，因此 == 0 表示移动成功
    pub fn next(self: *Iterator) bool {
        return c.phpglue_hash_move_forward(self.ht) == 0;
    }

    /// 获取当前元素的值，指针无效时返回 null
    pub fn value(self: *Iterator) ?Zval {
        const zv = c.phpglue_hash_get_current_data(self.ht);
        if (zv) |ptr| return Zval.fromPtr(ptr);
        return null;
    }
};
