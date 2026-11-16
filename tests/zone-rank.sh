#!/bin/sh
# 电池温区优选单元测试：batt-therm 是连接器侧，不能当电芯用
# 用法：sh tests/zone-rank.sh
set -u
BASE=/tmp/qcz
ROOT=$BASE/zt
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $3，实际 $2）"; fi; }

MOD=$(cd "$(dirname "$0")/.." && pwd)

mkz() { mkdir -p "$ROOT/$1"; printf '%s\n' "$2" >"$ROOT/$1/type"; printf '%s\n' "$3" >"$ROOT/$1/temp"; }

setup() {
    rm -rf "$BASE"
    mkdir -p "$BASE/data" "$BASE/ps/battery" "$ROOT"
    printf 'Charging\n' >"$BASE/ps/battery/status"
    printf '34000\n'    >"$BASE/ps/battery/temp"
    printf '40\n'       >"$BASE/ps/battery/capacity"
}

# 输出：<zone 名> <type>
pick_zone() {
    SD_DATA=$BASE/data SD_PS=$BASE/ps SD_ZONE_GLOB="$ROOT/thermal_zone*" MODDIR=$MOD \
    sh -c '. "$MODDIR/lib/qc.sh"; _sd_scanned=0
           sd_pick_batt_zone_v && printf "%s %s" "${_sd_rv##*/}" "$_sd_sent_type"' 2>/dev/null
}

# 输出：<温度> <来源>
pick_temp() {
    SD_DATA=$BASE/data SD_PS=$BASE/ps SD_ZONE_GLOB="$ROOT/thermal_zone*" MODDIR=$MOD \
    sh -c '. "$MODDIR/lib/qc.sh"; _sd_scanned=0
           sd_pick_batt_zone_v || exit 1
           z=$_sd_rv
           sd_batt_best_v "$z" && printf "%s %s" "$_sd_rv" "$_sd_temp_src"' 2>/dev/null
}

echo "[1] 电芯与连接器同时存在"
setup
mkz thermal_zone0 battery    34000
mkz thermal_zone1 batt-therm 48000
chk "选中 battery 而非 batt-therm" "$(pick_zone)" "thermal_zone0 battery"
chk "温度取电芯 34℃"              "$(pick_temp)" "34 both"

echo "[2] 只有连接器侧（比电量计高 14℃）"
setup
mkz thermal_zone1 batt-therm 48000
chk "温区仍是 batt-therm" "$(pick_zone)" "thermal_zone1 batt-therm"
chk "温度回退电量计 34℃"  "$(pick_temp)" "34 ps"

echo "[3] 连接器只高 6℃（在容差内）"
setup
mkz thermal_zone1 batt-therm 40000
chk "保留温区读数" "$(pick_temp)" "40 both"

echo "[4] 两者同值"
setup
mkz thermal_zone0 battery 34000
chk "来源 both" "$(pick_temp)" "34 both"

echo
echo "结果：通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
