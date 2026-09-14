# 责任边界

> php-zig 是**骨架**，不是运行时。本文划边界：哪些失败骨架接住，哪些归下游。
> 版本约定见 [`compat.md`](compat.md)，能力清单见 [`../README.md`](../README.md#能力)。

骨架交付的不是「长跑不出问题」，而是让下游**可控地失败**：类型闭合（进来的值可解释）、
失败显式（编译错误 / 异常 / reject，不静默）、内存可观测（框架占多少能测能断言）、
崩溃可定位（能定位到用例与输入）、边界已声明（本文第二节）。

## 一、骨架负责

| # | 能力 | 机制 | 验证方式 |
|:--:|---|---|---|
| 1 | 类型边界不越界 | 取参走引擎 cast 转换（`zval_get_long`/`zval_get_double`）；`asString()` 对非字符串返回 null，`toStringVal()` 返回空串，不产生垃圾指针。object/array → int 是 **cast（操作符）语义**（Warning + 值），**有意**不同于内置函数的 ZPP（TypeError）—— 理由见下节「取值语义」 | `test_corpus.php`（17 函数 × 24 语料：不崩溃 **且**诊断在预期范围内）+ `test_all.php` 的 `asString()` 类型不符断言 |
| 2 | 失败显式 | 缺 `Args`/`Untyped` → 编译期报错；OOM 走 reject 语义 + 抛 PHP 异常，不 panic；`RequestArena.init()` 返回 `?*` | Zig 单测 + `test_all.php` |
| 3 | 内存可观测 | 框架自身 `c_allocator` 全部经 `memtrack` 记账；`Arena.usage()`/`peak()` 可断言归零；INI 限额默认参与 `memory_limit` 额度 | Zig 单测 + `test_all.php` |
| 4 | 崩溃可定位 | fork 隔离 + 信号检测 + **退出码判据**（致命错误退出不算「不崩溃」，`exit=255` 会被记成通过正是这条要堵的洞） | `test_crash.php` |
| 5 | 请求生命周期兜底 | `Cleanup` + `RequestArena` 在 RSHUTDOWN 回收，含真实 bailout（longjmp）路径 | `test_bailout.php` |
| 6 | 线程模型无关 | 请求级状态 `threadlocal`（cleanup 注册表、arena 派生额度），进程级计数原子（memtrack），限额按请求从 INI 载入——ZTS 与 NTS 行为一致 | Zig 单测（线程隔离用例）+ CI 矩阵 |
| 7 | 版本 / 平台适配 | 不硬编码 PHP 版本常量：`ZEND_MODULE_API_NO`、`ZEND_ACC_*`、`sizeof(zend_internal_arg_info)` 由 C glue 编译期取自 PHP 头文件 | CI 矩阵 PHP 8.2~8.5 |
| 8 | 逃生路径 | 骨架未覆盖的 Zend API，下游可自建 C glue，与内置 glue 同机制共存 | [`tutorial.md`](tutorial.md) |
| 9 | 两个内存作用域隔离 | 请求级 / 常驻级是两套**物理隔离**账本：`shouldReject` 只读请求级，常驻内存不挤占任何请求的 Arena 额度 | Zig 单测（红线回归）+ `test_all.php` §31 |
| 10 | 常驻内存生命周期 | `ResidentArena.shared()` 由框架在 MSHUTDOWN 释放；请求级在 RSHUTDOWN 释放（含真实 bailout 路径） | `test_bailout.php`（请求级归零 vs 常驻级存活） |
| 11 | 诊断可分类 | 子进程内关闭 `log_errors` 与 `display_errors`（`log_errors` 是唯一能穿透 `ob_start` 的通道），诊断经 socketpair 回传，按坐标**双向**核对：该有的必须有、不该有的不能有 | `isolation.php` + 三套隔离测试（`stderr` 全空 = 无意外诊断） |

### 线程模型：ZTS 与 NTS 的行为一致性

PHP 侧已吃掉 ZTS/NTS 的差异：扩展拿到的 `execute_data`、zval、`EG()`/`PG()` 都是
当前请求线程的，扩展层看到的行为一致。骨架要负责的只是**别让自己的状态跨线程串**：

- 请求级状态（`cleanup` 注册表、`arena` 的 `effective_limit`/`since_check`）是 `threadlocal`
  ——ZTS 下每请求线程各一份，NTS 下只有主线程，与普通全局等价；
- 进程级状态（`memtrack` 的 `usage`/`peak`、限额配置、PHP 探针函数指针）保持全局。
  「框架 c_allocator 一共能用多少」是进程视角的约束，按线程拆开会让 N 个线程各吃一份额度；
- 限额原本在 MINIT 读取，已改为 **RINIT**：INI 值可被 perdir 机制按请求改变，且 ZTS 下
  PG 每线程一份，只在 MINIT 读会让其它请求线程一直用默认额度。

`php_config.ztsMode()` 可查询当前线程模型，供下游决定能否自开线程。

### 取值语义：跟随 cast（操作符）语义，**不**模仿 ZPP

这是有意与 PHP 内部函数不同的一处，也是"责任边界"里最容易被误解的一格，故单独说明。

> **术语约定**：**cast 语义** = 我们的取值 API（等价 PHP 里的 `(int)$v` / `(string)$v`）；
> **ZPP 弱模式** = 原生内部函数的参数解析。「弱转换」一词常被同时用来指这两者，故本文不用它。

| 输入 | php-zig 取值 / PHP 的 `(int)$v` | 内置函数 `int $n` 参数（ZPP） |
|---|---|---|
| `"3"`、`3.7`、`null`、`true` | cast 结果（`3` / `3` / `0` / `1`）；`3.7`、`null` 无提示 | `"3"`→3（弱模式）；`3.7`/`null` 附 `E_DEPRECATED` |
| `"abc"`、`""`、`[]`、`object`、`resource` | cast 结果（`0`/`0`/`0`或`1`/`1`+Warning/句柄） | **`TypeError`** |
| `strict_types=1` | **无影响**（cast 不受其影响） | **全面拒绝**，连 `"3"` 都拒 |

ZPP 弱模式有两个前提：该参数**声明了具体标量类型**，且调用方文件**不是** `strict_types`；
声明 `mixed` 或不声明时，ZPP 不做任何转换。php-zig 的取值原语没有这套前提，也不打算重建它，
理由有三：

1. **缺上下文**：ZPP 是*参数解析器*，它知道"第几个参数、声明了什么类型、是否 nullable、
   调用方是否严格"。取值原语面对的是**任意来源的 zval**（数组元素、被调函数返回值、闭包回传值），
   给它们套参数语义本身不成立。
2. **它是 PHP 内部函数的实现细节，会随版本漂移**：`1.9`→int 的弃用（8.1）、`null`→非 nullable
   的弃用、`__toString` 的参与规则……跟随等于把这份维护成本搬进框架。
3. **cast 语义精确可得且已在用**：`phpglue_zval_get_long` 就是 `zval_get_long`，与开发者自己写
   `(int)$v` 是同一条路径——可预期、可推理，且**永不返回垃圾指针**（这才是它的存在理由：
   Release 下引擎不校验 arg_info，直读 `Z_LVAL_P` 会把指针当数值）。

**代价（必须知道）**：以参数语义衡量，这是**宽松**的——传错类型不报错，`toLong()` 会把
`object` 变成 `1`（附一条 `Warning`）。所以"严格"要自己拿：

- 声明 `Args`/`ArgTypes`（Reflection / IDE / 文档 / ZEND_DEBUG 断言），
  并在 handler 内显式校验（`isLong()`/`isString()`/`asString()` + `Throw`）。
  框架不替你拦，因为 Release 构建下引擎也不拦（见 §二 第 3、9 条）。
- 取值 API 的定位因此是"**永不返回垃圾值的 cast**"，不是"参数校验器"。
  要"传错就拒"的调用者体验，由**声明 + 显式校验**提供，而不是由取值 API 提供。

> `toStringVal()` 是有意**不**做 cast 的：非字符串一律返回空串（而 `(string)123` 是 `"123"`），
> 这是防野指针的安全默认。要 cast 结果用 `castString()`（`(string)$v` 语义，见
> [`api.md`](api.md)）——两者并存，各服务不同场合：一个给"安全的空值"，一个给"PHP 的转换结果"。

## 二、骨架不负责

| # | 项 | 为什么骨架不管 | 下游该做什么 |
|:--:|---|---|---|
| 1 | 下游自己的 `c_allocator` / 裸 malloc | `memtrack` 只覆盖框架内部的分配，下游调用点骨架看不见 | 优先用 `RequestArena` / `ResidentArena`；确需裸分配则用 `Memtrack.trackAlloc`/`trackFree` 注入观测，或接受不可见 |
| 2 | Zig 侧自开线程 | 这类线程没有 RINIT/RSHUTDOWN，也拿不到请求上下文——与 ZTS/NTS 无关，是通用约束 | 需要的数据显式传入或走 IPC；线程内不要用 `RequestArena`/`Cleanup` |
| 3 | 绕过 `PhpType` 的取参 | 骨架提供 cast 语义 API，拦不住 `isLong() else 0` 这类写法 | 用 `toLong()`/`toDouble()`/`asString()`；要约束就声明 `Args`/`ArgTypes` |
| 4 | 跨请求 / 跨进程存活的指针 | MINIT 期持久内存、opcache 共享内存上的 `op_array`/`class_entry` 挂 Zig 指针会跨请求甚至跨进程悬垂 | 只在请求生命周期内持有 Zend 结构指针 |
| 5 | PHP 侧内存（ZendMM 池） | 由引擎管理；骨架只在 arena 侧参与额度核算 | 用 `memory_get_usage()` 观测 |
| 6 | 请求内改限额的进程可见性 | 限额配置是进程级的，请求内 `configure()` 对其余请求线程同样生效，且会锁定使后续 INI 载入不再覆盖 | 限额在 INI/启动期定好 |
| 7 | 部署环境策略 | 骨架给 `usage()`/`peak()`，不做 cgroup 感知、水位告警、OOM 降级 | 基于 `usage()`/`peak()` 自行实现 |
| 8 | Valgrind / 长跑审计 | 非实时、依赖环境；骨架侧已有归零断言 | 归下游（含下游自己的裸分配） |
| 9 | 参数个数校验 | 内部函数少参不抛 `ArgumentCountError`，由 handler 判断——当前行为特征 | handler 内用 `callNumArgs()` 判断并 `Throw` |
| 10 | 返回值移交之后的生命周期 | `returnString`/`returnZval` 之后所有权归引擎 | 不缓存已移交的 zval 指针 |
| 11 | `unsafeAllocator()` 的分配 | 语义即「明确放弃托管」：不记账、不受额度约束、bailout 时无兜底 | 非必要不使用；用则自控释放时机与 OOM 后果 |
| 12 | 常驻内存的容器上限 | `resident_limit` 默认 0（不设防），框架不做 cgroup 感知 | 按部署环境在 INI 设值，或基于 `usageScope(.resident)` 自建告警 |

## 三、下游自查

1. 内存归属：自己的裸分配是否换成 `RequestArena`（请求内）或 `ResidentArena`
   （跨请求），或已用 `Memtrack.trackAlloc`/`trackFree` 注入观测。
2. 泄漏探针：循环 5 万次后断言内存增量 < 64KB（模板见 `example/tests/test_all.php`
   的内存增长探针段，含反向验证控制组）。
3. 归零断言：请求结束后 `Arena.usage()` 回到基线；常驻级在 MSHUTDOWN 后归零。
4. bailout 模板：`example/tests/test_bailout.php`，三组对照（正常返回 / Zig 侧 E_ERROR /
   回调内 E_USER_ERROR），可照搬成自己扩展的回归用例。
5. 语料矩阵：新函数补进 `test_corpus.php`，并声明它的cast 位（第 3 位）。判据是
   「不崩溃 **且**诊断在预期范围内」——预期诊断由「cast 位 × object 语料」推导，
   分类之外一律拒绝；不要用「看见了就加进白名单」的方式放行。
6. 自建 C glue：见 [`tutorial.md`](tutorial.md) 逃生路径。
7. 常驻内存：`ResidentArena.init()` 的实例是否已 `destroy()`（`shared()` 单例由框架
   在 MSHUTDOWN 释放）；持有常驻指针的模块级静态是否在 `shutdown()` 时清空。
8. unsafe 自查：`unsafeAllocator()` 的每一笔是否都有对应释放；若已用裸记账 API
   注入观测，释放时是否同步 `trackFree`（漏掉会让计数永久虚高，由第 3 条兜住）。
