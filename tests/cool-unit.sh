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
    cat >"$BASE/data/state.conf" <<'EOF'
temp_mode=static
shell_temp=30
cool_guard=1
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

echo "[1] 亮屏充电：按温度/电量给出目标值"
setup; run_cool 1
chk "34℃/40% → 0" "$(cool)" "0"

setup; setb temp 46000; run_cool 1
chk "46℃ → 2" "$(cool)" "2"

setup; setb temp 49000; run_cool 1
chk "49℃ → 不干预" "$(cool)" "7"

setup; setb capacity 90; run_cool 1
chk "90% → 1" "$(cool)" "1"

echo "[2] 不该动的场景"
setup; run_cool 0
chk "灭屏也解除（驱动本来给 0，写 0 无副作用）" "$(cool)" "0"

setup; setb status Discharging; run_cool 1
chk "未充电 → 不干预" "$(cool)" "7"

setup; run_cool 1
printf 'cool_guard=0\n' >>"$BASE/data/state.conf"
setcool 7; run_cool 1
chk "cool_guard=0 → 不干预" "$(cool)" "7"

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

echo
echo "结果：通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
