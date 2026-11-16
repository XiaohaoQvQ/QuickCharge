#!/bin/sh
# 挂载存活判定单元测试：/proc/mounts 看不到时用内容比对兜底
# 用法：sh tests/mount-unit.sh
set -u
BASE=/tmp/qcm
ROOT=$BASE/root
MOD=$BASE/mod
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $3，实际 $2）"; fi; }

SRC=$(cd "$(dirname "$0")/.." && pwd)

setup() {
    rm -rf "$BASE"
    mkdir -p "$BASE/data" "$MOD" "$ROOT/vendor/etc"
    ln -s "$SRC/lib" "$MOD/lib"
    mkdir -p "$MOD/files/vendor/etc"
    printf 'rewritten\n' >"$MOD/files/vendor/etc/a.xml"
    printf '/vendor/etc/a.xml\n' >"$BASE/data/mounts.list"
}

alive() {
    SD_DATA=$BASE/data MODDIR=$MOD SD_ROOT=$ROOT SD_PS=$ROOT/ps \
    sh -c '. "$MODDIR/lib/qc.sh"; sd_mounts_alive' 2>/dev/null
    echo "rc=$?"
}

echo "[1] 目标文件内容与改写版一致（跨 namespace 看不到挂载）"
setup
printf 'rewritten\n' >"$ROOT/vendor/etc/a.xml"
chk "判定为已生效" "$(alive | tail -1)" "rc=0"

echo "[2] 目标文件仍是原始内容"
setup
printf 'original\n' >"$ROOT/vendor/etc/a.xml"
chk "判定为未生效" "$(alive | tail -1)" "rc=1"

echo "[3] 清单为空"
setup
: >"$BASE/data/mounts.list"
chk "无记录直接失败" "$(alive | tail -1)" "rc=1"

echo "[4] 清单有记录但改写版缺失"
setup
rm -f "$MOD/files/vendor/etc/a.xml"
printf 'rewritten\n' >"$ROOT/vendor/etc/a.xml"
chk "无对应文件不误判" "$(alive | tail -1)" "rc=1"

echo
echo "结果：通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
