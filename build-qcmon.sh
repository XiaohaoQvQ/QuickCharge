#!/bin/sh
# 编译 qcmon：
#   sh build-qcmon.sh            → bin/qcmon（arm64 静态，随包发布）
#   sh build-qcmon.sh x86        → bin/qcmon-x86（本机调试用，可以直接跑测试）
#   sh build-qcmon.sh arm64 /tmp/out
set -e
cd "$(dirname "$0")"
OUT=${2:-bin/qcmon}

# 版本号从 module.prop 取，去掉 -c 后缀：C 版和 shell 版共用同一个号，
# 免得 qcmon 自报的版本跟包版本对不上（之前写死 2.9.49，日志一直误导排查）。
VER=$(sed -n 's/^version=//p' module.prop 2>/dev/null | head -1 | sed 's/-c$//')
[ -n "$VER" ] || VER=dev
DEF="-DQC_VER=\"$VER\""

if [ "$1" = x86 ]; then
    gcc -O2 -static -no-pie -Wall -Wextra -Wno-format-truncation $DEF -o "$OUT" src/qcmon.c
else
    # 体积优先：-Os；静态链接不依赖 bionic 版本，Android 8~16 通用
    aarch64-linux-gnu-gcc -Os -static -no-pie -s -Wall -Wextra \
        -Wno-format-truncation $DEF -o "$OUT" src/qcmon.c
fi
echo "-> $OUT ($VER)"
ls -l "$OUT"
