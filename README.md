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

fn hello(execute_data: *phpzig.ZendExecuteData, rv: *phpzig.Zval) callconv(.c) void {
    phpzig.Return.returnString(rv, "Hello from Zig!");
}

// comptime struct 反射——参数名+类型全自动推导
const AddArgs = struct { a: i64, b: i64 };
const funcs = &.{ phpzig.FunctionDesc.createFrom("add", add, AddArgs) };

// v0.5.1: struct 即 class——方法 + 属性全部编译期推导
const BankAccount = struct {
    balance: i64 = 0,
    open: bool = true,

    pub fn public_magic_construct(_: *phpzig.ZendExecuteData, _: *phpzig.Zval) callconv(.c) void {}
    pub fn protect_getBalance(_: *phpzig.ZendExecuteData, rv: *phpzig.Zval) callconv(.c) void {
        phpzig.Return.returnLong(rv, 1000);
    }
};
const classes = &.{ phpzig.ClassDesc.createFromStruct("BankAccount", BankAccount) };
```

## 为什么不用 C 写扩展？

PHP 扩展属于内核态开发：直接操作 `zval`、管理引用计数、手工注册函数表——每步出错都是 segfault。C 语言的原生武器在这一层几乎失效——没有泛型、没有编译期计算、宏是唯一的抽象手段。

**Zig 带来三样 C 不具备的东西：**

- **`comptime` 编译期执行**：函数注册表、arg_info 参数元信息、类属性声明全在编译期生成，运行时零开销。不需要 C 的宏堆叠或运行期反射。
- **`defer` + 明确所有权**：引用计数、动态分配的释放路径显式但无噪声，不会漏也不会 double-free。
- **原生交叉编译**：`zig build -Dphp=/path/to/arm-php` 直接产出目标架构的 `.so`。

**代价**：必须保留约 300 行 C 胶水层。Zend Engine 的核心 API 以"语句级宏"的形式存在（`ZVAL_STRINGL` 内部包含 `return` 语句），`@cImport` 无法翻译。这部分 C 代码是刚性依赖，无法消除。

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
    - Object      : 对象属性读写 + 方法调用 + instanceof
    - Resource    : 资源类型注册
    - Iterator    : HashTable 遍历
    - Closure     : 从 Zig 函数创建 PHP Closure
    - Module      : comptime 模块注册（函数/类/接口/属性/常量/继承/生命周期）
    ────────────────
    glue/php_glue.c (C 胶水层)
    ZVAL_* / RETVAL_* / array_init / class/property 等宏 → 普通 C 函数
```

从下往上看：Zend Engine 提供 C API → glue 把宏转成函数 → php-zig 用 Zig 的类型系统和 comptime 封装 → 下游只写纯 Zig。

## 起步

需要 Zig 0.16+，以及目标 PHP 的开发头文件。

```bash
git clone https://github.com/workbunny/php-zig.git
cd php-zig/example
zig build -Dphp=/usr/local
```


`-Dphp` 指向 PHP 安装前缀，框架自动查找 `include/php/`。构建产物是 `zig-out/lib/libhello.so`。

```bash
php -d extension=zig-out/lib/libhello.so \
    -r "echo hello_world() . PHP_EOL . hello_name('Zig') . PHP_EOL . add(3, 5);"
```

```
Hello from Zig!
Hello, Zig!
8
```

完整教程见 [doc/tutorial.md](doc/tutorial.md)。

## 能力

| 类别 | 状态 | 说明 |
|------|:--:|------|
| 函数注册 | ✅ | 声明式 + comptime struct 反射 arg_info，参数名/类型/可选性全自动推导 |
| 类型系统 | ✅ | IS_* 全类型判断（8 种）+ isCallable/isIterable/isScalar/isEmpty/isNumeric、取值/设值、eql/neq、算术运算符（add/sub/mul/div/mod）、关系比较（cmp/lt/le/gt/ge） |
| 数组 | ✅ | append / set / setAssoc / find / del / count / pop / shift / unshift / merge / keys / values / slice / sort / each / iterator / filter / map / reduce |
| 返回值 | ✅ | 9 种返回类型 |
| 调用 PHP | ✅ | `PhpFunc.call*` 系列 + `Object.call` 对象方法 + `callZval` 闭包调用 |
| 异常 / 错误 | ✅ | `Throw.throwException` + `Error.docref/warning/notice` |
| 模块常量 | ✅ | long / double / string / bool / null 五种 |
| 类注册 | ✅ | 方法（含 static/protected/private）+ 类常量 + 类属性（5 种类型）+ 继承 + 构造器 |
| 接口 | ✅ | `createInterface` 注册 + `createImplements` 实现 |
| 类属性 | ✅ | 声明式 `ClassPropertyDesc.create*` + comptime struct 反射 `createWithPropsFrom` + 全反射 `createFromStruct` |
| 生命周期 | ✅ | MINIT / MSHUTDOWN / RINIT / RSHUTDOWN |
| 对象属性 | ✅ | `readProperty` / `writeProperty` + `instanceOf` |
| 资源类型 | ✅ | `Resource.register/store/fetch` |
| 闭包导出 | ✅ | `Closure.create` 从 Zig 函数创建 PHP Closure |
| phpinfo | ✅ | `info_func` 回调 |
| 测试 | ✅ | Zig 单元测试 57 项 + PHP 集成测试 115 项 |
| INI 配置 | ❌ | 依赖 `PHP_INI_BEGIN/END` 编译期声明 |

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

## 与 PHPX 的取舍

| | PHPX (C++) | php-zig v0.7 (Zig) |
|--|-----------|---------------|
| 函数注册 | 宏自注册 + 运行时分发 | comptime 泛型 + 直接函数指针 |
| arg_info | 自动生成 | 声明式 + comptime struct 反射（双轨） |
| 类导出 | Class / Interface / 继承 / 属性 / 常量 / 访问修饰符 | Class / Interface / 继承 / 属性（5 种类型）/ 常量 / public/protected/private |
| 数组操作 | 完整（push/pop/shift/unshift/slice/merge/sort/keys/values） | 完整（对齐 PHPX）+ filter/map/reduce/each |
| 运算符 | 算术 + 比较重载 | add/sub/mul/div/mod + cmp/lt/le/gt/ge |
| 闭包导出 | 支持 | 支持（Closure.create） |
| 构建 | CMake + phpize | `zig build -Dphp=/path` |
| 生产可用性 | 生产级 | 主体功能完成（v0.7），接近生产可用 |

php-zig 的策略：优先覆盖 PHPX 主体功能（OOP、数组、闭包、接口均已对齐），comptime 能力是 PHPX 不具备的差异优势。

## 许可证

Apache License 2.0
