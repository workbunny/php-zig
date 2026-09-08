//! php-zig benchmark 扩展构建文件（模块 bench_zig → libbench_zig.so）

const std = @import("std");
const build_php_ext = @import("phpzig").build_php_ext;

pub fn build(b: *std.Build) void {
    const php_prefix = b.option([]const u8, "php", "PHP prefix path (required)") orelse {
        @panic("-Dphp is required! e.g. -Dphp=/usr/local");
    };

    _ = build_php_ext.addPhpExtension(b, "bench_zig", b.path("src/main.zig"), .{
        .php_prefix = php_prefix,
    });
}
