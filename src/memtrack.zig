//! Zig 侧 c_allocator 分配的进程级记账（memtrack）
//!
//! 背景：框架自身也有不走 RequestArena 的 c_allocator 分配——
//!   - cleanup 注册表动态扩容（cleanup.zig）
//!   - RequestArena 实例自身的堆分配（arena.zig init/destroy）
//! 这些分配零散在各自模块，若各自计数则 `Arena.usage()` 回答不了
//! 「框架 c_allocator 一共占了多少」，测试也覆盖不到。
//!
//! 故把计数收敛到本模块：任何用系统 malloc 的框架代码统一经
//! `trackAlloc`/`trackFree` 记账，`usage()` 即「框架 Zig 侧 c_allocator
//! 总占用」。它同时也是限额判断的基数（见 arena.zig 的 shouldReject）。
//!
//! 用原子而非普通变量：ZTS 下多个请求线程会并发进出这些路径，普通变量
//! 会产生竞争导致计数漂移，进而让限额判断失效。原子成本远低于埋雷代价。

const std = @import("std");

/// 当前活跃占用（全部 c_allocator 分配合计）
var g_live = std.atomic.Value(usize).init(0);
/// 进程内峰值（RSHUTDOWN 后仍保留，供事后排查）
var g_peak = std.atomic.Value(usize).init(0);

/// 当前活跃占用（字节）
pub fn usage() usize {
    return g_live.load(.acquire);
}

/// 进程内峰值占用（字节）
pub fn peak() usize {
    return g_peak.load(.acquire);
}

/// 记一笔分配。`len` 为分配的实际字节数。
pub fn trackAlloc(len: usize) void {
    const cur = g_live.fetchAdd(len, .monotonic) + len;
    var old = g_peak.load(.acquire);
    while (cur > old) {
        old = g_peak.cmpxchgWeak(old, cur, .release, .acquire) orelse return;
    }
}

/// 记一笔释放。饱和减法：直接用 fetchSub 在计数已被减到 0 时会 wrap 成
/// 天文数字，使限额判断彻底失效（表现为「永不超限」）。CAS 循环保证下限为 0。
pub fn trackFree(len: usize) void {
    var old = g_live.load(.acquire);
    while (true) {
        const new = if (old > len) old - len else 0;
        old = g_live.cmpxchgWeak(old, new, .release, .acquire) orelse return;
    }
}

/// 仅测试用：重置计数，避免测试间共享 g_live/g_peak 互相干扰。
pub fn resetForTests() void {
    g_live.store(0, .release);
    g_peak.store(0, .release);
}

// ＝＝＝＝ 单元测试（不依赖 PHP 运行时） ＝＝＝＝

const testing = std.testing;

test "memtrack: alloc + free 对称归零" {
    resetForTests();
    trackAlloc(1024);
    try testing.expectEqual(@as(usize, 1024), usage());
    trackFree(1024);
    try testing.expectEqual(@as(usize, 0), usage());
}

test "memtrack: peak 记录历史高点不回落" {
    resetForTests();
    trackAlloc(512);
    trackAlloc(2048);
    try testing.expectEqual(@as(usize, 2560), usage());
    try testing.expectEqual(@as(usize, 2560), peak());

    trackFree(2048);
    trackFree(512);
    try testing.expectEqual(@as(usize, 0), usage());
    // 峰值是历史高点，释放后仍应保留
    try testing.expectEqual(@as(usize, 2560), peak());
}

test "memtrack: 过度释放不 wrap（饱和到 0）" {
    resetForTests();
    trackAlloc(64);
    trackFree(64);
    trackFree(64); // 重复释放：应饱和到 0，不 wrap 成天文数字
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
    while (i < 1000) : (i += 1) trackAlloc(64);
}
