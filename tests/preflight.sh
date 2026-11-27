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
# 这份拷贝 3.1.11 分叉了 16 行（versionCode 反算、去重只在主仓），发版时全绿也没发现，
# 就是因为清单里没有它。加进来才算真同步 —— 守卫本身不同步，等于 C 仓没有守卫。
same "$A/tests/preflight.sh" "$B/tests/preflight.sh" "tests/preflight.sh 逐字节一致"
# WebUI 两仓同源。3.1.13 加 batt_spoof 提示时就漏同步了一次，打包前才发现 C 包里的
# index.html 比主仓少一行 —— 面板文案分叉，用户看到的是哪版取决于装哪个包。
same "$A/webroot/index.html" "$B/webroot/index.html" "webroot/index.html 逐字节一致"
for f in lib/qc.sh customize.sh post-fs-data.sh action.sh service.sh; do
    same "$A/$f" "$B/$f" "$f 一致"
done

echo "[2] C 版二进制带得动本轮修复"
BIN=$B/bin/qcmon
if [ -f "$BIN" ]; then
    # 特征串是唯一骗不过的东西：版本号可以由构建脚本注入，功能串不行。
    # 用 grep -a 而不是 strings：中文是多字节，strings 会当不可打印丢掉。
    for t in /pc_port/ /wireless/ input_current_limit 只记录不写入; do
        has "$BIN" "$t" "bin 含 $t"
    done
    # 3.1.5 之前的老实现，出现即说明编的是旧源码
    nhas "$BIN" "息屏保持（回写 FCC" "bin 不含已删除的旧文案"
    # 3.1.13 删掉了对 cool_down 的写入。这行文案留着就说明编的是旧源码 ——
    # 它带来的不是"少一个功能"，是写一次就把协议打断一次。
    nhas "$BIN" "降流解除" "bin 不再写 cool_down（无「降流解除」）"
else
    bad "$BIN 不存在"
fi
# 两处在说「有温度兜底」的假话。WebUI 那行是 HTML 初值：JS 正常加载会覆盖，
# 首帧仍会闪，JS 抛错就一直显示；日志里那句「电池偏热」对应的分支也只活在
# 3.1.3 之前的温度闸里。都在 bin 之外，preflight 原来拦不到。
nhas "$A/webroot/index.html" "≥46℃ 撤销" "WebUI 静态文案不承诺 46℃ 撤销"
# C 侧同源的残留：3.1.0 删熔断、3.1.3 删亮屏温度闸、3.1.8 删 curr 备份，
# 函数体删了注释和分支还留着，上轮只查了 lib/qc.sh，C 里的一直没进视野。
# 3.1.10 验收发现这里和上面那条重复查了 lib/qc.sh 的「电池偏热」，多打一条同样的 ok，
# 循环覆盖两个文件就够了，单条已删。
for f in src/qcmon.c lib/qc.sh; do
    nhas "$A/$f" "电池偏热" "$f 无「电池偏热」分支"
    nhas "$A/$f" "熔断" "$f 无熔断残留"
done
nhas "$A/src/qcmon.c" "g_curr_orig" "src/qcmon.c 无 curr.orig 死代码"
# cool_down 只读：写回路径（反噬复查、写 0、冷却计时）删干净了才发版
for f in src/qcmon.c lib/qc.sh; do
    nhas "$A/$f" "降流解除反噬" "$f 无反噬复查（只读后没有写回）"
done
nhas "$A/lib/qc.sh" "降流解除：cool_down" "lib/qc.sh 不写 cool_down"
has  "$A/lib/qc.sh" "只记录不写入" "lib/qc.sh 记录文案在"
nhas "$A/lib/qc.sh" "_sd_cool_prev" "lib/qc.sh 无写回用的档位备份"
nhas "$A/service.sh" '_ws=3' "service.sh 充电时不再压到 3s"

# 3.1.14：日志里得有功率。快照锁在 2 级时，用户默认（1 级）的日志 [chg] 为 0，
# PLG110 那份「10–20W」的反馈就是这么变成无解的 —— 缺的正好是功率本身。
has  "$A/lib/qc.sh" "_sd_chg_emit" "lib/qc.sh 快照在 1 级降级为 I"
nhas "$A/lib/qc.sh" '${_sd_lv:-0}" -ge 2 ] || return 0' "快照门禁不再卡在 2 级"
# 双守护：qcmon 自己校验通道，shell 侧收掉并存的 qcmon，两边都要在
has  "$A/src/qcmon.c" "拒绝启动" "qcmon 校验 channel"
has  "$BIN" "不是 c" "bin 带通道闸"
has  "$A/service.sh" "收掉并存的 qcmon" "service.sh 清理残留 qcmon"
# 一个变量两个主人：service.sh 当开关、sd_scr_tick 当状态，每轮互相踩出两条日志
has  "$A/service.sh" "_sd_scr_once" "service.sh 的开关独立成 _sd_scr_once"
nhas "$A/service.sh" '_sd_scr_log=1' "service.sh 不再改 sd_scr_tick 的状态"
# 混合安装（module.prop 新、脚本旧）只能靠节拍反推，指纹要写进启动日志
has  "$A/lib/qc.sh" "sd_file_sum" "有代码指纹函数"
has  "$A/service.sh" "代码指纹 service.sh=" "启动日志记 service.sh/lib 指纹"
# 只给数量时「fcc 节点=none」追不下去，命中清单与 cool_down 可读性都要记
has  "$A/lib/qc.sh" "charge nodes 命中" "env 记命中的电流节点"
has  "$A/lib/qc.sh" "cool_down 节点存在但读不到" "cool_down 读不到不静默"

echo "[3] 版本号自洽"
v_prop=$(sed -n 's/^version=//p' "$A/module.prop" | head -1)
vc_prop=$(sed -n 's/^versionCode=//p' "$A/module.prop" | head -1)
v_upd=$(grep -o '"version": *"[^"]*"' "$A/update.json" | sed 's/.*"\([^"]*\)"$/\1/')
vc_upd=$(grep -o '"versionCode": *[0-9]*' "$A/update.json" | grep -o '[0-9]*$')
[ "$v_prop" = "$v_upd" ] && ok "update.json version=$v_upd" || bad "update.json version=$v_upd ≠ module.prop $v_prop"
[ "$vc_prop" = "$vc_upd" ] && ok "update.json versionCode=$vc_upd" || bad "versionCode $vc_upd ≠ $vc_prop"

# versionCode 在 3.1.10 换了第三代编码。旧公式 `(主×100+次)×1000+修订×2+通道` 到这一步
# 会算出 301021 —— 比 3.1.9 的 301901 还小，管理器当降级，卡片连「更新」都不显示；
# 这种错不报错、不崩，只是静默推不动，所以从 version 反算，人算错立刻红。
vcmaj=${v_prop%%.*}; _rest=${v_prop#*.}
vcmin=${_rest%%.*}; vcrev=${_rest#*.}; vcrev=${vcrev%%-*}
vcch=$(sed -n 's/^channel=//p' "$A/module.prop" | head -1)
if [ "$vcch" = c ]; then vcbit=0; else vcbit=1; fi
vc_calc=$(( ${vcmaj:-0} * 1000000 + ${vcmin:-0} * 10000 + ${vcrev:-0} * 100 + vcbit ))
# 3.1.10 之前的号是历史编码（3.0.12=300025、3.1.9=301901），不回溯重算，老 tag 上跑不误报
if [ "$vc_calc" -ge 3011001 ]; then
    chknd "versionCode 反算（$v_prop → $vc_calc）" "$vc_prop" "$vc_calc"
else
    ok "versionCode 反算跳过：$v_prop 早于 3.1.10 的 7 位编码"
fi
case "$(grep -o '"zipUrl": *"[^"]*"' "$A/update.json")" in
    *"$v_prop"*) ok "zipUrl 指向 $v_prop" ;;
    *) bad "zipUrl 没跟着改：$(grep -o '"zipUrl": *"[^"]*"' "$A/update.json")" ;;
esac

# README 不在打包范围，升级时最容易被忘掉。它写错版本，用户照着复制 zipUrl
# 就会拿到上一版 —— 3.1.7 就这么漏过一次，所以并进版本检查一起看。
# 下面几条按主仓 README 的版式取值。C 仓那份副本单独跑时（A 就是 C 仓）版式不同，
# 取不到值会连报 4 条假红，所以先看通道：channel=c 说明坐在 C 仓里。
if [ "$vcch" = c ]; then
    ok "当前是 C 仓副本：跳过 4 条主仓 README 数字检查（全量请看主仓的 preflight）"
else
v_readme=$(sed -n 's/^- 当前版本：`\([^`]*\)`.*/\1/p' "$A/README.md" | head -1)
[ "$v_readme" = "$v_prop" ] && ok "README 当前版本 = $v_readme" \
    || bad "README 当前版本写 ${v_readme:-（没写）}，module.prop 是 $v_prop"
v_doc=$(grep -o '"version": *"[^"]*"' "$A/README.md" | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
[ "$v_doc" = "$v_prop" ] && ok "README 里 update.json 示例 = $v_doc" \
    || bad "README 的 update.json 示例写 ${v_doc:-（没写）}，实际 $v_prop"

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
if [ -n "$c_cases" ] && [ "$c_cases" -ge 100 ] 2>/dev/null; then
    ok "C README c-test 项数 = $c_cases（≥100）"
else
    bad "C README c-test 项数：文档写 ${c_cases:-（没写）}，应 ≥100"
fi
chknd "C README c-test 行数" \
    "$(nl "$(line 'tests/c-test.sh' "$B/README.md" | grep '项冒烟测试' | head -1)")" "$(num "$B/tests/c-test.sh")"
chknd "C README lib/qc.sh 行数" \
    "$(nl "$(line 'shell 版核心库' "$B/README.md" | head -1)")" "$(num "$B/lib/qc.sh")"
# 参数表里的默认值和代码里的 SD_DEFAULTS 对不上，比版本号写错更容易坑人：
# 用户会以为自己的 30 是被人改过的，调参也从错的那头开始试。
d_doc=$(grep -F '| `shell_temp` |' "$A/README.md" | grep -o '`[0-9][0-9]*`' | head -1 | tr -d '`')
d_code=$(sed -n 's/^shell_temp=//p' "$A/customize.sh" | head -1)
chknd "README shell_temp 默认值" "$d_doc" "$d_code"
fi

# 用例数静态数不出来（循环里的断言只算一行代码），要跑一遍才准。
if [ "$FULL" = 1 ]; then
    echo "[5] 实跑 c-test 核对用例数（--full）"
    X86=/tmp/qcmon_preflight.$$
    if sh "$A/build-qcmon.sh" x86 "$X86" >/dev/null 2>&1; then
        got=$(sh "$A/tests/c-test.sh" "$X86" 2>/dev/null | sed -n 's/^结果：通过 \([0-9][0-9]*\).*/\1/p')
        rm -f "$X86"
        want=$(n1 "$(line '共 **' "$B/README.md" | head -1)")
        chknd "c-test 用例数（C README）" "$want" "$got"
        # 单测总数不写死：实跑五个脚本求和，再和 RELEASE 里那行比。
        # 3.1.6 漏了 zone-rank 写成 91、3.1.8 删熔断后从 97 变 92，
        # 都是人肉维护数字出的错 —— 这里改成算出来的。
        ut=0
        for t in chg-unit cool-unit state-unit mount-unit zone-rank; do
            n=$(sh "$A/tests/$t.sh" 2>/dev/null | sed -n 's/.*通过 \([0-9][0-9]*\)，失败.*/\1/p')
            ut=$((ut + ${n:-0}))
        done
        for r in "$A/RELEASE.md" "$B/RELEASE.md"; do
            got_n=$(n1 "$(line '单元' "$r" | head -1)")
            chknd "${r##*/} 单测总数" "$got_n" "$ut"
        done
    else
        bad "x86 编译失败，跳过用例数核对"
    fi
fi

echo
[ "$fail" -eq 0 ] && echo "preflight: 全绿" || echo "preflight: $fail 项不合格，别发版"
[ "$fail" -eq 0 ]
