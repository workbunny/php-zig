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

php-zig 提供 `addPhpExtension` 构建辅助，一行完成扩展编译的全部通用工作
（target/optimize 注册、phpzig 依赖、PHP 头文件、C glue 编译、动态库输出）：

```zig
const std = @import("std");
const build_php_ext = @import("phpzig").build_php_ext;

pub fn build(b: *std.Build) void {
    const php_prefix = b.option([]const u8, "php", "PHP prefix path") orelse {
        @panic("-Dphp is required");
    };

    // 返回 *Step.Compile，可继续追加 step 依赖
    const ext = build_php_ext.addPhpExtension(b, "myext", b.path("src/main.zig"), .{
        .php_prefix = php_prefix,
    });
}
```

### 注册透传：自定义构建参数

`standardTargetOptions` / `standardOptimizeOption` 只能注册一次（重复会 panic），
由 `addPhpExtension` 统一注册。下游若有自己的 `-D` 参数或额外构建逻辑，
通过 `configure` 回调透传：

```zig
const ext = build_php_ext.addPhpExtension(b, "myext", b.path("src/main.zig"), .{
    .php_prefix = php_prefix,
    .configure = struct {
        fn cfg(ctx: *build_php_ext.ExtContext) void {
            // 解析自定义 -D 参数
            const extra = ctx.b.option(bool, "extra", "enable extra feature") orelse false;
            if (extra) {
                // 追加模块配置：额外头文件 / 链接库 / 宏
                ctx.module.addIncludePath(.{ .cwd_relative = ctx.b.pathJoin(&.{ ctx.php_prefix, "include" }) });
                ctx.module.linkSystemLibrary("curl", .{});
                ctx.module.defineCMacro("MYEXT_EXTRA", null);
            }
        }
    }.cfg,
});
```

`ExtContext` 提供：`b`（Build）、`module`（扩展模块）、`target`、`optimize`、`php_prefix`。
注意回调是普通函数，无法捕获外层局部变量，所需上下文均由 `ExtContext` 提供。

### 手动构建（可选）

若需完全手动控制构建流程，可参照 `example/hello/build.zig` 早期写法，但通常推荐
直接用 `addPhpExtension`。

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

### 参数元信息（comptime struct 反射）

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

### 参数默认值 + 可变参数

`ParamDesc` 支持默认值与可变参数，Reflection 可完整读取：

```zig
phpzig.FunctionDesc.createWithParams("greet", greet, &.{
    phpzig.ParamDesc.create("name"),
    // 默认值以 PHP 源码字符串形式给出
    phpzig.ParamDesc.createTypedWithDefault("greeting", .string, "\"Hello\""),
}),

phpzig.FunctionDesc.createWithParams("sum_all", sumAll, &.{
    phpzig.ParamDesc.create("first"),
    phpzig.ParamDesc.createVariadic("rest"),        // ...$rest
    // 带类型的可变参数：createVariadicTyped("rest", .long)
}),
```

```php
greet("Bob");            // → "Hello, Bob!"（使用默认 greeting）
greet("Bob", "Hi");      // → "Hi, Bob!"
sum_all(1, 2, 3);        // → 6
```

`default_value` 是**源码文本**，字符串默认值需写 `"\"Hello\""`，
数值/布尔/null 写字面量（`"0"`、`"1"`、`"NULL"`、`"[]"`）。
可变参数不计入必填参数数（`getNumberOfRequiredParameters`）。

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

// 语义判断（依赖 Zend 运行时）
if (arg.isCallable()) { ... }   // 函数名/闭包/可调用对象
if (arg.isIterable()) { ... }   // 数组/可遍历对象
if (arg.isScalar()) { ... }     // int/float/string/bool
if (arg.isEmpty()) { ... }      // 等价 PHP empty()
if (arg.isNumeric()) { ... }    // int/float/数值字符串
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

### zval 关系比较

```zig
const a = phpzig.Return.callArg(execute_data, 1);
const b = phpzig.Return.callArg(execute_data, 2);

const c: i8 = a.cmp(b);  // 三值比较：-1（小于）/ 0（等于）/ 1（大于），等价 PHP <=>
if (a.lt(b)) { /* a < b */ }
if (a.le(b)) { /* a <= b */ }
if (a.gt(b)) { /* a > b */ }
if (a.ge(b)) { /* a >= b */ }
```

### zval 算术运算符

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

### zval -> 数组

```zig
const arg = phpzig.Return.callArg(execute_data, 1);
const arr = arg.toArray() orelse { phpzig.Return.returnNull(return_value); return; };
```

### 异常抛出

```zig
// 抛出 \Exception（最常用）
phpzig.Throw.throwException("Division by zero");

// 按类名抛出任意异常/错误类（自定义异常类 + Error 家族）
phpzig.Throw.throwClass("MyAppException", "custom error");
phpzig.Throw.throwClassCode("MyAppError", "with code", 42);

// 内置 Error 家族快捷方法
phpzig.Throw.throwError("generic error");          // \Error
phpzig.Throw.typeError("type mismatch");           // \TypeError
phpzig.Throw.valueError("invalid value");          // \ValueError
phpzig.Throw.divisionByZeroError("div zero");      // \DivisionByZeroError
```

自定义异常/错误类用普通继承注册（不自定义 `create_object`，
message/code/trace 由父类 handler 正确初始化）：

```zig
phpzig.ClassDesc.createExtends("MyAppException", "Exception", &.{}),
phpzig.ClassDesc.createExtends("MyAppError", "Error", &.{}),
```

注意：`warning`/`notice` 是错误报告（`Error.warning/notice`），
不中断执行、也不属于异常/错误对象体系，勿混淆。

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

### 类属性

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

### 类属性 comptime struct 反射

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

### 类继承

```zig
phpzig.ClassDesc.createExtends("SavingsAccount", "BankAccount", &.{
    phpzig.FunctionDesc.create("interest", handler),
}),
```

```
父类必须是先于子类在同一个 `.classes` 数组中声明的类。
```

### 类全反射 — struct 即 class

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

### 数组高级操作

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

### zval -> 对象（toObject）

面向对象风格的对象包装：

```zig
fn readName(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const arg = phpzig.Return.callArg(ed, 1);
    const obj = arg.toObject() orelse { phpzig.Return.returnNull(rv); return; };
    if (obj.readProperty("name")) |v| {
        phpzig.Return.returnString(rv, v.toStringVal());
    } else {
        phpzig.Return.returnNull(rv);
    }
}
```

`Object` 结构体包装提供 `readProperty/writeProperty/call/instanceOf`，
由 `Zval.toObject()` 构造（非对象返回 null）。

### extern struct 对象绑定

将 Zig struct 生命周期绑定到 PHP 对象——每个对象实例持有独立的
struct 数据区，对象销毁时自动调用 dtor：

```zig
const Counter = struct { count: i64 = 0 };

fn counterInit(extra: ?*anyopaque) callconv(.c) void {
    const c: *Counter = @ptrCast(@alignCast(extra.?));
    c.count = 0;
}
fn counterDtor(extra: ?*anyopaque) callconv(.c) void {
    _ = extra; // 无堆资源可不清理
}

fn counterIncrement(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const this = phpzig.Return.getThis(ed) orelse { phpzig.Return.returnNull(rv); return; };
    const extra = phpzig.Object.getExtra(this.ptr) orelse { phpzig.Return.returnNull(rv); return; };
    const c: *Counter = @ptrCast(@alignCast(extra));
    c.count += 1;
    phpzig.Return.returnLong(rv, c.count);
}

// 注册：Data 类型决定 extra_size，init/dtor 为可选生命周期回调
phpzig.ClassDesc.createObject("Counter", &.{
    phpzig.FunctionDesc.create("increment", counterIncrement),
}, Counter, counterInit, counterDtor),
```

```php
$c = new Counter();
$c->increment();   // → 1
$c->increment();   // → 2（每个实例独立状态）
```

### 序列化

等价 PHP `serialize()` / `unserialize()`：

```zig
fn doSerialize(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const arg = phpzig.Return.callArg(ed, 1);
    phpzig.Serialize.serialize(arg.ptr, rv);
}

fn doUnserialize(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const s = phpzig.Return.callArg(ed, 1).toStringVal();
    var out: T.Zval = undefined;
    if (phpzig.Serialize.unserialize(s, &out)) {
        phpzig.Return.returnZval(rv, &out);
    } else {
        phpzig.Return.returnNull(rv);
    }
}
```

### INI 配置

声明式注册 INI 项（MINIT 自动注册 / MSHUTDOWN 自动注销），并支持变更通知：

```zig
const M = phpzig.Module(.{
    // ...
    .ini = &.{
        phpzig.IniEntry.createLong("myext.max_items", "100"),
        phpzig.IniEntry.createString("myext.greeting", "Hi"),
        phpzig.IniEntry.createBool("myext.enabled", "1"),
    },
    .ini_notify = onIniChange,   // 可选：任一 INI 项变更时触发
});

fn onIniChange(name: [*c]const u8, name_len: usize) callconv(.c) void {
    // name/name_len 为变更项名（C 字符串 + 长度）
}

// 读取
const max = phpzig.Ini.getLong("myext.max_items", 0);
if (phpzig.Ini.getString("myext.greeting")) |g| { /* ... */ }
const enabled = phpzig.Ini.getBool("myext.enabled", false);
```

### 资源类型

```zig
const MyRes = phpzig.Resource.register();
MyRes.store(fn, &/* ptr to anything */);

const ptr: ?*anyopaque = MyRes.fetch(&arg_zval);
```

### 请求级内存池 + 清理注册表 ★ v0.9.0

bailout（`longjmp`）会跳过 Zig `defer`，但 RSHUTDOWN 仍执行，故用两层机制兜底：

```zig
// RequestArena：请求级内存池，自动注册 RSHUTDOWN 回收
const arena = phpzig.RequestArena.init();
defer arena.deinit();                 // 正常路径（幂等），bailout 时 RSHUTDOWN 兜底
const a = arena.allocator();
var list: std.ArrayList(i64) = .empty; // Zig 0.16：unmanaged，方法传 allocator
defer list.deinit(a);
list.append(a, 10) catch unreachable;
const used = arena.bytesAllocated();   // 累计字节（预留统计接口）

// Cleanup：绕过 arena 自行管理资源时，注册任意回收逻辑
phpzig.Cleanup.register(myCleanupFn, data);
```

`defer` 负责正常路径，`Cleanup.register`/arena 负责 bailout 兜底，两者叠加。

### 内存归属心智模型

php-zig 遵循「PHP 用 PHP 的，Zig 用 Zig 的」，两类内存**边界清晰、互不重叠**：

| 资源 | 归谁管 | bailout 后 | 需要 arena/cleanup？ |
|------|--------|-----------|---------------------|
| `zval` / `zend_array` / `zend_string`（`Zval`/`Array`/`Object` 操作的对象） | **PHP 请求级内存池（emalloc）** | PHP 请求结束自动清空整个池，**不泄漏** | ❌ 否 |
| `c_allocator` 分配的内存 / fd / socket | **Zig 自己** | `defer` 被 longjmp 跳过 → **真泄漏** | ✅ 是 |

**要点**：
- `Array`/`Zval`/`Object` 等模块操作的是 PHP 的 `HashTable`（住在 emalloc 里），
  即使 bailout 跳过某个 `defer zval_ptr_dtor`，也只是「晚释放到请求结束」，**不会泄漏**。
- 这些模块里的 `defer zval_ptr_dtor` 是「提前归还引用计数」（性能优化），
  **不是防泄漏**——正确性不依赖它。
- 只有 **Zig 自己分配**（`c_allocator`）的内存/fd/socket 才会因 bailout 泄漏，
  这部分由 `RequestArena` / `Cleanup` 兜底。

### 内存最佳实践

**1. 临时字符串：用 arena 或栈缓冲，勿用 `c_allocator`**

```zig
// ❌ 错误：allocPrint(c_allocator) 后未释放，正常路径也泄漏
const msg = std.fmt.allocPrint(std.heap.c_allocator, "Hi {s}", .{name}) catch ...;
phpzig.Return.returnString(return_value, msg);   // returnString 内部复制到 PHP 池，msg 泄漏

// ✅ 正确：用请求级 arena（bailout-safe）
const arena = phpzig.RequestArena.init();
defer arena.deinit();
const msg = std.fmt.allocPrint(arena.allocator(), "Hi {s}", .{name}) catch ...;
phpzig.Return.returnString(return_value, msg);

// ✅ 更轻量：固定长度场景用栈缓冲
var buf: [128]u8 = undefined;
const msg = std.fmt.bufPrint(&buf, "Hi {s}", .{name}) catch ...;
phpzig.Return.returnString(return_value, msg);
```

**2. 长生命周期/跨请求数据：用 `c_allocator` 或 GeneralPurposeAllocator，并显式管理**

**3. 系统资源（fd/socket）：用 `Cleanup.register` 兜底**

```zig
const fd = std.posix.open(...) catch ...;
phpzig.Cleanup.register(closeFd, @ptrCast(@as(usize, fd)));
```

**4. `@memcpy` 不分配内存**：它只做字节复制，目标是调用者提供的内存
（通常是栈数组）。泄漏的唯一根源是「堆分配了没释放」，与 `@memcpy` 无关。

### Fiber 协程 ★ v0.9.1

定位：**PHP 是调度器（event-loop），Zig 提供挂起/唤起/检测能力**，不自行构建 event-loop。
Zig 扩展函数可在 Fiber 内挂起自己、把控制权交还 PHP 主协程，PHP 侧在合适时机
resume 后从挂起点继续执行。

**只读查询**（glue 直读 `zend_fiber` 结构体，零方法调用开销）：

```zig
phpzig.Fiber.isFiber(zv) -> bool          // instanceof Fiber
phpzig.Fiber.getStatus(zv) -> ?Status     // INIT/RUNNING/SUSPENDED/DEAD，非 Fiber 返回 null
phpzig.Fiber.getCurrent(&rv) -> bool      // 当前活跃 Fiber（EG(active_fiber)），非 Fiber 上下文 false
phpzig.Fiber.getReturn(zv, &rv) -> bool   // 最终返回值（仅 DEAD 且未抛异常）
phpzig.Fiber.create(callable, &rv) -> bool // 用 callable 构造 Fiber（等价 new Fiber($callable)）
```

**控制操作**（走 PHP 原生 `Fiber` 方法，复用校验 + `FiberError` 抛出）：

```zig
phpzig.Fiber.start(zv, &rv, args) -> bool        // 启动（须 Fiber 外，status == INIT）
phpzig.Fiber.suspend_(zv, &value, &rv) -> bool   // 挂起自己（须 Fiber 内）
phpzig.Fiber.resume_(zv, &value, &rv) -> bool    // 唤起（须 Fiber 外，SUSPENDED）
phpzig.Fiber.throw(zv, &ex, &rv) -> bool         // 注入异常（须 Fiber 外，SUSPENDED）
```

> `suspend`/`resume` 是 Zig 保留关键字（async 语义），故命名加下划线 `suspend_`/`resume_`。

**完整示例——Zig 闭包在 Fiber 内挂起自己，PHP event-loop 唤起**：

```zig
fn fiberBody(_: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    var cur: T.Zval = undefined;
    if (!phpzig.Fiber.getCurrent(&cur)) { phpzig.Return.returnNull(rv); return; }

    var value: T.Zval = undefined;
    c.phpglue_zval_set_stringl(&value, "from-fiber", 10);
    var ret: T.Zval = undefined;
    _ = phpzig.Fiber.suspend_(phpzig.Zval.fromPtr(&cur), &value, &ret);  // 挂起，交还 PHP

    // 被 resume 后从这里继续，ret 为 PHP 侧 resume 传入的值
    phpzig.Return.returnZval(rv, &ret);
}

// PHP 侧：
//   $fiber = hello_fiber_create(hello_fiber_body());  // Zig 用 callable 构造
//   $startRet = $fiber->start();      // fiber 内部 suspend，start 返回 "from-fiber"
//   $fiber->resume("from-php");       // 唤起，fiber 继续并返回 "from-php"
```

**关键语义**：`resume()` 返回「fiber **下一次 suspend** 交出的值」；若 fiber 直接完成
（不再 suspend），`resume()` 返回 null，最终结果走 `getReturn()` 获取。
控制操作是真正的栈切换（`swapcontext`），被挂起的 Zig 栈帧冻结在 fiber 栈上，
若 fiber 未完成即被销毁，`defer` 不执行——由 `Cleanup`/`RequestArena` 兜底。

### Observer 集中式观察代理 ★ v0.9.1

定位：所有关键事件汇聚到一个「代理」入口，下游 handler 决定统计/监测等
**旁路动作**（不拦截函数执行——拦截需走异常系统）。静态注册：MINIT 一次性，
请求期不变。

**五类观察点**：

| 观察点 | 回调签名 | 触发时机 |
|--------|---------|---------|
| 函数调用 begin/end | `fn(execute_data)` / `fn(execute_data, retval)` | 每次函数调用（含内部函数） |
| 错误 | `fn(type, filename+len, lineno, message+len)` | 每次 error 触发 |
| 函数声明 | `fn(name+len)` | 编译期声明函数 |
| 类链接 | `fn(name+len)` | 类链接时 |
| fiber init/switch/destroy | `fn(status)` / `fn(from_status, to_status)` | fiber 创建/启动/切换/销毁 |

**在 `moduleInit` 里注册**：

```zig
fn onFcallBegin(execute_data: *T.ZendExecuteData) callconv(.c) void {
    if (phpzig.Observer.funcName(execute_data)) |name| {
        // name 为被观察函数名，做统计/采样/插针
    }
}
fn onFcallEnd(execute_data: *T.ZendExecuteData, retval: *T.Zval) callconv(.c) void {
    _ = execute_data; _ = retval;
}
fn onError(type_: c_int, filename: [*c]const u8, filename_len: usize, lineno: u32,
           message: [*c]const u8, message_len: usize) callconv(.c) void {
    // error 观察（type_ 为 E_* 常量）
}
fn onFiberSwitch(from_status: c_int, to_status: c_int) callconv(.c) void {
    // fiber 切换观察
}

comptime {
    phpzig.moduleInit(@This(), .{
        .name = "monitor",
        .version = "1.0.0",
        .observer = .{
            .fcall_begin = onFcallBegin,
            .fcall_end = onFcallEnd,
            .@"error" = onError,        // error 是 Zig 保留字，须 @"error"
            .fiber_switch = onFiberSwitch,
            // 未设置的字段 = 不观察该类事件
        },
    });
}
```

**注意**：
- `error` 是 Zig 保留字，字段名须 `@"error"` 转义，访问时 `obs.@"error"`。
- fcall observer 观察**所有函数**（含内部函数），下游自行过滤；测试用相对增量断言。
- fiber 观察回调拿到的是 status（非 Fiber 对象），需要对象细节时配合 `Fiber.getCurrent()`。
- 观察是旁路动作，不拦截执行；返回值改写/reject 不在 observer 能力内（用 `Throw`）。

### 接口与实现

```zig
fn greet(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    phpzig.Return.returnString(rv, "hello");
}

const M = phpzig.Module(.{
    // ...
    .classes = &.{
        // 注册接口
        phpzig.ClassDesc.createInterface("Greetable", &.{
            phpzig.FunctionDesc.create("greet", greet),
        }),
        // 注册实现接口的类（接口须先声明）
        phpzig.ClassDesc.createImplements("Person", &.{
            phpzig.FunctionDesc.create("greet", greet),
        }, &.{"Greetable"}),
    },
});
```

### instanceof 检查

```zig
fn check(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const obj = phpzig.Return.callArg(ed, 1);
    const name = phpzig.Return.callArg(ed, 2).toStringVal();
    // 判断对象是否属于指定类（或实现指定接口）
    const is = phpzig.Object.instanceOf(obj.ptr, name);
    phpzig.Return.returnBool(rv, is);
}
```

### 闭包创建

从 Zig 函数创建 PHP Closure，可传给 `array_map` 等 PHP 回调参数：

```zig
fn myCallback(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    phpzig.Return.returnString(rv, "from closure");
}

fn make(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    var closure_zv: T.Zval = undefined;
    phpzig.Closure.create(myCallback, "my_closure", &closure_zv);
    phpzig.Return.returnZval(rv, &closure_zv);
}

// 调用传入的闭包
fn callIt(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const fn_arg = phpzig.Return.callArg(ed, 1);
    _ = phpzig.PhpFunc.callZval(fn_arg.ptr, rv, &.{});
}
```

### 错误报告

与异常抛出互补——error 用于 WARNING/NOTICE 等非致命报告：

```zig
fn warn(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    // 带 docref 前缀
    phpzig.Error.docref("warn", .warning, "something wrong");
    // 或无 docref
    phpzig.Error.warning("plain warning");
    phpzig.Error.notice("plain notice");
    phpzig.Return.returnNull(rv);
}
```

### 模块入口

在 `comptime` 块中调用 `phpzig.moduleInit(@This(), meta)`——扫描当前文件，
按命名约定自动发现函数与类，并导出 `get_module` 符号。

命名约定（声明须为 `pub`）：

| 声明 | 含义 |
|------|------|
| `pub fn php_<name>` | 模块函数 `<name>` |
| `pub fn php_<name>` + `pub const <name>Args` | 有参函数（Args 字段 = 参数名/类型） |
| `pub const Class_<name>` | 类 `<name>`（内部用 public_/static_ 等前缀） |

```zig
const phpzig = @import("phpzig");
const T = phpzig.php_types;

// 无参函数——自动发现
pub fn php_hello(_: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    phpzig.Return.returnString(rv, "Hello");
}

// 有参函数——参数由伴生 struct 反射
pub fn php_add(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    const a = phpzig.Return.callArg(ed, 1).toLong();
    const b = phpzig.Return.callArg(ed, 2).toLong();
    phpzig.Return.returnLong(rv, a + b);
}
pub const addArgs = struct { a: i64, b: i64 };   // php_add 的参数

comptime {
    phpzig.moduleInit(@This(), .{
        .name    = "myext",
        .version = "1.0.0",
        // 复杂场景用 .functions/.classes 显式补充（与自动发现合并）
        .classes = &.{ /* 继承/接口/常量/对象绑定等 */ },
        .constants = &.{ /* 模块常量 */ },
        .minit   = myMinit,
    });
}
```

**为何不能 100% 只写 `@This()`**：Zig 函数签名没有参数名（`@typeInfo(fn)` 拿不到
`fn add(a,b)` 的 a/b），所以有参函数必须用 `<name>Args` struct 提供参数名；
默认值/可变参数也无法从字段推导，需 `meta.functions` 显式。

`moduleInit(@This(), meta)` 的底层仍是 `Module()`（供需要持有 Module type 引用的高级用法）：

```zig
const M = phpzig.Module(.{ /* opts */ });
comptime { @export(&M.get_module, .{ .name = "get_module" }); }
```

## 运行测试

框架根目录运行 Zig 单元测试：

```bash
cd php-zig
zig build test
# 57/57 通过
```

集成测试扩展（`example/tests/`）编译后运行 PHP 集成测试：

```bash
cd example/tests
zig build -Dphp=/usr/local
php -d extension=zig-out/lib/libext-tests.so test_all.php
# 179/179 通过
```

最小示例（`example/hello/`）构建与运行：

```bash
cd example/hello
zig build -Dphp=/usr/local
php -d extension=zig-out/lib/libhello.so hello.php
# Hello from php-zig!
```
