<?php
/**
 * 类型语料库矩阵测试 —— 系统性验证「任意类型 × 任意 API」不崩溃
 *
 * 与 test_crash.php 的分工：
 *   test_crash.php  手动选择的危险边界（循环引用、魔术方法、畸形序列化）
 *   test_corpus.php 自动枚举的笛卡尔积（N 个代表值 × M 个核心函数）
 *
 * 断言只有一条：**不崩溃**（fork 隔离下崩溃即信号）。返回值正确性由
 * test_all.php 的功能断言覆盖，这里只验证「弱类型 PHP 传入任何值都不该
 * 弄死进程」——这是 php-zig 作为扩展框架的底线承诺。
 *
 * 语料取 PHP 全部基础类型的代表值，含边界与极端值。
 */

$passed = 0;
$failed = 0;
$skipped = 0;

if (!function_exists('pcntl_fork')) {
    echo "pcntl 不可用，跳过语料库测试\n";
    exit(0);
}

/** 语料库：PHP 各类型的代表值 */
function corpus(): array {
    $res = fopen('php://memory', 'r');
    return [
        'null'          => null,
        'false'         => false,
        'true'          => true,
        'int 0'         => 0,
        'int -1'        => -1,
        'int PHP_INT_MAX' => PHP_INT_MAX,
        'int PHP_INT_MIN' => PHP_INT_MIN,
        'float 1.5'     => 1.5,
        'float INF'     => INF,
        'float NAN'     => NAN,
        'string 空'     => '',
        'string 数字'   => '123',
        'string 非数字' => 'abc',
        'string 长(1MB)' => str_repeat('x', 1048576),
        'string 二进制' => "\x00\x01\x02\xff",
        'string UTF-8'  => '中文测试🙂',
        'array 空'      => [],
        'array 数字'    => [1, 2, 3],
        'array 混合'    => [1, 'a', 1.5, null, [2]],
        'array 深层'    => [[[[[1]]]]],
        'object stdClass' => new stdClass,
        'object __toString' => new class { public function __toString(): string { return 's'; } },
        'closure'       => fn() => 1,
        'resource'      => $res,
    ];
}

/** 被测试的核心函数（覆盖数值/字符串/数组/序列化/混合参数）。
 *  [fn, 参数个数]：单参传 (val)，双参传 (val, 1)——第二参用正常值，
 *  避免两个危险值叠加，同时覆盖「双参之一正常」的常见调用形态。 */
function coreFuncs(): array {
    return [
        'add'              => [fn($a, $b) => add($a, $b), 2],
        'hello_name'       => [fn($a) => hello_name($a), 1],
        'hello_concat'     => [fn($a, $b) => hello_concat($a, $b), 2],
        'hello_sum'        => [fn($a, $b) => hello_sum($a, $b), 2],
        'hello_divide'     => [fn($a, $b) => hello_divide($a, $b), 2],
        'hello_pop'        => [fn($a) => hello_pop($a), 1],
        'hello_sum_all'    => [fn($a) => hello_sum_all($a), 1],
        'hello_iterate'    => [fn($a) => hello_iterate($a), 1],
        'hello_serialize'  => [fn($a) => hello_serialize($a), 1],
        'hello_unserialize' => [fn($a) => hello_unserialize($a), 1],
        'hello_zip'        => [fn($a, $b) => hello_zip($a, $b), 2],
        'hello_object'     => [fn($a) => hello_object($a), 1],
        'Calculator::add'  => [fn($a, $b) => Calculator::add($a, $b), 2],
    ];
}

/**
 * fork 隔离单次调用。返回：'ok'（不崩溃）/ 崩溃信号名。
 * 子进程内任何输出与异常都不向外传——只报告「崩没崩」。
 */
function isolatedCall(callable $fn): string {
    $pid = pcntl_fork();
    if ($pid === 0) {
        ob_start();
        try {
            $fn();
        } catch (\Throwable $e) {
            // 异常不算崩溃（PHP 的可预期行为），吞掉
        }
        ob_end_clean();
        exit(0);
    }
    pcntl_waitpid($pid, $status);
    if (pcntl_wifexited($status)) return 'ok';
    if (pcntl_wifsignaled($status)) {
        $sig = pcntl_wtermsig($status);
        return match ($sig) { 11 => 'SEGV', 6 => 'ABRT', 4 => 'ILL', default => "SIG$sig" };
    }
    return 'unknown';
}

// ============================================================
// 主循环：函数 × 语料 笛卡尔积
// ============================================================
$c = corpus();
$funcs = coreFuncs();

echo "=== 类型语料库矩阵（" . count($funcs) . " 函数 × " . count($c) . " 语料）===\n";

$worst = [];
foreach ($funcs as $fname => [$f, $arity]) {
    foreach ($c as $cname => $val) {
        $call = $arity === 1
            ? isolatedCall(fn() => $f($val))
            : isolatedCall(fn() => $f($val, 1)); // 双参：第二参用正常值
        if ($call === 'ok') {
            $passed++;
        } else {
            $failed++;
            $worst[] = "$fname × $cname => $call";
        }
    }
}

echo "\n矩阵结果：通过 {$passed}，崩溃 {$failed}\n";
if ($worst) {
    echo "崩溃明细：\n";
    foreach ($worst as $w) echo "  ✗ $w\n";
    echo "有崩溃项！\n";
    exit(1);
}
echo "全部通过：任意类型 × 核心 API 均不崩溃\n";
