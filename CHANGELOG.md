# Changelog

php-zig 的版本变更记录。从 0.11.0 起维护。

> 版本约定见 [`doc/compat.md`](doc/compat.md)：在 0.x 基础上，**z 版本
> 发布不破坏 API**（`0.11.0 → 0.11.1` 兼容）；**y 版本可能破坏 API**
> （`0.11 → 0.12` 需查本节）。变更均以本节为准。

## [0.11.1] - 2026-09-09

> z 版本发布，不破坏 API。本轮无任何删除或签名变更，新增项均为加法
> （`ErrorType.fatal`、`Arena.effectiveLimit()`、`php_config.ztsMode()`、
> `Arena.configure()` 的仲裁语义）。
>
> 兼容性说明：`ErrorType` 新增枚举成员——对 `ErrorType` 做**穷举 switch**
> 的下游代码需补 `.fatal` 分支（该类型通常只作为 `docref` 的入参使用）。

### 真实 bailout（longjmp）兜底验证

- **新增 `example/tests/test_bailout.php`**：框架此前多处声称「bailout-safe / RSHUTDOWN 兜底」，
  但只在 Zig 单测里用手动 `Cleanup.flush()` **模拟**过，真实 longjmp 路径从未验证。
  新测试用 fork 子进程触发真实 bailout（Zig 侧 E_ERROR / PHP 回调内 E_USER_ERROR），
  靠 marker 文件回传观察点，并带**正常返回对照组**——否则「held 字节数很大」
  无法与 arena 内部开销区分，断言就没有判别力。
- **验证结论**：真实 longjmp 下 `Cleanup` 仍按 LIFO 执行、`RequestArena` 仍被回收
  （MSHUTDOWN 全局计数归零），`defer` 被跳过这一风险点确实被兜住。
- CI 接入该步骤（此前 bailout 路径完全在测试体系外）。
- 新增测试扩展函数 `hello_bailout_probe`（**仅测试扩展内**，不是框架 API）。

### ZTS 兼容（请求级状态线程局部化）

- PHP 侧已吃掉 ZTS/NTS 的差异（扩展拿到的 `execute_data`、zval、`EG()`/`PG()` 都是
  当前请求线程的），扩展层只需保证自己的状态不跨线程串。此前 cleanup 注册表与
  arena 核算状态是进程级全局，ZTS 下请求 A 的 cleanup 条目会被请求 B 的 RSHUTDOWN 执行。
- 请求级状态改 `threadlocal`：`cleanup.entries`/`len`、`arena` 的 `effective_limit`/
  `since_check`。NTS 下只有主线程，与普通全局等价，两种构建行为一致。
- 进程级状态保持全局：`memtrack` 的 `usage`/`peak`（跨线程累加才是「进程占多少」的正确
  语义）、限额配置、PHP 探针函数指针（MINIT 后只读）。
- 限额改由 **RINIT** 从 INI 载入（原先在 MINIT）：INI 值可被 perdir 机制按请求改变，
  且 ZTS 下 PG 每请求线程一份，只在 MINIT 读会让其它请求线程一直用默认额度。
- **显式 `configure()` 优先于 INI**：RINIT 的载入会覆盖下游在 MINIT 设的限额，
  使其静默失效。故 `configure()` 调用后即锁定，`configureFromIni()` 不再覆盖。
  回归用例见 `test_all.php`「显式 configure 不被 INI 载入覆盖」。
- 新增 `php_config.ztsMode()`；新增回归用例「cleanup: 注册表线程隔离」。

### 责任边界声明

- **新增 [`doc/boundary.md`](doc/boundary.md)**：骨架负责 8 项 / 不负责 10 项 /
  下游自查 6 步，回答「出问题是谁的责任」。
- 已知缺口登记：非核心 API 的错误分支长尾、bailout 观测面只覆盖 `Cleanup`/`RequestArena`、
  ZTS 无自动化构建回归。

### API

- `ErrorType` 新增 `fatal`（E_ERROR）。glue 契约早已注明 E_ERROR 会 bailout，
  但 Zig 侧枚举缺失，此前只能用整型字面量。文档明确「调用后不会返回，`defer` 被跳过」。

### 文档

- README 新增「责任边界」章节、测试项同步（功能 200 / 崩溃 59 / 语料 312 / bailout 15）。
- `doc/api.md` 补 `.fatal` 语义；

---

## [0.11.0] - 2026-09-09

### 类型系统（v0.10.2 起的能力在 0.11.0 正式对外）

- **新增 `PhpType` 位掩码类型**：表达 `int|string` 这类联合类型，
  经 `createFromWith(name, handler, Args, ArgTypes)` 显式补齐。
  用法：`PhpType.string.unionWith(PhpType.long)`、`nullable()`、`callable`。
- **自动发现的编译期校验**：`pub fn php_<name>` 必须配套
  `<name>Args`（类型约束）或 `<name>Untyped = true`（故意无约束），
  否则编译错误。目的：防止「声明了类型约束却因命名不匹配静默失效」
  （历史上曾因此触发野指针崩溃）。
- **取值改官方弱转换**：`toLong()`/`toDouble()`/`toStringVal()` 等
  底层改用 `zval_get_long`/`zval_get_double`，`toStringVal` 非字符串
  返回空串（不再解引用野指针）。新增 `asString()` 区分空串与类型不符。
- **修复模块级函数 flags 恒为 0**：`resolveFlags`（含 `ZEND_ACC_HAS_TYPE_HINTS`）
  结果此前从未写入 `zend_function_entry.flags`。

### 测试体系（三件套）

- 新增 `example/tests/test_crash.php`：崩溃隔离（fork + 信号检测），59 项危险边界。
- 新增 `example/tests/test_corpus.php`：类型语料库矩阵（13 函数 × 24 语料），312 项。
- CI 接入三件套（此前只跑 `test_all.php`，崩溃防线在 CI 外）。

### 内存治理收敛

- 新增 `src/memtrack.zig`：框架全部 `c_allocator` 分配统一记账。
  `Arena.usage()`/`peak()` 现覆盖 arena 子分配 + 实例 + cleanup 注册表，
  可在测试中断言「RSHUTDOWN 后归零」检测框架自身泄漏。

### 破坏性变更（相对 v0.10.x）

- `pub fn php_<name>` 无参函数须加 `<name>Untyped = true`（0.10.2 起）。
- `Array.pop()`/`shift()` 返回 `?Zval` → out-param 形态 `pop(*T.Zval) bool`。
- `RequestArena.init()` 返回 `?*RequestArena`（OOM 抛异常，不再 panic）。
- `addArgs` 类参数 struct 建议用 `i64`/`[]const u8` 等具体类型代替
  `*T.Zval`（否则无类型约束，PHP 不做隐式转换）。

### 文档

- 新增 `doc/compat.md`：版本兼容性约定。
- `doc/api.md` / `doc/tutorial.md` / `doc/special.md` 同步本轮全部 API 变更。

---

## 版本约定速查

| 0.x 段 | 语义 |
|---|---|
| `0.y.z` 的 **z** | 发布不破坏 API（bugfix / 内部重构） |
| `0.y` 的 **y** | 可能破坏 API（破坏性变更见本节对应版本条目） |
| `0.x` 全部 | 暂不承诺 1.x 稳定性，迁移以本节为准 |
