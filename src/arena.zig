//! 请求级内存池（Arena）
//!
//! backing 用 c_allocator（Zig 用 Zig 的，不进 PHP 内存池）——这既是特性也是
//! 风险：大块临时内存不触发 memory_limit，但同样**不受其约束**，进程可在
//! PHP 侧完全无感知的情况下逼近容器上限而被 OOM killer 杀死。
//!
//! 故本模块提供两层保障：
//!   - 可观测：进程级全局计数（usage / peak），跨全部 arena 实例
//!   - 可约束：INI 配置额度，超限按 reject 语义返回 error.OutOfMemory
//!
//! init() 时自动注册 RSHUTDOWN 回收（bailout-safe），正常路径可
//! `defer arena.deinit()` 提前释放（幂等）。

const std = @import("std");
const Cleanup = @import("cleanup.zig");
const c = @import("php_c.zig");

// ＝＝＝＝ 进程级全局计数 ＝＝＝＝
//
// 单个 arena 实例只知道自己分配了多少，回答不了「Zig 侧一共占了多少」——
// 一个请求里往往有若干 arena 并存。故在此做进程级累加。
//
// 用原子而非普通变量：ZTS 下多个请求线程会并发进出这些路径，普通变量会
// 产生竞争导致计数漂移，进而让限额判断失效。原子成本远低于埋雷代价。

/// 当前活跃占用（全部 arena 实例合计）
var g_live = std.atomic.Value(usize).init(0);
/// 进程内峰值（RSHUTDOWN 后仍保留，供事后排查）
var g_peak = std.atomic.Value(usize).init(0);

/// 距上次额度检查以来新分配的字节数，用于降频（见 checkQuota）
var g_since_check = std.atomic.Value(usize).init(0);

// ＝＝＝＝ 限额配置 ＝＝＝＝

pub const Config = struct {
    /// 显式上限（字节）。0 = 不以此项限制
    limit: usize = 0,
    /// 是否参与 PHP memory_limit 的额度核算
    account_to_php: bool = true,
    /// 降频检查阈值：距上次检查新分配超过该字节数才重新核算 PHP 池用量
    check_interval: usize = 64 * 1024,
    /// 当前核算出的有效额度。0 = 不限
    effective_limit: usize = 0,
};

var g_config: Config = .{};

/// 配置由下游模块在 MINIT 设置（或从 INI 读取后填入）。
/// 未显式配置时：不限制，但计数照常工作——可观测不应依赖是否开启限额。
pub fn configure(cfg: Config) void {
    g_config = cfg;
    recomputeLimit();
}

/// 从 INI 读取配置并生效。MINIT 之后调用（INI 项须已注册）。
///
/// 读取的项：
///   phpzig.arena_limit           字节，0 = 不以此项限制（支持 64M 简写由 PHP 解析）
///   phpzig.arena_account_to_php  1 = 参与 memory_limit 额度核算（默认 1）
///   phpzig.arena_check_interval  距上次核算累积多少字节后重新核算（默认 64K）
///
/// 未注册这些 INI 项时按默认值处理，故本函数可安全调用。
pub fn configureFromIni() void {
    const Ini = @import("ini.zig");
    configure(.{
        .limit = @intCast(@max(0, Ini.getLong("phpzig.arena_limit", 0))),
        .account_to_php = Ini.getBool("phpzig.arena_account_to_php", true),
        .check_interval = @intCast(@max(0, Ini.getLong("phpzig.arena_check_interval", 64 * 1024))),
    });
}

/// 当前活跃占用（字节）
pub fn usage() usize {
    return g_live.load(.acquire);
}

/// 进程内峰值占用（字节）
pub fn peak() usize {
    return g_peak.load(.acquire);
}

/// PHP 池用量查询。
///
/// 走函数指针而非直接 extern：arena.zig 的单元测试**不链接 PHP 运行时**
/// （项目约定单测在宿主机裸跑），直接 extern 会导致链接期未定义符号。
/// Module 初始化时把真实实现挂上，测试环境则是空实现。
var php_probes: PhpProbes = .{};

const PhpProbes = struct {
    memory_limit: *const fn () usize = stubMemoryLimit,
    memory_usage: *const fn (c_int) usize = stubMemoryUsage,
    throw_oom: *const fn ([*:0]const u8, usize) void = stubThrow,
};

fn stubMemoryLimit() usize {
    return 0; // 0 = 不限，测试环境不施加 PHP 侧额度
}
fn stubMemoryUsage(_: c_int) usize {
    return 0;
}
fn stubThrow(_: [*:0]const u8, _: usize) void {}

/// 由 Module 在 MINIT 调用，挂载真实 PHP 实现。
/// 未挂载前使用空实现，保证纯 Zig 环境可独立测试。
pub fn bindPhpProbes() void {
    php_probes = .{
        .memory_limit = struct {
            fn f() usize {
                return c.phpglue_memory_limit();
            }
        }.f,
        .memory_usage = struct {
            fn f(real: c_int) usize {
                return c.phpglue_memory_usage(real);
            }
        }.f,
        .throw_oom = struct {
            fn f(msg: [*:0]const u8, len: usize) void {
                c.phpglue_throw_exception(msg, len);
            }
        }.f,
    };
}

/// 重新核算有效额度：取显式上限与 PHP 池剩余中的较小者。
/// account_to_php 关闭时只用显式上限。
fn recomputeLimit() void {
    var eff = g_config.limit;

    if (g_config.account_to_php) {
        const php_limit = php_probes.memory_limit();
        if (php_limit > 0) {
            const used = php_probes.memory_usage(0);
            const remaining = if (php_limit > used) php_limit - used else 0;
            eff = if (eff == 0) remaining else @min(eff, remaining);
        }
    }

    g_config.effective_limit = eff;
    g_since_check.store(0, .release);
}

/// 判断本次分配是否应被拒绝。
///
/// 降频：每次 alloc 都读 PHP 池用量代价过高（zend_memory_usage 要遍历 ZendMM
/// 统计），故累积到 check_interval 才重新核算一次。误差有界——最多多占
/// check_interval 字节，相对 OOM 阈值可忽略。
fn shouldReject(len: usize) bool {
    if (g_config.effective_limit == 0 and g_config.limit == 0 and !g_config.account_to_php) {
        return false; // 完全未开启限制，不检查
    }

    const since = g_since_check.fetchAdd(len, .monotonic) + len;
    if (since >= g_config.check_interval) {
        recomputeLimit();
    }

    const eff = g_config.effective_limit;
    if (eff == 0) return false; // 不限

    return g_live.load(.acquire) + len > eff;
}

/// 计数 allocator：包装 c_allocator，累计分配字节并参与全局计数。
/// 作为 RequestArena 的 backing，arena 的 free 是 no-op，故计数在 arena
/// 存活期间单调增长，deinit 时随子分配释放而回落。
const CountingAllocator = struct {
    total: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        // reject 语义：超限返回 null，由调用方拿到 error.OutOfMemory 后
        // 自行决定降级还是抛异常——框架不替下游决策
        if (shouldReject(len)) return null;

        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = std.heap.c_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.total += len;
        trackAlloc(len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (std.heap.c_allocator.rawResize(memory, alignment, new_len, ret_addr)) {
            if (new_len > memory.len) {
                const delta = new_len - memory.len;
                self.total += delta;
                trackAlloc(delta);
            } else {
                const delta = memory.len - new_len;
                self.total -= delta;
                trackFree(delta);
            }
            return true;
        }
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const new_ptr = std.heap.c_allocator.rawRemap(memory, alignment, new_len, ret_addr);
        if (new_ptr != null) {
            if (new_len > memory.len) {
                const delta = new_len - memory.len;
                self.total += delta;
                trackAlloc(delta);
            } else {
                const delta = memory.len - new_len;
                self.total -= delta;
                trackFree(delta);
            }
        }
        return new_ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.total -= memory.len;
        trackFree(memory.len);
        std.heap.c_allocator.rawFree(memory, alignment, ret_addr);
    }
};

fn trackAlloc(len: usize) void {
    const cur = g_live.fetchAdd(len, .monotonic) + len;
    updatePeak(cur);
}

fn trackFree(len: usize) void {
    // 饱和减法：直接用 fetchSub 在计数已被减到 0 时会 wrap 成天文数字，
    // 使限额判断彻底失效（表现为「永不超限」）。CAS 循环保证下限为 0。
    var old = g_live.load(.acquire);
    while (true) {
        const new = if (old > len) old - len else 0;
        old = g_live.cmpxchgWeak(old, new, .release, .acquire) orelse return;
    }
}

fn updatePeak(cur: usize) void {
    var old = g_peak.load(.acquire);
    while (cur > old) {
        old = g_peak.cmpxchgWeak(old, cur, .release, .acquire) orelse return;
    }
}

pub const RequestArena = struct {
    counting: CountingAllocator,
    arena: std.heap.ArenaAllocator,
    deinited: bool,

    /// 堆分配实例并自动注册 RSHUTDOWN 回收（bailout-safe）。
    ///
    /// OOM 时**不 panic**——生产环境 panic 等于进程崩溃，且调用方无从补救。
    /// 改为设置 PHP 异常并返回 null：调用方 `orelse return` 即可让 PHP 传播
    /// 异常，也可自行降级后继续。
    pub fn init() ?*RequestArena {
        const self = std.heap.c_allocator.create(RequestArena) catch {
            throwOom("request arena: out of memory");
            return null;
        };
        self.counting = .{};
        self.arena = std.heap.ArenaAllocator.init(self.counting.allocator());
        self.deinited = false;
        Cleanup.register(rsDeinit, self);
        return self;
    }

    /// 获取 arena 的 allocator，供 ArrayList/HashMap 等 Zig 数据结构使用。
    pub fn allocator(self: *RequestArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// 释放 arena 全部子分配（幂等，可安全多次调用）。
    /// 正常路径用 `defer arena.deinit()`；bailout 场景由 RSHUTDOWN 兜底。
    /// 注意：`ArenaAllocator.deinit` 本身非幂等（不置空链表），故用 deinited 标志保护。
    pub fn deinit(self: *RequestArena) void {
        if (self.deinited) return;
        self.arena.deinit();
        self.deinited = true;
    }

    /// 本实例累计分配字节数（arena 场景下 free 为 no-op，故为存活期间的占用量）
    pub fn bytesAllocated(self: *const RequestArena) usize {
        return self.counting.total;
    }

    /// RSHUTDOWN 清理回调：幂等释放子分配 + 销毁堆实例。
    fn rsDeinit(data: ?*anyopaque) callconv(.c) void {
        const self: *RequestArena = @ptrCast(@alignCast(data.?));
        self.deinit();
        std.heap.c_allocator.destroy(self);
    }
};

inline fn throwOom(msg: [:0]const u8) void {
    php_probes.throw_oom(msg.ptr, msg.len);
}

// ＝＝＝＝ 单元测试（不依赖 PHP 运行时） ＝＝＝＝
//
// 注意：以下测试通过 std.heap.c_allocator 直接驱动 CountingAllocator，
// 不经过 phpglue_*，故无需 PHP 运行时即可验证计数与限额逻辑。

const testing = std.testing;

/// 重置全局状态。测试间共享 g_live/g_peak，不重置会互相干扰。
///
/// 必须关闭 account_to_php：单测不链接 PHP 运行时，一旦触发
/// recomputeLimit 就会调用 phpglue_memory_limit 等 extern 符号而崩溃。
fn resetGlobals() void {
    g_live.store(0, .release);
    g_peak.store(0, .release);
    g_since_check.store(0, .release);
    g_config = .{ .account_to_php = false };
}

test "arena: 分配 + 计数 + 释放" {
    resetGlobals();
    const arena = RequestArena.init().?;
    const a = arena.allocator();

    const buf = a.alloc(u8, 1024) catch unreachable;
    @memset(buf, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), buf[0]);

    try testing.expect(arena.bytesAllocated() >= 1024);
    try testing.expect(usage() >= 1024);

    arena.deinit();
    Cleanup.flush();
}

test "arena: 全局计数跨实例累加" {
    resetGlobals();
    const a1 = RequestArena.init().?;
    const a2 = RequestArena.init().?;

    _ = a1.allocator().alloc(u8, 1000) catch unreachable;
    _ = a2.allocator().alloc(u8, 2000) catch unreachable;

    // 用 >= 而非 ==：ArenaAllocator 会额外分配内部节点/buffer，
    // bytesAllocated 反映的是**真实内存占用**而非仅用户请求量
    try testing.expect(a1.bytesAllocated() >= 1000);
    try testing.expect(a2.bytesAllocated() >= 2000);
    try testing.expect(usage() >= 3000);

    a1.deinit();
    a2.deinit();
    Cleanup.flush();
}

test "arena: deinit 后全局计数回落" {
    resetGlobals();
    const arena = RequestArena.init().?;
    _ = arena.allocator().alloc(u8, 4096) catch unreachable;
    try testing.expect(usage() >= 4096);

    arena.deinit();
    // ArenaAllocator.deinit 会释放全部子分配，触发 CountingAllocator.free
    try testing.expectEqual(@as(usize, 0), usage());

    Cleanup.flush();
}

test "arena: peak 记录峰值且不回落" {
    resetGlobals();
    const arena = RequestArena.init().?;
    _ = arena.allocator().alloc(u8, 8192) catch unreachable;
    try testing.expect(peak() >= 8192);

    arena.deinit();
    // 峰值是历史高点，释放后仍应保留
    try testing.expect(peak() >= 8192);

    Cleanup.flush();
}

test "arena: 限额生效 —— 超限返回 OutOfMemory（reject）" {
    resetGlobals();
    g_config = .{ .limit = 64 * 1024, .account_to_php = false };
    recomputeLimit();

    const arena = RequestArena.init().?;
    const a = arena.allocator();

    // 额度内应成功。注意额度不仅约束用户请求量，也包含 ArenaAllocator 的
    // 内部节点开销——故首次分配量要留余量
    const first = a.alloc(u8, 32 * 1024) catch unreachable;
    try testing.expectEqual(@as(usize, 32 * 1024), first.len);

    // 持续分配至超限：应在某次被拒绝（reject → error.OutOfMemory）
    var rejected = false;
    for (0..64) |_| {
        _ = a.alloc(u8, 8 * 1024) catch {
            rejected = true;
            break;
        };
    }
    try testing.expect(rejected);

    arena.deinit();
    Cleanup.flush();
}

test "arena: 未开启限制时不检查" {
    resetGlobals();
    g_config = .{ .limit = 0, .account_to_php = false };
    recomputeLimit();

    const arena = RequestArena.init().?;
    const a = arena.allocator();
    // 额度为 0（不限），大块分配也应成功
    _ = a.alloc(u8, 16 * 1024 * 1024) catch unreachable;

    arena.deinit();
    Cleanup.flush();
}

test "arena: deinit 幂等（二次调用不 double free）" {
    resetGlobals();
    const arena = RequestArena.init().?;
    _ = arena.allocator().alloc(u8, 64) catch unreachable;

    arena.deinit();
    arena.deinit(); // 二次 deinit：应被 deinited 标志拦截
    try testing.expectEqual(true, arena.deinited);

    Cleanup.flush();
}

test "arena: 0 字节分配" {
    resetGlobals();
    const arena = RequestArena.init().?;
    const p = arena.allocator().alloc(u8, 0) catch unreachable;
    try testing.expectEqual(@as(usize, 0), p.len);

    arena.deinit();
    Cleanup.flush();
}

test "arena: 跳过 defer 由 RSHUTDOWN 兜底（bailout 路径）" {
    resetGlobals();
    const arena = RequestArena.init().?;
    _ = arena.allocator().alloc(u8, 256) catch unreachable;
    try testing.expect(arena.bytesAllocated() >= 256);

    // 模拟 bailout：不调 deinit，直接 flush
    Cleanup.flush();
    // 计数应回落，否则说明 RSHUTDOWN 路径漏了释放
    try testing.expectEqual(@as(usize, 0), usage());
}
