//! 请求级内存池（Arena）
//!
//! 实例化创建的请求级 arena，backing 用 c_allocator（Zig 用 Zig 的，
//! 不进 PHP 内存池）。init() 时自动注册 RSHUTDOWN 回收（bailout-safe），
//! 正常路径可 `defer arena.deinit()` 提前释放（幂等）。
//!
//! 内置计数 allocator，暴露累计分配字节，供后续统计/调试模块读取
//! （配合 PHP 的 memory_get_usage() 输出总占用对比）。

const std = @import("std");
const Cleanup = @import("cleanup.zig");

/// 计数 allocator：包装 c_allocator，累计分配字节数。
/// 作为 RequestArena 的 backing，arena 的 free 是 no-op，故 total 单调增长，
/// 反映「请求内累计分配总量」。
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
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = std.heap.c_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.total += len;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (std.heap.c_allocator.rawResize(memory, alignment, new_len, ret_addr)) {
            if (new_len > memory.len) self.total += new_len - memory.len;
            return true;
        }
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const new_ptr = std.heap.c_allocator.rawRemap(memory, alignment, new_len, ret_addr);
        if (new_ptr != null) {
            if (new_len > memory.len) {
                self.total += new_len - memory.len;
            } else {
                self.total -= memory.len - new_len;
            }
        }
        return new_ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.total -= memory.len;
        std.heap.c_allocator.rawFree(memory, alignment, ret_addr);
    }
};

pub const RequestArena = struct {
    counting: CountingAllocator,
    arena: std.heap.ArenaAllocator,
    deinited: bool,

    /// 堆分配实例并自动注册 RSHUTDOWN 回收（bailout-safe）。
    /// 返回 *RequestArena，其 allocator 的 backing 计数状态位于堆上，地址稳定。
    pub fn init() *RequestArena {
        const self = std.heap.c_allocator.create(RequestArena) catch
            @panic("request arena: out of memory");
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

    /// 累计分配字节数（arena 场景下 free 为 no-op，故为峰值/累计值）。
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

// ＝＝ 单元测试（不依赖 PHP 运行时） ＝＝

const testing = std.testing;

test "request arena: 分配 + 计数 + 释放" {
    const arena = RequestArena.init();
    const a = arena.allocator();

    // 分配并写入（arena 的 free 是 no-op，无需逐个 free，deinit 一次性回收）
    const buf = a.alloc(u8, 1024) catch unreachable;
    @memset(buf, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), buf[0]);

    // 计数单调增长，至少覆盖 1024 字节
    try testing.expect(arena.bytesAllocated() >= 1024);

    // 正常路径释放子分配 + flush 触发 RSHUTDOWN 销毁实例
    arena.deinit();
    Cleanup.flush();
}
