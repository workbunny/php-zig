#!/usr/bin/env bash
# 编译原生 C benchmark 扩展 bench_c.so
# 依赖：php-dev（提供 php-config 与头文件）
set -euo pipefail
cd "$(dirname "$0")"

PHP_CONFIG="${PHP_CONFIG:-php-config}"

echo "[c_ext] 编译 bench_c.so ..."
gcc -O2 -shared -fPIC -o bench_c.so bench.c $($PHP_CONFIG --includes)
echo "[c_ext] 完成 -> bench_c.so"
