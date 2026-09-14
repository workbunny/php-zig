<?php
/**
 * fork 隔离 + 诊断分类 —— crash / corpus / bailout 三个隔离型测试共用
 *
 * 【为什么要显式回传通道】
 * PHP 的诊断走两条互不相干的通道：
 *   display_errors → 输出缓冲，子进程的 ob_start() 能拦住
 *   log_errors     → SAPI 日志；CLI 下写 fd 2 stderr，ob_start() **拦不住**
 * 只关 display 时警告仍会漏进父进程日志。实测（PHP 8.4.19 / CLI）：
 *   php -d display_errors=0 -d log_errors=1 test_corpus.php   → 漏 21 条
 *   php -d log_errors=0                     test_corpus.php   → 漏 0 条
 * 泄漏通道是 log_errors，与 display_errors 无关 —— test_bailout 早就
 * ini_set('display_errors','0')，因为关错了通道所以没用。
 *
 * 【本文件做什么】
 * 把诊断从「副作用」变成「数据」：子进程内关掉两条通道，用
 * set_error_handler（非致命）+ register_shutdown_function（致命）捕获，
 * 经 socketpair 回到父进程，由调用方按坐标分类。
 * 副产品：stderr 变成真正的报警器 —— 诊断全部入账后它上面不该再有任何输出。
 *
 * 【边界】
 * 回传走 socket，容量有限：单条消息截断到 ISOLATE_MSG_MAX、条数上限
 * ISOLATE_DIAG_MAX。父进程在 waitpid 之后才读，子进程若写满缓冲区会阻塞在
 * 写操作上、waitpid 永不返回 —— 所以这两个上限是死锁护栏，不是审美选择。
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
 * fork 出子进程执行 $fn，回传结构化结果。子进程内任何诊断都不再流向终端。
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
    $pair = stream_socket_pair(STREAM_PF_UNIX, STREAM_SOCK_STREAM, STREAM_IPPROTO_IP);
    if ($pair === false) {
        // 没有 socketpair 就不假装能隔离诊断：静默降级等于把诊断重新变成泄漏
        fwrite(STDERR, "forkIsolate: stream_socket_pair 不可用，无法隔离诊断\n");
        exit(1);
    }
    [$parentEnd, $childEnd] = $pair;

    $pid = pcntl_fork();
    if ($pid === 0) {
        fclose($parentEnd);
        isolateChildMain($fn, $childEnd);
        // isolateChildMain 不返回
    }
    fclose($childEnd);
    pcntl_waitpid($pid, $status);

    $signaled = pcntl_wifsignaled($status);
    $exited = pcntl_wifexited($status);
    $exitCode = $exited ? pcntl_wexitstatus($status) : -1;
    $sigName = $signaled ? signalName(pcntl_wtermsig($status)) : null;

    // 子进程已退出 → 写端全部关闭 → 这里读到 EOF，不会阻塞
    $raw = stream_get_contents($parentEnd);
    fclose($parentEnd);

    $payload = is_string($raw) && $raw !== '' ? json_decode($raw, true) : null;

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
        // E_USER_ERROR 必须放行（返回 false）：用户错误处理器返回 true 会**取消**它的
        // 致命语义，trigger_error(E_USER_ERROR) 就退化成普通提示、bailout 不再发生
        // —— 实测过，吞掉它会让 test_bailout 的 C 组变成 exit=0、defer 照跑。
        // 放行不会造成泄漏：两条输出通道已在上方关闭，消息由 shutdown 处理器取回。
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
