# php-zig 开发教程

从零到一编写一个 PHP 扩展。

## 前置要求

- Zig 0.16.0+
- PHP 开发头文件（`php.h`、`zend_API.h` 等，通常由 `php-dev` 或 `php-devel` 包提供）

## 项目结构

```
myext/
├── build.zig          ← 构建配置
├── build.zig.zon      ← 包清单 + phpzig 依赖
└── src/
    └── main.zig       ← 扩展源码
```

## build.zig.zon

```zig
.{
    .name = "myext",
    .version = "0.1.0",
    .dependencies = .{
        .phpzig = .{ .path = "../php-zig" },
    },
    .paths = .{"src"},
}
```

## build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const php_prefix = b.option([]const u8, "php", "PHP prefix path") orelse {
        @panic("-Dphp is required");
    };
    const phpzig_dep = b.dependency("phpzig", .{ .target = target, .optimize = optimize });
    const phpzig_mod = phpzig_dep.module("phpzig");

    const ext_mod = b.addModule("myext_root", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ext_mod.addImport("phpzig", phpzig_mod);

    const subdirs = [_][]const u8{
        "include/php/main", "include/php", "include/php/Zend",
        "include/php/ext", "include/php/TSRM",
    };
    for (subdirs) |sub| ext_mod.addIncludePath(.{
        .cwd_relative = b.pathJoin(&.{ php_prefix, sub }),
    });
    ext_mod.addIncludePath(phpzig_dep.path("glue"));
    ext_mod.linkSystemLibrary("c", .{});
    ext_mod.addCSourceFile(.{ .file = phpzig_dep.path("glue/php_glue.c"), .flags = &.{} });

    const ext = b.addLibrary(.{ .linkage = .dynamic, .name = "myext", .root_module = ext_mod });
    b.installArtifact(ext);
}
```

## 第一个扩展

### 基础函数

```zig
const phpzig = @import("phpzig");
const T = phpzig.php_types;

fn greet(execute_data: *T.ZendExecuteData, return_value: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(execute_data) < 1) {
        phpzig.Return.returnNull(return_value);
        return;
    }
    const arg = phpzig.Return.callArg(execute_data, 1);
    if (!arg.isString()) { phpzig.Return.returnNull(return_value); return; }

    // 用 Zig 标准库格式化字符串
    const allocator = std.heap.c_allocator;
    const msg = allocator.allocPrint("Hello, {s}!", .{arg.toStringVal()}) catch return;
    phpzig.Return.returnString(return_value, msg);
}

fn add(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(ed) < 2) { phpzig.Return.returnNull(rv); return; }
    const a = phpzig.Return.callArg(ed, 1);
    const b = phpzig.Return.callArg(ed, 2);
    phpzig.Return.returnLong(rv,
        (if (a.isLong()) a.toLong() else 0) +
        (if (b.isLong()) b.toLong() else 0));
}
```

### 参数元信息（声明式）

`createWithParams` 声明参数名，在 PHP 反射中可读：

```zig
phpzig.FunctionDesc.createWithParams("add", add, &.{
    phpzig.ParamDesc.create("a"),
    phpzig.ParamDesc.create("b"),
}),
```

### 参数元信息（comptime struct 反射）★ v0.4.0 新增

Zig 惯用方式：定义一个 struct，字段名 = 参数名，字段类型 → PHP 类型标注。
编译期自动推导 arg_info，零手写：

```zig
// 1. 定义参数 struct（字段顺序 = PHP 参数顺序）
const AddArgs = struct {
    a: i64,          // → 参数 "a"，类型 LONG
    b: i64,          // → 参数 "b"，类型 LONG
};

const FormatArgs = struct {
    name: []const u8,  // → 参数 "name"，类型 STRING
    age: i64,           // → 参数 "age"，类型 LONG
};

// 2. 一行注册
phpzig.FunctionDesc.createFrom("add", add, AddArgs),
phpzig.FunctionDesc.createFrom("format", format, FormatArgs),

// 3. Optional 参数用 ?T
const OptArgs = struct {
    name: []const u8,
    limit: ?i64,       // → 参数 "limit"，类型 LONG，allow_null=true
};
phpzig.FunctionDesc.createFrom("query", query, OptArgs),
```

**类型映射表**：

| Zig 类型 | PHP 类型 |
|----------|---------|
| `i64`, `u64`, `isize`, `usize` | `int` |
| `f64`, `f32` | `float` |
| `bool` | `bool` |
| `[]const u8`, `[:0]const u8` | `string` |
| `*T.Zval` | `mixed` |

**静态方法**用 `createStaticFrom`，其余完全相同。

声明式 `createWithParams` 完全保留，与 comptime 反射双轨并行——
C/C++ 开发者习惯声明式，Zig 开发者习惯类型推导，各取所需。

### 返回值类型

全部 9 种：

```zig
phpzig.Return.returnString(rv, "hello");
phpzig.Return.returnStringl(rv, str, len);
phpzig.Return.returnLong(rv, 42);
phpzig.Return.returnDouble(rv, 3.14);
phpzig.Return.returnBool(rv, true);
phpzig.Return.returnNull(rv);
phpzig.Return.returnTrue(rv);
phpzig.Return.returnFalse(rv);
phpzig.Return.returnZval(rv, &other_zval);
```

### zval 类型判断与取值

```zig
const arg = phpzig.Return.callArg(execute_data, 1);

if (arg.isString()) {
    const s: []const u8 = arg.toStringVal();
}

if (arg.isLong()) {
    const v: c_long = arg.toLong();
}

if (arg.isDouble()) {
    const v: f64 = arg.toDouble();
}

if (arg.isBool()) {
    const v: bool = arg.toBool();
}

if (arg.isNull()) { ... }
if (arg.isArray()) { ... }
if (arg.isObject()) { ... }
if (arg.isResource()) { ... }
```

### zval 设值

```zig
var zv: T.Zval = undefined;
c.phpglue_zval_set_null(&zv);
c.phpglue_zval_set_long(&zv, 42);
c.phpglue_zval_set_double(&zv, 3.14);
c.phpglue_zval_set_stringl(&zv, "hello", 5);
c.phpglue_zval_set_bool(&zv, true);
```

### zval 比较

```zig
const a = phpzig.Return.callArg(execute_data, 1);
const b = phpzig.Return.callArg(execute_data, 2);

if (a.eql(b)) { /* 按 PHP 类型值比较相等 */ }
if (a.neq(b)) { /* 不等 */ }
```

### zval 关系比较 ★ v0.6.0

```zig
const a = phpzig.Return.callArg(execute_data, 1);
const b = phpzig.Return.callArg(execute_data, 2);

const c: i8 = a.cmp(b);  // 三值比较：-1（小于）/ 0（等于）/ 1（大于），等价 PHP <=>
if (a.lt(b)) { /* a < b */ }
if (a.le(b)) { /* a <= b */ }
if (a.gt(b)) { /* a > b */ }
if (a.ge(b)) { /* a >= b */ }
```

### zval 算术运算符 ★ v0.6.0

```zig
const a = phpzig.Return.callArg(execute_data, 1);
const b = phpzig.Return.callArg(execute_data, 2);

var result: T.Zval = undefined;
if (a.add(b, &result)) { /* result = a + b */ }
if (a.sub(b, &result)) { /* result = a - b */ }
if (a.mul(b, &result)) { /* result = a * b */ }
if (a.div(b, &result)) { /* result = a / b */ }
if (a.mod_(b, &result)) { /* result = a % b */ }
```

算术运算符结果写入调用者提供的 `*T.Zval`（成功返回 `true`），遵循 Zig 显式所有权哲学。
类型不兼容（如 PHP 8 中字符串 `+` 字符串）时返回 `false`，`result` 未定义。

### zval 到数组

```zig
const arg = phpzig.Return.callArg(execute_data, 1);
const arr = arg.toArray() orelse { phpzig.Return.returnNull(return_value); return; };
```

### 异常抛出

```zig
phpzig.Throw.throwException("Division by zero");
```

### 调用 PHP 函数

```zig
var retval: T.Zval = undefined;

// 调用 strlen("hello") → 5
if (phpzig.PhpFunc.call1Str("strlen", &retval, "hello")) {
    const len: c_long = c.phpglue_zval_get_long(&retval);
    c.phpglue_zval_ptr_dtor(&retval);
}

// 调用 abs(-5) → 5
if (phpzig.PhpFunc.call1Long("abs", &retval, -5)) { ... }

// 调用 implode("", ["a","b"]) → "ab"
if (phpzig.PhpFunc.call("implode", &retval, &.{ zv_glue, zv_arr })) { ... }
```

### 模块常量

```zig
.constants = &.{
    phpzig.ConstantDesc.createLong("MAX_SIZE", 4096),
    phpzig.ConstantDesc.createDouble("PI", 3.14),
    phpzig.ConstantDesc.createString("AUTHOR", "php-zig"),
    phpzig.ConstantDesc.createBool("DEBUG", false),
    phpzig.ConstantDesc.createNull("NONE"),
},
```

### 生命周期钩子

```zig
fn myMinit(type_: c_int, module_number: c_int) callconv(.c) c_int {
    // 全局资源初始化
    return 0; // SUCCESS
}

fn myRinit(type_: c_int, module_number: c_int) callconv(.c) c_int {
    // 请求级初始化
    return 0;
}

const M = phpzig.Module(.{
    .name = "myext",
    .version = "1.0.0",
    .minit = myMinit,
    .rinit = myRinit,
    // ...
});
```

### 类注册

```zig
fn calcAdd(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    // 实现略
}

const M = phpzig.Module(.{
    .name = "myext",
    .version = "1.0.0",
    .classes = &.{
        // 静态方法
        phpzig.ClassDesc.create("Calculator", &.{
            phpzig.FunctionDesc.createStatic("add", calcAdd),
        }),
        // 含类常量的类
        phpzig.ClassDesc.createWithConstants("MathConst", &.{}, &.{
            phpzig.ClassConstantDesc.createLong("PI", 3),
            phpzig.ClassConstantDesc.createString("NAME", "Math"),
        }),
    },
    // ...
});
```

### 类属性 ★ v0.5.0

声明式创建属性，5 种类型 + 访问修饰符：

```zig
// 声明式
phpzig.ClassDesc.createWithProperties("BankAccount", &.{
    phpzig.FunctionDesc.create("__construct", handler),
    phpzig.FunctionDesc.createProtected("getBalance", handler),
    phpzig.FunctionDesc.createPrivate("internal", handler),
}, &.{
    phpzig.ClassPropertyDesc.createLong("balance", 0),
    phpzig.ClassPropertyDesc.createBool("open", true).makeProtected(),
    phpzig.ClassPropertyDesc.createString("label", "default").makeStatic(),
    phpzig.ClassPropertyDesc.createNull("data"),
}),
```

### 类属性 comptime struct 反射 ★ v0.5.0

```zig
const BankProps = struct {
    balance: i64 = 0,         // → long 属性，默认值 0
    open: bool = true,        // → bool 属性，默认值 true
    rate: f64 = 0.05,         // → double 属性，默认值 0.05
    label: []const u8 = "ok", // → string 属性，默认值 "ok"
};

phpzig.ClassDesc.createWithPropsFrom("Bank", &.{
    phpzig.FunctionDesc.create("__construct", handler),
}, BankProps)
```

### 类继承 ★ v0.5.0

```zig
phpzig.ClassDesc.createExtends("SavingsAccount", "BankAccount", &.{
    phpzig.FunctionDesc.create("interest", handler),
}),
```

```
父类必须是先于子类在同一个 `.classes` 数组中声明的类。
```

### 类全反射 ★ v0.5.1 — struct 即 class

一个 struct 同时定义方法 + 属性 + 魔术方法，编译期全自动推导。

方法命名约定：`public_xxx` → public function xxx，`protect_` → protected，`private_` → private，`static_` → public static；`magic_` → `__` 前缀魔术方法。

```zig
const BankAccount = struct {
    // 字段 → PHP 属性
    balance: i64 = 0,
    open: bool = true,

    // public_magic_construct → public function __construct
    pub fn public_magic_construct(_: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
        phpzig.Return.returnNull(rv);
    }
    // protect_getBalance → protected function getBalance
    pub fn protect_getBalance(_: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
        phpzig.Return.returnLong(rv, 1000);
    }
    // private_internal → private function internal
    pub fn private_internal(_: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
        phpzig.Return.returnNull(rv);
    }
};

// 一行注册
phpzig.ClassDesc.createFromStruct("BankAccount", BankAccount)
```

支持的魔术方法（`magic_` 前缀）：

| Zig 声明 | PHP 方法 | Zig 声明 | PHP 方法 |
|----------|---------|----------|---------|
| `magic_construct` | `__construct` | `magic_destruct` | `__destruct` |
| `magic_call` | `__call` | `magic_callStatic` | `__callStatic` |
| `magic_get` | `__get` | `magic_set` | `__set` |
| `magic_isset` | `__isset` | `magic_unset` | `__unset` |
| `magic_sleep` | `__sleep` | `magic_wakeup` | `__wakeup` |
| `magic_toString` | `__toString` | `magic_invoke` | `__invoke` |
| `magic_clone` | `__clone` | `magic_debugInfo` | `__debugInfo` |
| `magic_serialize` | `__serialize` | `magic_unserialize` | `__unserialize` |
| `magic_set_state` | `__set_state` | | |

### 数组操作

```zig
var zv: T.Zval = undefined;
var arr = phpzig.Array.init(&zv);

// 追加
arr.appendLong(1);
arr.appendString("hello");
arr.appendBool(true);

// 按索引设值
arr.setLong(0, 99);

// 按键设值（关联数组）
arr.setAssocLong("key", 42);

// 查询
if (arr.find("key")) |zv2| { ... }
if (arr.exists("key")) { ... }

// 删除
arr.del("key");
arr.delIndex(0);

// 弹出
if (arr.pop()) |val| { ... }

// 迭代
var iter = arr.iterator();
if (iter.value()) |val| { ... }
while (iter.next()) {
    if (iter.value()) |val| { ... }
}

// 计数
const n: u32 = arr.count();
```

### 数组高级操作 ★ v0.6.0

```zig
// shift — 移除并返回首元素（空数组返回 null）
if (arr.shift()) |val| { ... }

// unshift — 头部插入（数字键重索引）
arr.unshift(some_zval);

// merge — 合并两个数组（数字键重索引、字符串键覆盖）
var merged_zv: T.Zval = undefined;
arr1.merge(arr2, &merged_zv);

// keys / values — 收集键或值
var keys_zv: T.Zval = undefined;
arr.keysInto(&keys_zv);

var vals_zv: T.Zval = undefined;
arr.valuesInto(&vals_zv);

// slice — 切片（len<0 表示到末尾）
var slice_zv: T.Zval = undefined;
arr.sliceInto(&slice_zv, 1, 2);  // 从下标 1 起取 2 个

// sort — 值排序 + 重索引（原地修改）
arr.sort();

// each — foreach 语法糖，context 指针捕获可变状态
const SumCtx = struct { sum: c_long = 0 };
var ctx = SumCtx{};
arr.each(&ctx, struct {
    fn cb(ud: ?*anyopaque, v: phpzig.Zval) void {
        const s: *SumCtx = @ptrCast(@alignCast(ud.?));
        s.sum += v.toLong();
    }
}.cb);
```

**注意**：`merge/keysInto/valuesInto/sliceInto` 都接受输出参数 `*T.Zval`，由调用者管理结果内存生命周期（与 `Array.init()` 同哲学）。`sort/unshift` 原地修改，调用前若数组可能是共享的，先 `arr.separate()` 写时分离。

### 数组算法（filter / map / reduce）

```zig
var src_zv: T.Zval = undefined;
var src = phpzig.Array.init(&src_zv);
src.appendLong(1); src.appendLong(2); src.appendLong(3); src.appendLong(4);

// filter — 输出到调用者提供的 zval
var filtered_zv: T.Zval = undefined;
src.filterInto(&filtered_zv, struct {
    fn even(v: phpzig.Zval) bool { return v.toLong() % 2 == 0; }
}.even);

// map — 每个元素 ×2
var mapped_zv: T.Zval = undefined;
src.mapInto(&mapped_zv, c_long, struct {
    fn double(v: phpzig.Zval) c_long { return v.toLong() * 2; }
}.double);

// reduce — 求和
const sum = src.reduce(c_long, 0, struct {
    fn add(acc: c_long, v: phpzig.Zval) c_long { return acc + v.toLong(); }
}.add);
```

### 对象操作

```zig
// 创建对象
var obj: T.Zval = undefined;
phpzig.Object.createStdClass(&obj);

// 写入属性
var zv_name: T.Zval = undefined;
c.phpglue_zval_set_stringl(&zv_name, "php-zig", 7);
phpzig.Object.writeProperty(&obj, "name", &zv_name);

// 读取属性（zend_hash_find 直读 HashTable）
if (phpzig.Object.readProperty(&obj, "name")) |prop| {
    const val = prop.toStringVal();
}

// 调用方法
var retval: T.Zval = undefined;
if (phpzig.Object.call(&obj, "someMethod", &retval, &.{})) {
    // 处理返回值
}
```

### 资源类型

```zig
const MyRes = phpzig.Resource.register();
MyRes.store(fn, &/* ptr to anything */);

const ptr: ?*anyopaque = MyRes.fetch(&arg_zval);
```

### 模块入口

```zig
const M = phpzig.Module(.{
    .name      = "myext",
    .version   = "1.0.0",
    .functions = &.{ /* ... */ },
    .classes   = &.{ /* ... */ },
    .constants = &.{ /* ... */ },
    .minit     = myMinit,
    .rinit     = myRinit,
    .info_func = myInfo,
});

comptime {
    @export(&M.get_module, .{ .name = "get_module" });
}
```

## 运行测试

框架根目录运行 Zig 单元测试：

```bash
cd php-zig
zig build test
# 54/54 通过（v0.6.0）
```

示例扩展编译后运行 PHP 集成测试：

```bash
cd example
zig build -Dphp=/usr/local
php -d extension=zig-out/lib/libhello.so test_all.php
# 100/100 通过（v0.6.0）
```
