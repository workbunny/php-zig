# php-zig 性能与内存基准

对比 **php-zig / 原生 C / 纯 PHP** 在相同用例上的调用开销与内存占用。

## 对比对象

| 实现 | 模块名 | 定位 |
|------|--------|------|
| `php_zig/` | `bench_zig` | 主角 |
| `c_ext/` | `bench_c` | 理论下限 / 原生上限参照 |
| `pure_php`（内联） | — | baseline（解释执行） |

三实现对每个用例做**相同语义**，由 `smoke.php` 逐项校验返回值一致。

## 环境依赖

PHP 开发头文件（`php-config` + `php.h`）、可运行的 `php` CLI、Zig 0.16、gcc。

## 运行

```bash
cd benchmark
bash run.sh                    # 文档复现参数：性能 30 万次 × 5 轮，内存 200 次重复
bash run.sh 300000 5 200       # 显式指定（性能迭代 × 轮数 × 内存重复数）
PHP_SDK=/usr/local bash run.sh # 指定 PHP SDK（同 -Dphp）
ZIG=/path/to/zig bash run.sh   # 指定 zig（容器内常不在 PATH）
SKIP_BUILD=1 bash run.sh       # 跳过编译，只测量（交叉编译产物已在位时）
```

不带参即文档复现参数，本节所有结论都以此为准。

两个迭代数**语义不同、量级差三个数量级，不可互换**：

| 参数 | 作用 | 默认 |
|------|------|------|
| `iters` | `bench.php`：每次调用处理一条数据，重复次数 | 300000 |
| `mem_iters` | `memory.php`：用例重复次数，**单次调用固定处理 10 万级数据** | 200 |

产物写入 `results.tsv`（性能）与 `memory.tsv`（内存），均已 gitignore。

校验单个实现（扩展是否加载、函数是否注册、语义是否与另两方一致）：

```bash
php -d extension=php_zig/zig-out/lib/libbench_zig.so smoke.php bench_zig
php -d extension=c_ext/bench_c.so                     smoke.php bench_c
php                                                   smoke.php pure_php
```

## 用例

### 微观开销

| 用例 | 语义 |
|------|------|
| `empty` | 空函数返回 null |
| `add` | 两整数相加 |
| `concat` | 字符串拼接 |
| `array_build(100)` | 建 100 元素数组 |
| `array_read(100)` | 建表 + 逐个读回求和 |
| `str_len` | 读字符串入参返回长度 |
| `math(1000)` | 纯算术循环（无 Zend 交互） |
| `call_php(10)` | 循环调用 PHP 函数 strlen |
| `throw(10)` | 抛异常 + 清理 |

### 复合类型 / 业务形态

同构数字数组只需 `Z_LVAL_P` 直读；真实业务数据是异构与嵌套的，
按类型分派与多层查找才是常例。

| 用例 | 语义 |
|------|------|
| `mixed(100)` | long / string / double 按 `i%3` 轮换，再逐个读回 |
| `nested(100)` | 100 行 × 单字段的嵌套数组，逐层查键 |
| `strkey(1000)` | 64 键字典的读密集访问（配置查找/字典场景） |
| `assoc(100)` | 关联数组写 + 读 |
| `object(100)` | stdClass 属性写 + 读 |

### php-zig 特色能力

| 用例 | 语义 |
|------|------|
| `method(100)` | 对传入对象调真实方法 |
| `serialize(100)` | PHP serialize |
| `closure(100)` | 创建 PHP Closure 并调用 |
| `fiber(100)` | 创建 Fiber |
| `arena(1000)` | `RequestArena` 连续分配、末尾统一释放（Zig 侧内存，见下） |

## 测量方法

- 进程内 `hrtime(true)`，**多轮取中位数**（默认 5 轮）。单轮受调度抖动影响可达数倍。
- 测量前预热 1 万次（触发函数解析、autoload 等一次性开销）。
- **直接调用而非闭包包装**：闭包引入固定开销，且差距越大稀释越严重。
- **不绑核**：负载不为空的机器上 `taskset -c 0` 会把进程按在被争抢的核上
  （实测 real 达 user 的 3 倍、同用例慢 3 倍），抖动交给多轮取中位数吸收。
- php-zig 必须 `-Doptimize=ReleaseFast`：Debug 比 C 的 `-O2` 慢 1.3~5 倍。
- CLI 默认 JIT 关闭，扩展函数不受 JIT 影响（JIT 无法跨扩展边界优化）。

内存基准另有三条：

- 数据量放大到 **10 万级**（`memory.php` 内 `$SIZE`，与 `mem_iters` 无关）：
  小数据量单次分配仅数 KB，会淹没在数百 KB 基线里，各方案测出同一值、对比失效。
- RSS 取**循环内多次采样的最大增量**：ZendMM 会把空 chunk 还给 OS，
  只看「末值 − 初值」会得到负数。
- 测 **baseline**（扩展加载后的固定开销）：数据结构层面三方案操作同一套
  zval/HashTable，差别只可能来自框架自身占了多少。

## 性能结论

PHP 8.4.19 (NTS) / Linux / 30 万次迭代 × 5 轮取中位数（zig 侧经 7 轮复核），
`zig / C` 开销比：

| 用例 | 比值 | 用例 | 比值 |
|---|---:|---|---:|
| empty | 0.96x | str_len | 1.06x |
| add | 1.10x | math(1000) | 0.97x |
| concat | 1.15x | call_php(10) | 1.09x |
| array_build(100) | 1.17x | object(100) | 0.74x |
| **array_read(100)** | **1.41x** | throw(10) | 1.06x |
| assoc(100) | 0.70x | method(100) | 1.19x |
| mixed(100) | 0.89x | serialize(100) | 1.08x |
| nested(100) | 1.18x | closure(100) | 0.94x |
| strkey(1000) | 0.75x | fiber(100) | 0.99x |
| | | arena(1000) | 0.69x |

1. **调用分发与纯计算已达原生水准**：`empty` 0.96x、`math` 0.97x、
   `closure` 0.94x、`fiber` 0.99x、`arena` 0.69x。
2. **复合类型场景多数优于 C**：`strkey` 0.75x、`object` 0.74x、`assoc` 0.70x。
   这些差距来自两侧实现策略不同（键生成、属性访问路径），不代表 php-zig
   更快，但说明**无系统性劣势**。
3. **`array_read` 1.41x 是唯一明显短板**，且**只影响纯数字紧密循环**——
   换成混合类型的 `mixed` 反而 0.89x。

> 注：单用例跨轮波动可达 ±0.1x（容器调度抖动），结论看整体分布而非单值。
> 最近的 v0.10.2 改动（取值弱转换、flags 传递）经实测**零性能影响**——
> 弱转换对 IS_LONG 快路径是 inline 直读，benchmark 参数均为 mixed 不触发
> HAS_TYPE_HINTS 运行时检查。

### `array_read` 的 1.41x

根因是跨 ABI 调用次数：

```
php-zig:  zval_get_array → hash_index_find → zval_get_long   （3 次 extern）
原生 C:   zend_hash_index_find + Z_LVAL_P（内联宏）            （1 次）
```

三条解法与代价：

| 解法 | 代价 |
|---|---|
| 接受 1.41x（**推荐**） | 无。跨语言框架在紧密循环付 1.4x~1.5x 是正常量级 |
| 加复合 API（一次调用完成查+取） | 违反「不为 benchmark 做特异化优化」铁律 |
| Zig 侧直接操作 `zend_array` 布局 | 违反「版本差异隔离在 C 层」的架构原则 |

## 内存结论

PHP 8.4.19 / Linux / 单次 10 万级数据：

| 维度 | bench_zig | bench_c | pure_php |
|---|---:|---:|---:|
| baseline（PHP 池） | 625.3 KB | 625.3 KB | 641.0 KB |
| baseline（进程 RSS） | 49.5 MB | 47.0 MB | 46.7 MB |
| 各用例峰值 | 与 C **完全相同** | 同左 | 与 C 相同（`nested` 更省） |
| `arena` RSS | **8.0 KB** | 852.0 KB | 0 B |

1. **数据结构层面零开销**：所有用例的峰值与稳态持有量同原生 C **完全相同
   （1.00x）**。三方案操作同一套 PHP 数据结构，php-zig 未引入任何 per-op 额外内存。
2. **框架自身开销与 C 持平**：PHP 池内 baseline 完全相同，且**低于纯 PHP**
   （PHP 函数定义本身也占内存）。
3. **RSS 高约 2.4 MB**：Zig 运行时与静态数据的固定成本，与请求量无关，
   长驻进程里是常数。
4. **`arena` 场景 php-zig 明显更省**（8 KB vs 852 KB）：`RequestArena` 按 chunk
   批量分配；原生 C 要实现同样的「末尾统一释放」需额外维护 N 个指针。

### 三维度不一致是有价值的信息

`arena` 在 PHP 池里是 0——`RequestArena` 的 backing 是 `c_allocator`，
**不进 PHP 内存池**：好处是大块临时内存不触发 `memory_limit`，
代价是 PHP 的 `memory_limit` 看不见它，只有 RSS 能反映真实占用。

**这块的治理已落地**：框架提供进程级原子计数与 INI 限额，并**默认参与
`memory_limit` 额度核算**——即 arena 不再能悄悄吃掉池外内存，超限按 reject
语义返回 `error.OutOfMemory`。

```ini
phpzig.arena_limit = 0              ; 字节，0 = 不以此项限制
phpzig.arena_account_to_php = 1     ; 参与 memory_limit 额度（默认开）
phpzig.arena_check_interval = 65536 ; 降频阈值，默认 64K
```

```zig
phpzig.Arena.usage();   // 当前 Zig 侧占用（跨全部 arena 实例）
phpzig.Arena.peak();    // 进程内峰值
```

降频检查的开销可忽略——本基准的 `arena` 用例在限额默认开启下仍为 **0.71x**。

容器感知（读 cgroup limit）与水位告警不在框架职责内，由下游基于
`usage()` / `peak()` 自行实现：php-zig 是骨架，不该替业务决定特定部署环境
下的内存策略。

## 已知限制

- 结果受 CPU/负载波动影响，跨机器对比绝对值无意义；只保证同机同轮相对比值可复现。
- `php_zig/build.zig.zon` 的 `fingerprint` 为占位值，首次 `zig build` 若报
  `invalid fingerprint`，`run.sh` 会自动修复。
- `method`/`closure` 的 C 侧与 php-zig 侧实现策略不同（键生成、闭包构造路径），
  绝对值受实现细节影响，看相对纯 PHP 的加速更有意义。
