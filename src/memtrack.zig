//! Zig 侧 c_allocator 分配的进程级记账（memtrack）
//!
//! 背景：框架自身也有不走 RequestArena 的 c_allocator 分配——
//!   - cleanup 注册表动态扩容（cleanup.zig）
//!   - Arena 实例自身的堆分配（arena.zig init/destroy）
//! 这些分配零散在各自模块，若各自计数则 `Arena.usage()` 回答不了
//! 「框架 c_allocator 一共占了多少」，测试也覆盖不到。
//!
//! 故把计数收敛到本模块：任何用系统 malloc 的框架代码统一经
//! `trackAlloc`/`trackFree` 记账，`usage()` 即「框架 Zig 侧 c_allocator
//! 总占用」。它同时也是限额判断的基数（见 arena.zig 的 shouldReject）。
//!
//! ## 两个作用域（Scope）
//!
//! 计数按 Scope 拆成两套互相隔离的账本：
//!
//! | 作用域 | 生命周期 | 额度来源 | 谁读它 |
//! |---|---|---|---|
//! | `.request` | 请求，RSHUTDOWN 回收 | `arena_limit` ∩ `memory_limit` 剩余 | `shouldReject` 的请求级分支 |
//! | `.resident` | 模块，MSHUTDOWN 回收 | `resident_limit` | `shouldReject` 的常驻级分支 |
//!
//! **隔离是硬约束**：请求级的限额判定只读请求级账本，常驻内存（可能从
//! MINIT 起就存在、跨请求不释放）绝不可能挤占某个请求的 Arena 额度。
//! 反过来，把两个作用域混在一个计数器里会产生一个极隐蔽的失效——常驻
//! 内存越大，每个请求可用的 Arena 额度越小，表现为「本地正常、上线全量
//! 报 OutOfMemory」。故两者不是「同一变量的两个名字」，是两套独立原子。
//!
//! 计数是**进程级**而非请求级：要限制的是整个进程被 OOM killer 杀掉的风险，
//! 按请求线程拆开会让 N 个线程各吃掉一份额度。请求级隔离由 cleanup/arena
//! 各自负责，本模块只回答「进程一共占了多少」。
//!
//! 用原子而非普通变量：ZTS 下多个请求线程会并发进出这些路径，普通变量
//! 会产生竞争导致计数漂移，进而让限额判断失效。原子成本远低于埋雷代价。

const std = @import("std");

/// 记账 / 限额归属的作用域。
/// 定义在最底层（本模块无 import 依赖），供 arena.zig 复用。
pub const Scope = enum {
    /// 请求级：跟随请求生命周期，参与 memory_limit 额度核算
    request,
    /// 常驻级：跨请求存活，独立额度（resident_limit）
    resident,
};

// 两套计数，物理隔离。命名中的 req/res 即作用域。
var g_live_req = std.atomic.Value(usize).init(0);
var g_peak_req = std.atomic.Value(usize).init(0);
var g_live_res = std.atomic.Value(usize).init(0);
var g_peak_res = std.atomic.Value(usize).init(0);

fn livePtr(scope: Scope) *std.atomic.Value(usize) {
    return switch (scope) {
        .request => &g_live_req,
        .resident => &g_live_res,
    };
}

fn peakPtr(scope: Scope) *std.atomic.Value(usize) {
    return switch (scope) {
        .request => &g_peak_req,
        .resident => &g_peak_res,
    };
}

/// 请求级当前活跃占用（字节）。
///
/// 签名与语义与 v0.11.x 完全一致——`Arena.usage()` 转发到这里，
/// 也是 arena 限额判定的基数。要看常驻级请用 `usageScope(.resident)`。
pub fn usage() usize {
    return usageScope(.request);
}

/// 请求级进程内峰值占用（字节）
pub fn peak() usize {
    return peakScope(.request);
}

/// 指定作用域的当前活跃占用（字节）
pub fn usageScope(scope: Scope) usize {
    return livePtr(scope).load(.acquire);
}

/// 指定作用域的进程内峰值占用（字节）
pub fn peakScope(scope: Scope) usize {
    return peakPtr(scope).load(.acquire);
}

/// 进程全景 = 请求级 + 常驻级。仅用于观测，不参与任何限额判定。
pub fn total() usize {
    return usageScope(.request) + usageScope(.resident);
}

/// 记一笔分配。`len` 为分配的实际字节数。
pub fn trackAlloc(scope: Scope, len: usize) void {
    const cur = livePtr(scope).fetchAdd(len, .monotonic) + len;
    const p = peakPtr(scope);
    var old = p.load(.acquire);
    while (cur > old) {
        old = p.cmpxchgWeak(old, cur, .release, .acquire) orelse return;
    }
}

/// 记一笔释放。饱和减法：直接用 fetchSub 在计数已被减到 0 时会 wrap 成
/// 天文数字，使限额判断彻底失效（表现为「永不超限」）。CAS 循环保证下限为 0。
pub fn trackFree(scope: Scope, len: usize) void {
    const p = livePtr(scope);
    var old = p.load(.acquire);
    while (true) {
        const new = if (old > len) old - len else 0;
        old = p.cmpxchgWeak(old, new, .release, .acquire) orelse return;
    }
}

/// 仅测试用：重置计数，避免测试间共享状态互相干扰。
pub fn resetForTests() void {
    g_live_req.store(0, .release);
    g_peak_req.store(0, .release);
    g_live_res.store(0, .release);
    g_peak_res.store(0, .release);
}

// ＝＝＝＝ 单元测试（不依赖 PHP 运行时） ＝＝＝＝

const testing = std.testing;

test "memtrack: alloc + free 对称归零" {
    resetForTests();
    trackAlloc(.request, 1024);
    try testing.expectEqual(@as(usize, 1024), usage());
    trackFree(.request, 1024);
    try testing.expectEqual(@as(usize, 0), usage());
}

test "memtrack: peak 记录历史高点不回落" {
    resetForTests();
    trackAlloc(.request, 512);
    trackAlloc(.request, 2048);
    try testing.expectEqual(@as(usize, 2560), usage());
    try testing.expectEqual(@as(usize, 2560), peak());

    trackFree(.request, 2048);
    trackFree(.request, 512);
    try testing.expectEqual(@as(usize, 0), usage());
    // 峰值是历史高点，释放后仍应保留
    try testing.expectEqual(@as(usize, 2560), peak());
}

test "memtrack: 过度释放不 wrap（饱和到 0）" {
    resetForTests();
    trackAlloc(.request, 64);
    trackFree(.request, 64);
    trackFree(.request, 64); // 重复释放：应饱和到 0，不 wrap 成天文数字
    try testing.expectEqual(@as(usize, 0), usage());
}

test "memtrack: 并发下计数正确（原子性冒烟）" {
    resetForTests();
    var t1 = try std.Thread.spawn(.{}, threadAlloc, .{});
    var t2 = try std.Thread.spawn(.{}, threadAlloc, .{});
    t1.join();
    t2.join();
    // 每个线程分配 1000 次 × 64 字节，应精确累加
    try testing.expectEqual(@as(usize, 2 * 1000 * 64), usage());
}

fn threadAlloc() void {
    var i: usize = 0;
    while (i < 1000) : (i += 1) trackAlloc(.request, 64);
}

test "memtrack: 两个作用域物理隔离（常驻内存不挤占请求级额度）" {
    resetForTests();

    // 模拟下游登记 100MB 常驻内存
    trackAlloc(.resident, 100 * 1024 * 1024);

    try testing.expectEqual(@as(usize, 100 * 1024 * 1024), usageScope(.resident));
    try testing.expectEqual(@as(usize, 100 * 1024 * 1024), peakScope(.resident));
    try testing.expectEqual(@as(usize, 100 * 1024 * 1024), total());

    // 请求级账本【必须】纹丝不动 —— 它是 shouldReject 的基数。
    // 若此处非 0，就会复现「常驻内存越大、请求可用的 arena 额度越小」的隐蔽失效。
    try testing.expectEqual(@as(usize, 0), usage());
    try testing.expectEqual(@as(usize, 0), peak());

    // 反向：请求级分配也不污染常驻账本
    trackAlloc(.request, 4096);
    try testing.expectEqual(@as(usize, 4096), usage());
    try testing.expectEqual(@as(usize, 100 * 1024 * 1024), usageScope(.resident));
    try testing.expectEqual(@as(usize, 100 * 1024 * 1024 + 4096), total());

    trackFree(.request, 4096);
    trackFree(.resident, 100 * 1024 * 1024);
    try testing.expectEqual(@as(usize, 0), total());
}

test "memtrack: resetForTests 清空两个作用域" {
    trackAlloc(.request, 100);
    trackAlloc(.resident, 200);
    resetForTests();
    try testing.expectEqual(@as(usize, 0), total());
    try testing.expectEqual(@as(usize, 0), peakScope(.request));
    try testing.expectEqual(@as(usize, 0), peakScope(.resident));
}
