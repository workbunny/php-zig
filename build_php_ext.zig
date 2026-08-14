//! php-zig 扩展构建辅助
//!
//! 提供 `addPhpExtension` 函数，下游项目在 build.zig 中通过
//! `@import("phpzig").build_php_ext.addPhpExtension(...)` 调用，
//! 一次性完成 PHP 扩展编译的全部通用工作：平台识别、target/optimize 注册、
//! phpzig 依赖、PHP 头文件路径、C glue 编译、动态库输出。
//!
//! # 平台自动识别
//!
//! `-Dphp` 指向的目录是**唯一的平台决策源**：
//! - 编译 `.so`（Linux）：`-Dphp=/usr/local`（php-dev，含 `include/php/main/php_config.h`）
//! - 编译 `.so`（macOS）：`-Dphp=$(brew --prefix php)`（Homebrew，含同路径 `php_config.h`）
//! - 编译 `.dll`：`-Dphp=/path/to/php-devel-pack`（Windows devel-pack，含 `include/main/config.w32.h`）
//!
//! `detectPhpPlatform()` 通过读取 SDK 内容自动识别平台 + 架构 + ZTS + CRT，
//! 据此分叉 target triple、include 路径、import 库、`.def` 导出，
//! 用户零额外参数，控制台输出识别结果。
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
const builtin = @import("builtin");

/// 识别出的 PHP SDK 平台
pub const PhpPlatform = enum {
    /// Linux php-dev（含 `include/php/main/php_config.h`），libc 见 `libc` 字段
    linux,
    /// macOS（Homebrew / 源码编译，含 `include/php/main/php_config.h`），用 Darwin libSystem
    darwin,
    /// Windows devel-pack（含 `include/main/config.w32.h`）
    windows,
};

/// Linux 下 libc 类型
pub const Libc = enum {
    glibc,
    musl,
};

/// 识别结果：SDK 平台 + 架构 + 线程模型 + libc
pub const DetectedSdk = struct {
    platform: PhpPlatform,
    /// 目标 CPU 架构（从 PHP_BUILD_ARCH 或宿主推导）
    arch: std.Target.Cpu.Arch,
    /// 线程模型：true = ZTS（线程安全），false = NTS
    zts: bool,
    /// 仅 Linux 有效（glibc/musl）；darwin/Windows 下无意义（恒 glibc，仅占位）
    libc: Libc = .glibc,
};

/// 透传钩子上下文：下游在 `configure` 回调里解析自定义参数 + 追加构建逻辑。
/// 注意：回调是普通函数（非闭包），无法捕获外层局部变量，所需上下文均由本结构提供。
pub const ExtContext = struct {
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// PHP 安装前缀（与 PhpExtensionOptions.php_prefix 相同）
    php_prefix: []const u8,
    /// 平台识别结果
    sdk: DetectedSdk,
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

// ================================================================
// 平台识别
// ================================================================

/// 探测 `-Dphp` 指向的 SDK 平台。按信号文件优先级判断，读不到则 panic（明确报错）。
pub fn detectPhpPlatform(b: *std.Build, php_prefix: []const u8) DetectedSdk {
    const cwd = std.Io.Dir.cwd();
    const io = b.graph.io;

    // 信号文件：Windows devel-pack 有 include/main/config.w32.h；
    // Linux / macOS 的 php-dev 都有 include/php/main/php_config.h（平台差异由 PHP_OS 分流）。
    const win_config = b.pathJoin(&.{ php_prefix, "include/main/config.w32.h" });
    const unix_config = b.pathJoin(&.{ php_prefix, "include/php/main/php_config.h" });

    const win_ok = fileExists(cwd, io, win_config);
    const unix_ok = fileExists(cwd, io, unix_config);

    if (!win_ok and !unix_ok) {
        std.debug.print(
            \\php-zig: 无法在 -Dphp={s} 下识别 PHP SDK。
            \\  期望以下任一信号文件：
            \\    - Windows devel-pack:    {s}
            \\    - Linux / macOS php-dev: {s}
            \\  提示：Windows 需下载 php-devel-pack-*.zip（含 include/），
            \\        而非运行时发行包 php-*.zip（无 include/ 头文件）；
            \\        Linux 需安装 php-dev（apt/yum）或源码编译，macOS 用 Homebrew/源码编译。
            \\
        , .{ php_prefix, win_config, unix_config });
        @panic("php-zig: 无法识别 PHP SDK 平台");
    }

    if (win_ok) {
        return detectWindowsSdk(b, php_prefix);
    }
    return detectUnixSdk(b, php_prefix);
}

fn detectWindowsSdk(b: *std.Build, php_prefix: []const u8) DetectedSdk {
    const content = readConfigFile(b, b.pathJoin(&.{ php_prefix, "include/main/config.w32.h" }));
    var arch: std.Target.Cpu.Arch = .x86_64;
    var zts = false;

    // 解析 PHP_BUILD_ARCH "x64" / "x86" / "arm64"
    if (extractDefineString(content, "PHP_BUILD_ARCH")) |arch_str| {
        if (std.mem.eql(u8, arch_str, "x64")) {
            arch = .x86_64;
        } else if (std.mem.eql(u8, arch_str, "x86")) {
            arch = .x86;
        } else if (std.mem.eql(u8, arch_str, "arm64")) {
            arch = .aarch64;
        }
    }
    // 解析 ZTS：configure 命令行 --enable-zts → ZTS；--disable-zts → NTS
    if (extractDefineString(content, "CONFIGURE_COMMAND")) |cmd| {
        zts = std.mem.indexOf(u8, cmd, "--enable-zts") != null;
    }

    std.debug.print(
        \\php-zig: 识别到 Windows devel-pack（架构 {s}，{s}）
        \\
    , .{ @tagName(arch), if (zts) "ZTS" else "NTS" });

    // Windows DLL 硬前提：php8.lib / php8ts.lib 是 MSVC 的 COFF import library，
    // 必须以 -msvc 目标链接，而 -msvc 目标依赖主机上的 MSVC 库（Zig 不内置）。
    // 无 MSVC 库则无法产出可被 php8.dll 正确加载的扩展，须明确报错而非静默失败。
    if (!detectMsvc(b, arch)) {
        std.debug.print(
            \\php-zig: 无法编译 Windows DLL —— 缺少 MSVC 库。
            \\  Windows 扩展须链接 MSVC import library（{s}），需以 -msvc 目标 + MSVC 库编译，
            \\  而当前主机（{s}）不满足该前提：
            \\    - Linux / macOS 主机：不支持跨平台产出 Windows DLL，请在 Windows 主机编译。
            \\    - Windows 主机：请安装 Visual Studio 或「Build Tools for Visual Studio」，
            \\      并勾选「MSVC v143 生成工具」+「Windows SDK」。
            \\
        , .{ if (zts) "php8ts.lib" else "php8.lib", @tagName(builtin.os.tag) });
        @panic("php-zig: 缺少 MSVC 库，无法编译 Windows DLL");
    }

    return .{ .platform = .windows, .arch = arch, .zts = zts };
}

/// 检测主机是否具备 MSVC 库（Windows DLL 链接 MSVC import library 的硬前提）。
/// 复用 Zig 自带的 `std.zig.WindowsSdk.find`：`msvc_lib_dir` 非空即代表具备 MSVC 库。
/// 仅 Windows 宿主可能返回 true；Linux / macOS 宿主恒 false（Zig 不内置 MSVC libc）。
fn detectMsvc(b: *std.Build, arch: std.Target.Cpu.Arch) bool {
    const sdk = std.zig.WindowsSdk.find(b.allocator, b.graph.io, arch, &b.graph.environ_map) catch return false;
    defer sdk.free(b.allocator);
    return sdk.msvc_lib_dir != null;
}

fn detectUnixSdk(b: *std.Build, php_prefix: []const u8) DetectedSdk {
    const content = readConfigFile(b, b.pathJoin(&.{ php_prefix, "include/php/main/php_config.h" }));

    // PHP_OS 由 configure 写入 `uname` 输出（configure.ac: PHP_OS=$(uname | xargs)）：
    // macOS 上为 "Darwin"，Linux 上为 "Linux"。据此分流平台。
    const php_os = extractDefineString(content, "PHP_OS") orelse "";
    if (std.mem.indexOf(u8, php_os, "Darwin") != null) {
        std.debug.print(
            \\php-zig: 识别到 macOS php（Darwin libSystem）
            \\
        , .{});
        return .{ .platform = .darwin, .arch = builtin.cpu.arch, .zts = false };
    }

    // __MUSL__ 被 #undef → glibc；#define __MUSL__ 1 → musl
    const libc: Libc = if (std.mem.indexOf(u8, content, "#define __MUSL__ 1") != null) .musl else .glibc;

    std.debug.print(
        \\php-zig: 识别到 Linux php-dev（libc = {s}）
        \\
    , .{@tagName(libc)});

    return .{ .platform = .linux, .arch = builtin.cpu.arch, .zts = false, .libc = libc };
}

/// 判断文件是否存在
fn fileExists(cwd: std.Io.Dir, io: std.Io, path: []const u8) bool {
    cwd.access(io, path, .{}) catch return false;
    return true;
}

/// 读取 config 头文件全文（失败则 panic）
fn readConfigFile(b: *std.Build, path: []const u8) []const u8 {
    const cwd = std.Io.Dir.cwd();
    return cwd.readFileAlloc(b.graph.io, path, b.allocator, .unlimited) catch |e| {
        std.debug.print("php-zig: 读取 {s} 失败：{s}\n", .{ path, @errorName(e) });
        @panic("php-zig: 读取 SDK config 头文件失败");
    };
}

/// 从 `#define NAME "value"` 提取 value（不含引号）；找不到返回 null
fn extractDefineString(content: []const u8, name: []const u8) ?[]const u8 {
    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "#define {s} \"", .{name}) catch return null;
    const start = std.mem.indexOf(u8, content, prefix) orelse return null;
    const val_start = start + prefix.len;
    const rest = content[val_start..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

// ================================================================
// 扩展构建
// ================================================================

/// 为下游项目创建 PHP 扩展动态库，返回 `*Step.Compile` 供下游追加 step 依赖。
pub fn addPhpExtension(
    b: *std.Build,
    name: []const u8,
    root_source: std.Build.LazyPath,
    options: PhpExtensionOptions,
) *std.Build.Step.Compile {
    // 1. 识别平台（据此决定 target 默认值）
    const sdk = detectPhpPlatform(b, options.php_prefix);

    // 2. 根据平台构造 target 默认值；用户仍可用 -Dtarget 覆盖
    const default_target = std.Target.Query{
        .cpu_arch = sdk.arch,
        .os_tag = switch (sdk.platform) {
            .windows => .windows,
            .linux => .linux,
            .darwin => .macos,
        },
        .abi = switch (sdk.platform) {
            .windows => .msvc, // MSVC CRT，对齐 php8.lib 的符号装饰（mingw 与 MSVC import library ABI 不匹配）
            .linux => switch (sdk.libc) {
                .glibc => .gnu,
                .musl => .musl,
            },
            .darwin => .none, // Darwin libSystem，无 gnu/musl 概念
        },
    };
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    // 3. 创建 phpzig 依赖并透传 target/optimize（保证与 ext_module 一致）
    const phpzig_dep = b.dependency("phpzig", .{ .target = target, .optimize = optimize });
    const phpzig_mod = phpzig_dep.module("phpzig");

    const ext_module = b.addModule(name, .{
        .root_source_file = root_source,
        .target = target,
        .optimize = optimize,
    });
    ext_module.addImport("phpzig", phpzig_mod);

    // 4. PHP 头文件路径（平台分叉）
    switch (sdk.platform) {
        .linux, .darwin => {
            const subdirs = [_][]const u8{
                "include/php/main", "include/php",      "include/php/Zend",
                "include/php/ext",  "include/php/TSRM", "include/php/sapi",
            };
            for (subdirs) |sub| {
                ext_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ options.php_prefix, sub }) });
            }
        },
        .windows => {
            const subdirs = [_][]const u8{
                "include/main", "include",      "include/Zend",
                "include/ext",  "include/TSRM", "include/sapi", "include/win32",
            };
            for (subdirs) |sub| {
                ext_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ options.php_prefix, sub }) });
            }
        },
    }
    ext_module.addIncludePath(phpzig_dep.path("glue"));
    ext_module.linkSystemLibrary("c", .{});

    // 5. Windows 平台：链接 import 库（php8.lib NTS / php8ts.lib ZTS）+ 平台宏
    if (sdk.platform == .windows) {
        const lib_name = if (sdk.zts) "php8ts.lib" else "php8.lib";
        const lib_path = b.pathJoin(&.{ options.php_prefix, "lib", lib_name });
        ext_module.addObjectFile(.{ .cwd_relative = lib_path });
        // 官方 win32 构建注入的宏（confutils.js:3246）：/D ZEND_WIN32=1 /D PHP_WIN32=1 /D WIN32 /D _MBCS
        ext_module.addCMacro("ZEND_WIN32", "1");
        ext_module.addCMacro("PHP_WIN32", "1");
        ext_module.addCMacro("WIN32", "1");
        ext_module.addCMacro("_MBCS", "1");
        // ZTS 宏对齐：ZTS 版 devel-pack 需定义 ZTS
        if (sdk.zts) {
            ext_module.addCMacro("ZTS", "1");
        }
    }

    // 6. 编译 C glue（随当前 PHP 头文件一起编译，保证 ABI 一致）
    ext_module.addCSourceFile(.{ .file = phpzig_dep.path("glue/php_glue.c"), .flags = &.{} });

    // 7. 透传：下游追加自定义参数解析 + 模块配置
    if (options.configure) |configure| {
        var ctx = ExtContext{
            .b = b,
            .module = ext_module,
            .target = target,
            .optimize = optimize,
            .php_prefix = options.php_prefix,
            .sdk = sdk,
        };
        configure(&ctx);
    }

    // 8. 输出动态库
    const ext = b.addLibrary(.{ .linkage = .dynamic, .name = name, .root_module = ext_module });

    // 9. Windows：生成 .def 导出 get_module
    if (sdk.platform == .windows) {
        const def = writeGetModuleDef(b, name);
        ext.win32_module_definition = def.path;
        ext.step.dependOn(&def.step.step);
    }

    b.installArtifact(ext);
    return ext;
}

/// 生成 Windows `.def` 文件导出 `get_module`
fn writeGetModuleDef(b: *std.Build, name: []const u8) struct { path: std.Build.LazyPath, step: *std.Build.Step.WriteFile } {
    const def_content = std.fmt.allocPrint(b.allocator, "LIBRARY {s}\nEXPORTS\n    get_module\n", .{name}) catch @panic("OOM");
    const def_file = b.addWriteFiles();
    const path = def_file.add("php_ext.def", def_content);
    return .{ .path = path, .step = def_file };
}
