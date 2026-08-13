//! PHP 闭包创建
//!
//! 从 Zig 函数处理器创建 PHP Closure，可传给 PHP 侧（如 array_map、回调参数）。

const c = @import("php_c.zig");
const T = @import("php_types.zig");

/// 从 Zig 函数处理器创建 PHP Closure。
///
/// handler 为标准 `zif_handler` 签名的函数指针，name 为闭包内部函数名
/// （通常无实际含义，取 "{closure}" 或任意描述性名字）。
///
/// ```zig
/// fn myCallback(execute_data: *phpzig.ZendExecuteData, rv: *phpzig.Zval) callconv(.c) void {
///     phpzig.Return.returnString(rv, "from closure");
/// }
///
/// var closure_zv: T.Zval = undefined;
/// phpzig.Closure.create(myCallback, "my_callback", &closure_zv);
/// ```
pub fn create(handler: T.FunctionHandler, name: []const u8, zv: *T.Zval) void {
    c.phpglue_create_closure(zv, handler, name.ptr, name.len);
}
