# 设计哲学与竞品分析

> 本文件记录**长期稳定**的项目定位、设计哲学与竞品对比。
> 实现细节与踩坑见 [`special.md`](special.md)。

---

## 项目定位

php-zig 是用 Zig 编写 PHP 扩展的框架，受 [swoole/PHPX](https://github.com/swoole/phpx) 启发。

**核心目标**：用少量 C 代码包装 Zend 的宏 DSL，再按 Zig 的设计理念封装 Zend API，让下游用 Zig 写 PHP 扩展。

一句话概括架构：**Zend 的宏在 C 侧展开，Zig 只面对干净的 extern fn ABI。**

---

## 设计哲学

| # | 原则 | 含义 |
|:--:|------|------|
| 1 | **最小原则** | Zig 能实现的不包装，只有 Zig 做不到的才进 C 胶水层 |
| 2 | **Zig 惯用风格** | 参考 PHPX 但适配 Zig 习惯，不照搬 C++ 模式 |
| 3 | **C 最小使用** | C 只做 Zig 做不到的事（见 special.md「glue 分类」） |
| 4 | **Zig 内存优先** | 能用 Zig 内存体系就不用 PHP 的 |
| 5 | **构建独立** | 不依赖 PHP 的 phpize / CMake，用 Zig 原生 build system |

这五条不是并列关系——**原则 1 是总纲**，其余是它在风格、语言边界、内存、构建四个维度的展开。

---

## 核心架构决策

### 为什么不用 translate-c（extern fn ABI）

PHP 是为 GCC/Clang/MSVC 写的 **C89** 代码，Zend 头文件充满依赖 C 编译器「宽容行为」的宏。Zig 的 `translate-c`（`@cImport`）对其无能为力：

| Zend 宏类别 | 特性 | translate-c 的问题 |
|---|---|---|
| 语句级宏 | `ZVAL_STRINGL` 内含 `do-while` 块 | 无法翻译成 Zig 表达式 |
| 提前返回宏 | `RETURN_STRING` 内含 `return` | 破坏 Zig 控制流（会跳过 `defer`） |
| 类型双关宏 | `Z_TYPE_P` 解引用 union 成员 | Zig 严格类型拒绝隐式转换 |
| 遍历宏 | `ZEND_HASH_FOREACH_*` 依赖指针运算 | 翻译后类型推导失败 |
| 编译器内建 | `EXPECTED/UNEXPECTED`（`__builtin_expect`） | 内建函数无法移植 |
| 跨位数类型 | `zend_long` 在 32/64 位不同 | 翻译结果平台相关 |
| 复杂初始化 | `INIT_CLASS_ENTRY_EX` 结构体初始化 | 布局推导易错 |

**根因**：这不是工具实现问题，而是**两种语言类型哲学的本质冲突**——C 的隐式转换 / `container_of` / 语句块展开 vs Zig 的严格类型 + 无隐式转换。

```
phpz：    C 头文件 ──translate-c──► Zig 声明（宏翻译失败 / 类型错乱）
php-zig： C 头文件 ──C 编译器──► php_glue.c（宏正常展开为普通函数）
                                    ↓
                               Zig 只看到 extern fn ABI（类型边界清晰）
```

**收益**：宏由 C 编译器原生展开，零兼容问题；Zig 侧只面对普通 C 函数；版本适配在 C glue 内部用 `#ifdef` / 运行时查询完成。

**代价**：手写 C 胶水是刚性依赖，每加一个能力要同步写 C + Zig 两端。相比 translate-c 不可控的翻译结果，这是**确定性的成本**。

> 注：Zig 0.10 后 translate-c 已从 libclang 改为自研翻译器，但根本矛盾不变。

### 版本自适应：运行时而非编译期

不硬编码 PHP 版本号。ACC 常量（`ZEND_ACC_PUBLIC` 等在 PHP 7.x/8.4+ 取值不同）、arg_info 布局、函数调用 API 均在**运行时从 C glue 查询**，一套二进制适配多版本。

### 直接函数指针：零运行时开销

PHPX 用 `_exec_function` 统一分发器 + `reserved[3]` 缓存 C++ 对象指针；php-zig 用 comptime 生成 `zend_function_entry[]` + **直接函数指针**，无分发层。

---

## 竞品分析

### PHPX（C++）

swoole 出品的成熟框架，架构四层：`PHP 扩展层 → 门面层(func/class/const) → 核心层(Variant/Array/Object) → Zend Engine API`。

| 设计决策 | PHPX | php-zig |
|---|---|---|
| 模块入口 | `PHPX_EXTENSION()` 宏定义 `get_module()` | comptime 泛型函数生成 |
| 函数注册 | C++ 静态全局对象自注册到 `function_map` | comptime 生成 `zend_function_entry[]` |
| 函数分发 | `_exec_function` 统一分发 + 槽缓存 | 直接函数指针（零开销） |
| 类型系统 | `Variant` RAII + 继承链 | `Zval` struct + `defer` |
| 构建 | CMake + phpize | Zig 原生 build system |

### phpz（Zig）

[happystraw/phpz](https://github.com/happystraw/phpz)，同为 Zig 实现的框架，**是最直接的竞品**。

| | phpz | php-zig |
|---|---|---|
| C 绑定 | `translate-c` 自动翻译 | 手写 C glue |
| arg_info 生成 | PHP 官方 `gen_stub.php`（需 php-src 源码） | comptime struct 反射（零外部依赖） |
| 版本适应 | 依赖 nightly Zig + 编译期头文件 | 运行时自适应 |
| 对象绑定 | `extern struct` 绑定生命周期 | 运行时属性读写 + extern struct 绑定 |

- **phpz 优势**：INI、观察者、枚举、模块全局变量、allocator、bailout-safe cleanup、多平台、CLI 骨架生成器
- **phpz 劣势**：依赖 nightly Zig（0.17.0-dev 不稳定）、构建链长（gen_stub + translate-c）、API 剧变
- **php-zig 优势**：零外部依赖、稳定 Zig 0.16、comptime 元编程（**struct 反射 / 全反射类注册是 phpz 不具备的差异化竞争力**）、数组算法与运算符更全
- **php-zig 劣势**：平台验证少、无 CLI

### vphp（V 语言）

用 V 编译器 pipeline 生成胶水，`@[php_function]` attribute 声明导出，GC + borrow/own 内存模型。

### 关键差异总结

| | PHPX (C++) | vphp (V) | php-zig |
|---|---|---|---|
| 入口方式 | `PHPX_EXTENSION()` 宏 | `@[php_function]` | comptime `Module()` + `@export` |
| 函数分发 | 运行时分发 | 编译器生成胶水 | ★ 直接函数指针（零开销） |
| 元编程 | C++ 模板 + 静态构造 | 编译器 pipeline | Zig comptime |
| 内存模型 | 引用计数 RAII | GC + borrow/own | 手动管理 + `defer` |
| OOP 导出 | 完整 Class/Interface | Class/Interface/Trait/Enum | Class/Interface/继承/属性/常量 |
| 版本兼容 | 编译期头文件 | 编译期头文件 | ★ 运行时自适应 |
| 构建 | CMake + phpize | V 编译器 + Makefile | Zig build system |

---

## 边界：明确不做的事

对齐 PHPX 的生产能力是目标，但**违背 Zig 宗旨的部分明确排除**：

| 排除项 | 原因 |
|---|---|
| Trait | Zig 无对应语言特性，强行模拟违背惯用风格 |
| Enum / Native Enum 导出 | 同上 |
| RAII 自动引用计数 | Zig 无 RAII，用 `defer` 显式管理更契合 |
| `$args[i]` 语法糖 | 引入非 Zig 惯用的魔法，违反「Zig 惯用风格」 |

**判断标准**：凡是需要「模拟别的语言」才能做到的功能，都不做；只做「用 Zig 的原生能力自然表达」的功能。

---

## 其他关键决策

- **bailout-safe cleanup**：PHP 的 bailout（OOM/超时/fatal）用 `longjmp` 跳过 Zig `defer`。但 zval/emalloc 由请求级内存池兜底，真正泄漏的只有 Zig 侧系统资源（allocator 内存/文件/socket），故与 allocator 一起做。
- **Fiber 控制操作走 PHP 原生方法**：`zend_fiber_suspend/resume/start` 内含 `return` 宏（会提前中断 glue 函数），故控制操作改用 `PhpFunc.callMethod` 调 PHP 原生 `Fiber::*`，既避开陷阱又天然获得运行时校验。只读查询仍由 glue 直读结构体（零开销）。
- **Observer 集中式代理**：MINIT 静态注册，用一个 init handler 代理所有事件（Zend 只允许注册一个）。注册了 filter 时按 filter 结果决定是否观察某函数，引擎缓存判定结果，未放行函数零开销；未注册 filter 则观察全部，由下游自行过滤。
- **Zig 侧内存须显式约束**：`RequestArena` 的 backing 是 `c_allocator`，不进 PHP 内存池、不受 `memory_limit` 约束——这既是特性（大块临时内存不触发 memory_limit）也是风险（PHP 侧无感知地逼近容器上限被 OOM 杀死）。故框架提供进程级计数与 INI 限额，并默认参与 `memory_limit` 额度核算。

---

## 参考资料

- PHPX: https://github.com/swoole/phpx
- phpz: https://github.com/happystraw/phpz
- vphp: https://github.com/guweigang/vphp
- Zig: https://ziglang.org
