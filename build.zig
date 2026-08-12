//! php-zig 框架构建文件
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("phpzig", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 纯 Zig 单元测试（无需 PHP 运行时）
    const test_mod = b.addModule("test_helpers", .{
        .root_source_file = b.path("src/test_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "运行纯 Zig 单元测试");
    test_step.dependOn(&run_unit_tests.step);
}
