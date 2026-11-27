#!/bin/sh
# sd_cool_tick 单元测试：假 sysroot + 直接调用函数，不依赖真机
# 用法：sh tests/cool-unit.sh
set -u
BASE=/tmp/qcu
ROOT=$BASE/root
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $3，实际 $2）"; fi; }

MOD=$(cd "$(dirname "$0")/.." && pwd)

setup() {
    rm -rf "$BASE"
    mkdir -p "$ROOT/ps/battery" "$ROOT/oplus/battery" "$ROOT/bl/panel0-backlight" "$BASE/data"
    printf 'Charging\n' >"$ROOT/ps/battery/status"
    printf '34000\n'    >"$ROOT/ps/battery/temp"
    printf '40\n'       >"$ROOT/ps/battery/capacity"
    printf '512\n'      >"$ROOT/bl/panel0-backlight/actual_brightness"
    printf '7\n'        >"$ROOT/oplus/battery/cool_down"
    # 默认给一个「确实被降流」的电流：电流读不到时 cool_tick 不再动节点，
    # 没这一行所有用例都会因为「不知道电流」而跳过。
    printf '1500000\n'  >"$ROOT/ps/battery/current_now"
    cat >"$BASE/data/state.conf" <<'EOF'
temp_mode=static
shell_temp=30
log_level=3
EOF
}

# 每次新起子 shell，避免函数间状态残留
run_cool() {
    SD_DATA=$BASE/data SD_PS=$ROOT/ps SD_OPLUS_CHG=$ROOT/oplus/battery \
    SD_BL=$ROOT/bl SD_FB=$ROOT/none MODDIR=$MOD \
    sh -c '. "$MODDIR/lib/qc.sh"; sd_state_load; _sd_st_loaded=1; _sd_screen_on=$1; sd_cool_tick' _ "$1" 2>/dev/null
}

cool() { cat "$ROOT/oplus/battery/cool_down" | tr -d ' \r\n'; }
setb() { printf '%s\n' "$2" >"$ROOT/ps/battery/$1"; }
setcool() { printf '%s\n' "$1" >"$ROOT/oplus/battery/cool_down"; }

# 同进程连跑两轮，中间把 current_now 改成 $1：验证「写 0 后复查」那条路。
run_cool2() {
    SD_DATA=$BASE/data SD_PS=$ROOT/ps SD_OPLUS_CHG=$ROOT/oplus/battery \
    SD_BL=$ROOT/bl SD_FB=$ROOT/none MODDIR=$MOD \
    sh -c '. "$MODDIR/lib/qc.sh"; sd_state_load; _sd_st_loaded=1; _sd_screen_on=1
           sd_cool_tick
           _sd_cool_prev_at=$((_sd_cool_prev_at - 60))
           printf "%s\n" "$1" >"$SD_PS/battery/current_now"
           sd_cool_tick' _ "$1" 2>/dev/null
}

echo "[1] 充电中被降流就压回 0（不看温度/电量）"
setup; run_cool 1
chk "34℃/40% → 0" "$(cool)" "0"

setup; setb temp 46000; run_cool 1
chk "46℃ → 0" "$(cool)" "0"

setup; setb temp 49000; run_cool 1
chk "49℃ 也压 0（不看温度）" "$(cool)" "0"

setup; setb capacity 90; run_cool 1
chk "90% 也写 0（写 1 会掉协议，见 qcmon.c cool_tick）" "$(cool)" "0"

setup; setb capacity 90; setb temp 46000; run_cool 1
chk "90% 且 46℃ → 0" "$(cool)" "0"

echo "[1b] 电流闸：已经满速时不要碰这个节点"
# 实测 PKB110：4.3A 时被写 2→0，三秒后掉到 9.7W 并一路抖到 6W。
# 写入本身会让 OPlus 重选档，所以只有 ibat < 2.5A 才允许写。
setup; setb current_now 4300000; run_cool 1
chk "4.3A 充电中 → 不动节点" "$(cool)" "7"

setup; setb current_now 4300000; setb temp 49000; run_cool 1
chk "4.3A + 49℃ → 仍不动" "$(cool)" "7"

setup; setb current_now 1500000; run_cool 1
chk "1.5A（已降流）→ 写 0" "$(cool)" "0"

setup; setb current_now -4300000; run_cool 1
chk "电流为负也按绝对值判（4.3A → 不动）" "$(cool)" "7"

setup; setb current_now 2500000; run_cool 1
chk "正好 2.5A → 不动（边界含在闸内）" "$(cool)" "7"

setup; setb current_now 2499000; run_cool 1
chk "2499mA → 写 0" "$(cool)" "0"

echo "[1c] 电流读不到：不知道就别动"
setup; rm -f "$ROOT/ps/battery/current_now"; run_cool 1
chk "没有 current_now → 保持 7" "$(cool)" "7"

setup; printf 'x\n' >"$ROOT/ps/battery/current_now"; run_cool 1
chk "current_now 非数字 → 保持 7" "$(cool)" "7"

echo "[1d] 写 0 后复查：电流没升就写回原档位"
setup; setb current_now 1500000
run_cool2 1500000
chk "写 0 后仍是 1.5A → 写回 7" "$(cool)" "7"

setup; setb current_now 1500000
run_cool2 3000000
chk "写 0 后升到 3.0A → 保持 0" "$(cool)" "0"

echo "[2] 不该动的场景"
setup; run_cool 0
chk "灭屏也解除（驱动本来给 0，写 0 无副作用）" "$(cool)" "0"

setup; setb status Discharging; run_cool 1
chk "未充电 → 不干预" "$(cool)" "7"

setup; run_cool 1
printf 'cool_guard=0\n' >>"$BASE/data/state.conf"
setcool 7; run_cool 1
chk "残留的 cool_guard 键已失效 → 照样压 0" "$(cool)" "0"

echo "[3] 屏幕判定：任一亮度节点有值就算亮屏"
run_screen() {
    SD_DATA=$BASE/data SD_PS=$ROOT/ps SD_OPLUS_CHG=$ROOT/oplus/battery \
    SD_BL=$ROOT/bl SD_FB=$ROOT/none MODDIR=$MOD \
    sh -c '. "$MODDIR/lib/qc.sh"; sd_screen_tick; sd_screen_tick; echo "$_sd_screen_on"' 2>/dev/null
}

setup; mkdir -p "$ROOT/bl/dsi-backlight"
printf '0\n'   >"$ROOT/bl/dsi-backlight/actual_brightness"
chk "panel0=0 但 dsi=512 → 亮" "$(run_screen)" "1"

setup; mkdir -p "$ROOT/bl/dsi-backlight"
printf '0\n'   >"$ROOT/bl/dsi-backlight/actual_brightness"
printf '0\n'   >"$ROOT/bl/panel0-backlight/actual_brightness"
chk "全部为 0 → 灭" "$(run_screen)" "0"

setup; rm -rf "$ROOT/bl"
chk "无亮度节点 → 按亮屏" "$(run_screen)" "1"

echo "[4] 节点缺失与幂等"
setup; rm -f "$ROOT/oplus/battery/cool_down"; run_cool 1
chk "无 cool_down 节点不报错" "$?" "0"

setup; setcool 0; run_cool 1
chk "已是 0 时保持" "$(cool)" "0"

echo "[5] 亮屏快充 FCC 死区"
# 驱动自己也在动态算 FCC；贴目标值反复覆盖会让电流在两档间跳成锯齿。
# 目标是 2000mA 时：1400 才写，1500（差 25% 以内）不动。
FCC=$ROOT/oplus_chg/battery/chg_current_max
run_scr() {
    SD_DATA=$BASE/data SD_PS=$ROOT/ps SD_OPLUS_CHG=$ROOT/oplus/battery \
    SD_CURR_NODES=$FCC SD_BL=$ROOT/bl SD_FB=$ROOT/none MODDIR=$MOD \
    sh -c '. "$MODDIR/lib/qc.sh"; sd_state_load; _sd_st_loaded=1; _sd_screen_on=1; sd_scr_apply >/dev/null; cat "$SD_CURR_NODES"' 2>/dev/null
}

setup; mkdir -p "$BASE/data/run" "$ROOT/oplus_chg/battery"
printf '2000\n' >"$BASE/data/run/fcc.norm"
printf '1500\n' >"$FCC"
chk "1500 在死区内 → 不写" "$(run_scr | tr -d ' \r\n')" "1500"

setup; mkdir -p "$BASE/data/run" "$ROOT/oplus_chg/battery"
printf '2000\n' >"$BASE/data/run/fcc.norm"
printf '1400\n' >"$FCC"
chk "1400 低于 3/4 → 写回 2000" "$(run_scr | tr -d ' \r\n')" "2000"

setup; mkdir -p "$BASE/data/run" "$ROOT/oplus_chg/battery"
printf '2000\n' >"$BASE/data/run/fcc.norm"
printf '2300\n' >"$FCC"
chk "2300 已超目标 → 不动" "$(run_scr | tr -d ' \r\n')" "2300"

# ---------------------------------------------------------------- 熔断残留
# 熔断（sd_sentinel_guard / sd_guard_read_v / sd_batt_guard_v / sd_batt_best_v /
# sd_sentinel_best_v）在 3.1.0 移除，但函数体一直留着，连注释都在讲"为什么熔断
# 要取高值"。3.1.8 删干净，这里守住，别让谁再顺手加回来。
_stale=""
for _f in sd_sentinel_guard sd_guard_read_v sd_batt_guard_v sd_batt_best_v \
          sd_sentinel_best_v SD_BATT_HARD SD_UNLOCK_HARD; do
    grep -q "$_f" "$MOD/lib/qc.sh" 2>/dev/null && _stale="$_stale $_f"
done
chk "熔断读数链与硬上限常量已删净" "$_stale" ""
if grep -q 'battery_limit' "$MOD/lib/qc.sh" 2>/dev/null; then
    bad "battery_limit 仍在（应已删除）"
else
    ok "battery_limit 配置项已删除"
fi

echo
echo "结果：通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
