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

cnt() {
    local n
    n=$(grep -c '\[chg\]' "$BASE/data/log.txt" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
}

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

echo "[5b] 充电判重：按中值功率分档，脉动不跨档、真降档能跟上"
setup
run_sh 'printf -- "-4500000\n" >"$SD_PS/battery/current_now"
        _sd_chg_scan=0; sd_chg_snapshot 1
        printf -- "-4400000\n" >"$SD_PS/battery/current_now"
        _sd_chg_scan=0; sd_chg_snapshot 1
        printf -- "-3800000\n" >"$SD_PS/battery/current_now"
        _sd_chg_scan=0; sd_chg_snapshot 1'
chk "4.5→4.4→3.8A 的脉动不追加" "$(cnt)" "1"

run_sh 'printf -- "-3000000\n" >"$SD_PS/battery/current_now"
        for i in 1 2 3; do _sd_chg_scan=0; sd_chg_snapshot 1; done'
# 真降档会经过一档中间值（16W），最终落到 12W，所以最多 3 条；
# 关键是它不再像以前那样每 3 秒一条。
c=$(cnt)
[ "$c" -le 3 ] && ok "降到 3.0A 后收敛（$c 条，不再刷屏）" || bad "降档后写了 $c 条"
tail -n 1 "$BASE/data/log.txt" | grep -q 'ibat=-3000mA' \
    && ok "末条是降档后的新值" || bad "末条不是 3.0A：$(tail -n 1 "$BASE/data/log.txt")"

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

echo "[7] 功率取 5 点中值"
# bcc 电流是瞬时值，充电时在两档之间脉动（±600mA ↔ vbat ±40mV）；
# 直接画出来就是一条锯齿。最近 5 次取中值，既压住脉动又跟得上真实降档。
setup
med() { run_sh "sd_power_median $1 1; printf '%s' \"\$_sd_rv\""; }
chk "第 1 个样本原样输出" "$(med 2445)" "2445"
chk "第 2 个样本仍原样输出" "$(med 3148)" "3148"
chk "满 3 个取中值" "$(med 3614)" "3148"
med 3587 >/dev/null
chk "5 个样本取中值" "$(med 3603)" "3587"

n=$(wc -l <"$BASE/data/run/power.hist" | tr -d ' ')
chk "历史只留 5 条" "$n" "5"

# 插拔那一刻两种工况不能混算：状态码一变，旧样本直接作废
setup
med 2445 >/dev/null; med 3148 >/dev/null
chk "状态码变化后重新起算" "$(run_sh 'sd_power_median 900 0; printf "%s" "$_sd_rv"')" "900"

# 时钟往回跳（开机后 RTC 才校准）时，过旧和"未来"的样本都必须丢掉，
# 否则它们会一直占着 5 个窗口，把中值拖到错误的档位
setup; mkdir -p "$BASE/data/run"
now=$(date +%s)
printf '%s 1 9999\n%s 1 8888\n%s 1 1111\n%s 1 2222\n%s 1 3333\n' \
    "$((now - 3600))" "$((now + 3600))" "$((now - 3))" "$((now - 2))" "$((now - 1))" \
    >"$BASE/data/run/power.hist"
chk "过旧/未来样本不参与中值" "$(med 4444)" "2222"

echo "[8] 协议判定：欧加私有协议不能显示成公有快充"
# 实机 usb/type 只报 USB_DCP，9V/2A 是充电器上限而不是 PPS 协商。
# 以前按「≥8V 且 ≥2A」判 pps，30W 的 VOOC 被显示成“公有快充”。
setup
printf '9000000\n' >"$ROOT/ps/usb/voltage_max"
printf '7\n'       >"$ROOT/oplus/battery/charge_technology"
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'proto=vooc' && ok "tech=7 → vooc" || bad "tech=7 判错: $line"

setup
printf '9000000\n' >"$ROOT/ps/usb/voltage_max"
printf '14\n'      >"$ROOT/oplus/battery/charge_technology"
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'proto=pd' && ok "tech=14 → pd（不是 pps）" || bad "tech=14 判错: $line"

setup
printf '9000000\n' >"$ROOT/ps/usb/voltage_max"
printf 'SVOOC\n'   >"$ROOT/ps/usb/real_type"
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'proto=vooc' && ok "real_type=SVOOC → vooc" || bad "real_type 判错: $line"

setup
printf '9000000\n' >"$ROOT/ps/usb/voltage_max"
printf '1\n'       >"$ROOT/oplus/battery/voocchg_ing"
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'proto=vooc' && ok "voocchg_ing=1 → vooc" || bad "voocchg_ing 判错: $line"

# 私有协议在线时欧加的 usb/type 也可能写 USB_PD（充电器先 PD 握手再切 VOOC）。
# tech 是驱动自己维护的档位，必须压过类型串，否则 30W VOOC 永远显示 PD。
setup
printf '9000000\n' >"$ROOT/ps/usb/voltage_max"
printf 'USB_PD\n'  >"$ROOT/ps/usb/type"
printf 'USB_PD\n'  >"$ROOT/ps/usb/real_type"
printf '8\n'       >"$ROOT/oplus/battery/charge_technology"
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'proto=vooc' && ok "type=USB_PD + tech=8 → vooc（tech 优先）" || bad "类型串压过 tech: $line"

setup
printf '9000000\n' >"$ROOT/ps/usb/voltage_max"
printf 'USB_PD\n'  >"$ROOT/ps/usb/type"
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'proto=pd' && ok "无 tech 时 type=USB_PD → pd" || bad "无 tech 类型串判错: $line"

echo "[8b] 没插充电器不能显示成 PD"
# voltage_max / current_max 是端口能力上限，拔线后仍常驻 5V/500mA（标准 SDP）。
# 以前拿「v>0 就是 PD」兜底，面板没插电也一直写着「PD 快充」。
setup
printf '0\n'           >"$ROOT/ps/usb/online"
printf '5000000\n'     >"$ROOT/ps/usb/voltage_max"
printf '500000\n'      >"$ROOT/ps/usb/current_max"
printf 'Discharging\n' >"$ROOT/ps/battery/status"
rm -f "$ROOT/ps/usb/voltage_now"
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'proto=none' && ok "online=0 → none" || bad "拔线仍判协议: $line"
echo "$line" | grep -q 'proto=pd'   && bad "拔线仍显示 PD" || ok "拔线不显示 PD"

setup
printf 'Discharging\n' >"$ROOT/ps/battery/status"
rm -f "$ROOT/ps/usb/voltage_now"
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'proto=none' && ok "无 online 节点也无输入 → none" || bad "无输入仍判协议: $line"

echo "[8c] 有适配器但无协议字样时不再猜 PD"
setup
printf '1\n'       >"$ROOT/ps/usb/online"
printf '9000000\n' >"$ROOT/ps/usb/voltage_max"
printf '2000000\n' >"$ROOT/ps/usb/current_max"
printf '0\n'       >"$ROOT/oplus/battery/charge_technology"
printf '0\n'       >"$ROOT/oplus/battery/voocchg_ing"
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'proto=unknown' && ok "9V/2A 无字样 → unknown" || bad "仍瞎猜协议: $line"
echo "$line" | grep -q 'proto=pd'      && bad "无证据仍判 PD" || ok "无证据不判 PD"

setup
printf '1\n'  >"$ROOT/ps/usb/online"
printf '14\n' >"$ROOT/oplus/battery/charge_technology"
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'proto=pd' && ok "tech=14 → pd（有依据）" || bad "tech=14 判错: $line"

echo "[9] 一行里带输入侧实测与两侧功率"
setup
printf '2030000\n' >"$ROOT/ps/usb/current_now"
printf '9000000\n' >"$ROOT/ps/usb/voltage_max"
printf -- '-4000000\n' >"$ROOT/ps/battery/current_now"
line=$(run_sh 'sd_chg_line')
echo "$line" | grep -q 'iusb=2.03A' && ok "iusb 取实测输入电流" || bad "iusb: $line"
echo "$line" | grep -q 'pin=18.0W'  && ok "pin = iusb×vusb" || bad "pin: $line"
echo "$line" | grep -q 'pb=16.9W'   && ok "pb = |ibat|×vbat" || bad "pb: $line"
echo "$line" | grep -q 'cells=1'    && ok "cells 字段" || bad "cells: $line"

echo "[10] 日志级别语义：0 关 / 1 事件 / 2 现场"
setup
sed -i 's/log_level=3/log_level=0/' "$BASE/data/state.conf"
run_sh 'sd_info log "不应出现"; sd_chg_snapshot 1'
n=$(grep -c '不应出现' "$BASE/data/log.txt" 2>/dev/null || echo 0)
chk "级别 0 不写事件" "$n" "0"
chk "级别 0 不写快照" "$(cnt)" "0"

setup
sed -i 's/log_level=3/log_level=1/' "$BASE/data/state.conf"
run_sh 'sd_info log "事件应出现"; sd_chg_snapshot 1'
grep -q '事件应出现' "$BASE/data/log.txt" && ok "级别 1 写事件" || bad "级别 1 丢了事件"
chk "级别 1 不写快照" "$(cnt)" "0"

echo
echo "结果：通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
