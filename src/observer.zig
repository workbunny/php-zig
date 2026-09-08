//! Observer — 集中式观察代理（静态注册）
//!
//! 定位：所有关键事件汇聚到一个「代理」入口，由下游 handler 决定
//! 转换 / 统计 / 监测（旁路动作）。观察本身**不拦截**函数执行——
//! 拦截（reject）需走异常系统（Throw）。
//!
//! 静态注册：观察点五类（fcall begin/end、error、function_declared、
//! class_linked、fiber init/switch/destroy），在 MINIT 一次性注册，
//! 之后请求期不变。
//!
//! 注意：fiber 观察回调拿到的是 `zend_fiber_context*`，glue 已将其
//! 转为 status（INIT/RUNNING/SUSPENDED/DEAD）转发。若需 fiber 对象
//! 细节，可配合 `Fiber.getCurrent()` 在事件发生时读取。

const c = @import("php_c.zig");
const T = @import("php_types.zig");

/// Fiber 状态（与 fiber.zig 的 Status 一致，observer 独立使用避免循环依赖）
pub const FiberStatus = enum(c_int) {
    init = 0,
    running = 1,
    suspended = 2,
    dead = 3,
    _,
};

/// 观察点配置 — 各回调可独立为 null，null 表示不观察该类事件
pub const Config = struct {
    fcall_begin: ?c.ObserverFcallBeginFn = null,
    fcall_end: ?c.ObserverFcallEndFn = null,
    /// error 是 Zig 保留字，字段名用 @"error" 转义
    @"error": ?c.ObserverErrorFn = null,
    function_declared: ?c.ObserverDeclaredFn = null,
    class_linked: ?c.ObserverDeclaredFn = null,
    fiber_init: ?c.ObserverFiberInitFn = null,
    fiber_switch: ?c.ObserverFiberSwitchFn = null,
    fiber_destroy: ?c.ObserverFiberDestroyFn = null,
    /// 只观察感兴趣的函数。null 表示观察全部（与未设 filter 时行为一致）。
    fcall_filter: ?c.ObserverFcallFilterFn = null,
};

/// 注册全部观察点（须在 MINIT 阶段调用一次）
pub fn register(cfg: Config) void {
    c.phpglue_observer_register(
        cfg.fcall_begin,
        cfg.fcall_end,
        cfg.@"error",
        cfg.function_declared,
        cfg.class_linked,
        cfg.fiber_init,
        cfg.fiber_switch,
        cfg.fiber_destroy,
        cfg.fcall_filter,
    );
}

/// 从 execute_data 提取当前函数名（仅 fcall begin/end 回调内有效）
pub fn funcName(execute_data: *T.ZendExecuteData) ?[]const u8 {
    var len: usize = 0;
    const ptr = c.phpglue_observer_func_name(execute_data, &len) orelse return null;
    return ptr[0..len];
}

/// 被观察函数自身的信息快照（一次性取全，避免多次跨 ABI 调用取到不一致状态）
pub const FuncInfo = struct {
    /// 函数名；匿名函数/闭包无函数名时为 null
    func_name: ?[]const u8,
    /// 方法所属类名；非方法为 null
    scope_name: ?[]const u8,
    /// 定义所在文件；内部函数（C 实现）为 null
    filename: ?[]const u8,
    /// 定义行号；内部函数为 0
    lineno: u32,
    /// 内部函数（C 实现）为 true，用户函数（PHP 实现）为 false
    internal: bool,
    is_method: bool,
    /// 本次调用传入的参数个数
    num_args: u32,
};

/// 提取被观察函数自身信息（仅 fcall begin/end 回调内有效）。
/// 取的是**被调函数的定义位置**；要定位「谁调用了我」用 `callSite`。
pub fn funcInfo(execute_data: *T.ZendExecuteData) FuncInfo {
    var raw: c.ObserverFuncInfo = undefined;
    c.phpglue_observer_func_info(execute_data, &raw);
    return .{
        .func_name = slice(raw.func_name, raw.func_name_len),
        .scope_name = slice(raw.scope_name, raw.scope_name_len),
        .filename = slice(raw.filename, raw.filename_len),
        .lineno = raw.lineno,
        .internal = raw.internal != 0,
        .is_method = raw.is_method != 0,
        .num_args = raw.num_args,
    };
}

/// 调用点位置——「谁调用了我」，取自 prev_execute_data。
/// 顶层调用（无调用者）或调用者为内部函数时 file 为 null、lineno 为 0。
pub fn callSite(execute_data: *T.ZendExecuteData) struct { file: ?[]const u8, lineno: u32 } {
    var file: ?[*:0]const u8 = null;
    var file_len: usize = 0;
    var lineno: u32 = 0;
    c.phpglue_observer_call_site(execute_data, &file, &file_len, &lineno);
    return .{ .file = slice(file, file_len), .lineno = lineno };
}

fn slice(ptr: ?[*:0]const u8, len: usize) ?[]const u8 {
    const p = ptr orelse return null;
    return p[0..len];
}
