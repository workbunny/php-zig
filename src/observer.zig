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
    );
}

/// 从 execute_data 提取当前函数名（仅 fcall begin/end 回调内有效）
pub fn funcName(execute_data: *T.ZendExecuteData) ?[]const u8 {
    var len: usize = 0;
    const ptr = c.phpglue_observer_func_name(execute_data, &len) orelse return null;
    return ptr[0..len];
}
