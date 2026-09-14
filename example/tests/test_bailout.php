<?php
/**
 * 真实 bailout（longjmp）下的资源兜底验证
 *
 * bailout 会跳过 Zig 的 defer，请求级资源只能靠 RSHUTDOWN 的 Cleanup 回收。
 * 单测里手动调 Cleanup.flush() 模拟不出这条路径（longjmp 不走 Zig 的返回路径），
 * 故由 fork 出的子进程真实触发一次，观察点写进 marker 文件带回父进程断言
 * （fork 后内存不共享）。
 *
 * 观察点由扩展侧的 hello_bailout_probe 写入：
 *   held-usage=N          RSHUTDOWN 时 arena 仍持有的字节数。回调后注册 → LIFO
 *                         先跑，读到的正是「被跳过的 defer 本该释放的字节」。
 *                         对照组 < 4K，bailout 组 ≥ 64K
 *   reached-after-call=1  触发点之后的代码执行到；bailout 组不应出现
 *   mshutdown-usage=N     MSHUTDOWN 时【请求级】计数，三组都应为 0
 *   mshutdown-resident-usage=N
 *                         MSHUTDOWN 时【常驻级】计数，三组都应 > 0。
 *                         与上一条构成对照：请求级已被 RSHUTDOWN 回收，常驻级
 *                         跨越请求继续存活 —— 这就是「常驻」的定义。
 *
 * 诊断也是断言对象：B/C 两组各自触发一条 Fatal error，它就是「bailout 确实发生」
 * 的证据，故按组声明为预期（恰好 1 条，且消息匹配探针），A 组则应为零诊断。
 * 收集与分类见 isolation.php —— 此前靠 ini_set('display_errors','0') 抑制，
 * 但致命错误经 log_errors 走 fd 2，压不住，于是漏进了 CI 日志。
 *
 * 用法：php -d extension=... test_bailout.php
 */

$passed = 0;
$failed = 0;

if (!function_exists('pcntl_fork')) {
    echo "pcntl 不可用，跳过 bailout 兜底测试\n";
    exit(0);
}
if (!function_exists('hello_bailout_probe')) {
    echo "hello_bailout_probe 未注册，无法运行 bailout 兜底测试\n";
    exit(1);
}

require __DIR__ . '/isolation.php';

/** 探针在 arena 里分配的字节数，用来区分「defer 跑没跑」 */
const HOLD_BYTES = 65536;
/** 探针在常驻级写的字节数，用来验证它跨越请求存活 */
const RESIDENT_BYTES = 32768;
/** 预期的致命错误消息（探针自己触发的） */
const PAT_PROBE_FATAL = '/php-zig bailout probe/';
/** PHP 8.4 起 trigger_error(E_USER_ERROR) 被弃用（仍致命）；C 组故意选用它，故属预期 */
const PAT_TRIGGER_ERROR_DEPRECATED = '/Passing E_USER_ERROR to trigger_error\(\) is deprecated/';

function check(string $name, bool $ok, string $detail = ''): void
{
    global $passed, $failed;
    if ($ok) {
        $passed++;
        echo "  ✓ $name" . ($detail !== '' ? "  [$detail]" : '') . "\n";
    } else {
        $failed++;
        echo "  ✗ $name" . ($detail !== '' ? "  —— $detail" : '') . "\n";
    }
}

/**
 * 在 fork 出的子进程里跑一次探针。
 *
 * @return array{0:array, 1:array<string,string>} [isolation 结果, marker 键值]
 */
function runProbe(int $mode, ?callable $cb): array
{
    $marker = tempnam(sys_get_temp_dir(), 'phpzig_bailout');
    file_put_contents($marker, '');

    $res = forkIsolate(function () use ($marker, $mode, $cb): void {
        if ($cb === null) {
            hello_bailout_probe($marker, $mode);
        } else {
            hello_bailout_probe($marker, $mode, $cb);
        }
    });

    $kv = [];
    $lines = file($marker, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
    foreach ($lines as $line) {
        if (str_contains($line, '=')) {
            [$k, $v] = explode('=', $line, 2);
            $kv[trim($k)] = trim($v);
        }
    }
    @unlink($marker);

    return [$res, $kv];
}

/**
 * 通用断言组：真实 bailout 的两个场景（Zig 侧 E_ERROR / 回调内 E_USER_ERROR）
 * 共用，区别在于 longjmp 的发起位置。
 */
function assertBailoutRecovered(string $label, array $res, array $kv): void
{
    // 变量名必须写成 {$label}：紧随其后的全角「：」属 0x80-0xFF，
    // PHP 会把它当变量名的一部分（报 Undefined variable: $label：…）
    check("{$label}：未崩溃（无 SEGV/ABRT）", $res['signal'] === null, $res['signal'] ?? '');
    check("{$label}：致命错误确实触发（非 0 退出）", $res['exit'] !== 0, "exit={$res['exit']}");
    // 本组触发的那条 Fatal error 就是断言对象本身：它必须出现，且必须是探针发的。
    // 声明之外（多一条或少一条）都算意外 —— 诊断不是噪声，是证据。
    $fatal = array_values(array_filter($res['diags'], fn($d) => $d['fatal']));
    $other = array_values(array_filter($res['diags'], fn($d) => !$d['fatal']));
    check(
        "{$label}：诊断恰好 1 条探针 Fatal error（本组断言对象）",
        count($fatal) === 1 && preg_match(PAT_PROBE_FATAL, $fatal[0]['msg']) === 1,
        'fatal=' . count($fatal) . ($fatal !== [] ? ' [' . diagText($fatal[0]) . ']' : '')
    );
    // C 组用 trigger_error(E_USER_ERROR) 触发 bailout，而 PHP 8.4 起该用法本身被弃用，
    // 于是 8.4+ 会多一条 Deprecated。它由测试自己选择的触发方式决定，属预期；
    // 其余任何非致命诊断都是意外。
    $unexpectedOther = unexpectedDiags($other, [PAT_TRIGGER_ERROR_DEPRECATED]);
    check(
        "{$label}：非致命诊断均已声明（8.4 的 trigger_error 弃用提示）",
        $unexpectedOther === [],
        $other === [] ? 'none' : implode(' / ', array_map('diagText', $other))
    );
    check(
        "{$label}：defer 被跳过（触发点之后的代码没执行到）",
        !isset($kv['reached-after-call']),
        'reached=' . ($kv['reached-after-call'] ?? 'no')
    );
    check(
        "{$label}：RSHUTDOWN 时内存仍挂着（反证 defer 确实没跑）",
        isset($kv['held-usage']) && (int)$kv['held-usage'] >= HOLD_BYTES,
        'held=' . ($kv['held-usage'] ?? 'n/a')
    );
    check(
        "{$label}：兜底回收生效（请求级 MSHUTDOWN 计数归零）",
        ($kv['mshutdown-usage'] ?? null) === '0',
        'mshutdown=' . ($kv['mshutdown-usage'] ?? 'n/a')
    );
    // 与上一条成对：同一次 MSHUTDOWN 里请求级归零、常驻级仍挂着。
    // 只断言请求级归零会被「常驻也被误回收」这类缺陷漏过。
    check(
        "{$label}：常驻级跨越请求存活（MSHUTDOWN 时仍 > 0）",
        isset($kv['mshutdown-resident-usage'])
            && (int)$kv['mshutdown-resident-usage'] >= RESIDENT_BYTES,
        'resident=' . ($kv['mshutdown-resident-usage'] ?? 'n/a')
    );
}

// ============================================================
// A. 对照组：正常返回（defer 生效，走常规释放路径）
// ============================================================
echo "\n=== A. 对照组：正常返回 ===\n";
[$res, $kv] = runProbe(0, null);
check('子进程正常退出', $res['signal'] === null && $res['exit'] === 0, "exit={$res['exit']}");
check('对照组：无诊断（正常返回不该产生任何诊断）', $res['diags'] === [], 'diags=' . count($res['diags']));
check('触发点之后的代码执行到', ($kv['reached-after-call'] ?? null) === '1');
check(
    'arena 已被 defer 释放（RSHUTDOWN 时只剩实例+注册表）',
    isset($kv['held-usage']) && (int)$kv['held-usage'] < 4096,
    'held=' . ($kv['held-usage'] ?? 'n/a')
);
check(
    'MSHUTDOWN 计数归零（请求级）',
    ($kv['mshutdown-usage'] ?? null) === '0',
    'mshutdown=' . ($kv['mshutdown-usage'] ?? 'n/a')
);
check(
    '常驻级跨越请求存活（MSHUTDOWN 时仍 > 0）',
    isset($kv['mshutdown-resident-usage'])
        && (int)$kv['mshutdown-resident-usage'] >= RESIDENT_BYTES,
    'resident=' . ($kv['mshutdown-resident-usage'] ?? 'n/a')
);
// 对照组不是陪跑：没有它，「held 很大」无法与 arena 内部开销区分，
// 断言就失去判别力。

// ============================================================
// B. 真实 bailout：Zig 侧报 E_ERROR（longjmp 从本帧发起）
// ============================================================
echo "\n=== B. 真实 bailout：Zig 侧 E_ERROR ===\n";
[$res, $kv] = runProbe(1, null);
assertBailoutRecovered('Zig 侧 E_ERROR', $res, $kv);

// ============================================================
// C. 真实 bailout：PHP 回调内 E_USER_ERROR（longjmp 穿过 Zig 帧）
//
// 触发方式选的是 trigger_error(E_USER_ERROR)：PHP 8.4 起该用法被标记弃用
// （仍是致命错误），故 8.4+ 会多一条 Deprecated —— 见 assertBailoutRecovered
// 的声明。若将来 8.5+ 彻底取消它的致命语义，本组会立刻拒绝（exit=0、
// reached 出现），这是设计如此：本组的价值就在于「回调里真发起了一次 bailout」。
// ============================================================
echo "\n=== C. 真实 bailout：回调内 E_USER_ERROR（longjmp 穿过 Zig 帧）===\n";
[$res, $kv] = runProbe(2, function () {
    trigger_error('php-zig bailout probe', E_USER_ERROR);
});
assertBailoutRecovered('回调内 E_USER_ERROR', $res, $kv);

// ============================================================
// 结果汇总
// ============================================================
echo "\n========================================\n";
echo "bailout 兜底测试：通过 {$passed}，失败 {$failed}\n";
echo "预期诊断：B/C 两组各 1 条探针 Fatal error（本组断言对象），A 组 0 条\n";
echo $failed === 0 ? "全部通过\n" : "有失败项！\n";
exit($failed === 0 ? 0 : 1);
