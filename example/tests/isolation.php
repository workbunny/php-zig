<?php
/**
 * 子进程隔离 + 诊断分类 —— crash / corpus / bailout 三个隔离型测试共用
 *
 * 【隔离后端】两个，表现等价（都是拷贝进程镜像出一个子进程，子进程内崩溃不波及父进程）：
 *   pcntl —— NTS 构建自带：pcntl_fork + pcntl_waitpid + pcntl_wif*
 *   ffi   —— ZTS 构建不带 pcntl，改用 FFI 直调 libc 的 fork/waitpid，
 *            状态字按 POSIX 宏在 PHP 侧解码（glibc/musl 一致）
 * 选择顺序 pcntl → ffi；可用环境变量 PZ_ISOLATE_BACKEND=pcntl|ffi 强制，
 * 便于 NTS/ZTS 两档分别验证各自后端。FFI 路径需要 ffi 扩展与 ffi.enable=1
 * （CLI 默认为 preload，非预加载脚本会被拒）。
 *
 * 【诊断的两条通道】
 *   display_errors → 输出缓冲（子进程 ob_start() 可拦）
 *   log_errors     → SAPI 日志；CLI 下写 fd 2，ob_start() **拦不住**
 * 提示：子进程两条都关（只关 display 会把诊断漏进父进程日志）；诊断一律经本文件的
 *       回传通道收集 —— 入账之后 stderr 上不该再出现任何输出。
 *
 * 【能力】
 * 诊断由「副作用」变为「数据」：set_error_handler（非致命）+
 * register_shutdown_function（致命）捕获 → socketpair 回传 → 调用方按坐标分类。
 * 退出码与信号一并回传，故「致命错误退出」与「正常返回」可区分。
 *
 * 【上限】
 * 回传走 socket：单条消息截断到 ISOLATE_MSG_MAX、条数上限 ISOLATE_DIAG_MAX。
 * 提示：父进程在 waitpid 之后才读，写满缓冲区会让子进程阻塞在写操作上、
 *       waitpid 永不返回 —— 两个上限是死锁护栏。
 */

/** 单条诊断消息截断长度（字节） */
const ISOLATE_MSG_MAX = 512;
/** 回传诊断条数上限 */
const ISOLATE_DIAG_MAX = 32;

/** 崩溃信号名（只列测试可能真正遇到的） */
function signalName(int $sig): string
{
    return match ($sig) {
        11 => 'SEGV',
        6  => 'ABRT',
        4  => 'ILL',
        7  => 'BUS',
        8  => 'FPE',
        default => "SIG{$sig}",
    };
}

/**
 * 该「抛出」是否说明**环境/前置缺失**，而不是被测代码的行为。
 *
 * 判据：扩展未加载（或某个函数/类没注册）时，子进程抛的是
 * `Error: Call to undefined function xxx()` / `Class "X" not found`。
 * 这类结果在「只要不崩溃就算合格」的断言下会被当成通过 —— 那是假绿：
 * 它证明的是"什么都没跑到"，不是"没崩"。调用方拿到 true 必须判失败。
 */
function envBrokenThrow(?string $thrown): bool
{
    if ($thrown === null) {
        return false;
    }
    return preg_match('/Call to undefined function|Class ".*" not found|Undefined constant/', $thrown) === 1;
}

/**
 * 当前进程可用的隔离后端：'pcntl' | 'ffi' | null（null = 都没得用）。
 *
 * 探测而非假设：FFI 是否可用取决于扩展与 ffi.enable（preload 下不可用）。
 * 调用方拿到 null 必须显式跳过并打印，不得让「没跑」伪装成「通过」。
 */
function isolateBackend(): ?string
{
    static $probed = false;
    static $backend = null;
    if ($probed) {
        return $backend;
    }
    $probed = true;

    $forced = getenv('PZ_ISOLATE_BACKEND');
    if ($forced === 'pcntl' || $forced === 'ffi') {
        return $backend = (isolateBackendUsable($forced) ? $forced : null);
    }
    if (isolateBackendUsable('pcntl')) {
        return $backend = 'pcntl';
    }
    if (isolateBackendUsable('ffi')) {
        return $backend = 'ffi';
    }
    return $backend = null;
}

/** 指定后端在当前进程是否真的可用 */
function isolateBackendUsable(string $name): bool
{
    if ($name === 'pcntl') {
        return function_exists('pcntl_fork') && function_exists('pcntl_waitpid');
    }
    if (!class_exists('FFI')) {
        return false;
    }
    try {
        isolateFfi();
        return true;
    } catch (\Throwable) {
        // ffi.enable=preload 时 cdef 会抛错——正是要探测的状态
        return false;
    }
}

/** FFI 句柄。lib 传 null = 用当前进程已加载的符号（libc 一定在） */
function isolateFfi(): FFI
{
    static $ffi = null;
    return $ffi ??= FFI::cdef(
        "int fork(void);\nint waitpid(int pid, int *status, int options);\n",
    );
}

/** 复制出子进程；返回 0 = 当前是子进程，-1 = 失败 */
function isolateFork(): int
{
    return isolateBackend() === 'ffi' ? (int) isolateFfi()->fork() : pcntl_fork();
}

/**
 * 等子进程结束，返回 [退出码, 信号名]。
 * FFI 路径下状态字由 PHP 侧按 POSIX 宏解码：
 *   退出 = (status & 0x7f) == 0，退出码 = (status >> 8) & 0xff
 *   信号 = ((status & 0x7f) + 1) >> 1 > 0，信号号 = status & 0x7f
 */
function isolateWait(int $pid): array
{
    if (isolateBackend() === 'ffi') {
        $ffi = isolateFfi();
        $status = $ffi->new('int');
        $ffi->waitpid($pid, FFI::addr($status), 0);
        $s = (int) $status->cdata;
        $exited = ($s & 0x7f) === 0;
        $signaled = ((($s & 0x7f) + 1) >> 1) > 0;
        return [$exited ? (($s >> 8) & 0xff) : -1, $signaled ? signalName($s & 0x7f) : null];
    }

    pcntl_waitpid($pid, $status);
    $exited = pcntl_wifexited($status);
    $signaled = pcntl_wifsignaled($status);
    return [$exited ? pcntl_wexitstatus($status) : -1, $signaled ? signalName(pcntl_wtermsig($status)) : null];
}

/**
 * 复制出子进程执行 $fn，回传结构化结果。子进程内任何诊断都不再流向终端。
 *
 * 后端由 isolateBackend() 决定（pcntl 或 FFI fork），调用方无需关心。
 *
 * 诊断回传被截断（超过 ISOLATE_DIAG_MAX）时**直接失败退出**：截断意味着分类通道
 * 不可信，此时"意外诊断为空"可能只是因为那条被丢了，继续跑就是假绿。
 *
 * @return array{
 *   signal: ?string,
 *   exit: int,
 *   outcome: string,   // return | throw | fatal | lost
 *   thrown: ?string,
 *   diags: list<array{type:int, msg:string, fatal:bool}>,
 *   diagsDropped: int  // 超出 ISOLATE_DIAG_MAX 被丢弃的条数
 * }
 */
function forkIsolate(callable $fn): array
{
    if (isolateBackend() === null) {
        fwrite(STDERR, "forkIsolate: 无可用隔离后端（pcntl 与 FFI 都不可用）\n");
        exit(1);
    }

    $pair = stream_socket_pair(STREAM_PF_UNIX, STREAM_SOCK_STREAM, STREAM_IPPROTO_IP);
    if ($pair === false) {
        // 没有 socketpair 就不假装能隔离诊断：静默降级等于把诊断重新变成泄漏
        fwrite(STDERR, "forkIsolate: stream_socket_pair 不可用，无法隔离诊断\n");
        exit(1);
    }
    [$parentEnd, $childEnd] = $pair;

    $pid = isolateFork();
    if ($pid === -1) {
        fwrite(STDERR, "forkIsolate: 复制子进程失败\n");
        exit(1);
    }
    if ($pid === 0) {
        fclose($parentEnd);
        isolateChildMain($fn, $childEnd);
        // isolateChildMain 不返回
    }
    fclose($childEnd);
    [$exitCode, $sigName] = isolateWait($pid);

    // 子进程已退出 → 写端全部关闭 → 这里读到 EOF，不会阻塞
    $raw = stream_get_contents($parentEnd);
    fclose($parentEnd);

    $payload = is_string($raw) && $raw !== '' ? json_decode($raw, true) : null;

    $dropped = is_array($payload) ? (int) ($payload['dropped'] ?? 0) : 0;
    if ($dropped > 0) {
        fwrite(STDERR, "forkIsolate: 诊断回传被截断（丢弃 {$dropped} 条，上限 " . ISOLATE_DIAG_MAX
            . "）：分类不可信，按失败处理\n");
        exit(1);
    }

    return [
        'signal'       => $sigName,
        'exit'         => $exitCode,
        // 'lost' = 子进程没来得及回传（被信号杀死 / 致命错误前就死了）
        'outcome'      => is_array($payload) ? ($payload['outcome'] ?? 'lost') : 'lost',
        'thrown'       => is_array($payload) ? ($payload['thrown'] ?? null) : null,
        'diags'        => is_array($payload) ? ($payload['diags'] ?? []) : [],
        'diagsDropped' => is_array($payload) ? ($payload['dropped'] ?? 0) : 0,
    ];
}

/**
 * 子进程主体：跑一次 $fn，把「结果 + 全部诊断」写回父进程。
 * 正常返回 / 抛异常 / 致命错误三条路径都要回传，故发送逻辑只写一份。
 */
function isolateChildMain(callable $fn, $sock): void
{
    // 关掉两条输出通道。log_errors 必须关：它是唯一能穿透 ob_start 的通道。
    ini_set('log_errors', '0');
    ini_set('display_errors', '0');

    $diags = [];
    $dropped = 0;
    $sent = false;
    $outcome = 'return';
    $thrown = null;

    $send = function () use (&$sent, &$diags, &$dropped, &$outcome, &$thrown, $sock): void {
        if ($sent) {
            return;
        }
        $sent = true;
        // 致命错误路径下 ob_end_clean() 不会被调用，缓冲会在请求收尾时被 flush，
        // 故在此统一清空 —— 否则子进程的中间输出会漏到父进程终端。
        while (ob_get_level() > 0) {
            ob_end_clean();
        }
        $json = json_encode([
            'outcome' => $outcome,
            'thrown'  => $thrown,
            'diags'   => $diags,
            'dropped' => $dropped,
        ], JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE | JSON_PARTIAL_OUTPUT_ON_ERROR);
        fwrite($sock, is_string($json) ? $json : '');
        fclose($sock);
    };

    set_error_handler(function (int $type, string $msg) use (&$diags, &$dropped): bool {
        // E_USER_ERROR 必须放行（返回 false）。
        // 提示：处理器返回 true 会**取消**它的致命语义 —— trigger_error(E_USER_ERROR)
        //       退化成普通提示、bailout 不再发生（C 组会变成 exit=0 且 defer 照跑）。
        // 放行不产生泄漏：两条输出通道已在上方关闭，消息由 shutdown 处理器取回。
        if ($type === E_USER_ERROR) {
            return false;
        }
        if (count($diags) >= ISOLATE_DIAG_MAX) {
            $dropped++;
            return true;
        }
        $diags[] = [
            'type'  => $type,
            // 截断在字节边界，可能切断多字节字符 —— JSON_INVALID_UTF8_SUBSTITUTE 兜住
            'msg'   => strlen($msg) > ISOLATE_MSG_MAX ? substr($msg, 0, ISOLATE_MSG_MAX) . '…' : $msg,
            'fatal' => false,
        ];
        return true; // 吞掉：诊断已回传，不再走 display/log
    });

    // 致命错误（E_ERROR/E_USER_ERROR 等）不经 set_error_handler，只能在收尾时取回
    register_shutdown_function(function () use (&$diags, &$outcome, $send): void {
        $e = error_get_last();
        if ($e !== null && in_array($e['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR, E_USER_ERROR], true)) {
            $diags[] = [
                'type'  => $e['type'],
                'msg'   => strlen($e['message']) > ISOLATE_MSG_MAX
                    ? substr($e['message'], 0, ISOLATE_MSG_MAX) . '…'
                    : $e['message'],
                'fatal' => true,
            ];
            $outcome = 'fatal';
        }
        $send();
    });

    ob_start();
    try {
        $fn();
    } catch (\Throwable $e) {
        // 抛异常是 PHP 的可预期行为，不是崩溃
        $outcome = 'throw';
        $thrown = get_class($e) . ': ' . $e->getMessage();
    }
    $send();
    exit(0);
}

/** 把 forkIsolate 的结果压成一个可读标签（三个测试共用同一套词汇） */
function isolateTag(array $res): string
{
    if ($res['signal'] !== null) {
        return "CRASH({$res['signal']})";
    }
    return match ($res['outcome']) {
        'return' => 'return',
        'throw'  => 'throw',
        'fatal'  => 'fatal',
        default  => "exit({$res['exit']})",
    };
}

/** 诊断文本：统一成 "Warning: 消息" 形式，便于报告与比对 */
function diagText(array $d): string
{
    $kind = match (true) {
        $d['fatal']        => 'Fatal',
        $d['type'] === E_WARNING     => 'Warning',
        $d['type'] === E_NOTICE      => 'Notice',
        $d['type'] === E_DEPRECATED  => 'Deprecated',
        default            => "type({$d['type']})",
    };
    return "{$kind}: {$d['msg']}";
}

/** 落在允许集合内的诊断条数（按「有没有落在集合里」计数，不按 pattern 计） */
function countExpectedDiags(array $diags, array $patterns): int
{
    $n = 0;
    foreach ($diags as $d) {
        foreach ($patterns as $p) {
            if (preg_match($p, $d['msg']) === 1) {
                $n++;
                break;
            }
        }
    }
    return $n;
}

/**
 * 不在允许集合内的诊断文本（= 意外诊断）。
 * 允许集合是正则列表，调用方按坐标声明「这一格该出什么」，
 * 声明之外的任何一条都算意外 —— 这是分类能成立的前提。
 *
 * @return list<string>
 */
function unexpectedDiags(array $diags, array $patterns): array
{
    $bad = [];
    foreach ($diags as $d) {
        $hit = false;
        foreach ($patterns as $p) {
            if (preg_match($p, $d['msg']) === 1) {
                $hit = true;
                break;
            }
        }
        if (!$hit) {
            $bad[] = diagText($d);
        }
    }
    return $bad;
}
