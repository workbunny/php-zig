<p align="center">
  <img width="260px" src="https://chaz6chez.cn/images/workbunny-logo.png" alt="workbunny">
</p>

<h1 align="center">workbunny/php-zig</h1>

<p align="center">
  🐇 A Zig wrapper for the Zend API that allows developers to build PHP extensions safely and efficiently. 🐇
</p>

# php-zig

用 Zig 语言编写 PHP 扩展，受 [PHPX](https://github.com/swoole/phpx) 启发。

```zig
const phpzig = @import("phpzig");

// 命名约定自动发现：pub fn php_<name> → 模块函数（无需手写注册列表）
pub fn php_hello(_: *phpzig.ZendExecuteData, rv: *phpzig.Zval) callconv(.c) void {
    phpzig.Return.returnString(rv, "Hello from Zig!");
}

// 有参函数——参数名由伴生 struct 反射（Zig fn 无参数名，故需 Args struct）
pub fn php_add(ed: *phpzig.ZendExecuteData, rv: *phpzig.Zval) callconv(.c) void {
    const a = phpzig.Return.callArg(ed, 1).toLong();
    const b = phpzig.Return.callArg(ed, 2).toLong();
    phpzig.Return.returnLong(rv, a + b);
}
pub const addArgs = struct { a: i64, b: i64 };

// 类自动发现：pub const Class_<name> + 方法前缀约定
pub const Class_BankAccount = struct {
    balance: i64 = 0,
    open: bool = true,

    pub fn protect_getBalance(_: *phpzig.ZendExecuteData, rv: *phpzig.Zval) callconv(.c) void {
        phpzig.Return.returnLong(rv, 1000);
    }
};

// 一行注册入口——@This() 扫描当前文件自动发现函数/类，并导出 get_module
comptime {
    phpzig.moduleInit(@This(), .{
        .name    = "hello",
        .version = "1.0.0",
    });
}
```

## 为什么不用 C 写扩展？

PHP 扩展属于内核态开发：直接操作 `zval`、管理引用计数、手工注册函数表——每步出错都是 segfault。C 语言的原生武器在这一层几乎失效——没有泛型、没有编译期计算、宏是唯一的抽象手段。

**Zig 带来三样 C 不具备的东西：**

- **`comptime` 编译期执行**：函数注册表、arg_info 参数元信息、类属性声明全在编译期生成，运行时零开销。不需要 C 的宏堆叠或运行期反射。
- **`defer` + 明确所有权**：引用计数、动态分配的释放路径显式但无噪声，不会漏也不会 double-free。
- **原生交叉编译**：`zig build -Dphp=/path/to/arm-php` 直接产出目标架构的 `.so`。

**代价**：必须保留 C 胶水层（`glue/`）。Zend Engine 的核心 API 以"语句级宏"的形式存在（`ZVAL_STRINGL` 内部包含 `return` 语句），`@cImport` 无法翻译。这部分 C 代码是刚性依赖，无法消除。

## 架构

```
下游扩展 (your-ext/src/main.zig)
    导入 @import("phpzig")
    ────────────────
    php-zig 核心层
    - Zval        : 类型安全的 zval 包装 + 运算符 + 类型判断
    - Array       : 数组增删查 + filter/map/reduce + 迭代器
    - Return      : 返回值 + 参数获取
    - PhpFunc     : 从 Zig 调用 PHP 函数 / 闭包
    - Throw       : 异常抛出
    - Error       : 错误报告（php_error_docref）
    - Object      : 对象属性读写 + 方法调用 + instanceof + extern struct 绑定
    - Resource    : 资源类型注册
    - Iterator    : HashTable 遍历
    - Closure     : 从 Zig 函数创建 PHP Closure
    - Serialize   : PHP 序列化（serialize/unserialize）
    - Ini         : PHP INI 配置（声明式注册 + 读取 + 变更通知）
    - Arena       : 请求级内存池（bailout-safe，自动 RSHUTDOWN 回收）
    - Cleanup     : 清理注册表（bailout-safe，RSHUTDOWN 统一回收）
    - Fiber       : PHP Fiber 协程（只读查询 + create/start/suspend_/resume_/throw）
    - Observer    : 集中式观察代理（fcall/error/declared/class_linked/fiber 五类观察点静态注册）
    - Module      : comptime 模块注册（函数/类/接口/属性/常量/继承/生命周期/INI/对象绑定）
    ────────────────
    glue/php_glue.c (C 胶水层)
    ZVAL_* / RETVAL_* / array_init / class/property 等宏 → 普通 C 函数
```

从下往上看：Zend Engine 提供 C API → glue 把宏转成函数 → php-zig 用 Zig 的类型系统和 comptime 封装 → 下游只写纯 Zig。

一次 PHP 请求到响应的完整流转，以及各模块的生命周期归属：

```
                    一次 PHP 请求 -> 响应：php-zig 内部流转

进程级 · 模块加载（一次）
-------------------------------------------------------------------
  get_module() -> initModule() -> MINIT
    |- 函数表 / 类 / 常量 / INI 注册
    '- Observer 五类观察点注册（fcall / error / declared / class_linked / fiber）

请求级 · 每次请求
-------------------------------------------------------------------
  RINIT（可选）
    |
    v
  PHP: hello_add(1, 2)
    |
    v
  Zend Engine --zif_handler-->  php-zig handler (Zig)
    |                              |
    |  ① Observer.fcall_begin ----+  旁路：统计 / 监测（不拦截）
    |                              |
    |                              +- Return.callArg()          取参数
    |                              +- RequestArena.init()       临时内存 -> RSHUTDOWN 回收
    |                              +- Cleanup.register()        系统资源 -> RSHUTDOWN flush
    |                              +- Array / Object / Zval     PHP emalloc 池（无需回收）
    |                              +- Throw.throw*()            抛异常（仅设置 EG(exception)，defer 正常执行）
    |                              +- PhpFunc.call / Closure    回调 PHP 函数
    |                              +- Fiber.suspend_/resume_    协程挂起 / 唤起
    |                              |
    |                              '- Return.return*()          写返回值
    |  ② Observer.fcall_end ----+  旁路：统计 / 监测（不拦截）
    v
  响应返回给 PHP
    |
    v
  RSHUTDOWN（请求结束）
    |- Cleanup.flush()             清理注册的系统资源
    '- RequestArena 回收           请求级内存池

进程级 · 模块卸载
-------------------------------------------------------------------
  MSHUTDOWN -> 注销 INI 项

对象级 · extern struct 绑定（随对象生命周期，可跨请求）
-------------------------------------------------------------------
  对象创建 create_object -> init(extra) -> 方法操作 getExtra() -> dtor(extra)
```

图中三个生命周期层级：
- **进程级**：`MINIT` 注册函数/类/常量/INI/Observer，`MSHUTDOWN` 注销 INI（一次）。
- **请求级**：handler 内按内存归属分组——arena/cleanup 属 Zig 侧（RSHUTDOWN 兜底），Array/Zval 属 PHP emalloc 池（无需回收）；Observer 为旁路（不拦截）。普通 Throw 仅设置 `EG(exception)`、不 longjmp，defer 照常执行；真正跳过 defer 的是 bailout（OOM/超时/fatal/`exit`），此时由 arena/cleanup 在 RSHUTDOWN 兜底，故临时内存用 arena、系统资源用 cleanup，勿裸用 `c_allocator` 依赖 defer。
- **对象级**：extern struct 绑定随对象创建/销毁，可跨请求存活。

## 起步

需要 Zig 0.16+，以及目标 PHP 的开发头文件。

```bash
git clone https://github.com/workbunny/php-zig.git
cd php-zig/example/hello
zig build -Dphp=/usr/local
```


`-Dphp` 指向 PHP 安装前缀，框架自动查找 `include/php/`。构建产物是 `zig-out/lib/libhello.so`。

```bash
php -d extension=zig-out/lib/libhello.so \
    -r "echo hello_world() . PHP_EOL;"
```

```
Hello from php-zig!
```

完整教程见 [doc/tutorial.md](doc/tutorial.md)。

## 能力

| 类别 | 状态 | 说明 |
|------|:--:|------|
| 函数注册 | ✅ | 声明式 + comptime struct 反射 arg_info，参数名/类型/可选性全自动推导 |
| 参数默认值 | ✅ | `ParamDesc.createWithDefault/createTypedWithDefault`，Reflection 可读默认值 |
| 可变参数 | ✅ | `ParamDesc.createVariadic/createVariadicTyped`，`...$args` variadic 位 |
| 类型系统 | ✅ | IS_* 全类型判断（8 种）+ isCallable/isIterable/isScalar/isEmpty/isNumeric、取值/设值、eql/neq、算术运算符（add/sub/mul/div/mod）、关系比较（cmp/lt/le/gt/ge） |
| 数组 | ✅ | append / set / setAssoc / find / del / count / pop / shift / unshift / merge / keys / values / slice / sort / each / iterator / filter / map / reduce |
| 返回值 | ✅ | 9 种返回类型 |
| 调用 PHP | ✅ | `PhpFunc.call*` 系列 + `Object.call` 对象方法 + `callZval` 闭包调用 |
| 异常 / 错误 | ✅ | `Throw.throwException`（\Exception）+ `throwClass`（自定义异常/错误类）+ Error 家族（throwError/typeError/valueError 等）+ `Error.docref/warning/notice` |
| 模块常量 | ✅ | long / double / string / bool / null 五种 |
| 类注册 | ✅ | 方法（含 static/protected/private）+ 类常量 + 类属性（5 种类型）+ 继承 + 构造器 |
| extern struct 绑定 | ✅ | `ClassDesc.createObject` — Zig struct 生命周期绑定到 PHP 对象 |
| 接口 | ✅ | `createInterface` 注册 + `createImplements` 实现 |
| 类属性 | ✅ | 声明式 `ClassPropertyDesc.create*` + comptime struct 反射 `createWithPropsFrom` + 全反射 `createFromStruct` |
| 生命周期 | ✅ | MINIT / MSHUTDOWN / RINIT / RSHUTDOWN |
| 对象属性 | ✅ | `readProperty` / `writeProperty` + `instanceOf` + `toObject()` |
| 资源类型 | ✅ | `Resource.register/store/fetch` |
| 请求级内存池 | ✅ | `RequestArena` + `Cleanup.register`（bailout-safe，RSHUTDOWN 回收） |
| 闭包导出 | ✅ | `Closure.create` 从 Zig 函数创建 PHP Closure |
| Fiber 协程 | ✅ | 只读查询（isFiber/getStatus/getCurrent/getReturn）+ 控制操作（create/start/suspend_/resume_/throw，走 PHP 原生方法复用校验） |
| Observer 观察代理 | ✅ | 五类观察点静态注册（fcall begin/end、error、function_declared、class_linked、fiber init/switch/destroy）+ `funcName` |
| INI 配置 | ✅ | `IniEntry` 声明式注册 + `Ini.getLong/getString/getBool` 读取 + 变更通知 |
| 序列化 | ✅ | `Serialize.serialize/unserialize` — 等价 PHP serialize()/unserialize() |
| phpinfo | ✅ | `info_func` 回调 |
| 测试 | ✅ | Zig 单元测试 59 项 + PHP 集成测试 179 项 |

### 两种注册哲学，并存

```zig
// 声明式——C/C++ 开发者惯用
phpzig.FunctionDesc.createWithParams("add", add, &.{
    phpzig.ParamDesc.create("a"),
    phpzig.ParamDesc.create("b"),
});

// comptime struct 反射——Zig 惯用，编译期全自动
const AddArgs = struct { a: i64, b: i64 };
phpzig.FunctionDesc.createFrom("add", add, AddArgs);
```

类属性同样多轨并存，且支持**完整 struct 反射**——`pub fn public_xxx` → public method，`protect_` → protected，`private_` → private，`static_` → static，`magic_` → `__`前缀魔术方法：

```zig
// 全反射：struct 即 class 定义，方法 + 属性全部编译期推导
const Bank = struct {
    balance: i64 = 0,
    open: bool = true,

    pub fn public_magic_construct(_: *phpzig.ZendExecuteData, _: *phpzig.Zval) callconv(.c) void {}
    pub fn protect_getBalance(_: *phpzig.ZendExecuteData, rv: *phpzig.Zval) callconv(.c) void {
        phpzig.Return.returnLong(rv, 1000);
    }
};
phpzig.ClassDesc.createFromStruct("Bank", Bank);

// 分步式（方法 + 属性分开定义）
const BankProps = struct { balance: i64 = 0, open: bool = true };
phpzig.ClassDesc.createWithPropsFrom("Bank", &.{ ...methods... }, BankProps);
```

## 版本兼容

框架不硬编码任何 PHP 版本号。`ZEND_MODULE_API_NO`、`ZEND_ACC_*` 标志位、`sizeof(zend_internal_arg_info)`、`USING_ZTS` 等全部由 C glue 在编译期从 PHP 头文件获取。用哪个版本的 PHP 头文件编译，就产出一个与该版本兼容的 `.so`。

注意事项见 [special.md](doc/special.md)。

## 与 PHPX 的异同

php-zig 以 PHPX 为功能对齐目标，主体能力（OOP、数组、闭包、接口、异常、资源）均已覆盖。

| 维度 | PHPX (C++) | php-zig (Zig) |
|--|-----------|---------------|
| 语言 | C++（RAII、模板元编程） | Zig（comptime、defer） |
| 函数注册 | 宏自注册 + 运行时分发 | comptime 泛型 + 直接函数指针 |
| arg_info | 自动生成 | 声明式 + comptime struct 反射（双轨） |
| 类导出 | Class / Interface / 继承 / 属性 / 常量 / 访问修饰符 | 对齐 PHPX，另支持 extern struct 对象绑定 |
| 数组操作 | 完整（push/pop/shift/unshift/slice/merge/sort/keys/values） | 完整 + filter/map/reduce/each |
| 运算符 | 算术 + 比较重载 | add/sub/mul/div/mod + cmp/lt/le/gt/ge |
| 闭包导出 | 支持 | 支持（Closure.create） |
| 异常抛出 | Exception | Exception + 自定义异常类 + Error 家族 |
| 内存管理 | PHP 内存池 + C++ RAII | 「PHP 用 PHP 的，Zig 用 Zig 的」+ arena/cleanup（bailout-safe） |
| 构建 | CMake + phpize | `zig build -Dphp=/path`（注册透传，脚本 ~5 行） |
| 交叉编译 | 依赖工具链 | Zig 原生，`-Dtarget` 一键切换 |

### 我们的特色

除了对齐 PHPX 的主体能力，php-zig 在几个方向上有自己的差异化设计：

**1. comptime 全反射——`struct 即 class`**

函数参数元信息、类属性、方法（含访问修饰符）全部编译期推导，`struct` 定义本身即声明。运行时零反射开销：

```zig
const Bank = struct {
    balance: i64 = 0,          // → 属性
    pub fn public_deposit(_: *phpzig.ZendExecuteData, rv: *phpzig.Zval) callconv(.c) void {}  // → public 方法
};
phpzig.ClassDesc.createFromStruct("Bank", Bank);
```

**2. extern struct 对象绑定——Zig struct 生命周期绑定 PHP 对象**

`ClassDesc.createObject` 把 Zig struct 直接挂到 PHP 对象上，对象创建/销毁时自动调用 Zig 侧 init/dtor，状态随对象生命周期管理：

```zig
const Counter = struct { count: i64 = 0 };
phpzig.ClassDesc.createObject("Counter", &.{ /* methods */ }, Counter, counterInit, counterDtor);
```

**3. 请求级内存管理——bailout-safe**

明确「PHP 用 PHP 的、Zig 用 Zig 的」边界：PHP 数据结构由 PHP 请求池兜底，Zig 自己分配的内存用 `RequestArena`（请求级内存池）或 `Cleanup.register` 兜底。两者在 bailout（`longjmp` 跳过 `defer`）后都保证回收：

```zig
const arena = phpzig.RequestArena.init();
defer arena.deinit();          // 正常路径，bailout 时 RSHUTDOWN 兜底
const a = arena.allocator();
```

**4. 极简注册入口——`moduleInit(@This())`**

一行注册，按命名约定自动发现函数与类，无需手写注册表：

```zig
comptime {
    phpzig.moduleInit(@This(), .{ .name = "hello", .version = "1.0.0" });
}
```

**5. Fiber 协程——PHP 调度，Zig 参与**

Zig 扩展函数可在 Fiber 内挂起自己、把控制权交还 PHP event-loop，PHP 侧在合适时机唤起后继续执行。定位是「PHP 是调度器，Zig 提供挂起/唤起/检测能力」，不自行构建 event-loop：

```zig
// fiber body：挂起自己，被 resume 后继续
pub fn php_async_task(_: *phpzig.ZendExecuteData, rv: *phpzig.Zval) callconv(.c) void {
    const cur = phpzig.Fiber.getCurrent().?;   // 当前活跃 Fiber
    var value = ...;
    var ret: phpzig.Zval = undefined;
    _ = phpzig.Fiber.suspend_(cur, &value, &ret);  // 挂起，交还 PHP
    phpzig.Return.returnZval(rv, &ret);            // 被 resume 后继续
}
```

控制操作走 PHP 原生 `Fiber` 方法，复用其运行时校验与 `FiberError` 抛出，健壮产出。

**6. Observer 集中式观察代理——五类事件静态注册**

所有关键事件（函数调用 begin/end、错误、函数声明、类链接、fiber 切换）汇聚到一个代理入口，由下游 handler 决定统计/监测等旁路动作。静态注册（MINIT 一次性），请求期不变：

```zig
comptime {
    phpzig.moduleInit(@This(), .{
        .name = "monitor",
        .version = "1.0.0",
        .observer = .{
            .fcall_begin = onFcallBegin,   // 观察函数调用
            .@"error" = onError,           // 观察错误（error 是 Zig 保留字）
            .fiber_switch = onFiberSwitch, // 观察 fiber 切换
        },
    });
}

fn onFcallBegin(execute_data: *phpzig.ZendExecuteData) callconv(.c) void {
    if (phpzig.Observer.funcName(execute_data)) |name| {
        // name 为被观察的函数名，可做统计/采样/插针
    }
}
```

**7. 构建注册透传——下游 build.zig 约 5 行**

`addPhpExtension` 统一注册 target/optimize，自定义参数通过 `configure` 回调透传，无重复注册冲突。

## 许可证

Apache License 2.0
