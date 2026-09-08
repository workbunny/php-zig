<?php
/**
 * php-zig benchmark 测量脚本
 *
 * 用法 1: php bench.php <mode> [iters] [rounds]
 *     测量单个实现，输出 TSV（mode<TAB>case<TAB>ns/op，取中位数）
 *   mode 取值：
 *     pure_php   —— 纯 PHP baseline（require 引入实现，无需加载扩展）
 *     bench_zig / bench_c —— 对应扩展（需通过 -d extension= 在启动时加载）
 *
 * 用法 2: php bench.php --summary <file>   汇总 TSV 为 markdown 对比表
 */

// ---- 汇总模式 ----
if (($argv[1] ?? '') === '--summary') {
    summary($argv[2] ?? 'results.tsv');
    exit(0);
}

$mode  = $argv[1] ?? 'pure_php';
$iters = (int)($argv[2] ?? 1000000);
$rounds = (int)($argv[3] ?? 5);

// ---- 纯 PHP baseline：仅在 pure_php 模式 require，避免与扩展同名函数冲突 ----
if ($mode === 'pure_php') {
    require __DIR__ . '/pure_php.php';
}

// ---- 三侧共享的辅助函数 ----
// fiber 用例需要：zend_fiber_create 非公开 API，故 zig / C 两侧都改为
// 经 PHP 函数创建 Fiber，才能与纯 PHP 侧走同一条路径对比。
if (!function_exists('bench_fiber_body')) {
    function bench_fiber_body() { Fiber::suspend(); }
}
if (!function_exists('bench_make_fiber')) {
    function bench_make_fiber($callable) { return new Fiber($callable); }
}

// 方法调用用例的被测类：三侧共用同一个类，测的才是同一条方法调用路径。
// 不能拿 stdClass 顶替——它没有目标方法，扩展侧会直接抛 Error 而非静默失败。
if (!class_exists('BenchObj')) {
    class BenchObj {
        public function method() { return 1; }
    }
}
$BENCH_OBJ = new BenchObj();

// ---- 用例表 ----
// 直接调用而非闭包包装：闭包会引入一层固定开销，把「扩展比纯 PHP 快 N 倍」
// 稀释成「快 M 倍」（N 越大稀释越严重），使相对结论失真。
//
// 数组/对象类用例传 100——单次调用的绝对耗时才有意义；
// math 传 1000 让循环体足够大以压过调用开销。
$cases = [
    'empty'           => ['fn' => 'bench_empty',        'args' => []],
    'add'             => ['fn' => 'bench_add',          'args' => [1, 2]],
    'concat'          => ['fn' => 'bench_concat',       'args' => ['hello', 'world']],
    'array_build(100)' => ['fn' => 'bench_array_build', 'args' => [100]],
    'array_read(100)' => ['fn' => 'bench_array_read',   'args' => [100]],
    'assoc(100)'      => ['fn' => 'bench_assoc',        'args' => [100]],

    // 复合类型 / 真实业务形态：同构数字数组只需 Z_LVAL_P，异构与嵌套才是常例
    'mixed(100)'      => ['fn' => 'bench_mixed',        'args' => [100]],
    'nested(100)'     => ['fn' => 'bench_nested',       'args' => [100]],
    'strkey(1000)'    => ['fn' => 'bench_strkey',       'args' => [1000]],
    'str_len'         => ['fn' => 'bench_str_len',      'args' => ['hello world']],
    'math(1000)'      => ['fn' => 'bench_math',         'args' => [1000]],
    'call_php(10)'    => ['fn' => 'bench_call_php',     'args' => [10]],
    'object(100)'     => ['fn' => 'bench_object',       'args' => [100]],
    'throw(10)'       => ['fn' => 'bench_throw',        'args' => [10]],

    // php-zig 特色能力
    'method(100)'     => ['fn' => 'bench_method',       'args' => [$BENCH_OBJ, 100]],
    'serialize(100)'  => ['fn' => 'bench_serialize',    'args' => [100]],
    'closure(100)'    => ['fn' => 'bench_closure',      'args' => [100]],
    'fiber(100)'      => ['fn' => 'bench_fiber',        'args' => [100]],
    // arena 是 php-zig 独有（RequestArena），纯 PHP 侧为不同语义的等量分配，
    // 故该项只看 zig 与 C 的对比，不要与 pure_php 横向比
    'arena(1000)'     => ['fn' => 'bench_arena',        'args' => [1000]],
];

// ---- 预热：触发函数解析、autoload、JIT（如开启） ----
foreach ($cases as $c) {
    for ($i = 0; $i < 10000; $i++) { $c['fn'](...$c['args']); }
}

// ---- 测量：多轮取中位数 ----
// 单轮结果受调度抖动影响可达数倍，中位数比平均值稳健（不受个别毛刺拉高）。
foreach ($cases as $name => $c) {
    $samples = [];
    for ($r = 0; $r < $rounds; $r++) {
        $start = hrtime(true);
        for ($i = 0; $i < $iters; $i++) { $c['fn'](...$c['args']); }
        $samples[] = (hrtime(true) - $start) / $iters;
    }
    sort($samples);
    $median = $samples[intdiv(count($samples), 2)];
    printf("%s\t%s\t%.2f\n", $mode, $name, $median);
}

// ---- 汇总：TSV -> markdown 转置表 + 相对纯 PHP 的加速比 ----
function summary(string $file): void {
    $rows = file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if ($rows === false || count($rows) === 0) {
        fwrite(STDERR, "summary: 无数据（{$file} 为空或不存在）\n");
        exit(1);
    }
    $data = [];
    $modes = [];
    $cases = [];
    foreach ($rows as $line) {
        $parts = explode("\t", $line);
        if (count($parts) < 3) { continue; }
        [$mode, $case, $ns] = $parts;
        $data[$case][$mode] = (float)$ns;
        if (!in_array($mode, $modes, true)) { $modes[] = $mode; }
        if (!in_array($case, $cases, true)) { $cases[] = $case; }
    }

    echo '| 用例 | ' . implode(' | ', $modes) . " |\n";
    echo '|' . str_repeat('---|', count($modes) + 1) . "\n";
    foreach ($cases as $case) {
        echo "| $case";
        foreach ($modes as $mode) {
            $ns = $data[$case][$mode] ?? null;
            echo ' | ' . ($ns === null ? '-' : sprintf('%.2f ns/op', $ns));
        }
        echo " |\n";
    }

    // 相对 C 扩展的开销比：php-zig 应贴近 1.00x
    if (in_array('bench_c', $modes, true) && in_array('bench_zig', $modes, true)) {
        echo "\n| 用例 | zig / C 开销比 |\n|---|---|\n";
        foreach ($cases as $case) {
            $c = $data[$case]['bench_c'] ?? null;
            $z = $data[$case]['bench_zig'] ?? null;
            if ($c === null || $z === null || $c == 0) { continue; }
            printf("| %s | %.2fx |\n", $case, $z / $c);
        }
    }
}
