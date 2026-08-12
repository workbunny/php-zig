# 特殊实现说明

本文档记录 php-zig 中非常规的 C glue 和 Zig 实现决策及其原因。

## arg_info 的 C 端模板策略

### 问题

PHP 的 `zend_internal_arg_info` 结构体内部包含 `zend_type` union，该 union 在 PHP 不同版本间布局不同：

- PHP 8.1-8.3：`zend_type` 是一个带 tag 的 union，内部有指针和整数字段。
- PHP 8.4+：`zend_type` 重构为更紧凑的结构，所有 flags（`pass_by_reference`、`is_variadic` 等）编码在其内部。

我们的 Zig 侧无法直接定义 `zend_type` 的 extern struct（跨版本不一致），也不能用 `memset` 清零替代——`zend_type` 不能等价于全零值。

### 解决方案：PHP 宏模板 + memcpy

```c
// 用 PHP 官方宏生成两个静态模板，布局 100% 由 PHP 编译器保证：
ZEND_BEGIN_ARG_INFO_EX(__phpglue_arg_header_template, 0, 0, 0)
ZEND_END_ARG_INFO()

static const zend_internal_arg_info __phpglue_arg_param_template[] = {
    ZEND_ARG_INFO(0, _placeholder)
};

void phpglue_fill_arg_info(void *dst, uint32_t required_count, const char **names,
                           size_t name_count, size_t *out_entry_count) {
    zend_internal_arg_info *entries = (zend_internal_arg_info *)dst;

    // 头条目：memcpy PHP 宏生成的模板，仅覆盖 name 字段
    memcpy(&entries[0], &__phpglue_arg_header_template[0], sizeof(zend_internal_arg_info));
    entries[0].name = (const char *)(uintptr_t)(required_count);

    // 参数条目：memcpy 模板，覆盖 name
    for (size_t i = 0; i < name_count; i++) {
        memcpy(&entries[i + 1], &__phpglue_arg_param_template[0], sizeof(zend_internal_arg_info));
        entries[i + 1].name = names[i];
    }

    // 末尾哨兵：PHP 在 zend_API.c:3015 读 arg_info[num_args] 判断 is_variadic
    memcpy(&entries[name_count + 1], &__phpglue_arg_param_template[0], sizeof(zend_internal_arg_info));
    entries[name_count + 1].name = NULL;

    *out_entry_count = name_count;
}
```

`memcpy` 而非 `memset` 的原因是：`zend_type` union 的初始化状态不是 `{0}`。只有 PHP 编译器用 `ZEND_BEGIN_ARG_INFO_EX` 宏生成的静态数组才是正确的"未设置任何类型提示"的 state。

## Zig 侧 `[N]u8 align(8)` + `[*]align(8)` 桥接

### 问题

arg_info 缓冲区 `param_entries_buf` 需要 8 字节对齐才能被 Zend Engine 安全读取（`zend_type` 内部包含 `void*` 字段）。但索引 `[N]u8` 后得到的是 `*u8`（align=1），无法直接传 `@alignCast`。

### 解决方案

```zig
// 声明时强制对齐
var param_entries_buf: [total_param_bytes]u8 align(8) = undefined;

// 取地址时桥接：[*]align(8) u8 保留对齐信息
const base: [*]align(8) u8 = @as([*]align(8) u8, @ptrCast(&param_entries_buf));
const ptr: ?*anyopaque = @ptrCast(base + byte_offset);
```

## num_args 与末尾哨兵

### 问题

`ZendFunctionEntry.num_args` 必须设置为**参数个数（不含 header 条目）**。当 `num_args > 0` 时，Zend Engine 在 `zend_API.c:3015` 读取 `arg_info[num_args]` 检查 `is_variadic`——这意味着我们必须分配至少 `num_args + 1` 个条目。

### 解决方案

每函数分配 `header + N params + 1 sentinel = N + 2` 个 `zend_internal_arg_info` 条目。`num_args = N`（不含 header 和 sentinel）。

## RETVAL_* 而非 RETURN_*

### 问题

PHP 标准宏 `RETURN_STRING()` 内含 `return` 语句：

```c
#define RETURN_STRING(s) { RETVAL_STRING(s); return; }
```

如果 Zig 侧 `callconv(.c) void` 函数内部调用 C 宏包含的 `return`，会跳过 Zig 的 `defer` 块和栈帧清理，导致资源泄漏。

### 解决方案

C glue 统一使用 `RETVAL_*`（仅设值不 return），由 Zig 函数末尾自然返回。

```c
// 正确
void phpglue_return_string(zval *return_value, const char *s) {
    RETVAL_STRING(s);
}

// 错误 — 不应该出现在 C glue 中
void phpglue_return_string_bad(zval *return_value, const char *s) {
    RETURN_STRING(s);
}
```

## 容器级 var 的懒初始化

### 问题

`Module()` comptime 泛型返回的 struct 中包含容器级变量（如 `module_entry`）。Zig 要求容器级 `var` 的初始化器在 comptime 求值，但我们需运行时调用 C glue（`phpglue_module_api_no` 等 extern fn）。

### 解决方案

初始化为 `undefined`，用 `module_entry.size` 字段做初始化哨兵：

```zig
var module_entry: ZendModuleEntry = undefined;

pub fn get_module() callconv(.c) *ZendModuleEntry {
    // 惰性初始化：首调用时 size 值来自 undefined（≠真实值）
    if (module_entry.size != @sizeOf(ZendModuleEntry)) {
        initModule();
    }
    return &module_entry;
}
```

PHP 加载 `.so` 后模块注册是单线程的，不需要加锁。`initModule()` 只执行一次。

## 可见性标志位运行时推断

### 问题

`ZEND_ACC_PUBLIC` 在 PHP 7.x 中为 `0x100`，在 PHP 8.4 中为 `0x01`。不能硬编码。

### 解决方案

```c
// C glue 提供运行时查询
uint32_t phpglue_acc_public(void) { return ZEND_ACC_PUBLIC; }
```

```zig
// Zig 侧 FunctionDesc 不设置 flags 默认值，用哨兵标记静态方法
pub fn create(name, handler) FunctionDesc { return .{ .name = name, .handler = handler }; }
// flags 默认为 0，init 时调用 phpglue_acc_public()

pub fn createStatic(name, handler) FunctionDesc {
    return .{ .name = name, .handler = handler, .flags = Marker.static_marker };
}
// flags = 0xDEADBEEF，init 时调用 phpglue_acc_public() | phpglue_acc_static()
```

## call_user_function 平铺数组

### 问题

PHP 8.4 的 `call_user_function` 宏参数签名为 `zval params[]`（平铺值数组），老版本的 `call_user_function_ex` 则接受 `zval** argv`（指针数组）。

### 解决方案

C glue 内部使用 `call_user_function`（PHP 8.2+ 可用），参数声明为 `const zval *argv`。Zig 侧提供 `[]const T.Zval` 切片，与 C 的平铺数组布局一致。
