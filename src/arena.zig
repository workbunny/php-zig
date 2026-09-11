//! 请求级内存池（Arena）
//!
//! backing 用 c_allocator（Zig 用 Zig 的，不进 PHP 内存池）——这既是特性也是
//! 风险：大块临时内存不触发 memory_limit，但同样**不受其约束**，进程可在
//! PHP 侧完全无感知的情况下逼近容器上限而被 OOM killer 杀死。
//!
//! 故本模块提供两层保障：
//!   - 可观测：进程级全局计数（usage / peak），跨全部 c_allocator 分配
//!     （含本模块子分配 + 实例自身 + cleanup 注册表，见 memtrack.zig）
//!   - 可约束：INI 配置额度，超限按 reject 语义返回 error.OutOfMemory
//!
//! init() 时自动注册 RSHUTDOWN 回收（bailout-safe），正常路径可
//! `defer arena.deinit()` 提前释放（幂等）。

const std = @import("std");
const Cleanup = @import("cleanup.zig");
const track = @import("memtrack.zig");
const c = @import("php_c.zig");

/// 记账 / 限额作用域。定义在 memtrack（最底层、无 import 依赖），此处转发
/// 供下游与测试引用，避免在 arena 侧再造一个同名枚举导致两套语义。
pub const Scope = track.Scope;

// ＝＝＝＝ 限额配置 ＝＝＝＝

pub const Config = struct {
    /// 显式上限（字节）。0 = 不以此项限制
    limit: usize = 0,
    /// 是否参与 PHP memory_limit 的额度核算
    account_to_php: bool = true,
    /// 降频检查阈值：距上次检查新分配超过该字节数才重新核算 PHP 池用量
    check_interval: usize = 64 * 1024,
    /// 派生值，configure 传入时被忽略；读取请用 `effectiveLimit()`
    effective_limit: usize = 0,
};

// 配置三件套是**进程级**：「框架的 c_allocator 一共能用多少」是进程视角的
// 约束，按请求线程各存一份会让 N 个线程吃掉 N 倍额度。副作用是请求内改配置
// 对整个进程生效——限额应在启动期（INI/MINIT）定好。
var g_limit = std.atomic.Value(usize).init(0);
var g_account_to_php = std.atomic.Value(bool).init(true);
var g_check_interval = std.atomic.Value(usize).init(64 * 1024);

// 派生状态是**线程局部**：effective_limit 里的 PHP 池剩余取自 PG/EG，ZTS 下
// 每请求线程各一份；since_check 只是降频计数，跟着本线程走才有意义。
// NTS 下只有主线程，threadlocal 与全局等价——两种构建行为一致。
threadlocal var g_effective_limit: usize = 0;
threadlocal var g_since_check: usize = 0;

// 显式配置过就锁住：configure() 表达的是明确意图，而 INI 由框架在 RINIT
// 载入。若后者能覆盖前者，下游在 MINIT 里设的限额会在首个请求到来时被
// 静默重置为 INI 默认值——这是最难排查的一类失效。
var g_pinned = std.atomic.Value(bool).init(false);

/// 配置由下游模块设置（MINIT 或请求内均可）。一旦调用，后续
/// `configureFromIni()` 不再覆盖。
/// 未显式配置时：不限制，但计数照常工作——可观测不应依赖是否开启限额。
pub fn configure(cfg: Config) void {
    g_limit.store(cfg.limit, .release);
    g_account_to_php.store(cfg.account_to_php, .release);
    g_check_interval.store(cfg.check_interval, .release);
    g_pinned.store(true, .release);
    recomputeLimit();
}

/// 当前请求线程的有效额度（字节）。0 = 不限。
pub fn effectiveLimit() usize {
    return g_effective_limit;
}

/// 从 INI 读取配置并生效。由 Module 在 **RINIT** 调用（INI 项须已注册）。
///
/// 放在 RINIT 而非 MINIT：INI 值可被 perdir 机制（.htaccess / php_admin_value）
/// 按请求改变，且 ZTS 下 PG 是每请求线程的——只在 MINIT 读，其它请求线程
/// 会一直用默认额度。
///
/// 读取的项：
///   phpzig.arena_limit           字节，0 = 不以此项限制（支持 64M 简写由 PHP 解析）
///   phpzig.arena_account_to_php  1 = 参与 memory_limit 额度核算（默认 1）
///   phpzig.arena_check_interval  距上次核算累积多少字节后重新核算（默认 64K）
///
/// 未注册这些 INI 项时按默认值处理，故本函数可安全调用。
/// 已显式 `configure()` 过时跳过，避免覆盖下游的明确设置。
pub fn configureFromIni() void {
    if (g_pinned.load(.acquire)) return;
    const Ini = @import("ini.zig");
    configure(.{
        .limit = @intCast(@max(0, Ini.getLong("phpzig.arena_limit", 0))),
        .account_to_php = Ini.getBool("phpzig.arena_account_to_php", true),
        .check_interval = @intCast(@max(0, Ini.getLong("phpzig.arena_check_interval", 64 * 1024))),
    });
}

// ＝＝＝＝ 常驻级额度 ＝＝＝＝
//
// 与请求级额度完全独立：常驻内存【不】参与 memory_limit 核算（它跨请求存活，
// 用「每请求的 PHP 池剩余」去约束它会把两个口径混在一起——常驻越多，每个请求
// 可用的 arena 额度越小）。故常驻级只有自己的显式上限。
//
// 额度默认 0（不设防）：容器/进程级内存预算属部署环境策略，骨架不替下游决策
// （见 doc/boundary.md）。要防 OOM kill 请在 INI 里显式设值。
var g_resident_limit = std.atomic.Value(usize).init(0);

/// 设置常驻级额度（字节）。0 = 不设防（默认）。
/// 进程级语义，应在 MINIT / 启动期定好。
pub fn configureResident(limit: usize) void {
    g_resident_limit.store(limit, .release);
}

/// 从 INI 载入常驻级额度。由 Module 在 **MINIT** 调用。
///
/// 与请求级额度放在 RINIT 不同：常驻级是进程级语义，INI 值取启动时的
/// 那份即可，perdir 的按请求覆盖对它没有意义。
///
/// 读取的项：
///   phpzig.resident_limit  字节，0 = 不设防（支持 64M 简写由 PHP 解析）
///
/// 未注册该 INI 项时按默认值处理，故本函数可安全调用。
pub fn configureResidentFromIni() void {
    const Ini = @import("ini.zig");
    configureResident(@intCast(@max(0, Ini.getLong("phpzig.resident_limit", 0))));
}

/// 当前常驻级有效额度（字节）。0 = 不限。
pub fn residentLimit() usize {
    return g_resident_limit.load(.acquire);
}

/// 当前活跃占用（字节）——转发到 memtrack：计数已收敛为
/// 「框架全部 c_allocator 分配」，不只是 RequestArena 子分配
pub fn usage() usize {
    return track.usage();
}

/// 进程内峰值占用（字节）
pub fn peak() usize {
    return track.peak();
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
    var eff = g_limit.load(.acquire);

    if (g_account_to_php.load(.acquire)) {
        const php_limit = php_probes.memory_limit();
        if (php_limit > 0) {
            const used = php_probes.memory_usage(0);
            const remaining = if (php_limit > used) php_limit - used else 0;
            eff = if (eff == 0) remaining else @min(eff, remaining);
        }
    }

    g_effective_limit = eff;
    g_since_check = 0;
}

/// 判断本次分配是否应被拒绝。
///
/// 降频：每次 alloc 都读 PHP 池用量代价过高（zend_memory_usage 要遍历 ZendMM
/// 统计），故累积到 check_interval 才重新核算一次。误差有界——最多多占
/// check_interval 字节，相对 OOM 阈值可忽略。
///
/// 额度按 scope 分流：请求级只读请求级账本——常驻内存（可能从 MINIT 起就
/// 存在、跨请求不释放）【不可能】影响这里的判定。混用两个账本会产生极隐蔽
/// 的失效：常驻内存越大，每个请求可用的 Arena 额度越小。
fn shouldReject(scope: Scope, len: usize) bool {
    switch (scope) {
        .resident => {
            // 常驻级只有自己的显式额度，不读 memory_limit、不做降频核算
            // （这里没有任何昂贵的 PHP 侧调用，无需 check_interval 机制）。
            const eff = g_resident_limit.load(.acquire);
            if (eff == 0) return false; // 不设防（默认）
            return track.usageScope(.resident) + len > eff;
        },
        .request => {},
    }

    if (g_limit.load(.acquire) == 0 and !g_account_to_php.load(.acquire)) {
        return false; // 完全未开启限制，不检查
    }

    g_since_check += len;
    if (g_since_check >= g_check_interval.load(.acquire)) {
        recomputeLimit();
    }

    const eff = g_effective_limit;
    if (eff == 0) return false; // 不限

    return track.usageScope(.request) + len > eff;
}

/// 计数 allocator：包装 c_allocator，累计分配字节并参与**所属作用域**的记账。
/// 作为 Arena 的 backing，arena 的 free 是 no-op，故计数在 arena
/// 存活期间单调增长，deinit 时随子分配释放而回落。
const CountingAllocator = struct {
    total: usize = 0,
    /// 记账与限额归属的作用域，由 Arena 在 init 时写入。
    scope: Scope = .request,

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
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));

        // reject 语义：超限返回 null，由调用方拿到 error.OutOfMemory 后
        // 自行决定降级还是抛异常——框架不替下游决策
        if (shouldReject(self.scope, len)) return null;

        const p = std.heap.c_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.total += len;
        track.trackAlloc(self.scope, len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (std.heap.c_allocator.rawResize(memory, alignment, new_len, ret_addr)) {
            if (new_len > memory.len) {
                const delta = new_len - memory.len;
                self.total += delta;
                track.trackAlloc(self.scope, delta);
            } else {
                const delta = memory.len - new_len;
                self.total -= delta;
                track.trackFree(self.scope, delta);
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
                track.trackAlloc(self.scope, delta);
            } else {
                const delta = memory.len - new_len;
                self.total -= delta;
                track.trackFree(self.scope, delta);
            }
        }
        return new_ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.total -= memory.len;
        track.trackFree(self.scope, memory.len);
        std.heap.c_allocator.rawFree(memory, alignment, ret_addr);
    }
};

/// 统一 Arena 实现：同一套分配 / 记账 / 限额 / 兜底逻辑，按 scope 分两种配置。
///
/// | 维度 | `.request` | `.resident` |
/// |---|---|---|
/// | 生命周期 | 请求级，RSHUTDOWN 兜底 | 模块级，MSHUTDOWN 回收 |
/// | 额度来源 | min(arena_limit, memory_limit 剩余) | resident_limit |
/// | 记账归属 | usageScope(.request) | usageScope(.resident) |
/// | 方法 | allocator / deinit / bytesAllocated | 同左 |
///
/// 差异只有两处：额度来源、是否注册 RSHUTDOWN 钩子。两者共享同一套
/// CountingAllocator 与 reject 语义，故用同一个泛型表达——避免两份会各自
/// 漂移的实现（尤其 reject 判定这类「改一处要同步另一处」的逻辑）。
fn ArenaOf(comptime scope: Scope) type {
    return struct {
        const Self = @This();

        const oom_msg: [:0]const u8 = if (scope == .request)
            "request arena: out of memory"
        else
            "resident arena: out of memory";

        // 进程级单例状态（仅 .resident 实例化时被引用）。
        // 放在泛型内是因为它只对常驻级有意义；.request 下这两个变量不会被
        // 引用，也不会有任何分配。
        //
        // 用自旋锁而非 std.Io.Mutex：后者需要 Io 实例（事件循环），扩展侧
        // 没有；临界区内只有一次 malloc + 几次赋值，不存在阻塞，自旋足够。
        // Zig 0.16 已移除 std.Thread.Mutex，故不依赖标准库互斥量。
        var shared_lock: std.atomic.Mutex = .unlocked;
        var shared_ptr: ?*Self = null;

        inline fn lockShared() void {
            while (!shared_lock.tryLock()) std.atomic.spinLoopHint();
        }

        inline fn unlockShared() void {
            shared_lock.unlock();
        }

        counting: CountingAllocator,
        arena: std.heap.ArenaAllocator,
        deinited: bool,

        /// 堆分配实例。请求级额外注册 RSHUTDOWN 回收（bailout-safe）；
        /// 常驻级不注册任何请求级钩子——它不随请求结束而回收。
        ///
        /// OOM 时**不 panic**——生产环境 panic 等于进程崩溃，且调用方无从补救。
        /// 改为设置 PHP 异常并返回 null：调用方 `orelse return` 即可让 PHP 传播
        /// 异常，也可自行降级后继续。
        pub fn init() ?*Self {
            const self = std.heap.c_allocator.create(Self) catch {
                throwOom(oom_msg);
                return null;
            };
            // 实例自身的堆分配也计入 memtrack——usage() 要回答
            // 「该作用域 c_allocator 一共占了多少」，不能漏掉实例这块
            track.trackAlloc(scope, @sizeOf(Self));
            self.counting = .{ .scope = scope };
            self.arena = std.heap.ArenaAllocator.init(self.counting.allocator());
            self.deinited = false;

            // ★ 生命周期差异的唯一落点：仅请求级挂 RSHUTDOWN 兜底
            if (scope == .request) Cleanup.register(rsDeinit, self);
            return self;
        }

        /// 获取 arena 的 allocator，供 ArrayList/HashMap 等 Zig 数据结构使用。
        /// 分配由本 Arena 兜底回收（请求级 RSHUTDOWN、常驻级手动 deinit/destroy）。
        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.arena.allocator();
        }

        /// 非托管分配入口：返回裸 `c_allocator` —— **不记账、不限额、不回收**。
        ///
        /// 语义上等价于直接用 `std.heap.c_allocator`，此处存在的意义是让「绕过
        /// 托管」这件事在代码里显式、可检索。明确放弃的安全属性：
        ///   1. 不进 `usageScope(scope)`，默认不可观测（要观测请自行
        ///      `Memtrack.trackAlloc/trackFree` 注入）；
        ///   2. 不受本 Arena 的额度约束（请求级 arena_limit / 常驻级
        ///      resident_limit 都管不到它）；
        ///   3. bailout（longjmp 跳过 defer）时无兜底，忘记释放即真泄漏。
        ///
        /// 非必要不使用。
        pub fn unsafeAllocator(self: *Self) std.mem.Allocator {
            _ = self;
            return std.heap.c_allocator;
        }

        /// 释放 arena 全部子分配（幂等，可安全多次调用）。
        /// 正常路径用 `defer arena.deinit()`；请求级 bailout 场景由 RSHUTDOWN 兜底。
        /// 注意：`ArenaAllocator.deinit` 本身非幂等（不置空链表），故用 deinited 标志保护。
        pub fn deinit(self: *Self) void {
            if (self.deinited) return;
            self.arena.deinit();
            self.deinited = true;
        }

        /// 本实例累计分配字节数（arena 场景下 free 为 no-op，故为存活期间的占用量）
        pub fn bytesAllocated(self: *const Self) usize {
            return self.counting.total;
        }

        /// 释放子分配 + 销毁实例自身。【仅 `.resident` 可用】
        ///
        /// 请求级实例的销毁归 RSHUTDOWN 的 rsDeinit ——若允许手动 destroy，
        /// Cleanup 注册表里会留下指向已释放内存的条目，RSHUTDOWN 时野指针。
        pub fn destroy(self: *Self) void {
            if (scope != .resident) @compileError(
                "destroy() 仅 ResidentArena 可用；请求级实例由 RSHUTDOWN 自动销毁",
            );
            self.releaseInstance();
        }

        /// 进程级共享实例。**【仅 `.resident` 可用】**
        ///
        /// 常驻内存天然是「一个进程一份」，故提供单例便利入口：首次调用惰性创建，
        /// 由框架在 MSHUTDOWN 自动释放（见 `shutdown`）。并发首次调用由互斥量
        /// 串行化，ZTS 下安全。
        ///
        /// 生命周期：跨请求存活，**不**随请求结束回收。FPM 下各 worker 进程各有
        /// 一份，不跨进程共享。
        pub fn shared() ?*Self {
            if (scope != .resident) @compileError("shared() 仅 ResidentArena 可用");
            lockShared();
            defer unlockShared();
            if (shared_ptr == null) shared_ptr = Self.init();
            return shared_ptr;
        }

        /// 释放 `shared()` 创建的实例并归零其账目（幂等）。
        /// 由框架在 MSHUTDOWN 调用，也可由下游提前调用做精确控制。
        /// 注意：释放后再次 `shared()` 会重建一个空实例，数据不保留。
        pub fn shutdown() void {
            if (scope != .resident) @compileError("shutdown() 仅 ResidentArena 可用");
            lockShared();
            defer unlockShared();
            if (shared_ptr) |inst| {
                inst.releaseInstance();
                shared_ptr = null;
            }
        }

        /// 内部：归还子分配 + 记账回落 + 销毁堆实例。两条生命周期路径共用。
        fn releaseInstance(self: *Self) void {
            self.deinit();
            track.trackFree(scope, @sizeOf(Self));
            std.heap.c_allocator.destroy(self);
        }

        /// RSHUTDOWN 清理回调：仅请求级注册此回调（见 init）。
        fn rsDeinit(data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(data.?));
            self.releaseInstance();
        }
    };
}

/// 请求级 Arena：跟随请求生命周期，RSHUTDOWN 兜底回收（含 bailout 路径），
/// 额度取 min(phpzig.arena_limit, memory_limit 剩余)，超限按 reject 语义拒绝。
pub const RequestArena = ArenaOf(.request);

/// 常驻级 Arena：跨请求存活，**不**随请求结束回收，额度取
/// `phpzig.resident_limit`（默认 0 = 不设防），不参与 `memory_limit` 核算。
///
/// 两种用法：
///   - `ResidentArena.shared()` —— 进程级单例，MSHUTDOWN 自动释放（推荐）
///   - `ResidentArena.init()`   —— 独立实例，由调用方 `destroy()` 手动释放
pub const ResidentArena = ArenaOf(.resident);

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
    track.resetForTests();
    configure(.{ .account_to_php = false });
    configureResident(0); // 常驻额度复位，避免测试间串味
    ResidentArena.shutdown(); // 清掉可能残留的常驻单例（其内存也计入 usage）
    Cleanup.flush(); // 清空可能残留的注册表（其内存也计入 usage）
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

test "arena: deinit 后子分配计数回落（实例内存待 RSHUTDOWN 释放）" {
    resetGlobals();
    const arena = RequestArena.init().?;
    _ = arena.allocator().alloc(u8, 4096) catch unreachable;
    try testing.expect(usage() >= 4096);

    arena.deinit();
    // ArenaAllocator.deinit 释放全部子分配（触发 CountingAllocator.free）。
    // 剩余 = 实例自身（init trackAlloc @sizeOf=48）+ cleanup 注册表
    // （register 触发的 16×16=256，占用量随历史扩容变化，故不断言精确值）。
    // 关键断言：4096 的子分配已回落，剩余远小于它。
    try testing.expect(usage() < 4096);

    Cleanup.flush();
    // flush 触发 rsDeinit → destroy + trackFree，并释放注册表，全部归零
    try testing.expectEqual(@as(usize, 0), usage());
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
    configure(.{ .limit = 64 * 1024, .account_to_php = false });

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

// 「显式 configure 不被 INI 载入覆盖」的回归在集成测试侧
// （example/tests/test_all.php）：configureFromIni 会调到 phpglue_ini_*，
// 而单测不链接 PHP 运行时——把符号拉进测试二进制在 Windows 上直接链接失败。

test "arena: 未开启限制时不检查" {
    resetGlobals();
    configure(.{ .limit = 0, .account_to_php = false });

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

// ＝＝＝＝ 双作用域隔离回归（红线）＝＝＝＝
//
// 这两个用例守住一条硬约束：请求级的 shouldReject 只读请求级账本。
// 若两个作用域被混成同一个计数器，就会出现「常驻内存越大，每个请求可用的
// arena 额度越小」——表现为本地正常、上线加载完整数据后全量报 OutOfMemory。

test "arena: 常驻计数不挤占请求级额度（红线回归）" {
    resetGlobals();
    configure(.{ .limit = 128 * 1024, .account_to_php = false });

    // 模拟下游在 MINIT 登记 100MB 常驻内存（如常驻词典）
    track.trackAlloc(.resident, 100 * 1024 * 1024);

    // 请求级账本必须纹丝不动 —— 它是 shouldReject 的基数
    try testing.expectEqual(@as(usize, 0), usage());
    try testing.expectEqual(@as(usize, 100 * 1024 * 1024), track.usageScope(.resident));

    // 账本若被混用，这里的 32KB 分配会因为「已占 100MB」而被 reject
    const arena = RequestArena.init().?;
    const buf = arena.allocator().alloc(u8, 32 * 1024) catch unreachable;
    try testing.expectEqual(@as(usize, 32 * 1024), buf.len);

    arena.deinit();
    Cleanup.flush();
    track.trackFree(.resident, 100 * 1024 * 1024);
    try testing.expectEqual(@as(usize, 0), track.total());
}

test "arena: 请求级分配不污染常驻账本" {
    resetGlobals();
    const arena = RequestArena.init().?;
    _ = arena.allocator().alloc(u8, 4096) catch unreachable;

    try testing.expect(usage() >= 4096);
    try testing.expectEqual(@as(usize, 0), track.usageScope(.resident));

    arena.deinit();
    Cleanup.flush();
    try testing.expectEqual(@as(usize, 0), track.total());
}

// ＝＝＝＝ 常驻级（resident）＝＝＝＝

test "arena: 常驻级限额生效 —— 超限返回 OutOfMemory（reject）" {
    resetGlobals();
    configureResident(64 * 1024);

    const arena = ResidentArena.init().?;
    const a = arena.allocator();

    // 额度内应成功
    const first = a.alloc(u8, 32 * 1024) catch unreachable;
    try testing.expectEqual(@as(usize, 32 * 1024), first.len);

    // 持续分配至超限
    var rejected = false;
    for (0..64) |_| {
        _ = a.alloc(u8, 8 * 1024) catch {
            rejected = true;
            break;
        };
    }
    try testing.expect(rejected);

    arena.destroy();
    try testing.expectEqual(@as(usize, 0), track.total());
}

test "arena: 常驻级不随请求结束回收（Cleanup.flush 不影响）" {
    resetGlobals();
    const arena = ResidentArena.init().?;
    _ = arena.allocator().alloc(u8, 4096) catch unreachable;
    try testing.expect(track.usageScope(.resident) >= 4096);

    // 模拟请求结束：flush 只清请求级资源，常驻实例与数据必须原样保留
    Cleanup.flush();
    try testing.expect(track.usageScope(.resident) >= 4096);

    arena.destroy();
    try testing.expectEqual(@as(usize, 0), track.total());
}

test "arena: shared() 单例幂等 + shutdown 归零" {
    resetGlobals();

    const a1 = ResidentArena.shared().?;
    const a2 = ResidentArena.shared().?;
    try testing.expect(a1 == a2); // 同一实例，不是新建

    _ = a1.allocator().alloc(u8, 1024) catch unreachable;
    try testing.expect(track.usageScope(.resident) >= 1024);

    ResidentArena.shutdown();
    ResidentArena.shutdown(); // 幂等
    try testing.expectEqual(@as(usize, 0), track.total());

    // 释放后可重建（数据不保留，属预期语义）
    try testing.expect(ResidentArena.shared() != null);
    ResidentArena.shutdown();
    try testing.expectEqual(@as(usize, 0), track.total());
}

// ＝＝＝＝ 非托管入口（unsafe）＝＝＝＝

test "arena: unsafeAllocator 是裸 c_allocator（不记账、不受额度约束）" {
    resetGlobals();
    configure(.{ .limit = 1, .account_to_php = false }); // 请求级额度压到 1 字节

    const arena = RequestArena.init().?;
    const ua = arena.unsafeAllocator();

    // 基线：实例自身 + Cleanup 注册表（init 时注册，均计入请求级账本）。
    // 必须先确认基线非 0，否则「unsafe 不进账本」这条断言会因记账整体失效
    // 而虚假通过。
    const baseline = track.total();
    try testing.expect(baseline > 0);

    // 绕过额度：即使请求级额度只有 1 字节，unsafe 分配也应成功
    const buf = ua.alloc(u8, 8192) catch unreachable;
    try testing.expectEqual(@as(usize, 8192), buf.len);

    // 且不进账本 —— unsafe 分配前后总账分文不差
    try testing.expectEqual(baseline, track.total());

    ua.free(buf);
    try testing.expectEqual(baseline, track.total());

    arena.deinit();
    Cleanup.flush();
    try testing.expectEqual(@as(usize, 0), track.total());
}
