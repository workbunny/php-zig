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

PHP 的 `call_user_function` 宏参数签名为 `zval params[]`（平铺值数组），老版本的 `call_user_function_ex` 则接受 `zval** argv`（指针数组）。

### 解决方案

C glue 内部使用 `call_user_function`，参数声明为 `const zval *argv`。Zig 侧提供 `[]const T.Zval` 切片，与 C 的平铺数组布局一致。

## 类常量先注册后声明

### 问题

PHP 的类常量声明有两种路径：
- `zend_declare_class_constant_ex(ce, zend_string*, zval*, flags, doc_comment)` — 接收 `zend_string*`，需要自建和释放。
- `zend_declare_class_constant(ce, char*, size_t, zval*)` — 接收裸字符串和长度。

初次尝试用 `zend_declare_class_constant_ex` 在 `INIT_CLASS_ENTRY_EX` 之后、`zend_register_internal_class` 之前声明，导致 segfault。因为此时 `ce` 的 `constants_table` 尚未初始化。PHPX 的做法——先注册类、后在返回的 `zend_class_entry*` 上声明常量——是正确的流程。

### 解决方案

```c
zend_class_entry ce;
INIT_CLASS_ENTRY_EX(ce, name, name_len, methods);
zend_class_entry *ce_ptr = zend_register_internal_class(&ce);

// zend_declare_class_constant 需要在 ce_ptr 而非临时 ce 上调用
for (int i = 0; i < const_count; i++) {
    zval zv;
    ZVAL_LONG(&zv, val);  // or ZVAL_STRINGL
    zend_declare_class_constant(ce_ptr, key, key_len, &zv);
    zval_ptr_dtor(&zv);
}
```

两个 `zend_declare_class_constant` 变体的选择：`_ex` 版本需要 `zend_string*` + flags + doc_comment 参数，且不能在 `zend_register_internal_class` 返回之前调用。非 `_ex` 版本的参数更简单，且与 PHPX `Class::addConstant` 的实现流程一致。

## `Array.init()` 接受输出参数而非返回值

### 问题

原始设计是 `Array.init() Array`——函数内部声明 `var zv: T.Zval = undefined` 并调用 `array_init(&zv)`，然后返回 `{ .zv = Zval.fromPtr(&zv) }`。但 `zv` 是栈上局部变量，`Array.init()` 返回后该内存已被释放或复用，`Zval.fromPtr` 持有的指针变为悬空指针。后续调用 `appendLong` 等操作会写入已被覆盖的栈空间，导致 segfault。

filter/map 内部也有同样问题——局部变量 `result_zv` 在函数返回时失效。

### 解决方案

`Array.init()` 改为接受输出参数：调用者提供 `*T.Zval` 指针，框架在指定内存上初始化数组。生命周期由调用者显式管理。

```zig
// 修改前 — 栈指针返回，悬空
pub fn init() Array {
    var zv: T.Zval = undefined;
    c.phpglue_array_init(&zv);
    return .{ .zv = Zval.fromPtr(&zv) }; // 返回后 zv 已失效
}

// 修改后 — 调用者管理内存
pub fn init(zv: *T.Zval) Array {
    c.phpglue_array_init(zv);
    return .{ .zv = Zval.fromPtr(zv) };
}
```

`filterInto` / `mapInto` 同样接受 `out_zv: *T.Zval` 输出参数。这遵循了 Zig 的显式所有权哲学——不隐藏内存分配，调用者清楚每块内存由谁负责。

## `find/findIndex/exists/existsIndex` 使用 `*const Array`

### 问题

查询方法不应修改数组，但原始签名为 `self: *Array`（可变指针）。在 `const doubled = arr.mapInto(...)` 后，`doubled.findIndex(2)` 对 `const` 变量调用失败——Zig 不允许将 `const` 指针传递给 `*Array` 参数。

### 解决方案

```zig
// const-self 用于纯查询方法
pub fn find(self: *const Array, key: []const u8) ?Zval { ... }
pub fn exists(self: *const Array, key: []const u8) bool { ... }
// mutable-self 用于修改方法
pub fn appendLong(self: *Array, v: T.zend_long) void { ... }
pub fn del(self: *Array, key: []const u8) void { ... }
```

## 对象属性读写：`Z_OBJCE_P` 替代 NULL scope

### 问题

PHP 8.4 中 `zend_read_property(NULL, ...)` 和 `zend_update_property(NULL, ...)` 的 scope 参数不再接受 NULL。传入 NULL 时内部路径尝试访问 NULL 指针的成员导致 segfault。

### 解决方案

- **写属性**：`zend_update_property(Z_OBJCE_P(obj), Z_OBJ_P(obj), name, len, val)`——scope 设为对象所属的类。
- **读属性**：改用 `zend_hash_find(obj->properties, zend_string*)` 直接查找 HashTable，绕过 `zend_read_property` 的 scope 校验。因为 `object_init` 创建的 stdClass 的 `properties` 是一个普通 HashTable，不需要复杂的继承链查找。
- **创建对象**：用 `object_init(zv)` 替代 `call_user_function("stdClass", ...)`。前者直接分配 zend_object，后者需要函数表查找和调用栈开销，且在模块加载早期可能尚未注册。

## 类属性声明：`zend_declare_property` 而非 `_ex` 版本

### 问题

类属性声明需要设置默认值。PHP 提供 `zend_declare_property`（接收 `char*/size_t` 对）和 `zend_declare_property_ex`（接收 `zend_string*`）。与类常量类似，属性声明必须在 `zend_register_internal_class` **之后**调用——`ce` 在注册前是临时变量，`properties` 表未初始化。

### 解决方案

统一使用 `zend_declare_property`（非 `_ex` 版本）在已注册的 `ce_ptr` 上声明。5 种默认值类型：

```c
ZVAL_LONG(&zv, val);       // long
ZVAL_DOUBLE(&zv, val);     // double
ZVAL_STRINGL(&zv, s, l);   // string
ZVAL_BOOL(&zv, val);       // bool
ZVAL_NULL(&zv);            // null
zend_declare_property(ce_ptr, name, name_len, &zv, ZEND_ACC_PUBLIC);
```

访问修饰符通过 `access` 参数传递：`ZEND_ACC_PUBLIC | ZEND_ACC_PROTECTED | ZEND_ACC_PRIVATE | ZEND_ACC_STATIC`。

**时序**：先 `zend_register_internal_class` → 再 `zend_declare_class_constant`（类常量） → 再 `zend_declare_property`（类属性）。三者顺序不可颠倒。

## 类继承时父类查找：CG(class_table) 键小写

### 问题

PHP 内部 `CG(class_table)` 中所有类名以**小写**存储为 `zend_string` 键。若用原始类名（如 `"BankAccount"`）查找，哈希不匹配，`zend_hash_str_find_ptr` 返回 NULL。

### 解决方案

```c
// 错误：直接用原始类名查找
zend_hash_str_find_ptr(CG(class_table), "BankAccount", 11); // → NULL

// 正确：先转为小写再查找
char buf[128];
for (size_t i = 0; i < len; i++) buf[i] = tolower(name[i]);
zend_hash_str_find_ptr(CG(class_table), buf, len); // → 找到
```

**注意**：PHP 8.4 的 `zend_lookup_class` 可能在该场景（MINIT 中查找刚刚注册的类）下触发异常或行为异常，直接查 HashTable 更可靠。

## `zend_function_entry` flags 的 ZEND_ACC_PROTECTED/PRIVATE

### 问题

`zend_function_entry.flags` 需设置为 `ZEND_ACC_PUBLIC | ZEND_ACC_PROTECTED` 等组合才能正确反映方法可见性。与 ZEND_ACC_PUBLIC 一样，PROTECTED 和 PRIVATE 的位值也随 PHP 版本变化，不能硬编码。

### 解决方案

C glue 已预提供 `phpglue_acc_protected()` 和 `phpglue_acc_private()`（与 `phpglue_acc_public()` 同模式）。Zig 侧使用哨兵标记（`0xDEADBEF0`/`0xDEADBEF1`），`resolveFlags` 运行时转为真实值。

```c
// C glue（已存在）
uint32_t phpglue_acc_protected(void) { return ZEND_ACC_PROTECTED; }
uint32_t phpglue_acc_private(void)   { return ZEND_ACC_PRIVATE; }
```

## 类属性声明：使用高层 API 避免 zval 生命周期陷阱

### 问题

用 `zend_declare_property(ce_ptr, name, name_len, &zv, access)` 手动构造 zval 再注册属性时，zval 的内存管理极度脆弱：

- `ZVAL_STRINGL(&zv, val, len)` 分配堆上的 zend_string
- `zend_declare_property` 内部 `ZVAL_COPY_OR_DUP` 可能 copy 也可能 dup 引用
- 调用方无法确定需要 dtor 还是保留，无论 `zval_ptr_dtor` 调用与否都会在 PHP shutdown 时导致 segfault（或内存泄漏）

### 解决方案

直接使用 Zend 高层 API，每种类型对应一个函数，内部正确处理生命周期：

```c
zend_declare_property_long(ce_ptr,   name, nlen, val, access);
zend_declare_property_double(ce_ptr, name, nlen, val, access);
zend_declare_property_stringl(ce_ptr, name, nlen, val, vlen, access);
zend_declare_property_bool(ce_ptr,   name, nlen, val, access);
zend_declare_property_null(ce_ptr,   name, nlen, access);
```

这些函数全部为 `void` 返回，内部自管理所有 zval/zend_string 生命周期，shutdown 时 PHP 统一清理。

## 类继承父类查找：CG(class_table) 小写键

### 问题

PHP 内部 `CG(class_table)` 中所有类名以**小写** zend_string 存储。`zend_hash_str_find_ptr` 直接用原始大小写名称查找 → NULL。

### 解决方案

```c
char buf[128];
for (size_t i = 0; i < len; i++) buf[i] = tolower(name[i]);
zend_hash_str_find_ptr(CG(class_table), buf, len);
```

`zend_lookup_class` 在 MINIT 阶段行为不稳定，直接操作 HashTable 更可靠。
