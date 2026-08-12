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

### 参数元信息

`createWithParams` 声明参数名，在 PHP 反射中可读：

```zig
phpzig.FunctionDesc.createWithParams("add", add, &.{
    phpzig.ParamDesc.create("a"),
    phpzig.ParamDesc.create("b"),
}),
```

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
        phpzig.ClassDesc.create("Calculator", &.{
            phpzig.FunctionDesc.createStatic("add", calcAdd),
        }),
    },
    // ...
});
```

### 数组操作

```zig
var arr = phpzig.Array.init();

// 追加
arr.appendLong(1);
arr.appendString("hello");
arr.appendBool(true);

// 按索引设值
arr.setLong(0, 99);
arr.setString(0, "updated");

// 按键设值（关联数组）
arr.setAssocLong("key", 42);
arr.setAssocString("name", "value");

// 查询
if (arr.find("key")) |zv| { ... }
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

### 对象属性读写

```zig
var obj: T.Zval = undefined;
phpzig.PhpFunc.call0("stdClass", &obj);

phpzig.Object.writeProperty(&obj, "name", &value_zval);
if (phpzig.Object.readProperty(&obj, "name")) |prop| { ... }
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
# 18/18 通过
```

示例扩展编译后运行 PHP 集成测试：

```bash
cd example
zig build -Dphp=/usr/local
php -d extension=zig-out/lib/libhello.so test_all.php
# 47/47 通过
```
