#!/bin/sh
# 机型适配矩阵：用不同机型的 sysfs 布局跑真实命令，看"哪些功能真的能用"。
#
# 与 run.sh 的分工：run.sh 钉行为细节（一次装好 OPPO Find X8 场景，跑 500 多项），
# 这里钉兼容面（同一套代码换 4 种机型的节点布局，看会不会整段失效）。
# 只做命令级验证，不起守护 —— 起守护要几十秒，机器矩阵会被拖成几分钟。
#
# 用法: sh tests/sim/machines.sh

PASS=0; FAIL=0; FAILED=""
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
ng() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; FAILED="$FAILED  $*
"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else ng "$3 (want=$2 got=$1)"; fi; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) ng "$3（缺「$2」）" ;; esac; }
hasnt() { case "$1" in *"$2"*) ng "$3（出现了「$2」）" ;; *) ok "$3" ;; esac; }

MOD=/opt/qc-m
D=/data/adb/qc-m
# 必须连目录一起删再拷：MOD 已存在时 cp -a src dst 会嵌套成 dst/src，
# 于是整套用例跑的是上一轮的旧代码（这个坑踩过一次）。
rm -rf "$D" "$MOD"
cp -a "$(dirname "$0")/../.." "$MOD" 2>/dev/null || cp -a /mod "$MOD"
chmod +x "$MOD"/*.sh

# ---------------------------------------------------------------- 桩
cat >/usr/local/bin/getprop <<'EOF'
#!/bin/sh
case "$1" in
  ro.product.odm.manufacturer|ro.product.vendor.manufacturer|ro.product.manufacturer)
      echo "${M_MFR:-realme}" ;;
  ro.product.model)                echo "${M_MODEL:-RMX0000}" ;;
  ro.vendor.oplus.market.name)     echo "${M_NAME:-realme GT8 Pro}" ;;
  ro.soc.model)                    echo "${M_SOC:-SM8850}" ;;
  ro.board.platform)               echo "${M_PLAT:-sun}" ;;
  ro.soc.manufacturer)             echo "${M_SOCMFR:-Qualcomm}" ;;
  ro.hardware)                     echo "${M_HW:-qcom}" ;;
  ro.build.display.id)             echo "${M_BUILD:-RMX0000_16.0.1}" ;;
  ro.build.version.release)        echo "${M_ANDROID:-16}" ;;
  ro.build.version.security_patch) echo 2026-10-01 ;;
  sys.boot_completed)              echo 1 ;;
  *) echo "" ;;
esac
EOF
printf '#!/bin/sh\necho "UI: $*"\n' >/usr/local/bin/ui_print
printf '#!/bin/sh\necho "ABORT: $*" >&2\nexit 1\n' >/usr/local/bin/abort
printf '#!/bin/sh\nexit 0\n' >/usr/local/bin/start
printf '#!/bin/sh\nexit 0\n' >/usr/local/bin/stop
printf '#!/bin/sh\nexit 1\n' >/usr/local/bin/chcon
cat >/usr/local/bin/settings <<'EOS'
#!/bin/sh
DB=/tmp/settings-m.db
case "$1" in
  get)    grep "^$3=" "$DB" 2>/dev/null | cut -d= -f2- ;;
  put)    k=$3; v=$4
          grep -v "^$k=" "$DB" 2>/dev/null >"$DB.t"
          printf '%s=%s\n' "$k" "$v" >>"$DB.t"
          mv -f "$DB.t" "$DB" ;;
  delete) grep -v "^$3=" "$DB" 2>/dev/null >"$DB.t"; mv -f "$DB.t" "$DB" ;;
esac
EOS
cat >/usr/local/bin/cmd <<'EOS'
#!/bin/sh
case "$2" in
  get-supported-modes)
    printf 'Supported modes for display 0:\n'
    for r in $M_MODES; do
      printf '  Mode ID: 1, Resolution: 1560x3136, Refresh Rate: %s.00 Hz\n' "$r"
    done ;;
  get-active-mode)
    r=$(settings get system peak_refresh_rate 2>/dev/null)
    case "$r" in ''|null) r=120 ;; esac
    printf 'Active mode for display 0: Mode ID: 3, Resolution: 1560x3136, Refresh Rate: %s.00 Hz\n' "$r" ;;
esac
EOS
chmod +x /usr/local/bin/getprop /usr/local/bin/ui_print /usr/local/bin/abort \
         /usr/local/bin/start /usr/local/bin/stop /usr/local/bin/chcon \
         /usr/local/bin/settings /usr/local/bin/cmd 2>/dev/null

# ---------------------------------------------------------------- 假 sysfs
SYSN=/sys
fresh_sys() {
    umount "$SYSN" 2>/dev/null || umount -l "$SYSN" 2>/dev/null
    mount -t tmpfs tmpfs "$SYSN" || { echo "NO_TMPFS_SYS"; exit 1; }
    mkdir -p "$SYSN/class/thermal" "$SYSN/class/power_supply" \
             "$SYSN/devices/virtual/oplus_chg/battery"
}
zone() { # 名 类型 温度(mC)
    mkdir -p "$SYSN/class/thermal/$1"
    printf '%s\n' "$2" >"$SYSN/class/thermal/$1/type"
    printf '%s\n' "$3" >"$SYSN/class/thermal/$1/temp"
    : >"$SYSN/class/thermal/$1/emul_temp"
}
zone_nonl() { # 真机实测：temp 末尾不带换行，read 读到值后仍返回 1
    mkdir -p "$SYSN/class/thermal/$1"
    printf '%s' "$2" >"$SYSN/class/thermal/$1/type"
    printf '%s' "$3" >"$SYSN/class/thermal/$1/temp"
    : >"$SYSN/class/thermal/$1/emul_temp"
}
zone_noemul() { # 只有 temp，没有 emul_temp：模拟写了 emul_temp 也没用的机型
    mkdir -p "$SYSN/class/thermal/$1"
    printf '%s\n' "$2" >"$SYSN/class/thermal/$1/type"
    printf '%s\n' "$3" >"$SYSN/class/thermal/$1/temp"
}
psnode() { mkdir -p "${1%/*}"; printf '%s\n' "$2" >"$1"; }

# 每个机型跑前清干净，避免上一个机型的 state / run 残留
reset_mod() {
    rm -rf "$D"; mkdir -p "$D"
    export SD_DATA="$D" MODDIR="$MOD" \
           SD_ZONE_GLOB="$SYSN/class/thermal/thermal_zone*" \
           SD_OPLUS_CHG="$SYSN/class/oplus_chg/battery" \
           SD_MTK_CMD=/proc/mtk_battery_cmd \
           SD_VOTABLE=/proc/oplus-votable
    : >/tmp/settings-m.db
}

# 命令入口：走 action.sh，和真机 / WebUI 完全同一条代码路径
q() { SD_DATA="$D" MODDIR="$MOD" SD_NO_DAEMON=1 sh "$MOD/action.sh" "$@"; }
# 内部函数入口：只给库函数用（state 走文件，跨进程可见）
qlib() { SD_DATA="$D" MODDIR="$MOD" SD_NO_DAEMON=1 sh -c ". $MOD/lib/qc.sh; $*"; }

# ============================================================ M0 真机布局
# 这一段是照着真机 check/probe 的原始输出录的，不是"理想命名"：
#   * 99 个温区，temp 文件末尾没有换行
#   * 没有 battery 温区，只有 vbat（电压）
#   * 混着 cpu-hw-trip（跳闸阈值）、bcl-lvl / ibat-lvl（电流档位）
#   * sys-therm-0 常态 42℃，比电池还热
# 旧代码在这里同时踩两个坑：read 退出码让 99 个温区全判不可读，
# 哨兵又可能落到 42℃ 的板温上，墙一设就永远不伪装。
echo "===== M0 realme GT8 Pro 实测布局 · temp 无换行 ====="
fresh_sys
reset_mod
zone_nonl thermal_zone0  cpullc-0-0        54800
zone_nonl thermal_zone1  cpu-0-0-0         56700
zone_nonl thermal_zone2  cpu-0-0-1         54800
zone_nonl thermal_zone3  cpullc-1-0        50800
zone_nonl thermal_zone4  cpu-1-0-0         50200
zone_nonl thermal_zone5  gpuss-0           48600
zone_nonl thermal_zone6  ddr               50500
zone_nonl thermal_zone7  qmx-0-0           52500
zone_nonl thermal_zone8  nsphvx-0          47800
zone_nonl thermal_zone9  mdmss-0           48400
zone_nonl thermal_zone10 camera-0          49200
zone_nonl thermal_zone11 video             49600
zone_nonl thermal_zone12 shell_front       30000
zone_nonl thermal_zone13 shell_frame       30000
zone_nonl thermal_zone14 shell_back        30000
zone_nonl thermal_zone15 sys-therm-0       42106
zone_nonl thermal_zone16 sys-therm-2       47321
zone_nonl thermal_zone17 pmh0104_tz        37000
zone_nonl thermal_zone18 pmr735d_tz        37000
zone_nonl thermal_zone19 pm8010m_tz        37000
zone_nonl thermal_zone20 cpu-hw-trip-0     95000
zone_nonl thermal_zone21 cpu-hw-trip-1     95000
zone_nonl thermal_zone22 pmh0101-bcl-lvl0  0
zone_nonl thermal_zone23 pmh0101-bcl-lvl1  0
zone_nonl thermal_zone24 pmih010x-ibat-lvl0 0
zone_nonl thermal_zone25 vbat              0
# 真机上还有三个"读得到但不是正常温度"的节点，单个就够把归一化打偏：
#   socd 直接以度为单位（69，不是 69000）
#   sys-therm-12 报 -40960（未接热敏，驱动填了哨兵值）
#   usb 报 0（未插入）
zone_nonl thermal_zone26 socd              69
zone_nonl thermal_zone27 sys-therm-12      -40960
zone_nonl thermal_zone28 usb               0
zone_nonl thermal_zone29 board_temp        43059
psnode "$SYSN/class/power_supply/battery/status"      Charging
psnode "$SYSN/class/power_supply/battery/capacity"    55
psnode "$SYSN/class/power_supply/battery/temp"        380
psnode "$SYSN/class/power_supply/battery/voltage_now" 8000000
psnode "$SYSN/class/power_supply/usb/current_max"     500000

export M_MODES="60 90 120 144" M_SOC=SM8850 M_PLAT=canoe M_SOCMFR=Qualcomm \
       M_MFR=realme M_NAME="realme GT8 Pro" M_MODEL=RMX0000 M_HW=qcom

out=$(q check)
hasnt "$out" "一个都读不到" "M0 temp 无换行时不再全判不可读"
has "$out" "Qualcomm（高通）" "M0 平台识别为高通（canoe）"

eq "$(qlib 'sd_zone_class vbat; printf %s "$_sd_zc"')" "other" "M0 vbat（电压）不当电池温度"
eq "$(qlib 'sd_zone_class cpu-hw-trip-0; printf %s "$_sd_zc"')" "other" "M0 跳闸点不当 core"
eq "$(qlib 'sd_zone_class pmh0104_tz; printf %s "$_sd_zc"')" "board" "M0 PMIC 归主板"
eq "$(qlib 'sd_zone_class sys-therm-0; printf %s "$_sd_zc"')" "board" "M0 sys-therm 归主板"
eq "$(qlib 'sd_zone_class pmh0101-bcl-lvl0; printf %s "$_sd_zc"')" "other" "M0 电流档位归 other"
eq "$(qlib 'sd_zone_class socd; printf %s "$_sd_zc"')" "core" "M0 socd 归 core"
eq "$(qlib 'sd_sentinel_temp_v /sys/class/thermal/thermal_zone27; echo $?')" "1" "M0 负值温区判为不可读"
hasnt "$(q check)" "一个都读不到" "M0 混有负值/0 值温区时仍判为可读"
# cpullc 是 cpul-lc，名字里没有完整 "cpu" 子串；归错就少 4 个 core 候选
eq "$(qlib 'sd_zone_class cpullc-0-0; printf %s "$_sd_zc"')" "core" "M0 cpullc（CPU 缓存）归 core"
eq "$(qlib 'sd_zone_class cpuss-0; printf %s "$_sd_zc"')" "core" "M0 cpuss 归 core"
# 伪装命令必须真的落到 core 节点上，而且不能只剩结论一行
has "$(q core 45 2>&1)" "伪装 -> 45" "M0 core 伪装成功"
eq "$(cat "$SYSN/class/thermal/thermal_zone1/temp")" "45000" "M0 伪装写入 cpu-0-0-0"
has "$(q zones 2>&1)" "core 候选" "M0 zones 能列全表"

# 哨兵必须是电量计的 38℃，不能是 42.1℃ 的板温
eq "$(qlib 'sd_shell_target >/dev/null; printf %s "$_sd_last_zone"')" "battery(ps)" "M0 哨兵回落到电量计"
eq "$(qlib 'sd_shell_target >/dev/null; printf %s "$_sd_last_cur"')" "38" "M0 当前温度取电量计 38℃"

# 墙 42 低于板温 42.1 但高于电池 38：伪装必须还在
q wall 42 >/dev/null 2>&1
eq "$(qlib 'sd_shell_target >/dev/null; printf %s "$_sd_last_out"')" "30" "M0 墙 42 时伪装仍然生效"

# 墙 36 低于电池 38：立刻交回真实温度
q wall 36 >/dev/null 2>&1
eq "$(qlib 'sd_shell_target >/dev/null; printf %s "$_sd_last_out"')" "0" "M0 墙低于电池温度时停止伪装"

qlib 'sd_spoof_apply core 45' >/dev/null 2>&1
eq "$(cat "$SYSN/class/thermal/thermal_zone1/temp")" "45000" "M0 core 伪装写入 cpu-0-0-0"
eq "$(cat "$SYSN/class/thermal/thermal_zone25/temp")" "0" "M0 vbat 未被伪装"
qlib 'sd_spoof_clear_scope core' >/dev/null 2>&1

# 电池 55℃ 必须熔断 —— vbat 排除后如果没接上电量计，这里会静默不触发
psnode "$SYSN/class/power_supply/battery/temp" 550
q core 45 >/dev/null 2>&1
eq "$(qlib 'sd_state_load; sd_sentinel_guard; printf %s $?')" "1" "M0 电池 55℃ 触发熔断"
psnode "$SYSN/class/power_supply/battery/temp" 380

# ============================================================ M1 GT8 Pro
echo "===== M1 realme GT8 Pro · SM8850 · realme UI 7 · 120W 双芯 144Hz ====="
fresh_sys
reset_mod
zone thermal_zone0 shell_back    31500
zone thermal_zone1 battery        38500
zone thermal_zone2 xo-therm       40500
zone thermal_zone3 cpu-0-0        43000
zone thermal_zone4 cpu-1-0        44500
zone thermal_zone5 gpu-0-0        44000
zone thermal_zone6 ddr-0-0        42000
zone thermal_zone7 charger-therm  36500
zone thermal_zone8 pa-therm0      39000
zone thermal_zone9 socd           45000
psnode "$SYSN/class/power_supply/battery/status"       Charging
psnode "$SYSN/class/power_supply/battery/capacity"     55
psnode "$SYSN/class/power_supply/battery/temp"         385
psnode "$SYSN/class/power_supply/battery/voltage_now"  8000000
psnode "$SYSN/class/power_supply/usb/real_type"        USB_TYPE_SUPERVOOC
psnode "$SYSN/class/power_supply/usb/voltage_max"      11000000
psnode "$SYSN/class/power_supply/usb/current_max"      11000000
psnode "$SYSN/class/oplus_chg/battery/chg_current_max" 11000
psnode "$SYSN/class/oplus_chg/battery/current_max"     11000
psnode "$SYSN/class/oplus_chg/battery/chg_enable"      1
psnode "$SYSN/class/oplus_chg/battery/batt_temp"       385
psnode "$SYSN/class/oplus_chg/battery/bcc_parms"       \
  '1,2,3,4,5,6,3820,8,5000,10,11,3830,13,14,15,16,17,18,19'

export M_MODES="60 90 120 144"
# 第一道门是安装脚本的厂商白名单：realme 机型装不上，后面全都无从谈起
SD_DATA="$D" MODPATH="$MOD" sh "$MOD/customize.sh" >/tmp/m1inst.log 2>&1
eq "$?" "0" "M1 安装脚本在 realme 机型上不中止"
has "$(cat /tmp/m1inst.log)" "realme GT8 Pro" "M1 安装界面显示正确机型名"
hasnt "$(cat /tmp/m1inst.log)" "仅支持" "M1 未被厂商白名单拦下"

out=$(q check)
has "$out" "Qualcomm（高通）"                  "M1 平台识别为高通"
has "$out" "10 个"                             "M1 扫到 10 个温区"
has "$out" "emul_temp"                         "M1 温度改写走 emul_temp"
has "$out" "限流"                              "M1 有限流节点"
has "$out" "2 芯"                              "M1 识别双电芯"
has "$out" "VOOC"                              "M1 协议识别为私有快充"

out=$(q probe)
has "$out" "cpu-0-0" "M1 probe 列出 cpu-0-0"
has "$out" "core"    "M1 cpu-0-0 归类为 core"

# 伪装：只动 core，不动电池与充电 IC
qlib 'sd_spoof_apply core 45' >/tmp/m1a.log 2>&1
eq "$(cat "$SYSN/class/thermal/thermal_zone3/temp")" "45000" "M1 core 伪装把 cpu-0-0 顶到 45℃"
eq "$(cat "$SYSN/class/thermal/thermal_zone1/temp")" "38500" "M1 电池温区未被伪装"
eq "$(cat "$SYSN/class/thermal/thermal_zone7/temp")" "36500" "M1 充电 IC 温区未被伪装"
qlib 'sd_spoof_clear_scope core' >/dev/null 2>&1

# 限流：oplus_chg 节点是 mA，不能写 3000000
# 关掉温度墙让目标固定 100%，否则这里测到的是"当前温度允许多少"，
# 单位对不对反而看不出来
q wall off >/dev/null 2>&1
has "$(q curr 3000 2>&1 | tail -1)" "已写入" "M1 限流命令回执包含已写入"
eq "$(cat "$SYSN/class/oplus_chg/battery/chg_current_max")" "3000" "M1 限流写入 mA 单位（未放大量级）"
eq "$(cat "$SYSN/class/oplus_chg/battery/current_max")" "3000" "M1 两个 oplus 电流节点都写"

# 刷新率：144 可用，185 应被机型列表挡掉
q hz 144 >/tmp/m1hz.log 2>&1
eq "$(settings get system peak_refresh_rate)" "144" "M1 锁 144Hz 写入系统设置"
q hz 185 >/tmp/m1hz2.log 2>&1
has "$(cat /tmp/m1hz2.log)" "未报告 185Hz" "M1 本机没有 185Hz 时明确拒绝"

# 温度墙 + 核心伪装同时开：真实温度超过墙就撤销
qlib 'sd_spoof_apply core 45' >/dev/null 2>&1
q wall 40 >/tmp/m1w.log 2>&1
has "$(cat /tmp/m1w.log)" "40" "M1 温度墙写入 40℃"
qlib 'sd_spoof_clear_scope core' >/dev/null 2>&1

# 哨兵：双芯机型的总压换算
q cells 2 >/dev/null 2>&1
has "$(qlib 'sd_cells_resolve; echo $_sd_rv' | tail -1)" "2" "M1 双芯参数被接受"

# ============================================================ M2 一加 13
echo "===== M2 一加 13 · SM8750 · ColorOS 15 · 100W 单芯 120Hz ====="
fresh_sys
reset_mod
zone thermal_zone0 cpu-0-0      52000
zone thermal_zone1 cpu-1-0      51000
zone thermal_zone2 gpu-0-0      50000
zone thermal_zone3 ddr-0-0      48000
zone thermal_zone4 battery      34000
zone thermal_zone5 xo-therm     38000
zone thermal_zone6 charger-therm 40000
zone thermal_zone7 skin-therm   33000
psnode "$SYSN/class/power_supply/battery/status"          Charging
psnode "$SYSN/class/power_supply/battery/capacity"        40
psnode "$SYSN/class/power_supply/battery/temp"            340
psnode "$SYSN/class/power_supply/battery/constant_charge_current_max" 8000000
psnode "$SYSN/class/power_supply/usb/real_type"           USB_TYPE_VOOC
psnode "$SYSN/class/power_supply/usb/voltage_max"         10000000
psnode "$SYSN/class/power_supply/usb/current_max"         10000000
psnode "$SYSN/class/oplus_chg/battery/chg_current_max"    10000

export M_MODES="60 90 120" M_NAME="OnePlus 13" M_MODEL=PJZ110 M_SOC=SM8750
out=$(q check)
has "$out" "Qualcomm（高通）" "M2 平台识别为高通"
has "$out" "1 芯"             "M2 识别单电芯"
eq "$(q curr 4000 >/dev/null 2>&1; cat "$SYSN/class/power_supply/battery/constant_charge_current_max")" \
   "4000000" "M2 通用节点按 µA 写入（4000mA → 4000000）"
qlib 'sd_spoof_apply core 45' >/dev/null 2>&1
eq "$(cat "$SYSN/class/thermal/thermal_zone0/temp")" "45000" "M2 core 伪装生效"
eq "$(cat "$SYSN/class/thermal/thermal_zone4/temp")" "34000" "M2 电池温区未被伪装"
qlib 'sd_spoof_clear_scope core' >/dev/null 2>&1

# ============================================================ M3 新平台变体
echo "===== M3 高通新命名变体 · cpuss / socd / bcl / pm8550 ====="
fresh_sys
reset_mod
zone thermal_zone0 cpuss-0        47000
zone thermal_zone1 cpuss-1        46000
zone thermal_zone2 gpu-0-0        45000
zone thermal_zone3 ddr-0-0        44000
zone thermal_zone4 socd           48000
zone thermal_zone5 bcl            0
zone thermal_zone6 skin-therm     32000
zone thermal_zone7 pm8550-therm   36000
zone thermal_zone8 battery        33000
psnode "$SYSN/class/power_supply/battery/status"   Charging
psnode "$SYSN/class/power_supply/battery/capacity" 70
psnode "$SYSN/class/power_supply/battery/temp"     330
psnode "$SYSN/class/power_supply/bms/current_max"  6000000

export M_MODES="60 120 144" M_NAME="测试机 A" M_MODEL=TESTA M_SOC=SM8850
out=$(q check)
has "$out" "Qualcomm（高通）" "M3 平台识别为高通"
out=$(qlib 'sd_spoof_apply core 42' 2>&1)
eq "$(cat "$SYSN/class/thermal/thermal_zone0/temp")" "42000" "M3 cpuss-0 被识别为 core 并伪装"
eq "$(cat "$SYSN/class/thermal/thermal_zone8/temp")" "33000" "M3 电池未被伪装"
eq "$(cat "$SYSN/class/thermal/thermal_zone7/temp")" "36000" "M3 PMIC 未被伪装"
# bcl 是电流不是温度，读 0 不能被当成"电池 0℃"
hasnt "$(qlib 'sd_pick_sentinel_v; echo $_sd_rv' | tail -1)" "bcl" "M3 bcl（电流节点）不会被选为温度哨兵"
qlib 'sd_spoof_clear_scope core' >/dev/null 2>&1

# ============================================================ M4 天玑
echo "===== M4 天玑 9400 · MTK 命名 · mtkts* ====="
fresh_sys
reset_mod
zone thermal_zone0 mtktscpu      46000
zone thermal_zone1 mtktsbattery  35000
zone thermal_zone2 mtktscharger  37000
zone thermal_zone3 mtktsPA       88000
zone thermal_zone4 mtktswmt      60000
zone thermal_zone5 shell-back    31000
psnode "$SYSN/class/power_supply/battery/status"              Charging
psnode "$SYSN/class/power_supply/battery/capacity"            50
psnode "$SYSN/class/power_supply/battery/temp"                350
psnode "$SYSN/class/power_supply/battery/input_current_limit" 5000000
psnode "$SYSN/class/power_supply/charger/current_max"         5000000

export M_MODES="60 90 120 144 165" M_SOC=MT6991 M_SOCMFR=MediaTek M_PLAT=mt6991 M_MFR=OPPO \
       M_NAME="测试机 B" M_MODEL=TESTB M_HW=mt6991
out=$(q check)
has "$out" "MediaTek（MTK）" "M4 平台识别为联发科"
has "$out" "限流"            "M4 找到 MTK 限流节点"
eq "$(q curr 2500 >/dev/null 2>&1; cat "$SYSN/class/power_supply/battery/input_current_limit")" \
   "2500000" "M4 MTK 的 input_current_limit 按 µA 写入（2500mA → 2500000）"
qlib 'sd_spoof_apply core 44' >/dev/null 2>&1
eq "$(cat "$SYSN/class/thermal/thermal_zone0/temp")" "44000" "M4 mtktscpu 被识别为 core"
eq "$(cat "$SYSN/class/thermal/thermal_zone1/temp")" "35000" "M4 mtktsbattery 受保护"
eq "$(cat "$SYSN/class/thermal/thermal_zone2/temp")" "37000" "M4 mtktscharger 受保护"
qlib 'sd_spoof_clear_scope core' >/dev/null 2>&1
hasnt "$(qlib 'sd_pick_sentinel_v; echo $_sd_rv' | tail -1)" "mtktsPA" "M4 PA 不会被选为哨兵"

# ============================================================ M5 陌生命名
echo "===== M5 陌生命名（无法归类的机型）====="
fresh_sys
reset_mod
zone thermal_zone0 tz0 40000
zone thermal_zone1 tz1 35000
psnode "$SYSN/class/power_supply/battery/status"   Charging
psnode "$SYSN/class/power_supply/battery/capacity" 60
psnode "$SYSN/class/power_supply/battery/temp"     350
psnode "$SYSN/class/power_supply/battery/current_max" 5000000

out=$(M_MODES="60 120" q check)
has "$out" "温区" "M5 仍能列出温区"
hasnt "$out" "0 个 · 一个都读不到" "M5 温区可读"
export M_SOC=SM9999 M_SOCMFR=Qualcomm M_PLAT=unknown M_NAME="测试机 C" M_MODEL=TESTC
out=$(q core 45 2>&1)
# 分类表认不出 tz0/tz1，但它们是可写的温度节点：兜底接管，
# 不能因为"名字没见过"就整个功能不可用
has "$out" "按节点兜底" "M5 陌生命名时按节点兜底，不直接放弃"
# 哨兵本身不参与伪装（tz0 被选为哨兵），落点在 tz1
eq "$(cat "$SYSN/class/thermal/thermal_zone1/temp")" "45000" "M5 兜底确实写入了节点"
eq "$(cat "$SYSN/class/power_supply/battery/temp")" "350" "M5 兜底不碰电量计"
# 温度读取还能用（other 类），限流也不依赖温区
has "$(qlib 'sd_curr_nodes | head -1')" "current_max" "M5 陌生命区不影响限流节点选择"

# ============================================================ M6 只有受保护温区
# 兜底也不能越过红线：表里全是电池/主板类时，没有合法的伪装目标，
# 必须明确拒绝，而不是把电池 NTC 钉死。
echo "===== M6 只有受保护温区 ====="
fresh_sys
reset_mod
zone thermal_zone0 battery 35000
zone thermal_zone1 charger-therm 42000
psnode "$SYSN/class/power_supply/battery/status"  Charging
psnode "$SYSN/class/power_supply/battery/capacity" 60
psnode "$SYSN/class/power_supply/battery/temp"     350
out=$(q core 45 2>&1)
has "$out" "没有 core 类型" "M6 只有受保护温区时明确拒绝"
hasnt "$out" "按节点兜底" "M6 兜底不越过受保护类"
eq "$(cat "$SYSN/class/thermal/thermal_zone0/temp")" "35000" "M6 电池 NTC 未被钉死"

# ============================================================ 汇总
echo
echo "===== 结果 ====="
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ -n "$FAILED" ] && printf '失败清单:\n%s' "$FAILED"
[ "$FAIL" -eq 0 ] || exit 1
