//! php-zig 集成测试扩展构建文件

const std = @import("std");
const build_php_ext = @import("phpzig").build_php_ext;

pub fn build(b: *std.Build) void {
    const php_prefix = b.option([]const u8, "php", "PHP prefix path (required)") orelse {
        @panic("-Dphp is required! e.g. -Dphp=/usr/local");
    };

    // 复用框架构建逻辑（target/optimize 注册 + 依赖 + 头文件 + C glue）
    const ext = build_php_ext.addPhpExtension(b, "ext-tests", b.path("src/main.zig"), .{
        .php_prefix = php_prefix,
    });

    // ==== 集成测试 ====
    const run_test = b.addSystemCommand(&.{
        b.pathJoin(&.{ php_prefix, "bin/php" }),
        "-d",
        "extension=zig-out/lib/libext-tests.so",
        "test_all.php",
    });
    run_test.step.dependOn(&ext.step);

    const test_step = b.step("test", "构建扩展并运行 PHP 集成测试");
    test_step.dependOn(&run_test.step);
}
