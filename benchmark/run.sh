#!/usr/bin/env bash
# php-zig benchmark 一键运行：编译两个扩展 + 依次测量 + 汇总对比
#
# 用法：
#   bash run.sh [iters] [rounds]     默认 100 万次迭代、5 轮取中位数
#   PHP_SDK=/path bash run.sh        指定 PHP SDK（默认 /usr/local，同 -Dphp）
#
# 前提：php 在 PATH 中；zig / gcc 可用。
set -euo pipefail
cd "$(dirname "$0")"

ITERS="${1:-1000000}"
ROUNDS="${2:-5}"
PHP_SDK="${PHP_SDK:-/usr/local}"

echo "================ php-zig benchmark ================"
echo "iters=$ITERS  rounds=$ROUNDS  PHP_SDK=$PHP_SDK"
echo ""

# ---- 编译 php-zig（含首次 fingerprint 自动修复）----
# -Doptimize=ReleaseFast 不可省：Debug 构建比 C 的 -O2 慢 1.3~5 倍，
# 拿 Debug 去比 -O2 的 C 会让整份数据失去意义。
echo "[1/2] 编译 php-zig 扩展（bench_zig，ReleaseFast）..."
if ! BUILD_LOG=$(cd php_zig && zig build -Dphp="$PHP_SDK" -Doptimize=ReleaseFast --cache-dir=/tmp/zig-cache --summary all 2>&1); then
    echo "$BUILD_LOG"
    if echo "$BUILD_LOG" | grep -qi "fingerprint"; then
        NEW_FP=$(echo "$BUILD_LOG" | grep -oE '0x[0-9a-fA-F]{16}' | tail -1)
        if [ -n "$NEW_FP" ]; then
            echo ">>> 首次构建：自动更新 fingerprint -> $NEW_FP"
            sed -i "s/\.fingerprint = 0x0,/.fingerprint = $NEW_FP,/" php_zig/build.zig.zon
            (cd php_zig && zig build -Dphp="$PHP_SDK" -Doptimize=ReleaseFast --cache-dir=/tmp/zig-cache --summary all)
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

# ---- 测量 ----
echo ""
echo "================ 运行 benchmark ================"
RESULTS="results.tsv"
MEM_RESULTS="memory.tsv"
: > "$RESULTS"

# taskset 固定 CPU：跨核调度会让同一用例的抖动达到数倍
CPUSET=""
if command -v taskset >/dev/null 2>&1; then
    CPUSET="taskset -c 0"
    echo "  (已启用 taskset -c 0 固定 CPU)"
fi

echo "  -> bench_zig（php-zig）"
$CPUSET php -d extension=php_zig/zig-out/lib/libbench_zig.so bench.php bench_zig "$ITERS" "$ROUNDS" >> "$RESULTS"
echo "  -> bench_c（原生 C）"
$CPUSET php -d extension=c_ext/bench_c.so                  bench.php bench_c    "$ITERS" "$ROUNDS" >> "$RESULTS"
echo "  -> pure_php（纯 PHP）"
$CPUSET php bench.php pure_php "$ITERS" "$ROUNDS" >> "$RESULTS"

# ---- 汇总 ----
echo ""
echo "================ 汇总对比（ns/op，越低越好） ================"
php bench.php --summary "$RESULTS"

# ---- 内存占用（空间敏感场景）----
echo ""
echo "================ 内存占用对比 ================"
: > "$MEM_RESULTS"
for m in bench_zig bench_c pure_php; do
    case "$m" in
        bench_zig) EXT="-dextension=php_zig/zig-out/lib/libbench_zig.so" ;;
        bench_c)   EXT="-dextension=c_ext/bench_c.so" ;;
        *)         EXT="" ;;
    esac
    echo "  -> $m（内存）"
    if [ -n "$EXT" ]; then
        $CPUSET php $EXT memory.php "$m" "$ITERS" >> "$MEM_RESULTS"
    else
        $CPUSET php memory.php "$m" "$ITERS" >> "$MEM_RESULTS"
    fi
done
php memory.php --summary "$MEM_RESULTS"

echo ""
echo "结果已写入 $RESULTS / $MEM_RESULTS"
