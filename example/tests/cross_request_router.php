<?php
/**
 * F 组（跨请求继承）的 `php -S` 路由器。
 *
 * 两条路径：
 *   /bail   武装「本次请求收尾时在 RSHUTDOWN 钩子里注册条目并 bailout」
 *   /stats  返回 Cleanup.stats()（请求序号、继承条目数、在册条目数）
 *
 * 本文件不做任何判断 —— 断言全部在 test_bailout.php 里。
 *
 * 为什么必须用 php -S：CLI 单进程只跑一个请求，观测不到「上一请求收尾被中断、
 * 本请求继承其条目」这条链；php -S 是一个进程顺序处理多个请求，正是复现所需。
 */

header('Content-Type: application/json');

$uri = $_SERVER['REQUEST_URI'] ?? '';

if ($uri === '/bail') {
    echo json_encode(['armed' => hello_arm_rshutdown_bailout(3)]);

    return;
}

$stats = hello_cleanup_stats();
$stats['uri'] = $uri;

echo json_encode($stats);
