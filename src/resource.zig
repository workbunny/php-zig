//! PHP 资源类型
//!
//! 将任意 Zig 指针包装为 PHP 资源，在 PHP 脚本中以 resource 类型表示。
//! 典型场景：数据库连接、文件句柄等需要在请求间持留的 C 指针。

const c = @import("php_c.zig");
const T = @import("php_types.zig");

/// 资源类型包装器
pub const Resource = struct {
    /// 资源类型 ID（全局唯一，在 MINIT 中注册获得）
    type_id: c_int,

    /// 注册新的资源类型，返回 Resource 实例
    pub fn register() Resource {
        return .{ .type_id = c.phpglue_register_resource_type() };
    }

    /// 将任意 Zig 指针存入 zval 作为 PHP 资源
    pub fn store(self: Resource, zv: *T.Zval, ptr: ?*anyopaque) void {
        c.phpglue_store_resource(zv, ptr, self.type_id);
    }

    /// 从 zval 中取出资源指针
    pub fn fetch(self: Resource, zv: *T.Zval) ?*anyopaque {
        return c.phpglue_fetch_resource(zv, self.type_id);
    }
};
