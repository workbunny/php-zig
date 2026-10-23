<?php
/**
 * 真实 bailout（longjmp）下的资源兜底验证
 *
 * bailout 会跳过 Zig 的 defer，请求级资源只能靠 RSHUTDOWN 的 Cleanup 回收。
 * 单测里手动调 Cleanup.flush() 模拟不出这条路径（longjmp 不走 Zig 的返回路径），
 * 故由子进程真实触发一次（隔离后端见 isolation.php：pcntl 或 FFI fork），
 * 观察点写进 marker 文件带回父进程断言（子进程与父进程内存不共享）。
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
 * 诊断也是断言对象：B/C 两组各触发一条 Fatal error（「bailout 确实发生」的证据），
 * 按组声明为预期（恰好 1 条且消息匹配探针），A 组为零诊断。
 * 提示：致命错误经 log_errors 走 fd 2，ini_set('display_errors','0') 压不住 ——
 *       收集与分类见 isolation.php。
 *
 * 六组，按「longjmp 从哪发起」与「RSHUTDOWN 有没有被执行」分：
 *   A 正常返回（对照组）
 *   B Zig 侧 E_ERROR
 *   C 用户回调内 E_USER_ERROR（longjmp 穿过 Zig 帧）
 *   D **清理回调**自身 bailout —— 链被断，但收尾必须完成（不吞错、不漏内存）
 *   E **RINIT 阶段** bailout —— RSHUTDOWN 被整段跳过，请求级内存不回收（反向对照）
 *   F1 **跨请求继承 · RINIT 阶段 bailout** —— 整张注册表原样留到下一请求（CVE 精确场景）
 *   F2 **跨请求继承 · 收尾钩子内 bailout** —— 遗留被下一请求回收，worker 健康
 *
 * D 组新增 marker：chain-fatal=1（断链起点执行到）、chain-reached（不该出现）。
 * E 组跑在全新进程里（fork 的子进程不会再走 RINIT），marker 路径与开关走环境变量：
 *   PHPZIG_TEST_MARKER / PHPZIG_TEST_RINIT_BAILOUT=1
 * F1 用 PHPZIG_TEST_RINIT_BAILOUT_ONCE=<文件> 让只有首个请求在 RINIT bailout。
 * F2 不靠环境变量，改由 /bail 请求武装「收尾时钩子内 bailout」。
 *
 * 用法：php -d extension=... test_bailout.php
 */

$passed = 0;
$failed = 0;

if (!function_exists('hello_bailout_probe')) {
    echo "hello_bailout_probe 未注册，无法运行 bailout 兜底测试\n";
    exit(1);
}

require __DIR__ . '/isolation.php';

// 隔离后端：pcntl（NTS 自带）或 FFI fork（ZTS 无 pcntl）。
// 环境不满足一律非绿（探针未注册的分支在上面同样是 exit(1)）。
$backend = isolateBackend();
if ($backend === null) {
    echo "无可用隔离后端（pcntl / FFI 均不可用）：无法运行 bailout 兜底测试\n";
    exit(1);
}
echo "隔离后端：{$backend}\n";

/** 探针在 arena 里分配的字节数，用来区分「defer 跑没跑」 */
const HOLD_BYTES = 65536;
/** 探针在常驻级写的字节数，用来验证它跨越请求存活 */
const RESIDENT_BYTES = 32768;
/** 预期的致命错误消息（探针自己触发的） */
const PAT_PROBE_FATAL = '/php-zig bailout probe/';
/** PHP 8.4 起 trigger_error(E_USER_ERROR) 被弃用（仍致命）；C 组故意选用它，故属预期 */
const PAT_TRIGGER_ERROR_DEPRECATED = '/Passing E_USER_ERROR to trigger_error\(\) is deprecated/';
/**
 * 断言数下界（结构断言）。低于它说明有整组断言被删掉或压根没执行 ——
 * 那种情况下「失败 0」同样成立。新增断言时上调此值。
 */
const EXPECTED_MIN_CHECKS = 46;

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

    $kv = readMarker($marker);
    @unlink($marker);

    return [$res, $kv];
}

/**
 * 起一个**全新** PHP 进程跑一段代码。
 *
 * 与 forkIsolate 的分工：forkIsolate 是「请求中途 fork」，子进程不会再走 RINIT ——
 * 所以「RINIT 阶段 bailout」只能用全新进程复现。全新进程没有回传通道，
 * 观察点仍走 marker 文件（路径由环境变量在 MINIT 期取，见扩展侧 myMinit）。
 *
 * @param array<string,string> $extraEnv
 * @return array{exit:int, stdout:string, stderr:string}
 */
function runFreshProcess(array $extraEnv, string $code): array
{
    // 数组形式：不经 /bin/sh 包装，参数不依赖 escapeshellarg 的转义规则，
    // 也与 serverStart 保持同一种启动方式（原因见该处注释）。
    $cmd = [
        PHP_BINARY,
        '-d', 'extension=' . extFilePath(),
        '-d', 'display_errors=0',
        '-d', 'log_errors=1',
        '-r', $code,
    ];

    $proc = proc_open(
        $cmd,
        [1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
        $pipes,
        null,
        array_merge(getenv(), $extraEnv)
    );
    if (!is_resource($proc)) {
        echo "proc_open 失败，RINIT 组无法运行\n";
        exit(1);
    }
    $stdout = (string) stream_get_contents($pipes[1]);
    $stderr = (string) stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);

    return ['exit' => proc_close($proc), 'stdout' => $stdout, 'stderr' => $stderr];
}

/**
 * 定位当前加载的 ext-tests 扩展文件。
 *
 * PHP 没有可靠的「查询已加载扩展的 .so 路径」接口（8.4 的 ReflectionExtension 无
 * getFileName）。故按约定取 zig-out 产物，并允许 PHPZIG_EXT_PATH 覆盖（ZTS 等使用
 * 独立产物目录的场景）。取不到**直接失败** —— 环境不满足即非绿，不得跳过。
 */
function extFilePath(): string
{
    static $cached = null;
    if ($cached !== null) {
        return $cached;
    }

    $candidates = [];
    $override = getenv('PHPZIG_EXT_PATH');
    if (is_string($override) && $override !== '') {
        $candidates[] = $override;
    }
    $candidates[] = __DIR__ . '/zig-out/lib/libext-tests.so';

    foreach ($candidates as $f) {
        if (is_file($f) && is_readable($f)) {
            return $cached = $f;
        }
    }

    echo '无法定位 ext-tests 扩展文件（已试：' . implode(', ', $candidates)
        . "）；可用 PHPZIG_EXT_PATH 指定\n";
    exit(1);
}

/**
 * 起一个 `php -S` 单进程服务器（F 组专用），让「跨请求」真实发生。
 *
 * 与 runFreshProcess 的分工：那个是一次性进程（只跑一个请求）；这个要连跑多个请求
 * 且**共用同一个 worker**，才能观测到遗留条目被下一请求继承。
 *
 * 一次性 bailout 开关走**文件**而不是环境变量：`php -S` 进程内环境变量不变，只读
 * env 会让每个请求都在 RINIT 里 bailout，永远观测不到继承。
 *
 * 起不来直接 exit(1) —— 环境不满足即非绿，不跳过。
 *
 * @return array{port:int, proc:resource, logHandle:resource, log:string}
 */
function serverStart(array $extraEnv = []): array
{
    $log = tempnam(sys_get_temp_dir(), 'phpzig_xreq_log');
    $port = freePort();

    // 必须用**数组形式**启动：字符串形式会被 PHP 包成 `/bin/sh -c '<cmd>'`，
    // 于是 proc_get_status()['pid'] 是 sh 的 pid，proc_terminate() 只杀 sh，
    // 真正的 php -S 变成孤儿继续占着端口 —— 下一组再起来就会静默连到它上面，
    // 全部断言错位（表现为请求序号累积、inherited 是上一组的值）。
    $cmd = [
        PHP_BINARY,
        '-S', '127.0.0.1:' . $port,
        '-d', 'extension=' . extFilePath(),
        '-d', 'display_errors=0',
        '-d', 'log_errors=1',
        __DIR__ . '/cross_request_router.php',
    ];

    $logHandle = fopen($log, 'w');
    $proc = proc_open($cmd, [1 => $logHandle, 2 => $logHandle], $pipes, null, array_merge(getenv(), $extraEnv));
    if (!is_resource($proc)) {
        echo "proc_open 起 php -S 失败，F 组无法运行\n";
        exit(1);
    }

    // 就绪判定只做裸 TCP 连接、不发 HTTP：php -S 会为每个接受到的连接走一遍请求
    // 生命周期（不完整的请求也占请求序号），故在探测阶段不做业务请求，
    // 断言也不依赖 current_req 的绝对值。
    // 探测期间同时盯进程是否已死：端口若被占，php -S 会立即退出，继续空等没有意义。
    $ready = false;
    for ($i = 0; $i < 200; $i++) {
        $fp = @fsockopen('127.0.0.1', $port, $errno, $errstr, 0.1);
        if (is_resource($fp)) {
            fclose($fp);
            $ready = true;
            break;
        }
        if (!proc_get_status($proc)['running']) {
            break;
        }
        usleep(50000);
    }

    // 连接成功只证明「端口上有人在听」，不证明「听的是我们刚起的这个」。
    // 进程活着 + 日志无 bind 失败，才能排除连到别人的服务器。
    $alive = proc_get_status($proc)['running'];
    usleep(100000); // 让 php -S 的启动行落盘
    $logText = (string) @file_get_contents($log);
    $bindFailed = stripos($logText, 'Address already in use') !== false
        || stripos($logText, 'Failed to listen') !== false;

    if (!$ready || !$alive || $bindFailed) {
        proc_terminate($proc, 9);
        proc_close($proc);
        fclose($logHandle);
        echo "php -S 未能就绪（port {$port}；ready=" . var_export($ready, true)
            . ' alive=' . var_export($alive, true)
            . ' bindFailed=' . var_export($bindFailed, true) . "）\n";
        echo 'log=' . substr(str_replace("\n", ' ', $logText), 0, 200) . "\n";
        exit(1);
    }

    return [
        'port'      => $port,
        'proc'      => $proc,
        'logHandle' => $logHandle,
        'log'       => $log,
    ];
}

/**
 * 取一个当前空闲的本机端口。
 *
 * 不用 `20000 + getmypid() % 20000`：同一测试进程里两次 serverStart 会拿到同一个
 * 端口，只要前一个服务器没死透就会撞车。交给内核分配能直接消掉这一类冲突。
 */
function freePort(): int
{
    $sock = @stream_socket_server('tcp://127.0.0.1:0', $errno, $errstr);
    if ($sock === false) {
        echo "无法分配空闲端口（{$errno} {$errstr}），F 组无法运行\n";
        exit(1);
    }
    $name = (string) stream_socket_get_name($sock, false);
    fclose($sock);

    $pos = strrpos($name, ':');
    if ($pos === false) {
        echo "无法从 {$name} 解析端口，F 组无法运行\n";
        exit(1);
    }

    return (int) substr($name, $pos + 1);
}

/** 发一个最小 HTTP/1.0 GET，返回去掉响应头的正文（连接失败返回空串） */
function httpGet(int $port, string $path): string
{
    $fp = @fsockopen('127.0.0.1', $port, $errno, $errstr, 2.0);
    if (!is_resource($fp)) {
        return '';
    }
    fwrite($fp, "GET {$path} HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    $raw = (string) stream_get_contents($fp);
    fclose($fp);
    $pos = strpos($raw, "\r\n\r\n");

    return $pos === false ? '' : substr($raw, $pos + 4);
}

/**
 * 停服并返回服务端日志。
 * 用 SIGKILL：断言所需的日志在请求阶段已落盘，此处只求「不挂住 CI」。
 */
function serverStop(array $srv): string
{
    proc_terminate($srv['proc'], 9);
    proc_close($srv['proc']);
    fclose($srv['logHandle']);
    $text = (string) @file_get_contents($srv['log']);
    @unlink($srv['log']);

    return $text;
}

/** 读 marker 文件 → 键值表 */
function readMarker(string $marker): array
{
    $kv = [];
    foreach (file($marker, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
        if (str_contains($line, '=')) {
            [$k, $v] = explode('=', $line, 2);
            $kv[trim($k)] = trim($v);
        }
    }

    return $kv;
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
    // C 组用 trigger_error(E_USER_ERROR) 触发 bailout；PHP 8.4 起该用法本身被弃用，
    // 8.4+ 因此多一条 Deprecated（属预期，由测试选择的触发方式决定）；
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
// D. 清理回调自身 bailout —— LIFO 链被断，但收尾必须完成
//
// 本组锁住两件事：
//   1. 致命错误不被吞（框架捕获只为完成收尾，之后照样交还引擎）
//   2. 链条被打断后，注册表的中间数组仍被释放（否则就是 c_allocator 静默泄漏）
// 前者是「不静默」，后者是「不漏」——缺任一，框架的内存可观测性就不成立。
// ============================================================
echo "\n=== D. 清理回调内 bailout（断链与收尾）===\n";
[$res, $kv] = runProbe(3, null);
check('D：未崩溃（无 SEGV/ABRT）', $res['signal'] === null, $res['signal'] ?? '');
check('D：致命错误未被吞（捕获只是为收尾，不改变结果）', $res['exit'] !== 0, "exit={$res['exit']}");
check('D：fatal 回调确实执行（断链起点）', ($kv['chain-fatal'] ?? null) === '1');
check(
    'D：链上剩余条目未执行（已声明边界：longjmp 不返回）',
    !isset($kv['chain-reached']),
    'chain-reached=' . ($kv['chain-reached'] ?? 'no')
);
check(
    'D：收尾未被中断（请求级 MSHUTDOWN 归零 = 中间数组已释放，无静默泄漏）',
    ($kv['mshutdown-usage'] ?? null) === '0',
    'mshutdown=' . ($kv['mshutdown-usage'] ?? 'n/a')
);

// 诊断必须另起全新进程取：本组的 fatal 发生在 exit(0) 之后的 RSHUTDOWN，
// 那时 forkIsolate 的回传通道已经关闭 —— 它会漏掉这一条（fatal=0），
// 所以只能走 stderr。这不是噪声漏采，是通道时序决定的分工。
$markerD = tempnam(sys_get_temp_dir(), 'phpzig_cleanup_bail');
file_put_contents($markerD, '');
$freshD = runFreshProcess(
    ['PHPZIG_TEST_MARKER' => $markerD],
    'hello_bailout_probe(' . var_export($markerD, true) . ', 3);'
);
@unlink($markerD);
check(
    'D：致命错误经引擎如实上报（stderr 含探针消息）',
    str_contains($freshD['stderr'], 'php-zig cleanup bailout probe'),
    'stderr=' . substr(str_replace("\n", ' ', trim($freshD['stderr'])), 0, 120)
);

// ============================================================
// E. RINIT 阶段 bailout —— RSHUTDOWN 被整段跳过（反向对照）
//
// A/B/C/D 四组证明「兜底在 RSHUTDOWN 执行时有效」；本组证明「RSHUTDOWN 本身会
// 被跳过」——bailout 早于 PG(modules_activated) 置位时，php_request_shutdown
// 跳过全部模块 RSHUTDOWN，请求级内存就此跨请求留存。这正是「请求边界事件需要
// 补发」（Cleanup.beginRequest + stats().inherited）的存在理由。
// 必须用全新进程：forkIsolate 的子进程不会再走 RINIT。
// ============================================================
echo "\n=== E. RINIT 阶段 bailout（RSHUTDOWN 被跳过）===\n";
$markerE = tempnam(sys_get_temp_dir(), 'phpzig_rinit');
file_put_contents($markerE, '');
$fresh = runFreshProcess([
    'PHPZIG_TEST_MARKER'        => $markerE,
    'PHPZIG_TEST_RINIT_BAILOUT' => '1',
], 'echo "STARTED";');
$kvE = readMarker($markerE);
@unlink($markerE);

check('E：子进程非 0 退出（RINIT 内致命错误）', $fresh['exit'] !== 0, "exit={$fresh['exit']}");
check(
    'E：用户代码从未执行（启动阶段即中止）',
    !str_contains($fresh['stdout'], 'STARTED'),
    'stdout=' . trim($fresh['stdout'])
);
check(
    'E：探针确实在 RINIT 内触发（marker 由 RINIT 写入）',
    ($kvE['rinit-bailed'] ?? null) === '1',
    'rinit-bailed=' . ($kvE['rinit-bailed'] ?? 'n/a')
);
check(
    'E：stderr 含探针 Fatal error（致命错误如实上报）',
    str_contains($fresh['stderr'], 'php-zig rinit bailout probe'),
    'stderr=' . substr(trim($fresh['stderr']), 0, 120)
);
check(
    'E：反向对照 —— RSHUTDOWN 被整段跳过，请求级内存未回收（>= 64K）',
    isset($kvE['mshutdown-usage']) && (int) $kvE['mshutdown-usage'] >= HOLD_BYTES,
    'mshutdown=' . ($kvE['mshutdown-usage'] ?? 'n/a')
);

// ============================================================
// F. 跨请求继承 —— 「补发」语义的端到端验证（php -S 单进程多请求）
//
// 两种「endRequest 未送达」的成因必须分开验，风险量级不同：
//
//  F1  RINIT 阶段 bailout —— RSHUTDOWN 整段跳过，**注册表一条都没清**。
//      这是 php2shell-poc 的精确前提，也是风险最高的一条。
//  F2  收尾钩子内 bailout —— 第一次 endRequest 已跑完，只有钩子内新注册的
//      条目留下。量级小得多，但它能验证「遗留会被下一请求正常收尾回收」。
//
// F1 的观测方式受过上游限制：php -S 在某请求 RINIT 失败后，**下一个**请求仍能
// 正常响应（响应体在收尾之前就已写出），但它自己的收尾会 SEGV，之后不再服务。
// 换言之 F1 只证「继承可见」，未证「后续回收」—— 补齐方案见 TODO.md 第 1 条。
// 已用对照开关 PHPZIG_TEST_RINIT_BAILOUT_NOALLOC（只 bailout、不注册任何资源）
// 确认该崩溃与框架无关，是 CLI 内置服务器处理「启动失败」的上游缺陷。
// 故 F1 只发 **2 个请求**：拿到继承证据即止，不声称 worker 长期存活。
// F2 走不触发该缺陷的路径，可以发满 3 个请求验证回收与存活。
//
// 不硬编码 current_req：php -S 为每个接受到的连接都走一遍请求生命周期，就绪探测
// 也会占用序号，故只断言相对关系。
// ============================================================

// ------------------------------------------------------------
// F1. RINIT 阶段 bailout（CVE 精确场景）
// ------------------------------------------------------------
echo "\n=== F1. 跨请求继承：RINIT 阶段 bailout ===\n";
$onceF1 = tempnam(sys_get_temp_dir(), 'phpzig_xreq_once');
@unlink($onceF1); // 不存在 = 尚未 bailout；请求 1 会消耗它
$srv1 = serverStart(['PHPZIG_TEST_RINIT_BAILOUT_ONCE' => $onceF1]);

$bodyF1 = httpGet($srv1['port'], '/r1');
check(
    'F1：请求 1 未进入业务（RINIT 即 bailout，拿不到 stats）',
    !str_contains($bodyF1, 'current_req'),
    'body=' . substr(trim($bodyF1), 0, 80)
);

$r1 = json_decode(httpGet($srv1['port'], '/stats'), true);
check(
    'F1：请求 2 拿到 stats（响应在 worker 崩之前已写出）',
    is_array($r1) && isset($r1['current_req'])
);
check(
    'F1：请求 2 继承了 RINIT bailout 遗留的条目（inherited=1）',
    ($r1['inherited'] ?? null) === 1,
    'inherited=' . var_export($r1['inherited'] ?? null, true)
);
check(
    'F1：整张注册表原样存活到下一请求（pending=1）',
    ($r1['pending'] ?? null) === 1,
    'pending=' . var_export($r1['pending'] ?? null, true)
);
@unlink($onceF1);
serverStop($srv1); // 不再发第三个请求 —— 见本组注释

// ------------------------------------------------------------
// F2. 收尾钩子内 bailout（worker 健康，可验证回收）
// ------------------------------------------------------------
echo "\n=== F2. 跨请求继承：收尾钩子内 bailout ===\n";
$srv = serverStart();

// 请求 1：武装 —— 本次收尾时在 RSHUTDOWN 钩子里注册 3 条条目并 bailout，
// 使框架在钩子之后的第二次 endRequest() 永不执行，条目就此留到下一请求。
$b1 = json_decode(httpGet($srv['port'], '/bail'), true);
check(
    'F2：请求 1 武装成功（收尾时钩子会 bailout）',
    ($b1['armed'] ?? null) === true,
    'body=' . var_export($b1, true)
);

// 请求 2：应继承请求 1 遗留的 3 条
$r2 = json_decode(httpGet($srv['port'], '/stats'), true);
check(
    'F2：请求 2 拿到 stats（收尾 bailout 未杀死 worker）',
    is_array($r2) && isset($r2['current_req'])
);
check(
    'F2：请求 2 继承了请求 1 遗留的 3 条（inherited=3）',
    ($r2['inherited'] ?? null) === 3,
    'inherited=' . var_export($r2['inherited'] ?? null, true)
);
check(
    'F2：遗留条目仍在册（pending=3）',
    ($r2['pending'] ?? null) === 3,
    'pending=' . var_export($r2['pending'] ?? null, true)
);

// 请求 3：请求 2 正常收尾时已把遗留回收
$r3 = json_decode(httpGet($srv['port'], '/stats'), true);
check(
    'F2：请求 2 正常收尾后不再有继承条目（inherited=0）',
    ($r3['inherited'] ?? null) === 0,
    'inherited=' . var_export($r3['inherited'] ?? null, true)
);
check(
    'F2：请求 1 的遗留已被回收（pending=0）',
    ($r3['pending'] ?? null) === 0,
    'pending=' . var_export($r3['pending'] ?? null, true)
);
check(
    'F2：请求号逐请求递增（R3 = R2 + 1）',
    is_array($r2) && is_array($r3)
        && ($r3['current_req'] ?? -1) === ($r2['current_req'] ?? -2) + 1,
    'r2=' . var_export($r2['current_req'] ?? null, true)
        . ' r3=' . var_export($r3['current_req'] ?? null, true)
);

$srvLog = serverStop($srv);
check(
    'F2：服务端日志含 RSHUTDOWN 钩子探针 Fatal（bailout 确有发生）',
    str_contains($srvLog, 'php-zig rshutdown hook bailout probe'),
    'log=' . substr(str_replace("\n", ' ', trim($srvLog)), 0, 120)
);
check(
    'F2：worker 未崩溃（日志无 Segmentation fault）',
    !str_contains($srvLog, 'Segmentation fault'),
    'log=' . substr(str_replace("\n", ' ', trim($srvLog)), -120)
);

// ============================================================
// 结果汇总
// ============================================================
echo "\n========================================\n";
echo "bailout 兜底测试：通过 {$passed}，失败 {$failed}，实跑 " . ($passed + $failed) . "\n";
echo "预期诊断：B/C/D 三组各 1 条探针 Fatal error（本组断言对象），E 组经 stderr 单独断言，A 组 0 条\n";
if ($passed + $failed < EXPECTED_MIN_CHECKS) {
    echo "结构断言失败：实跑 " . ($passed + $failed) . " 条断言，低于下界 " . EXPECTED_MIN_CHECKS . "\n";
    exit(1);
}
echo $failed === 0 ? "全部通过\n" : "有失败项！\n";
exit($failed === 0 ? 0 : 1);
