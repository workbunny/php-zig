//! PHP 模块注册
//!
//! comptime 泛型驱动的编译期模块生成，覆盖模块入口、函数注册、
//! 生命周期钩子、类与方法注册、参数 arg_info、常量注册、phpinfo 回调。
//!
//! 版本适配策略：所有 PHP 头文件常量（ZEND_ACC_*、zend_internal_arg_info 大小等）
//! 通过 C glue 运行时查询，不硬编码任何版本特定值。

const c       = @import("php_c.zig");
const T       = @import("php_types.zig");
const builtin = @import("builtin");
const std     = @import("std");

// ＝＝ Zend 结构体布局（extern struct，必须与 C 布局一致） ＝＝
// 字段顺序与 PHP 头文件定义严格对应。
// 具体字段布局随编译时 PHP 头文件版本而定，无需在此定义版本号。

pub const ZendFunctionEntry = extern struct {
    fname:                    [*c]const u8          = null,
    handler:                  ?T.FunctionHandler    = null,
    arg_info:                 ?*anyopaque           = null,
    num_args:                 u32                   = 0,
    flags:                    u32                   = 0,
    frameless_function_infos: ?*anyopaque           = null,
    doc_comment:              [*c]const u8          = null,
};

pub const ZendModuleEntry = extern struct {
    size:                    c_ushort                           = @sizeOf(ZendModuleEntry),
    zend_api:                c_uint                            = 0,
    zend_debug:              u8                                = 0,
    zts:                     u8                                = 0,
    ini_entry:               ?*anyopaque                       = null,
    deps:                    ?*anyopaque                       = null,
    name:                    [*c]const u8                      = null,
    functions:               [*c]const ZendFunctionEntry       = null,
    module_startup_func:     ?T.ModuleLifecycleFn              = null,
    module_shutdown_func:    ?T.ModuleLifecycleFn              = null,
    request_startup_func:    ?T.ModuleLifecycleFn              = null,
    request_shutdown_func:   ?T.ModuleLifecycleFn              = null,
    info_func:               ?*const fn (zend_module: *ZendModuleEntry) callconv(.c) void = null,
    version:                 [*c]const u8                      = null,
    globals_size:            usize                             = 0,
    globals_ptr:             ?*anyopaque                       = null,
    globals_ctor:            ?*const fn (global: ?*anyopaque) callconv(.c) void = null,
    globals_dtor:            ?*const fn (global: ?*anyopaque) callconv(.c) void = null,
    post_deactivate_func:    ?*const fn () callconv(.c) c_int  = null,
    module_started:          c_int                             = 0,
    type:                    u8                                = 0,
    handle:                  ?*anyopaque                       = null,
    module_number:           c_int                             = 0,
    build_id:                [*c]const u8                      = null,
};

// ＝＝ arg_info 缓冲区常量 ＝＝
// 使用慷慨上限而非精确 sizeof(zend_internal_arg_info)，
// 在 initModule() 中运行时校验实际大小不超过上限。
// 上限 64 字节在 64 位系统上覆盖了所有已知 PHP 版本的 arg_info 结构。

const ARGINFO_ENTRY_SIZE_MAX: usize = 64;

// ＝＝ 参数描述符 ＝＝

/// PHP 类型标注枚举。值 0~6 与 C glue phpglue_fill_arg_info_typed 约定一致。
pub const ParamType = enum(u8) {
    mixed  = 0,  // 无类型提示
    long   = 1,
    double = 2,
    string = 3,
    bool   = 4,
    array  = 5,
    object = 6,
};

pub const ParamDesc = struct {
    name:       [:0]const u8,
    param_type: ParamType = .mixed,
    allow_null: bool      = false,

    /// 声明式构造（兼容旧版，无类型标注）
    pub fn create(name: [:0]const u8) ParamDesc { return .{ .name = name }; }
    /// 声明式构造 + 类型标注
    pub fn createTyped(name: [:0]const u8, pt: ParamType) ParamDesc {
        return .{ .name = name, .param_type = pt };
    }
};

/// comptime：Zig 类型 → PHP 参数类型 + allow_null
/// ?i64 → { .long, allow_null=true }; ?[]const u8 → { .string, allow_null=true }
pub fn zigTypeToPhpType(comptime Z: type) struct { pt: ParamType, an: bool } {
    const info = @typeInfo(Z);
    if (info == .@"optional") {
        const inner = zigTypeToPhpType(info.@"optional".child);
        return .{ .pt = inner.pt, .an = true };
    }
    return switch (Z) {
        i64, u64, i32, u32, isize, usize => .{ .pt = .long,   .an = false },
        f64, f32                         => .{ .pt = .double, .an = false },
        bool                             => .{ .pt = .bool,   .an = false },
        []const u8, [:0]const u8         => .{ .pt = .string, .an = false },
        *T.Zval                          => .{ .pt = .mixed,  .an = false },
        else => @compileError("Unsupported comptime arg type: " ++ @typeName(Z)),
    };
}

// ＝＝ 函数 / 方法描述符 ＝＝
//
// flags 字段不提供 comptime 默认值 —— 实际值由 init*Entries 在运行时
// 从 C glue 获取，确保与编译时 PHP 头文件的 ZEND_ACC_* 一致。

pub const FunctionDesc = struct {
    name:     [:0]const u8,
    handler:  T.FunctionHandler,
    arg_info: ?*anyopaque = null,
    /// 运行时标志位（0 表示 init 时自动从 C glue 获取）：
    ///   PUBLIC=0 — 模块级函数用 ACC_PUBLIC；类方法用 ACC_PUBLIC；
    ///   STATIC  — 类静态方法用 ACC_PUBLIC|ACC_STATIC
    ///   PROTECTED_MARKER — ACC_PUBLIC|ACC_PROTECTED
    ///   PRIVATE_MARKER   — ACC_PUBLIC|ACC_PRIVATE
    flags:    u32 = 0,
    params:   []const ParamDesc = &.{},

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
            .name    = name,
            .handler = handler,
            .params  = comptime paramsFromStruct(Args),
        };
    }

    /// createFrom 的静态方法版本
    pub fn createStaticFrom(comptime name: [:0]const u8, handler: T.FunctionHandler, comptime Args: type) FunctionDesc {
        return .{
            .name    = name,
            .handler = handler,
            .params  = comptime paramsFromStruct(Args),
            .flags   = Marker.static_marker,
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
    const publicz_marker:   u32 = 0xDEADBEE0;
    const static_marker:    u32 = 0xDEADBEEF;
    const protected_marker: u32 = 0xDEADBEF0;
    const private_marker:   u32 = 0xDEADBEF1;
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
                .name       = field.name,
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
                .name   = field.name,
                .value  = dv,
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
            const prefix: []const u8 = if (std.mem.startsWith(u8, name, "public_"))  "public_"
                                  else if (std.mem.startsWith(u8, name, "protect_")) "protect_"
                                  else if (std.mem.startsWith(u8, name, "private_")) "private_"
                                  else if (std.mem.startsWith(u8, name, "static_"))  "static_"
                                  else @compileError("BUG: " ++ name);

            // 2. 去掉前缀 (Zig 0.16: name[prefix.len..] 有 bug，显式指定结束位置)
            const rest: [:0]const u8 = name[prefix.len..name.len];
            const php_name: [:0]const u8 = if (std.mem.eql(u8, rest, "magic_construct"))    "__construct"
            else if (std.mem.eql(u8, rest, "magic_destruct"))   "__destruct"
            else if (std.mem.eql(u8, rest, "magic_call"))       "__call"
            else if (std.mem.eql(u8, rest, "magic_callStatic")) "__callStatic"
            else if (std.mem.eql(u8, rest, "magic_get"))        "__get"
            else if (std.mem.eql(u8, rest, "magic_set"))        "__set"
            else if (std.mem.eql(u8, rest, "magic_isset"))      "__isset"
            else if (std.mem.eql(u8, rest, "magic_unset"))      "__unset"
            else if (std.mem.eql(u8, rest, "magic_sleep"))      "__sleep"
            else if (std.mem.eql(u8, rest, "magic_wakeup"))     "__wakeup"
            else if (std.mem.eql(u8, rest, "magic_toString"))   "__toString"
            else if (std.mem.eql(u8, rest, "magic_invoke"))     "__invoke"
            else if (std.mem.eql(u8, rest, "magic_set_state"))  "__set_state"
            else if (std.mem.eql(u8, rest, "magic_clone"))      "__clone"
            else if (std.mem.eql(u8, rest, "magic_debugInfo"))  "__debugInfo"
            else if (std.mem.eql(u8, rest, "magic_serialize"))  "__serialize"
            else if (std.mem.eql(u8, rest, "magic_unserialize")) "__unserialize"
            else if (std.mem.startsWith(u8, rest, "magic_"))     @compileError("Unknown magic method: " ++ rest)
            else                                                   rest;

            // 4. 确定 flags
            const f: u32 = if (std.mem.eql(u8, prefix, "public_"))  Marker.publicz_marker
                      else if (std.mem.eql(u8, prefix, "protect_")) Marker.protected_marker
                      else if (std.mem.eql(u8, prefix, "private_")) Marker.private_marker
                      else Marker.static_marker;

            arr[idx] = FunctionDesc{ .name = php_name, .handler = handler, .flags = f };
            idx += 1;
        }
        break :blk arr;
    };
    return &methods;
}

// ＝＝ 类属性描述符 ＝＝

pub const PropertyType = enum(u8) {
    long   = 0,
    double = 1,
    string = 2,
    bool   = 3,
    null_  = 4,
};

pub const ClassPropertyDesc = struct {
    name:    [:0]const u8,
    value:   ClassPropertyValue,
    /// ZEND_ACC_* 组合——由 C glue 运行时查询，不硬编码
    access:  u32 = 0, // 0 = init 时自动设为 ACC_PUBLIC

    pub const ClassPropertyValue = union(enum) {
        long:   T.zend_long,
        double: f64,
        string: [:0]const u8,
        bool:   bool,
        null_:  void,
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

// ＝＝ 类描述符 ＝＝

pub const ClassDesc = struct {
    name:            [:0]const u8,
    methods:         []const FunctionDesc,
    parent_name:     ?[:0]const u8 = null,
    class_constants: []const ClassConstantDesc = &.{},
    properties:      []const ClassPropertyDesc = &.{},

    pub fn create(name: [:0]const u8, methods: []const FunctionDesc) ClassDesc {
        return .{ .name = name, .methods = methods };
    }
    pub fn createExtends(name: [:0]const u8, parent: [:0]const u8, methods: []const FunctionDesc) ClassDesc {
        return .{ .name = name, .methods = methods, .parent_name = parent };
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
            .name       = name,
            .methods    = methods,
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
            .name       = name,
            .methods    = comptime methodsFromStruct(Cls),
            .properties = comptime propsFromStruct(Cls),
        };
    }
};

// ＝＝ 类常量描述符 ＝＝

pub const ClassConstantDesc = struct {
    name:  [:0]const u8,
    value: ClassConstantValue,

    pub const ClassConstantValue = union(enum) {
        long:   T.zend_long,
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
    name:  [:0]const u8,
    value: ConstantValue,

    pub const ConstantValue = union(enum) {
        long:   T.zend_long,
        double: f64,
        string: [:0]const u8,
        bool:   bool,
        null_:  void,
    };

    pub fn createLong(name: [:0]const u8, v: T.zend_long) ConstantDesc   { return .{ .name = name, .value = .{ .long = v } }; }
    pub fn createDouble(name: [:0]const u8, v: f64) ConstantDesc          { return .{ .name = name, .value = .{ .double = v } }; }
    pub fn createString(name: [:0]const u8, v: [:0]const u8) ConstantDesc  { return .{ .name = name, .value = .{ .string = v } }; }
    pub fn createBool(name: [:0]const u8, v: bool) ConstantDesc            { return .{ .name = name, .value = .{ .bool = v } }; }
    pub fn createNull(name: [:0]const u8) ConstantDesc                     { return .{ .name = name, .value = .{ .null_ = {} } }; }
};

// ＝＝ 模块入口 ＝＝

pub fn Module(comptime opts: struct {
    name:      [:0]const u8,
    version:   [:0]const u8,
    functions: []const FunctionDesc = &.{},
    minit:     ?T.ModuleLifecycleFn = null,
    mshutdown: ?T.ModuleLifecycleFn = null,
    rinit:     ?T.ModuleLifecycleFn = null,
    rshutdown: ?T.ModuleLifecycleFn = null,
    classes:   []const ClassDesc = &.{},
    constants: []const ConstantDesc = &.{},
    info_func: ?*const fn (module: *ZendModuleEntry) callconv(.c) void = null,
}) type {

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

    const total_param_bytes = total_param_entries * ARGINFO_ENTRY_SIZE_MAX;
    const has_classes = opts.classes.len > 0;
    const needs_minit_wrapper = has_classes or opts.constants.len > 0 or opts.minit != null;

    return struct {

        var function_entries:    [opts.functions.len + 1]ZendFunctionEntry = undefined;
        var class_method_entries: [total_class_methods]ZendFunctionEntry    = undefined;
        var class_method_ptrs:    [opts.classes.len]?*anyopaque             = undefined;
        var param_entries_buf: [total_param_bytes]u8 align(8) = undefined;
        var module_entry:         ZendModuleEntry                            = undefined;

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
        /// 自动检测：若任一 ParamDesc 带类型标注，走 typed C glue；否则走原版。
        fn resolveArgInfo(desc: FunctionDesc, arginfo_offset: *usize) struct { ptr: ?*anyopaque, num: u32 } {
            if (desc.arg_info) |a| return .{ .ptr = a, .num = 0 };
            if (desc.params.len == 0) return .{ .ptr = c.phpglue_get_empty_arg_info(), .num = 0 };

            const required = desc.params.len;
            const off      = arginfo_offset.*;
            const byte_off = off * ARGINFO_ENTRY_SIZE_MAX;

            var name_ptrs: [8][*c]const u8 = undefined;
            if (desc.params.len > 8) @panic("max 8 params supported for arg_info");
            for (desc.params, 0..) |p, j| name_ptrs[j] = p.name.ptr;

            // 检测是否包含类型标注
            const hasTypes = for (desc.params) |p| {
                if (p.param_type != .mixed or p.allow_null) break true;
            } else false;

            var entry_count: usize = 0;

            if (hasTypes) {
                var types: [8]u8 = undefined;
                var nulls: [8]u8 = undefined;
                for (desc.params, 0..) |p, j| {
                    types[j] = @intFromEnum(p.param_type);
                    nulls[j] = @intFromBool(p.allow_null);
                }
                c.phpglue_fill_arg_info_typed(
                    @ptrCast(&param_entries_buf[byte_off]),
                    @intCast(required), &name_ptrs, &types, &nulls, required,
                    &entry_count,
                );
            } else {
                c.phpglue_fill_arg_info(
                    @ptrCast(&param_entries_buf[byte_off]),
                    @intCast(required), &name_ptrs, required,
                    &entry_count,
                );
            }

            arginfo_offset.* += required + 2; // header + params + sentinel

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
                    .fname    = desc.name.ptr,
                    .handler  = desc.handler,
                    .arg_info = ai.ptr,
                    .num_args = ai.num,
                };
            }
            function_entries[opts.functions.len] = .{};
        }

        fn initClassMethodEntries() void {
            var off: usize    = 0;
            var ps_off: usize = 0;
            inline for (opts.classes, 0..) |cls, i| {
                inline for (cls.methods, 0..) |method, j| {
                    const ai = resolveArgInfo(method, &ps_off);
                    class_method_entries[off + j] = .{
                        .fname    = method.name.ptr,
                        .handler  = method.handler,
                        .arg_info = ai.ptr,
                        .num_args = ai.num,
                        .flags    = resolveFlags(method),
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
                .size                  = @sizeOf(ZendModuleEntry),
                .name                  = opts.name.ptr,
                .version               = opts.version.ptr,
                .functions             = &function_entries,
                .module_startup_func   = minitPtr(),
                .module_shutdown_func  = mshutdownPtr(),
                .request_startup_func  = rinitPtr(),
                .request_shutdown_func = rshutdownPtr(),
                .info_func             = opts.info_func,
                .zend_api              = c.phpglue_module_api_no(),
                .zend_debug            = if (builtin.mode == .Debug) @as(u8, 1) else @as(u8, 0),
                // ZTS 自动检测 — 由 COMPILE_DL_ZTS 决定，NTS PHP 头文件返回 0
                .zts                   = c.phpglue_zts_mode(),
                .build_id              = c.phpglue_module_build_id(),
            };
        }

        fn minitPtr()     ?T.ModuleLifecycleFn { return if (needs_minit_wrapper) &phpzigMinit else null; }
        fn mshutdownPtr() ?T.ModuleLifecycleFn { return if (opts.mshutdown) |_| &phpzigMshutdown else null; }
        fn rinitPtr()     ?T.ModuleLifecycleFn { return if (opts.rinit) |_| &phpzigRinit else null; }
        fn rshutdownPtr() ?T.ModuleLifecycleFn { return if (opts.rshutdown) |_| &phpzigRshutdown else null; }

        fn registerClassWithConstants(comptime cls: ClassDesc, methods_ptr: ?*anyopaque) c_int {
            // registerClassFull 统一处理常量+属性（prop_count=0 时只注册常量）
            return registerClassFull(cls, methods_ptr);
        }

        fn registerClassFull(comptime cls: ClassDesc, methods_ptr: ?*anyopaque) c_int {
            // — 常量打包 —
            const k = cls.class_constants.len;
            var c_keys: [8][*c]const u8 = undefined;
            var c_kls:  [8]usize = undefined;
            var c_vals: [8]?*anyopaque = undefined;
            var c_vls:  [8]usize = undefined;
            var c_types:[8]u8 = undefined;
            var ls_buf: [8]T.zend_long = undefined;
            inline for (cls.class_constants, 0..) |cnst, j| {
                c_keys[j] = cnst.name.ptr;
                c_kls[j]  = cnst.name.len;
                switch (cnst.value) {
                    .long => |v| { ls_buf[j] = v; c_vals[j] = @ptrCast(&ls_buf[j]); c_vls[j] = 0; c_types[j] = 0; },
                    .string => |v| { c_vals[j] = @ptrCast(@constCast(v.ptr)); c_vls[j] = v.len; c_types[j] = 1; },
                }
            }
            // — 属性打包 —
            const p = cls.properties.len;
            if (p > 8) @panic("max 8 properties");
            var p_keys:  [8][*c]const u8 = undefined;
            var p_kls:   [8]usize = undefined;
            var p_vals:  [8]?*anyopaque = undefined;
            var p_vls:   [8]usize = undefined;
            var p_access:[8]u32 = undefined;
            var p_types: [8]u8 = undefined;
            var dbl_buf: [8]f64 = undefined;
            var bl_buf:  [8]u8 = undefined;
            inline for (cls.properties, 0..) |prop, j| {
                p_keys[j] = prop.name.ptr;
                p_kls[j]  = prop.name.len;
                // 运行时解析 access 哨兵 + 默认值
                p_access[j] = switch (prop.access) {
                    1 => c.phpglue_acc_public() | c.phpglue_acc_static(),
                    2 => c.phpglue_acc_protected(),
                    3 => c.phpglue_acc_private(),
                    else => c.phpglue_acc_public(),
                };
                switch (prop.value) {
                    .long   => |v| { ls_buf[j] = v;            p_vals[j] = @ptrCast(&ls_buf[j]); p_vls[j] = 0;           p_types[j] = 0; },
                    .double => |v| { dbl_buf[j] = v;            p_vals[j] = @ptrCast(&dbl_buf[j]); p_vls[j] = 0;           p_types[j] = 1; },
                    .string => |v| { p_vals[j] = @ptrCast(@constCast(v.ptr)); p_vls[j] = v.len; p_types[j] = 2; },
                    .bool   => |v| { bl_buf[j]  = @intFromBool(v); p_vals[j] = @ptrCast(&bl_buf[j]);  p_vls[j] = 0;           p_types[j] = 3; },
                    .null_  => { p_vals[j] = null; p_vls[j] = 0; p_types[j] = 4; },
                }
            }
            return c.phpglue_register_class_full(
                cls.name.ptr, cls.name.len, methods_ptr,
                @intCast(k), &c_keys, &c_kls, &c_vals, &c_vls, &c_types,
                @intCast(p), &p_keys, &p_kls, &p_vals, &p_vls, &p_access, &p_types,
            );
        }

        fn phpzigMinit(type_: c_int, module_number: c_int) callconv(.c) c_int {
            inline for (opts.constants) |cnst| {
                switch (cnst.value) {
                    .long   => |v| c.phpglue_register_constant_long(cnst.name.ptr, cnst.name.len, v, module_number),
                    .double => |v| c.phpglue_register_constant_double(cnst.name.ptr, cnst.name.len, v, module_number),
                    .string => |v| c.phpglue_register_constant_string(cnst.name.ptr, cnst.name.len, v.ptr, v.len, module_number),
                    .bool   => |v| c.phpglue_register_constant_bool(cnst.name.ptr, cnst.name.len, v, module_number),
                    .null_  => c.phpglue_register_constant_null(cnst.name.ptr, cnst.name.len, module_number),
                }
            }
            initClassMethodEntries();
            inline for (opts.classes, 0..) |cls, i| {
                const result: c_int = if (cls.properties.len > 0 or cls.class_constants.len > 0)
                    registerClassFull(cls, class_method_ptrs[i])
                else if (cls.parent_name) |parent_name|
                    c.phpglue_register_class_ex(cls.name.ptr, cls.name.len, class_method_ptrs[i],
                        c.phpglue_lookup_class(parent_name.ptr, parent_name.len) orelse return -1)
                else
                    c.phpglue_register_class(cls.name.ptr, cls.name.len, class_method_ptrs[i]);

                if (result == 0) return -1;
            }
            if (opts.minit) |user_minit| return user_minit(type_, module_number);
            return 0;
        }
        fn phpzigMshutdown(type_: c_int, module_number: c_int) callconv(.c) c_int {
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
