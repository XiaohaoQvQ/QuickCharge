#!/bin/sh
# 发版前机械检查。3.1.4-c 那次空发布就是因为「同步两仓」靠人记 —— 这里把它变成命令。
#
# 用法：
#   sh tests/preflight.sh                          主仓 = 本脚本上一级，C 仓 = 同级 qc-c-repo
#   sh tests/preflight.sh <主仓> <C 仓>             换机器 / CI 必须传两个参数
#   sh tests/preflight.sh --full <主仓> <C 仓>      额外编 x86 跑 c-test，核对用例数（约 1 分钟）
#
# 主仓目录名可以随便叫，「../qc-c-repo」只是本机默认值；找不到会直接报路径问题，
# 不会退化成一片 FAIL 让人以为代码坏了。
set -u
FULL=0
if [ "${1:-}" = "--full" ]; then FULL=1; shift; fi
A=${1:-$(cd "$(dirname "$0")/.." && pwd)}
B=${2:-$A/../qc-c-repo}
fail=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
same() { if cmp -s "$1" "$2"; then ok "$3"; else bad "$3"; fi; }
has()  { if grep -aqF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3"; fi; }
nhas() { if grep -aqF -- "$2" "$1" 2>/dev/null; then bad "$3"; else ok "$3"; fi; }
num()  { wc -l <"$1" 2>/dev/null | tr -d ' '; }
# 文档里的行/项用「文件里含某段文字的那一行」定位，再取行内数字。
# 注意不能用 sed 的 s/.*lib/qc.sh.*/ 这种：pattern 里的斜杠就是分隔符。
# 注意不能 -m1：同一个文件名在 README 里会出现多次（简介、目录树、发行表），
# 取第一条往往不是带数字的那条。返回全部匹配行，调用方再按上下文筛。
line()  { grep -F -- "$1" "$2" 2>/dev/null; }
n1()    { printf '%s' "$1" | grep -o '[0-9][0-9]*' | head -1; }
nl()    { printf '%s' "$1" | grep -o '[0-9][0-9]*' | tail -1; }
# 描述, 文档写的值, 实际值
chknd() { if [ -n "$2" ] && [ "$2" = "$3" ]; then ok "$1 = $3"; else bad "$1：文档写 ${2:-（没写）}，实际 $3"; fi; }

if [ ! -d "$B" ]; then
    echo "找不到 C 仓：$B"
    echo "换机器时请显式传路径：sh tests/preflight.sh <主仓> <C 仓>"
    exit 1
fi

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

# 文档里的行数已经在三轮里漂移过两次，靠人眼看不住，直接和 wc -l 比。
echo "[4] 文档数字与代码一致"
chknd "README lib/qc.sh 行数" \
    "$(nl "$(line 'lib/qc.sh' "$A/README.md" | grep '核心库' | head -1)")" "$(num "$A/lib/qc.sh")"
chknd "README src/qcmon.c 行数" \
    "$(nl "$(line 'src/qcmon.c' "$A/README.md" | grep 'C 版源码' | head -1)")" "$(num "$A/src/qcmon.c")"
chknd "README action.sh 行数" \
    "$(nl "$(line 'action.sh' "$A/README.md" | grep '控制入口' | head -1)")" "$(num "$A/action.sh")"
chknd "C README src/qcmon.c 行数" \
    "$(nl "$(line 'src/qcmon.c' "$B/README.md" | grep 'C 守护源码' | head -1)")" "$(num "$B/src/qcmon.c")"
c_cases=$(n1 "$(line 'tests/c-test.sh' "$B/README.md" | grep '项冒烟测试' | head -1)")
# 只查「不少于」，加用例不用回来改这里；漏写/写小才是要拦的
if [ -n "$c_cases" ] && [ "$c_cases" -ge 87 ] 2>/dev/null; then
    ok "C README c-test 项数 = $c_cases（≥87）"
else
    bad "C README c-test 项数：文档写 ${c_cases:-（没写）}，应 ≥87"
fi
chknd "C README c-test 行数" \
    "$(nl "$(line 'tests/c-test.sh' "$B/README.md" | grep '项冒烟测试' | head -1)")" "$(num "$B/tests/c-test.sh")"
chknd "C README lib/qc.sh 行数" \
    "$(nl "$(line 'shell 版核心库' "$B/README.md" | head -1)")" "$(num "$B/lib/qc.sh")"

# 用例数静态数不出来（循环里的断言只算一行代码），要跑一遍才准。
if [ "$FULL" = 1 ]; then
    echo "[5] 实跑 c-test 核对用例数（--full）"
    X86=/tmp/qcmon_preflight.$$
    if sh "$A/build-qcmon.sh" x86 "$X86" >/dev/null 2>&1; then
        got=$(sh "$A/tests/c-test.sh" "$X86" 2>/dev/null | sed -n 's/^结果：通过 \([0-9][0-9]*\).*/\1/p')
        rm -f "$X86"
        want=$(n1 "$(line '共 **' "$B/README.md" | head -1)")
        chknd "c-test 用例数（C README）" "$want" "$got"
        # 单测总数必须写 97（44+31+12+4+6）。3.1.6 漏了 zone-rank 写成 91，
        # 这里只认「同一行里既有 单元 又有 97」，写漏写错都红。
        for r in "$A/RELEASE.md" "$B/RELEASE.md"; do
            if grep -q '单元.*97' "$r" 2>/dev/null; then
                ok "${r##*/} 单测总数写的是 97"
            else
                bad "${r##*/} 里找不到「单元 … 97」"
            fi
        done
    else
        bad "x86 编译失败，跳过用例数核对"
    fi
fi

echo
[ "$fail" -eq 0 ] && echo "preflight: 全绿" || echo "preflight: $fail 项不合格，别发版"
[ "$fail" -eq 0 ]
