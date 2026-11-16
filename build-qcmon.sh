#!/bin/sh
# 编译 qcmon：默认出 arm64 静态包，参数 x86 时出本机版（调试用）
set -e
cd "$(dirname "$0")"
OUT=${2:-bin/qcmon}
if [ "$1" = x86 ]; then
    gcc -O2 -static -no-pie -Wno-format-truncation -o "$OUT" src/qcmon.c
else
    aarch64-linux-gnu-gcc -O2 -Os -static -no-pie -s -Wno-format-truncation -o "$OUT" src/qcmon.c
fi
echo "-> $OUT"
