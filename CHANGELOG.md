# Changelog

php-zig 的版本变更记录。从 0.11.0 起维护。

> 版本约定见 [`doc/compat.md`](doc/compat.md)：在 0.x 基础上，**z 版本
> 发布不破坏 API**（`0.11.0 → 0.11.1` 兼容）；**y 版本可能破坏 API**
> （`0.11 → 0.12` 需查本节）。变更均以本节为准。

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
- `PROJECT.md` 待办精简归档。

---

## 版本约定速查

| 0.x 段 | 语义 |
|---|---|
| `0.y.z` 的 **z** | 发布不破坏 API（bugfix / 内部重构） |
| `0.y` 的 **y** | 可能破坏 API（破坏性变更见本节对应版本条目） |
| `0.x` 全部 | 暂不承诺 1.x 稳定性，迁移以本节为准 |
