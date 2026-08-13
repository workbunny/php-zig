//! PHP 模块注册
//!
//! comptime 泛型驱动的编译期模块生成，覆盖模块入口、函数注册、
//! 生命周期钩子、类与方法注册、参数 arg_info、常量注册、phpinfo 回调。
//!
//! 版本适配策略：所有 PHP 头文件常量（ZEND_ACC_*、zend_internal_arg_info 大小等）
//! 通过 C glue 运行时查询，不硬编码任何版本特定值。

const c = @import("php_c.zig");
const T = @import("php_types.zig");
const builtin = @import("builtin");
const std = @import("std");
const IniEntry = @import("ini.zig").IniEntry;

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

pub const ParamDesc = struct {
    name: [:0]const u8,
    param_type: ParamType = .mixed,
    allow_null: bool = false,
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

    /// comptime struct 反射 — 从 struct 字段名和类型自动推导 arg_info。
    ///
    /// ```zig
    /// const AddArgs = struct { a: i64, b: i64, name: []const u8 };
    /// const funcs = &.{ FunctionDesc.createFrom("my_add", my_add, AddArgs) };
    /// ```
    ///
    /// 字段顺序 = 参数顺序，字段名 = 参数名，字段类型 → PHP 类型标注。
    /// ?T 类型自动映射为 allow_null。
    pub fn createFrom(comptime name: [:0]const u8, handler: T.FunctionHandler, comptime Args: type) FunctionDesc {
        return .{
            .name = name,
            .handler = handler,
            .params = comptime paramsFromStruct(Args),
        };
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
};

pub fn Module(comptime opts: ModuleOptions) type {
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
    const needs_minit_wrapper = has_classes or opts.constants.len > 0 or opts.minit != null or has_ini;
    const needs_mshutdown_wrapper = opts.mshutdown != null or has_ini;

    return struct {
        var function_entries: [opts.functions.len + 1]ZendFunctionEntry = undefined;
        var class_method_entries: [total_class_methods]ZendFunctionEntry = undefined;
        var class_method_ptrs: [opts.classes.len]?*anyopaque = undefined;
        var param_entries_buf: [total_param_bytes]u8 align(8) = undefined;
        var module_entry: ZendModuleEntry = undefined;

        /// 将方法 flags 哨兵转换为运行时 ACC 标志。
        /// __construct → ACC_PUBLIC|ACC_CTOR，__destruct → ACC_PUBLIC|ACC_DTOR
        fn resolveFlags(desc: FunctionDesc) u32 {
            if (desc.flags == Marker.static_marker) {
                return c.phpglue_acc_public() | c.phpglue_acc_static();
            }
            if (desc.flags == Marker.protected_marker) {
                return c.phpglue_acc_protected();
            }
            if (desc.flags == Marker.private_marker) {
                return c.phpglue_acc_private();
            }
            if (desc.flags == Marker.publicz_marker) {
                return c.phpglue_acc_public();
            }
            if (desc.flags != 0) return desc.flags;
            return c.phpglue_acc_public();
        }

        /// 解析 arg_info + num_args。
        /// 按需选择：含 variadic/default_value 走 full C glue；
        /// 否则含类型标注走 typed；否则走无类型原版。
        fn resolveArgInfo(desc: FunctionDesc, arginfo_offset: *usize) struct { ptr: ?*anyopaque, num: u32 } {
            if (desc.arg_info) |a| return .{ .ptr = a, .num = 0 };
            if (desc.params.len == 0) return .{ .ptr = c.phpglue_get_empty_arg_info(), .num = 0 };

            const off = arginfo_offset.*;
            const byte_off = off * ARGINFO_ENTRY_SIZE_MAX;

            var name_ptrs: [8][*c]const u8 = undefined;
            if (desc.params.len > 8) @panic("max 8 params supported for arg_info");
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

            // 检测是否包含类型标注
            const hasTypes = for (desc.params) |p| {
                if (p.param_type != .mixed or p.allow_null) break true;
            } else false;

            var entry_count: usize = 0;

            if (hasFull) {
                var types: [8]u8 = undefined;
                var nulls: [8]u8 = undefined;
                var varis: [8]u8 = undefined;
                var defs: [8]?[*:0]const u8 = undefined;
                for (desc.params, 0..) |p, j| {
                    types[j] = @intFromEnum(p.param_type);
                    nulls[j] = @intFromBool(p.allow_null);
                    varis[j] = @intFromBool(p.is_variadic);
                    defs[j] = if (p.default_value) |dv| dv.ptr else null;
                }
                c.phpglue_fill_arg_info_full(
                    @ptrCast(&param_entries_buf[byte_off]),
                    @intCast(required),
                    &name_ptrs,
                    &types,
                    &nulls,
                    &varis,
                    &defs,
                    desc.params.len,
                    &entry_count,
                );
            } else if (hasTypes) {
                var types: [8]u8 = undefined;
                var nulls: [8]u8 = undefined;
                for (desc.params, 0..) |p, j| {
                    types[j] = @intFromEnum(p.param_type);
                    nulls[j] = @intFromBool(p.allow_null);
                }
                c.phpglue_fill_arg_info_typed(
                    @ptrCast(&param_entries_buf[byte_off]),
                    @intCast(required),
                    &name_ptrs,
                    &types,
                    &nulls,
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
            for (opts.functions, 0..) |desc, i| {
                const ai = resolveArgInfo(desc, &off);
                function_entries[i] = .{
                    .fname = desc.name.ptr,
                    .handler = desc.handler,
                    .arg_info = ai.ptr,
                    .num_args = ai.num,
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
            return if (opts.rinit) |_| &phpzigRinit else null;
        }
        fn rshutdownPtr() ?T.ModuleLifecycleFn {
            return if (opts.rshutdown) |_| &phpzigRshutdown else null;
        }

        fn registerClassFull(comptime cls: ClassDesc, methods_ptr: ?*anyopaque) c_int {
            // — 常量打包 —
            const k = cls.class_constants.len;
            var c_keys: [8][*c]const u8 = undefined;
            var c_kls: [8]usize = undefined;
            var c_vals: [8]?*anyopaque = undefined;
            var c_vls: [8]usize = undefined;
            var c_types: [8]u8 = undefined;
            var ls_buf: [8]T.zend_long = undefined;
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
            if (p > 8) @panic("max 8 properties");
            var p_keys: [8][*c]const u8 = undefined;
            var p_kls: [8]usize = undefined;
            var p_vals: [8]?*anyopaque = undefined;
            var p_vls: [8]usize = undefined;
            var p_access: [8]u32 = undefined;
            var p_types: [8]u8 = undefined;
            var dbl_buf: [8]f64 = undefined;
            var bl_buf: [8]u8 = undefined;
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
            if (opts.ini.len > 64) @panic("max 64 INI entries");
            var names: [64][*c]const u8 = undefined;
            var name_lens: [64]usize = undefined;
            var defaults: [64][*c]const u8 = undefined;
            var types: [64]u8 = undefined;
            var modifiables: [64]u8 = undefined;
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
            if (opts.mshutdown) |hook| return hook(type_, module_number);
            return 0;
        }
        fn phpzigRinit(type_: c_int, module_number: c_int) callconv(.c) c_int {
            if (opts.rinit) |hook| return hook(type_, module_number);
            return 0;
        }
        fn phpzigRshutdown(type_: c_int, module_number: c_int) callconv(.c) c_int {
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
            arr[idx] = if (@hasDecl(file, args_name))
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
    });
    @export(&M.get_module, .{ .name = "get_module" });
}
