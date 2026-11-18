#!/bin/sh
# sd_chg_line / sd_chg_snapshot 单元测试：假 sysroot + 直接调用函数，不依赖真机
# 用法：sh tests/chg-unit.sh
set -u
BASE=/tmp/qcg
ROOT=$BASE/root
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $3，实际 $2）"; fi; }

MOD=$(cd "$(dirname "$0")/.." && pwd)

setup() {
    rm -rf "$BASE"
    mkdir -p "$ROOT/ps/battery" "$ROOT/ps/usb" "$ROOT/oplus/battery" "$BASE/data"
    printf 'Charging\n'  >"$ROOT/ps/battery/status"
    printf '34000\n'     >"$ROOT/ps/battery/temp"
    printf '40\n'        >"$ROOT/ps/battery/capacity"
    printf '4219000\n'   >"$ROOT/ps/battery/voltage_now"
    printf -- '-3000\n'  >"$ROOT/ps/battery/current_now"
    printf '8850000\n'   >"$ROOT/ps/usb/voltage_now"
    printf '2000000\n'   >"$ROOT/ps/usb/current_max"
    printf 'USB_DCP\n'   >"$ROOT/ps/usb/type"
    printf '7\n'         >"$ROOT/oplus/battery/cool_down"
    printf '0\n'         >"$ROOT/oplus/battery/voocchg_ing"
    printf '14\n'        >"$ROOT/oplus/battery/charge_technology"
    cat >"$BASE/data/state.conf" <<'EOF'
temp_mode=static
shell_temp=30
log_level=3
EOF
}

# 每次新起子 shell；同一用例内多次调用共用状态，与守护里的情况一致
run_sh() {
    SD_DATA=$BASE/data SD_PS=$ROOT/ps SD_OPLUS_CHG=$ROOT/oplus/battery \
    SD_BL=$ROOT/bl SD_FB=$ROOT/none MODDIR=$MOD \
    sh -c '. "$MODDIR/lib/qc.sh"; sd_state_load; _sd_st_loaded=1; _sd_screen_on=1; '"$1" 2>/dev/null
}

cnt() { grep -c '\[chg\]' "$BASE/data/log.txt" 2>/dev/null || echo 0; }

echo "[1] 一行快照的字段与单位"
setup
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'vusb=8.85V'   && ok "vusb µV→V"    || bad "vusb: $line"
echo "$line" | grep -q 'imax=2.00A'   && ok "imax µA→A"    || bad "imax: $line"
echo "$line" | grep -q 'vbat=4.219V'  && ok "vbat 三位小数" || bad "vbat: $line"
echo "$line" | grep -q 'ibat=-3mA'    && ok "ibat 保留负号" || bad "ibat: $line"
echo "$line" | grep -q '40%'          && ok "capacity"      || bad "cap: $line"
echo "$line" | grep -q '34℃'          && ok "temp"          || bad "temp: $line"
echo "$line" | grep -q 'cool=7'       && ok "cool_down"     || bad "cool: $line"
echo "$line" | grep -q 'tech=14'      && ok "charge_technology" || bad "tech: $line"
echo "$line" | grep -q 'type=USB_DCP' && ok "usb/type"      || bad "type: $line"

echo "[2] 只在变化时写日志"
setup
run_sh 'sd_chg_snapshot 1; sd_chg_snapshot 1; sd_chg_snapshot 1'
chk "三次同值只写一条" "$(cnt)" "1"

setup
run_sh 'sd_chg_snapshot 1; printf "5000000\n" >"$SD_PS/usb/voltage_now"; sd_chg_snapshot 1'
chk "电压变化追加一条" "$(cnt)" "2"
grep -q 'vusb=5.00V' "$BASE/data/log.txt" && ok "新值落进日志" || bad "日志没更新"

echo "[3] 日志级别"
setup
sed -i 's/log_level=3/log_level=1/' "$BASE/data/state.conf"
run_sh 'sd_chg_snapshot 1'
chk "log_level=1 不写快照" "$(cnt)" "0"

setup
sed -i 's/log_level=3/log_level=2/' "$BASE/data/state.conf"
run_sh 'sd_chg_snapshot 1'
chk "log_level=2 保留快照" "$(cnt)" "1"

echo "[4] 插拔判定"
setup
run_sh 'sd_chg_snapshot 1; printf "Discharging\n" >"$SD_PS/battery/status"; sd_chg_snapshot 0'
grep -q '停充' "$BASE/data/log.txt" && ok "停充有标注" || bad "没有停充标注"

setup
line=$(run_sh 'rm -f "$SD_PS/usb/voltage_now"; sd_chg_line')
echo "$line" | grep -q 'vusb=?V' && ok "缺节点显示 ?" || bad "缺节点输出: $line"

echo "[5] 未充电时的判重（只看状态签名）"
setup
# 每次调用前把节流计时清零，模拟"已经过去 30 秒"
run_sh 'printf "Discharging\n" >"$SD_PS/battery/status"
        _sd_chg_scan=0; sd_chg_snapshot 0
        printf "4253000\n" >"$SD_PS/battery/voltage_now"
        _sd_chg_scan=0; sd_chg_snapshot 0
        printf "4201000\n" >"$SD_PS/battery/voltage_now"
        _sd_chg_scan=0; sd_chg_snapshot 0'
chk "电压在几十 mV 内抖动不追加" "$(cnt)" "1"

setup
run_sh 'printf "Discharging\n" >"$SD_PS/battery/status"
        _sd_chg_scan=0; sd_chg_snapshot 0
        printf "46\n" >"$SD_PS/battery/capacity"
        _sd_chg_scan=0; sd_chg_snapshot 0'
chk "电量跨 5% 档追加一条" "$(cnt)" "2"

setup
run_sh 'printf "Discharging\n" >"$SD_PS/battery/status"
        _sd_chg_scan=0; sd_chg_snapshot 0
        printf "42\n" >"$SD_PS/battery/capacity"
        _sd_chg_scan=0; sd_chg_snapshot 0'
chk "电量同档内变化不追加" "$(cnt)" "1"

echo "[6] 电池电流优先取 bcc"
setup
printf '1,2,3,4,5,6,4200,8,-350,10,11,0,12,13,14,15,16,17,18\n' \
    >"$ROOT/oplus/battery/bcc_parms"
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'ibat=-350mA' && ok "current_now=-3mA 时用 bcc 的 -350mA" || bad "ibat: $line"

setup
printf '1,2,3,4,5,6,4200,8,-350,10,11,0,12,13,14,15,16,17,18\n' \
    >"$ROOT/oplus/battery/bcc_parms"
printf '0\n' >"$ROOT/ps/battery/current_now"
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'ibat=-350mA' && ok "灭屏 current_now=0 时用 bcc" || bad "ibat: $line"

setup
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'ibat=-3mA' && ok "无 bcc 时回退 current_now" || bad "ibat: $line"

setup
# bcc 第 9 段是个位数噪声（PJD110 实机就是这样），不能盖掉真实电流
printf '1,2,3,4,5,6,4210,8,-3,10,11,0,12,13,14,15,16,17,18\n' \
    >"$ROOT/oplus/battery/bcc_parms"
printf -- '-2500000\n' >"$ROOT/ps/battery/current_now"
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'ibat=-2500mA' && ok "bcc 噪声 -3mA 时改用 current_now" || bad "ibat: $line"

echo
echo "结果：通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
