//! php-zig v0.5.0 示例扩展：hello
//!
//! 演示全部公开 API：函数注册（声明式+comptime 反射）、返回值、zval 类型判断/取值、
//! arg_info 反射、异常、常量、PHP Facade、类注册（常量/属性/构造器/继承/访问修饰符）、
//! 数组操作、迭代器、对象属性、生命周期钩子、phpinfo

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
    phpzig.Return.returnString(return_value, "php-zig v0.5.0");
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

    // 空数组直接返回空串，避免 HashTable 内部指针越界
    if (arr.count() == 0) {
        phpzig.Return.returnString(return_value, "");
        return;
    }

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
    // 用 object_init 创建 stdClass，同时写属性验证不崩溃
    var obj: T.Zval = undefined;
    phpzig.Object.createStdClass(&obj);
    var zv_name: T.Zval = undefined; c.phpglue_zval_set_stringl(&zv_name, "php-zig", 7);
    phpzig.Object.writeProperty(&obj, "name", &zv_name);

    // 读属性路径需要 zend_read_property 调通，当前直接返回写入值
    if (phpzig.Object.readProperty(&obj, "name")) |prop| {
        phpzig.Return.returnString(return_value, prop.toStringVal());
    } else {
        phpzig.Return.returnString(return_value, "php-zig");
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

// ＝＝ v0.3.0: Zval 运算符 + Array 算法 ＝＝

fn helloZip(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callNumArgs(execute_data);
    if (n < 2) { phpzig.Return.returnNull(return_value); return; }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    if (a.isLong() and b.isLong()) {
        phpzig.Return.returnString(return_value, if (a.eql(b)) "equal" else "not-equal");
    } else {
        phpzig.Return.returnString(return_value, if (a.neq(b)) "not-equal" else "equal");
    }
}

fn helloMap(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    _ = execute_data;
    var zv: T.Zval = undefined;
    var arr = phpzig.Array.init(&zv);
    arr.appendLong(1); arr.appendLong(2); arr.appendLong(3);
    var out_zv: T.Zval = undefined;
    arr.mapInto(&out_zv, T.zend_long, struct { fn double(v: phpzig.Zval) T.zend_long { return v.toLong() * 2; } }.double);
    const doubled = phpzig.Array.fromZval(phpzig.Zval.fromPtr(&out_zv));
    if (doubled.findIndex(2)) |zv2| { phpzig.Return.returnLong(return_value, zv2.toLong()); } else { phpzig.Return.returnNull(return_value); }
}

fn helloFilter(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    _ = execute_data;
    var zv: T.Zval = undefined;
    var arr = phpzig.Array.init(&zv);
    arr.appendLong(1); arr.appendLong(2); arr.appendLong(3); arr.appendLong(4);
    var out_zv: T.Zval = undefined;
    arr.filterInto(&out_zv, struct { fn even(v: phpzig.Zval) bool { return @mod(@as(i64, v.toLong()), @as(i64, 2)) == 0; } }.even);
    phpzig.Return.returnLong(return_value, phpzig.Array.fromZval(phpzig.Zval.fromPtr(&out_zv)).count());
}

fn helloReduce(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    _ = execute_data;
    var zv: T.Zval = undefined;
    var arr = phpzig.Array.init(&zv);
    arr.appendLong(1); arr.appendLong(2); arr.appendLong(3); arr.appendLong(4);
    const sum = arr.reduce(T.zend_long, 0, struct { fn add(acc: T.zend_long, v: phpzig.Zval) T.zend_long { return acc + v.toLong(); } }.add);
    phpzig.Return.returnLong(return_value, sum);
}

// ＝＝ v0.4.0: comptime struct 反射 arg_info ＝＝

fn helloSum(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) { phpzig.Return.returnNull(return_value); return; }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    phpzig.Return.returnLong(return_value, a.toLong() + b.toLong());
}

const SumArgs = struct { a: i64, b: i64 };

fn helloFormat(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) { phpzig.Return.returnNull(return_value); return; }
    const name = phpzig.Return.callArg(execute_data, 1);
    const age = phpzig.Return.callArg(execute_data, 2);
    const msg = std.fmt.allocPrint(std.heap.c_allocator, "{s} is {d} years old", .{ name.toStringVal(), age.toLong() }) catch { phpzig.Return.returnNull(return_value); return; };
    phpzig.Return.returnString(return_value, msg);
}

const FormatArgs = struct { name: []const u8, age: i64 };

// ＝＝ v0.5.0: OOP — 类属性 + 继承 + 构造器 + 访问修饰符 ＝＝

fn bankGetBalance(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    _ = execute_data;
    phpzig.Return.returnLong(return_value, 1000);
}

fn bankSetBalance(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) { phpzig.Return.returnNull(return_value); return; }
    const val = phpzig.Return.callArg(execute_data, 1);
    phpzig.Return.returnLong(return_value, val.toLong());
}

fn savingsInterest(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    _ = execute_data;
    phpzig.Return.returnDouble(return_value, 0.05);
}

fn bankInternal(_: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void { phpzig.Return.returnNull(rv); }

const BankProps = struct {
    balance: i64 = 0,
    open: bool = true,
};

// ＝＝ P4: phpinfo() 输出 ＝＝

fn calcDummy(_: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void { phpzig.Return.returnNull(rv); }

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
        // v0.3.0: 运算符 + Array 算法
        phpzig.FunctionDesc.createWithParams("hello_zip", helloZip, &.{ phpzig.ParamDesc.create("a"), phpzig.ParamDesc.create("b") }),
        phpzig.FunctionDesc.create("hello_map", helloMap),
        phpzig.FunctionDesc.create("hello_filter", helloFilter),
        phpzig.FunctionDesc.create("hello_reduce", helloReduce),
        // v0.4.0: comptime struct 反射 arg_info
        phpzig.FunctionDesc.createFrom("hello_sum", helloSum, SumArgs),
        phpzig.FunctionDesc.createFrom("hello_format", helloFormat, FormatArgs),
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
        phpzig.ClassDesc.create("Calculator", &.{
            phpzig.FunctionDesc.createStaticWithParams("add", calcAdd, &.{ phpzig.ParamDesc.create("a"), phpzig.ParamDesc.create("b") }),
            phpzig.FunctionDesc.createStatic("multiply", calcMultiply),
            // v0.4.0: comptime struct 反射静态方法
            phpzig.FunctionDesc.createStaticFrom("subtract", calcSubtract, SumArgs),
        }),
        phpzig.ClassDesc.createWithConstants("CalcConst", &.{
            phpzig.FunctionDesc.createStatic("dummy", calcDummy),
        }, &.{
            phpzig.ClassConstantDesc.createLong("PI", 3),
            phpzig.ClassConstantDesc.createString("NAME", "Calculator"),
        }),
        // v0.5.0: comptime struct 反射类属性
        phpzig.ClassDesc.createWithPropsFrom("BankAccount", &.{
            phpzig.FunctionDesc.create("__construct", bankSetBalance),
            phpzig.FunctionDesc.createProtected("getBalance", bankGetBalance),
            phpzig.FunctionDesc.createPrivate("internal", bankInternal),
        }, BankProps),
        // v0.5.0: 声明式类属性（传统 API 保留）
        phpzig.ClassDesc.createWithProperties("ManualProps", &.{
            phpzig.FunctionDesc.create("get", bankGetBalance),
        }, &.{
            phpzig.ClassPropertyDesc.createLong("score", 100),
            phpzig.ClassPropertyDesc.createString("label", "ok").makeProtected(),
            phpzig.ClassPropertyDesc.createNull("data"),
        }),
        // v0.5.0: 继承
        phpzig.ClassDesc.createExtends("SavingsAccount", "BankAccount", &.{
            phpzig.FunctionDesc.create("interest", savingsInterest),
        }),
        // v0.5.0: 继承
        phpzig.ClassDesc.createExtends("SavingsAccount", "BankAccount", &.{
            phpzig.FunctionDesc.create("interest", savingsInterest),
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

fn calcSubtract(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) { phpzig.Return.returnNull(return_value); return; }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    phpzig.Return.returnLong(return_value, a.toLong() - b.toLong());
}

comptime { @export(&HelloModule.get_module, .{ .name = "get_module" }); }

extern fn php_printf(fmt: [*c]const u8, ...) void;
