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

echo "[1] 只读：任何电流/温度/电量/屏幕都不改 cool_down"
# 3.0~3.1.12 这里会写 0（"降流解除"）。三次实测全是净损失，最惨的 PJD110
# 写 3→0 之后 33.6W 掉到 2.2W、45 分钟没回来（vusb 8V→5.15V、vooc 1→0）。
# 3.1.13 起只读，下面每个场景都必须原样不动。
setup; run_cool 1
chk "34℃/40% → 不动" "$(cool)" "7"

setup; setb temp 46000; run_cool 1
chk "46℃ → 不动" "$(cool)" "7"

setup; setb temp 49000; run_cool 1
chk "49℃ → 不动" "$(cool)" "7"

setup; setb capacity 90; run_cool 1
chk "90% → 不动" "$(cool)" "7"

setup; setb capacity 90; setb temp 46000; run_cool 1
chk "90% 且 46℃ → 不动" "$(cool)" "7"

echo "[1b] 电流高低都不写"
setup; setb current_now 4300000; run_cool 1
chk "4.3A 满速 → 不动" "$(cool)" "7"

setup; setb current_now 1500000; run_cool 1
chk "1.5A（看着像被降流）→ 不动" "$(cool)" "7"

setup; setb current_now 368000; run_cool 1
chk "368mA（一加 15 那种极端低流）→ 不动" "$(cool)" "7"

setup; setb current_now 2499000; run_cool 1
chk "2499mA（旧 2.5A 闸的边界）→ 不动" "$(cool)" "7"

setup; rm -f "$ROOT/ps/battery/current_now"; run_cool 1
chk "没有 current_now → 不动" "$(cool)" "7"

echo "[1c] 档位原样保留，一个字节都不写"
setup; setcool 3; run_cool 1
chk "档位 3 → 还是 3" "$(cool)" "3"

setup; setcool 13; run_cool 1
chk "档位 13（亮屏上限）→ 还是 13" "$(cool)" "13"

setup; setcool 0; run_cool 1
chk "已经是 0 → 保持 0" "$(cool)" "0"

echo "[1d] 只读也要留痕：档位变了记一条，不变不重复"
# 只有同一个进程里连跑两轮才看得出「不重复」；单次命令每次都是新进程，
# 上一档位自然丢，计数没有意义。
run_seq() {   # $1 = 两轮之间要不要改档位
    SD_DATA=$BASE/data SD_PS=$ROOT/ps SD_OPLUS_CHG=$ROOT/oplus/battery \
    SD_BL=$ROOT/bl SD_FB=$ROOT/none MODDIR=$MOD \
    sh -c '. "$MODDIR/lib/qc.sh"; sd_state_load; _sd_st_loaded=1
           sd_cool_tick
           [ -n "$1" ] && printf "%s\n" "$1" >"$SD_OPLUS_CHG/cool_down"
           sd_cool_tick' _ "$1" 2>/dev/null
}
logc() { grep -ac 'cool_down=' "$BASE/data/log.txt" 2>/dev/null || echo 0; }

setup; setcool 7; run_seq ""
chk "两轮同档位只记 1 条" "$(logc)" "1"

setup; setcool 7; run_seq 3
chk "档位 7→3 记 2 条" "$(logc)" "2"

setup; setcool 3; run_seq 0
chk "档位 3→0 也记" "$(logc)" "2"

chk "日志里有档位原文" \
    "$(grep -a 'cool_down=3（亮屏降流标记，只记录不写入）' "$BASE/data/log.txt" | wc -l | tr -d ' ')" "1"

echo "[2] 不该动的场景"
setup; run_cool 0
chk "灭屏同样不动" "$(cool)" "7"

setup; setb status Discharging; run_cool 1
chk "未充电 → 不动" "$(cool)" "7"

setup
printf 'cool_guard=0\n' >>"$BASE/data/state.conf"
run_cool 1
chk "残留的 cool_guard 键不影响（写回路径已删）" "$(cool)" "7"

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
