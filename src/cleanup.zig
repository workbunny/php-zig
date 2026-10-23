//! 请求级清理注册表 + 请求边界事件
//!
//! 供 Zig 侧资源在请求结束（RSHUTDOWN）时统一回收，覆盖 bailout 场景。
//!
//! # 为什么需要「事件补发」
//!
//! PHP 的 bailout（`zend_bailout` → `longjmp`）会跳过 Zig 的 `defer`；当它发生在
//! `PG(modules_activated)` 置位之前的 RINIT 阶段时，`php_request_shutdown` 会整段
//! 跳过模块 RSHUTDOWN。此时 `shutdown_memory_manager()` 照常回收请求堆，但框架的
//! `c_allocator` 分配不归它管 —— 资源既没被 `defer` 释放，也没被引擎回收。
//!
//! 框架因此把「请求结束」抽象成**可补发的事件**：
//!
//! - `beginRequest()`：RINIT 最早期由框架调用。推进 `req_id`，并把当时的条目数
//!   记为 `inherited`。**不执行任何回调、不清空注册表** —— 因为 RINIT 之前
//!   （如 INI 的 `on_modify` 早于模块 RINIT）可能已有本请求的**活**条目，立即执行
//!   会把它们误回收。
//! - `endRequest()`：RSHUTDOWN 调用。**先摘牌、后执行**：摘牌不可失败，执行可能
//!   失败（回调自己也可能 bailout）。幂等，可重复调用。
//!
//! 框架只保证「事件送达」与「事实可读」，**不替下游决定策略**：继承来的条目要不
//! 要执行、要不要丢弃，由下游依据 `stats()` / `reqId()` / `Entry.req` 自行判断。
//!
//! # 下游注入口
//!
//! - `Entry.data`：**调用契约** —— 框架原样传给回调，不解释内容。
//! - `Entry.any`：**纯下游字段** —— 框架永不写入、永不读取，仅在 `registerEx`
//!   注册的回调（`CleanupFnEx`）里作为第二个参数原样传回。
//!
//! 两者生命周期必须 ≥ 条目存活期。条目在 RSHUTDOWN 被跳过时**跨请求存活**，故指向
//! `emalloc` 出来的请求内存（`zend_string` / `Zval` 等）会在下一请求悬垂；指向
//! `c_allocator` 或静态数据才安全。
//!
//! # 线程模型
//!
//! 注册表与请求状态是**线程局部**的：ZTS 下每个请求线程各跑一次 RINIT/RSHUTDOWN，
//! 共享一张表会让请求 A 的条目被请求 B 的 RSHUTDOWN 执行掉。NTS 下只有一个请求
//! 线程，`threadlocal` 与普通全局等价 —— 两种构建下行为一致。
//!
//! 由此推出一条与 ZTS/NTS 无关的使用约束：Zig 侧自开线程里注册的资源没有对应的
//! RSHUTDOWN，要么自行回收，要么把数据交回请求线程处理（跨线程访问请求上下文本身
//! 就是错的，得走 IPC 或显式传参）。
//!
//! 注册表自身用 `c_allocator` 动态扩容（初始 16，翻倍增长），`endRequest()` 时
//! 释放，其生命周期 = 请求生命周期。扩容/释放计入 memtrack：这样 `Arena.usage()`
//! 才能回答「框架 `c_allocator` 一共占了多少」，而不仅是 `RequestArena` 子分配。

const std = @import("std");
const track = @import("memtrack.zig");
const c = @import("php_c.zig");

/// 基础清理回调（`data` 为唯一入参）
pub const CleanupFn = *const fn (data: ?*anyopaque) callconv(.c) void;

/// 扩展清理回调（额外收到 `any` —— 下游注入口，框架不解释）
pub const CleanupFnEx = *const fn (data: ?*anyopaque, any: ?*anyopaque) callconv(.c) void;

/// 回调变体。
///
/// 这是**框架内部的调用约定区分**（basic / ext 两种签名），下游无需关心；它不是
/// 语义标签——语义由下游放进 `Entry.any` 自行表达。
pub const Callback = union(enum) {
    basic: CleanupFn,
    ext: CleanupFnEx,
};

/// 注册表条目：下游可见、可读（`entryAt`），但**不要持有其指针** —— 扩容会搬移。
pub const Entry = struct {
    /// 回调（basic / ext 变体）
    cb: Callback,
    /// 调用契约：框架传给回调的第一个参数，内容框架不解释
    data: ?*anyopaque,
    /// 下游注入口：框架永不写入、永不读取
    any: ?*anyopaque = null,
    /// 归属请求号（`beginRequest` 推进、`register` 打戳）。0 = 尚未进入任何请求
    req: u32 = 0,
};

/// 注册失败原因
pub const RegisterError = error{
    /// `c_allocator` 扩容失败
    OutOfMemory,
    /// 触达 `setMaxEntries()` 设定的上限
    RegistryFull,
};

/// 注册表快照（供下游观测，不含任何策略）
pub const Stats = struct {
    /// 当前请求号（`beginRequest` 每调用一次 +1）
    current_req: u32,
    /// 当前未回收条目数
    pending: usize,
    /// 本请求开始时继承的条目数。
    /// **> 0 说明上一请求的 `endRequest()` 未送达**（典型成因：bailout 跳过了 RSHUTDOWN）
    inherited: usize,
    /// 注册表当前容量（条目数）
    capacity: usize,
    /// 被 `register` / `registerEx` **静默丢弃**的注册次数（累计）。
    /// `tryRegister` / `tryRegisterEx` 的失败不计入（调用方已显式知情）
    dropped: usize,
};

threadlocal var entries: []Entry = &.{};
threadlocal var len: usize = 0;
/// 本请求开始时从上一请求继承的条目数
threadlocal var inherited: usize = 0;
/// 当前请求号（单调递增）
threadlocal var current_req: u32 = 0;
/// 静默丢弃计数（累计，跨请求不清零）
threadlocal var dropped: usize = 0;

/// 条目上限。0 = 不设防（默认，与 `resident_limit` 的约定一致）。
/// 属进程级配置，请在 MINIT 期调用 `setMaxEntries()`，请求期改动不保证可见。
var max_entries: usize = 0;

/// 设置条目上限。`0` 表示不设防。
pub fn setMaxEntries(n: usize) void {
    max_entries = n;
}

// ＝＝ PHP 调用隔离探针 ＝＝
//
// 走函数指针而非直接 extern：cleanup.zig 的单元测试**不链接 PHP 运行时**，
// 直接 extern 会在链接期报未定义符号（与 arena.zig 的 php_probes 同一约定）。
// Module 在 MINIT 挂载真实实现；未挂载前是直调桩——桩无法产生 longjmp，
// 正好等价于「回调从不 bailout」的正常路径。

const PhpProbes = struct {
    invoke_guarded: *const fn (e: Entry) bool = stubInvoke,
    raise_bailout: *const fn () void = stubRaise,
};

var php_probes: PhpProbes = .{};

fn stubInvoke(e: Entry) bool {
    run(e);
    return false;
}

fn stubRaise() void {}

/// 由 Module 在 MINIT 调用，挂载真实 PHP 实现。
/// 未挂载时退化为直调 —— 于是「回调内的 bailout 打断整条链」这一旧行为仍在，
/// 但不会静默：MINIT 总会执行（见 module.zig 的 needs_minit_wrapper）。
pub fn bindPhpProbes() void {
    php_probes = .{
        .invoke_guarded = struct {
            fn f(e: Entry) bool {
                return switch (e.cb) {
                    .basic => |cb| c.phpglue_invoke_guarded1(cb, e.data) != 0,
                    .ext => |cb| c.phpglue_invoke_guarded2(cb, e.data, e.any) != 0,
                };
            }
        }.f,
        .raise_bailout = struct {
            fn f() void {
                c.phpglue_bailout();
            }
        }.f,
    };
}

// ＝＝ 请求边界事件 ＝＝

/// 请求开始事件（RINIT 最早期由框架调用）。
///
/// 只推进 `req_id` 并记录继承条目数，**不执行、不清空、不判断**。
/// 清理由 `endRequest()` 负责；继承条目如何处置由下游决定。
pub fn beginRequest() void {
    current_req +%= 1;
    inherited = len;
}

/// 请求结束事件（RSHUTDOWN 由框架调用，也供下游手动提前调用）。
///
/// **先摘牌、后执行**：摘牌与状态复位不可失败，回调执行可能失败，故必须先把注册表
/// 摘下并复位，再逐个执行 —— 否则回调内 bailout 会让注册表停在"已执行一半、状态
/// 未复位"的中间态。
///
/// **逐条隔离**：每条回调经 glue 的 `zend_try` 包裹调用，其 bailout 不会打断本条链，
/// 从而保证「释放中间数组」这一步一定执行。捕获后**不吞**致命错误：收尾完成即重新
/// bailout，请求照常中止。链上剩余条目不再执行——这是 longjmp 的固有属性，属已声明
/// 边界（见 `doc/boundary.md` §二）。
///
/// 幂等：重复调用只会处理「上一次调用之后新注册的条目」。
pub fn endRequest() void {
    const det = entries;
    const n = len;

    // —— 摘牌（不可失败）——
    entries = &.{};
    len = 0;
    inherited = 0;

    // —— 执行（逐条隔离）——
    var i = n;
    var bailed = false;
    while (i > 0) {
        i -= 1;
        if (php_probes.invoke_guarded(det[i])) {
            bailed = true;
            break;
        }
    }

    // 收尾只做本进程资源释放：捕获 bailout 后引擎已处于中间态，
    // 不得再触碰 Zend 状态（free 中间数组是安全的）。
    if (det.len > 0) {
        track.trackFree(.request, det.len * @sizeOf(Entry));
        std.heap.c_allocator.free(det);
    }

    if (bailed) php_probes.raise_bailout();
}

/// 兼容入口：等价 `endRequest()`。
///
/// 保留旧名以免破坏既有调用点；新代码建议用 `endRequest()` 以表达「请求结束事件」。
pub fn flush() void {
    endRequest();
}

fn run(e: Entry) void {
    switch (e.cb) {
        .basic => |f| f(e.data),
        .ext => |f| f(e.data, e.any),
    }
}

// ＝＝ 观测 ＝＝

/// 当前请求号。0 = 尚未进入任何请求（模块刚加载，或框架尚未接线）。
pub fn reqId() u32 {
    return current_req;
}

/// 注册表快照。框架不打日志、不做告警、不做 metrics —— 只把数字交出去。
pub fn stats() Stats {
    return .{
        .current_req = current_req,
        .pending = len,
        .inherited = inherited,
        .capacity = entries.len,
        .dropped = dropped,
    };
}

/// 读取第 `i` 条（**值拷贝**）。越界返回 null。
///
/// 不提供可变访问、不返回指针：注册表扩容会搬移条目，指针不可持有。
pub fn entryAt(i: usize) ?Entry {
    if (i >= len) return null;
    return entries[i];
}

// ＝＝ 注册 ＝＝

/// 注册清理（basic 变体，`any` 为 null）。
///
/// 失败（OOM / 超上限）时**丢弃该条目**并累加 `stats().dropped`，**不 panic** ——
/// panic 等于 abort worker 进程，会剥夺下游处理 OOM 的机会。需要显式感知失败
/// 请用 `tryRegister()`。
pub fn register(fn_: CleanupFn, data: ?*anyopaque) void {
    registerImpl(.{ .basic = fn_ }, data, null) catch {
        dropped += 1;
    };
}

/// 注册清理（ext 变体，`any` 原样传给回调）。
pub fn registerEx(fn_: CleanupFnEx, data: ?*anyopaque, any: ?*anyopaque) void {
    registerImpl(.{ .ext = fn_ }, data, any) catch {
        dropped += 1;
    };
}

/// 严格注册（basic 变体）：失败返回错误，不静默丢弃。
pub fn tryRegister(fn_: CleanupFn, data: ?*anyopaque) RegisterError!void {
    try registerImpl(.{ .basic = fn_ }, data, null);
}

/// 严格注册（ext 变体）：失败返回错误，不静默丢弃。
pub fn tryRegisterEx(fn_: CleanupFnEx, data: ?*anyopaque, any: ?*anyopaque) RegisterError!void {
    try registerImpl(.{ .ext = fn_ }, data, any);
}

fn registerImpl(cb: Callback, data: ?*anyopaque, any: ?*anyopaque) RegisterError!void {
    if (max_entries != 0 and len >= max_entries) return error.RegistryFull;

    if (len == entries.len) {
        const new_cap: usize = if (entries.len == 0) 16 else entries.len * 2;
        const new_entries = std.heap.c_allocator.alloc(Entry, new_cap) catch
            return error.OutOfMemory;
        track.trackAlloc(.request, new_entries.len * @sizeOf(Entry));
        if (len > 0) {
            @memcpy(new_entries[0..len], entries[0..len]);
            track.trackFree(.request, entries.len * @sizeOf(Entry));
            std.heap.c_allocator.free(entries);
        }
        entries = new_entries;
    }

    entries[len] = .{ .cb = cb, .data = data, .any = any, .req = current_req };
    len += 1;
}

// ＝＝ 下游可用的处置原语 ＝＝

/// 丢弃继承来的条目（**不执行**其回调），只保留本请求注册的部分；返回丢弃条数。
///
/// 供下游在 `beginRequest()` 之后表达「宁可泄漏也不跑陈旧回调」的策略。框架自身
/// 从不调用它 —— 是否该丢弃取决于 `Entry.data` 的归属，只有下游知道。
///
/// 继承条目恒为本请求注册条目的**前缀**（注册表只追加，`endRequest` 整体摘牌）。
pub fn discardInherited() usize {
    const n = @min(inherited, len);
    if (n == 0) {
        inherited = 0;
        return 0;
    }
    const rest = len - n;
    if (rest > 0) std.mem.copyForwards(Entry, entries[0..rest], entries[n..len]);
    len = rest;
    inherited = 0;
    return n;
}

// ＝＝ 单元测试（不依赖 PHP 运行时） ＝＝

const testing = std.testing;

var test_order: [128]u8 = undefined;
var test_idx: usize = 0;
var spawn_hits: usize = 0;
var spawned_hits: usize = 0;
var reset_check_hits: usize = 0;
var ex_data: ?*anyopaque = null;
var ex_any: ?*anyopaque = null;

/// 复位到「模块刚加载、尚未进入任何请求」的状态，并清空用例间的共享计数
/// （注册表与各计数器都是 threadlocal / 全局，用例间必须显式归零）。
fn resetAll() void {
    endRequest();
    current_req = 0;
    inherited = 0;
    dropped = 0;
    max_entries = 0;
    test_idx = 0;
    spawn_hits = 0;
    spawned_hits = 0;
    reset_check_hits = 0;
    ex_data = null;
    ex_any = null;
}

fn cbRecord(data: ?*anyopaque) callconv(.c) void {
    const slot: *u8 = @ptrCast(@alignCast(data.?));
    test_order[test_idx] = slot.*;
    test_idx += 1;
}

/// 计数回调：计数器由调用方通过 data 传入，避免复用共享全局状态
/// （全局 test_idx 在测试并行执行时会竞争）。
fn cbCount(data: ?*anyopaque) callconv(.c) void {
    const slot: *usize = @ptrCast(@alignCast(data.?));
    slot.* += 1;
}

fn cbNoop(_: ?*anyopaque) callconv(.c) void {}

/// 在清理回调内再注册一条：验证「摘牌先于执行」后新条目落入新表。
fn cbSpawn(_: ?*anyopaque) callconv(.c) void {
    spawn_hits += 1;
    register(&cbSpawned, null);
}

fn cbSpawned(_: ?*anyopaque) callconv(.c) void {
    spawned_hits += 1;
}

fn cbResetCheck(_: ?*anyopaque) callconv(.c) void {
    reset_check_hits += 1;
}

/// ext 变体回调：记录框架传回的 data / any 原值。
fn cbEx(data: ?*anyopaque, any: ?*anyopaque) callconv(.c) void {
    ex_data = data;
    ex_any = any;
}

// — 基础形态 —

test "cleanup: 空注册表 endRequest 不崩溃且幂等" {
    resetAll();
    endRequest(); // 清空共享状态
    endRequest(); // 再次调用：无条目，不应崩溃或越界
    try testing.expectEqual(@as(usize, 0), stats().pending);
}

test "cleanup: 单条 register 后未 endRequest 不执行" {
    resetAll();
    var count: usize = 0;
    register(&cbCount, &count);
    // 未送达 endRequest 前回调不应触发
    try testing.expectEqual(@as(usize, 0), count);

    endRequest();
    try testing.expectEqual(@as(usize, 1), count);
}

test "cleanup: endRequest 幂等 —— 回调不被重复执行" {
    resetAll();
    var count: usize = 0;
    register(&cbCount, &count);
    endRequest();
    try testing.expectEqual(@as(usize, 1), count);

    // 二次调用：注册表已清空，回调不应再被执行
    endRequest();
    try testing.expectEqual(@as(usize, 1), count);
}

test "cleanup: LIFO 顺序 + 自动扩容" {
    resetAll();

    // 注册 100 个（远超初始容量 16，验证自动扩容）
    var tags: [100]u8 = undefined;
    for (&tags, 0..) |*t, i| {
        t.* = @intCast(i);
        register(&cbRecord, t);
    }
    try testing.expectEqual(@as(usize, 128), stats().capacity); // 16 -> 32 -> ... -> 128

    endRequest();

    // LIFO：最后注册的先执行
    try testing.expectEqual(@as(usize, 100), test_idx);
    for (0..100) |i| {
        try testing.expectEqual(@as(u8, @intCast(99 - i)), test_order[i]);
    }
}

test "cleanup: 注册表线程隔离（ZTS 下每请求线程各一份）" {
    resetAll();
    var main_count: usize = 0;
    register(&cbCount, &main_count);

    var child_count: usize = 0;
    const t = try std.Thread.spawn(.{}, struct {
        fn f(slot: *usize) void {
            register(&cbCount, slot);
            endRequest();
        }
    }.f, .{&child_count});
    t.join();

    // 子线程的 endRequest 只能执行子线程注册的回调；共享注册表时这里会变成 1
    try testing.expectEqual(@as(usize, 1), child_count);
    try testing.expectEqual(@as(usize, 0), main_count);

    endRequest();
    try testing.expectEqual(@as(usize, 1), main_count);
}

// — 请求边界事件 —

test "cleanup: beginRequest 推进 req_id 且不执行回调" {
    resetAll();
    var count: usize = 0;

    try testing.expectEqual(@as(u32, 0), reqId());
    beginRequest();
    try testing.expectEqual(@as(u32, 1), reqId());

    register(&cbCount, &count);

    // 再进一次请求边界：绝不能在 beginRequest 里执行回调
    beginRequest();
    try testing.expectEqual(@as(u32, 2), reqId());
    try testing.expectEqual(@as(usize, 0), count);
    try testing.expectEqual(@as(usize, 1), stats().pending);

    endRequest();
    try testing.expectEqual(@as(usize, 1), count);
}

test "cleanup: 继承条目 —— 模拟 bailout 跳过 endRequest" {
    resetAll();
    var count: usize = 0;

    beginRequest(); // req 1
    register(&cbCount, &count);
    try testing.expectEqual(@as(usize, 0), stats().inherited);

    // 模拟 bailout：请求 1 的 endRequest 从未送达
    beginRequest(); // req 2
    const s = stats();
    try testing.expectEqual(@as(u32, 2), s.current_req);
    try testing.expectEqual(@as(usize, 1), s.inherited);
    try testing.expectEqual(@as(usize, 1), s.pending);

    // 继承条目的归属戳仍是请求 1
    try testing.expectEqual(@as(u32, 1), entryAt(0).?.req);

    // 本请求新注册的条目归属请求 2
    register(&cbNoop, null);
    try testing.expectEqual(@as(u32, 2), entryAt(1).?.req);

    // endRequest 一次清空全部（框架不区分继承/自有，策略归下游）
    endRequest();
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(usize, 0), stats().pending);
}

test "cleanup: 摘牌语义 —— 回调内注册的条目不被本轮执行" {
    resetAll();
    beginRequest();
    register(&cbSpawn, null);

    endRequest();
    try testing.expectEqual(@as(usize, 1), spawn_hits);
    try testing.expectEqual(@as(usize, 0), spawned_hits);
    // 回调内注册的条目落入新表，等待下一次 endRequest
    try testing.expectEqual(@as(usize, 1), stats().pending);

    endRequest();
    try testing.expectEqual(@as(usize, 1), spawned_hits);
    try testing.expectEqual(@as(usize, 0), stats().pending);
}

test "cleanup: 回调内 bailout 后状态已复位（摘牌先于执行）" {
    resetAll();
    beginRequest();
    register(&cbResetCheck, null);

    endRequest();

    // 摘牌先于执行 ⇒ 即使回调抛出/中止，状态也已复位
    try testing.expectEqual(@as(usize, 0), stats().pending);
    try testing.expectEqual(@as(usize, 0), stats().inherited);
    // 空表再调用一次：不得重复执行
    endRequest();
    try testing.expectEqual(@as(usize, 1), reset_check_hits);
}

// — 下游注入口 any —

test "cleanup: registerEx 把 any 原样传给回调" {
    resetAll();

    var d: u8 = 1;
    var a: u8 = 2;
    registerEx(&cbEx, &d, &a);
    endRequest();

    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&d)), ex_data);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&a)), ex_any);
}

test "cleanup: register（basic 变体）的 any 为 null 且不被框架改动" {
    resetAll();
    var count: usize = 0;
    register(&cbCount, &count);
    try testing.expectEqual(@as(?*anyopaque, null), entryAt(0).?.any);
    endRequest();
    try testing.expectEqual(@as(usize, 1), count);
}

// — 失败可感知 —

test "cleanup: 超上限返回 RegistryFull，静默入口累加 dropped" {
    resetAll();
    setMaxEntries(2);
    beginRequest();

    register(&cbNoop, null);
    register(&cbNoop, null);
    try testing.expectEqual(@as(usize, 2), stats().pending);

    // 严格入口：返回错误，不静默
    try testing.expectError(error.RegistryFull, tryRegister(&cbNoop, null));
    try testing.expectError(error.RegistryFull, tryRegisterEx(&cbEx, null, null));
    try testing.expectEqual(@as(usize, 0), stats().dropped);

    // 静默入口：丢弃并计数
    register(&cbNoop, null);
    registerEx(&cbEx, null, null);
    try testing.expectEqual(@as(usize, 2), stats().dropped);
    try testing.expectEqual(@as(usize, 2), stats().pending);

    endRequest();
    setMaxEntries(0);
}

// — 处置原语 —

test "cleanup: discardInherited 丢弃继承条目且不执行其回调" {
    resetAll();
    var count: usize = 0;

    beginRequest(); // req 1
    register(&cbCount, &count);
    register(&cbCount, &count);

    beginRequest(); // req 2：两条均继承而来
    try testing.expectEqual(@as(usize, 2), stats().inherited);
    register(&cbNoop, null); // 本请求自有
    try testing.expectEqual(@as(usize, 3), stats().pending);

    const n = discardInherited();
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 1), stats().pending);
    try testing.expectEqual(@as(usize, 0), stats().inherited);
    // 保留下来的是本请求注册的那条
    try testing.expectEqual(@as(u32, 2), entryAt(0).?.req);
    // 继承条目被丢弃 ⇒ 其回调从未执行
    try testing.expectEqual(@as(usize, 0), count);

    endRequest();
    try testing.expectEqual(@as(usize, 0), count);
}

test "cleanup: discardInherited 无可丢弃时返回 0" {
    resetAll();
    beginRequest();
    register(&cbNoop, null);
    try testing.expectEqual(@as(usize, 0), discardInherited());
    try testing.expectEqual(@as(usize, 1), stats().pending);
    endRequest();
}

// — 观测 —

test "cleanup: stats 字段随生命周期变化" {
    resetAll();
    const s0 = stats();
    try testing.expectEqual(@as(u32, 0), s0.current_req);
    try testing.expectEqual(@as(usize, 0), s0.pending);
    try testing.expectEqual(@as(usize, 0), s0.capacity);

    beginRequest();
    register(&cbNoop, null);
    const s1 = stats();
    try testing.expectEqual(@as(u32, 1), s1.current_req);
    try testing.expectEqual(@as(usize, 1), s1.pending);
    try testing.expectEqual(@as(usize, 16), s1.capacity);

    endRequest();
    const s2 = stats();
    try testing.expectEqual(@as(usize, 0), s2.pending);
    // 容量随注册表释放归零，便于「请求结束后不留底」的断言
    try testing.expectEqual(@as(usize, 0), s2.capacity);
}

test "cleanup: entryAt 越界返回 null" {
    resetAll();
    beginRequest();
    register(&cbNoop, null);
    try testing.expect(entryAt(0) != null);
    try testing.expectEqual(@as(?Entry, null), entryAt(1));
    try testing.expectEqual(@as(?Entry, null), entryAt(1024));
    endRequest();
    try testing.expectEqual(@as(?Entry, null), entryAt(0));
}

test "cleanup: endRequest 后注册表内存归还（memtrack 回到基线）" {
    resetAll();
    const base = track.usageScope(.request);

    beginRequest();
    for (0..50) |_| register(&cbNoop, null);
    try testing.expect(track.usageScope(.request) > base);

    endRequest();
    try testing.expectEqual(base, track.usageScope(.request));
}
