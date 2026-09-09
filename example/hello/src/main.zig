//! php-zig 最小示例
//!
//! 展示最简模块注册：一个 hello_world 函数 + moduleInit(@This()) 自动发现。

const phpzig = @import("phpzig");
const T = phpzig.php_types;

// 命名约定自动发现：pub fn php_<name> → 模块函数 <name>
// 无参函数须显式声明不做类型约束（编译期校验，v0.10.2 起）
pub const hello_worldUntyped = true;
pub fn php_hello_world(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnString(return_value, "Hello from php-zig!");
}

comptime {
    phpzig.moduleInit(@This(), .{
        .name = "hello",
        .version = "1.0.0",
    });
}
