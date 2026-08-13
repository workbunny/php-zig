//! php-zig 扩展构建辅助
//!
//! 提供 `addPhpExtension` 函数，下游项目在 build.zig 中通过
//! `@import("phpzig").build_php_ext.addPhpExtension(...)` 调用，
//! 一次性完成 PHP 扩展编译的全部通用工作：target/optimize 注册、phpzig 依赖、
//! PHP 头文件路径、C glue 编译、动态库输出。
//!
//! # 注册透传设计
//!
//! `standardTargetOptions` / `standardOptimizeOption` 内部依赖 `b.option` 注册
//! `-Dtarget` / `-Doptimize`，在同一 Build 实例中只能调用一次，重复调用会 panic。
//! 因此由 `addPhpExtension` 统一注册（仅一次），下游若有自己的 `-D` 自定义参数
//! 或额外构建逻辑，通过 `options.configure` 回调透传——在回调里解析自己的参数、
//! 追加 include 路径 / 链接库等，无需关心 target/optimize 的注册。
//!
//! 用法见 example/hello/build.zig（最小）与 example/tests/build.zig（带集成测试）。

const std = @import("std");

/// 透传钩子上下文：下游在 `configure` 回调里解析自定义参数 + 追加构建逻辑。
/// 注意：回调是普通函数（非闭包），无法捕获外层局部变量，所需上下文均由本结构提供。
pub const ExtContext = struct {
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// PHP 安装前缀（与 PhpExtensionOptions.php_prefix 相同）
    php_prefix: []const u8,
};

/// 透传钩子：下游解析自己的 `-D` 参数、配置模块。
/// target/optimize 已由 `addPhpExtension` 注册，下游不应重复调用
/// `standardTargetOptions` / `standardOptimizeOption`。
pub const ConfigureFn = *const fn (ctx: *ExtContext) void;

pub const PhpExtensionOptions = struct {
    /// PHP 安装前缀（用于定位 `include/php/` 头文件）
    php_prefix: []const u8,
    /// 透传钩子（可选）：解析自定义参数 + 追加构建逻辑
    configure: ?ConfigureFn = null,
};

/// 为下游项目创建 PHP 扩展动态库，返回 `*Step.Compile` 供下游追加 step 依赖。
pub fn addPhpExtension(
    b: *std.Build,
    name: []const u8,
    root_source: std.Build.LazyPath,
    options: PhpExtensionOptions,
) *std.Build.Step.Compile {
    // 统一注册 target/optimize（同一 Build 实例仅此一处，勿重复）
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 创建 phpzig 依赖并透传 target/optimize（保证与 ext_module 一致）
    const phpzig_dep = b.dependency("phpzig", .{ .target = target, .optimize = optimize });
    const phpzig_mod = phpzig_dep.module("phpzig");

    const ext_module = b.addModule(name, .{
        .root_source_file = root_source,
        .target = target,
        .optimize = optimize,
    });
    ext_module.addImport("phpzig", phpzig_mod);

    // PHP 头文件路径
    const php_subdirs = [_][]const u8{
        "include/php/main", "include/php",      "include/php/Zend",
        "include/php/ext",  "include/php/TSRM",
    };
    for (php_subdirs) |sub| {
        ext_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ options.php_prefix, sub }) });
    }
    ext_module.addIncludePath(phpzig_dep.path("glue"));
    ext_module.linkSystemLibrary("c", .{});

    // 编译 C glue（随当前 PHP 头文件一起编译，保证 ABI 一致）
    ext_module.addCSourceFile(.{ .file = phpzig_dep.path("glue/php_glue.c"), .flags = &.{} });

    // 透传：下游追加自定义参数解析 + 模块配置
    if (options.configure) |configure| {
        var ctx = ExtContext{ .b = b, .module = ext_module, .target = target, .optimize = optimize, .php_prefix = options.php_prefix };
        configure(&ctx);
    }

    const ext = b.addLibrary(.{ .linkage = .dynamic, .name = name, .root_module = ext_module });
    b.installArtifact(ext);
    return ext;
}
