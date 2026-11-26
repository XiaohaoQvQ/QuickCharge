#!/bin/sh
# 发版前机械检查。3.1.4-c 那次空发布就是因为「同步两仓」靠人记 —— 这里把它变成命令。
# 用法：sh tests/preflight.sh [主仓] [C 仓]      两个路径都可省略
set -u
A=${1:-$(cd "$(dirname "$0")/.." && pwd)}
B=${2:-$A/../qc-c-repo}
fail=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
same() { if cmp -s "$1" "$2"; then ok "$3"; else bad "$3"; fi; }
has()  { if grep -aqF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3"; fi; }
nhas() { if grep -aqF -- "$2" "$1" 2>/dev/null; then bad "$3"; else ok "$3"; fi; }

echo "[1] 两仓源码与测试一致"
same "$A/src/qcmon.c"      "$B/src/qcmon.c"      "src/qcmon.c 逐字节一致"
same "$A/tests/c-test.sh"  "$B/tests/c-test.sh"  "tests/c-test.sh 逐字节一致"
for f in lib/qc.sh customize.sh post-fs-data.sh action.sh service.sh; do
    same "$A/$f" "$B/$f" "$f 一致"
done

echo "[2] C 版二进制带得动本轮修复"
BIN=$B/bin/qcmon
if [ -f "$BIN" ]; then
    # 特征串是唯一骗不过的东西：版本号可以由构建脚本注入，功能串不行。
    # 用 grep -a 而不是 strings：中文是多字节，strings 会当不可打印丢掉。
    for t in /pc_port/ /wireless/ input_current_limit 降流解除反噬; do
        has "$BIN" "$t" "bin 含 $t"
    done
    # 3.1.5 之前的老实现，出现即说明编的是旧源码
    nhas "$BIN" "息屏保持（回写 FCC" "bin 不含已删除的旧文案"
else
    bad "$BIN 不存在"
fi

echo "[3] 版本号自洽"
v_prop=$(sed -n 's/^version=//p' "$A/module.prop" | head -1)
vc_prop=$(sed -n 's/^versionCode=//p' "$A/module.prop" | head -1)
v_upd=$(grep -o '"version": *"[^"]*"' "$A/update.json" | sed 's/.*"\([^"]*\)"$/\1/')
vc_upd=$(grep -o '"versionCode": *[0-9]*' "$A/update.json" | grep -o '[0-9]*$')
[ "$v_prop" = "$v_upd" ] && ok "update.json version=$v_upd" || bad "update.json version=$v_upd ≠ module.prop $v_prop"
[ "$vc_prop" = "$vc_upd" ] && ok "update.json versionCode=$vc_upd" || bad "versionCode $vc_upd ≠ $vc_prop"
case "$(grep -o '"zipUrl": *"[^"]*"' "$A/update.json")" in
    *"$v_prop"*) ok "zipUrl 指向 $v_prop" ;;
    *) bad "zipUrl 没跟着改：$(grep -o '"zipUrl": *"[^"]*"' "$A/update.json")" ;;
esac

echo
[ "$fail" -eq 0 ] && echo "preflight: 全绿" || echo "preflight: $fail 项不合格，别发版"
[ "$fail" -eq 0 ]
