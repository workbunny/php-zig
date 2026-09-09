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
 *   mshutdown-usage=N     MSHUTDOWN 时全局计数，两组都应为 0
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

/** 探针在 arena 里分配的字节数，用来区分「defer 跑没跑」 */
const HOLD_BYTES = 65536;

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
 * @return array{0:int, 1:bool, 2:array<string,string>} [退出码, 是否被信号杀死, marker 键值]
 */
function runProbe(int $mode, ?callable $cb): array
{
    $marker = tempnam(sys_get_temp_dir(), 'phpzig_bailout');
    file_put_contents($marker, '');

    $pid = pcntl_fork();
    if ($pid === 0) {
        // 抑制 fatal 输出，避免把预期内的错误信息混进测试结果
        ini_set('display_errors', '0');
        if ($cb === null) {
            hello_bailout_probe($marker, $mode);
        } else {
            hello_bailout_probe($marker, $mode, $cb);
        }
        exit(0);
    }
    pcntl_waitpid($pid, $status);

    $signaled = pcntl_wifsignaled($status);
    $code = pcntl_wifexited($status) ? pcntl_wexitstatus($status) : -1;

    $kv = [];
    $lines = file($marker, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
    foreach ($lines as $line) {
        if (str_contains($line, '=')) {
            [$k, $v] = explode('=', $line, 2);
            $kv[trim($k)] = trim($v);
        }
    }
    @unlink($marker);

    return [$code, $signaled, $kv];
}

/**
 * 通用断言组：真实 bailout 的两个场景（Zig 侧 E_ERROR / 回调内 E_USER_ERROR）
 * 共用，区别在于 longjmp 的发起位置。
 */
function assertBailoutRecovered(string $label, int $code, bool $signaled, array $kv): void
{
    // 变量名必须写成 {$label}：紧随其后的全角「：」属 0x80-0xFF，
    // PHP 会把它当变量名的一部分（报 Undefined variable: $label：…）
    check("{$label}：未崩溃（无 SEGV/ABRT）", !$signaled);
    check("{$label}：致命错误确实触发（非 0 退出）", $code !== 0, "exit=$code");
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
        "{$label}：兜底回收生效（MSHUTDOWN 计数归零）",
        ($kv['mshutdown-usage'] ?? null) === '0',
        'mshutdown=' . ($kv['mshutdown-usage'] ?? 'n/a')
    );
}

// ============================================================
// A. 对照组：正常返回（defer 生效，走常规释放路径）
// ============================================================
echo "\n=== A. 对照组：正常返回 ===\n";
[$code, $signaled, $kv] = runProbe(0, null);
check('子进程正常退出', !$signaled && $code === 0, "exit=$code");
check('触发点之后的代码执行到', ($kv['reached-after-call'] ?? null) === '1');
check(
    'arena 已被 defer 释放（RSHUTDOWN 时只剩实例+注册表）',
    isset($kv['held-usage']) && (int)$kv['held-usage'] < 4096,
    'held=' . ($kv['held-usage'] ?? 'n/a')
);
check(
    'MSHUTDOWN 计数归零',
    ($kv['mshutdown-usage'] ?? null) === '0',
    'mshutdown=' . ($kv['mshutdown-usage'] ?? 'n/a')
);
// 对照组不是陪跑：没有它，「held 很大」无法与 arena 内部开销区分，
// 断言就失去判别力。

// ============================================================
// B. 真实 bailout：Zig 侧报 E_ERROR（longjmp 从本帧发起）
// ============================================================
echo "\n=== B. 真实 bailout：Zig 侧 E_ERROR ===\n";
[$code, $signaled, $kv] = runProbe(1, null);
assertBailoutRecovered('Zig 侧 E_ERROR', $code, $signaled, $kv);

// ============================================================
// C. 真实 bailout：PHP 回调内 E_USER_ERROR（longjmp 穿过 Zig 帧）
// ============================================================
echo "\n=== C. 真实 bailout：回调内 E_USER_ERROR（longjmp 穿过 Zig 帧）===\n";
[$code, $signaled, $kv] = runProbe(2, function () {
    trigger_error('php-zig bailout probe', E_USER_ERROR);
});
assertBailoutRecovered('回调内 E_USER_ERROR', $code, $signaled, $kv);

// ============================================================
// 结果汇总
// ============================================================
echo "\n========================================\n";
echo "bailout 兜底测试：通过 {$passed}，失败 {$failed}\n";
echo $failed === 0 ? "全部通过\n" : "有失败项！\n";
exit($failed === 0 ? 0 : 1);
