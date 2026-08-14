//! PHP Fiber（协程）能力
//!
//! 定位：PHP 是调度器（event-loop），Zig 只提供「挂起 / 唤起 / 检测 / 监控」
//! 能力，不自行构建 event-loop。Zig 扩展函数可在 Fiber 内 suspend 自己，
//! 将控制权交还 PHP 主协程；PHP 侧在合适时机 resume，Zig 从挂起点继续执行。
//!
//! 分层设计：
//! - 只读查询（isFiber/getStatus/getCurrent/getReturn）：glue 直读 zend_fiber 结构体，
//!   零方法调用开销。
//! - 控制操作（create/start/suspend/resume/throw）：走 PHP 原生 Fiber 方法调用，
//!   复用其运行时校验与 FiberError 抛出（健壮产出）。
//!
//! 注意：控制操作会触发真正的 C 栈切换（swapcontext/jump_fcontext），
//! 被挂起后 Zig 栈帧冻结，若 Fiber 未完成即被销毁，defer 不会执行，
//! 故需配合 Cleanup 注册表兜底（bailout-safe）。

const c = @import("php_c.zig");
const T = @import("php_types.zig");
const Zval = @import("zval.zig").Zval;
const PhpFunc = @import("php_func.zig");

/// Fiber 状态（对应 zend_fiber_status）
pub const Status = enum(c_int) {
    init = 0, // ZEND_FIBER_STATUS_INIT
    running = 1, // ZEND_FIBER_STATUS_RUNNING
    suspended = 2, // ZEND_FIBER_STATUS_SUSPENDED
    dead = 3, // ZEND_FIBER_STATUS_DEAD
    _,
};

/// 判断 zval 是否为 Fiber 实例
pub fn isFiber(zv: Zval) bool {
    return c.phpglue_zval_is_fiber(zv.ptr) != 0;
}

/// 读取 Fiber 状态；非 Fiber 返回 null
pub fn getStatus(zv: Zval) ?Status {
    const s = c.phpglue_fiber_status(zv.ptr);
    if (s < 0) return null;
    return @enumFromInt(s);
}

/// 获取当前活跃 Fiber 到 rv（ZVAL_OBJ_COPY）；非 Fiber 上下文返回 false
pub fn getCurrent(rv: *T.Zval) bool {
    return c.phpglue_fiber_get_current(rv) != 0;
}

/// 读取 Fiber 返回值到 rv（仅 DEAD 且未抛异常）；失败返回 false
pub fn getReturn(zv: Zval, rv: *T.Zval) bool {
    return c.phpglue_fiber_get_return(zv.ptr, rv) != 0;
}

/// 用 callable 构造 Fiber 对象（等价 new Fiber($callable)）
pub fn create(callable: Zval, rv: *T.Zval) bool {
    return c.phpglue_fiber_create(callable.ptr, rv) != 0;
}

// ＝＝ 控制操作（走 PHP 原生 Fiber 方法，复用校验 + FiberError） ＝＝

/// 启动 Fiber（须在 Fiber 外，status == INIT）
pub fn start(zv: Zval, rv: *T.Zval, args: []const T.Zval) bool {
    return PhpFunc.callMethod(zv.ptr, "start", rv, args);
}

/// 挂起当前 Fiber（须在 Fiber 内，由 Fiber 自身主动挂起）。
/// 命名带下划线：`suspend` 是 Zig 保留关键字（async 语义），不可作标识符。
pub fn suspend_(zv: Zval, value: *T.Zval, rv: *T.Zval) bool {
    return PhpFunc.callMethod(zv.ptr, "suspend", rv, &.{value.*});
}

/// 唤起 Fiber（须在 Fiber 外，status == SUSPENDED）。
/// 命名带下划线：`resume` 是 Zig 保留关键字（async 语义），不可作标识符。
pub fn resume_(zv: Zval, value: *T.Zval, rv: *T.Zval) bool {
    return PhpFunc.callMethod(zv.ptr, "resume", rv, &.{value.*});
}

/// 向 Fiber 注入异常（须在 Fiber 外，status == SUSPENDED）
pub fn throw(zv: Zval, exception: *T.Zval, rv: *T.Zval) bool {
    return PhpFunc.callMethod(zv.ptr, "throw", rv, &.{exception.*});
}
