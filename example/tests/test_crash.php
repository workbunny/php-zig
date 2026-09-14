<?php
/**
 * 崩溃隔离测试 —— 类型越界 / 危险结构的最后防线
 *
 * 背景：200 项功能测试全跑正常路径，类型越界零覆盖。探针实测发现
 * `add(PHP_INT_MAX,1)` 整数溢出崩溃、`hello_format(null,null)` 野指针
 * 解引用崩溃——而功能测试无一发现。
 *
 * 本文件用 fork 隔离每个用例：崩溃（SEGV/ABRT）只影响子进程，父进程能
 * 捕获信号并精确定位到具体用例。没有 fork 能力时（非 CLI）跳过。
 *
 * 断言理念：危险测试的核心断言是「**不崩溃**」，其次才是行为可预期
 * （cast 语义 / TypeError / 优雅降级），**不是**返回值精确相等。
 *
 * 诊断同样纳入判据：本文件的每个用例都是越界探针，预期诊断按用例声明
 * （$allowDiags）。声明之外的任何诊断、以及致命错误退出，都算拒绝 ——
 * 否则「不崩溃」会掩盖「靠致命错误退出」这种情况。收集与分类见 isolation.php。
 *
 * 用法：php -d extension=... test_crash.php
 */

$passed = 0;
$rejected = 0;
$skipped = 0;

if (!function_exists('pcntl_fork')) {
    echo "pcntl 不可用，跳过崩溃隔离测试\n";
    exit(0);
}

require __DIR__ . '/isolation.php';

/**
 * fork 隔离执行一个用例，按标签与诊断分类判定。
 *
 * 标签词汇（isolation.php 的 isolateTag）：return / throw / fatal / exit(N) / CRASH(信号)
 *   CRASH        永远拒绝
 *   'no-crash'   期望：return 与 throw 都通过（核心断言是「不崩溃」）
 *   具体标签     精确匹配
 *   fatal/exit(N) 一律拒绝：致命错误退出不是「不崩溃」，是「没崩但死了」
 *
 * @param list<string> $expect     允许的标签
 * @param list<string> $allowDiags 该用例允许出现的诊断正则（默认空 = 不该有任何诊断）
 */
function crashTest(string $name, callable $fn, array $expect = ['no-crash'], array $allowDiags = []): void {
    global $passed, $rejected, $skipped;

    $res = forkIsolate($fn);
    $tag = isolateTag($res);

    $crashed = $res['signal'] !== null;
    $badExit = !$crashed && ($res['outcome'] === 'fatal' || $res['outcome'] === 'lost');
    $bad = unexpectedDiags($res['diags'], $allowDiags);

    $ok = false;
    if (!$crashed && !$badExit) {
        $ok = in_array('no-crash', $expect, true) || in_array($tag, $expect, true);
    }
    if ($bad !== []) {
        $ok = false;
    }

    if ($ok) {
        $passed++;
        $extra = $res['diags'] !== [] ? '  诊断 ' . count($res['diags']) . ' 条（已声明）' : '';
        echo "  ✓ $name  [{$tag}]$extra\n";
    } else {
        $rejected++;
        $why = $crashed ? '崩溃！'
            : ($badExit ? '意外退出（致命错误不是「不崩溃」）' : '');
        echo "  ✗ $name  —— 期望 " . implode('/', $expect) . "，实际 {$tag}" . ($why !== '' ? "（$why）" : '') . "\n";
        if ($res['thrown'] !== null) {
            echo "      抛出：{$res['thrown']}\n";
        }
        foreach ($bad as $b) {
            echo "      意外诊断：$b\n";
        }
    }
}

// ============================================================
// A. 数值类 API —— 错误类型入参
// ============================================================
echo "\n=== A. 数值类：错误类型入参（不崩溃即可）===\n";
foreach ([
    'add(1,2)'             => fn() => add(1, 2),
    'add("1","2") cast 语义' => fn() => add("1", "2"),
    'add(PHP_INT_MAX,1) 溢出' => fn() => add(PHP_INT_MAX, 1),
    'add(PHP_INT_MIN,-1)'  => fn() => add(PHP_INT_MIN, -1),
    'add(null, 2)'         => fn() => add(null, 2),
    'add([], 2)'           => fn() => add([], 2),
    'add(1.9, 2.9)'        => fn() => add(1.9, 2.9),
    'hello_sum(5,3)'       => fn() => hello_sum(5, 3),
    'hello_sum("5","3")'   => fn() => hello_sum("5", "3"),
    'hello_sum([],3)'      => fn() => hello_sum([], 3),
    'hello_divide(10,2)'   => fn() => hello_divide(10, 2),
    'hello_divide("10","2")' => fn() => hello_divide("10", "2"),
    'Calculator::add(1,2)' => fn() => Calculator::add(1, 2),
    'Calculator::add("1","2")' => fn() => Calculator::add("1", "2"),
] as $name => $fn) {
    crashTest($name, $fn);
}

// ============================================================
// B. 字符串类 API —— 错误类型入参
// ============================================================
echo "\n=== B. 字符串类：错误类型入参 ===\n";
foreach ([
    'hello_name("ok")'          => fn() => hello_name('ok'),
    'hello_name(123)'           => fn() => hello_name(123),
    'hello_name(null)'          => fn() => hello_name(null),
    'hello_name([1,2])'         => fn() => hello_name([1, 2]),
    'hello_name(fopen 资源)'     => fn() => hello_name(fopen('php://memory', 'r')),
    'hello_name(stdClass)'      => fn() => hello_name(new stdClass),
    'hello_name(str_repeat 1MB)' => fn() => hello_name(str_repeat('x', 1048576)),
    'hello_concat(null,null)'   => fn() => hello_concat(null, null),
    'hello_concat([],[])'       => fn() => hello_concat([], []),
    'hello_concat(1MB,1MB)'     => fn() => hello_concat(str_repeat('a', 1048576), str_repeat('b', 1048576)),
    'hello_typed_args(null,3)'  => fn() => hello_typed_args(null, 3),
    'hello_typed_args("a",[])'  => fn() => hello_typed_args("a", []),
] as $name => $fn) {
    crashTest($name, $fn);
}

// ============================================================
// C. 数组类 API —— 错误类型入参
// ============================================================
echo "\n=== C. 数组类：错误类型入参 ===\n";
foreach ([
    'hello_pop([7,8])'   => fn() => hello_pop([7, 8]),
    'hello_pop(null)'    => fn() => hello_pop(null),
    'hello_pop("str")'   => fn() => hello_pop('str'),
    'hello_pop(42)'      => fn() => hello_pop(42),
    'hello_pop(range 10万)' => fn() => hello_pop(range(0, 99999)),
    'hello_sum_all([1,2,3])' => fn() => hello_sum_all([1, 2, 3]),
    'hello_sum_all(null)'    => fn() => hello_sum_all(null),
    'hello_iterate([1,2])'   => fn() => hello_iterate([1, 2]),
    'hello_iterate(null)'    => fn() => hello_iterate(null),
    'hello_iterate(42)'      => fn() => hello_iterate(42),
    'hello_zip([1,2],[3,4])' => fn() => hello_zip([1, 2], [3, 4]),
    'hello_zip(null,null)'   => fn() => hello_zip(null, null),
    'hello_map([1,2,3])'     => fn() => hello_map([1, 2, 3]),
    'hello_map(null)'        => fn() => hello_map(null),
    'hello_filter([1,2,3])'  => fn() => hello_filter([1, 2, 3]),
    'hello_reduce([1,2,3])'  => fn() => hello_reduce([1, 2, 3]),
] as $name => $fn) {
    crashTest($name, $fn);
}

// ============================================================
// D. 序列化 —— 畸形输入
// ============================================================
echo "\n=== D. 序列化：畸形输入 ===\n";
foreach ([
    'hello_serialize([1,2])'  => fn() => hello_serialize([1, 2]),
    'hello_serialize(null)'   => fn() => hello_serialize(null),
    'hello_unserialize("O:8:\\"stdClass\\":0:{}")' => fn() => hello_unserialize('O:8:"stdClass":0:{}'),
    'hello_unserialize(垃圾串)' => fn() => hello_unserialize('not-a-serialized-blob'),
    'hello_unserialize("")'   => fn() => hello_unserialize(''),
    'hello_unserialize(截断的)' => fn() => hello_unserialize('O:8:"stdClass":0'),
] as $name => $fn) {
    crashTest($name, $fn);
}

// ============================================================
// E. 危险结构：循环引用 / 深嵌套 / 魔术方法
// ============================================================
echo "\n=== E. 危险结构 ===\n";
$cyclic = [];
$cyclic[] = &$cyclic;
crashTest('hello_zip(循环引用, 1)', fn() => hello_zip($cyclic, 1));
crashTest('hello_serialize(循环引用)', fn() => hello_serialize($cyclic));
crashTest('hello_sum_all(循环引用)', fn() => hello_sum_all($cyclic));

$deep = [[[[[1]]]]];
crashTest('hello_zip(深嵌套)', fn() => hello_zip($deep, 1));

// 魔术方法
$toStr = new class { public function __toString(): string { return 'x'; } };
crashTest('hello_name(obj __toString)', fn() => hello_name($toStr));

$badToStr = new class {
    public function __toString(): string { throw new Exception('boom'); }
};
crashTest('hello_name(obj __toString 抛异常)', fn() => hello_name($badToStr));

$getter = new class {
    public function __get($n): mixed { return 'v'; }
};
crashTest('hello_object(obj __get)', fn() => hello_object($getter));

// ============================================================
// F. 参数个数错误
//
// 实测行为发现：php-zig 函数少参**不抛 ArgumentCountError**（PHP 内置会），
// 由 handler 自行用 callNumArgs 判断。这是当前框架的行为特征，不崩溃即底线。
// ============================================================
echo "\n=== F. 参数个数错误 ===\n";
crashTest('hello_concat("a") 少参', fn() => hello_concat('a'));
crashTest('hello_name() 无参', fn() => hello_name());
crashTest('hello_sum(1) 少参', fn() => hello_sum(1));
crashTest('add(1,2,3) 多参', fn() => add(1, 2, 3));

// ============================================================
// G. cast 取值（`(string)$v`）—— 诊断必须按用例声明
// ============================================================
echo "\n=== G. cast 取值 ===\n";
$castRes = fopen('php://memory', 'r');
crashTest('hello_cast_string(123)', fn() => hello_cast_string(123));
crashTest('hello_cast_string(1.5)', fn() => hello_cast_string(1.5));
crashTest('hello_cast_string(null)', fn() => hello_cast_string(null));
crashTest('hello_cast_string(资源)', fn() => hello_cast_string($castRes));
crashTest('hello_cast_string(obj __toString)', fn() => hello_cast_string($toStr));
crashTest('hello_cast_string(对象无 __toString) → 抛 Error', fn() => hello_cast_string(new stdClass), ['throw']);
crashTest('hello_cast_string() 无参', fn() => hello_cast_string());
crashTest('hello_cast_string(array) 附 E_WARNING', fn() => hello_cast_string([1, 2]), ['no-crash'], ['/^Array to string conversion$/']);
crashTest('hello_cast_string(深嵌套数组)', fn() => hello_cast_string($deep), ['no-crash'], ['/^Array to string conversion$/']);
crashTest('hello_cast_string(循环引用数组)', fn() => hello_cast_string($cyclic), ['no-crash'], ['/^Array to string conversion$/']);

// ============================================================
// 结果汇总
// ============================================================
echo "\n========================================\n";
echo "崩溃隔离测试：通过 {$passed}，拒绝 {$rejected}，跳过 {$skipped}\n";
echo $rejected === 0 ? "全部通过\n" : "有拒绝项！\n";
exit($rejected === 0 ? 0 : 1);
