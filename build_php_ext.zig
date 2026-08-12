//! php-zig 扩展构建辅助
//!
//! 提供 addPhpExtension 函数，下游项目在 build.zig 中直接调用。
//! 完成所有 PHP 扩展编译的通用工作：PHP 头文件路径、C glue 编译、动态库输出。
//!
//! 下游项目只需：
//! 1. 在 build.zig.zon 中添加 phpzig 依赖
//! 2. 在 build.zig 中调用 addPhpExtension
//!
//! 用法见 example/build.zig。

const std = @import("std");

pub const PhpExtensionOptions = struct {
    php_prefix: []const u8,
};

/// 为下游项目创建 PHP 扩展动态库
pub fn addPhpExtension(
    b: *std.Build,
    name: []const u8,
    root_source: std.Build.LazyPath,
    phpzig_dep: *std.Build.Dependency,
    options: PhpExtensionOptions,
) *std.Build.Step.Compile {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const phpzig_mod = phpzig_dep.module("phpzig");

    // PHP 头文件路径
    const php_subdirs = [_][]const u8{
        "include/php/main", "include/php", "include/php/Zend",
        "include/php/ext", "include/php/TSRM",
    };

    const ext_module = b.addModule(name, .{
        .root_source_file = root_source,
        .target = target,
        .optimize = optimize,
    });
    ext_module.addImport("phpzig", phpzig_mod);

    for (php_subdirs) |sub| {
        ext_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ options.php_prefix, sub }) });
    }
    ext_module.addIncludePath(phpzig_dep.path("glue"));
    ext_module.linkSystemLibrary("c", .{});

    // 编译 C glue（每次构建都会重新编译，确保与当前 PHP 头文件一致）
    ext_module.addCSourceFile(.{ .file = phpzig_dep.path("glue/php_glue.c"), .flags = &.{} });

    const ext = b.addLibrary(.{ .linkage = .dynamic, .name = name, .root_module = ext_module });
    b.installArtifact(ext);
    return ext;
}
