<?php
/**
 * php-zig 内存占用基准 —— 面向空间敏感场景
 *
 * 延迟不是唯一指标。批量处理、长驻进程、内存受限容器更关心
 * 「处理同样的数据占多少内存」。
 *
 * 用法：
 *   php memory.php <mode> [iters]          mode 同 bench.php
 *   php memory.php --summary <file>        汇总 TSV 为 markdown
 *
 * iters 是**用例重复次数**（默认 200），不是数据量：单次调用固定处理下面
 * $SIZE（10 万级）的数据。与 bench.php 的 iters 语义不同——那边每轮只处理
 * 一条数据，故量级差三个数量级，两者不可互换。
 *
 * 测三个维度（均为**相对基线增量**，绝对值含进程基线无意义）：
 *
 *   1. peak  用例执行期间的峰值增量 = reset 后的 peak - 执行前 usage
 *            体现临时分配策略：频繁分配大缓冲会推高峰值
 *   2. hold  执行结束且未触发 GC 时的持有量净增
 *            体现稳态持有；不为 0 通常意味着泄漏或缓存
 *   3. rss   进程驻留内存增量（/proc/self/statm）
 *            唯一能发现「内存不在 PHP 池里但占了物理内存」的视角
 *
 * 三个维度不一致是**有价值的信息**而非噪声：某实现 pool 很小但 rss 很大，
 * 说明它把内存转移到了 PHP 池之外（绕过 memory_limit，但也绕过了监控）。
 */

if (($argv[1] ?? '') === '--summary') {
    summary($argv[2] ?? 'memory.tsv');
    exit(0);
}

$mode  = $argv[1] ?? 'pure_php';
$iters = (int)($argv[2] ?? 200);

if ($mode === 'pure_php') {
    require __DIR__ . '/pure_php.php';
}

// 与 bench.php 一致的共享辅助
if (!function_exists('bench_fiber_body')) {
    function bench_fiber_body() { Fiber::suspend(); }
}
if (!function_exists('bench_make_fiber')) {
    function bench_make_fiber($callable) { return new Fiber($callable); }
}
if (!class_exists('BenchObj')) {
    class BenchObj { public function method() { return 1; } }
}
$BENCH_OBJ = new BenchObj();

/**
 * 用例表。
 *
 * 与 bench.php 的关键差异：**单次调用处理的数据量要大得多**。
 * 内存基准若沿用性能基准的小数据量（如 100 元素数组），单次分配只有几 KB，
 * 会完全淹没在数百 KB 的进程基线里，三个方案测出来都是同一个基线值，
 * 对比毫无意义。故这里放大到 10 万级，让分配量级远大于基线。
 */
$SIZE  = 100000;
$cases = [
    'array_build'   => ['fn' => 'bench_array_build', 'args' => [$SIZE]],
    'array_read'    => ['fn' => 'bench_array_read',  'args' => [$SIZE]],
    'assoc'         => ['fn' => 'bench_assoc',       'args' => [$SIZE]],
    'mixed'         => ['fn' => 'bench_mixed',       'args' => [$SIZE]],
    'nested'        => ['fn' => 'bench_nested',      'args' => [$SIZE]],
    'strkey'        => ['fn' => 'bench_strkey',      'args' => [$SIZE]],
    'object'        => ['fn' => 'bench_object',      'args' => [$SIZE]],
    'concat'        => ['fn' => 'bench_concat',      'args' => [str_repeat('a', $SIZE), str_repeat('b', $SIZE)]],
    'serialize'     => ['fn' => 'bench_serialize',   'args' => [$SIZE]],
    'closure'       => ['fn' => 'bench_closure',     'args' => [$SIZE]],
    'arena'         => ['fn' => 'bench_arena',       'args' => [$SIZE]],
];

/** 读 /proc/self/statm 的驻留页数 -> 字节。无 /proc 时返回 -1。 */
function rssBytes(): int {
    $statm = @file_get_contents('/proc/self/statm');
    if ($statm === false) { return -1; }
    $parts = preg_split('/\s+/', trim($statm));
    if (!$parts || count($parts) < 2) { return -1; }
    return ((int) $parts[1]) * 4096;   // 第 2 字段是 resident 页数
}

$hasPeakReset = function_exists('memory_reset_peak_usage');

// 预热：让请求池、类、函数表达到稳态，避免把一次性分配计入
foreach ($cases as $c) {
    for ($i = 0; $i < 3; $i++) { $c['fn'](...$c['args']); }
}
gc_collect_cycles();

// baseline：扩展自身的固定开销（模块注册、函数表、arg_info 等）。
//
// 这是唯一能体现框架差异的维度——数据结构层面三方案操作的是同一套
// zval/HashTable，内存占用必然相同；差别只可能来自框架自身占了多少。
// 纯 PHP 模式无扩展，其 baseline 即「零框架开销」参照。
printf("%s\t%s\t%d\t%d\t%d\n", $mode, 'baseline', memory_get_usage(), memory_get_usage(), rssBytes());

foreach ($cases as $name => $c) {
    gc_collect_cycles();

    // peak 是进程级累计值，不重置就读到历史峰值而非本用例的峰值
    if ($hasPeakReset) { memory_reset_peak_usage(); }

    $usageBefore = memory_get_usage();
    $rssBefore   = rssBytes();

    // RSS 只增不减并不成立：ZendMM 在 chunk 全空时会把内存还给 OS，
    // 故只看「末值 - 初值」会得到负数。改为循环内多次采样取最大增量，
    // 这样测到的是真实达到过的水位。
    $rssPeakDelta = 0;
    $sampleEvery  = max(1, intdiv($iters, 10));
    for ($i = 0; $i < $iters; $i++) {
        $c['fn'](...$c['args']);
        if ($i % $sampleEvery === 0 && $rssBefore >= 0) {
            $r = rssBytes();
            if ($r >= 0) { $rssPeakDelta = max($rssPeakDelta, $r - $rssBefore); }
        }
    }

    $usageAfter = memory_get_usage();
    $rssAfter   = rssBytes();

    // 峰值增量：本用例执行期间达到的最高水位，相对执行前用量
    $peak = $hasPeakReset
        ? memory_get_peak_usage() - $usageBefore
        : -1;

    printf("%s\t%s\t%d\t%d\t%d\n",
        $mode, $name,
        max(0, $peak),                                  // peak 增量
        $usageAfter - $usageBefore,                     // hold 净增
        $rssBefore < 0 ? -1 : $rssPeakDelta             // RSS 最大增量
    );
}

function summary(string $file): void {
    $rows = file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if (!$rows) {
        fwrite(STDERR, "summary: 无数据（{$file} 为空或不存在）\n");
        exit(1);
    }
    $data = []; $modes = []; $cases = [];
    foreach ($rows as $line) {
        $p = explode("\t", $line);
        if (count($p) < 5) { continue; }
        [$mode, $case, $peak, $hold, $rss] = $p;
        $data[$case][$mode] = [
            'peak' => (int) $peak,
            'hold' => (int) $hold,
            'rss'  => (int) $rss,
        ];
        if (!in_array($mode, $modes, true)) { $modes[] = $mode; }
        if (!in_array($case, $cases, true)) { $cases[] = $case; }
    }

    $fmt = function (int $v): string {
        if ($v < 0) { return '-'; }
        if ($v >= 1048576) { return sprintf('%.2f MB', $v / 1048576); }
        if ($v >= 1024)    { return sprintf('%.1f KB', $v / 1024); }
        return $v . ' B';
    };

    foreach (['peak' => '峰值增量', 'hold' => '稳态持有净增', 'rss' => '进程 RSS 增量'] as $k => $title) {
        echo "\n### {$title}（越低越好）\n\n";
        echo '| 用例 | ' . implode(' | ', $modes) . " |\n";
        echo '|' . str_repeat('---|', count($modes) + 1) . "\n";
        foreach ($cases as $case) {
            echo "| $case";
            foreach ($modes as $mode) {
                $v = $data[$case][$mode][$k] ?? -1;
                echo ' | ' . $fmt($v);
            }
            echo " |\n";
        }
    }

    // zig 相对 C 的内存比：<1 表示 php-zig 更省
    if (in_array('bench_c', $modes, true) && in_array('bench_zig', $modes, true)) {
        echo "\n### zig / C 内存比（<1.00 表示 php-zig 更省）\n\n";
        echo "| 用例 | peak | hold |\n|---|---|---|\n";
        // 两边同为 0 表示「都没持有」，属相同而非不可比
        $ratio = function (int $z, int $c): string {
            if ($z < 0 || $c < 0) { return '-'; }
            if ($c == 0) { return $z == 0 ? '1.00x (both 0)' : 'inf'; }
            return sprintf('%.2fx', $z / $c);
        };
        foreach ($cases as $case) {
            $zc = $data[$case]['bench_zig']['peak'] ?? -1;
            $cc = $data[$case]['bench_c']['peak'] ?? -1;
            $zh = $data[$case]['bench_zig']['hold'] ?? -1;
            $ch = $data[$case]['bench_c']['hold'] ?? -1;
            echo "| $case | {$ratio($zc, $cc)} | {$ratio($zh, $ch)} |\n";
        }
    }
}
