<?php
/**
 * 纯 PHP baseline 实现。
 *
 * 由 bench.php 仅在 pure_php 模式 require 引入；扩展模式不加载，
 * 避免与扩展导出的同名函数（bench_empty 等）冲突。
 *
 * 语义必须与 bench_c / bench_zig 严格一致。
 */

function bench_empty() { return null; }

function bench_add($a, $b) { return $a + $b; }

function bench_concat($s1, $s2) { return $s1 . $s2; }

// 与扩展侧一致：只建数组，返回元素个数（不读回）
function bench_array_build($n) {
    $arr = [];
    for ($i = 0; $i < $n; $i++) {
        $arr[] = $i;
    }
    return $n;
}

// 与扩展侧一致：建表 + 逐个读回求和
function bench_array_read($n) {
    $arr = [];
    for ($i = 0; $i < $n; $i++) {
        $arr[] = $i;
    }
    $sum = 0;
    for ($i = 0; $i < $n; $i++) {
        $sum += $arr[$i];
    }
    return $sum;
}

function bench_assoc($n) {
    $arr = [];
    for ($i = 0; $i < $n; $i++) {
        $arr["k" . $i] = $i;
    }
    $sum = 0;
    for ($i = 0; $i < $n; $i++) {
        $sum += $arr["k" . $i];
    }
    return $sum;
}

function bench_str_len($s) { return strlen($s); }

function bench_math($n) {
    $acc = 0;
    for ($i = 0; $i < $n; $i++) {
        $acc += ($i * 31 + 7) % 1009;
    }
    return $acc;
}

// 与扩展侧一致：循环调用 PHP 函数 strlen
function bench_call_php($n) {
    $total = 0;
    for ($i = 0; $i < $n; $i++) {
        $total += strlen("hello");
    }
    return $total;
}

function bench_object($n) {
    $obj = new stdClass();
    for ($i = 0; $i < $n; $i++) {
        $obj->{"p" . $i} = $i;
    }
    $sum = 0;
    for ($i = 0; $i < $n; $i++) {
        $sum += $obj->{"p" . $i};
    }
    return $sum;
}

// 与扩展侧一致：抛异常 + 清理，返回成功次数
function bench_throw($n) {
    $caught = 0;
    for ($i = 0; $i < $n; $i++) {
        try {
            throw new Exception("bench");
        } catch (Throwable $e) {
            $caught++;
        }
    }
    return $caught;
}

// 与扩展侧一致：long / string / double 按 i%3 轮换，再逐个读回求和
function bench_mixed($n) {
    $arr = [];
    for ($i = 0; $i < $n; $i++) {
        switch ($i % 3) {
            case 0: $arr[] = $i; break;
            case 1: $arr[] = "v" . $i; break;
            default: $arr[] = $i * 1.5; break;
        }
    }
    $sum = 0;
    for ($i = 0; $i < $n; $i++) {
        $sum += (int) $arr[$i];
    }
    return $sum;
}

// 与扩展侧一致：n 行 × 单个 id 字段的嵌套数组
function bench_nested($n) {
    $arr = [];
    for ($i = 0; $i < $n; $i++) {
        $arr[] = ["id" => $i * 4];
    }
    $sum = 0;
    for ($i = 0; $i < $n; $i++) {
        $sum += $arr[$i]["id"];
    }
    return $sum;
}

// 与扩展侧一致：64 个固定键的字典，读密集访问
function bench_strkey($n) {
    $arr = [];
    for ($i = 0; $i < 64; $i++) {
        $arr["key_" . $i] = $i;
    }
    $sum = 0;
    for ($i = 0; $i < $n; $i++) {
        $sum += $arr["key_" . ($i % 64)];
    }
    return $sum;
}

// 与扩展侧一致：对传入对象调用真实方法 method()
function bench_method($obj, $n) {
    $total = 0;
    for ($i = 0; $i < $n; $i++) {
        $total += $obj->method();
    }
    return $total;
}

function bench_serialize($n) {
    $arr = [];
    for ($i = 0; $i < 8; $i++) {
        $arr[] = $i;
    }
    $total = 0;
    for ($i = 0; $i < $n; $i++) {
        $total += strlen(serialize($arr));
    }
    return $total;
}

function bench_closure($n) {
    $total = 0;
    for ($i = 0; $i < $n; $i++) {
        $fn = function () { return 1; };
        $total += $fn();
    }
    return $total;
}

// Fiber 体：被 bench_fiber 创建后并不启动，只测创建开销
function bench_fiber_body() {
    Fiber::suspend();
}

function bench_make_fiber($callable) {
    return new Fiber($callable);
}

function bench_fiber($n) {
    $total = 0;
    for ($i = 0; $i < $n; $i++) {
        $f = new Fiber('bench_fiber_body');
        $total++;
        unset($f);
    }
    return $total;
}

// PHP 侧无 RequestArena 对等物：用 str_repeat 制造等量的请求级分配，
// 量级可比，语义不同——此项只看 zig 与 C 的对比
function bench_arena($n) {
    $total = 0;
    for ($i = 0; $i < $n; $i++) {
        $s = str_repeat('x', 64);
        $total += 64;
    }
    return $total;
}
