#!/usr/bin/env bash
# php-zig benchmark 一键运行：编译两个扩展 + 依次测量 + 汇总对比
#
# 用法：
#   bash run.sh [iters] [rounds] [mem_iters]
#   PHP_SDK=/path bash run.sh        指定 PHP SDK（默认 /usr/local，同 -Dphp）
#   ZIG=/path/to/zig bash run.sh     指定 zig（容器内常不在 PATH 里）
#   SKIP_BUILD=1 bash run.sh         跳过编译，直接测量（交叉编译产物已在位时）
#
# 不带参即文档复现参数：性能 30 万次迭代 × 5 轮，内存 200 次重复。
# mem_iters 与 iters 语义不同、量级差三个数量级，不可混用（见下）。
#
# 前提：php 在 PATH 中；zig / gcc 可用。
set -euo pipefail
cd "$(dirname "$0")"

ITERS="${1:-300000}"
ROUNDS="${2:-5}"
MEM_ITERS="${3:-200}"
PHP_SDK="${PHP_SDK:-/usr/local}"
ZIG="${ZIG:-zig}"
SKIP_BUILD="${SKIP_BUILD:-0}"

echo "================ php-zig benchmark ================"
echo "iters=$ITERS  rounds=$ROUNDS  mem_iters=$MEM_ITERS  PHP_SDK=$PHP_SDK"
echo ""

# ---- 编译 php-zig（含首次 fingerprint 自动修复）----
# -Doptimize=ReleaseFast 不可省：Debug 构建比 C 的 -O2 慢 1.3~5 倍，
# 拿 Debug 去比 -O2 的 C 会让整份数据失去意义。
if [ "$SKIP_BUILD" = "1" ]; then
    echo "[1/2] 跳过编译（SKIP_BUILD=1），沿用既有产物"
else
echo "[1/2] 编译 php-zig 扩展（bench_zig，ReleaseFast）..."
if ! BUILD_LOG=$(cd php_zig && "$ZIG" build -Dphp="$PHP_SDK" -Doptimize=ReleaseFast --cache-dir=/tmp/zig-cache --summary all 2>&1); then
    echo "$BUILD_LOG"
    if echo "$BUILD_LOG" | grep -qi "fingerprint"; then
        NEW_FP=$(echo "$BUILD_LOG" | grep -oE '0x[0-9a-fA-F]{16}' | tail -1)
        if [ -n "$NEW_FP" ]; then
            echo ">>> 首次构建：自动更新 fingerprint -> $NEW_FP"
            sed -i "s/\.fingerprint = 0x0,/.fingerprint = $NEW_FP,/" php_zig/build.zig.zon
            (cd php_zig && "$ZIG" build -Dphp="$PHP_SDK" -Doptimize=ReleaseFast --cache-dir=/tmp/zig-cache --summary all)
        else
            echo ">>> 无法自动确定 fingerprint，请按上方提示手动更新 php_zig/build.zig.zon" >&2
            exit 1
        fi
    else
        exit 1
    fi
fi

# ---- 编译原生 C ----
echo "[2/2] 编译原生 C 扩展（bench_c，gcc -O2）..."
bash c_ext/build.sh
fi

# ---- 测量 ----
echo ""
echo "================ 运行 benchmark ================"
RESULTS="results.tsv"
MEM_RESULTS="memory.tsv"
: > "$RESULTS"

# 不绑核：实测在负载不为空的宿主机上 taskset -c 0 会把进程按在被争抢的核上，
# real 达到 user 的 3 倍（CPU 利用率仅 32%），同一用例慢 3 倍——绑核带来的
# 「消除抖动」收益远小于争抢造成的损失。抖动由多轮取中位数吸收。

echo "  -> bench_zig（php-zig）"
php -d extension=php_zig/zig-out/lib/libbench_zig.so bench.php bench_zig "$ITERS" "$ROUNDS" >> "$RESULTS"
echo "  -> bench_c（原生 C）"
php -d extension=c_ext/bench_c.so                  bench.php bench_c    "$ITERS" "$ROUNDS" >> "$RESULTS"
echo "  -> pure_php（纯 PHP）"
php bench.php pure_php "$ITERS" "$ROUNDS" >> "$RESULTS"

# ---- 汇总 ----
echo ""
echo "================ 汇总对比（ns/op，越低越好） ================"
php bench.php --summary "$RESULTS"

# ---- 内存占用（空间敏感场景）----
#
# memory.php 的 iters 是「用例重复次数」，单次调用固定处理 10 万级数据
# （小数据量会淹没在进程基线里，见 README）。它与 bench.php 的 iters
# 「每次调用处理一条数据」语义不同：把 30 万传过去等于每用例 3×10^10 次
# 元素操作，永远跑不完。故内存走独立的 MEM_ITERS。
echo ""
echo "================ 内存占用对比（mem_iters=$MEM_ITERS） ================"
: > "$MEM_RESULTS"
for m in bench_zig bench_c pure_php; do
    case "$m" in
        bench_zig) EXT="-dextension=php_zig/zig-out/lib/libbench_zig.so" ;;
        bench_c)   EXT="-dextension=c_ext/bench_c.so" ;;
        *)         EXT="" ;;
    esac
    echo "  -> $m（内存）"
    if [ -n "$EXT" ]; then
        php $EXT memory.php "$m" "$MEM_ITERS" >> "$MEM_RESULTS"
    else
        php memory.php "$m" "$MEM_ITERS" >> "$MEM_RESULTS"
    fi
done
php memory.php --summary "$MEM_RESULTS"

echo ""
echo "结果已写入 $RESULTS / $MEM_RESULTS"
