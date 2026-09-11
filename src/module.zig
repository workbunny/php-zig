//! PHP 模块注册
//!
//! comptime 泛型驱动的编译期模块生成，覆盖模块入口、函数注册、
//! 生命周期钩子、类与方法注册、参数 arg_info、常量注册、phpinfo 回调。
//!
//! 版本适配策略：所有 PHP 头文件常量（ZEND_ACC_*、zend_internal_arg_info 大小等）
//! 通过 C glue 运行时查询，不硬编码任何版本特定值。

const c = @import("php_c.zig");
const T = @import("php_types.zig");
const Cleanup = @import("cleanup.zig");
const Arena = @import("arena.zig");
const builtin = @import("builtin");
const std = @import("std");
const IniEntry = @import("ini.zig").IniEntry;
const ObserverConfig = @import("observer.zig").Config;

// ＝＝ Zend 结构体布局（extern struct，必须与 C 布局一致） ＝＝
// 字段顺序与 PHP 头文件定义严格对应。
// 具体字段布局随编译时 PHP 头文件版本而定，无需在此定义版本号。

pub const ZendFunctionEntry = extern struct {
    fname: [*c]const u8 = null,
    handler: ?T.FunctionHandler = null,
    arg_info: ?*anyopaque = null,
    num_args: u32 = 0,
    flags: u32 = 0,
    frameless_function_infos: ?*anyopaque = null,
    doc_comment: [*c]const u8 = null,
};

pub const ZendModuleEntry = extern struct {
    size: c_ushort = @sizeOf(ZendModuleEntry),
    zend_api: c_uint = 0,
    zend_debug: u8 = 0,
    zts: u8 = 0,
    ini_entry: ?*anyopaque = null,
    deps: ?*anyopaque = null,
    name: [*c]const u8 = null,
    functions: [*c]const ZendFunctionEntry = null,
    module_startup_func: ?T.ModuleLifecycleFn = null,
    module_shutdown_func: ?T.ModuleLifecycleFn = null,
    request_startup_func: ?T.ModuleLifecycleFn = null,
    request_shutdown_func: ?T.ModuleLifecycleFn = null,
    info_func: ?*const fn (zend_module: *ZendModuleEntry) callconv(.c) void = null,
    version: [*c]const u8 = null,
    globals_size: usize = 0,
    globals_ptr: ?*anyopaque = null,
    globals_ctor: ?*const fn (global: ?*anyopaque) callconv(.c) void = null,
    globals_dtor: ?*const fn (global: ?*anyopaque) callconv(.c) void = null,
    post_deactivate_func: ?*const fn () callconv(.c) c_int = null,
    module_started: c_int = 0,
    type: u8 = 0,
    handle: ?*anyopaque = null,
    module_number: c_int = 0,
    build_id: [*c]const u8 = null,
};

// ＝＝ arg_info 缓冲区常量 ＝＝
// 使用慷慨上限而非精确 sizeof(zend_internal_arg_info)，
// 在 initModule() 中运行时校验实际大小不超过上限。
// 上限 64 字节在 64 位系统上覆盖了所有已知 PHP 版本的 arg_info 结构。

const ARGINFO_ENTRY_SIZE_MAX: usize = 64;

// ＝＝ 参数描述符 ＝＝

/// PHP 类型标注枚举。值 0~6 与 C glue phpglue_fill_arg_info_typed 约定一致。
pub const ParamType = enum(u8) {
    mixed = 0, // 无类型提示
    long = 1,
    double = 2,
    string = 3,
    bool = 4,
    array = 5,
    object = 6,
};

// ＝＝＝＝ PHP 类型位掩码（PhpType）＝＝＝＝
//
// 直接对应 Zend 的 MAY_BE_*，用位组合表达联合类型（`int|string`），
// 这是 enum(u8) 的 ParamType 做不到的——它只能表达单一类型。
//
// 位值由 glue/php_glue.c 顶部的 _Static_assert 守护：PHP 若调整 MAY_BE_*
// 布局，编译期即失败，不会产生「类型约束静默失效」这种比崩溃更难查的问题。

pub const PhpType = packed struct(u32) {
    mask: u32,

    /// 无约束（mixed / 不检查）
    pub const any = PhpType{ .mask = 0 };

    // — 基础类型 —
    pub const null_ = PhpType{ .mask = 1 << 1 }; // IS_NULL
    pub const false_ = PhpType{ .mask = 1 << 2 }; // IS_FALSE
    pub const true_ = PhpType{ .mask = 1 << 3 }; // IS_TRUE
    pub const long = PhpType{ .mask = 1 << 4 };
    pub const double = PhpType{ .mask = 1 << 5 };
    pub const string = PhpType{ .mask = 1 << 6 };
    pub const array = PhpType{ .mask = 1 << 7 };
    pub const object = PhpType{ .mask = 1 << 8 };
    pub const resource = PhpType{ .mask = 1 << 9 };

    // — 便捷组合（纯语法糖，不含额外语义）—
    /// bool：false|true。注意 PHP 的 bool 是两个独立类型的联合
    pub const bool_ = false_.unionWith(true_);
    /// 数值：int|float
    pub const number = long.unionWith(double);
    /// 全部基础类型
    pub const any_typed = PhpType{ .mask = 0x3FF };

    // — 伪类型：位值不落在基础类型区间，由 Zend 特殊处理 —
    pub const callable = PhpType{ .mask = 1 << 12 };
    pub const iterable = PhpType{ .mask = 1 << 21 };

    /// 组合出联合类型：`PhpType.string.unionWith(PhpType.long)` → `string|int`
    /// 链式即可表达多项：`a.unionWith(b).unionWith(c)`
    ///
    /// 方法名不能用 `or`——它是 Zig 保留字。
    pub fn unionWith(self: PhpType, other: PhpType) PhpType {
        return .{ .mask = self.mask | other.mask };
    }

    /// 允许 null。PHP 的 `?int` 与 `int|null` 完全等价——
    /// MAY_BE_NULL 位与 _ZEND_TYPE_NULLABLE_BIT 同值，故此处无需区分。
    pub fn nullable(self: PhpType) PhpType {
        return self.unionWith(null_);
    }
};

/// Zig 类型 → PHP 类型位掩码（供 arg_info 生成与联合类型补齐共用）
pub fn zigTypeToPhpMask(comptime Z: type) PhpType {
    const info = @typeInfo(Z);
    if (info == .optional) {
        return zigTypeToPhpMask(info.optional.child).nullable();
    }
    return switch (Z) {
        i64, u64, i32, u32, i16, u16, i8, u8, isize, usize => PhpType.long,
        f64, f32 => PhpType.double,
        bool => PhpType.bool_,
        []const u8, [:0]const u8, []u8 => PhpType.string,
        // mixed：不生成类型约束，值原样进 handler（unsafe 路径，保留）
        *T.Zval, ?*T.Zval => PhpType.any,
        *const T.Zval => PhpType.any,
        else => @compileError("Unsupported comptime arg type: " ++ @typeName(Z)),
    };
}

pub const ParamDesc = struct {
    name: [:0]const u8,
    param_type: ParamType = .mixed,
    allow_null: bool = false,
    /// PHP 类型位掩码（MAY_BE_*）。非零时优先于 param_type，用于表达
    /// `int|string` 这类联合类型——param_type 只能表达单一类型。
    type_mask: u32 = 0,
    /// 是否为可变参数（...$args），仅对最后一个参数有意义
    is_variadic: bool = false,
    /// 默认值源码字符串（如 "NULL"、"0"、"[]"），null 表示无默认值
    default_value: ?[:0]const u8 = null,

    /// 声明式构造（兼容旧版，无类型标注）
    pub fn create(name: [:0]const u8) ParamDesc {
        return .{ .name = name };
    }
    /// 声明式构造 + 类型标注
    pub fn createTyped(name: [:0]const u8, pt: ParamType) ParamDesc {
        return .{ .name = name, .param_type = pt };
    }
    /// 声明式构造 + 位掩码类型（支持联合类型）
    pub fn createMasked(name: [:0]const u8, mask: PhpType) ParamDesc {
        return .{ .name = name, .type_mask = mask.mask };
    }
    /// 声明式构造 + 类型标注 + nullable
    pub fn createNullable(name: [:0]const u8, pt: ParamType) ParamDesc {
        return .{ .name = name, .param_type = pt, .allow_null = true };
    }
    /// 可变参数（无类型标注的 ...$args）
    pub fn createVariadic(name: [:0]const u8) ParamDesc {
        return .{ .name = name, .is_variadic = true };
    }
    /// 可变参数 + 类型标注（...$args 带类型提示）
    pub fn createVariadicTyped(name: [:0]const u8, pt: ParamType) ParamDesc {
        return .{ .name = name, .param_type = pt, .is_variadic = true };
    }
    /// 带默认值（默认值以 PHP 源码字符串形式给出，如 "0"、"\"str\""、"[]"）
    pub fn createWithDefault(name: [:0]const u8, default_value: [:0]const u8) ParamDesc {
        return .{ .name = name, .default_value = default_value };
    }
    /// 类型标注 + 默认值
    pub fn createTypedWithDefault(name: [:0]const u8, pt: ParamType, default_value: [:0]const u8) ParamDesc {
        return .{ .name = name, .param_type = pt, .default_value = default_value };
    }
};

/// comptime：Zig 类型 → PHP 参数类型 + allow_null
/// ?i64 → { .long, allow_null=true }; ?[]const u8 → { .string, allow_null=true }
pub fn zigTypeToPhpType(comptime Z: type) struct { pt: ParamType, an: bool } {
    const info = @typeInfo(Z);
    if (info == .optional) {
        const inner = zigTypeToPhpType(info.optional.child);
        return .{ .pt = inner.pt, .an = true };
    }
    return switch (Z) {
        i64, u64, i32, u32, isize, usize => .{ .pt = .long, .an = false },
        f64, f32 => .{ .pt = .double, .an = false },
        bool => .{ .pt = .bool, .an = false },
        []const u8, [:0]const u8 => .{ .pt = .string, .an = false },
        *T.Zval => .{ .pt = .mixed, .an = false },
        else => @compileError("Unsupported comptime arg type: " ++ @typeName(Z)),
    };
}

// ＝＝ 函数 / 方法描述符 ＝＝
//
// flags 字段不提供 comptime 默认值 —— 实际值由 init*Entries 在运行时
// 从 C glue 获取，确保与编译时 PHP 头文件的 ZEND_ACC_* 一致。

pub const FunctionDesc = struct {
    name: [:0]const u8,
    handler: T.FunctionHandler,
    arg_info: ?*anyopaque = null,
    /// 运行时标志位（0 表示 init 时自动从 C glue 获取）：
    ///   PUBLIC=0 — 模块级函数用 ACC_PUBLIC；类方法用 ACC_PUBLIC；
    ///   STATIC  — 类静态方法用 ACC_PUBLIC|ACC_STATIC
    ///   PROTECTED_MARKER — ACC_PUBLIC|ACC_PROTECTED
    ///   PRIVATE_MARKER   — ACC_PUBLIC|ACC_PRIVATE
    flags: u32 = 0,
    params: []const ParamDesc = &.{},

    pub fn create(name: [:0]const u8, handler: T.FunctionHandler) FunctionDesc {
        return .{ .name = name, .handler = handler };
    }
    pub fn createWithArgInfo(name: [:0]const u8, handler: T.FunctionHandler, arg_info: ?*anyopaque) FunctionDesc {
        return .{ .name = name, .handler = handler, .arg_info = arg_info };
    }
    pub fn createStatic(name: [:0]const u8, handler: T.FunctionHandler) FunctionDesc {
        return .{ .name = name, .handler = handler, .flags = Marker.static_marker };
    }
    pub fn createWithParams(name: [:0]const u8, handler: T.FunctionHandler, params: []const ParamDesc) FunctionDesc {
        return .{ .name = name, .handler = handler, .params = params };
    }
    pub fn createStaticWithParams(name: [:0]const u8, handler: T.FunctionHandler, params: []const ParamDesc) FunctionDesc {
        return .{ .name = name, .handler = handler, .params = params, .flags = Marker.static_marker };
    }

    /// 反射 + 显式补齐。`overrides` 是匿名 struct，字段名对应 Args 的字段。
    ///
    /// 用于 Zig 类型无法表达的场合：
    /// ```zig
    /// const Args = struct { key: *T.Zval };
    /// createFromWith("f", f, Args, .{
    ///     .key = PhpType.long.unionWith(PhpType.string),   // int|string
    /// })
    /// ```
    ///
    /// 编译期校验，均为「显式报错」而非静默失效：
    ///  1. overrides 的字段必须在 Args 中存在（防拼写错误）
    ///  2. overrides 中出现的字段在 Args 中必须是 `*T.Zval`（mixed）类型
    ///     —— 与反射结果冲突说明意图不清，静默选一个会埋雷
    ///
    /// `handler` 不声明 comptime：它常由 `@ptrCast(&fn)` 得到，
    /// 标 comptime 会导致「unable to resolve comptime value」。
    pub fn createFromWith(
        comptime name: [:0]const u8,
        handler: T.FunctionHandler,
        comptime Args: type,
        comptime overrides: anytype,
    ) FunctionDesc {
        const info = @typeInfo(Args);
        if (info != .@"struct") @compileError("createFromWith expects a struct, got " ++ @typeName(Args));
        const fields = info.@"struct".fields;

        // 校验：overrides 的字段必须存在，且对应字段是 mixed（*T.Zval）。
        // 反射已能推出类型的字段不允许再覆盖——声明与反射冲突说明意图不清，
        // 静默选一个会埋雷，故显式编译错误。
        inline for (@typeInfo(@TypeOf(overrides)).@"struct".fields) |of| {
            var found = false;
            inline for (fields) |af| {
                if (std.mem.eql(u8, af.name, of.name)) {
                    found = true;
                    if (zigTypeToPhpMask(af.type).mask != 0) {
                        @compileError("createFromWith: field '" ++ af.name ++
                            "' already has a reflected type; overrides are only for mixed (*T.Zval) fields");
                    }
                }
            }
            if (!found) {
                @compileError("createFromWith: override field '" ++ of.name ++
                    "' does not exist in " ++ @typeName(Args));
            }
        }

        return .{ .name = name, .handler = handler, .params = comptime paramsFromStructWithOverrides(Args, overrides) };
    }

    /// comptime struct 反射 — 从 struct 字段名和类型自动推导 arg_info。
    ///
    /// ```zig
    /// const AddArgs = struct { a: i64, b: i64, name: []const u8 };
    /// const funcs = &.{ FunctionDesc.createFrom("my_add", my_add, AddArgs) };
    /// ```
    ///
    /// 字段顺序 = 参数顺序，字段名 = 参数名，字段类型 → PHP 类型标注。
    /// ?T 类型自动映射为 allow_null。
    ///
    /// 需要联合类型时用 `createFromWith` 补齐。
    pub fn createFrom(comptime name: [:0]const u8, handler: T.FunctionHandler, comptime Args: type) FunctionDesc {
        return createFromWith(name, handler, Args, .{});
    }

    /// createFrom 的静态方法版本
    pub fn createStaticFrom(comptime name: [:0]const u8, handler: T.FunctionHandler, comptime Args: type) FunctionDesc {
        return .{
            .name = name,
            .handler = handler,
            .params = comptime paramsFromStruct(Args),
            .flags = Marker.static_marker,
        };
    }

    pub fn createProtected(name: [:0]const u8, handler: T.FunctionHandler) FunctionDesc {
        return .{ .name = name, .handler = handler, .flags = Marker.protected_marker };
    }
    pub fn createProtectedWithParams(name: [:0]const u8, handler: T.FunctionHandler, params: []const ParamDesc) FunctionDesc {
        return .{ .name = name, .handler = handler, .params = params, .flags = Marker.protected_marker };
    }
    pub fn createPrivate(name: [:0]const u8, handler: T.FunctionHandler) FunctionDesc {
        return .{ .name = name, .handler = handler, .flags = Marker.private_marker };
    }
    pub fn createPrivateWithParams(name: [:0]const u8, handler: T.FunctionHandler, params: []const ParamDesc) FunctionDesc {
        return .{ .name = name, .handler = handler, .params = params, .flags = Marker.private_marker };
    }
};

/// 哨兵常量 — 用于区分"用户未设置 flags"和"用户设了 PUBLIC"
const Marker = struct {
    const publicz_marker: u32 = 0xDEADBEE0;
    const static_marker: u32 = 0xDEADBEEF;
    const protected_marker: u32 = 0xDEADBEF0;
    const private_marker: u32 = 0xDEADBEF1;
};

/// ParamDesc → MAY_BE_* 掩码。
/// type_mask 非零时优先（联合类型）；否则由 ParamType 枚举折算，
/// 有 allow_null 时补上 MAY_BE_NULL 位。
fn paramMask(p: ParamDesc) u32 {
    if (p.type_mask != 0) return p.type_mask;
    var m: u32 = switch (p.param_type) {
        .long => PhpType.long.mask,
        .double => PhpType.double.mask,
        .string => PhpType.string.mask,
        .bool => PhpType.bool_.mask,
        .array => PhpType.array.mask,
        .object => PhpType.object.mask,
        .mixed => 0,
    };
    if (p.allow_null) m |= PhpType.null_.mask;
    return m;
}

/// comptime：从 struct 类型反射出 []const ParamDesc
fn paramsFromStruct(comptime Args: type) []const ParamDesc {
    const info = @typeInfo(Args);
    if (info != .@"struct") @compileError("createFrom expects a struct, got " ++ @typeName(Args));
    const fields = info.@"struct".fields;
    const params: [fields.len]ParamDesc = blk: {
        var arr: [fields.len]ParamDesc = undefined;
        inline for (fields, 0..) |field, i| {
            const ti = zigTypeToPhpType(field.type);
            arr[i] = ParamDesc{
                .name = field.name,
                .param_type = ti.pt,
                .allow_null = ti.an,
                .type_mask = zigTypeToPhpMask(field.type).mask,
            };
        }
        break :blk arr;
    };
    return &params;
}

/// comptime：反射 + overrides 补齐。overrides 中出现的字段用其位掩码，
/// 其余字段走反射。所有校验已在 createFromWith 中完成。
fn paramsFromStructWithOverrides(comptime Args: type, comptime overrides: anytype) []const ParamDesc {
    const info = @typeInfo(Args);
    if (info != .@"struct") @compileError("createFromWith expects a struct, got " ++ @typeName(Args));
    const fields = info.@"struct".fields;
    const ov_fields = @typeInfo(@TypeOf(overrides)).@"struct".fields;

    const params: [fields.len]ParamDesc = blk: {
        var arr: [fields.len]ParamDesc = undefined;
        inline for (fields, 0..) |field, i| {
            var mask = zigTypeToPhpMask(field.type).mask;
            // overrides 优先：找到同名字段就用其掩码（仅 mixed 字段会走到这里）
            inline for (ov_fields) |of| {
                if (comptime std.mem.eql(u8, field.name, of.name)) {
                    mask = @field(overrides, of.name).mask;
                }
            }
            const ti = zigTypeToPhpType(field.type);
            arr[i] = ParamDesc{
                .name = field.name,
                .param_type = ti.pt,
                .allow_null = ti.an,
                .type_mask = mask,
            };
        }
        break :blk arr;
    };
    return &params;
}

/// comptime：从 struct 类型反射出 []const ClassPropertyDesc
fn propsFromStruct(comptime Props: type) []const ClassPropertyDesc {
    const info = @typeInfo(Props);
    if (info != .@"struct") @compileError("createWithPropsFrom expects a struct, got " ++ @typeName(Props));
    const fields = info.@"struct".fields;
    const props: [fields.len]ClassPropertyDesc = blk: {
        var arr: [fields.len]ClassPropertyDesc = undefined;
        inline for (fields, 0..) |field, i| {
            const dv = switch (field.type) {
                i64, u64, i32, u32, isize, usize => ClassPropertyDesc.ClassPropertyValue{
                    .long = if (field.default_value_ptr) |dv_ptr|
                        @as(*const i64, @ptrCast(@alignCast(dv_ptr))).*
                    else
                        @as(T.zend_long, 0),
                },
                f64, f32 => ClassPropertyDesc.ClassPropertyValue{
                    .double = if (field.default_value_ptr) |dv_ptr|
                        @floatCast(@as(*const f64, @ptrCast(@alignCast(dv_ptr))).*)
                    else
                        @as(f64, 0.0),
                },
                bool => ClassPropertyDesc.ClassPropertyValue{
                    .bool = if (field.default_value_ptr) |dv_ptr|
                        @as(*const bool, @ptrCast(@alignCast(dv_ptr))).*
                    else
                        false,
                },
                []const u8, [:0]const u8 => bk2: {
                    if (field.default_value_ptr) |dv_ptr| {
                        const s = @as(*const []const u8, @ptrCast(@alignCast(dv_ptr))).*;
                        break :bk2 ClassPropertyDesc.ClassPropertyValue{
                            .string = s.ptr[0..s.len :0],
                        };
                    }
                    break :bk2 ClassPropertyDesc.ClassPropertyValue{ .string = "" };
                },
                else => unreachable,
            };
            arr[i] = ClassPropertyDesc{
                .name = field.name,
                .value = dv,
                .access = 0, // PUBLIC
            };
        }
        break :blk arr;
    };
    return &props;
}

// ＝＝ Comptime struct → FunctionDesc[]：从 struct 内 `pub fn` 声明自动推导方法注册 ＝＝
//
// 命名约定：
//   public_xxx       → ACC_PUBLIC    function xxx
//   protect_xxx      → ACC_PROTECTED function xxx
//   private_xxx      → ACC_PRIVATE   function xxx
//   static_xxx       → ACC_PUBLIC|ACC_STATIC function xxx
//
// 魔术方法映射（magic_ 前缀）：
//   magic_set → __set, magic_get → __get, magic_call → __call,
//   magic_tostring → __tostring, magic_construct → __construct 等

pub fn methodsFromStruct(comptime Cls: type) []const FunctionDesc {
    const info = @typeInfo(Cls);
    if (info != .@"struct") @compileError("Expected struct, got " ++ @typeName(Cls));
    const decls = info.@"struct".decls;

    // 只统计匹配命名约定的声明
    comptime var count = 0;
    inline for (decls) |d| {
        if (std.mem.startsWith(u8, d.name, "public_") or std.mem.startsWith(u8, d.name, "protect_") or
            std.mem.startsWith(u8, d.name, "private_") or std.mem.startsWith(u8, d.name, "static_"))
            count += 1;
    }

    const methods: [count]FunctionDesc = blk: {
        var arr: [count]FunctionDesc = undefined;
        comptime var idx = 0;
        inline for (decls) |d| {
            if (!(std.mem.startsWith(u8, d.name, "public_") or std.mem.startsWith(u8, d.name, "protect_") or
                std.mem.startsWith(u8, d.name, "private_") or std.mem.startsWith(u8, d.name, "static_")))
                continue;

            const name = d.name;
            const handler: T.FunctionHandler = @ptrCast(@alignCast(&@field(Cls, name)));

            // 1. 确定前缀
            const prefix: []const u8 = if (std.mem.startsWith(u8, name, "public_")) "public_" else if (std.mem.startsWith(u8, name, "protect_")) "protect_" else if (std.mem.startsWith(u8, name, "private_")) "private_" else if (std.mem.startsWith(u8, name, "static_")) "static_" else @compileError("BUG: " ++ name);

            // 2. 去掉前缀
            const rest: [:0]const u8 = name[prefix.len..];
            const php_name: [:0]const u8 = if (std.mem.eql(u8, rest, "magic_construct")) "__construct" else if (std.mem.eql(u8, rest, "magic_destruct")) "__destruct" else if (std.mem.eql(u8, rest, "magic_call")) "__call" else if (std.mem.eql(u8, rest, "magic_callStatic")) "__callStatic" else if (std.mem.eql(u8, rest, "magic_get")) "__get" else if (std.mem.eql(u8, rest, "magic_set")) "__set" else if (std.mem.eql(u8, rest, "magic_isset")) "__isset" else if (std.mem.eql(u8, rest, "magic_unset")) "__unset" else if (std.mem.eql(u8, rest, "magic_sleep")) "__sleep" else if (std.mem.eql(u8, rest, "magic_wakeup")) "__wakeup" else if (std.mem.eql(u8, rest, "magic_toString")) "__toString" else if (std.mem.eql(u8, rest, "magic_invoke")) "__invoke" else if (std.mem.eql(u8, rest, "magic_set_state")) "__set_state" else if (std.mem.eql(u8, rest, "magic_clone")) "__clone" else if (std.mem.eql(u8, rest, "magic_debugInfo")) "__debugInfo" else if (std.mem.eql(u8, rest, "magic_serialize")) "__serialize" else if (std.mem.eql(u8, rest, "magic_unserialize")) "__unserialize" else if (std.mem.startsWith(u8, rest, "magic_")) @compileError("Unknown magic method: " ++ rest) else rest;

            // 4. 确定 flags
            const f: u32 = if (std.mem.eql(u8, prefix, "public_")) Marker.publicz_marker else if (std.mem.eql(u8, prefix, "protect_")) Marker.protected_marker else if (std.mem.eql(u8, prefix, "private_")) Marker.private_marker else Marker.static_marker;

            arr[idx] = FunctionDesc{ .name = php_name, .handler = handler, .flags = f };
            idx += 1;
        }
        break :blk arr;
    };
    return &methods;
}

// ＝＝ 类属性描述符 ＝＝

pub const PropertyType = enum(u8) {
    long = 0,
    double = 1,
    string = 2,
    bool = 3,
    null_ = 4,
};

pub const ClassPropertyDesc = struct {
    name: [:0]const u8,
    value: ClassPropertyValue,
    /// ZEND_ACC_* 组合——由 C glue 运行时查询，不硬编码
    access: u32 = 0, // 0 = init 时自动设为 ACC_PUBLIC

    pub const ClassPropertyValue = union(enum) {
        long: T.zend_long,
        double: f64,
        string: [:0]const u8,
        bool: bool,
        null_: void,
    };

    pub fn createLong(name: [:0]const u8, v: T.zend_long) ClassPropertyDesc {
        return .{ .name = name, .value = .{ .long = v } };
    }
    pub fn createDouble(name: [:0]const u8, v: f64) ClassPropertyDesc {
        return .{ .name = name, .value = .{ .double = v } };
    }
    pub fn createString(name: [:0]const u8, v: [:0]const u8) ClassPropertyDesc {
        return .{ .name = name, .value = .{ .string = v } };
    }
    pub fn createBool(name: [:0]const u8, v: bool) ClassPropertyDesc {
        return .{ .name = name, .value = .{ .bool = v } };
    }
    pub fn createNull(name: [:0]const u8) ClassPropertyDesc {
        return .{ .name = name, .value = .{ .null_ = {} } };
    }

    pub fn makeStatic(self: ClassPropertyDesc) ClassPropertyDesc {
        return .{ .name = self.name, .value = self.value, .access = 1 }; // 1 = static marker
    }
    pub fn makeProtected(self: ClassPropertyDesc) ClassPropertyDesc {
        return .{ .name = self.name, .value = self.value, .access = 2 }; // 2 = protected marker
    }
    pub fn makePrivate(self: ClassPropertyDesc) ClassPropertyDesc {
        return .{ .name = self.name, .value = self.value, .access = 3 }; // 3 = private marker
    }
};

// ＝＝ 对象绑定（extern struct） ＝＝

/// 对象额外数据（Zig struct）的生命周期回调签名
pub const ObjectDataFn = *const fn (extra: ?*anyopaque) callconv(.c) void;

/// 对象绑定描述：extra_size 为每个对象分配的 Zig struct 字节数，
/// init/dtor 在对象创建/销毁时回调。
pub const ObjectBinding = struct {
    extra_size: usize,
    init: ?ObjectDataFn = null,
    dtor: ?ObjectDataFn = null,
};

// ＝＝ 类描述符 ＝＝

pub const ClassDesc = struct {
    name: [:0]const u8,
    methods: []const FunctionDesc,
    parent_name: ?[:0]const u8 = null,
    class_constants: []const ClassConstantDesc = &.{},
    properties: []const ClassPropertyDesc = &.{},
    /// 是否为接口（true 时用 zend_register_internal_interface 注册）
    is_interface: bool = false,
    /// 要实现的接口名列表（须先于本类注册）
    interfaces: []const [:0]const u8 = &.{},
    /// 对象绑定（extern struct）：非 null 时用自定义 create_object 注册
    object_binding: ?ObjectBinding = null,

    pub fn create(name: [:0]const u8, methods: []const FunctionDesc) ClassDesc {
        return .{ .name = name, .methods = methods };
    }
    /// 注册带 Zig struct 数据区的对象类（extern struct 绑定）。
    /// Data 为绑定到每个对象的 Zig struct 类型，init/dtor 为可选生命周期回调。
    pub fn createObject(name: [:0]const u8, methods: []const FunctionDesc, comptime Data: type, init: ?ObjectDataFn, dtor: ?ObjectDataFn) ClassDesc {
        return .{
            .name = name,
            .methods = methods,
            .object_binding = .{
                .extra_size = @sizeOf(Data),
                .init = init,
                .dtor = dtor,
            },
        };
    }
    pub fn createExtends(name: [:0]const u8, parent: [:0]const u8, methods: []const FunctionDesc) ClassDesc {
        return .{ .name = name, .methods = methods, .parent_name = parent };
    }
    /// 注册接口
    pub fn createInterface(name: [:0]const u8, methods: []const FunctionDesc) ClassDesc {
        return .{ .name = name, .methods = methods, .is_interface = true };
    }
    /// 注册类并实现指定接口（接口须先声明）
    pub fn createImplements(name: [:0]const u8, methods: []const FunctionDesc, interfaces: []const [:0]const u8) ClassDesc {
        return .{ .name = name, .methods = methods, .interfaces = interfaces };
    }
    pub fn createWithConstants(name: [:0]const u8, methods: []const FunctionDesc, constants: []const ClassConstantDesc) ClassDesc {
        return .{ .name = name, .methods = methods, .class_constants = constants };
    }
    pub fn createWithProperties(name: [:0]const u8, methods: []const FunctionDesc, props: []const ClassPropertyDesc) ClassDesc {
        return .{ .name = name, .methods = methods, .properties = props };
    }

    /// comptime struct 反射类属性——从 struct 字段名、类型和默认值自动推导 ClassPropertyDesc。
    ///
    /// ```zig
    /// const BankProps = struct {
    ///     balance: i64 = 0,
    ///     open: bool = true,
    /// };
    /// ClassDesc.createWithPropsFrom("Bank", &.{_}, BankProps)
    /// ```
    ///
    /// 字段顺序 = 属性声明顺序，字段名 = 属性名，
    /// 字段类型 → PropertyType，字段默认值 → 属性默认值。
    pub fn createWithPropsFrom(comptime name: [:0]const u8, methods: []const FunctionDesc, comptime Props: type) ClassDesc {
        return .{
            .name = name,
            .methods = methods,
            .properties = comptime propsFromStruct(Props),
        };
    }

    /// 完全 comptime 驱动的类注册：struct 内 `pub fn` 声明 → PHP 方法，
    /// struct 字段 → PHP 属性。方法 + 属性的名称/类型/可见性全部编译期推导。
    ///
    /// 命名约定：
    ///   public_xxx  → public function xxx
    ///   protect_xxx → protected function xxx
    ///   private_xxx → private function xxx
    ///   static_xxx  → public static function xxx
    ///   *_magic_xxx → __xxx（魔术方法）
    ///
    /// struct 字段：balance: i64 = 0 → public long 属性，默认值 0
    pub fn createFromStruct(comptime name: [:0]const u8, comptime Cls: type) ClassDesc {
        return .{
            .name = name,
            .methods = comptime methodsFromStruct(Cls),
            .properties = comptime propsFromStruct(Cls),
        };
    }
};

// ＝＝ 类常量描述符 ＝＝

pub const ClassConstantDesc = struct {
    name: [:0]const u8,
    value: ClassConstantValue,

    pub const ClassConstantValue = union(enum) {
        long: T.zend_long,
        string: [:0]const u8,
    };

    pub fn createLong(name: [:0]const u8, v: T.zend_long) ClassConstantDesc {
        return .{ .name = name, .value = .{ .long = v } };
    }
    pub fn createString(name: [:0]const u8, v: [:0]const u8) ClassConstantDesc {
        return .{ .name = name, .value = .{ .string = v } };
    }
};

// ＝＝ 常量描述符 ＝＝

pub const ConstantDesc = struct {
    name: [:0]const u8,
    value: ConstantValue,

    pub const ConstantValue = union(enum) {
        long: T.zend_long,
        double: f64,
        string: [:0]const u8,
        bool: bool,
        null_: void,
    };

    pub fn createLong(name: [:0]const u8, v: T.zend_long) ConstantDesc {
        return .{ .name = name, .value = .{ .long = v } };
    }
    pub fn createDouble(name: [:0]const u8, v: f64) ConstantDesc {
        return .{ .name = name, .value = .{ .double = v } };
    }
    pub fn createString(name: [:0]const u8, v: [:0]const u8) ConstantDesc {
        return .{ .name = name, .value = .{ .string = v } };
    }
    pub fn createBool(name: [:0]const u8, v: bool) ConstantDesc {
        return .{ .name = name, .value = .{ .bool = v } };
    }
    pub fn createNull(name: [:0]const u8) ConstantDesc {
        return .{ .name = name, .value = .{ .null_ = {} } };
    }
};

// ＝＝ 模块入口 ＝＝

/// 模块配置项 — 供 `Module()` 与 `moduleInit()` 共用。
/// 通过 `moduleInit()` 注册时，开发者无需手动 `@export(get_module)`。
pub const ModuleOptions = struct {
    name: [:0]const u8,
    version: [:0]const u8,
    functions: []const FunctionDesc = &.{},
    minit: ?T.ModuleLifecycleFn = null,
    mshutdown: ?T.ModuleLifecycleFn = null,
    rinit: ?T.ModuleLifecycleFn = null,
    rshutdown: ?T.ModuleLifecycleFn = null,
    classes: []const ClassDesc = &.{},
    constants: []const ConstantDesc = &.{},
    /// INI 项列表（MINIT 自动注册，MSHUTDOWN 自动注销）
    ini: []const IniEntry = &.{},
    /// INI 变更通知回调（任一 INI 项值变更时触发，name 为 C 字符串 + 长度）
    ini_notify: ?*const fn (name: [*c]const u8, name_len: usize) callconv(.c) void = null,
    info_func: ?*const fn (module: *ZendModuleEntry) callconv(.c) void = null,
    /// Observer 观察点配置（MINIT 一次性静态注册）
    observer: ?ObserverConfig = null,
};

/// 模块元信息 — 供 `moduleInit(@This(), meta)` 使用。
/// 函数与类通过命名约定从当前文件自动发现，复杂场景（继承/接口/常量/对象绑定）
/// 用 `functions`/`classes` 显式补充，两者合并注册。
pub const ModuleMeta = struct {
    name: [:0]const u8,
    version: [:0]const u8,
    minit: ?T.ModuleLifecycleFn = null,
    mshutdown: ?T.ModuleLifecycleFn = null,
    rinit: ?T.ModuleLifecycleFn = null,
    rshutdown: ?T.ModuleLifecycleFn = null,
    constants: []const ConstantDesc = &.{},
    ini: []const IniEntry = &.{},
    ini_notify: ?*const fn (name: [*c]const u8, name_len: usize) callconv(.c) void = null,
    info_func: ?*const fn (module: *ZendModuleEntry) callconv(.c) void = null,
    /// 显式补充的函数（与自动发现合并，用于有参/复杂签名）
    functions: []const FunctionDesc = &.{},
    /// 显式补充的类（与自动发现合并，用于继承/接口/常量/对象绑定等复杂场景）
    classes: []const ClassDesc = &.{},
    /// Observer 观察点配置（MINIT 一次性静态注册）
    observer: ?ObserverConfig = null,
};

/// comptime 校验：拦截**语义错误**（Zend/PHP 层面本就不合法的写法），
/// 在编译期暴露，避免留到运行时才崩。
///
/// 边界：只校验 Zend 确实不允许的写法，**不引入任何 Zend 没有的数量上限**
/// （参数/属性/常量/INI 的个数 Zend 均不限制，故此处同样不限制）。
fn validateOptions(comptime opts: ModuleOptions) void {
    if (opts.name.len == 0) @compileError("module name must not be empty");
    if (opts.version.len == 0) @compileError("module version must not be empty");

    inline for (opts.ini) |e| {
        if (e.name.len == 0) @compileError("INI entry name must not be empty");
    }
    inline for (opts.constants) |cst| {
        if (cst.name.len == 0) @compileError("constant name must not be empty");
    }
    inline for (opts.functions) |f| validateFunction(f);
    inline for (opts.classes) |cls| {
        if (cls.name.len == 0) @compileError("class name must not be empty");
        inline for (cls.class_constants) |cst| {
            if (cst.name.len == 0) @compileError("class constant name must not be empty");
        }
        inline for (cls.properties) |prop| {
            if (prop.name.len == 0) @compileError("class property name must not be empty");
        }
        inline for (cls.methods) |m| validateFunction(m);
    }
}

fn validateFunction(comptime f: FunctionDesc) void {
    if (f.name.len == 0) @compileError("function/method name must not be empty");
    inline for (f.params, 0..) |p, i| {
        if (p.name.len == 0) {
            @compileError(std.fmt.comptimePrint(
                "function '{s}' param #{d} has empty name",
                .{ f.name, i + 1 },
            ));
        }
        // 重复参数名会让 PHP 侧静默异常，编译期拦住
        inline for (f.params[0..i]) |q| {
            if (std.mem.eql(u8, p.name, q.name)) {
                @compileError(std.fmt.comptimePrint(
                    "function '{s}' has duplicate param name '{s}'",
                    .{ f.name, p.name },
                ));
            }
        }
        // variadic 必须是最后一个参数，否则违反 PHP 语义
        if (p.is_variadic and i != f.params.len - 1) {
            @compileError(std.fmt.comptimePrint(
                "function '{s}': variadic param '{s}' must be the last param",
                .{ f.name, p.name },
            ));
        }
    }
}

pub fn Module(comptime opts: ModuleOptions) type {
    comptime validateOptions(opts);

    // 各维度缓冲**不再需要此处计算**：参数由 resolveArgInfo 按该函数自身精确分配，
    // 类常量/属性由 registerClassFull 按该类自身精确分配，INI 按实际项数分配。
    // Zend 对参数 / 属性 / 类常量 / INI 的个数均不设上限，本项目同样不设
    // （此前固定 8/8/64 属自造限制，已移除）。

    const total_class_methods = comptime blk: {
        var n: usize = 0;
        for (opts.classes) |cls| n += cls.methods.len + 1;
        break :blk n;
    };

    const total_param_entries = comptime blk: {
        var n: usize = 0;
        for (opts.functions) |f| {
            if (f.params.len > 0) n += f.params.len + 2; // header + N params + sentinel
        }
        for (opts.classes) |cls| {
            for (cls.methods) |m| {
                if (m.params.len > 0) n += m.params.len + 2;
            }
        }
        break :blk n;
    };

    // 至少保留 1 字节：当模块没有任何带参函数时 total_param_entries 为 0，
    // 否则 param_entries_buf 会退化为 [0]u8 空数组，无法索引/取地址（编译期报错）。
    const total_param_bytes = @max(1, total_param_entries) * ARGINFO_ENTRY_SIZE_MAX;
    const has_classes = opts.classes.len > 0;
    const has_ini = opts.ini.len > 0;
    const has_observer = opts.observer != null;
    const needs_minit_wrapper = has_classes or opts.constants.len > 0 or opts.minit != null or has_ini or has_observer;
    // 无条件注册：常驻 Arena（ResidentArena.shared()）的生命终点是模块卸载，
    // 没有这条 wrapper 它必然泄漏——与下游是否声明 mshutdown / 有无 INI 无关。
    const needs_mshutdown_wrapper = true;

    return struct {
        var function_entries: [opts.functions.len + 1]ZendFunctionEntry = undefined;
        var class_method_entries: [total_class_methods]ZendFunctionEntry = undefined;
        var class_method_ptrs: [opts.classes.len]?*anyopaque = undefined;
        var param_entries_buf: [total_param_bytes]u8 align(8) = undefined;
        var module_entry: ZendModuleEntry = undefined;

        /// 将方法 flags 哨兵转换为运行时 ACC 标志。
        /// __construct → ACC_PUBLIC|ACC_CTOR，__destruct → ACC_PUBLIC|ACC_DTOR
        /// 参数是否带类型约束（单一类型标注或联合类型掩码）
        fn hasTypedParams(desc: FunctionDesc) bool {
            for (desc.params) |p| {
                if (p.type_mask != 0) return true;
                if (p.param_type != .mixed) return true;
            }
            return false;
        }

        fn resolveFlags(desc: FunctionDesc) u32 {
            const base = blk: {
                if (desc.flags == Marker.static_marker) {
                    break :blk c.phpglue_acc_public() | c.phpglue_acc_static();
                }
                if (desc.flags == Marker.protected_marker) {
                    break :blk c.phpglue_acc_protected();
                }
                if (desc.flags == Marker.private_marker) {
                    break :blk c.phpglue_acc_private();
                }
                if (desc.flags == Marker.publicz_marker) {
                    break :blk c.phpglue_acc_public();
                }
                if (desc.flags != 0) break :blk desc.flags;
                break :blk c.phpglue_acc_public();
            };

            // 参数带类型约束时必须置 HAS_TYPE_HINTS：PHP 只在 fn_flags 含该位
            // 时才对内部函数参数做校验与转换（zend_execute.c 中
            // zend_verify_internal_arg_types 的调用条件）。缺了它，arg_info
            // 的类型信息虽能被 Reflection 读到，运行时却完全不生效——
            // 表现为「声明了 int 却照样收到 string/array」，而这正是
            // hello_format(null,null) 野指针崩溃的成因。
            if (hasTypedParams(desc)) {
                return base | c.phpglue_acc_has_type_hints();
            }
            return base;
        }

        /// 解析 arg_info + num_args。
        /// 按需选择：含 variadic/default_value 走 full C glue；
        /// 否则含类型标注走 typed；否则走无类型原版。
        /// desc 为 comptime 参数：缓冲按**该函数自身**的参数个数精确分配，
        /// 而非模块级最大值——调用者无需关心总量，也不浪费栈空间。
        fn resolveArgInfo(comptime desc: FunctionDesc, arginfo_offset: *usize) struct { ptr: ?*anyopaque, num: u32 } {
            if (desc.arg_info) |a| return .{ .ptr = a, .num = 0 };
            if (desc.params.len == 0) return .{ .ptr = c.phpglue_get_empty_arg_info(), .num = 0 };

            const off = arginfo_offset.*;
            const byte_off = off * ARGINFO_ENTRY_SIZE_MAX;

            var name_ptrs: [desc.params.len][*c]const u8 = undefined;
            for (desc.params, 0..) |p, j| name_ptrs[j] = p.name.ptr;

            // required_count = 非 variadic 参数个数（variadic 可传 0 个）
            var required: usize = 0;
            for (desc.params) |p| {
                if (!p.is_variadic) required += 1;
            }

            // 检测是否需要完整版（variadic / default_value）
            const hasFull = for (desc.params) |p| {
                if (p.is_variadic or p.default_value != null) break true;
            } else false;

            // 检测是否包含类型标注（单一类型或位掩码）
            const hasTypes = for (desc.params) |p| {
                if (p.param_type != .mixed or p.allow_null) break true;
            } else false;
            const hasMask = for (desc.params) |p| {
                if (p.type_mask != 0) break true;
            } else false;

            var entry_count: usize = 0;

            if (hasFull or hasTypes or hasMask) {
                // 统一走掩码版本：它能表达 typed 的单一类型、支持联合类型，
                // 且同样处理 variadic 与默认值。type_mask 为 0 时即 mixed。
                var masks: [desc.params.len]u32 = undefined;
                var varis: [desc.params.len]u8 = undefined;
                var defs: [desc.params.len]?[*:0]const u8 = undefined;
                for (desc.params, 0..) |p, j| {
                    masks[j] = paramMask(p);
                    varis[j] = @intFromBool(p.is_variadic);
                    defs[j] = if (p.default_value) |dv| dv.ptr else null;
                }
                c.phpglue_fill_arg_info_masked(
                    @ptrCast(&param_entries_buf[byte_off]),
                    @intCast(required),
                    &name_ptrs,
                    &masks,
                    &varis,
                    &defs,
                    desc.params.len,
                    &entry_count,
                );
            } else {
                c.phpglue_fill_arg_info(
                    @ptrCast(&param_entries_buf[byte_off]),
                    @intCast(required),
                    &name_ptrs,
                    desc.params.len,
                    &entry_count,
                );
            }

            arginfo_offset.* += desc.params.len + 2; // header + params + sentinel

            const base: [*]align(8) u8 = @as([*]align(8) u8, @ptrCast(&param_entries_buf));
            return .{
                .ptr = @ptrCast(base + byte_off),
                .num = @intCast(entry_count),
            };
        }

        fn initFunctionEntries() void {
            var off: usize = 0;
            // inline：使每个 desc 成为 comptime 值，resolveArgInfo 得以按
            // 该函数自身的参数个数精确分配缓冲
            inline for (opts.functions, 0..) |desc, i| {
                const ai = resolveArgInfo(desc, &off);
                // flags 此前留空（默认 0），导致 resolveFlags 算出的
                // ZEND_ACC_HAS_TYPE_HINTS 从未传给 PHP——arg_info 的类型信息
                // 因此只在 Reflection 里可见，运行时不做校验与转换。
                function_entries[i] = .{
                    .fname = desc.name.ptr,
                    .handler = desc.handler,
                    .arg_info = ai.ptr,
                    .num_args = ai.num,
                    .flags = resolveFlags(desc),
                };
            }
            function_entries[opts.functions.len] = .{};
        }

        fn initClassMethodEntries() void {
            var off: usize = 0;
            var ps_off: usize = 0;
            inline for (opts.classes, 0..) |cls, i| {
                inline for (cls.methods, 0..) |method, j| {
                    const ai = resolveArgInfo(method, &ps_off);
                    // 接口方法须带 abstract 标志
                    const flags = if (cls.is_interface)
                        resolveFlags(method) | c.phpglue_acc_abstract()
                    else
                        resolveFlags(method);
                    class_method_entries[off + j] = .{
                        .fname = method.name.ptr,
                        .handler = method.handler,
                        .arg_info = ai.ptr,
                        .num_args = ai.num,
                        .flags = flags,
                    };
                }
                class_method_entries[off + cls.methods.len] = .{};
                class_method_ptrs[i] = @ptrCast(@alignCast(&class_method_entries[off]));
                off += cls.methods.len + 1;
            }
        }

        fn initModule() void {
            // zval 大小校验 — Zig 侧 extern struct 必须不小于 C 侧 sizeof(zval)
            if (c.phpglue_zval_size() > @sizeOf(T.Zval)) {
                @panic("Zig Zval buffer too small for this PHP/architecture combination");
            }
            // arg_info 大小校验
            if (c.phpglue_arginfo_entry_size() > ARGINFO_ENTRY_SIZE_MAX) {
                @panic("ARGINFO_ENTRY_SIZE_MAX too small for this PHP version");
            }

            initFunctionEntries();
            module_entry = .{
                .size = @sizeOf(ZendModuleEntry),
                .name = opts.name.ptr,
                .version = opts.version.ptr,
                .functions = &function_entries,
                .module_startup_func = minitPtr(),
                .module_shutdown_func = mshutdownPtr(),
                .request_startup_func = rinitPtr(),
                .request_shutdown_func = rshutdownPtr(),
                .info_func = opts.info_func,
                .zend_api = c.phpglue_module_api_no(),
                .zend_debug = if (builtin.mode == .Debug) @as(u8, 1) else @as(u8, 0),
                // ZTS 自动检测 — 由 COMPILE_DL_ZTS 决定，NTS PHP 头文件返回 0
                .zts = c.phpglue_zts_mode(),
                .build_id = c.phpglue_module_build_id(),
            };
        }

        fn minitPtr() ?T.ModuleLifecycleFn {
            return if (needs_minit_wrapper) &phpzigMinit else null;
        }
        fn mshutdownPtr() ?T.ModuleLifecycleFn {
            return if (needs_mshutdown_wrapper) &phpzigMshutdown else null;
        }
        fn rinitPtr() ?T.ModuleLifecycleFn {
            // 始终注册：限额要按请求载入，见 phpzigRinit
            return &phpzigRinit;
        }
        fn rshutdownPtr() ?T.ModuleLifecycleFn {
            // 始终注册：Cleanup 注册表需要在 RSHUTDOWN 统一回收（bailout-safe）
            return &phpzigRshutdown;
        }

        fn registerClassFull(comptime cls: ClassDesc, methods_ptr: ?*anyopaque) c_int {
            // — 常量打包 —
            const k = cls.class_constants.len;
            // cls 是 comptime 参数：按该类自身的常量个数精确分配
            const nc = @max(1, cls.class_constants.len);
            var c_keys: [nc][*c]const u8 = undefined;
            var c_kls: [nc]usize = undefined;
            var c_vals: [nc]?*anyopaque = undefined;
            var c_vls: [nc]usize = undefined;
            var c_types: [nc]u8 = undefined;
            var ls_buf: [nc]T.zend_long = undefined;
            inline for (cls.class_constants, 0..) |cnst, j| {
                c_keys[j] = cnst.name.ptr;
                c_kls[j] = cnst.name.len;
                switch (cnst.value) {
                    .long => |v| {
                        ls_buf[j] = v;
                        c_vals[j] = @ptrCast(&ls_buf[j]);
                        c_vls[j] = 0;
                        c_types[j] = 0;
                    },
                    .string => |v| {
                        c_vals[j] = @ptrCast(@constCast(v.ptr));
                        c_vls[j] = v.len;
                        c_types[j] = 1;
                    },
                }
            }
            // — 属性打包 —
            const p = cls.properties.len;
            const np = @max(1, p); // 至少 1，避免零长数组（该类可能只有常量无属性）
            var p_keys: [np][*c]const u8 = undefined;
            var p_kls: [np]usize = undefined;
            var p_vals: [np]?*anyopaque = undefined;
            var p_vls: [np]usize = undefined;
            var p_access: [np]u32 = undefined;
            var p_types: [np]u8 = undefined;
            var dbl_buf: [np]f64 = undefined;
            var bl_buf: [np]u8 = undefined;
            inline for (cls.properties, 0..) |prop, j| {
                p_keys[j] = prop.name.ptr;
                p_kls[j] = prop.name.len;
                // 运行时解析 access 哨兵 + 默认值
                p_access[j] = switch (prop.access) {
                    1 => c.phpglue_acc_public() | c.phpglue_acc_static(),
                    2 => c.phpglue_acc_protected(),
                    3 => c.phpglue_acc_private(),
                    else => c.phpglue_acc_public(),
                };
                switch (prop.value) {
                    .long => |v| {
                        ls_buf[j] = v;
                        p_vals[j] = @ptrCast(&ls_buf[j]);
                        p_vls[j] = 0;
                        p_types[j] = 0;
                    },
                    .double => |v| {
                        dbl_buf[j] = v;
                        p_vals[j] = @ptrCast(&dbl_buf[j]);
                        p_vls[j] = 0;
                        p_types[j] = 1;
                    },
                    .string => |v| {
                        p_vals[j] = @ptrCast(@constCast(v.ptr));
                        p_vls[j] = v.len;
                        p_types[j] = 2;
                    },
                    .bool => |v| {
                        bl_buf[j] = @intFromBool(v);
                        p_vals[j] = @ptrCast(&bl_buf[j]);
                        p_vls[j] = 0;
                        p_types[j] = 3;
                    },
                    .null_ => {
                        p_vals[j] = null;
                        p_vls[j] = 0;
                        p_types[j] = 4;
                    },
                }
            }
            return c.phpglue_register_class_full(
                cls.name.ptr,
                cls.name.len,
                methods_ptr,
                @intCast(k),
                &c_keys,
                &c_kls,
                &c_vals,
                &c_vls,
                &c_types,
                @intCast(p),
                &p_keys,
                &p_kls,
                &p_vals,
                &p_vls,
                &p_access,
                &p_types,
            );
        }

        /// 注册带对象绑定（extern struct 数据区）的类
        fn registerObjectClass(cls: ClassDesc, methods_ptr: ?*anyopaque, binding: ObjectBinding) c_int {
            const ce = c.phpglue_register_object_class(
                cls.name.ptr,
                cls.name.len,
                methods_ptr,
                binding.extra_size,
                binding.init,
                binding.dtor,
            );
            return if (ce != null) 1 else 0;
        }

        /// 注册全部 INI 项 + 设置变更通知回调
        fn registerIniEntries(module_number: c_int) void {
            if (opts.ini.len == 0) return;
            const ni = opts.ini.len; // opts 是 comptime，此处即实际项数
            var names: [ni][*c]const u8 = undefined;
            var name_lens: [ni]usize = undefined;
            var defaults: [ni][*c]const u8 = undefined;
            var types: [ni]u8 = undefined;
            var modifiables: [ni]u8 = undefined;
            for (opts.ini, 0..) |entry, j| {
                names[j] = entry.name.ptr;
                name_lens[j] = entry.name.len;
                defaults[j] = entry.default_value.ptr;
                types[j] = @intFromEnum(entry.entry_type);
                modifiables[j] = @intFromEnum(entry.modifiable);
            }
            _ = c.phpglue_register_ini_entries(
                &names,
                &name_lens,
                &defaults,
                &types,
                &modifiables,
                opts.ini.len,
                module_number,
            );
            if (opts.ini_notify != null) c.phpglue_set_ini_notify(&phpzigIniNotify);
        }

        /// INI 变更通知 C 回调 → 转发到用户回调
        fn phpzigIniNotify(name: [*c]const u8, name_len: usize) callconv(.c) void {
            if (opts.ini_notify) |cb| cb(name, name_len);
        }

        fn phpzigMinit(type_: c_int, module_number: c_int) callconv(.c) c_int {
            inline for (opts.constants) |cnst| {
                switch (cnst.value) {
                    .long => |v| c.phpglue_register_constant_long(cnst.name.ptr, cnst.name.len, v, module_number),
                    .double => |v| c.phpglue_register_constant_double(cnst.name.ptr, cnst.name.len, v, module_number),
                    .string => |v| c.phpglue_register_constant_string(cnst.name.ptr, cnst.name.len, v.ptr, v.len, module_number),
                    .bool => |v| c.phpglue_register_constant_bool(cnst.name.ptr, cnst.name.len, v, module_number),
                    .null_ => c.phpglue_register_constant_null(cnst.name.ptr, cnst.name.len, module_number),
                }
            }
            registerIniEntries(module_number);
            // 挂载 PHP 侧实现的探针（内存额度查询、OOM 抛异常）：函数指针在
            // MINIT 后不再改动，各请求线程读到同一份，故保持进程级全局。
            // 请求级限额本身不在这里读——见 phpzigRinit。
            Arena.bindPhpProbes();
            // 常驻级额度是进程级语义，故在 MINIT 读（perdir 的按请求覆盖对它
            // 没有意义）。放在下游 minit 钩子之前，钩子里可用 configureResident
            // 覆盖。
            Arena.configureResidentFromIni();
            if (opts.observer) |obs| {
                c.phpglue_observer_register(
                    obs.fcall_begin,
                    obs.fcall_end,
                    obs.@"error",
                    obs.function_declared,
                    obs.class_linked,
                    obs.fiber_init,
                    obs.fiber_switch,
                    obs.fiber_destroy,
                    obs.fcall_filter,
                );
            }
            initClassMethodEntries();
            inline for (opts.classes, 0..) |cls, i| {
                const result: c_int = if (cls.is_interface)
                    c.phpglue_register_interface(cls.name.ptr, cls.name.len, class_method_ptrs[i])
                else if (cls.object_binding) |binding|
                    registerObjectClass(cls, class_method_ptrs[i], binding)
                else if (cls.properties.len > 0 or cls.class_constants.len > 0)
                    registerClassFull(cls, class_method_ptrs[i])
                else if (cls.parent_name) |parent_name|
                    c.phpglue_register_class_ex(cls.name.ptr, cls.name.len, class_method_ptrs[i], c.phpglue_lookup_class(parent_name.ptr, parent_name.len) orelse return -1)
                else
                    c.phpglue_register_class(cls.name.ptr, cls.name.len, class_method_ptrs[i]);

                if (result == 0) return -1;

                // 类实现接口（接口须先于本类注册）
                inline for (cls.interfaces) |iface_name| {
                    if (c.phpglue_class_implements_one(cls.name.ptr, cls.name.len, iface_name.ptr, iface_name.len) == 0)
                        return -1;
                }
            }
            if (opts.minit) |user_minit| return user_minit(type_, module_number);
            return 0;
        }
        fn phpzigMshutdown(type_: c_int, module_number: c_int) callconv(.c) c_int {
            if (has_ini) c.phpglue_unregister_ini_entries(module_number);
            const rc: c_int = if (opts.mshutdown) |hook| hook(type_, module_number) else 0;
            // 常驻 Arena 的生命终点是模块卸载（不是请求结束）。放在下游钩子之后，
            // 让下游还能在钩子里读到常驻占用做泄漏自查。幂等，重复调用安全。
            Arena.ResidentArena.shutdown();
            return rc;
        }
        fn phpzigRinit(type_: c_int, module_number: c_int) callconv(.c) c_int {
            // 限额按请求载入：INI 值可被 perdir 机制按请求改变，且 ZTS 下 PG
            // 每请求线程一份——放在 MINIT 读，其它请求线程会一直用默认额度。
            Arena.configureFromIni();
            if (opts.rinit) |hook| return hook(type_, module_number);
            return 0;
        }
        fn phpzigRshutdown(type_: c_int, module_number: c_int) callconv(.c) c_int {
            Cleanup.flush();
            if (opts.rshutdown) |hook| return hook(type_, module_number);
            return 0;
        }

        pub fn get_module() callconv(.c) *ZendModuleEntry {
            if (module_entry.size != @sizeOf(ZendModuleEntry)) initModule();
            return &module_entry;
        }
    };
}

/// 自动发现模块级函数：`pub fn php_<name>` → 函数 `<name>`。
/// （`@This()` 的 decls 只枚举 pub 声明，故函数必须 `pub`。）
///
/// 参数通过伴生 struct 约定：若存在 `pub const <name>Args = struct {...}`，
/// 其字段反射为参数名/类型；否则视为无参函数。
fn discoverFunctions(comptime file: type) []const FunctionDesc {
    const info = @typeInfo(file);
    if (info != .@"struct") @compileError("moduleInit expects the current file type, got " ++ @typeName(file));
    const decls = info.@"struct".decls;

    comptime var count = 0;
    inline for (decls) |d| {
        if (!std.mem.startsWith(u8, d.name, "php_")) continue;
        if (@typeInfo(@TypeOf(@field(file, d.name))) != .@"fn") continue;
        count += 1;
    }

    const funcs: [count]FunctionDesc = blk: {
        var arr: [count]FunctionDesc = undefined;
        comptime var idx = 0;
        inline for (decls) |d| {
            if (!std.mem.startsWith(u8, d.name, "php_")) continue;
            if (@typeInfo(@TypeOf(@field(file, d.name))) != .@"fn") continue;

            const php_name: [:0]const u8 = d.name["php_".len..];
            const handler: T.FunctionHandler = @ptrCast(@alignCast(&@field(file, d.name)));

            const args_name = std.fmt.comptimePrint("{s}Args", .{php_name});
            const types_name = std.fmt.comptimePrint("{s}ArgTypes", .{php_name});

            // 静默退化成无类型约束是危险的：曾经 hello_format 声明了 FormatArgs
            // 但命名不匹配，约束没生效，null 直接进 handler 导致野指针崩溃。
            // 故声明了任何 *Args / *Types 形式却对不上名字时，一律编译错误。
            // 显式出口：`{name}Untyped` 表示「故意不做类型约束」。
            // 无参函数用它；有参但想保留 unsafe 灵活性的也可显式声明。
            const untyped_name = std.fmt.comptimePrint("{s}Untyped", .{php_name});
            if (!@hasDecl(file, args_name) and !@hasDecl(file, untyped_name)) {
                @compileError(std.fmt.comptimePrint(
                    \\php-zig: function `php_{0s}` has no parameter type declaration.
                    \\
                    \\  Add ONE of the following:
                    \\    pub const {0s}Args = struct {{ ... }};   // 反射生成类型约束
                    \\    pub const {0s}ArgTypes = .{{ ... }};      // 联合类型补齐（需配合 Args）
                    \\    pub const {0s}Untyped = true;             // 故意不加约束（无参函数用）
                    \\
                    \\  This is an error rather than a silent fallback because a
                    \\  misnamed declaration (e.g. `FormatArgs` instead of
                    \\  `hello_formatArgs`) previously caused the type constraint
                    \\  to be dropped silently — which let null reach the handler
                    \\  and crash via a wild pointer dereference.
                , .{php_name}));
            }

            arr[idx] = if (@hasDecl(file, args_name))
                if (@hasDecl(file, types_name))
                    FunctionDesc.createFromWith(php_name, handler, @field(file, args_name), @field(file, types_name))
                else
                    FunctionDesc.createFrom(php_name, handler, @field(file, args_name))
            else
                FunctionDesc{ .name = php_name, .handler = handler };
            idx += 1;
        }
        break :blk arr;
    };
    return &funcs;
}

/// 自动发现类：`pub const Class_<name> = struct {...}` → 类 `<name>`。
/// （`@This()` 的 decls 只枚举 pub 声明，故类 struct 必须 `pub`。）
/// 复用 `createFromStruct` 的方法/属性反射（public_/protect_/static_ 前缀）。
fn discoverClasses(comptime file: type) []const ClassDesc {
    const info = @typeInfo(file);
    if (info != .@"struct") @compileError("moduleInit expects the current file type, got " ++ @typeName(file));
    const decls = info.@"struct".decls;

    comptime var count = 0;
    inline for (decls) |d| {
        if (std.mem.startsWith(u8, d.name, "Class_")) count += 1;
    }

    const classes: [count]ClassDesc = blk: {
        var arr: [count]ClassDesc = undefined;
        comptime var idx = 0;
        inline for (decls) |d| {
            if (!std.mem.startsWith(u8, d.name, "Class_")) continue;
            const cls_name: [:0]const u8 = d.name["Class_".len..];
            arr[idx] = ClassDesc.createFromStruct(cls_name, @field(file, d.name));
            idx += 1;
        }
        break :blk arr;
    };
    return &classes;
}

/// 模块注册入口 — 在 comptime 块中调用，扫描当前文件（`@This()`）自动发现函数与类，
/// 并导出 `get_module` 符号。
///
/// 命名约定（声明须为 `pub`——`@This()` 的 decls 只枚举 pub 声明）：
/// - `pub fn php_<name>`                 → 模块函数 `<name>`
/// - `pub fn php_<name>` + `pub const <name>Args` struct → 有参函数（字段 = 参数）
/// - `pub const Class_<name>`            → 类 `<name>`（内部用 public_/static_ 等前缀）
///
/// ```zig
/// const phpzig = @import("phpzig");
/// const T = phpzig.php_types;
///
/// pub fn php_hello(_: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
///     phpzig.Return.returnString(rv, "Hello");
/// }
///
/// pub fn php_add(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
///     const a = phpzig.Return.callArg(ed, 1).toLong();
///     const b = phpzig.Return.callArg(ed, 2).toLong();
///     phpzig.Return.returnLong(rv, a + b);
/// }
/// pub const addArgs = struct { a: i64, b: i64 };   // php_add 的参数
///
/// comptime {
///     phpzig.moduleInit(@This(), .{
///         .name    = "myext",
///         .version = "1.0.0",
///     });
/// }
/// ```
pub fn moduleInit(comptime file: type, comptime meta: ModuleMeta) void {
    const M = Module(.{
        .name = meta.name,
        .version = meta.version,
        .functions = comptime discoverFunctions(file) ++ meta.functions,
        .classes = comptime discoverClasses(file) ++ meta.classes,
        .minit = meta.minit,
        .mshutdown = meta.mshutdown,
        .rinit = meta.rinit,
        .rshutdown = meta.rshutdown,
        .constants = meta.constants,
        .ini = meta.ini,
        .ini_notify = meta.ini_notify,
        .info_func = meta.info_func,
        .observer = meta.observer,
    });
    @export(&M.get_module, .{ .name = "get_module" });
}
