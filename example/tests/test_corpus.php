<?php
/**
 * 类型语料库矩阵测试 —— 系统性验证「任意类型 × 任意 API」不崩溃
 *
 * 与 test_crash.php 的分工：
 *   test_crash.php  手动选择的危险边界（循环引用、魔术方法、畸形序列化）
 *   test_corpus.php 自动枚举的笛卡尔积（N 个代表值 × M 个核心函数）
 *
 * 判据两条（缺一不可）：
 *   1. 不崩溃 —— fork 隔离下崩溃即信号
 *   2. 诊断在预期范围内 —— 见下
 *
 * 【诊断为什么要分类】
 * 语料测试故意把 object 喂给走 cast 语义（toLong()/toDouble()）的函数，PHP 引擎
 * 必然发出「could not be converted to int」。这类诊断是**输入决定的**：给定
 * 「函数 × 语料」就能推导出它必然出现，所以它属于预期，不是缺陷 —— 正常范围内
 * 操作不会产生任何诊断，出现了就说明越界探针命中。
 * 但「预期」必须是可核对的，否则第 22 条意外诊断会淹没在这堆噪声里。故本文件：
 *   - 按坐标（函数 × 语料）预先声明预期诊断，双向核对（该有的必须有、不该有的不能有）
 *   - 诊断经 isolation.php 的回传通道收集，不再依赖 stderr
 *
 * 返回值正确性由 test_all.php 覆盖，这里只验证边界行为。
 */

$passed = 0;
$rejected = 0;

if (!function_exists('pcntl_fork')) {
    echo "pcntl 不可用，跳过语料库测试\n";
    exit(0);
}

require __DIR__ . '/isolation.php';

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

/** `toLong()` 走 cast 语义时的必然产物：引擎对 object 发出 int/float 转换警告 */
const PAT_NUM_CONV = '/^Object of class .+ could not be converted to (int|float)$/';
/** cast 警告：array → string 时发出（`(string)$v` 的官方语义） */
const PAT_ARR_TO_STR = '/^Array to string conversion$/';

/** 被测试的核心函数（覆盖数值/字符串/数组/序列化/混合参数）。
 *
 *  [调用器, 参数个数, 预期诊断规则]
 *
 *  调用约定：单参传 (val)，双参传 (val, 1)——第二参用正常值，
 *  避免两个危险值叠加，同时覆盖「双参之一正常」的常见调用形态。
 *
 *  预期诊断规则两种写法，都是**可验证的断言**——声明错了会被
 *  「预期未命中 / 意外诊断」当场抓住：
 *    - 整数列表 → cast 位：该函数对第几个实参调用 toLong()/toDouble()（1 基）。
 *      这些位收到 object 语料时，引擎必定发 1 条 int/float 转换警告；
 *    - 字符串 → 具名规则（见 expectedDiags()），用于取值语义完全不同的入口。
 */
function coreFuncs(): array {
    return [
        'add'              => [fn($a, $b) => add($a, $b), 2, [1]],
        'hello_name'       => [fn($a) => hello_name($a), 1, []],
        'hello_concat'     => [fn($a, $b) => hello_concat($a, $b), 2, []],
        'hello_sum'        => [fn($a, $b) => hello_sum($a, $b), 2, [1]],
        'hello_divide'     => [fn($a, $b) => hello_divide($a, $b), 2, []],
        'hello_pop'        => [fn($a) => hello_pop($a), 1, []],
        'hello_sum_all'    => [fn($a) => hello_sum_all($a), 1, []],
        'hello_iterate'    => [fn($a) => hello_iterate($a), 1, []],
        'hello_serialize'  => [fn($a) => hello_serialize($a), 1, []],
        'hello_unserialize' => [fn($a) => hello_unserialize($a), 1, []],
        'hello_zip'        => [fn($a, $b) => hello_zip($a, $b), 2, []],
        'hello_object'     => [fn($a) => hello_object($a), 1, []],
        'Calculator::add'  => [fn($a, $b) => Calculator::add($a, $b), 2, [1]],
        // v0.11.2 新增的常驻级 / 非托管 / 裸记账入口：参数均未加约束，
        // 「任意类型不崩溃」这条契约对它们此前从未验证过。
        // 三者内部都有测试侧自设的上限（见 example/tests/src/main.zig），
        // 否则 PHP_INT_MAX 之类语料会先打破这条契约。
        'hello_resident_put' => [fn($a, $b) => hello_resident_put($a, $b), 2, [1]],
        'hello_resident_get' => [fn($a) => hello_resident_get($a), 1, [1]],
        'hello_unsafe_alloc' => [fn($a) => hello_unsafe_alloc($a), 1, [1]],
        'hello_ledger_probe' => [fn($a, $b) => hello_ledger_probe($a, $b), 2, [1]],
        // v0.11.4 的 cast 字符串入口：语义与数值位的 cast 不同——能转就真转
        // （123→"123"），转不成不能转的就抛（对象无 __toString → Error）。
        'hello_cast_string' => [fn($a) => hello_cast_string($a), 1, 'cast-str'],
    ];
}

/**
 * 某个坐标（函数 × 语料）上应当出现的诊断。语料固定从第 1 位传入。
 *
 * @param array|string $rule cast 位（整数列表）或具名规则（字符串）
 * @return list<string> 允许的诊断正则
 */
function expectedDiags(array|string $rule, $val): array {
    if (is_string($rule)) {
        return match ($rule) {
            // castString：array → "Array" + E_WARNING。
            // 对象无 __toString → 抛 Error —— 异常不是诊断，故不计入。
            'cast-str' => is_array($val) ? [PAT_ARR_TO_STR] : [],
            default => [],
        };
    }
    if (is_object($val) && in_array(1, $rule, true)) {
        return [PAT_NUM_CONV];
    }
    return [];
}

// ============================================================
// 主循环：函数 × 语料 笛卡尔积
// ============================================================
$c = corpus();
$funcs = coreFuncs();

echo "=== 类型语料库矩阵（" . count($funcs) . " 函数 × " . count($c) . " 语料）===\n";
echo "  隔离：fork 子进程；诊断经回传通道分类（子进程内 log_errors/display_errors 已关）\n\n";

$nCrash = 0;        // 信号崩溃
$nBadExit = 0;      // 致命错误 / 非预期退出
$nUnexpected = 0;   // 意外诊断
$nMissed = 0;       // 预期诊断未命中（声明与行为脱节）
$nExpectHit = 0;    // 预期诊断命中数
$expectTotal = 0;   // 预期诊断总数：逐坐标累加，与声明同源，故不可能与声明漂移
$details = [];

foreach ($funcs as $fname => [$f, $arity, $rule]) {
    foreach ($c as $cname => $val) {
        $res = forkIsolate($arity === 1 ? fn() => $f($val) : fn() => $f($val, 1));
        $tag = isolateTag($res);

        $expect = expectedDiags($rule, $val);
        $expectTotal += count($expect);
        $bad = unexpectedDiags($res['diags'], $expect);
        // 双向核对：落在预期集合里的条数必须**恰好等于**声明数 ——
        // 少了说明该发生的没发生，多了说明出现了未声明的东西（后者也由 $bad 兜一层）
        $hit = countExpectedDiags($res['diags'], $expect);
        $missed = $hit !== count($expect);

        $crashed = $res['signal'] !== null;
        $badExit = !$crashed && ($res['outcome'] === 'fatal' || $res['outcome'] === 'lost');

        if ($crashed) {
            $nCrash++;
            $details[] = "$fname × $cname => 崩溃 {$tag}";
        } elseif ($badExit) {
            $nBadExit++;
            $details[] = "$fname × $cname => 意外退出（{$tag}）" . ($res['thrown'] ?? '');
        }
        if ($bad !== []) {
            $nUnexpected += count($bad);
            $details[] = "$fname × $cname => 意外诊断 " . implode(' / ', $bad);
        }
        if ($missed) {
            $nMissed++;
            $n = $res['diags'] === [] ? 0 : count($res['diags']);  // 复杂表达式不能直接插值
            $details[] = "$fname × $cname => 预期诊断未命中（声明 " . count($expect) . " 条，实际 {$n} 条）";
        }

        if ($crashed || $badExit || $bad !== [] || $missed) {
            $rejected++;
        } else {
            $passed++;
            $nExpectHit += $hit;
        }
    }
}

// ============================================================
// 结果分类
// ============================================================
echo "矩阵结果：通过 {$passed}，拒绝 {$rejected}\n";
echo "  崩溃 {$nCrash} · 意外退出 {$nBadExit} · 意外诊断 {$nUnexpected} · 预期未命中 {$nMissed}\n";
echo "预期诊断：{$nExpectHit}/{$expectTotal} 命中";
echo "（数值 cast 位 × object → int/float 警告；字符串 cast 位 × array → Array to string conversion）\n";

if ($details) {
    echo "\n拒绝明细：\n";
    foreach ($details as $d) {
        echo "  ✗ $d\n";
    }
}
if ($rejected > 0) {
    echo "\n有拒绝项！\n";
    exit(1);
}
echo "\n全部通过：任意类型 × 核心 API 均不崩溃，且诊断完全在预期范围内\n";
