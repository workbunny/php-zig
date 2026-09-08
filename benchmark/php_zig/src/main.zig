//! php-zig benchmark 扩展实现（模块 bench_zig）
//!
//! 提供与 bench_c / pure_php 严格相同语义的用例，测什么见 README.md。
//! 语义必须与另两方一致，否则对比无意义——改动本文件时同步另两个实现。

const std = @import("std");
const phpzig = @import("phpzig");
const T = phpzig.php_types;
const c = phpzig.php_c;

// — empty：纯调用分发开销 —

pub fn php_bench_empty(_: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    phpzig.Return.returnNull(rv);
}

// — add：参数读取 + 整数返回 —

pub fn php_bench_add(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const a = phpzig.Return.callArg(ed, 1).toLong();
    const b = phpzig.Return.callArg(ed, 2).toLong();
    phpzig.Return.returnLong(rv, a + b);
}
pub const bench_addArgs = struct { a: *T.Zval, b: *T.Zval };

// — concat：与 C 侧同路径（一次分配 + 两次 memcpy），不引入格式串解析开销 —

pub fn php_bench_concat(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const s1 = phpzig.Return.callArg(ed, 1).toStringVal();
    const s2 = phpzig.Return.callArg(ed, 2).toStringVal();

    // 一次分配 + 两次 memcpy + 零拷贝移交，与 C 侧 RETVAL_STR 完全同路径。
    // 注意不可用 returnString：那里是 RETVAL_STRING = zend_string_init，
    // 会再分配一次并 memcpy，等于分配两次、拷贝两次。
    const s = c.phpglue_string_alloc(s1.len + s2.len) orelse {
        phpzig.Return.returnNull(rv);
        return;
    };
    const buf = c.phpglue_string_buffer(s);
    @memcpy(buf[0..s1.len], s1);
    @memcpy(buf[s1.len..], s2);
    c.phpglue_return_string_ptr(rv, s);
}
pub const bench_concatArgs = struct { s1: *T.Zval, s2: *T.Zval };

// — array_build：数组写入 —

pub fn php_bench_array_build(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callArg(ed, 1).toLong();
    var zv: T.Zval = undefined;
    var arr = phpzig.Array.init(&zv);
    defer c.phpglue_zval_ptr_dtor(&zv);
    var i: T.zend_long = 0;
    while (i < n) : (i += 1) arr.appendLong(i);
    phpzig.Return.returnLong(rv, n);
}
pub const bench_array_buildArgs = struct { n: *T.Zval };

// — array_read：建表 + 逐个读回求和（测读，与 array_build 分离） —

pub fn php_bench_array_read(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callArg(ed, 1).toLong();
    var zv: T.Zval = undefined;
    var arr = phpzig.Array.init(&zv);
    defer c.phpglue_zval_ptr_dtor(&zv);
    var i: T.zend_long = 0;
    while (i < n) : (i += 1) arr.appendLong(i);

    var sum: T.zend_long = 0;
    var j: T.zend_long = 0;
    while (j < n) : (j += 1) {
        if (arr.findIndex(@intCast(j))) |v| sum += v.toLong();
    }
    phpzig.Return.returnLong(rv, sum);
}
pub const bench_array_readArgs = struct { n: *T.Zval };

// — assoc：关联数组写 + 读（字符串键，走哈希而非连续索引） —

pub fn php_bench_assoc(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callArg(ed, 1).toLong();
    var zv: T.Zval = undefined;
    var arr = phpzig.Array.init(&zv);
    defer c.phpglue_zval_ptr_dtor(&zv);

    var key_buf: [32]u8 = undefined;
    var i: T.zend_long = 0;
    while (i < n) : (i += 1) {
        const key = std.fmt.bufPrint(&key_buf, "k{d}", .{i}) catch continue;
        arr.setAssocLong(key, i);
    }

    var sum: T.zend_long = 0;
    var j: T.zend_long = 0;
    while (j < n) : (j += 1) {
        const key = std.fmt.bufPrint(&key_buf, "k{d}", .{j}) catch continue;
        if (arr.find(key)) |v| sum += v.toLong();
    }
    phpzig.Return.returnLong(rv, sum);
}
pub const bench_assocArgs = struct { n: *T.Zval };

// — str_len：读字符串入参 + 返回长度（不分配新串） —

pub fn php_bench_str_len(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const s = phpzig.Return.callArg(ed, 1).toStringVal();
    phpzig.Return.returnLong(rv, @intCast(s.len));
}
pub const bench_str_lenArgs = struct { s: *T.Zval };

// — math：算术密集（纯计算，无 Zend 交互），测代码生成质量 —

pub fn php_bench_math(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callArg(ed, 1).toLong();
    var acc: T.zend_long = 0;
    var i: T.zend_long = 0;
    while (i < n) : (i += 1) {
        acc += @mod(i * 31 + 7, 1009);
    }
    phpzig.Return.returnLong(rv, acc);
}
pub const bench_mathArgs = struct { n: *T.Zval };

// — call_php：从扩展回调 PHP 函数（strlen）——扩展→PHP 跨界开销 —

pub fn php_bench_call_php(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callArg(ed, 1).toLong();
    var total: T.zend_long = 0;
    var i: T.zend_long = 0;
    while (i < n) : (i += 1) {
        var ret: T.Zval = undefined;
        if (phpzig.PhpFunc.call1Str("strlen", &ret, "hello")) {
            total += c.phpglue_zval_get_long(&ret);
            c.phpglue_zval_ptr_dtor(&ret);
        }
    }
    phpzig.Return.returnLong(rv, total);
}
pub const bench_call_phpArgs = struct { n: *T.Zval };

// — object：stdClass 属性写 + 读 —

pub fn php_bench_object(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callArg(ed, 1).toLong();
    var obj: T.Zval = undefined;
    c.phpglue_object_create_stdclass(&obj);
    defer c.phpglue_zval_ptr_dtor(&obj);

    var key_buf: [32]u8 = undefined;
    var val: T.Zval = undefined;
    var i: T.zend_long = 0;
    while (i < n) : (i += 1) {
        const key = std.fmt.bufPrint(&key_buf, "p{d}", .{i}) catch continue;
        c.phpglue_zval_set_long(&val, i);
        phpzig.Object.writeProperty(&obj, key, &val);
    }

    var sum: T.zend_long = 0;
    var j: T.zend_long = 0;
    while (j < n) : (j += 1) {
        const key = std.fmt.bufPrint(&key_buf, "p{d}", .{j}) catch continue;
        if (phpzig.Object.readProperty(&obj, key)) |v| sum += v.toLong();
    }
    phpzig.Return.returnLong(rv, sum);
}
pub const bench_objectArgs = struct { n: *T.Zval };

// — throw：抛异常 + 清理。测错误路径开销而非正常路径 —

pub fn php_bench_throw(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callArg(ed, 1).toLong();
    var caught: T.zend_long = 0;
    var i: T.zend_long = 0;
    while (i < n) : (i += 1) {
        c.phpglue_throw_exception("bench", 5);
        if (c.phpglue_exception_exists() != 0) {
            c.phpglue_clear_exception();
            caught += 1;
        }
    }
    phpzig.Return.returnLong(rv, caught);
}
pub const bench_throwArgs = struct { n: *T.Zval };

// — mixed：混合类型数组（真实业务数据的常见形态） —
//   纯数字数组的读取只需 Z_LVAL_P；异构数据才需要按类型分派，这才是常例。

pub fn php_bench_mixed(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callArg(ed, 1).toLong();
    var zv: T.Zval = undefined;
    var arr = phpzig.Array.init(&zv);
    defer c.phpglue_zval_ptr_dtor(&zv);

    var key_buf: [24]u8 = undefined;
    var i: T.zend_long = 0;
    while (i < n) : (i += 1) {
        switch (@mod(i, 3)) {
            0 => arr.appendLong(i),
            1 => {
                const key = std.fmt.bufPrint(&key_buf, "v{d}", .{i}) catch continue;
                arr.appendString(key);
            },
            else => arr.appendDouble(@as(f64, @floatFromInt(i)) * 1.5),
        }
    }

    var sum: T.zend_long = 0;
    var j: T.zend_long = 0;
    while (j < n) : (j += 1) {
        if (arr.findIndex(@intCast(j))) |v| sum += v.toLong();
    }
    phpzig.Return.returnLong(rv, sum);
}
pub const bench_mixedArgs = struct { n: *T.Zval };

// — nested：嵌套数组（配置、JSON 类结构的常见形态） —

pub fn php_bench_nested(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callArg(ed, 1).toLong();
    var zv: T.Zval = undefined;
    var arr = phpzig.Array.init(&zv);
    defer c.phpglue_zval_ptr_dtor(&zv);

    var i: T.zend_long = 0;
    while (i < n) : (i += 1) {
        var row_zv: T.Zval = undefined;
        var row = phpzig.Array.init(&row_zv);   // 返回 Array 值，须 var 才能取其可变地址
        row.setAssocLong("id", i * 4);
        // appendZval 底层是 add_next_index_zval——**接管**所有权而非增加引用
        // 计数。此处再 ptr_dtor 会把数组持有的底层数据一并释放，读出来是 0。
        arr.appendZval(phpzig.Zval.fromPtr(&row_zv));
    }

    var sum: T.zend_long = 0;
    var j: T.zend_long = 0;
    while (j < n) : (j += 1) {
        const row = arr.findIndex(@intCast(j)) orelse continue;
        const inner = phpzig.Array.fromZval(row);
        if (inner.find("id")) |id| sum += id.toLong();
    }
    phpzig.Return.returnLong(rv, sum);
}
pub const bench_nestedArgs = struct { n: *T.Zval };

// — strkey：字符串键读密集访问（配置查找、字典场景） —

pub fn php_bench_strkey(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callArg(ed, 1).toLong();
    var zv: T.Zval = undefined;
    var arr = phpzig.Array.init(&zv);
    defer c.phpglue_zval_ptr_dtor(&zv);

    // 键池固定 64 个，模拟字典/枚举表的实际规模
    var key_buf: [32]u8 = undefined;
    var i: T.zend_long = 0;
    while (i < 64) : (i += 1) {
        const key = std.fmt.bufPrint(&key_buf, "key_{d}", .{i}) catch continue;
        arr.setAssocLong(key, i);
    }

    var sum: T.zend_long = 0;
    var j: T.zend_long = 0;
    while (j < n) : (j += 1) {
        const key = std.fmt.bufPrint(&key_buf, "key_{d}", .{@mod(j, 64)}) catch continue;
        if (arr.find(key)) |v| sum += v.toLong();
    }
    phpzig.Return.returnLong(rv, sum);
}
pub const bench_strkeyArgs = struct { n: *T.Zval };

// — method：类方法调用（OOP 是主流场景，与纯函数调用的分布不同） —

pub fn php_bench_method(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const obj = phpzig.Return.callArg(ed, 1);
    const n = phpzig.Return.callArg(ed, 2).toLong();

    var total: T.zend_long = 0;
    var i: T.zend_long = 0;
    while (i < n) : (i += 1) {
        var ret: T.Zval = undefined;
        if (phpzig.Object.call(obj.ptr, "method", &ret, &.{})) {
            total += c.phpglue_zval_get_long(&ret);
            c.phpglue_zval_ptr_dtor(&ret);
        }
    }
    phpzig.Return.returnLong(rv, total);
}
pub const bench_methodArgs = struct { obj: *T.Zval, n: *T.Zval };

// — serialize：PHP serialize/unserialize（扩展常用能力） —

pub fn php_bench_serialize(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callArg(ed, 1).toLong();
    var zv: T.Zval = undefined;
    var arr = phpzig.Array.init(&zv);
    defer c.phpglue_zval_ptr_dtor(&zv);
    var i: T.zend_long = 0;
    while (i < 8) : (i += 1) arr.appendLong(i);

    var total: T.zend_long = 0;
    var j: T.zend_long = 0;
    while (j < n) : (j += 1) {
        var out: T.Zval = undefined;
        phpzig.Serialize.serialize(&zv, &out);
        total += @intCast(phpzig.Zval.fromPtr(&out).toStringVal().len);
        c.phpglue_zval_ptr_dtor(&out);
    }
    phpzig.Return.returnLong(rv, total);
}
pub const bench_serializeArgs = struct { n: *T.Zval };

// — closure：创建闭包并调用（扩展回调 PHP 的常见形态） —

pub fn php_bench_closure(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callArg(ed, 1).toLong();
    var total: T.zend_long = 0;
    var i: T.zend_long = 0;
    while (i < n) : (i += 1) {
        var cl: T.Zval = undefined;
        phpzig.Closure.create(struct {
            fn handler(_: *T.ZendExecuteData, r: *T.Zval) callconv(.c) void {
                phpzig.Return.returnLong(r, 1);
            }
        }.handler, "bench_closure_handler", &cl);
        defer c.phpglue_zval_ptr_dtor(&cl);

        var ret: T.Zval = undefined;
        if (phpzig.PhpFunc.callZval(&cl, &ret, &.{})) {
            total += c.phpglue_zval_get_long(&ret);
            c.phpglue_zval_ptr_dtor(&ret);
        }
    }
    phpzig.Return.returnLong(rv, total);
}
pub const bench_closureArgs = struct { n: *T.Zval };

// — fiber：创建 + 切换（php-zig 特色能力，纯 PHP 也有 Fiber 可对标） —

pub fn php_bench_fiber(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callArg(ed, 1).toLong();
    // zend_fiber_create 非公开 API，故与 C 侧一致：都经 PHP 函数
    // bench_make_fiber 创建，走同一条 Zend 路径才可比
    var total: T.zend_long = 0;
    var i: T.zend_long = 0;
    while (i < n) : (i += 1) {
        var ret: T.Zval = undefined;
        if (phpzig.PhpFunc.call1Str("bench_make_fiber", &ret, "bench_fiber_body")) {
            c.phpglue_zval_ptr_dtor(&ret);
            total += 1;
        }
    }
    phpzig.Return.returnLong(rv, total);
}
pub const bench_fiberArgs = struct { n: *T.Zval };

// — arena：RequestArena 分配（php-zig 特色：请求级内存池） —

pub fn php_bench_arena(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const n = phpzig.Return.callArg(ed, 1).toLong();
    const arena = phpzig.RequestArena.init() orelse {
        phpzig.Return.returnNull(rv);
        return;
    };
    defer arena.deinit();
    const alloc = arena.allocator();

    var total: T.zend_long = 0;
    var i: T.zend_long = 0;
    while (i < n) : (i += 1) {
        const buf = alloc.alloc(u8, 64) catch break;
        buf[0] = 1;
        total += 64;
    }
    phpzig.Return.returnLong(rv, total);
}
pub const bench_arenaArgs = struct { n: *T.Zval };

comptime {
    phpzig.moduleInit(@This(), .{
        .name = "bench_zig",
        .version = "1.0.0",
    });
}
