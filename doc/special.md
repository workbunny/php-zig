# 特殊实现说明

本文档记录 php-zig 中非常规的 C glue 和 Zig 实现决策及其原因。

## 为什么用 extern fn ABI 而非 translate-c（最早期的架构决策）

### 问题

项目早期曾尝试用 Zig 的 `translate-c`（`@cImport`）直接把 Zend Engine 的头文件翻译成 Zig 声明，但遇到大量**类型问题**——这是决定整个架构走向的最早踩坑。

### 根因

Zend Engine 是写给 GCC/Clang/MSVC 的 C89 代码，头文件充满依赖 C 编译器「宽容」行为的宏：

| Zend 宏类别 | 特性 | translate-c 的类型问题 |
|------------|------|----------------------|
| 语句级宏 | `ZVAL_STRINGL` 内含 `do-while` 块 | 无法翻译成 Zig 表达式 |
| 提前返回宏 | `RETURN_STRING` 内含 `return` | 破坏 Zig 控制流 |
| 类型双关宏 | `Z_TYPE_P` 解引用 union 成员 | Zig 严格类型拒绝隐式转换 |
| 遍历宏 | `ZEND_HASH_FOREACH_*` 依赖指针运算 | 类型推导失败 |
| 跨位数类型 | `zend_long` 32/64 位不同 | 翻译结果平台相关 |
| 复杂初始化 | `INIT_CLASS_ENTRY_EX` | 布局推导易错 |

Zig 的严格类型系统（无隐式类型转换）无法还原 C 宏的宽松语义——这是**两种语言类型哲学的本质冲突**，而非工具实现问题（Zig 0.10 后 translate-c 改为自研翻译器，矛盾不变）。

### 解决方案：extern fn ABI

在 C 侧完成所有宏展开和类型转换，Zig 侧只面对「普通 C 函数」的 ABI：

```
C 头文件 ──Zig cc──► php_glue.c（宏正常展开为普通函数）
                          ↓
                    Zig 只看到 extern fn ABI（类型边界清晰）
```

- 宏由 C 编译器原生展开，零兼容问题
- Zig 侧类型边界干净，无隐式转换烦恼
- 版本适配在 C glue 内部用运行时查询完成

**代价**：约 300 行手写 C 胶水层是刚性依赖，每加一个能力要同步写 C + Zig 两端。但相比 translate-c 不可控的翻译结果，这是可接受、确定性的成本。

> 本决策为 php-zig 的架构基石，后续所有「Zig 写不了的宏」都遵循此原则在 C glue 侧封装。

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

**时序**（不可颠倒）：先 `zend_register_internal_class` → 再 `zend_declare_class_constant`（类常量） → 再 `zend_declare_property_*`（类属性）。三者都必须在已注册的 `ce_ptr` 上调用，不能作用于 `INIT_CLASS_ENTRY_EX` 的临时 `ce`（此时 `properties`/`constants_table` 未初始化）。

## Zig 0.16 comptime: marker 值冲突

### 问题

`ClassDesc.createFromStruct` 的方法名解析引入了新的可见性 marker `publicz_marker`，初始值与 `static_marker` 同为 `0xDEADBEEF`。
`resolveFlags` 先匹配到 `static_marker` 导致所有 public 方法被误标为 static。

### 解决方案

区分 marker 值：`publicz_marker = 0xDEADBEE0`，`static_marker = 0xDEADBEEF`。
同时在 `resolveFlags` 中显式处理 `publicz_marker` 分支（返回 `phpglue_acc_public()`），与用户自设 `flags=0` 的默认逻辑分开。

## 调试教训：先核对测试样本，再怀疑编译器

### 问题

实现 `createFromStruct` 的魔术方法映射时，一度怀疑 Zig 0.16 存在两个编译器 bug：
「comptime 切片 `name[prefix.len..]` 返回错误值」「函数传回 `[:0]const u8` 字面量失效」。
据此做了 `name[prefix.len..name.len]` 显式切片、以及 17 条映射全内联等「绕过」处理。

### 真相

真正的根因是测试样本写错了：example 里写的是 `public_construct`（少了 `magic_` 前缀），
导致 `rest` 等于 `"construct"`，既不匹配任何 magic 映射、也根本不会进入映射函数——
方法名自然变成 `"construct"` 而非 `"__construct"`。

改回正确的 `public_magic_construct` 后，一切正常。切片 `name[prefix.len..]` 与函数传值均无问题。

### 教训

comptime 逻辑「看似不生效」时，优先排查输入样本是否正确（前缀、拼写、大小写），
不要急于断言编译器/语言层有 bug。真正影响行为的只有 marker 值冲突这一处。

## 数组 merge：zend_hash_merge 丢失数字键元素

### 问题

初次用 `zend_hash_merge` 实现 `array_merge`：

```c
zend_hash_merge(Z_ARRVAL_P(dst), Z_ARRVAL_P(src1), zval_add_ref, 0);
zend_hash_merge(Z_ARRVAL_P(dst), Z_ARRVAL_P(src2), zval_add_ref, 0);
```

第二个数组 `[3,4]` 的数字键 `0`/`1` 与第一个数组 `[1,2]` 已存在的键冲突，`overwrite=0` 时 `zend_hash_merge` 直接**跳过**冲突键——结果 `[1,2]` 而不是预期的 `[1,2,3,4]`。

### 解决方案

手动遍历两个源数组，模拟 PHP `array_merge` 语义：数字键 → 追加（重新索引），字符串键 → 覆盖/新增。

```c
ZEND_HASH_FOREACH_KEY_VAL(Z_ARRVAL_P(src1), num_key, str_key, data) {
    if (str_key) add_assoc_zval(dst, ZSTR_VAL(str_key), data);
    else         add_next_index_zval(dst, data);
} ZEND_HASH_FOREACH_END();
// 对 src2 重复同样流程
```

`zend_hash_merge` 只适合「键不冲突」的合并场景，不适用 `array_merge` 的「数字键重索引」语义。

## each 语法糖：comptime 回调无法捕获运行时状态

### 问题

`Array.each` 最初设计为 comptime 回调：

```zig
pub fn each(self: *Array, comptime cb: fn (Zval) void) void { ... }
```

但 comptime 函数指针**不能引用运行时变量**——想遍历累加 `sum` 时，`cb` 无法捕获 `&sum`。comptime 回调只能做无状态的纯处理。

### 解决方案

改为 runtime 回调 + context 指针，允许回调内部 `@ptrCast` 恢复成自己的状态类型：

```zig
pub fn each(self: *Array, ctx: ?*anyopaque, cb: fn (?*anyopaque, Zval) void) void { ... }

// 调用方
const SumCtx = struct { sum: c_long = 0 };
var ctx = SumCtx{};
arr.each(&ctx, struct {
    fn cb(ud: ?*anyopaque, v: Zval) void {
        const s: *SumCtx = @ptrCast(@alignCast(ud.?));
        s.sum += v.toLong();
    }
}.cb);
```

`?*anyopaque` 作为不透明上下文，把「状态捕获」从编译期下放到运行时，是 Zig 中遍历回调的惯用模式（类似 C 的 `qsort` ctx）。

## 闭包创建：zend_create_closure 的 function_name 引用计数

### 问题

从 Zig 函数创建 PHP Closure 时，需要构造 `zend_internal_function` 并传入 `zend_create_closure`。若对 `function_name` 的引用计数处理错误，会导致 shutdown 时 segfault 或内存泄漏。

### 解决方案

关键事实：`zend_create_closure` 内部会对 `function_name` 调用 `zend_string_addref`（闭包持有一份引用，析构时 `zend_string_release`）。因此 C glue 在创建闭包后必须释放自己持有的那一份：

```c
void phpglue_create_closure(zval *res, zif_handler handler, const char *name, size_t name_len) {
    zend_internal_function func;
    memset(&func, 0, sizeof(func));
    func.type = ZEND_INTERNAL_FUNCTION;
    func.function_name = zend_string_init(name, name_len, 0);  // 我们持有 1 份
    func.fn_flags = 0;
    func.handler = handler;
    func.num_args = 0;
    func.required_num_args = 0;
    func.arg_info = NULL;

    // zend_create_closure 内部 addref，闭包析构时 release
    zend_create_closure(res, (zend_function *)&func, NULL, NULL, NULL);
    zend_string_release(func.function_name);  // 释放我们这份
}
```

其他字段（`fn_flags`、`arg_info`）设零即可——闭包无需参数元信息或特殊标志。

## 接口方法需 abstract 标志

### 问题

用 `zend_register_internal_interface` 注册接口时，接口内的方法必须带 `ZEND_ACC_ABSTRACT` 标志。若沿用普通类方法的 `ZEND_ACC_PUBLIC`，接口注册会失败或产生非法的接口定义（接口方法本身就是抽象声明）。

### 解决方案

在生成类方法条目时，对接口类自动补上 abstract 标志：

```zig
// Zig 侧（module.zig 的 initClassMethodEntries）
const flags = if (cls.is_interface)
    resolveFlags(method) | c.phpglue_acc_abstract()
else
    resolveFlags(method);
```

`phpglue_acc_abstract()` 与 `phpglue_acc_public()` 同模式，运行时从编译时 PHP 头文件查询 `ZEND_ACC_ABSTRACT`，避免硬编码位值。

## callconv(.c) 回调禁用 Zig 切片参数

### 问题

`Module` 的 `ini_notify` 回调若声明为 `fn (name: []const u8) callconv(.c) void`，编译报错：`parameter of type '[]const u8' not allowed in function with calling convention`。

### 根因

`callconv(.c)` 强制 C ABI，而 Zig 切片（slice）没有固定的内存表示（指针 + 长度两个字段），不能作为 C 函数参数。

### 解决方案

跨 C 边界的回调统一用 C 风格签名，切片转换由 wrapper 完成：

```zig
// opts 里的回调类型（C ABI）
ini_notify: ?*const fn (name: [*c]const u8, name_len: usize) callconv(.c) void = null,

// C glue 收到的回调签名（一致）
void phpglue_set_ini_notify(void (*cb)(const char *name, size_t name_len));
```

## INI 注册：2 参数 + NULL 哨兵 + zend_atol 废弃

### 问题

实现 INI 注册时踩了三个 PHP 8.4 API 细节坑：

1. `zend_register_ini_entries` 签名仅 **2 参数**（`ini_entry` 数组 + `module_number`），**不接受 count**——`zend_ini_entry_def` 数组以 `name=NULL` 哨兵结尾。3 参数版本是 `zend_register_ini_entries_ex`（多了 `module_type`）。
2. `zend_atol` 在 PHP 8.4 被标记 `ZEND_ATTRIBUTE_DEPRECATED`，编译报 deprecation 错误。

### 解决方案

```c
zend_ini_entry_def defs[65];           // +1 哨兵
for (i < count) { /* 填充 defs[i] */ }
memset(&defs[count], 0, sizeof(zend_ini_entry_def));  // name=NULL 哨兵
return zend_register_ini_entries(defs, module_number) == SUCCESS ? 1 : 0;

// 字符串转数值改用 ZEND_STRTOL
return ZEND_STRTOL(v, NULL, 10);       // 替代废弃的 zend_atol(v, len)
```

## extern struct 对象绑定：create_object/free_obj + 归属判断

### 问题

要让 Zig struct 生命周期绑定到 PHP 对象，需要自定义 `zend_object` 的分配与释放，但必须避免与原生对象（stdClass 等）冲突。

### 解决方案

自定义 `create_object` 分配 `zend_object + extra` 连续内存，`free_obj` 时通过 `handlers.offset`（`XtOffsetOf`）反推结构体指针并调用 dtor：

```c
typedef struct { zend_object std; void *extra; } phpglue_object;

static zend_object *phpglue_object_create(zend_class_entry *ce) {
    phpglue_object *obj = emalloc(sizeof(phpglue_object) + extra_size);
    zend_object_std_init(&obj->std, ce);
    object_properties_init(&obj->std, ce);
    obj->std.handlers = &phpglue_object_handlers;   // 指向自定义 handlers
    obj->extra = (extra_size > 0) ? (void *)(obj + 1) : NULL;
    if (init) init(obj->extra);
    return &obj->std;
}

static void phpglue_object_free(zend_object *object) {
    phpglue_object *obj = (phpglue_object *)((char *)object - XtOffsetOf(phpglue_object, std));
    if (dtor && obj->extra) dtor(obj->extra);
    zend_object_std_dtor(object);
}
```

**归属判断**：`phpglue_object_get_extra` 通过「`zobj->handlers` 是否等于自定义 handlers」判断对象是否由本框架创建——stdClass 等原生对象 handler 不同，返回 NULL 安全兜底。

## getThis() 宏依赖局部变量名 execute_data

### 问题

`getThis()` 宏展开为 `(hasThis() ? ZEND_THIS : NULL)`，而 `ZEND_THIS` = `(&EX(This))`，`EX(element)` = `((execute_data)->element)`——**依赖 C 函数局部变量名 `execute_data`**。

### 解决方案

C glue 封装函数的参数名必须正好是 `execute_data`，否则宏展开引用未定义标识符：

```c
zval *phpglue_get_this(zend_execute_data *execute_data) {
    return getThis();   // 依赖参数名 execute_data
}
```

## 可变参数：variadic 位 + required_num_args 统计

### 问题

1. 可变参数的 `is_variadic` 位需写入 `zend_type` 的 extra_flags，用 `ZEND_TYPE_INIT_CODE(code, allow_null, _ZEND_ARG_INFO_FLAGS(0, 1, 0))` 传入。
2. arg_info 头部的 `required_num_args` 应为**非 variadic 参数个数**——variadic 可传 0 个，不能算必填。

### 解决方案

```c
// C 侧：extra_flags 携带 variadic 位
const uint32_t extra_flags = (uint32_t)_ZEND_ARG_INFO_FLAGS(0, variadic_flag, 0);
entry->type = (zend_type)ZEND_TYPE_INIT_CODE(IS_LONG, allow_null_flag, extra_flags);
// mixed（无类型）+ variadic 时：
entry->type = (zend_type)ZEND_TYPE_INIT_NONE(extra_flags);
```

```zig
// Zig 侧：required 单独统计非 variadic
var required: usize = 0;
for (desc.params) |p| { if (!p.is_variadic) required += 1; }
```

## 参数默认值：default_value 是源码字符串

### 问题

`zend_internal_arg_info.default_value` 存的是**源码文本**（而非解析后的值），Reflection 据此 `getDefaultValue()` 解析。

### 解决方案

字符串默认值需带引号转义：

```zig
// "Hello" 默认值 → 源码文本 "\"Hello\""
ParamDesc.createTypedWithDefault("greeting", .string, "\"Hello\""),
```

数值/布尔/null 直接写源码字面量（`"0"`、`"1"`、`"NULL"`、`"[]"`）。

## 无参模块触发 param_entries_buf 空数组编译错误

### 问题

当模块**没有任何带参函数**时（如最小示例只有一个无参的 `hello_world`），编译报错：

```
src/module.zig:678:48: error: cannot index into empty array
    @ptrCast(&param_entries_buf[byte_off]),
```

### 根因

`param_entries_buf: [total_param_bytes]u8` 的尺寸由 comptime 统计「带参函数的参数条目总数」得出。当所有函数都无参时 `total_param_entries = 0`，数组退化为 `[0]u8`。即使 `resolveArgInfo` 对无参函数会提前返回 `get_empty_arg_info()`、运行时不会执行到索引语句，但 **Zig 对空数组的索引/取地址是编译期语义错误**，与运行时是否执行无关。

### 解决方案

数组尺寸至少保留 1 字节，避免空数组：

```zig
// 至少保留 1 字节：模块无带参函数时 total_param_entries 为 0，
// 否则 param_entries_buf 退化为 [0]u8 空数组，无法索引/取地址。
const total_param_bytes = @max(1, total_param_entries) * ARGINFO_ENTRY_SIZE_MAX;
```

这 1 字节在「无带参函数」场景下永远不会被真正访问，仅用于满足编译期语义。
