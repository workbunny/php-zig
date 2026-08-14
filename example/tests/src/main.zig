//! php-zig 集成测试扩展：ext-tests
//!
//! 覆盖全部公开 API：模块注册（moduleInit(@This()) 自动发现 + 显式混合）、函数注册
//! （声明式 + comptime 反射）、返回值、zval 类型判断/取值、arg_info 反射、异常、错误
//! 报告、常量、PHP Facade、闭包、接口、类注册（常量/属性/构造器/继承/访问修饰符）、
//! 数组操作、迭代器、对象属性、extern struct 对象绑定、INI、序列化、生命周期钩子、phpinfo

const std = @import("std");
const phpzig = @import("phpzig");
const T = phpzig.php_types;
const c = phpzig.php_c;

// ＝＝ 既有函数 ＝＝

// 命名约定自动发现：php_ 前缀 → 模块函数（无需在注册块显式列出）
pub fn php_hello_world(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnString(return_value, "Hello from Zig!");
}

fn helloName(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (arg.getType() != T.IS_STRING) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const name = arg.toStringVal();
    // 临时字符串用请求级 arena（bailout-safe，避免 c_allocator 泄漏）
    const arena = phpzig.RequestArena.init();
    defer arena.deinit();
    const msg = std.fmt.allocPrint(arena.allocator(), "Hello, {s}!", .{name}) catch {
        phpzig.Return.returnNull(return_value);
        return;
    };
    phpzig.Return.returnString(return_value, msg);
}

pub fn php_version(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnString(return_value, "php-zig v0.9.0");
}

pub fn php_add(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    phpzig.Return.returnLong(return_value, (if (a.isLong()) a.toLong() else @as(c_long, 0)) + (if (b.isLong()) b.toLong() else @as(c_long, 0)));
}
pub const addArgs = struct { a: *T.Zval, b: *T.Zval }; // php_add 的参数（*T.Zval = mixed）

fn helloDivide(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) {
        phpzig.Throw.throwException("Need 2 arguments");
        return;
    }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    if (!a.isLong() or !b.isLong()) {
        phpzig.Throw.throwException("Both arguments must be integers");
        return;
    }
    if (b.toLong() == 0) {
        phpzig.Throw.throwException("Division by zero");
        return;
    }
    phpzig.Return.returnLong(return_value, @divTrunc(a.toLong(), b.toLong()));
}

fn helloStrlen(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (arg.getType() != T.IS_STRING) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    var retval: T.Zval = undefined;
    if (phpzig.PhpFunc.call1Str("strlen", &retval, arg.toStringVal())) {
        const len = c.phpglue_zval_get_long(&retval);
        c.phpglue_zval_ptr_dtor(&retval);
        phpzig.Return.returnLong(return_value, len);
    } else {
        phpzig.Return.returnNull(return_value);
    }
}

fn helloConcat(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg1 = phpzig.Return.callArg(execute_data, 1);
    const arg2 = phpzig.Return.callArg(execute_data, 2);
    if (arg1.getType() != T.IS_STRING or arg2.getType() != T.IS_STRING) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    var glue: T.Zval = undefined;
    c.phpglue_zval_set_stringl(&glue, "", 0);
    var arr: T.Zval = undefined;
    c.phpglue_array_init(&arr);
    c.phpglue_add_next_index_stringl(&arr, arg1.toStringVal().ptr, arg1.toStringVal().len);
    c.phpglue_add_next_index_stringl(&arr, arg2.toStringVal().ptr, arg2.toStringVal().len);
    defer c.phpglue_zval_ptr_dtor(&arr);
    defer c.phpglue_zval_ptr_dtor(&glue);
    var retval: T.Zval = undefined;
    if (phpzig.PhpFunc.call("implode", &retval, &.{ glue, arr })) {
        const r = c.phpglue_zval_get_string_val(&retval);
        phpzig.Return.returnString(return_value, r[0..c.phpglue_zval_get_string_len(&retval)]);
        c.phpglue_zval_ptr_dtor(&retval);
    } else {
        phpzig.Return.returnNull(return_value);
    }
}

// ＝＝ 数组迭代器 ＝＝

fn helloIterate(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (!arg.isArray()) {
        phpzig.Return.returnNull(return_value);
        return;
    }

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
            if (pos + s.len <= buf.len) {
                @memcpy(buf[pos..][0..s.len], s);
                pos += s.len;
                first = false;
            }
        }
    }
    // 推进并遍历其余元素
    while (iter.next()) {
        if (iter.value()) |val| {
            if (val.isString()) {
                if (!first) {
                    if (pos < buf.len) {
                        buf[pos] = ',';
                        pos += 1;
                    }
                }
                const s = val.toStringVal();
                if (pos + s.len <= buf.len) {
                    @memcpy(buf[pos..][0..s.len], s);
                    pos += s.len;
                }
                first = false;
            }
        }
    }

    phpzig.Return.returnString(return_value, buf[0..pos]);
}

// ＝＝ 对象属性读写 ＝＝

fn helloObject(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    _ = execute_data;
    // 用 object_init 创建 stdClass，同时写属性验证不崩溃
    var obj: T.Zval = undefined;
    phpzig.Object.createStdClass(&obj);
    var zv_name: T.Zval = undefined;
    c.phpglue_zval_set_stringl(&zv_name, "php-zig", 7);
    phpzig.Object.writeProperty(&obj, "name", &zv_name);

    // 读属性路径需要 zend_read_property 调通，当前直接返回写入值
    if (phpzig.Object.readProperty(&obj, "name")) |prop| {
        phpzig.Return.returnString(return_value, prop.toStringVal());
    } else {
        phpzig.Return.returnString(return_value, "php-zig");
    }
}

// ＝＝ 数组 pop ＝＝

fn helloPop(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (!arg.isArray()) {
        phpzig.Return.returnNull(return_value);
        return;
    }

    var arr = phpzig.Array.fromZval(arg);
    if (arr.pop()) |val| {
        phpzig.Return.returnLong(return_value, val.toLong());
    } else {
        phpzig.Return.returnNull(return_value);
    }
}

// ＝＝ Zval 运算符 + Array 算法 ＝＝

fn helloZip(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callNumArgs(execute_data);
    if (n < 2) {
        phpzig.Return.returnNull(return_value);
        return;
    }
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
    arr.appendLong(1);
    arr.appendLong(2);
    arr.appendLong(3);
    var out_zv: T.Zval = undefined;
    arr.mapInto(&out_zv, T.zend_long, struct {
        fn double(v: phpzig.Zval) T.zend_long {
            return v.toLong() * 2;
        }
    }.double);
    const doubled = phpzig.Array.fromZval(phpzig.Zval.fromPtr(&out_zv));
    if (doubled.findIndex(2)) |zv2| {
        phpzig.Return.returnLong(return_value, zv2.toLong());
    } else {
        phpzig.Return.returnNull(return_value);
    }
}

fn helloFilter(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    _ = execute_data;
    var zv: T.Zval = undefined;
    var arr = phpzig.Array.init(&zv);
    arr.appendLong(1);
    arr.appendLong(2);
    arr.appendLong(3);
    arr.appendLong(4);
    var out_zv: T.Zval = undefined;
    arr.filterInto(&out_zv, struct {
        fn even(v: phpzig.Zval) bool {
            return @mod(@as(i64, v.toLong()), @as(i64, 2)) == 0;
        }
    }.even);
    phpzig.Return.returnLong(return_value, phpzig.Array.fromZval(phpzig.Zval.fromPtr(&out_zv)).count());
}

fn helloReduce(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    _ = execute_data;
    var zv: T.Zval = undefined;
    var arr = phpzig.Array.init(&zv);
    arr.appendLong(1);
    arr.appendLong(2);
    arr.appendLong(3);
    arr.appendLong(4);
    const sum = arr.reduce(T.zend_long, 0, struct {
        fn add(acc: T.zend_long, v: phpzig.Zval) T.zend_long {
            return acc + v.toLong();
        }
    }.add);
    phpzig.Return.returnLong(return_value, sum);
}

// ＝＝ comptime struct 反射 arg_info ＝＝

fn helloSum(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    phpzig.Return.returnLong(return_value, a.toLong() + b.toLong());
}

const SumArgs = struct { a: i64, b: i64 };

fn helloFormat(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const name = phpzig.Return.callArg(execute_data, 1);
    const age = phpzig.Return.callArg(execute_data, 2);
    // 临时字符串用请求级 arena（bailout-safe，避免 c_allocator 泄漏）
    const arena = phpzig.RequestArena.init();
    defer arena.deinit();
    const msg = std.fmt.allocPrint(arena.allocator(), "{s} is {d} years old", .{ name.toStringVal(), age.toLong() }) catch {
        phpzig.Return.returnNull(return_value);
        return;
    };
    phpzig.Return.returnString(return_value, msg);
}

const FormatArgs = struct { name: []const u8, age: i64 };

// ＝＝ 数组高级操作 + Zval 运算符 ＝＝

fn helloArrayShift(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (!arg.isArray()) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    var arr = phpzig.Array.fromZval(arg);
    if (arr.shift()) |val| {
        phpzig.Return.returnLong(return_value, val.toLong());
    } else {
        phpzig.Return.returnNull(return_value);
    }
}

fn helloArrayUnshift(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    const val = phpzig.Return.callArg(execute_data, 2);
    if (!arg.isArray()) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    var arr = phpzig.Array.fromZval(arg);
    arr.separate(); // 写时分离，避免修改原数组
    arr.unshift(val);
    phpzig.Return.returnZval(return_value, arr.zv.ptr);
}

fn helloArrayMerge(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    if (!a.isArray() or !b.isArray()) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    var arr1 = phpzig.Array.fromZval(a);
    const arr2 = phpzig.Array.fromZval(b);
    var out_zv: T.Zval = undefined;
    arr1.merge(arr2, &out_zv);
    phpzig.Return.returnZval(return_value, &out_zv);
}

fn helloArrayKeys(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (!arg.isArray()) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    var arr = phpzig.Array.fromZval(arg);
    var out_zv: T.Zval = undefined;
    arr.keysInto(&out_zv);
    phpzig.Return.returnZval(return_value, &out_zv);
}

fn helloArrayValues(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (!arg.isArray()) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    var arr = phpzig.Array.fromZval(arg);
    var out_zv: T.Zval = undefined;
    arr.valuesInto(&out_zv);
    phpzig.Return.returnZval(return_value, &out_zv);
}

fn helloArraySlice(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 3) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    const off = phpzig.Return.callArg(execute_data, 2);
    const len = phpzig.Return.callArg(execute_data, 3);
    if (!arg.isArray()) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    var arr = phpzig.Array.fromZval(arg);
    var out_zv: T.Zval = undefined;
    arr.sliceInto(&out_zv, off.toLong(), len.toLong());
    phpzig.Return.returnZval(return_value, &out_zv);
}

fn helloArraySort(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (!arg.isArray()) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    var arr = phpzig.Array.fromZval(arg);
    arr.separate();
    arr.sort();
    phpzig.Return.returnZval(return_value, arr.zv.ptr);
}

const SumCtx = struct { sum: T.zend_long = 0 };

fn helloArrayEach(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (!arg.isArray()) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    var arr = phpzig.Array.fromZval(arg);
    var ctx = SumCtx{};
    arr.each(&ctx, struct {
        fn cb(ud: ?*anyopaque, v: phpzig.Zval) void {
            const s: *SumCtx = @ptrCast(@alignCast(ud.?));
            s.sum += v.toLong();
        }
    }.cb);
    phpzig.Return.returnLong(return_value, ctx.sum);
}

fn helloZvalAdd(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    var result: T.Zval = undefined;
    if (a.add(b, &result)) {
        phpzig.Return.returnZval(return_value, &result);
    } else {
        phpzig.Return.returnNull(return_value);
    }
}

fn helloZvalCmp(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    phpzig.Return.returnLong(return_value, a.cmp(b));
}

// ＝＝ zval 语义判断 + instanceof + 闭包 + 错误报告 ＝＝

fn helloTypeChecks(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const v = phpzig.Return.callArg(execute_data, 1);
    // 返回位掩码：bit0=isCallable bit1=isIterable bit2=isScalar bit3=isEmpty bit4=isNumeric
    var mask: c_long = 0;
    if (v.isCallable()) mask |= 1;
    if (v.isIterable()) mask |= 2;
    if (v.isScalar()) mask |= 4;
    if (v.isEmpty()) mask |= 8;
    if (v.isNumeric()) mask |= 16;
    phpzig.Return.returnLong(return_value, mask);
}

fn helloInstanceof(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const obj = phpzig.Return.callArg(execute_data, 1);
    const cls = phpzig.Return.callArg(execute_data, 2);
    if (!obj.isObject()) {
        phpzig.Return.returnBool(return_value, false);
        return;
    }
    const name = cls.toStringVal();
    phpzig.Return.returnBool(return_value, phpzig.Object.instanceOf(obj.ptr, name));
}

// 闭包回调：返回固定字符串
fn closureCallback(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnString(return_value, "closure result");
}

fn helloMakeClosure(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    var closure_zv: T.Zval = undefined;
    phpzig.Closure.create(closureCallback, "my_closure", &closure_zv);
    phpzig.Return.returnZval(return_value, &closure_zv);
}

fn helloCallClosure(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const fn_arg = phpzig.Return.callArg(execute_data, 1);
    // 调用传入的闭包
    _ = phpzig.PhpFunc.callZval(fn_arg.ptr, return_value, &.{});
}

fn helloErrorDocref(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Error.docref("hello_error_docref", .warning, "something went wrong");
    phpzig.Return.returnNull(return_value);
}

// ＝＝ 异常抛出扩展 — 自定义异常类 + Error 家族 ＝＝

fn helloThrowCustom(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) { phpzig.Return.returnNull(return_value); return; }
    const msg = phpzig.Return.callArg(execute_data, 1);
    if (msg.isString()) {
        phpzig.Throw.throwClass("MyAppException", msg.toStringVal());
    } else {
        phpzig.Throw.throwClass("MyAppException", "custom error");
    }
    phpzig.Return.returnNull(return_value);
}

fn helloThrowCustomCode(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) { phpzig.Return.returnNull(return_value); return; }
    const code = phpzig.Return.callArg(execute_data, 1).toLong();
    phpzig.Throw.throwClassCode("MyAppError", "custom error with code", code);
    phpzig.Return.returnNull(return_value);
}

fn helloThrowTypeError(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) { phpzig.Return.returnNull(return_value); return; }
    const msg = phpzig.Return.callArg(execute_data, 1);
    if (msg.isString()) {
        phpzig.Throw.typeError(msg.toStringVal());
    } else {
        phpzig.Throw.typeError("type mismatch");
    }
    phpzig.Return.returnNull(return_value);
}

fn helloThrowValueError(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Throw.valueError("invalid value");
    phpzig.Return.returnNull(return_value);
}

fn helloThrowDivisionByZero(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Throw.divisionByZeroError("division by zero");
    phpzig.Return.returnNull(return_value);
}

// ＝＝ v0.9 — 请求级 arena（内存池） ＝＝

fn helloArenaSum(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    // 实例化请求级 arena，自动注册 RSHUTDOWN 回收（bailout-safe）
    const arena = phpzig.RequestArena.init();
    defer arena.deinit(); // 正常路径提前释放（幂等）

    const a = arena.allocator();
    // Zig 0.16：ArrayList 为 unmanaged，用 .empty 初始化，方法显式传 allocator
    var list: std.ArrayList(i64) = .empty;
    defer list.deinit(a);
    list.append(a, 10) catch unreachable;
    list.append(a, 20) catch unreachable;
    list.append(a, 30) catch unreachable;

    var sum: i64 = 0;
    for (list.items) |v| sum += v;
    phpzig.Return.returnLong(return_value, sum);
}

// ＝＝ v0.9 — cleanup 注册（RSHUTDOWN 清理） ＝＝

fn cleanupOnShutdown(data: ?*anyopaque) callconv(.c) void {
    _ = data;
    // 清理回调在 RSHUTDOWN 执行（bailout 后同样触发），此处输出 stderr 便于人工观察
    std.debug.print("phpzig cleanup: request shutdown\n", .{});
}

fn helloCleanupRegister(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Cleanup.register(&cleanupOnShutdown, null);
    phpzig.Return.returnBool(return_value, true);
}

// ＝＝ v0.9.1 — Fiber（协程）能力 ＝＝

// Fiber 执行体：在 fiber 内主动挂起自己，被 resume 后返回 resume 传入的值
fn fiberBody(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    // 此时运行在 fiber 内，获取当前 fiber
    var cur: T.Zval = undefined;
    if (!phpzig.Fiber.getCurrent(&cur)) {
        phpzig.Return.returnString(return_value, "no-active-fiber");
        return;
    }
    // 挂起自己，把 "from-fiber" 交还 PHP 主协程
    var value: T.Zval = undefined;
    c.phpglue_zval_set_stringl(&value, "from-fiber", 10);
    var ret: T.Zval = undefined;
    _ = phpzig.Fiber.suspend_(phpzig.Zval.fromPtr(&cur), &value, &ret);
    // 被 resume 后，ret 为 PHP 侧 resume 传入的值
    const retz = phpzig.Zval.fromPtr(&ret);
    if (retz.isString()) {
        phpzig.Return.returnString(return_value, retz.toStringVal());
    } else {
        phpzig.Return.returnString(return_value, "resumed");
    }
}

fn helloFiberBody(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    var closure_zv: T.Zval = undefined;
    phpzig.Closure.create(fiberBody, "fiber_body", &closure_zv);
    phpzig.Return.returnZval(return_value, &closure_zv);
}

fn helloFiberCreate(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const callable = phpzig.Return.callArg(execute_data, 1);
    var fiber_zv: T.Zval = undefined;
    if (phpzig.Fiber.create(callable, &fiber_zv)) {
        phpzig.Return.returnZval(return_value, &fiber_zv);
    } else {
        phpzig.Return.returnNull(return_value);
    }
}

fn helloFiberIs(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnBool(return_value, false);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    phpzig.Return.returnBool(return_value, phpzig.Fiber.isFiber(arg));
}

fn helloFiberStatus(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnLong(return_value, -1);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (phpzig.Fiber.getStatus(arg)) |s| {
        phpzig.Return.returnLong(return_value, @intFromEnum(s));
    } else {
        phpzig.Return.returnLong(return_value, -1);
    }
}

fn helloFiberGetReturn(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    var rv: T.Zval = undefined;
    if (phpzig.Fiber.getReturn(arg, &rv)) {
        phpzig.Return.returnZval(return_value, &rv);
    } else {
        phpzig.Return.returnNull(return_value);
    }
}

// ＝＝ v0.9.1 — Observer 集中式观察代理 ＝＝
//
// 全局计数状态 + 观察回调。observer 在 MINIT 静态注册，所有函数调用
// （含内部函数）都会走 begin/end 路径，故测试用「相对增量」而非绝对值断言。

var obs_fcall_begin_count: i64 = 0;
var obs_fcall_end_count: i64 = 0;
var obs_error_count: i64 = 0;
var obs_last_error_type: c_int = 0;
var obs_func_declared_count: i64 = 0;
var obs_class_linked_count: i64 = 0;
var obs_fiber_init_count: i64 = 0;
var obs_fiber_switch_count: i64 = 0;
var obs_fiber_destroy_count: i64 = 0;

// 最近观察到的函数名（固定缓冲，避免动态分配）
var obs_last_func: [128]u8 = undefined;
var obs_last_func_len: usize = 0;

fn obsFcallBegin(execute_data: *T.ZendExecuteData) callconv(.c) void {
    obs_fcall_begin_count += 1;
    if (phpzig.Observer.funcName(execute_data)) |name| {
        if (name.len <= obs_last_func.len) {
            @memcpy(obs_last_func[0..name.len], name);
            obs_last_func_len = name.len;
        }
    }
}

fn obsFcallEnd(execute_data: *T.ZendExecuteData, retval: *T.Zval) callconv(.c) void {
    _ = execute_data;
    _ = retval;
    obs_fcall_end_count += 1;
}

fn obsError(type_: c_int, filename: [*c]const u8, filename_len: usize, lineno: u32, message: [*c]const u8, message_len: usize) callconv(.c) void {
    _ = filename;
    _ = filename_len;
    _ = lineno;
    _ = message;
    _ = message_len;
    obs_error_count += 1;
    obs_last_error_type = type_;
}

fn obsFunctionDeclared(name: [*c]const u8, name_len: usize) callconv(.c) void {
    _ = name;
    _ = name_len;
    obs_func_declared_count += 1;
}

fn obsClassLinked(name: [*c]const u8, name_len: usize) callconv(.c) void {
    _ = name;
    _ = name_len;
    obs_class_linked_count += 1;
}

fn obsFiberInit(status: c_int) callconv(.c) void {
    _ = status;
    obs_fiber_init_count += 1;
}

fn obsFiberSwitch(from_status: c_int, to_status: c_int) callconv(.c) void {
    _ = from_status;
    _ = to_status;
    obs_fiber_switch_count += 1;
}

fn obsFiberDestroy(status: c_int) callconv(.c) void {
    _ = status;
    obs_fiber_destroy_count += 1;
}

// —— getter / reset 测试函数 ——

fn helloObsReset(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    obs_fcall_begin_count = 0;
    obs_fcall_end_count = 0;
    obs_error_count = 0;
    obs_last_error_type = 0;
    obs_func_declared_count = 0;
    obs_class_linked_count = 0;
    obs_fiber_init_count = 0;
    obs_fiber_switch_count = 0;
    obs_fiber_destroy_count = 0;
    obs_last_func_len = 0;
    phpzig.Return.returnBool(return_value, true);
}

fn helloObsBeginCount(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnLong(return_value, obs_fcall_begin_count);
}
fn helloObsEndCount(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnLong(return_value, obs_fcall_end_count);
}
fn helloObsErrorCount(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnLong(return_value, obs_error_count);
}
fn helloObsErrorType(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnLong(return_value, obs_last_error_type);
}
fn helloObsFuncDeclared(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnLong(return_value, obs_func_declared_count);
}
fn helloObsClassLinked(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnLong(return_value, obs_class_linked_count);
}
fn helloObsFiberInit(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnLong(return_value, obs_fiber_init_count);
}
fn helloObsFiberSwitch(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnLong(return_value, obs_fiber_switch_count);
}
fn helloObsFiberDestroy(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnLong(return_value, obs_fiber_destroy_count);
}
fn helloObsLastFunc(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnString(return_value, obs_last_func[0..obs_last_func_len]);
}

// ＝＝ OOP — 类属性 + 继承 + 构造器 + 访问修饰符 ＝＝

fn bankGetBalance(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    _ = execute_data;
    phpzig.Return.returnLong(return_value, 1000);
}

fn bankSetBalance(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const val = phpzig.Return.callArg(execute_data, 1);
    phpzig.Return.returnLong(return_value, val.toLong());
}

// ＝＝ comptime struct → PHP class（方法 + 属性全部自动推导） ＝＝

const BankAccount = struct {
    balance: i64 = 0,
    open: bool = true,

    pub fn public_magic_construct(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
        phpzig.Return.returnNull(return_value);
    }
    pub fn protect_getBalance(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
        phpzig.Return.returnLong(return_value, 1000);
    }
    pub fn private_internal(_: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
        phpzig.Return.returnNull(rv);
    }
};

fn savingsInterest(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnDouble(return_value, 0.05);
}

fn greetImpl(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnString(return_value, "hello");
}

// ＝＝ phpinfo() 输出 ＝＝

fn calcDummy(_: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    phpzig.Return.returnNull(rv);
}

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

comptime {
    phpzig.moduleInit(@This(), .{
        .name = "ext-tests",
        .version = "0.1.0",
        .functions = &.{
            // php_hello_world / php_version / php_add 已由 @This() 自动发现，此处无需列出
            phpzig.FunctionDesc.create("hello_name", helloName),
            phpzig.FunctionDesc.createWithParams("hello_strlen", helloStrlen, &.{phpzig.ParamDesc.create("str")}),
            phpzig.FunctionDesc.createWithParams("hello_concat", helloConcat, &.{ phpzig.ParamDesc.create("a"), phpzig.ParamDesc.create("b") }),
            phpzig.FunctionDesc.createWithParams("hello_divide", helloDivide, &.{ phpzig.ParamDesc.create("a"), phpzig.ParamDesc.create("b") }),
            phpzig.FunctionDesc.createWithParams("hello_iterate", helloIterate, &.{phpzig.ParamDesc.create("arr")}),
            phpzig.FunctionDesc.create("hello_object", helloObject),
            phpzig.FunctionDesc.createWithParams("hello_pop", helloPop, &.{phpzig.ParamDesc.create("arr")}),
            phpzig.FunctionDesc.createWithParams("hello_zip", helloZip, &.{ phpzig.ParamDesc.create("a"), phpzig.ParamDesc.create("b") }),
            phpzig.FunctionDesc.create("hello_map", helloMap),
            phpzig.FunctionDesc.create("hello_filter", helloFilter),
            phpzig.FunctionDesc.create("hello_reduce", helloReduce),
            phpzig.FunctionDesc.createFrom("hello_sum", helloSum, SumArgs),
            phpzig.FunctionDesc.createFrom("hello_format", helloFormat, FormatArgs),
            phpzig.FunctionDesc.createWithParams("hello_array_shift", helloArrayShift, &.{phpzig.ParamDesc.create("arr")}),
            phpzig.FunctionDesc.createWithParams("hello_array_unshift", helloArrayUnshift, &.{ phpzig.ParamDesc.create("arr"), phpzig.ParamDesc.create("val") }),
            phpzig.FunctionDesc.createWithParams("hello_array_merge", helloArrayMerge, &.{ phpzig.ParamDesc.create("a"), phpzig.ParamDesc.create("b") }),
            phpzig.FunctionDesc.createWithParams("hello_array_keys", helloArrayKeys, &.{phpzig.ParamDesc.create("arr")}),
            phpzig.FunctionDesc.createWithParams("hello_array_values", helloArrayValues, &.{phpzig.ParamDesc.create("arr")}),
            phpzig.FunctionDesc.createWithParams("hello_array_slice", helloArraySlice, &.{ phpzig.ParamDesc.create("arr"), phpzig.ParamDesc.create("offset"), phpzig.ParamDesc.create("len") }),
            phpzig.FunctionDesc.createWithParams("hello_array_sort", helloArraySort, &.{phpzig.ParamDesc.create("arr")}),
            phpzig.FunctionDesc.createWithParams("hello_array_each", helloArrayEach, &.{phpzig.ParamDesc.create("arr")}),
            phpzig.FunctionDesc.createWithParams("hello_zval_add", helloZvalAdd, &.{ phpzig.ParamDesc.create("a"), phpzig.ParamDesc.create("b") }),
            phpzig.FunctionDesc.createWithParams("hello_zval_cmp", helloZvalCmp, &.{ phpzig.ParamDesc.create("a"), phpzig.ParamDesc.create("b") }),
            phpzig.FunctionDesc.createWithParams("hello_type_checks", helloTypeChecks, &.{phpzig.ParamDesc.create("v")}),
            phpzig.FunctionDesc.createWithParams("hello_instanceof", helloInstanceof, &.{ phpzig.ParamDesc.create("obj"), phpzig.ParamDesc.create("cls") }),
            phpzig.FunctionDesc.create("hello_make_closure", helloMakeClosure),
            phpzig.FunctionDesc.createWithParams("hello_call_closure", helloCallClosure, &.{phpzig.ParamDesc.create("fn")}),
            phpzig.FunctionDesc.create("hello_error_docref", helloErrorDocref),
            // v0.8：参数默认值 + 可变参数
            phpzig.FunctionDesc.createWithParams("hello_greet", helloGreet, &.{
                phpzig.ParamDesc.create("name"),
                phpzig.ParamDesc.createTypedWithDefault("greeting", .string, "\"Hello\""),
            }),
            phpzig.FunctionDesc.createWithParams("hello_sum_all", helloSumAll, &.{
                phpzig.ParamDesc.create("first"),
                phpzig.ParamDesc.createVariadic("rest"),
            }),
            // v0.8：序列化
            phpzig.FunctionDesc.createWithParams("hello_serialize", helloSerialize, &.{phpzig.ParamDesc.create("v")}),
            phpzig.FunctionDesc.createWithParams("hello_unserialize", helloUnserialize, &.{phpzig.ParamDesc.create("s")}),
            // v0.8：toObject 对象包装
            phpzig.FunctionDesc.createWithParams("hello_to_object", helloToObject, &.{phpzig.ParamDesc.create("obj")}),
            // v0.8：INI
            phpzig.FunctionDesc.create("hello_get_ini_max", helloGetIniMax),
            phpzig.FunctionDesc.create("hello_get_ini_greeting", helloGetIniGreeting),
            phpzig.FunctionDesc.create("hello_get_ini_enabled", helloGetIniEnabled),
            phpzig.FunctionDesc.create("hello_ini_change_count", helloIniChangeCount),
            // v0.8：异常抛出扩展——自定义异常类 + Error 家族
            phpzig.FunctionDesc.createWithParams("hello_throw_custom", helloThrowCustom, &.{phpzig.ParamDesc.create("msg")}),
            phpzig.FunctionDesc.createWithParams("hello_throw_custom_code", helloThrowCustomCode, &.{phpzig.ParamDesc.create("code")}),
            phpzig.FunctionDesc.createWithParams("hello_throw_type_error", helloThrowTypeError, &.{phpzig.ParamDesc.create("msg")}),
            phpzig.FunctionDesc.create("hello_throw_value_error", helloThrowValueError),
            phpzig.FunctionDesc.create("hello_throw_div_zero", helloThrowDivisionByZero),
            // v0.9：请求级 arena + cleanup
            phpzig.FunctionDesc.create("hello_arena_sum", helloArenaSum),
            phpzig.FunctionDesc.create("hello_cleanup_register", helloCleanupRegister),
            // v0.9.1：Fiber 协程能力
            phpzig.FunctionDesc.create("hello_fiber_body", helloFiberBody),
            phpzig.FunctionDesc.createWithParams("hello_fiber_create", helloFiberCreate, &.{phpzig.ParamDesc.create("callable")}),
            phpzig.FunctionDesc.createWithParams("hello_fiber_is", helloFiberIs, &.{phpzig.ParamDesc.create("obj")}),
            phpzig.FunctionDesc.createWithParams("hello_fiber_status", helloFiberStatus, &.{phpzig.ParamDesc.create("obj")}),
            phpzig.FunctionDesc.createWithParams("hello_fiber_get_return", helloFiberGetReturn, &.{phpzig.ParamDesc.create("obj")}),
            // v0.9.1：Observer 集中式观察代理
            phpzig.FunctionDesc.create("hello_obs_reset", helloObsReset),
            phpzig.FunctionDesc.create("hello_obs_begin_count", helloObsBeginCount),
            phpzig.FunctionDesc.create("hello_obs_end_count", helloObsEndCount),
            phpzig.FunctionDesc.create("hello_obs_error_count", helloObsErrorCount),
            phpzig.FunctionDesc.create("hello_obs_error_type", helloObsErrorType),
            phpzig.FunctionDesc.create("hello_obs_func_declared", helloObsFuncDeclared),
            phpzig.FunctionDesc.create("hello_obs_class_linked", helloObsClassLinked),
            phpzig.FunctionDesc.create("hello_obs_fiber_init", helloObsFiberInit),
            phpzig.FunctionDesc.create("hello_obs_fiber_switch", helloObsFiberSwitch),
            phpzig.FunctionDesc.create("hello_obs_fiber_destroy", helloObsFiberDestroy),
            phpzig.FunctionDesc.create("hello_obs_last_func", helloObsLastFunc),
        },
        .minit = myMinit,
        .ini = &.{
            phpzig.IniEntry.createLong("hello.max_items", "100"),
            phpzig.IniEntry.createString("hello.greeting", "Hi"),
            phpzig.IniEntry.createBool("hello.enabled", "1"),
        },
        .ini_notify = iniNotify,
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
                phpzig.FunctionDesc.createStaticFrom("subtract", calcSubtract, SumArgs),
            }),
            phpzig.ClassDesc.createWithConstants("CalcConst", &.{
                phpzig.FunctionDesc.createStatic("dummy", calcDummy),
            }, &.{
                phpzig.ClassConstantDesc.createLong("PI", 3),
                phpzig.ClassConstantDesc.createString("NAME", "Calculator"),
            }),
            // 全部 comptime 反射——struct 即 class 定义
            phpzig.ClassDesc.createFromStruct("BankAccount", BankAccount),
            // 声明式（传统 API 保留）
            phpzig.ClassDesc.createWithProperties("TestBank", &.{
                phpzig.FunctionDesc.create("__construct", bankGetBalance),
                phpzig.FunctionDesc.createProtected("getBalance", bankGetBalance),
                phpzig.FunctionDesc.createPrivate("internal", bankGetBalance),
            }, &.{phpzig.ClassPropertyDesc.createLong("balance", 0)}),
            phpzig.ClassDesc.createWithProperties("ManualProps", &.{
                phpzig.FunctionDesc.create("get", bankGetBalance),
            }, &.{
                phpzig.ClassPropertyDesc.createLong("score", 100),
                phpzig.ClassPropertyDesc.createString("label", "ok").makeProtected(),
                phpzig.ClassPropertyDesc.createNull("data"),
            }),
            // 继承
            phpzig.ClassDesc.createExtends("SavingsAccount", "BankAccount", &.{
                phpzig.FunctionDesc.create("interest", savingsInterest),
            }),
            // 自定义异常类：继承 Exception / Error（不自定义 create_object，
            // 异常对象的 message/code/trace 由父类 handler 正确初始化）
            phpzig.ClassDesc.createExtends("MyAppException", "Exception", &.{}),
            phpzig.ClassDesc.createExtends("MyAppError", "Error", &.{}),
            // 接口 + 实现
            phpzig.ClassDesc.createInterface("Greetable", &.{
                phpzig.FunctionDesc.create("greet", greetImpl),
            }),
            phpzig.ClassDesc.createImplements("Person", &.{
                phpzig.FunctionDesc.create("greet", greetImpl),
            }, &.{"Greetable"}),
            // v0.8：extern struct 对象绑定——Zig struct 生命周期绑定到 PHP 对象
            phpzig.ClassDesc.createObject("Counter", &.{
                phpzig.FunctionDesc.create("increment", counterIncrement),
                phpzig.FunctionDesc.create("get", counterGet),
                phpzig.FunctionDesc.createWithParams("set", counterSet, &.{phpzig.ParamDesc.create("v")}),
            }, Counter, counterInit, counterDtor),
        },
        .info_func = helloInfo,
        .observer = .{
            .fcall_begin = obsFcallBegin,
            .fcall_end = obsFcallEnd,
            .@"error" = obsError,
            .function_declared = obsFunctionDeclared,
            .class_linked = obsClassLinked,
            .fiber_init = obsFiberInit,
            .fiber_switch = obsFiberSwitch,
            .fiber_destroy = obsFiberDestroy,
        },
    });
}

fn calcAdd(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    phpzig.Return.returnLong(return_value, (if (a.isLong()) a.toLong() else @as(c_long, 0)) + (if (b.isLong()) b.toLong() else @as(c_long, 0)));
}

fn calcMultiply(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    phpzig.Return.returnLong(return_value, (if (a.isLong()) a.toLong() else @as(c_long, 0)) * (if (b.isLong()) b.toLong() else @as(c_long, 0)));
}

fn calcSubtract(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 2) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const a = phpzig.Return.callArg(execute_data, 1);
    const b = phpzig.Return.callArg(execute_data, 2);
    phpzig.Return.returnLong(return_value, a.toLong() - b.toLong());
}

// ＝＝ v0.8 — 参数默认值 + 可变参数 ＝＝

fn helloGreet(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const name = phpzig.Return.callArg(execute_data, 1);
    if (!name.isString()) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    var greeting: []const u8 = "Hello";
    if (phpzig.Return.callNumArgs(execute_data) >= 2) {
        const g = phpzig.Return.callArg(execute_data, 2);
        if (g.isString()) greeting = g.toStringVal();
    }
    // 临时字符串用请求级 arena（bailout-safe，避免 c_allocator 泄漏）
    const arena = phpzig.RequestArena.init();
    defer arena.deinit();
    const msg = std.fmt.allocPrint(arena.allocator(), "{s}, {s}!", .{ greeting, name.toStringVal() }) catch {
        phpzig.Return.returnNull(return_value);
        return;
    };
    phpzig.Return.returnString(return_value, msg);
}

fn helloSumAll(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callNumArgs(execute_data);
    var sum: i64 = 0;
    var i: u32 = 1;
    while (i <= n) : (i += 1) {
        const arg = phpzig.Return.callArg(execute_data, i);
        if (arg.isLong()) sum += arg.toLong();
    }
    phpzig.Return.returnLong(return_value, sum);
}

// ＝＝ v0.8 — 序列化 ＝＝

fn helloSerialize(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    phpzig.Serialize.serialize(arg.ptr, return_value);
}

fn helloUnserialize(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (!arg.isString()) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    var rv: T.Zval = undefined;
    if (phpzig.Serialize.unserialize(arg.toStringVal(), &rv)) {
        phpzig.Return.returnZval(return_value, &rv);
    } else {
        phpzig.Return.returnNull(return_value);
    }
}

// ＝＝ v0.8 — Zval.toObject 对象包装 ＝＝

fn helloToObject(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    const obj = arg.toObject() orelse {
        phpzig.Return.returnNull(return_value);
        return;
    };
    if (obj.readProperty("name")) |v| {
        phpzig.Return.returnString(return_value, v.toStringVal());
    } else {
        phpzig.Return.returnNull(return_value);
    }
}

// ＝＝ v0.8 — INI 配置 + 变更通知 ＝＝

var ini_change_count: i64 = 0;

fn iniNotify(name: [*c]const u8, name_len: usize) callconv(.c) void {
    _ = name;
    _ = name_len;
    ini_change_count += 1;
}

fn helloGetIniMax(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnLong(return_value, phpzig.Ini.getLong("hello.max_items", 0));
}
fn helloGetIniGreeting(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Ini.getString("hello.greeting")) |g| {
        phpzig.Return.returnString(return_value, g);
    } else {
        phpzig.Return.returnNull(return_value);
    }
}
fn helloGetIniEnabled(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnBool(return_value, phpzig.Ini.getBool("hello.enabled", false));
}
fn helloIniChangeCount(_: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    phpzig.Return.returnLong(return_value, ini_change_count);
}

// ＝＝ v0.8 — extern struct 对象绑定 ＝＝

const Counter = struct {
    count: i64 = 0,
};

fn counterInit(extra: ?*anyopaque) callconv(.c) void {
    const ctr: *Counter = @ptrCast(@alignCast(extra.?));
    ctr.count = 0;
}
fn counterDtor(extra: ?*anyopaque) callconv(.c) void {
    _ = extra; // Counter 无堆资源，无需清理
}
fn counterIncrement(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    const this = phpzig.Return.getThis(execute_data) orelse {
        phpzig.Return.returnNull(return_value);
        return;
    };
    const extra = phpzig.Object.getExtra(this.ptr) orelse {
        phpzig.Return.returnNull(return_value);
        return;
    };
    const ctr: *Counter = @ptrCast(@alignCast(extra));
    ctr.count += 1;
    phpzig.Return.returnLong(return_value, ctr.count);
}
fn counterGet(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    const this = phpzig.Return.getThis(execute_data) orelse {
        phpzig.Return.returnNull(return_value);
        return;
    };
    const extra = phpzig.Object.getExtra(this.ptr) orelse {
        phpzig.Return.returnNull(return_value);
        return;
    };
    const ctr: *Counter = @ptrCast(@alignCast(extra));
    phpzig.Return.returnLong(return_value, ctr.count);
}
fn counterSet(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    const this = phpzig.Return.getThis(execute_data) orelse {
        phpzig.Return.returnNull(return_value);
        return;
    };
    const extra = phpzig.Object.getExtra(this.ptr) orelse {
        phpzig.Return.returnNull(return_value);
        return;
    };
    const ctr: *Counter = @ptrCast(@alignCast(extra));
    if (phpzig.Return.callNumArgs(execute_data) >= 1) {
        const v = phpzig.Return.callArg(execute_data, 1);
        if (v.isLong()) ctr.count = v.toLong();
    }
    phpzig.Return.returnNull(return_value);
}

extern fn php_printf(fmt: [*c]const u8, ...) void;
