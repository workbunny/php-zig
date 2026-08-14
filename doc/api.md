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
| `createFrom(name, handler, Args)` | **comptime 反射**：struct 字段 → 参数（类型/可空自动推导） |
| `createStaticFrom(...)` | 反射 + 静态 |
| `createProtected(name, handler)` / `createProtectedWithParams(...)` | protected 方法 |
| `createPrivate(name, handler)` / `createPrivateWithParams(...)` | private 方法 |

```zig
// createFrom 示例：字段顺序 = 参数顺序，字段名 = 参数名
const AddArgs = struct { a: i64, b: i64, name: []const u8 };
FunctionDesc.createFrom("my_add", my_add, AddArgs);
```

### ParamDesc / ParamType

```zig
pub const ParamDesc = struct {
    name: [:0]const u8,
    param_type: ParamType = .mixed,
    allow_null: bool = false,
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

### 取值（强转）

| 方法 | 返回 |
|---|---|
| `toLong()` | `T.zend_long` |
| `toDouble()` | `f64` |
| `toBool()` | `bool` |
| `toStringVal()` | `[]const u8` |

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

`ErrorType` 枚举：`E_ERROR / E_WARNING / E_NOTICE / E_DEPRECATED` 等（对齐 PHP 常量）。

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

```zig
const cfg = php.ObserverConfig{
    .error = php.ObserverConfig.Mode.disabled, // 启用则记录错误回溯
};
```

| 类型/函数 | 说明 |
|---|---|
| `Config` | 观察点配置（`error` 字段等） |
| `register(cfg)` | MINIT 一次性注册观察点 |
| `funcName(execute_data)` | 取当前函数名 |

> 在 `ModuleOptions` / `ModuleMeta` 中设 `observer` 字段即可在 MINIT 自动注册。

---

## 资源管理（arena.zig / cleanup.zig）

### RequestArena（请求级内存池）

```zig
var arena = php.RequestArena.init();
defer arena.deinit();
const a = arena.allocator(); // 供 ArrayList/HashMap 等使用
```

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
