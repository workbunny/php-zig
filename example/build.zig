//! php-zig 示例扩展构建文件

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const php_prefix = b.option([]const u8, "php", "PHP prefix path (required)") orelse {
        @panic("-Dphp is required! e.g. -Dphp=/usr/local");
    };

    const phpzig_dep = b.dependency("phpzig", .{ .target = target, .optimize = optimize });
    const phpzig_mod = phpzig_dep.module("phpzig");

    // 创建扩展模块并绑定 phpzig
    const ext_module = b.addModule("hello_root", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ext_module.addImport("phpzig", phpzig_mod);

    // PHP 头文件路径
    const subdirs = [_][]const u8{ "include/php/main", "include/php", "include/php/Zend", "include/php/ext", "include/php/TSRM" };
    for (subdirs) |sub| ext_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ php_prefix, sub }) });
    ext_module.addIncludePath(phpzig_dep.path("glue"));
    ext_module.linkSystemLibrary("c", .{});

    // 编译 C glue
    ext_module.addCSourceFile(.{ .file = phpzig_dep.path("glue/php_glue.c"), .flags = &.{} });

    const ext = b.addLibrary(.{ .linkage = .dynamic, .name = "hello", .root_module = ext_module });
    b.installArtifact(ext);

    // ==== 集成测试 ====
    const run_test = b.addSystemCommand(&.{
        b.pathJoin(&.{ php_prefix, "bin/php" }),
        "-d",
        "extension=zig-out/lib/libhello.so",
        "test_all.php",
    });
    run_test.step.dependOn(&ext.step);

    const test_step = b.step("test", "构建扩展并运行 PHP 集成测试");
    test_step.dependOn(&run_test.step);
}
