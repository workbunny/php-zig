# php-zig API 参考

> 面向下游开发者的完整公开 API 索引。所有模块从 `src/main.zig` 统一 re-export，
> 使用方式：`const php = @import("php-zig");`。

---

## 快速上手

```zig
const php = @import("php-zig");

/// 导出的 PHP 函数：phpzig_add(1, 2) == 3
fn my_add(execute_data: ?*php.T.ZendExecuteData, return_value: *php.T.Zval) callconv(.c) void {
    const a = php.callArg(execute_data, 0).toLong();
    const b = php.callArg(execute_data, 1).toLong();
    php.returnLong(return_value, a + b);
}

pub export fn get_module() *php.T.ZendModuleEntry {
    return php.moduleInit(.{
        .name = "myext",
        .version = "1.0.0",
        .functions = &.{ php.FunctionDesc.create("phpzig_add", my_add) },
    });
}
```

---

## 模块注册（module.zig）

### 编译期约束（语义错误在 `zig build` 阶段即报错）

以下由 `validateOptions()` 在 **comptime** 拦截，写错时编译直接失败：

| 约束 | 规则 |
|---|---|
| 模块名 / 版本号 | 非空 |
| 函数、类、类常量、类属性、INI、参数名 | 非空 |
| 参数名 | 不可重复 |
| variadic 参数 | 必须是最后一个 |

错误信息示例：

```
error: function 'f' has duplicate param name 'a'
error: function 'f': variadic param 'rest' must be the last param
error: module name must not be empty
```

### 数量不受限（与 Zend 一致）

**参数个数、类属性个数、类常量个数、INI 项个数、类个数均不设上限**——Zend/PHP 对这些数量本身没有限制，故本框架同样不限制，只按你实际声明的数量精确分配。

缓冲按**各自**维度精确分配（非模块级最大值）：函数的参数缓冲按该函数自身的参数个数，类的常量/属性缓冲按该类自身的个数。你无需统计总数。

> 本项目曾错误地自设 8 / 8 / 64 上限（属实现细节而非 Zend 约束），现已移除。
> 若你在旧文档中见过这些数字，以本节为准。

以下约束**无法**在编译期判定（依赖 C 运行时查询），仍为运行时 panic：zval 大小、arg_info 实际布局。见 `initModule()` 中的校验。

### 入口函数

| 签名 | 说明 |
|---|---|
| `pub fn Module(comptime opts: ModuleOptions) type` | 低层：生成模块类型（含函数表/类方法表/arg_info 缓冲） |
| `pub fn moduleInit(meta: ModuleMeta) *T.ZendModuleEntry` | 高层：自动发现 + 显式补充，注册并返回 `get_module` 指针 |
| `pub fn getThis(execute_data: *T.ZendExecuteData) ?Zval` | 类方法内取当前对象（非对象方法返回 null） |

### ModuleOptions / ModuleMeta 字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `name` | `[:0]const u8` | 模块名（必填） |
| `version` | `[:0]const u8` | 版本号（必填） |
| `functions` | `[]const FunctionDesc` | 显式注册的函数 |
| `classes` | `[]const ClassDesc` | 显式注册的类 |
| `constants` | `[]const ConstantDesc` | 全局常量 |
| `ini` | `[]const IniEntry` | INI 项（MINIT 自动注册） |
| `ini_notify` | `?*const fn` | INI 变更通知回调 |
| `minit` / `mshutdown` / `rinit` / `rshutdown` | `?T.ModuleLifecycleFn` | 模块/请求生命周期钩子 |
| `info_func` | `?*const fn` | `phpinfo()` 输出回调 |
| `observer` | `?ObserverConfig` | Observer 观察点配置（MINIT 静态注册） |

### FunctionDesc

```zig
pub const FunctionDesc = struct {
    name: [:0]const u8,
    handler: T.FunctionHandler,
    arg_info: ?*anyopaque = null,
    flags: u32 = 0,
    params: []const ParamDesc = &.{},
};
```

| 工厂方法 | 说明 |
|---|---|
| `create(name, handler)` | 无参函数 |
| `createWithArgInfo(name, handler, arg_info)` | 显式 arg_info |
| `createStatic(name, handler)` | 静态方法 |
| `createWithParams(name, handler, params)` | 带参数描述 |
| `createStaticWithParams(...)` | 静态 + 参数 |
| `createFrom(name, handler, Args)` | **comptime 反射**：struct 字段 → 参数（类型/可空自动推导）。Zig 表达不了的（联合类型）用 `createFromWith` |
| `createFromWith(name, handler, Args, ArgTypes)` | 反射 + 显式补齐（联合类型 / callable 等） |
| `createStaticFrom(...)` | 反射 + 静态 |
| `createProtected(name, handler)` / `createProtectedWithParams(...)` | protected 方法 |
| `createPrivate(name, handler)` / `createPrivateWithParams(...)` | private 方法 |

```zig
// createFrom 示例：字段顺序 = 参数顺序，字段名 = 参数名
const AddArgs = struct { a: i64, b: i64, name: []const u8 };
FunctionDesc.createFrom("my_add", my_add, AddArgs);

// createFromWith 示例：联合类型（i64 无法表达 int|string）
const KeyArgs = struct { key: *T.Zval };        // mixed 字段
FunctionDesc.createFromWith("f", f, KeyArgs, .{
    .key = phpzig.PhpType.long.unionWith(phpzig.PhpType.string),
});
```

> **编译期校验**（`createFromWith`）：ArgTypes 的字段必须存在于 Args 中，且只能
> 覆盖 mixed（`*T.Zval`）字段——反射已推出类型的字段被覆盖会编译错误。
> 名字冲突用 `unionWith` 组合，方法名不是 `or`（Zig 保留字）。

#### 自动发现命名约定（`moduleInit(@This(), ...)`）

`moduleInit` 接收 `@This()` 时自动发现 `pub fn php_*` 函数并注册为 PHP 同名函数
（去 `php_` 前缀）。有参函数须配套声明，三种写法：

```zig
pub const hello_echoArgs = struct { name: []const u8, times: i64 }; // ① 反射
pub const hello_keyArgTypes = .{ .key = phpzig.PhpType.long.unionWith(...) }; // ② 联合类型补齐
pub const hello_worldUntyped = true;  // ③ 故意不加约束（无参函数用）
```

规则：
- `pub fn php_hello_echo` 找 `hello_echoArgs`（反射类型）；有 `hello_echoArgTypes`
  则叠加联合类型
- **缺 Args 且无 Untyped → 编译错误**（不是静默退化）。历史上 `FormatArgs` 命名
  不匹配导致约束静默失效，null 直达 handler 触发野指针崩溃——故强制显式声明。

### ParamDesc / ParamType

```zig
pub const ParamDesc = struct {
    name: [:0]const u8,
    param_type: ParamType = .mixed,
    allow_null: bool = false,
    /// MAY_BE_* 位掩码（联合类型）。非零时优先于 param_type——
    /// 单类型用 param_type，`int|string` 用 type_mask（经 PhpType）
    type_mask: u32 = 0,
    is_variadic: bool = false,
    default_value: ?[:0]const u8 = null, // PHP 源码字符串，如 "0"、"[]"、"NULL"
};
```

| 工厂方法 | 说明 |
|---|---|
| `create(name)` | 无类型标注 |
| `createTyped(name, pt)` | 类型标注 |
| `createNullable(name, pt)` | 类型 + nullable |
| `createVariadic(name)` | `...$args` |
| `createVariadicTyped(name, pt)` | 带类型可变参数 |
| `createWithDefault(name, dv)` | 带默认值 |
| `createTypedWithDefault(name, pt, dv)` | 类型 + 默认值 |

`ParamType` 枚举：`mixed / long / double / string / array / object / bool / callable / iterable`。

#### PhpType（联合类型位掩码）

单类型不够时（`int|string`、`?int`、`callable`）用 `PhpType`：

```zig
phpzig.PhpType.long                          // int
phpzig.PhpType.string.unionWith(PhpType.long)   // int|string（方法名非 or，Zig 保留字）
phpzig.PhpType.string.nullable()             // ?string（= string|null，PHP 中二者等价）
phpzig.PhpType.callable                      // callable（伪类型，不参与 unionWith）
phpzig.PhpType.iterable                      // iterable
```

位值对应 Zend `MAY_BE_*`，由 glue 顶部 `_Static_assert` 守护（PHP 改布局即编译失败）。
`nullable()` 与 `unionWith(null_)` 等价——PHP 中 `MAY_BE_NULL` 与 nullable 位同值。

### ClassDesc

| 工厂方法 | 说明 |
|---|---|
| `create(name, methods)` | 普通类 |
| `createObject(name, methods, Data, init, dtor)` | 带 Zig struct 数据区的对象类（extern struct 绑定） |
| `createExtends(name, parent, methods)` | 继承 |
| `createInterface(name, methods)` | 接口 |
| `createImplements(name, methods, interfaces)` | 实现接口 |
| `createWithConstants(name, methods, constants)` | 类常量 |
| `createWithProperties(name, methods, props)` | 类属性 |
| `createWithPropsFrom(name, methods, Props)` | comptime 反射属性 |
| `createFromStruct(name, Cls)` | **完全 comptime**：struct 的 `pub fn` → 方法、字段 → 属性 |

**`createFromStruct` 命名约定**：
```
public_xxx  → public function xxx
protect_xxx → protected function xxx
private_xxx → private function xxx
static_xxx  → public static function xxx
public_magic_tostring → __toString（魔术方法）
```

### 常量 / 属性描述符

- `ConstantDesc`：`createLong / createDouble / createString / createBool / createNull`
- `ClassConstantDesc`：`createLong / createString`
- `ClassPropertyDesc`：`createLong / createDouble / createString / createBool / createNull`，
  可见性 `makeStatic / makeProtected / makePrivate`

---

## Zval 类型安全包装（zval.zig）

`Zval` 是 PHP `zval` 的类型安全视图，`*T.Zval` 的薄封装。

### 构造

| 方法 | 说明 |
|---|---|
| `fromPtr(ptr)` / `fromPtrPtr(ptr)` | 从指针构造 |
| `toArray()` → `?Array` | 转数组包装 |
| `toObject()` → `?Object` | 转对象包装 |

### 类型判断

`getType()` / `isNull()` / `isBool()` / `isLong()` / `isDouble()` / `isString()` /
`isArray()` / `isObject()` / `isResource()` / `isCallable()` / `isIterable()` /
`isScalar()` / `isEmpty()` / `isNumeric()`

### 取值（弱转换，PHP 语义）

> **语义修正**：这些是官方弱转换（`zval_get_long` 等），不是强转直读。
> 背景：内部函数 arginfo 类型校验只在 ZEND_DEBUG 构建生效（见 special.md），
> Release 下 handler 收到原始未转换 zval。直读 `Z_LVAL_P` 会把 string/array
> 的指针当 long 解读（返回看似合理的垃圾值）；弱转换按 PHP 语义转换，
> **永不返回垃圾指针**。判断原始类型用 `isLong()` 等。

| 方法 | 返回 | 语义 |
|---|---|---|
| `toLong()` | `T.zend_long` | `zval_get_long`：`"1"`→1、`null`→0、`[]`→0、`1.9`→1 |
| `toDouble()` | `f64` | `zval_get_double` |
| `toBool()` | `bool` | `zval_is_true` |
| `toStringVal()` | `[]const u8` | 非字符串返回**空串**（底层防野指针） |
| `asString()` | `?[]const u8` | 非字符串返回 null（区分「空串」与「类型不符」） |

### 赋值

`setLong()` / `setDouble()` / `setString()` / `setBool()` / `setNull()`

### 引用计数

| 方法 | 说明 |
|---|---|
| `incRef()` | 引用计数 +1（`Z_ADDREF_P`），非引用类型 no-op |
| `decRef()` | 引用计数 -1（`Z_DELREF_P`） |
| `copy(dst)` | `ZVAL_COPY` 副本 |
| `separate()` | **写时分离**（`SEPARATE_ZVAL`）：引用计数 > 1 或引用类型时复制独立副本 |

### 比较与运算

- 比较：`eql / neq / cmp / lt / le / gt / ge`
- 算术：`add / sub / mul / div / mod_`（结果写入 `result: *T.Zval`，返回是否成功）

---

## Array 数组操作（array.zig）

### 构造与访问

| 方法 | 说明 |
|---|---|
| `init(zv)` / `fromZval(zv)` | 构造 |
| `count()` | 元素数 |
| `find(key)` / `findIndex(idx)` | 按键/索引取值 |
| `exists(key)` / `existsIndex(idx)` | 判断存在 |
| `del(key)` / `delIndex(idx)` | 删除 |
| `separate()` | 写时分离（`SEPARATE_ARRAY`） |

### 追加（append，数字索引）

`appendLong / appendDouble / appendString / appendBool / appendNull / appendZval`

### 写入

| 方法 | 说明 |
|---|---|
| `setLong / setString / setBool` | 数字索引写入 |
| `setAssocLong / setAssocString / setAssocBool` | 关联键写入 |

### 高级操作

| 方法 | 说明 |
|---|---|
| `pop()` / `shift()` / `unshift(zv)` | 栈/队列操作 |
| `merge(other, out)` | 数组合并 |
| `keysInto(out)` / `valuesInto(out)` | 提取键/值 |
| `sliceInto(out, offset, len)` | 切片 |
| `sort()` | 排序 |
| `iterator()` | 获取迭代器 |
| `each(ctx, cb)` | 遍历回调 |
| `filterInto(out, predicate)` | 过滤 |
| `mapInto(out, T2, transform)` | 映射 |
| `reduce(T2, initial, combine)` | 归约 |

---

## 返回值与参数（return.zig）

### 返回值

`returnString / returnLong / returnDouble / returnBool / returnNull / returnTrue / returnFalse / returnZval`

### 参数读取

| 函数 | 说明 |
|---|---|
| `callNumArgs(execute_data)` | 参数个数 |
| `callArg(execute_data, n)` | 第 n 个参数（`Zval`） |
| `getThis(execute_data)` | 当前对象（`?Zval`） |

---

## 函数调用（php_func.zig）

从 Zig 调用 PHP 函数。

| 函数 | 说明 |
|---|---|
| `call0(name, retval)` | 无参调用 |
| `call(name, retval, args)` | 通用调用 |
| `call1Str / call1Long` | 单参数便捷 |
| `call2Long / call2Str` | 双参数便捷 |
| `callMethod(obj, name, retval, args)` | 调用对象方法 |
| `callZval(callable, retval, args)` | 调用可调用对象（闭包/函数名/对象） |

---

## Object 对象操作（object.zig）

### 自由函数

`readProperty(obj, name)` / `writeProperty(obj, name, val)` / `createStdClass(zv)` /
`call(obj, name, retval, args)` / `instanceOf(obj, className)` / `getExtra(obj)`

### Object 包装

| 方法 | 说明 |
|---|---|
| `fromZval(zv)` | 构造 |
| `readProperty(name)` | 读属性 |
| `writeProperty(name, val)` | 写属性 |
| `call(name, retval, args)` | 调方法 |
| `instanceOf(className)` | 类型判断 |

---

## 异常（throw.zig）

| 函数 | 说明 |
|---|---|
| `throwException(message)` | 抛 `Exception` |
| `throwClass(className, message)` | 抛自定义类 |
| `throwClassCode(className, message, code)` | 带错误码 |
| `throwError(message)` | 抛 `Error` |
| `typeError(message)` | `TypeError` |
| `valueError(message)` | `ValueError` |
| `argumentCountError(message)` | `ArgumentCountError` |
| `arithmeticError(message)` | `ArithmeticError` |
| `divisionByZeroError(message)` | `DivisionByZeroError` |

> 注意：`throw*` 只是设置 `EG(exception)`，**不会跳过后续 defer**。
> 抛出后应立即 `return`；内存安全依赖请求级 arena 的 RSHUTDOWN 兜底（bailout-safe）。

---

## 错误报告（error.zig）

| 函数 | 说明 |
|---|---|
| `docref(doc, err_type, msg)` | 带文档引用的错误 |
| `warning(msg)` | 触发 `E_WARNING` |
| `notice(msg)` | 触发 `E_NOTICE` |

`ErrorType` 枚举：`fatal`(E_ERROR) / `warning`(E_WARNING) / `notice`(E_NOTICE) / `deprecated` / `user_warning` / `user_notice` / `user_deprecated`（对齐 PHP 常量）。

> ⚠️ `.fatal`（E_ERROR）会触发 **bailout（longjmp）**：调用后不会返回，
> Zig 侧 `defer` 被跳过。仅用于「扩展进入不可恢复状态」；
> 想让 PHP 侧可捕获请用 `Throw`（抛异常）。请求级资源由
> `Cleanup` / `RequestArena` 在 RSHUTDOWN 兜底回收（已验证，见 `example/tests/test_bailout.php`）。

---

## INI 配置（ini.zig）

### 注册

```zig
const ini = &.{ IniEntry.createLong("myext.max_len", "1024") };
```

| 工厂方法 | 说明 |
|---|---|
| `createLong(name, default_value)` | long 型 |
| `createString(name, default_value)` | string 型 |
| `createBool(name, default_value)` | bool 型 |

### 读取

| 函数 | 说明 |
|---|---|
| `getLong(name, dflt)` | 读 long |
| `getString(name)` | 读 string（`?[]const u8`） |
| `getBool(name, dflt)` | 读 bool |

---

## Fiber 协程（fiber.zig）

| 函数 | 说明 |
|---|---|
| `isFiber(zv)` | 是否为 Fiber |
| `getStatus(zv)` | 状态（`?Status`） |
| `getCurrent(rv)` | 当前 Fiber |
| `getReturn(zv, rv)` | 取返回值 |
| `create(callable, rv)` | 创建 Fiber |
| `start(zv, rv, args)` | 启动 |
| `suspend_(zv, value, rv)` | 挂起（`_` 后缀避开 Zig 关键字） |
| `resume_(zv, value, rv)` | 恢复 |
| `throw(zv, exception, rv)` | 向 Fiber 抛异常 |

`Status` 枚举：`created / running / suspended / terminated`。

---

## Observer 观察者（observer.zig）

集中式观察代理，在 MINIT 一次性静态注册，请求期内不变。观察是**旁路**——不拦截执行。

在 `ModuleOptions` / `ModuleMeta` 中设 `observer` 字段即可自动注册：

```zig
comptime {
    phpzig.moduleInit(@This(), .{
        .name = "monitor",
        .version = "1.0.0",
        .observer = .{
            .fcall_begin = onFcallBegin,
            .fcall_filter = onFcallFilter,   // 只观察关心的函数
            .@"error" = onError,             // error 是 Zig 保留字
        },
    });
}
```

### 观察点

| 字段 | 签名 | 触发时机 |
|---|---|---|
| `fcall_begin` | `fn (*ZendExecuteData) void` | 函数调用进入 |
| `fcall_end` | `fn (*ZendExecuteData, *Zval) void` | 函数调用返回 |
| `fcall_filter` | `fn (name, scope, internal) c_int` | 每个函数**首次执行前**一次 |
| `@"error"` | `fn (type, filename, lineno, message) void` | 错误/警告 |
| `function_declared` | `fn (name, handle) void` | 函数声明（handle = `zend_op_array*`） |
| `class_linked` | `fn (name, handle) void` | 类链接（handle = `zend_class_entry*`） |
| `fiber_init` / `fiber_switch` / `fiber_destroy` | `fn (status...) void` | Fiber 生命周期 |

各字段可独立为 `null`，`null` 表示不观察该类。

### 查询函数（仅 fcall begin/end 回调内有效）

| 函数 | 说明 |
|---|---|
| `funcName(execute_data)` | 当前函数名 |
| `funcInfo(execute_data)` | 被调函数自身信息（一次取全） |
| `callSite(execute_data)` | **调用点**位置（谁调用了我） |

`execute_data` 及由此取出的指针只在回调执行期间有效，**不得缓存到回调之外**。

### 过滤：只观察关心的函数

不设 `fcall_filter` 时观察全部函数——每个 PHP 函数调用都要付一次回调开销，
写监控/采样时通常不划算。设了 filter 后，引擎会把判定结果缓存进该函数的
observer 槽位，未放行的函数此后完全不进入 observer。

```zig
fn onFcallFilter(
    name: [*c]const u8, name_len: usize,
    scope: ?[*:0]const u8, scope_len: usize,
    internal: c_int,
) callconv(.c) c_int {
    const n: []const u8 = if (name != null) name[0..name_len] else "";
    // 返回非 0 = 观察，0 = 不观察
    return if (std.mem.eql(u8, n, "hello_world")) 1 else 0;
}
```

`scope` 为 `null` 表示非方法；`internal` 非 0 表示内部函数（C 实现）。
匿名函数没有函数名，会以空名传入，是否放行由 filter 自行决定。

**filter 对每个函数只调用一次**，故可放心在其中做字符串比较——但别做重活。

### 现场信息

```zig
fn onFcallBegin(execute_data: *phpzig.ZendExecuteData) callconv(.c) void {
    const info = phpzig.Observer.funcInfo(execute_data);
    // info.func_name / scope_name / filename
    // info.lineno     定义行号（内部函数为 0）
    // info.internal   内部函数（C 实现）为 true
    // info.is_method
    // info.num_args   本次调用传入的参数个数

    const site = phpzig.Observer.callSite(execute_data);
    // site.file / site.lineno —— 调用发生的位置，不是被调函数的定义位置
}
```

`funcInfo` 取的是**被调函数的定义位置**，`callSite` 取的是**调用发生的位置**，
两者语义不同，按需取用。内部函数没有 PHP 源码位置，故 `filename` 为 `null`、
`lineno` 为 0。顶层调用无调用者时 `callSite` 的 `file` 为 `null`。

### function_declared / class_linked 的 handle

`handle` 是不透明指针（`?*anyopaque`），分别为 `zend_op_array*` 与
`zend_class_entry*`。php-zig 刻意不解释其内容——这两个结构体的内存布局跨 PHP
版本变化，一旦在 Zig 侧按结构解读就会引入版本耦合。需要访问内部字段时，自行
在 C 胶水层解析。

---

## 资源管理（arena.zig / cleanup.zig）

### RequestArena（请求级内存池）

```zig
// OOM 时抛 PHP 异常并返回 null，故用 orelse return 让 PHP 传播
const arena = phpzig.RequestArena.init() orelse return;
defer arena.deinit();          // 幂等，bailout 时 RSHUTDOWN 兜底
const a = arena.allocator();   // 供 ArrayList/HashMap 等使用
```

`init()` 在 OOM 时**不 panic**——生产环境 panic 等于进程崩溃。改为设置 PHP
异常并返回 null，由调用方决定是传播（`orelse return`）还是降级后继续。

### Zig 侧内存：监控与限额

`RequestArena` 的 backing 是 `c_allocator`，**不进 PHP 内存池、不受
`memory_limit` 约束**。若无约束，进程可在 PHP 侧毫无感知的情况下逼近容器
上限并被 OOM killer 杀死——PHP 看到的用量远低于 `memory_limit`，一切"正常"。

```zig
// 可观测
phpzig.Arena.usage();   // 当前 Zig 侧活跃占用（跨全部 arena 实例）
phpzig.Arena.peak();    // 进程内峰值（RSHUTDOWN 后仍保留）

// 可约束
phpzig.Arena.configure(.{
    .limit = 64 * 1024 * 1024,  // 显式上限，0 = 不以此项限制
    .account_to_php = true,     // 参与 memory_limit 额度核算
    .check_interval = 64 * 1024,// 累积多少字节后重新核算 PHP 池用量
});
```

INI 项（由 `Module` 在 **RINIT** 自动读取，未注册则用默认值）：

INI 走 RINIT 而非 MINIT：值可被 perdir 机制按请求改变，且 ZTS 下 `PG` 每请求
线程一份——只在 MINIT 读，其它请求线程会一直用默认额度。

```ini
phpzig.arena_limit = 0              ; 字节，0 = 不以此项限制
phpzig.arena_account_to_php = 1     ; 1 = 参与 memory_limit 额度（默认开）
phpzig.arena_check_interval = 65536 ; 降频阈值，默认 64K
```

**限额语义是 reject**：超限时 `alloc` 返回 `error.OutOfMemory`，由业务代码
自行决定降级还是抛异常——框架不替下游决策。

```zig
const buf = a.alloc(u8, size) catch |err| {
    phpzig.Throw.throwException("arena exhausted");
    return;
};
```

额度取 `arena_limit` 与 `memory_limit` 剩余中的较小者。`check_interval`
用于降频：每次 alloc 都读 `zend_memory_usage()` 代价过高，故累积到阈值才
重新核算，误差最多多占一个 check_interval。

`bytesAllocated()` 是实例级的，且含 `ArenaAllocator` 内部节点开销——
反映的是**真实内存占用**而非仅用户请求量。要看总量用 `Arena.usage()`。

**使用前提**：真实的 PHP 探针（额度查询、OOM 抛异常）由 `Module` 在 MINIT 调用
`Arena.bindPhpProbes()` 挂载。绕过 `moduleInit` 直接使用 `RequestArena` 时，
这些探针是内建空实现——不施加 PHP 侧额度，但也不崩溃（安全方向的降级）。

**配置仲裁**：调用 `configure()` 后即锁定，框架在 RINIT 载入的 INI 值不再覆盖它——
否则下游在 MINIT 设的限额会在首个请求到来时被重置为 INI 默认值。
`configureFromIni()` 在已锁定时直接返回。

**线程归属**：`effective_limit`（含 `memory_limit` 剩余）是请求线程局部的，
`usage()`/`peak()`/限额配置是进程级的。`effectiveLimit()` 读当前线程的核算结果。
ZTS 与 NTS 行为一致：NTS 只有主线程，线程局部与普通全局等价。
`configure()` 改的是进程级配置，请求内调用会对其余请求线程生效——限额应在
启动期定好。

**边界**：框架只提供计数与限额能力，**不做容器感知与水位告警**。读 cgroup
limit、按水位发告警等策略由下游基于 `usage()` / `peak()` 自行实现——php-zig
是骨架，不该替业务决定特定部署环境下的内存策略。

| 方法 | 说明 |
|---|---|
| `init()` | 堆分配实例，自动注册 RSHUTDOWN 回收（bailout-safe） |
| `allocator()` | 获取 `std.mem.Allocator` |
| `deinit()` | 释放全部子分配（幂等） |
| `bytesAllocated()` | 累计分配字节数 |

### Cleanup（清理注册）

| 函数 | 说明 |
|---|---|
| `register(fn_, data)` | 注册 RSHUTDOWN 清理回调 |
| `flush()` | 立即执行所有待清理回调 |

---

## Resource 资源（resource.zig）

```zig
const Res = php.Resource.register();
Res.store(zv, ptr);   // 指针 → PHP resource
const p = Res.fetch(zv); // PHP resource → 指针（?*anyopaque）
```

---

## Closure 闭包（closure.zig）

| 函数 | 说明 |
|---|---|
| `create(handler, name, zv)` | 创建闭包 zval（handler 为 `T.FunctionHandler`） |

---

## 序列化（serialize.zig）

| 函数 | 说明 |
|---|---|
| `serialize(zv, return_value)` | 序列化（`serialize()`） |
| `unserialize(data, return_value)` | 反序列化，返回是否成功 |

---

## 类型系统（php_types.zig / php_config.zig）

### php_types.zig

底层 C 类型绑定：`Zval / ZendArray / ZendExecuteData / ZendModuleEntry / ZendFunctionEntry` 等，
以及 `IS_NULL / IS_LONG / IS_STRING / ...` 类型常量、`FunctionHandler / ModuleLifecycleFn` 回调签名。

### php_config.zig（运行时能力推导）

| 函数 | 说明 |
|---|---|
| `zendModuleApiNo()` | Zend Module API 版本号 |
| `zendModuleBuildIdPtr()` | 构建 ID 字符串指针 |
