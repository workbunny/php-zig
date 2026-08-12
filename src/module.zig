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

pub const ParamDesc = struct {
    name: [:0]const u8,
    pub fn create(name: [:0]const u8) ParamDesc { return .{ .name = name }; }
};

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
};

/// 哨兵常量 — 用于区分"用户未设置 flags"和"用户设了 PUBLIC"
const Marker = struct {
    const static_marker: u32 = 0xDEADBEEF;
};

// ＝＝ 类描述符 ＝＝

pub const ClassDesc = struct {
    name:            [:0]const u8,
    methods:         []const FunctionDesc,
    parent_name:     ?[:0]const u8 = null,
    class_constants: []const ClassConstantDesc = &.{},

    pub fn create(name: [:0]const u8, methods: []const FunctionDesc) ClassDesc {
        return .{ .name = name, .methods = methods };
    }
    pub fn createExtends(name: [:0]const u8, parent: [:0]const u8, methods: []const FunctionDesc) ClassDesc {
        return .{ .name = name, .methods = methods, .parent_name = parent };
    }
    pub fn createWithConstants(name: [:0]const u8, methods: []const FunctionDesc, constants: []const ClassConstantDesc) ClassDesc {
        return .{ .name = name, .methods = methods, .class_constants = constants };
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

        /// 将方法 flags 哨兵转换为运行时 ACC 标志
        fn resolveFlags(desc: FunctionDesc) u32 {
            if (desc.flags == Marker.static_marker) {
                return c.phpglue_acc_public() | c.phpglue_acc_static();
            }
            if (desc.flags != 0) return desc.flags;
            return c.phpglue_acc_public();
        }

        /// 解析 arg_info + num_args
        fn resolveArgInfo(desc: FunctionDesc, arginfo_offset: *usize) struct { ptr: ?*anyopaque, num: u32 } {
            if (desc.arg_info) |a| return .{ .ptr = a, .num = 0 };
            if (desc.params.len == 0) return .{ .ptr = c.phpglue_get_empty_arg_info(), .num = 0 };

            const required = desc.params.len;
            const off      = arginfo_offset.*;
            const byte_off = off * ARGINFO_ENTRY_SIZE_MAX;

            var name_ptrs: [8][*c]const u8 = undefined;
            if (desc.params.len > 8) @panic("max 8 params supported for arg_info");
            for (desc.params, 0..) |p, j| name_ptrs[j] = p.name.ptr;

            var entry_count: usize = 0;
            c.phpglue_fill_arg_info(
                @ptrCast(&param_entries_buf[byte_off]),
                @intCast(required), &name_ptrs, required,
                &entry_count,
            );
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
                const result = if (cls.parent_name) |parent_name|
                    c.phpglue_register_class_ex(cls.name.ptr, cls.name.len, class_method_ptrs[i],
                        c.phpglue_lookup_class(parent_name.ptr, parent_name.len) orelse return -1)
                else
                    c.phpglue_register_class(cls.name.ptr, cls.name.len, class_method_ptrs[i]);
                if (result == 0) return -1;

                // 注册类常量
                const ce = c.phpglue_lookup_class(cls.name.ptr, cls.name.len) orelse return -1;
                inline for (cls.class_constants) |cnst| {
                    switch (cnst.value) {
                        .long   => |v| c.phpglue_declare_class_constant_long(ce, cnst.name.ptr, cnst.name.len, v),
                        .string => |v| c.phpglue_declare_class_constant_string(ce, cnst.name.ptr, cnst.name.len, v.ptr, v.len),
                    }
                }
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
