<?php
/**
 * 冒烟检查：确认扩展已加载且全部用例函数已注册、返回值符合预期。
 *
 * 用法：php -d extension=<ext.so> smoke.php bench_zig|bench_c|pure_php
 *
 * bench.php 只输出 TSV，函数缺失时会静默产出空结果——本脚本用于在此之前
 * 拦截「扩展没加载 / 函数没注册 / 语义与另两方不一致」这三类问题。
 */
/**
 * 期望值「跳过精确校验」标记。
 * 不能用 null —— bench_empty 的合法返回值就是 null，会被误判为跳过。
 */
const SKIP = "\0SKIP";

$mode = $argv[1] ?? 'pure_php';
if ($mode === 'pure_php') {
    require __DIR__ . '/pure_php.php';
}

// 三侧共享的被测类与辅助（须早于 $expect 定义，因为数组字面量会实例化它）
if (!class_exists('BenchObj')) {
    class BenchObj { public function method() { return 1; } }
}
if (!function_exists('bench_fiber_body')) {
    function bench_fiber_body() { Fiber::suspend(); }
}
if (!function_exists('bench_make_fiber')) {
    function bench_make_fiber($callable) { return new Fiber($callable); }
}

// [函数名, 参数, 期望返回值]
$expect = [
    'bench_empty'       => [[], null],
    'bench_add'         => [[1, 2], 3],
    'bench_concat'      => [['hello', 'world'], 'helloworld'],
    'bench_array_build' => [[100], 100],
    'bench_array_read'  => [[100], 4950],   // 0+1+...+99
    'bench_assoc'       => [[100], 4950],
    'bench_str_len'     => [['hello world'], 11],
    'bench_math'        => [[1000], SKIP],  // 值随实现无关，只校验非空
    'bench_call_php'    => [[10], 50],      // 10 次 strlen("hello") = 5*10
    'bench_object'      => [[100], 4950],
    'bench_throw'       => [[10], 10],

    // 复合类型用例。期望值不写死：三侧必须一致即可，写死反而会因
    // 类型转换细节（如 string->int 的截断规则）产生无谓的分歧。
    'bench_mixed'       => [[300], SKIP],
    'bench_nested'      => [[100], 19800],   // Σ(i*4), i=0..99 = 4*4950
    'bench_strkey'      => [[1000], 31020],  // 15 轮 Σ0..63 + Σ0..39 = 30240+780

    // 特色能力用例
    'bench_method'      => [[new BenchObj(), 100], 100],
    'bench_serialize'   => [[100], SKIP],       // 长度随序列化格式，只校验非零
    'bench_closure'     => [[100], 100],
    'bench_fiber'       => [[100], 100],
    'bench_arena'       => [[1000], 64000],     // 1000 × 64 字节
];

$fail = 0;
foreach ($expect as $fn => [$args, $want]) {
    if (!function_exists($fn)) {
        printf("  MISSING  %s\n", $fn);
        $fail++;
        continue;
    }
    $got = $fn(...$args);
    if ($want === SKIP) {
        // 只校验「非空」，用于值依赖实现细节的用例
        $ok = ($got !== 0 && $got !== '' && $got !== '0');
        printf("  %s %-18s => %s\n", $ok ? 'ok      ' : 'EMPTY  ', $fn, var_export($got, true));
        if (!$ok) { $fail++; }
        continue;
    }
    if ($got !== $want) {
        printf("  MISMATCH %-18s => got %s, want %s\n", $fn, var_export($got, true), var_export($want, true));
        $fail++;
    } else {
        printf("  ok       %-18s => %s\n", $fn, var_export($got, true));
    }
}

echo $fail === 0 ? "smoke: $mode 全部通过\n" : "smoke: $mode 有 $fail 项失败\n";
exit($fail === 0 ? 0 : 1);
