//! PHP INI 配置
//!
//! 声明式 INI 项注册与读取。注册在 MINIT 阶段由 Module 自动完成，
//! 读取通过 ini.getLong / getString / getBool。
//!
//! 设计：采用「无 globals」方案——INI 值由 Zend ini_entry->value 存储，
//! on_modify 仅触发变更通知，读取直接查 ini_entry->value（见 glue 实现）。

const c = @import("php_c.zig");
const T = @import("php_types.zig");
const std = @import("std");

/// INI 值类型
pub const IniType = c.IniType;
/// INI 可修改级别（对应 ZEND_INI_USER/PERDIR/SYSTEM/ALL）
pub const IniModifiable = c.IniModifiable;

/// INI 项描述符
pub const IniEntry = struct {
    name:          [:0]const u8,
    default_value: [:0]const u8,
    entry_type:    IniType        = .long,
    modifiable:    IniModifiable  = .all,

    pub fn createLong(name: [:0]const u8, default_value: [:0]const u8) IniEntry {
        return .{ .name = name, .default_value = default_value, .entry_type = .long };
    }
    pub fn createString(name: [:0]const u8, default_value: [:0]const u8) IniEntry {
        return .{ .name = name, .default_value = default_value, .entry_type = .string };
    }
    pub fn createBool(name: [:0]const u8, default_value: [:0]const u8) IniEntry {
        return .{ .name = name, .default_value = default_value, .entry_type = .bool };
    }
};

/// 读取 long 型 INI 值，未找到返回 dflt
pub fn getLong(name: []const u8, dflt: T.zend_long) T.zend_long {
    return c.phpglue_ini_get_long(name.ptr, name.len, dflt);
}

/// 读取 string 型 INI 值，未找到返回 null（返回内部字符串，勿释放）
pub fn getString(name: []const u8) ?[]const u8 {
    const p = c.phpglue_ini_get_string(name.ptr, name.len);
    if (p == null) return null;
    return std.mem.span(p);
}

/// 读取 bool 型 INI 值，未找到返回 dflt
pub fn getBool(name: []const u8, dflt: bool) bool {
    return c.phpglue_ini_get_bool(name.ptr, name.len, dflt);
}
