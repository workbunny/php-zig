//! Zig 单元测试辅助：纯 Zig 构造体（无需 PHP 运行时）
//!
//! 覆盖：IS_* 常量 / Zval 大小 / FunctionDesc / ClassDesc / ConstantDesc / ParamDesc
//! 所有测试不依赖 C glue 或 PHP 运行时。

const php_types = @import("php_types.zig");
const mod = @import("module.zig");
const std = @import("std");

// ＝＝ IS_* 类型常量正确性 ＝＝

test "IS_* constants have stable values" {
    try std.testing.expectEqual(@as(u8, 0), php_types.IS_UNDEF);
    try std.testing.expectEqual(@as(u8, 1), php_types.IS_NULL);
    try std.testing.expectEqual(@as(u8, 2), php_types.IS_FALSE);
    try std.testing.expectEqual(@as(u8, 3), php_types.IS_TRUE);
    try std.testing.expectEqual(@as(u8, 4), php_types.IS_LONG);
    try std.testing.expectEqual(@as(u8, 5), php_types.IS_DOUBLE);
    try std.testing.expectEqual(@as(u8, 6), php_types.IS_STRING);
    try std.testing.expectEqual(@as(u8, 7), php_types.IS_ARRAY);
    try std.testing.expectEqual(@as(u8, 8), php_types.IS_OBJECT);
    try std.testing.expectEqual(@as(u8, 9), php_types.IS_RESOURCE);
    try std.testing.expectEqual(@as(u8, 10), php_types.IS_REFERENCE);
    try std.testing.expectEqual(@as(u8, 11), php_types.IS_INDIRECT);
}

// ＝＝ Zval 缓冲区大小 ＝＝

test "Zval buffer is 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(php_types.Zval));
}

test "Zval alignment is 8" {
    try std.testing.expectEqual(@as(usize, 8), @alignOf(php_types.Zval));
}

// ＝＝ ParamDesc 构造 ＝＝

test "ParamDesc.create stores name" {
    const p = mod.ParamDesc.create("argName");
    try std.testing.expectEqualStrings("argName", p.name);
}

// ＝＝ FunctionDesc 构造 ＝＝

test "FunctionDesc.create sets name and handler flags zero" {
    const desc = mod.FunctionDesc.create("testFunc", @ptrCast(@alignCast(&dummyHandler)));
    try std.testing.expectEqualStrings("testFunc", desc.name);
    try std.testing.expectEqual(@as(u32, 0), desc.flags);
    try std.testing.expectEqual(@as(usize, 0), desc.params.len);
    try std.testing.expectEqual(@as(?*anyopaque, null), desc.arg_info);
}

test "FunctionDesc.createWithArgInfo preserves user arg_info" {
    const fake: ?*anyopaque = @ptrFromInt(0xCAFE);
    const desc = mod.FunctionDesc.createWithArgInfo("f", @ptrCast(@alignCast(&dummyHandler)), fake);
    try std.testing.expectEqual(fake, desc.arg_info);
}

test "FunctionDesc.createStatic has static marker" {
    const desc = mod.FunctionDesc.createStatic("staticMethod", @ptrCast(@alignCast(&dummyHandler)));
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), desc.flags);
}

test "FunctionDesc.createWithParams stores params" {
    const params = [_]mod.ParamDesc{ mod.ParamDesc.create("a"), mod.ParamDesc.create("b") };
    const desc = mod.FunctionDesc.createWithParams("add", @ptrCast(@alignCast(&dummyHandler)), &params);
    try std.testing.expectEqual(@as(usize, 2), desc.params.len);
    try std.testing.expectEqualStrings("a", desc.params[0].name);
    try std.testing.expectEqualStrings("b", desc.params[1].name);
}

test "FunctionDesc.createStaticWithParams has marker and params" {
    const params = [_]mod.ParamDesc{mod.ParamDesc.create("x")};
    const desc = mod.FunctionDesc.createStaticWithParams("m", @ptrCast(@alignCast(&dummyHandler)), &params);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), desc.flags);
    try std.testing.expectEqual(@as(usize, 1), desc.params.len);
}

// ＝＝ ClassDesc 构造 ＝＝

test "ClassDesc.create stores name and methods" {
    const methods = [_]mod.FunctionDesc{
        mod.FunctionDesc.createStatic("m1", @ptrCast(@alignCast(&dummyHandler))),
    };
    const cls = mod.ClassDesc.create("MyClass", &methods);
    try std.testing.expectEqualStrings("MyClass", cls.name);
    try std.testing.expectEqual(@as(?[:0]const u8, null), cls.parent_name);
    try std.testing.expectEqual(@as(usize, 1), cls.methods.len);
}

test "ClassDesc.createExtends stores parent" {
    const methods = [_]mod.FunctionDesc{};
    const cls = mod.ClassDesc.createExtends("Child", "Parent", &methods);
    try std.testing.expectEqualStrings("Child", cls.name);
    try std.testing.expectEqualStrings("Parent", cls.parent_name.?);
}

// ＝＝ ConstantDesc 构造（5 种变体） ＝＝

test "ConstantDesc.createLong" {
    const c = mod.ConstantDesc.createLong("MAX", 100);
    try std.testing.expectEqualStrings("MAX", c.name);
    try std.testing.expectEqual(@as(c_long, 100), c.value.long);
}

test "ConstantDesc.createDouble" {
    const c = mod.ConstantDesc.createDouble("PI", 3.14);
    try std.testing.expectEqualStrings("PI", c.name);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), c.value.double, 0.001);
}

test "ConstantDesc.createString" {
    const c = mod.ConstantDesc.createString("AUTHOR", "php-zig");
    try std.testing.expectEqualStrings("php-zig", c.value.string);
}

test "ConstantDesc.createBool" {
    const c = mod.ConstantDesc.createBool("DEBUG", false);
    try std.testing.expectEqual(false, c.value.bool);
}

test "ConstantDesc.createNull" {
    const c = mod.ConstantDesc.createNull("NONE");
    _ = c.value.null_;
}

// ＝＝ Module() comptime 验证 ＝＝

test "Module() with minimal opts compiles" {
    const M = mod.Module(.{ .name = "test", .version = "0.0.0" });
    _ = M;
}

test "ClassDesc.createWithConstants stores constants" {
    const cc = [_]mod.ClassConstantDesc{
        mod.ClassConstantDesc.createLong("PI", 3),
        mod.ClassConstantDesc.createString("NAME", "Calc"),
    };
    const cls = mod.ClassDesc.createWithConstants("C", &.{}, &cc);
    try std.testing.expectEqual(@as(usize, 2), cls.class_constants.len);
    try std.testing.expectEqualStrings("PI", cls.class_constants[0].name);
    try std.testing.expectEqual(@as(c_long, 3), cls.class_constants[0].value.long);
    try std.testing.expectEqualStrings("NAME", cls.class_constants[1].name);
}

test "Module() with all options compiles" {
    const M = mod.Module(.{
        .name = "full",
        .version = "1.0.0",
        .functions = &.{
            mod.FunctionDesc.create("hello", @ptrCast(@alignCast(&dummyHandler))),
            mod.FunctionDesc.createWithParams("add", @ptrCast(@alignCast(&dummyHandler)), &.{
                mod.ParamDesc.create("a"),
                mod.ParamDesc.create("b"),
            }),
        },
        .minit = minitStub,
        .mshutdown = mshutdownStub,
        .rinit = rinitStub,
        .rshutdown = rshutdownStub,
        .constants = &.{
            mod.ConstantDesc.createLong("MAX", 999),
            mod.ConstantDesc.createNull("EMPTY"),
        },
        .classes = &.{
            mod.ClassDesc.create("Calc", &.{
                mod.FunctionDesc.createStatic("mul", @ptrCast(@alignCast(&dummyHandler))),
                mod.FunctionDesc.createStaticWithParams("div", @ptrCast(@alignCast(&dummyHandler)), &.{
                    mod.ParamDesc.create("x"),
                    mod.ParamDesc.create("y"),
                }),
            }),
        },
        .info_func = infoStub,
    });
    _ = M;
}

// ＝＝ comptime 类型反射 ＝＝

test "zigTypeToPhpType: i64 -> long, no allow_null" {
    const ti = mod.zigTypeToPhpType(i64);
    try std.testing.expectEqual(mod.ParamType.long, ti.pt);
    try std.testing.expectEqual(false, ti.an);
}

test "zigTypeToPhpType: f64 -> double" {
    const ti = mod.zigTypeToPhpType(f64);
    try std.testing.expectEqual(mod.ParamType.double, ti.pt);
}

test "zigTypeToPhpType: bool -> bool" {
    const ti = mod.zigTypeToPhpType(bool);
    try std.testing.expectEqual(mod.ParamType.bool, ti.pt);
}

test "zigTypeToPhpType: []const u8 -> string" {
    const ti = mod.zigTypeToPhpType([]const u8);
    try std.testing.expectEqual(mod.ParamType.string, ti.pt);
}

test "zigTypeToPhpType: [:0]const u8 -> string" {
    const ti = mod.zigTypeToPhpType([:0]const u8);
    try std.testing.expectEqual(mod.ParamType.string, ti.pt);
}

test "zigTypeToPhpType: ?i64 -> long, allow_null" {
    const ti = mod.zigTypeToPhpType(?i64);
    try std.testing.expectEqual(mod.ParamType.long, ti.pt);
    try std.testing.expectEqual(true, ti.an);
}

test "zigTypeToPhpType: ?[]const u8 -> string, allow_null" {
    const ti = mod.zigTypeToPhpType(?[]const u8);
    try std.testing.expectEqual(mod.ParamType.string, ti.pt);
    try std.testing.expectEqual(true, ti.an);
}

test "zigTypeToPhpType: *Zval -> mixed" {
    const ti = mod.zigTypeToPhpType(*php_types.Zval);
    try std.testing.expectEqual(mod.ParamType.mixed, ti.pt);
}

test "ParamDesc.createTyped stores type and name" {
    const p = mod.ParamDesc.createTyped("count", .long);
    try std.testing.expectEqualStrings("count", p.name);
    try std.testing.expectEqual(mod.ParamType.long, p.param_type);
    try std.testing.expectEqual(false, p.allow_null);
}

test "FunctionDesc.createFrom with simple struct" {
    const AddArgs = struct { a: i64, b: i64 };
    const desc = mod.FunctionDesc.createFrom("add", @ptrCast(@alignCast(&dummyHandler)), AddArgs);
    try std.testing.expectEqualStrings("add", desc.name);
    try std.testing.expectEqual(@as(usize, 2), desc.params.len);
    try std.testing.expectEqualStrings("a", desc.params[0].name);
    try std.testing.expectEqual(mod.ParamType.long, desc.params[0].param_type);
    try std.testing.expectEqualStrings("b", desc.params[1].name);
    try std.testing.expectEqual(mod.ParamType.long, desc.params[1].param_type);
}

test "FunctionDesc.createFrom with mixed types" {
    const Args = struct { name: []const u8, age: i64, ratio: f64, active: bool };
    const desc = mod.FunctionDesc.createFrom("fn", @ptrCast(@alignCast(&dummyHandler)), Args);
    try std.testing.expectEqual(@as(usize, 4), desc.params.len);
    try std.testing.expectEqual(mod.ParamType.string, desc.params[0].param_type);
    try std.testing.expectEqual(mod.ParamType.long,   desc.params[1].param_type);
    try std.testing.expectEqual(mod.ParamType.double, desc.params[2].param_type);
    try std.testing.expectEqual(mod.ParamType.bool,   desc.params[3].param_type);
}

test "FunctionDesc.createFrom with optional types" {
    const Args = struct { name: []const u8, limit: ?i64 };
    const desc = mod.FunctionDesc.createFrom("fn", @ptrCast(@alignCast(&dummyHandler)), Args);
    try std.testing.expectEqual(@as(usize, 2), desc.params.len);
    try std.testing.expectEqual(false, desc.params[0].allow_null);
    try std.testing.expectEqual(true,  desc.params[1].allow_null);
    try std.testing.expectEqual(mod.ParamType.long, desc.params[1].param_type);
}

test "FunctionDesc.createStaticFrom has marker" {
    const Args = struct { x: i64 };
    const desc = mod.FunctionDesc.createStaticFrom("m", @ptrCast(@alignCast(&dummyHandler)), Args);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), desc.flags);
    try std.testing.expectEqual(@as(usize, 1), desc.params.len);
}

test "Module() with createFrom compiles" {
    const AddArgs = struct { a: i64, b: i64 };
    const M = mod.Module(.{
        .name = "from",
        .version = "0.1.0",
        .functions = &.{
            mod.FunctionDesc.createFrom("add", @ptrCast(@alignCast(&dummyHandler)), AddArgs),
        },
    });
    _ = M;
}

// ＝＝ 类属性 / 构造器 / 继承 / 访问修饰符（声明式） ＝＝

test "ClassPropertyDesc.createLong" {
    const p = mod.ClassPropertyDesc.createLong("count", 42);
    try std.testing.expectEqualStrings("count", p.name);
    try std.testing.expectEqual(@as(c_long, 42), p.value.long);
    try std.testing.expectEqual(@as(u32, 0), p.access);
}

test "ClassPropertyDesc.createString" {
    const p = mod.ClassPropertyDesc.createString("label", "hello");
    try std.testing.expectEqualStrings("label", p.name);
    try std.testing.expectEqualStrings("hello", p.value.string);
}

test "ClassPropertyDesc.createDouble" {
    const p = mod.ClassPropertyDesc.createDouble("pi", 3.14);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), p.value.double, 0.001);
}

test "ClassPropertyDesc.createBool" {
    const p = mod.ClassPropertyDesc.createBool("active", true);
    try std.testing.expectEqual(true, p.value.bool);
}

test "ClassPropertyDesc.createNull" {
    const p = mod.ClassPropertyDesc.createNull("none");
    _ = p.value.null_;
}

test "ClassPropertyDesc.makeStatic sets access=1" {
    const p = mod.ClassPropertyDesc.createLong("x", 1).makeStatic();
    try std.testing.expectEqual(@as(u32, 1), p.access);
}

test "ClassPropertyDesc.makeProtected sets access=2" {
    const p = mod.ClassPropertyDesc.createLong("x", 1).makeProtected();
    try std.testing.expectEqual(@as(u32, 2), p.access);
}

test "ClassPropertyDesc.makePrivate sets access=3" {
    const p = mod.ClassPropertyDesc.createLong("x", 1).makePrivate();
    try std.testing.expectEqual(@as(u32, 3), p.access);
}

test "ClassDesc.createWithProperties stores properties" {
    const props = [_]mod.ClassPropertyDesc{mod.ClassPropertyDesc.createLong("val", 99)};
    const cls = mod.ClassDesc.createWithProperties("MyClass", &.{}, &props);
    try std.testing.expectEqual(@as(usize, 1), cls.properties.len);
    try std.testing.expectEqualStrings("val", cls.properties[0].name);
}

test "FunctionDesc.createProtected has marker" {
    const d = mod.FunctionDesc.createProtected("m", @ptrCast(@alignCast(&dummyHandler)));
    try std.testing.expectEqual(@as(u32, 0xDEADBEF0), d.flags);
}

test "FunctionDesc.createPrivate has marker" {
    const d = mod.FunctionDesc.createPrivate("m", @ptrCast(@alignCast(&dummyHandler)));
    try std.testing.expectEqual(@as(u32, 0xDEADBEF1), d.flags);
}

test "Module() with properties and extends compiles" {
    const M = mod.Module(.{
        .name = "oop",
        .version = "0.5.0",
        .classes = &.{
            mod.ClassDesc.createWithProperties("Bank", &.{
                mod.FunctionDesc.create("__construct", @ptrCast(@alignCast(&dummyHandler))),
                mod.FunctionDesc.createPrivate("secret", @ptrCast(@alignCast(&dummyHandler))),
                mod.FunctionDesc.createProtected("prot", @ptrCast(@alignCast(&dummyHandler))),
            }, &.{
                mod.ClassPropertyDesc.createLong("balance", 0),
                mod.ClassPropertyDesc.createBool("open", true).makeProtected(),
                mod.ClassPropertyDesc.createNull("data"),
            }),
        },
    });
    _ = M;
}

// ＝＝ comptime struct 反射类属性 ＝＝

test "createWithPropsFrom: long props" {
    const Props = struct { balance: i64 = 0, maxval: i64 = 99 };
    const cls = mod.ClassDesc.createWithPropsFrom("Test", &.{}, Props);
    try std.testing.expectEqual(@as(usize, 2), cls.properties.len);
    try std.testing.expectEqualStrings("balance", cls.properties[0].name);
    try std.testing.expectEqual(@as(c_long, 0), cls.properties[0].value.long);
    try std.testing.expectEqualStrings("maxval", cls.properties[1].name);
    try std.testing.expectEqual(@as(c_long, 99), cls.properties[1].value.long);
}

test "createWithPropsFrom: bool props" {
    const Props = struct { active: bool = true, closed: bool = false };
    const cls = mod.ClassDesc.createWithPropsFrom("Test", &.{}, Props);
    try std.testing.expectEqual(@as(usize, 2), cls.properties.len);
    try std.testing.expectEqual(true, cls.properties[0].value.bool);
    try std.testing.expectEqual(false, cls.properties[1].value.bool);
}

test "createWithPropsFrom: mixed types" {
    const Props = struct { count: i64 = 0, rate: f64 = 0.05, label: []const u8 = "hello" };
    const cls = mod.ClassDesc.createWithPropsFrom("Test", &.{}, Props);
    try std.testing.expectEqual(@as(usize, 3), cls.properties.len);
    try std.testing.expectEqual(@as(c_long, 0), cls.properties[0].value.long);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), cls.properties[1].value.double, 0.001);
    try std.testing.expectEqualStrings("hello", cls.properties[2].value.string);
}

test "createWithPropsFrom: no default uses zero" {
    const Props = struct { x: i64 };
    const cls = mod.ClassDesc.createWithPropsFrom("Test", &.{}, Props);
    try std.testing.expectEqual(@as(c_long, 0), cls.properties[0].value.long);
}

test "Module() with createWithPropsFrom compiles" {
    const Props = struct { balance: i64 = 0, open: bool = true };
    const M = mod.Module(.{
        .name = "cpf",
        .version = "0.5.0",
        .classes = &.{
            mod.ClassDesc.createWithPropsFrom("Bank", &.{
                mod.FunctionDesc.create("get", @ptrCast(@alignCast(&dummyHandler))),
            }, Props),
        },
    });
    _ = M;
}

// ＝＝ comptime struct → 方法 + 属性全反射 ＝＝

test "methodsFromStruct: parses public/protect/private/static" {
    const Bank = struct {
        pub fn public_open(_: *php_types.ZendExecuteData, _: *php_types.Zval) callconv(.c) void {}
        pub fn protect_close(_: *php_types.ZendExecuteData, _: *php_types.Zval) callconv(.c) void {}
        pub fn private_secret(_: *php_types.ZendExecuteData, _: *php_types.Zval) callconv(.c) void {}
        pub fn static_util(_: *php_types.ZendExecuteData, _: *php_types.Zval) callconv(.c) void {}
    };
    const methods = comptime mod.methodsFromStruct(Bank);
    try std.testing.expectEqual(@as(usize, 4), methods.len);
    try std.testing.expectEqualStrings("open", methods[0].name);
    try std.testing.expectEqual(@as(u32, 0xDEADBEE0), methods[0].flags); // public
    try std.testing.expectEqualStrings("close", methods[1].name);
    try std.testing.expectEqual(@as(u32, 0xDEADBEF0), methods[1].flags); // protected
    try std.testing.expectEqualStrings("secret", methods[2].name);
    try std.testing.expectEqual(@as(u32, 0xDEADBEF1), methods[2].flags); // private
    try std.testing.expectEqualStrings("util", methods[3].name);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), methods[3].flags); // static
}

test "methodsFromStruct: magic methods" {
    const WithMagic = struct {
        pub fn public_magic_construct(_: *php_types.ZendExecuteData, _: *php_types.Zval) callconv(.c) void {}
        pub fn protect_magic_set(_: *php_types.ZendExecuteData, _: *php_types.Zval) callconv(.c) void {}
    };
    const methods = comptime mod.methodsFromStruct(WithMagic);
    try std.testing.expectEqual(@as(usize, 2), methods.len);
    try std.testing.expectEqualStrings("__construct", methods[0].name);
    try std.testing.expectEqualStrings("__set", methods[1].name);
}

test "ClassDesc.createFromStruct combines methods + props" {
    const Bank = struct {
        balance: i64 = 0,
        open: bool = true,
        pub fn public_getBal(_: *php_types.ZendExecuteData, _: *php_types.Zval) callconv(.c) void {}
        pub fn protect_setBal(_: *php_types.ZendExecuteData, _: *php_types.Zval) callconv(.c) void {}
    };
    const cls = comptime mod.ClassDesc.createFromStruct("Bank", Bank);
    try std.testing.expectEqualStrings("Bank", cls.name);
    try std.testing.expectEqual(@as(usize, 2), cls.methods.len);
    try std.testing.expectEqualStrings("getBal", cls.methods[0].name);
    try std.testing.expectEqualStrings("setBal", cls.methods[1].name);
    try std.testing.expectEqual(@as(usize, 2), cls.properties.len);
    try std.testing.expectEqualStrings("balance", cls.properties[0].name);
    try std.testing.expectEqualStrings("open", cls.properties[1].name);
}

test "Module() with createFromStruct compiles" {
    const Bank = struct {
        value: i64 = 100,
        pub fn public_deposit(_: *php_types.ZendExecuteData, _: *php_types.Zval) callconv(.c) void {}
        pub fn private_log(_: *php_types.ZendExecuteData, _: *php_types.Zval) callconv(.c) void {}
    };
    const M = mod.Module(.{
        .name = "cfs",
        .version = "0.5.1",
        .classes = &.{
            mod.ClassDesc.createFromStruct("Bank", Bank),
        },
    });
    _ = M;
}

// ＝＝ 接口注册与实现 ＝＝

test "ClassDesc.createInterface sets is_interface" {
    const iface = mod.ClassDesc.createInterface("Greetable", &.{});
    try std.testing.expectEqual(true, iface.is_interface);
    try std.testing.expectEqualStrings("Greetable", iface.name);
}

test "ClassDesc.createImplements stores interfaces" {
    const ifaces = [_][:0]const u8{ "Greetable", "Serializable" };
    const cls = mod.ClassDesc.createImplements("Person", &.{}, &ifaces);
    try std.testing.expectEqual(@as(usize, 2), cls.interfaces.len);
    try std.testing.expectEqualStrings("Greetable", cls.interfaces[0]);
    try std.testing.expectEqualStrings("Serializable", cls.interfaces[1]);
    try std.testing.expectEqual(false, cls.is_interface);
}

test "Module() with interface and implements compiles" {
    const M = mod.Module(.{
        .name = "iface",
        .version = "0.7.0",
        .classes = &.{
            mod.ClassDesc.createInterface("Greetable", &.{
                mod.FunctionDesc.create("greet", @ptrCast(@alignCast(&dummyHandler))),
            }),
            mod.ClassDesc.createImplements("Person", &.{
                mod.FunctionDesc.create("greet", @ptrCast(@alignCast(&dummyHandler))),
            }, &.{"Greetable"}),
        },
    });
    _ = M;
}

// ＝＝ 辅助桩函数（仅用于类型编译验证） ＝＝

fn dummyHandler(_: *php_types.ZendExecuteData, _: *php_types.Zval) callconv(.c) void {}
fn minitStub(_: c_int, _: c_int) callconv(.c) c_int { return 0; }
fn mshutdownStub(_: c_int, _: c_int) callconv(.c) c_int { return 0; }
fn rinitStub(_: c_int, _: c_int) callconv(.c) c_int { return 0; }
fn rshutdownStub(_: c_int, _: c_int) callconv(.c) c_int { return 0; }
fn infoStub(_: *mod.ZendModuleEntry) callconv(.c) void {}
