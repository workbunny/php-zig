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
 * （弱转换语义 / TypeError / 优雅降级），**不是**返回值精确相等。
 *
 * 用法：php -d extension=... test_crash.php
 */

$passed = 0;
$failed = 0;
$skipped = 0;

if (!function_exists('pcntl_fork')) {
    echo "pcntl 不可用，跳过崩溃隔离测试\n";
    exit(0);
}

/**
 * fork 隔离执行。子进程退出码编码：
 *   0 = 正常返回
 *   3 = 抛了异常（可诊断，不视为崩溃）
 *   信号 = 崩溃（SEGV/ABRT 等，测试失败）
 */
function crashTest(string $name, callable $fn, array $expect = ['no-crash']): void {
    global $passed, $failed, $skipped;

    $pid = pcntl_fork();
    if ($pid === 0) {
        // 子进程
        ob_start();
        try {
            $fn();
            ob_end_clean();
            exit(0);
        } catch (\TypeError $e) {
            ob_end_clean();
            exit(3); // TypeError 是预期的 PHP 行为
        } catch (\Throwable $e) {
            ob_end_clean();
            exit(3);
        }
    }
    pcntl_waitpid($pid, $status);

    $tag = '';
    if (pcntl_wifexited($status)) {
        $code = pcntl_wexitstatus($status);
        if ($code === 0) {
            $tag = 'return';
        } elseif ($code === 3) {
            $tag = 'throw';
        } else {
            $tag = "exit($code)";
        }
    } elseif (pcntl_wifsignaled($status)) {
        $sig = pcntl_wtermsig($status);
        $name_sig = match ($sig) { 11 => 'SEGV', 6 => 'ABRT', 4 => 'ILL', default => "SIG$sig" };
        $tag = "CRASH($name_sig)";
    } else {
        $tag = 'unknown';
    }

    // 判定：
    //   崩溃（CRASH）永远失败
    //   'no-crash' 期望：return / throw 都通过（核心断言是「不崩溃」）
    //   具体期望（如 'throw'）：精确匹配 tag
    $crash = str_starts_with($tag, 'CRASH');
    $ok = false;
    if (!$crash) {
        if (in_array('no-crash', $expect, true)) {
            $ok = true; // return 或 throw 都算不崩溃
        } elseif (in_array($tag, $expect, true)) {
            $ok = true;
        }
    }
    if ($ok) {
        $passed++;
        echo "  ✓ $name  [{$tag}]\n";
    } else {
        $failed++;
        echo "  ✗ $name  —— 期望 " . implode('/', $expect) . "，实际 {$tag}" . ($crash ? '（崩溃！）' : '') . "\n";
    }
}

// ============================================================
// A. 数值类 API —— 错误类型入参
// ============================================================
echo "\n=== A. 数值类：错误类型入参（不崩溃即可）===\n";
foreach ([
    'add(1,2)'             => fn() => add(1, 2),
    'add("1","2") 弱转换'   => fn() => add("1", "2"),
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
// 结果汇总
// ============================================================
echo "\n========================================\n";
echo "崩溃隔离测试：通过 {$passed}，失败 {$failed}，跳过 {$skipped}\n";
echo $failed === 0 ? "全部通过\n" : "有失败项！\n";
exit($failed === 0 ? 0 : 1);
