//! 最小测试：单个函数 + 参数 arg_info
const phpzig = @import("phpzig");
const T = phpzig.php_types;

fn add(ed: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    if (phpzig.Return.callNumArgs(ed) < 2) { phpzig.Return.returnNull(rv); return; }
    const a = phpzig.Return.callArg(ed, 1);
    const b = phpzig.Return.callArg(ed, 2);
    phpzig.Return.returnLong(rv, (if (a.isLong()) a.toLong() else @as(c_long, 0)) + (if (b.isLong()) b.toLong() else @as(c_long, 0)));
}

const M = phpzig.Module(.{
    .name = "tn",
    .version = "1.0",
    .functions = &.{
        // 仅此函数有 params，触发 num_args > 0 路径
        phpzig.FunctionDesc.createWithParams("add", add, &.{
            phpzig.ParamDesc.create("a"),
            phpzig.ParamDesc.create("b"),
        }),
    },
});

comptime { @export(&M.get_module, .{ .name = "get_module" }); }
