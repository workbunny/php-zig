//! 请求级清理注册表
//!
//! 供 Zig 侧资源在请求结束（RSHUTDOWN）时统一回收，覆盖 bailout 场景。
//! PHP 的 bailout（longjmp）会跳过 Zig 的 defer，但 RSHUTDOWN 在 bailout 后
//! 仍会执行，故此处兜底回收被跳过的资源。
//!
//! 注册表自身用 c_allocator 动态扩容（初始 16，翻倍增长），RSHUTDOWN 时
//! 释放，不引入额外泄漏——其生命周期 = 请求生命周期，由 flush() 兜底。
//! 扩容/释放计入 memtrack：这样 Arena.usage() 才能回答「框架 c_allocator
//! 一共占了多少」，而不仅是 RequestArena 子分配。

const std = @import("std");
const track = @import("memtrack.zig");

/// 清理回调签名（C ABI，与 Cleanup.register 一致）
pub const CleanupFn = *const fn (data: ?*anyopaque) callconv(.c) void;

const Entry = struct {
    fn_: CleanupFn,
    data: ?*anyopaque,
};

var entries: []Entry = &.{};
var len: usize = 0;

/// 注册清理：请求结束（RSHUTDOWN）时按 LIFO 顺序调用 fn(data)。
/// bailout 后 RSHUTDOWN 仍执行，故可兜住被 longjmp 跳过的 defer。
pub fn register(fn_: CleanupFn, data: ?*anyopaque) void {
    if (len == entries.len) {
        const new_cap: usize = if (entries.len == 0) 16 else entries.len * 2;
        const new_entries = std.heap.c_allocator.alloc(Entry, new_cap) catch
            @panic("cleanup registry: out of memory");
        track.trackAlloc(new_entries.len * @sizeOf(Entry));
        if (len > 0) {
            @memcpy(new_entries[0..len], entries[0..len]);
            track.trackFree(entries.len * @sizeOf(Entry));
            std.heap.c_allocator.free(entries);
        }
        entries = new_entries;
    }
    entries[len] = .{ .fn_ = fn_, .data = data };
    len += 1;
}

/// RSHUTDOWN 调用：LIFO 执行全部清理，并释放注册表自身内存。
/// 由 Module 的 rshutdown wrapper 自动触发，无需用户显式调用。
pub fn flush() void {
    var i = len;
    while (i > 0) {
        i -= 1;
        entries[i].fn_(entries[i].data);
    }
    if (entries.len > 0) {
        track.trackFree(entries.len * @sizeOf(Entry));
        std.heap.c_allocator.free(entries);
        entries = &.{};
    }
    len = 0;
}

// ＝＝ 单元测试（不依赖 PHP 运行时） ＝＝

const testing = std.testing;

var test_order: [128]u8 = undefined;
var test_idx: usize = 0;

fn cbRecord(data: ?*anyopaque) callconv(.c) void {
    const c: *u8 = @ptrCast(@alignCast(data.?));
    test_order[test_idx] = c.*;
    test_idx += 1;
}

/// 计数回调：计数器由调用方通过 data 传入，避免复用共享全局状态
/// （全局 test_idx 在测试并行执行时会竞争）。
fn cbCount(data: ?*anyopaque) callconv(.c) void {
    const c: *usize = @ptrCast(@alignCast(data.?));
    c.* += 1;
}

test "cleanup: 空注册表 flush 不崩溃" {
    flush(); // 清空共享状态
    flush(); // 再次 flush：无条目，不应崩溃或越界
}

test "cleanup: flush 幂等 —— 回调不被重复执行" {
    flush();
    var count: usize = 0;
    register(&cbCount, &count);
    flush();
    try testing.expectEqual(@as(usize, 1), count);

    // 二次 flush：注册表已清空，回调不应再被执行
    flush();
    try testing.expectEqual(@as(usize, 1), count);
}

test "cleanup: 单条 register 后未 flush 不执行" {
    flush();
    var count: usize = 0;
    register(&cbCount, &count);
    // 未 flush 前回调不应触发
    try testing.expectEqual(@as(usize, 0), count);

    flush();
    try testing.expectEqual(@as(usize, 1), count);
}

test "cleanup: LIFO 顺序 + 自动扩容" {
    flush(); // 清空，避免与其他测试共享状态
    test_idx = 0;

    // 注册 100 个（远超初始容量 16，验证自动扩容）
    var tags: [100]u8 = undefined;
    for (&tags, 0..) |*t, i| {
        t.* = @intCast(i);
        register(&cbRecord, t);
    }

    flush();

    // LIFO：最后注册的先执行
    try testing.expectEqual(@as(usize, 100), test_idx);
    for (0..100) |i| {
        try testing.expectEqual(@as(u8, @intCast(99 - i)), test_order[i]);
    }
}
