#!/usr/bin/env bash
# php-zig 基准报告：把 run.sh 产出的两份 TSV 汇总成一份 markdown
#
# CI 的 job summary（`.github/workflows/benchmark.yml`）与本地查看共用本脚本，口径一致。
#
# 用法：
#   bash report.sh [results.tsv] [memory.tsv] [out.md]
#   MAX_RATIO=3 bash report.sh ...     # 粗粒度守卫：最大 zig/C 开销比超过该值即退出 1
#                                      # 0（默认）= 不做守卫
#
# 元信息由环境变量注入（缺失显示 —）：BENCH_COMMIT BENCH_PHP BENCH_ZIG BENCH_CPU BENCH_PARAMS
#
# 提示：报告以**比值**为主 —— 绝对值跨 run 不可比（见 README「已知限制」）；
#       同一次运行内的 zig/C 比值用于趋势判断与守卫。
set -euo pipefail
cd "$(dirname "$0")"

RESULTS="${1:-results.tsv}"
MEM="${2:-memory.tsv}"
OUT="${3:-}"
MAX_RATIO="${MAX_RATIO:-0}"

if [ ! -s "$RESULTS" ]; then
    echo "report: $RESULTS 为空或不存在（先跑 run.sh）" >&2
    exit 1
fi

meta() { printf '%s' "${1:-—}"; }

# zig/C 开销比，按从大到小：`比值<TAB>用例`
ratio_table() {
    awk -F'\t' '
        $1 == "bench_c"   { c[$2] = $3 }
        $1 == "bench_zig" { z[$2] = $3 }
        END { for (k in z) if (c[k] > 0) printf "%.3f\t%s\n", z[k] / c[k], k }
    ' "$RESULTS" | sort -rn
}

emit() {
    cat <<EOF
# php-zig 基准报告

| 项 | 值 |
|---|---|
| 提交 | $(meta "${BENCH_COMMIT:-}") |
| PHP | $(meta "${BENCH_PHP:-}") |
| Zig | $(meta "${BENCH_ZIG:-}") |
| CPU | $(meta "${BENCH_CPU:-}") |
| 参数 | $(meta "${BENCH_PARAMS:-}") |

> **口径**：CI runner（共享、虚拟化）的 CPU 与负载每轮都不同，**绝对值跨 run 无意义**；
> 同一次运行内的 **zig / C 比值**是同机同轮测出，才具备粗略可比性。文档复现参数
> （30 万次 × 5 轮）与正式结论见 \`benchmark/README.md\`，CI 默认用小一档参数换运行时长。

## 调用开销（ns/op，越低越好）

EOF
    php bench.php --summary "$RESULTS"

    cat <<EOF

## 内存占用（增量，越低越好）

EOF
    php memory.php --summary "$MEM"

    cat <<EOF

## zig / C 开销比（守卫口径）

EOF
    ratio_table | head -5 | awk -F'\t' '{ printf "- %s：**%sx**\n", $2, $1 }'
}

# 先产出报告，再判定守卫：守卫失败时报告已落盘/落屏
if [ -n "$OUT" ]; then
    emit | tee "$OUT"
else
    emit
fi

if [ "$MAX_RATIO" != "0" ]; then
    WORST=$(ratio_table | head -1 || true)
    if [ -n "$WORST" ]; then
        R=$(printf '%s' "$WORST" | cut -f1)
        CASE=$(printf '%s' "$WORST" | cut -f2)
        if awk -v r="$R" -v t="$MAX_RATIO" 'BEGIN { exit !(r > t) }'; then
            echo "" >&2
            echo "❌ zig/C 开销比 $CASE = ${R}x，超过阈值 ${MAX_RATIO}x" >&2
            echo "   提示：本守卫针对构建配置事故（如漏掉 -Doptimize=ReleaseFast）；" >&2
            echo "   正常波动不触发（同机比值极差可达 0.15x，见 benchmark/README.md「已知限制」）。" >&2
            exit 1
        fi
    fi
fi
