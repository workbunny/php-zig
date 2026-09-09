# 责任边界

> php-zig 是**骨架**，不是运行时。本文划边界：哪些失败骨架接住，哪些归下游。
> 版本约定见 [`compat.md`](compat.md)，能力清单见 [`../README.md`](../README.md#能力)。

骨架交付的不是「长跑不出问题」，而是让下游**可控地失败**：类型闭合（进来的值可解释）、
失败显式（编译错误 / 异常 / reject，不静默）、内存可观测（框架占多少能测能断言）、
崩溃可定位（能定位到用例与输入）、边界已声明（本文第二节）。

## 一、骨架负责

| # | 能力 | 机制 | 验证方式 |
|:--:|---|---|---|
| 1 | 类型边界闭合 | 取参走官方弱转换（`zval_get_long`/`zval_get_double`）；`asString()` 对非字符串返回 null，`toStringVal()` 返回空串，不产生垃圾指针 | `test_corpus.php`（13 函数 × 24 语料） |
| 2 | 失败显式 | 缺 `Args`/`Untyped` → 编译期报错；OOM 走 reject 语义 + 抛 PHP 异常，不 panic；`RequestArena.init()` 返回 `?*` | Zig 单测 + `test_all.php` |
| 3 | 内存可观测 | 框架自身 `c_allocator` 全部经 `memtrack` 记账；`Arena.usage()`/`peak()` 可断言归零；INI 限额默认参与 `memory_limit` 额度 | Zig 单测 + `test_all.php` |
| 4 | 崩溃可定位 | fork 隔离 + 信号检测 | `test_crash.php` |
| 5 | 请求生命周期兜底 | `Cleanup` + `RequestArena` 在 RSHUTDOWN 回收，含真实 bailout（longjmp）路径 | `test_bailout.php` |
| 6 | 线程模型无关 | 请求级状态 `threadlocal`（cleanup 注册表、arena 派生额度），进程级计数原子（memtrack），限额按请求从 INI 载入——ZTS 与 NTS 行为一致 | Zig 单测（线程隔离用例）+ CI 矩阵 |
| 7 | 版本 / 平台适配 | 不硬编码 PHP 版本常量：`ZEND_MODULE_API_NO`、`ZEND_ACC_*`、`sizeof(zend_internal_arg_info)` 由 C glue 编译期取自 PHP 头文件 | CI 矩阵 PHP 8.2~8.5 |
| 8 | 逃生路径 | 骨架未覆盖的 Zend API，下游可自建 C glue，与内置 glue 同机制共存 | [`tutorial.md`](tutorial.md) |

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

## 二、骨架不负责

| # | 项 | 为什么骨架不管 | 下游该做什么 |
|:--:|---|---|---|
| 1 | 下游自己的 `c_allocator` / 裸 malloc | `memtrack` 只覆盖框架内部的分配，下游调用点骨架看不见 | 优先用 `RequestArena`；确需裸分配则自行记账 |
| 2 | Zig 侧自开线程 | 这类线程没有 RINIT/RSHUTDOWN，也拿不到请求上下文——与 ZTS/NTS 无关，是通用约束 | 需要的数据显式传入或走 IPC；线程内不要用 `RequestArena`/`Cleanup` |
| 3 | 绕过 `PhpType` 的取参 | 骨架提供弱转换 API，拦不住 `isLong() else 0` 这类写法 | 用 `toLong()`/`toDouble()`/`asString()`；要约束就声明 `Args`/`ArgTypes` |
| 4 | 跨请求 / 跨进程存活的指针 | MINIT 期持久内存、opcache 共享内存上的 `op_array`/`class_entry` 挂 Zig 指针会跨请求甚至跨进程悬垂 | 只在请求生命周期内持有 Zend 结构指针 |
| 5 | PHP 侧内存（ZendMM 池） | 由引擎管理；骨架只在 arena 侧参与额度核算 | 用 `memory_get_usage()` 观测 |
| 6 | 请求内改限额的进程可见性 | 限额配置是进程级的，请求内 `configure()` 对其余请求线程同样生效，且会锁定使后续 INI 载入不再覆盖 | 限额在 INI/启动期定好 |
| 7 | 部署环境策略 | 骨架给 `usage()`/`peak()`，不做 cgroup 感知、水位告警、OOM 降级 | 基于 `usage()`/`peak()` 自行实现 |
| 8 | Valgrind / 长跑审计 | 非实时、依赖环境；骨架侧已有归零断言 | 归下游（含下游自己的裸分配） |
| 9 | 参数个数校验 | 内部函数少参不抛 `ArgumentCountError`，由 handler 判断——当前行为特征 | handler 内用 `callNumArgs()` 判断并 `Throw` |
| 10 | 返回值移交之后的生命周期 | `returnString`/`returnZval` 之后所有权归引擎 | 不缓存已移交的 zval 指针 |

## 三、下游自查

1. 请求级内存：自己的裸分配是否换成 `RequestArena`，或已自行记账。
2. 泄漏探针：循环 5 万次后断言内存增量 < 64KB（模板见 `example/tests/test_all.php`
   的内存增长探针段，含反向验证控制组）。
3. 归零断言：请求结束后 `Arena.usage()` 回到基线。
4. bailout 模板：`example/tests/test_bailout.php`，三组对照（正常返回 / Zig 侧 E_ERROR /
   回调内 E_USER_ERROR），可照搬成自己扩展的回归用例。
5. 语料矩阵：新函数补进 `test_corpus.php`，保证任意类型不崩溃。
6. 自建 C glue：见 [`tutorial.md`](tutorial.md) 逃生路径。
