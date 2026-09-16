# Changelog

php-zig 的版本变更记录。从 0.11.0 起维护。

> 版本约定见 [`doc/compat.md`](doc/compat.md)：在 0.x 基础上，**z 版本
> 发布不破坏 API**（`0.11.0 → 0.11.1` 兼容）；**y 版本可能破坏 API**
> （`0.11 → 0.12` 需查本节）。变更均以本节为准。

## [0.11.6] - 2026-09-16

> z 版本发布，无 API 变更：接入 `zig fmt` 格式门禁，行尾钉为 LF。

### 新增

- CI 增加 **`zig fmt --check` 格式门禁**（独立 job，只跑一次，不随 8 档矩阵重复）。
  门禁显式列路径而不用 `zig fmt .`，避免走到不入库的 `reference/` 与构建产物。
- `.gitattributes`：`* text=auto eol=lf`（二进制产物标 `binary`）。属性优先于 `core.autocrlf`，
  任何平台检出都是 LF。

### 变更

- 全仓 `.zig` / `.zon` 过一遍 `zig fmt`（10 个文件，纯排版，无逻辑变化）。
- 行尾钉 LF 的原因：`zig fmt` 要求 LF，CRLF 文件会被 `zig fmt --check` 判为未格式化。
  不钉死的话，Windows 侧以 `core.autocrlf=true` 检出会得到 CRLF 工作区，格式门禁对每个文件误报。

## [0.11.5] - 2026-09-15

> z 版本发布，无 API 变更：测试体系接入 ZTS 档与 FFI 隔离后端，并修掉四处假绿。

### 新增

- **FFI fork 隔离后端**（`example/tests/isolation.php`）：ZTS 构建不带 `pcntl`，改用 FFI 直调
  libc 的 `fork`/`waitpid`，状态字按 POSIX 宏在 PHP 侧解码。三套隔离件因此在 ZTS 下同样运行；
  后端顺序 `pcntl → ffi`，可用 `PZ_ISOLATE_BACKEND=pcntl|ffi` 强制指定。
- CI 矩阵扩为 **8.2 / 8.3 / 8.4 / 8.5 × NTS / ZTS 共 8 档**，每档都跑满四套件。
  ZTS 档显式启用 `ffi` 扩展（预编译 ZTS 构建默认不含），并加「校验隔离后端」步骤把各档钉到
  对应后端（NTS → pcntl，ZTS → FFI fork）。
- `envBrokenThrow()`：`Call to undefined function` / `Class "X" not found` / `Undefined constant`
  一律判为环境失败 —— 这类抛出证明的是「没跑到」，不是「没崩」。

### 修复

测试体系四处「假绿」，全部改为非绿：

- 崩溃套件在**扩展未加载**时报「通过 69 / 拒绝 0」并以 0 退出 —— 「不崩溃」断言把
  `Error: Call to undefined function` 当成了合格结果。三个套件现加扩展前置断言。
- **无隔离后端**时三套隔离件「打印跳过并 exit 0」→ 改为 exit 1；跳过计数纳入退出条件。
- **诊断回传被截断**（超 `ISOLATE_DIAG_MAX`）时分类不可信 → `forkIsolate()` 内直接失败退出。
- **Zig 单测收集 0 用例**（新模块漏在聚合入口登记）仍报成功 → CI 断言收集数非零。

### 测试

- 新增**用例数下界结构断言**：功能 239、崩溃 69、bailout 22；语料矩阵按「函数数 × 语料数」
  逐格核对。整段用例被删或未执行时不再静默通过。
- ZTS 实测（PHP 8.4.25 ZTS + FFI 后端）：单元 87 / 功能 239 / 崩溃 69 / 语料 432 / bailout 22 全绿。

### 文档

- README 新增「仓库结构」与「模块加载流程」，版本兼容章补交叉编译矩阵。
- `doc/special.md` 补齐实现决策小节；`doc/zen.md` 增加「评估后不做（技术原因）」表。
- README 能力表的测试用例数按实测校正（229 / 59 / 408 / 17 → 239 / 69 / 432 / 22）。

## [0.11.4] - 2026-09-14

> z 版本发布，无 API 变更：新增一个取值入口，既有取值语义一字未改。

### 新增

- `Zval.castString()`：`(string)$v` cast 语义，与 PHP 里写 `(string)$v` 同一条路径
  （`zval_try_get_string`）——`123`→`"123"`、`1.5`→`"1.5"`、`true`→`"1"`、`null`→`""`、
  resource→`"Resource id #N"`、array→`"Array"`（附 `E_WARNING`）、object 走 `__toString()`。
  结果持有新引用（须 `deinit()`）；返回 null = **转换失败且异常已抛**（对象无
  `__toString` 时 PHP 抛 `Error`），调用方须立即返回。
- `toLong()` / `toDouble()` / `toStringVal()` / `asString()` 语义与签名**不变**。

### 修复

- 崩溃隔离测试的退出码判据：致命错误退出（`exit=255`）此前被记成「通过」，
  现判拒绝 —— 致命退出不是「不崩溃」。
- 示例扩展的 cleanup 探针不再向 stderr 打印：诊断一律走显式回传通道，
  stderr 留给「意外」。

### 测试

- 新增 `example/tests/isolation.php`：三个隔离型测试共用。子进程内关闭 `log_errors` 与
  `display_errors`（`log_errors` 是唯一能穿透 `ob_start` 的通道），诊断经 socketpair
  回传后按坐标分类：该有的必须有、不该有的不能有。
- 诊断按坐标预先声明：数值 cast 位 × object = **21** 条、字符串 cast 位 × array = **4** 条
  （引擎的 int/float 转换与 Array to string conversion 警告），bailout B/C 组各 1 条探针
  Fatal error（本组断言对象）；其余诊断、致命退出、预期未命中一律拒绝。四套 `stderr` 为空。
- 新增 `hello_cast_string` 与 10 个崩溃用例；诊断白名单按用例声明（`$allowDiags`）。
- 语料预期表按 `PHP_VERSION_ID` 门控版本差异：8.5 起 `INF`/`NAN` → int 与 `(string)NAN`
  各多 1 条引擎警告，8.2–8.4 静默；未登记的新行为以「意外诊断」拒绝。
- 新增 `benchmark/report.sh` 与 `.github/workflows/benchmark.yml`：手动 / 每周产出性能报告
  （job summary + artifact，保留 90 天），复用 `run.sh`，发布前先过 `smoke.php` 三方语义校验，
  只在 zig/C 比值 >3x 时失败；报告口径与本地一致（比值优先，绝对值跨 run 不可比）。
- 判别力验证：抹掉一处 cast 位声明 / 虚报一处 / 抹掉 `cast-str` 规则，分别精确报出
  3 条意外 + 3 条未命中、4 条意外诊断。
- 规模：功能 229 → **239**，语料 408 → **432**（17 → 18 函数），崩溃隔离 59 → **69**，
  bailout **22**，Zig 单测 87 不变。

### 文档

- `boundary.md` 新增「取值语义：跟随 cast（操作符）语义，**不**模仿 ZPP」：ZPP 基准
  对照表、三条理由（缺上下文 / 内部实现细节会随版本漂移 / cast 语义精确可得）、代价，
  以及「要严格就声明 + handler 内显式校验」。
- `special.md` / `api.md`：arg_info 在 Release 不校验、`strict_types` 对 php-zig 函数
  不生效（8.2 与 8.4 一致）；并写明这是**有意**选择，不是待修的缺陷。

## [0.11.3] - 2026-09-14

> z 版本发布，无 API 变更。

### 修复

- **PHP 8.2/8.3 上只注册第一个模块函数**。函数表原先按 Zig 侧写死的 PHP 8.4 结构布局
  排布，与 8.2/8.3 的实际 stride 不符，引擎读到零值即判为表尾哨兵，注册在第 1 个
  函数之后终止。现改为裸字节缓冲 + 运行时 stride，布局与写入全部交给 C glue。
- **带参模块函数的参数内省段错误**（`ReflectionFunction('hello_concat')->getParameters()`
  在 PHP 8.4 上 SIGSEGV）。arg_info 缓冲区的分配游标由模块函数与类方法各自持有、
  都从 0 开始，后注册的一方覆盖前一方。现统一为容器级游标 `arginfo_cursor`，
  两侧顺序分配、互不重叠。
- MINIT 新增两条校验：函数表 stride 上限、`ZendModuleEntry` 与 C 侧 `sizeof` 一致；
  不符即 panic，不再静默少注册。

### 新增

- C glue：`phpglue_function_entry_size`、`phpglue_set_function_entry`、
  `phpglue_module_entry_size`。
- Zig：`FUNCTION_ENTRY_SIZE_MAX` 上限常量与容器级 `arginfo_cursor`；
  删除 Zig 侧 `ZendFunctionEntry` 结构定义，函数表指针改为不透明类型。

### 测试

- 新增注册完整性结构断言：模块函数名单（覆盖注册顺序首 / 中 / 尾）、类方法表
  （11 个类，含 0 方法类 / 接口 / struct 反射 / extends / extern struct 绑定）。
- 新增参数元信息双侧精确匹配（模块函数 + 类方法）、常驻额度超限拒绝、
  裸记账 API 对称归零（含漏 `trackFree` 的反向验证）。
- 修正 §28 一处假阳性：用户函数回调未触发时 `internal = false` 同样成立，
  改为断言计数增长。
- 语料矩阵纳入常驻级 / 非托管 / 裸记账入口：13 → **17** 函数 × 24 语料。
- 规模：功能 217 → **229**，语料 312 → **408**，Zig 单测 87 不变。

## [0.11.2] - 2026-09-11

> z 版本发布，不破坏 API。`RequestArena` 构造与用法不变，`Arena.usage()` / `peak()`
> 签名与语义不变。

### 新增

- `ResidentArena`：常驻级内存池，跨请求存活，MSHUTDOWN 回收，额度取
  `phpzig.resident_limit`（默认 0 = 不设防，不读 `memory_limit`）。
- `RequestArena` 与 `ResidentArena` 合并为泛型实现 `ArenaOf(scope)`，reject 判定只有一份。
- `ResidentArena.shared()` 进程级单例、`shutdown()`（幂等）、独立实例的 `destroy()`。
- `Memtrack.usageScope` / `peakScope` / `total`：request 与 resident 两套独立账本。
- `Memtrack.trackAlloc` / `trackFree`：裸记账原语，供框架看不见的指针注入观测。
- `arena.unsafeAllocator()`：非托管入口，返回裸 `c_allocator`；两个作用域均提供。
- INI `phpzig.resident_limit`（MINIT 读取）。

### 变更

- `memtrack` 按 scope 拆为两套原子计数；请求级限额判定只读请求级账本，
  常驻内存不挤占请求额度。
- 模块 MSHUTDOWN wrapper 改为无条件注册，用于释放常驻单例。
- `doc/boundary.md` 补充 unsafe 的责任边界：释放时机与 OOM 后果由下游自控。

### 测试

- Zig 单测 78 → **87**：scope 隔离、常驻限额 reject、常驻不随请求回收、`shared()` 幂等、
  unsafe 不记账不限额。
- 功能集成 201 → **213**（§31 常驻级与统一观测）。
- bailout 14 → **17**：新增「常驻级跨越请求存活」断言，与「请求级 MSHUTDOWN 归零」成对。
- 现有 8 个 arena 单测与全部既有集成用例未改动。

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

---

## [0.1 ~ 0.10] 能力归档

> 本文件自 0.11.0 起逐版本维护；此前版本无逐条记录，按「能力边界」归并归档于此。

| 版本 | 能力 |
|---|---|
| v0.1 ~ v0.7 | 骨架：C glue 层、comptime 模块注册、OOP（类 / 继承 / 接口 / 属性 / 访问修饰符）、闭包、struct 反射 arg_info、错误报告 |
| v0.8.0 | extern struct 对象绑定、INI、序列化、参数默认值 / 可变参数 |
| v0.9.x | 请求级 `RequestArena` + `Cleanup`（bailout-safe）、Fiber 协程、Observer 五类观察点、`Zval.incRef`/`separate`、`-Dphp` 平台识别、Windows DLL 定案 |
| v0.10.0 | 文档体系（`api` / `tutorial` / `zen` / `special`）+ README 能力矩阵 |
| v0.10.1 | Observer 补强（`funcInfo` / `callSite` / `fcall_filter`）、Zig 侧内存治理（进程级原子计数 + INI 限额 + 参与 `memory_limit` 额度）、三路性能与内存基准、下游自建 C glue 逃生路径 |
| v0.10.2 | 类型系统（`PhpType` 联合类型 + 编译期校验）、弱转换取值（消灭垃圾指针 UB）、模块级函数 `flags` 传递修复、测试三件套（崩溃隔离 + 语料矩阵）、`memtrack` 收敛框架全部 c_allocator 分配 |
