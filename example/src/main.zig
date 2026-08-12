//! php-zig 示例扩展：hello
//!
//! 演示能力：
//! - 模块级函数、参数 arg_info、异常抛出、模块常量、类注册
//! - P3: 数组迭代器 (hello_iterate)、对象属性 (hello_object)
//! - P4: 数组 pop (hello_pop)、phpinfo() 回调

const std = @import("std");
const phpzig = @import("phpzig");
const T = phpzig.php_types;
const c = phpzig.php_c;

// ＝＝ 既有函数 ＝＝

fn helloWorld(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnString(return_value, "Hello from Zig!");
}

fn helloName(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) { phpzig.Return.returnNull(return_value); return; }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (arg.getType() != T.IS_STRING) { phpzig.Return.returnNull(return_value); return; }
    const name = arg.toStringVal();
    const msg = std.fmt.allocPrint(std.heap.c_allocator, "Hello, {s}!", .{name}) catch { phpzig.Return.returnNull(return_value); return; };
    phpzig.Return.returnString(return_value, msg);
}

fn version(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnString(return_value, "php-zig v0.1.0");
}

fn addFn(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) { phpzig.Return.returnNull(return_value); return; }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    phpzig.Return.returnLong(return_value, (if (a.isLong()) a.toLong() else @as(c_long, 0)) + (if (b.isLong()) b.toLong() else @as(c_long, 0)));
}

fn helloDivide(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) { phpzig.Throw.throwException("Need 2 arguments"); return; }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    if (!a.isLong() or !b.isLong()) { phpzig.Throw.throwException("Both arguments must be integers"); return; }
    if (b.toLong() == 0) { phpzig.Throw.throwException("Division by zero"); return; }
    phpzig.Return.returnLong(return_value, @divTrunc(a.toLong(), b.toLong()));
}

fn helloStrlen(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) { phpzig.Return.returnNull(return_value); return; }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (arg.getType() != T.IS_STRING) { phpzig.Return.returnNull(return_value); return; }
    var retval: T.Zval = undefined;
    if (phpzig.PhpFunc.call1Str("strlen", &retval, arg.toStringVal())) {
        const len = c.phpglue_zval_get_long(&retval);
        c.phpglue_zval_ptr_dtor(&retval);
        phpzig.Return.returnLong(return_value, len);
    } else { phpzig.Return.returnNull(return_value); }
}

fn helloConcat(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) { phpzig.Return.returnNull(return_value); return; }
    const arg1 = phpzig.Return.callArg(execute_data, 1);
    const arg2 = phpzig.Return.callArg(execute_data, 2);
    if (arg1.getType() != T.IS_STRING or arg2.getType() != T.IS_STRING) { phpzig.Return.returnNull(return_value); return; }
    var glue: T.Zval = undefined; c.phpglue_zval_set_stringl(&glue, "", 0);
    var arr: T.Zval = undefined; c.phpglue_array_init(&arr);
    c.phpglue_add_next_index_stringl(&arr, arg1.toStringVal().ptr, arg1.toStringVal().len);
    c.phpglue_add_next_index_stringl(&arr, arg2.toStringVal().ptr, arg2.toStringVal().len);
    defer c.phpglue_zval_ptr_dtor(&arr); defer c.phpglue_zval_ptr_dtor(&glue);
    var retval: T.Zval = undefined;
    if (phpzig.PhpFunc.call("implode", &retval, &.{ glue, arr })) {
        const r = c.phpglue_zval_get_string_val(&retval);
        phpzig.Return.returnString(return_value, r[0..c.phpglue_zval_get_string_len(&retval)]);
        c.phpglue_zval_ptr_dtor(&retval);
    } else { phpzig.Return.returnNull(return_value); }
}

// ＝＝ P3: 数组迭代器 ＝＝

fn helloIterate(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) { phpzig.Return.returnNull(return_value); return; }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (!arg.isArray()) { phpzig.Return.returnNull(return_value); return; }

    // 包装为 Array，创建迭代器遍历
    var arr = phpzig.Array.fromZval(arg);
    var iter = arr.iterator();

    // 手动拼接 — 避免 Zig 0.16 ArrayList([]const u8) aligned 变体 API 差异
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    var first: bool = true;

    // 遍历第一个元素
    if (iter.value()) |val| {
        if (val.isString()) {
            const s = val.toStringVal();
            if (pos + s.len <= buf.len) { @memcpy(buf[pos..][0..s.len], s); pos += s.len; first = false; }
        }
    }
    // 推进并遍历其余元素
    while (iter.next()) {
        if (iter.value()) |val| {
            if (val.isString()) {
                if (!first) { if (pos < buf.len) { buf[pos] = ','; pos += 1; } }
                const s = val.toStringVal();
                if (pos + s.len <= buf.len) { @memcpy(buf[pos..][0..s.len], s); pos += s.len; }
                first = false;
            }
        }
    }

    phpzig.Return.returnString(return_value, buf[0..pos]);
}

// ＝＝ P3: 对象属性读写 ＝＝

fn helloObject(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    _ = execute_data;
    // 创建一个 PHP 对象并设置属性
    var obj: T.Zval = undefined;
    if (!phpzig.PhpFunc.call0("stdClass", &obj)) { phpzig.Return.returnNull(return_value); return; }

    // 写入属性
    var zv_name: T.Zval = undefined; c.phpglue_zval_set_stringl(&zv_name, "php-zig", 7);
    phpzig.Object.writeProperty(&obj, "name", &zv_name);

    // 读取属性
    if (phpzig.Object.readProperty(&obj, "name")) |prop| {
        phpzig.Return.returnString(return_value, prop.toStringVal());
    } else {
        phpzig.Return.returnNull(return_value);
    }
}

// ＝＝ P4: 数组 pop ＝＝

fn helloPop(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) { phpzig.Return.returnNull(return_value); return; }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (!arg.isArray()) { phpzig.Return.returnNull(return_value); return; }

    var arr = phpzig.Array.fromZval(arg);
    if (arr.pop()) |val| {
        phpzig.Return.returnLong(return_value, val.toLong());
    } else {
        phpzig.Return.returnNull(return_value);
    }
}

// ＝＝ P4: phpinfo() 输出 ＝＝

fn helloInfo(module: *phpzig.mod.ZendModuleEntry) callconv(.c) void {
    _ = module;
    // 在 phpinfo 页面输出一段信息
    php_printf("<h2>php-zig</h2><p>PHP extension written in Zig</p>");
}

// ＝＝ 生命周期钩子 ＝＝

fn myMinit(type_: c_int, module_number: c_int) callconv(.c) c_int {
    _ = type_;
    _ = module_number;
    return 0;
}

// ＝＝ 模块注册 ＝＝

const HelloModule = phpzig.Module(.{
    .name = "hello",
    .version = "0.1.0",
    .functions = &.{
        phpzig.FunctionDesc.create("hello_world", helloWorld),
        phpzig.FunctionDesc.create("hello_name", helloName),
        phpzig.FunctionDesc.create("version", version),
        phpzig.FunctionDesc.createWithParams("add", addFn, &.{ phpzig.ParamDesc.create("a"), phpzig.ParamDesc.create("b") }),
        phpzig.FunctionDesc.createWithParams("hello_strlen", helloStrlen, &.{phpzig.ParamDesc.create("str")}),
        phpzig.FunctionDesc.createWithParams("hello_concat", helloConcat, &.{ phpzig.ParamDesc.create("a"), phpzig.ParamDesc.create("b") }),
        phpzig.FunctionDesc.createWithParams("hello_divide", helloDivide, &.{ phpzig.ParamDesc.create("a"), phpzig.ParamDesc.create("b") }),
        phpzig.FunctionDesc.createWithParams("hello_iterate", helloIterate, &.{phpzig.ParamDesc.create("arr")}),
        phpzig.FunctionDesc.create("hello_object", helloObject),
        phpzig.FunctionDesc.createWithParams("hello_pop", helloPop, &.{phpzig.ParamDesc.create("arr")}),
    },
    .minit = myMinit,
    .constants = &.{
        phpzig.ConstantDesc.createLong("HELLO_VERSION", 1),
        phpzig.ConstantDesc.createDouble("HELLO_PI", 3.14159),
        phpzig.ConstantDesc.createString("HELLO_AUTHOR", "php-zig"),
        phpzig.ConstantDesc.createBool("HELLO_DEBUG", false),
        phpzig.ConstantDesc.createNull("HELLO_NULL"),
    },
    .classes = &.{
        phpzig.ClassDesc.createWithConstants("Calculator", &.{
            phpzig.FunctionDesc.createStaticWithParams("add", calcAdd, &.{ phpzig.ParamDesc.create("a"), phpzig.ParamDesc.create("b") }),
            phpzig.FunctionDesc.createStatic("multiply", calcMultiply),
        }, &.{
            phpzig.ClassConstantDesc.createLong("PI", 3),
            phpzig.ClassConstantDesc.createString("NAME", "Calculator"),
        }),
    },
    .info_func = helloInfo,
});

fn calcAdd(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) { phpzig.Return.returnNull(return_value); return; }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    phpzig.Return.returnLong(return_value, (if (a.isLong()) a.toLong() else @as(c_long, 0)) + (if (b.isLong()) b.toLong() else @as(c_long, 0)));
}

fn calcMultiply(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) { phpzig.Return.returnNull(return_value); return; }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    phpzig.Return.returnLong(return_value, (if (a.isLong()) a.toLong() else @as(c_long, 0)) * (if (b.isLong()) b.toLong() else @as(c_long, 0)));
}

comptime { @export(&HelloModule.get_module, .{ .name = "get_module" }); }

extern fn php_printf(fmt: [*c]const u8, ...) void;
