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
    _ = c.value.null_; // void variant, just ensure construction succeeds
}

// ＝＝ Module() comptime：空配置合法 ＝＝

test "Module() with minimal opts compiles" {
    const M = mod.Module(.{ .name = "test", .version = "0.0.0" });
    _ = M;
    // 编译器确认该泛型实例化无误
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

// ＝＝ 辅助桩函数（仅用于类型编译验证） ＝＝

fn dummyHandler(_: *php_types.ZendExecuteData, _: *php_types.Zval) callconv(.c) void {}
fn minitStub(_: c_int, _: c_int) callconv(.c) c_int { return 0; }
fn mshutdownStub(_: c_int, _: c_int) callconv(.c) c_int { return 0; }
fn rinitStub(_: c_int, _: c_int) callconv(.c) c_int { return 0; }
fn rshutdownStub(_: c_int, _: c_int) callconv(.c) c_int { return 0; }
fn infoStub(_: *mod.ZendModuleEntry) callconv(.c) void {}
