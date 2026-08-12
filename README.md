# php-zig

用 Zig 语言编写 PHP 扩展，受 [PHPX](https://github.com/swoole/phpx) 启发。

```zig
const phpzig = @import("phpzig");

fn hello(execute_data: *T.ZendExecuteData, rv: *T.Zval) callconv(.c) void {
    phpzig.Return.returnString(rv, "Hello from Zig!");
}
```

## 为什么不用 C 写扩展？

PHP 扩展属于内核态开发：直接操作 `zval`、管理引用计数、手工注册函数表——每步出错都是 segfault。C 语言的原生武器在这一层几乎失效——没有泛型、没有编译期计算、宏是唯一的抽象手段。

**Zig 带来三样 C 不具备的东西：**

- **`comptime` 编译期执行**：函数注册表、参数元信息在编译期生成，运行时零开销。不需要 C 的宏堆叠或运行期反射。
- **`defer` + 明确所有权**：引用计数、动态分配的释放路径显式但无噪声，不会漏也不会 double-free。
- **原生交叉编译**：`zig build -Dphp=/path/to/arm-php` 直接产出目标架构的 `.so`。

**代价**：必须保留约 300 行 C 胶水层。Zend Engine 的核心 API 以"语句级宏"的形式存在（`ZVAL_STRINGL` 内部包含 `return` 语句），`@cImport` 无法翻译。这部分 C 代码是刚性依赖，无法消除。

## 架构

```
下游扩展 (your-ext/src/main.zig)
    导入 @import("phpzig")
    ────────────────
    php-zig 核心层
    - Zval     : 类型安全的 zval 包装
    - Array    : 数组增删查 + 迭代器
    - Return   : 返回值 + 参数获取
    - PhpFunc  : 从 Zig 调用 PHP 函数
    - Throw    : 异常抛出
    - Object   : 对象属性读写
    - Resource : 资源类型注册
    - Iterator : HashTable 遍历
    - Module   : comptime 模块注册（函数/类/常量/生命周期）
    ────────────────
    glue/php_glue.c (300行 C)
    ZVAL_* / RETVAL_* / array_init 等宏 → 普通 C 函数
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
| 函数注册 | ✅ | 模块级函数 + 类方法（含静态） + 参数 arg_info 自动生成 |
| 类型系统 | ✅ | IS_* 全类型判断、取值（long/double/string/bool）、设值（5 种） |
| 数组 | ✅ | 追加 / 索引设值 / 关联设值 / 查找 / 删除 / 计数 / pop / 迭代器 / filter / map / reduce |
| 返回值 | ✅ | 9 种返回类型 |
| 调用 PHP | ✅ | `PhpFunc.call*` 系列 + `Object.call` 对象方法 |
| 异常 | ✅ | `Throw.throwException(msg)` |
| 模块常量 | ✅ | long / double / string / bool / null 五种 |
| 类注册 | ✅ | 静态方法 + 继承 |
| 生命周期 | ✅ | MINIT / MSHUTDOWN / RINIT / RSHUTDOWN |
| 对象属性 | ✅ | `readProperty` / `writeProperty` |
| 资源类型 | ✅ | `Resource.register/store/fetch` |
| phpinfo | ✅ | `info_func` 回调 |
| 测试 | ✅ | Zig 单元测试 18 项 + PHP 集成测试 47 项 |
| Zval 运算符 | ✅ | `eql` / `neq`（类型标签 + 逐值比较，纯 Zig） |
| 非静态方法 | ✅ | flags=0 时 resolveFlags 仅返回 acc_public |
| 类常量 | ✅ | long / string 两种，`ClassConstantDesc` |
| Class 属性 | ❌ | 待实现 |
| INI 配置 | ❌ | 依赖 `PHP_INI_BEGIN/END` 编译期声明 |
| foreach 语法糖 | ❌ | 基于内部指针的迭代器已可用 |

## 版本兼容

框架不硬编码任何 PHP 版本号。`ZEND_MODULE_API_NO`、`ZEND_ACC_*` 标志位、`sizeof(zend_internal_arg_info)`、`USING_ZTS` 等全部由 C glue 在编译期从 PHP 头文件获取。用哪个版本的 PHP 头文件编译，就产出一个与该版本兼容的 `.so`。

注意事项见 [special.md](doc/special.md)。

## 与 PHPX 的取舍

| | PHPX (C++) | php-zig (Zig) |
|--|-----------|---------------|
| PHP 类导出 | Class / Interface / 继承 / 可见性 / 属性 / 常量 | Class 注册（静态方法 + 非静态方法 + 继承 + 类常量） |
| 闭包导出 | 支持 | 不支持 |
| 函数分发 | `_exec_function` 运行时分发 | 直接函数指针，零运行开销 |
| 构建 | CMake + phpize | `zig build -Dphp=/path` |
| 类型系统 | Variant（完整，包含运算符重载、类型转换） | Zval + Array（判断/取值/设值/迭代） |
| 生产可用性 | 生产级 | 原型阶段 |

PHPX 功能更全，php-zig 更轻、构建更直接。

## 许可证

Apache License 2.0
