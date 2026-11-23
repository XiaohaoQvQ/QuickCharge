#!/bin/sh
# C 守护（qcmon）冒烟测试：在假 sysroot 上跑完整热路径，逐项断言。
# 用法：sh c-test.sh /path/to/qcmon
# 依赖：root + 允许 bind mount（模拟设备节点）
set -u

BIN=${1:-/tmp/qcmon_x86}   # 可以是 "qemu-aarch64-static /path/bin"
BASE=/tmp/qct
ROOT=$BASE/root
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $3，实际 $2）"; fi; }
chkn() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1（不应等于 $3）"; fi; }
has()  { if grep -q "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1（日志缺：$2）"; fi; }
nhas() { if grep -q "$2" "$3" 2>/dev/null; then bad "$1（日志不该有：$2）"; else ok "$1"; fi; }

z() { echo "$ROOT/sys/class/thermal/$1"; }
mkz() { # name type temp
    mkdir -p "$(z "$1")"
    printf '%s\n' "$2" >"$(z "$1")/type"
    printf '%s\n' "$3" >"$(z "$1")/temp"
}

setup() {
    rm -rf "$BASE" 2>/dev/null
    mkdir -p "$BASE/spoof"
    mkdir -p "$ROOT/sys/class/thermal"
    mkdir -p "$ROOT/sys/class/power_supply/battery"
    mkdir -p "$ROOT/sys/class/power_supply/usb"
    mkdir -p "$ROOT/sys/class/backlight/panel0-backlight"
    mkdir -p "$ROOT/sys/class/graphics/fb0"
    mkdir -p "$ROOT/sys/module/oplus_chg/parameters"
    mkdir -p "$ROOT/sys/class/oplus_chg/battery"
    mkdir -p "$ROOT/proc"

    # 温区：电池 / 壳温(可 emul) / 核心 / 板级熔断源 / 热点 / 非温度
    mkz thermal_zone0 battery        34000
    mkz thermal_zone1 shell_back     33000
    mkz thermal_zone2 cpu-0-0        45000
    mkz thermal_zone3 xo-therm       36000
    mkz thermal_zone4 pa            39000
    mkz thermal_zone5 vbat            4000
    mkz thermal_zone6 hw-trip0       60000
    mkz thermal_zone7 bms            34500
    : >"$(z thermal_zone1)/emul_temp"
    chmod 644 "$(z thermal_zone1)/emul_temp"

    printf 'Charging\n' >"$ROOT/sys/class/power_supply/battery/status"
    printf '34000\n'    >"$ROOT/sys/class/power_supply/battery/temp"
    printf '40\n'       >"$ROOT/sys/class/power_supply/battery/capacity"
    printf '3000000\n'  >"$ROOT/sys/class/power_supply/battery/constant_charge_current_max"
    printf '3000000\n'  >"$ROOT/sys/class/power_supply/battery/current_max"
    printf '0\n'        >"$ROOT/sys/class/backlight/panel0-backlight/actual_brightness"
    printf '0\n'        >"$ROOT/sys/class/graphics/fb0/blank"
    printf '0\n'        >"$ROOT/sys/module/oplus_chg/parameters/ignore_screen_state"
    printf '7\n'        >"$ROOT/sys/class/oplus_chg/battery/cool_down"
    chmod 644 "$ROOT/sys/class/oplus_chg/battery/cool_down"
    # 充电快照用到的节点
    printf '8850000\n'  >"$ROOT/sys/class/power_supply/usb/voltage_now"
    printf '2000000\n'  >"$ROOT/sys/class/power_supply/usb/current_max"
    printf 'USB_DCP\n'  >"$ROOT/sys/class/power_supply/usb/type"
    printf '4219000\n'  >"$ROOT/sys/class/power_supply/battery/voltage_now"
    printf -- '-3000\n' >"$ROOT/sys/class/power_supply/battery/current_now"
    printf '0\n'        >"$ROOT/sys/class/oplus_chg/battery/voocchg_ing"
    printf '14\n'       >"$ROOT/sys/class/oplus_chg/battery/charge_technology"
    printf '0\n'        >"$ROOT/proc/shell-temp"
    printf '1234.56 900.0\n' >"$ROOT/proc/uptime"

    mkdir -p "$BASE/data/run" "$BASE/mod"
    MP="$(dirname "$0")/../module.prop"
    [ -f "$MP" ] || MP="$(dirname "$0")/../quickcharge/module.prop"
    cp "$MP" "$BASE/mod/module.prop" 2>/dev/null || \
        printf 'id=quickcharge\nname=Quick Charge\nversion=2.9.44\nversioncode=29440\ndescription=QC\n' >"$BASE/mod/module.prop"
}

# 基础 state.conf
state() {
    cat >"$BASE/data/state.conf" <<EOF
temp_mode=${1:-static}
shell_temp=${2:-30}
core_temp=${3:-off}
noncore_temp=${4:-off}
wall=${5:-42}
aggr=${6:-10}
curr_max=${7:-0}
curr_edge=4
battery_limit=48
sentinel_limit=85
tick=5
fast_cap=55
log_level=4
hz=off
hz_hard=0
batt_spoof=off
cool_guard=1
EOF
}

run() { # 子命令
    SD_DATA=$BASE/data SD_SYSROOT=$ROOT SD_MODDIR=$BASE/mod \
    SD_SPOOF_DIR=$BASE/spoof SD_BL=$ROOT/sys/class/backlight \
    SD_ADB=$BASE/adb \
    $BIN "$@"
}

# 亮屏 / 息屏
screen_on()  { printf '512\n' >"$ROOT/sys/class/backlight/panel0-backlight/actual_brightness"; }
screen_off() { printf '0\n' >"$ROOT/sys/class/backlight/panel0-backlight/actual_brightness"; }

val() { cat "$1" 2>/dev/null | tr -d ' \r\n'; }

daemon_start() {
    SD_DATA=$BASE/data SD_SYSROOT=$ROOT SD_MODDIR=$BASE/mod \
    SD_SPOOF_DIR=$BASE/spoof SD_BL=$ROOT/sys/class/backlight \
    $BIN >"$BASE/daemon.out" 2>&1 &
    DPID=$!
}

daemon_stop() {
    kill -TERM "$DPID" 2>/dev/null
    i=0
    while kill -0 "$DPID" 2>/dev/null && [ "$i" -lt 40 ]; do
        sleep 0.1; i=$((i + 1))
    done
    kill -KILL "$DPID" 2>/dev/null
    wait "$DPID" 2>/dev/null
}

# ============================================================ 1. 分类
echo "[1] 温区分类与作用域"
setup
state static
out=$(run zones)
echo "$out" | grep -q 'battery  *cls=battery'      && ok "battery 归入 battery"      || bad "battery 分类"
echo "$out" | grep -q 'shell_back .*cls=shell'     && ok "shell_back 归入 shell"     || bad "shell 分类"
echo "$out" | grep -q 'cpu-0-0 .*cls=core'         && ok "cpu-0-0 归入 core"         || bad "core 分类"
echo "$out" | grep -q 'xo-therm .*cls=board'       && ok "xo-therm 归入 board"       || bad "board 分类"
echo "$out" | grep -q 'vbat .*cls=other'           && ok "vbat 归入 other（非温度）"   || bad "vbat 分类"
echo "$out" | grep -q 'hw-trip0 .*cls=other'       && ok "hw-trip0 归入 other"       || bad "hw-trip 分类"

# ============================================================ 2. 壳温目标
echo "[2] 壳温目标计算（static）"
setup
state static 30
screen_on
out=$(run once)
echo "$out" | grep -q 'real=34'  && ok "真实温度取到 34℃" || bad "真实温度：$out"
echo "$out" | grep -q 'lim=48'   && ok "电池限值 48℃"     || bad "限值：$out"
# 屏障 42、真实 34、base 30、gap 12：余量 8℃ 还够，按 base 上报 30（低于真值 4℃）
echo "$out" | grep -q 'out=30' && ok "上报温度压在屏障下方（30）" || bad "上报温度：$out"

# ============================================================ 3. static 全链
echo "[3] static 模式：壳温模拟 + 核心伪装"
setup
state static 30 42 off
screen_on
daemon_start
sleep 6
# 壳温模拟写到 emul_temp
ev=$(val "$(z thermal_zone1)/emul_temp")
[ -n "$ev" ] && [ "$ev" != 0 ] && ok "壳温写入 emul_temp=$ev" || bad "壳温未写入（$ev）"
# core 伪装：cpu-0-0 读到 42℃
cv=$(val "$(z thermal_zone2)/temp")
chk "核心伪装 42℃" "$cv" "42000"
# 电池与板级不该被 core 作用域动到
bv=$(val "$(z thermal_zone0)/temp")
chk "电池温区保持真实" "$bv" "34000"
# 哨兵（battery 优先）没被伪装
gv=$(val "$(z thermal_zone3)/temp")
chk "xo-therm 保持真实" "$gv" "36000"
# 遥测文件
if [ -f "$BASE/data/run/sensor" ]; then
    set -- $(cat "$BASE/data/run/sensor")
    [ $# -eq 7 ] && ok "sensor 七字段：$*" || bad "sensor 字段数 $#"
    chk "sensor 记录 real" "$2" "34"
    chk "sensor 记录 mode" "$6" "static"
else bad "sensor 未生成"; fi
# 心跳必须是 uptime + pid
if [ -f "$BASE/data/run/hb" ]; then
    set -- $(cat "$BASE/data/run/hb")
    [ "$1" -lt 100000 ] && chk "心跳 pid 正确" "$2" "$DPID" || bad "心跳格式：$*"
else bad "hb 未写入"; fi
# USR1 不能把守护打死
kill -USR1 "$DPID" 2>/dev/null
sleep 1
kill -0 "$DPID" 2>/dev/null && ok "USR1 后守护存活" || bad "USR1 杀死了守护"
has "重载信号被处理" "收到重载信号" "$BASE/data/log.txt"
daemon_stop
# 退出还原
cv=$(val "$(z thermal_zone2)/temp")
chk "退出后核心温度还原" "$cv" "45000"
ev=$(val "$(z thermal_zone1)/emul_temp")
chk "退出后壳温归零" "$ev" "0"
has "退出日志" "已还原" "$BASE/data/log.txt"

# ============================================================ 4. charge 模式
echo "[4] charge 模式：按电量切换"
setup
state charge 30 off off
screen_on
run sensor >/dev/null
ev=$(val "$(z thermal_zone1)/emul_temp")
[ -n "$ev" ] && [ "$ev" != 0 ] && ok "电量 40% < fast_cap，接管壳温" || bad "charge 模式未接管（$ev）"
printf '80\n' >"$ROOT/sys/class/power_supply/battery/capacity"
run sensor >/dev/null
ev=$(val "$(z thermal_zone1)/emul_temp")
chk "电量 80% ≥ fast_cap，关闭模拟" "$ev" "0"

# ============================================================ 5. 熔断与恢复
echo "[5] 熔断 / 暂停 / 冷却恢复"
setup
state static 30 42 off
screen_on
daemon_start
sleep 6
cv=$(val "$(z thermal_zone2)/temp")
chk "熔断前已伪装" "$cv" "42000"
# 把 xo-therm 推到 90（≥ sentinel_limit 85）
printf '90000\n' >"$(z thermal_zone3)/temp"
sleep 7
cv=$(val "$(z thermal_zone2)/temp")
chk "熔断后伪装撤销" "$cv" "45000"
has "熔断日志" "熔断" "$BASE/data/log.txt"
has "暂停日志" "已暂停伪装" "$BASE/data/log.txt"
# 回落到 80（85-3=82 以下）。熔断那轮的 sleep 是 5s，冷却判定要再等一轮
printf '80000\n' >"$(z thermal_zone3)/temp"
sleep 12
cv=$(val "$(z thermal_zone2)/temp")
chk "冷却后自动恢复伪装" "$cv" "42000"
has "恢复日志" "温度已回落" "$BASE/data/log.txt"
daemon_stop

# 温区与电量计打架时取高值：连接器侧偏高不能当作"温度其实不高"，
# 只信偏低的一侧，单点传感器挂了就是漏熔断。
setup
state static 30 42 off
screen_on
daemon_start
sleep 6
printf '50000\n' >"$(z thermal_zone0)/temp"
sleep 7
cv=$(val "$(z thermal_zone2)/temp")
# 旧逻辑会采信偏低的电量计 34℃，不熔断，core 伪装保持 42000
chk "电池温区 50℃ / 电量计 34℃：取高值熔断" "$cv" "45000"
has "熔断指向电池温区" "thermal_zone0" "$BASE/data/log.txt"
daemon_stop

# ============================================================ 6. 亮屏快充（内核参数）
echo "[6] 亮屏快充：内核 ignore_screen_state"
setup
state static 30
screen_off
# 先息屏一轮，学到基准
run sensor >/dev/null
sleep 1
screen_on
run sensor >/dev/null
sv=$(val "$ROOT/sys/module/oplus_chg/parameters/ignore_screen_state")
chk "亮屏后置 1" "$sv" "1"
[ -f "$BASE/data/run/scr.orig" ] && ok "落盘 scr.orig" || bad "scr.orig 未落盘"
chk "scr.way 记 kernel" "$(val "$BASE/data/run/scr.way")" "kernel"
screen_off
run sensor >/dev/null
run sensor >/dev/null
sv=$(val "$ROOT/sys/module/oplus_chg/parameters/ignore_screen_state")
chk "息屏后还原 0" "$sv" "0"

# ============================================================ 6b. FCC 回写路径：息屏保持
# 旧实现息屏 30s 后按 scr.orig 还原，把亮屏被压的 2A 写回去，功率再也上不来。
echo "[6b] 亮屏快充：FCC 回写（息屏不放手）"
setup
rm -rf "$ROOT/sys/module/oplus_chg"
state static 30
screen_off
run sensor >/dev/null
chk "息屏学到基准 3A" "$(val "$BASE/data/run/fcc.norm")" "3000"
printf '2000000\n' >"$ROOT/sys/class/power_supply/battery/constant_charge_current_max"
screen_on
run sensor >/dev/null
chk "亮屏被压后写回 3A" \
    "$(val "$ROOT/sys/class/power_supply/battery/constant_charge_current_max")" "3000000"
printf '2000000\n' >"$ROOT/sys/class/power_supply/battery/constant_charge_current_max"
screen_off
run sensor >/dev/null
run sensor >/dev/null
chk "息屏也顶回 3A" \
    "$(val "$ROOT/sys/class/power_supply/battery/constant_charge_current_max")" "3000000"

# ============================================================ 6c. 极限充电：墙顶到熔断前 1℃
echo "[6c] 极限充电：max_mode 覆盖 42℃ 墙"
setup
state static 30 off off 42 10 6000
printf 'max_mode=1\n' >>"$BASE/data/state.conf"
screen_off
out=$(run once)
echo "$out" | grep -q 'wall=47' && ok "电流墙 42 -> 47（熔断 48-1）" || bad "极限墙未生效：$out"
setup
state static 30 off off 42 10 6000
out=$(run once)
echo "$out" | grep -q 'wall=42' && ok "关掉后回到用户设的 42" || bad "非极限模式墙被改：$out"

# ============================================================ 7. 限流
echo "[7] 电流墙"
setup
state static 30 off off 42 10 3000
screen_on
run sensor >/dev/null
cv=$(val "$ROOT/sys/class/power_supply/battery/constant_charge_current_max")
chk "写入 3A（µA 单位）" "$cv" "3000000"
[ -f "$BASE/data/run/curr.orig" ] && ok "记录原始值" || bad "curr.orig 未落盘"
# 目标归零，还原
state static 30 off off 42 10 0
run sensor >/dev/null
cv=$(val "$ROOT/sys/class/power_supply/battery/constant_charge_current_max")
chk "关闭限流后还原" "$cv" "3000000"

# ============================================================ 8. 电池伪装
echo "[8] 电池伪装与硬上限"
setup
state static 30 off off 42 10 0
screen_on
# batt_spoof=30
printf 'batt_spoof=30\n' >>"$BASE/data/state.conf"
run sensor >/dev/null
bv=$(val "$(z thermal_zone0)/temp")
chk "电池温区被伪装成 30℃" "$bv" "30000"
# bms 在 sd_zone_class 里不属于 battery 类（只有 batt/battery 关键词），两版行为一致
nb=$(val "$(z thermal_zone7)/temp")
chk "bms 不参与电池伪装" "$nb" "34500"
# 哨兵仍要读真温 34
out=$(run once)
echo "$out" | grep -q 'real=34' && ok "哨兵读真实温度" || bad "哨兵读了伪装值：$out"
# 真实温度到 47，撤销并冷却
printf '47000\n' >"$ROOT/sys/class/power_supply/battery/temp"
run sensor >/dev/null
bv=$(val "$(z thermal_zone0)/temp")
chk "超硬上限撤销伪装" "$bv" "34000"
has "硬上限日志" "硬上限" "$BASE/data/log.txt"

# ============================================================ 9. off 模式
echo "[9] off 模式不接管"
setup
state off 30 42000 off
screen_on
daemon_start
sleep 6
cv=$(val "$(z thermal_zone2)/temp")
chk "off 模式不改核心温度" "$cv" "45000"
sv=$(val "$ROOT/sys/module/oplus_chg/parameters/ignore_screen_state")
chk "off 模式不接管亮屏快充" "$sv" "0"
daemon_stop

# ============================================================ 10. 描述同步
echo "[10] module.prop 描述同步"
setup
state static 30
screen_on
run sensor >/dev/null
d=$(grep '^description=' "$BASE/mod/module.prop" | cut -d= -f2-)
case "$d" in "✅ 运行中 · 温控档位"*) ok "描述已写回：$d" ;; *) bad "描述未同步：$d" ;; esac

# 配置项计数：普通挂载走 mounts.list（去重），元模块走 nm.list（不去重）
seq 1 49 | sed 's|^|/vendor/etc/f|' >"$BASE/data/mounts.list"
run sensor >/dev/null
case "$(grep '^description=' "$BASE/mod/module.prop")" in
    *"配置 49 项"*) ok "普通挂载计数 49" ;;
    *) bad "普通挂载计数：$(grep '^description=' "$BASE/mod/module.prop")" ;;
esac

mkdir -p "$BASE/adb/modules/meta-magic_mount"
: >"$BASE/data/mounts.list"
seq 1 37 | sed 's|^|system/vendor/etc/f|' >"$BASE/data/nm.list"
printf 'description=QC\n' >"$BASE/mod/module.prop"
run sensor >/dev/null
case "$(grep '^description=' "$BASE/mod/module.prop")" in
    *"配置 37 项"*) ok "元模块读 nm.list 计数 37" ;;
    *) bad "元模块计数：$(grep '^description=' "$BASE/mod/module.prop")" ;;
esac

: >"$BASE/adb/modules/meta-magic_mount/disable"
seq 1 12 | sed 's|^|/vendor/etc/g|' >"$BASE/data/mounts.list"
printf 'description=QC\n' >"$BASE/mod/module.prop"
run sensor >/dev/null
case "$(grep '^description=' "$BASE/mod/module.prop")" in
    *"配置 12 项"*) ok "元模块被 disable 时回退 mounts.list" ;;
    *) bad "disable 回退：$(grep '^description=' "$BASE/mod/module.prop")" ;;
esac

# ============================================================ 11. 降流解除
echo "[11] 降流解除 cool_down"
setup
state static 30
screen_on

COOL=$ROOT/sys/class/oplus_chg/battery/cool_down
BT=$ROOT/sys/class/power_supply/battery/temp
CAP=$ROOT/sys/class/power_supply/battery/capacity

printf '7\n'     >"$COOL"; printf '34000\n' >"$BT"; printf '40\n' >"$CAP"
run sensor >/dev/null 2>&1
chk "亮屏 34℃/40% → 0" "$(val "$COOL")" "0"

printf '7\n' >"$COOL"; printf '46000\n' >"$BT"
run sensor >/dev/null 2>&1
chk "电池 46℃ → 2" "$(val "$COOL")" "2"

printf '7\n' >"$COOL"; printf '49000\n' >"$BT"
run sensor >/dev/null 2>&1
chk "电池 49℃ → 不干预" "$(val "$COOL")" "7"

printf '7\n' >"$COOL"; printf '34000\n' >"$BT"; printf '90\n' >"$CAP"
run sensor >/dev/null 2>&1
chk "电量 90% 也写 0（写 1 会掉协议）" "$(val "$COOL")" "0"

printf '7\n' >"$COOL"; printf '46000\n' >"$BT"; printf '90\n' >"$CAP"
run sensor >/dev/null 2>&1
chk "电量 90% 且 46℃ → 2" "$(val "$COOL")" "2"

printf '7\n' >"$COOL"; printf '34000\n' >"$BT"; printf '40\n' >"$CAP"
screen_off
run sensor >/dev/null 2>&1
chk "灭屏也解除（驱动本来给 0）" "$(val "$COOL")" "0"

printf '7\n' >"$COOL"
screen_on
sed -i 's/^cool_guard=.*/cool_guard=0/' "$BASE/data/state.conf"
run sensor >/dev/null 2>&1
chk "cool_guard=0 → 不干预" "$(val "$COOL")" "7"

# ============================================================ 12. 双实例保护
echo "[12] 单实例锁"
setup
state static 30
screen_on
daemon_start
sleep 2
out=$(run 2>&1)
case "$out" in *"已有实例"*) ok "第二个实例自动退出" ;; *) bad "未拦住重复启动：$out" ;; esac
daemon_stop

# ============================================================ 13. 电池温区优选
echo "[13] 电池温区优选"
setup
state static 30 42 off
# 同时存在 battery(34℃) 与 batt-therm(48℃)：必须选电芯
mkz thermal_zone8 batt-therm 48000
out=$(run once)
echo "$out" | grep -q 'real=34' && ok "优选电芯 battery（34℃）而非 batt-therm（48℃）" || bad "选了连接器温区：$out"
# 只剩连接器侧：比电量计高 14℃，必须回退电量计
printf 'batt-therm\n' >"$(z thermal_zone0)/type"
printf '48000\n'      >"$(z thermal_zone0)/temp"
rm -rf "$(z thermal_zone8)"
out=$(run once)
echo "$out" | grep -q 'real=34' && ok "连接器偏高 14℃ 时改用电量计" || bad "未回退电量计：$out"
echo "$out" | grep -q 'zone=battery(ps)' && ok "温区标注为 battery(ps)" || bad "zone 标注错误：$out"

# ============================================================ 14. 充电快照
echo "[14] 充电快照"
setup
state static 30 42 off
out=$(run chg)
echo "$out" | grep -q 'vusb=8.85V'   && ok "vusb 换算 µV→V" || bad "vusb 错：$out"
echo "$out" | grep -q 'imax=2.00A'   && ok "imax 换算 µA→A" || bad "imax 错：$out"
echo "$out" | grep -q 'vbat=4.219V'  && ok "vbat 三位小数"   || bad "vbat 错：$out"
echo "$out" | grep -q 'ibat=-3mA'    && ok "ibat 保留负号"   || bad "ibat 错：$out"
echo "$out" | grep -q 'cool=7'       && ok "读 cool_down"    || bad "cool 错：$out"
echo "$out" | grep -q 'tech=14'      && ok "读 charge_technology" || bad "tech 错：$out"
echo "$out" | grep -q 'type=USB_DCP' && ok "读 usb/type"     || bad "type 错：$out"

# 这个节点的单位各机型不统一：多数 µV，也有报 mV 的（4219 表示 4.219V）
printf '4219\n' >"$ROOT/sys/class/power_supply/battery/voltage_now"
out=$(run chg)
echo "$out" | grep -q 'vbat=4.219V' && ok "vbat 报 mV 时归一" || bad "mV 未归一：$out"

echo "[15] 电池电流优先取 bcc"
setup
state static 30 42 off
printf '1,2,3,4,5,6,4200,8,-350,10,11,0,12,13,14,15,16,17,18\n' \
    >"$ROOT/sys/class/oplus_chg/battery/bcc_parms"
out=$(run chg)
echo "$out" | grep -q 'ibat=-350mA' && ok "current_now=-3mA 时用 bcc 的 -350mA" || bad "ibat 错：$out"

setup
state static 30 42 off
printf '0\n' >"$ROOT/sys/class/power_supply/battery/current_now"
printf '1,2,3,4,5,6,4200,8,-350,10,11,0,12,13,14,15,16,17,18\n' \
    >"$ROOT/sys/class/oplus_chg/battery/bcc_parms"
out=$(run chg)
echo "$out" | grep -q 'ibat=-350mA' && ok "灭屏 current_now=0 时用 bcc" || bad "ibat 错：$out"

echo "[16] 充电行只记原始节点，不下协议结论"
# 2.9.72 起删掉协议判定：tech/type 原样记录，不再输出 proto= 字段。
setup
state static 30 42 off
printf '9000000\n' >"$ROOT/sys/class/power_supply/usb/voltage_max"
printf '7\n'       >"$ROOT/sys/class/oplus_chg/battery/charge_technology"
out=$(run chg)
echo "$out" | grep -q 'tech=7' && ok "tech 原样记录" || bad "tech 丢失：$out"
case "$out" in *proto=*) bad "充电行仍有 proto：$out" ;; *) ok "充电行不含 proto" ;; esac

setup
state static 30 42 off
printf 'USB_PD\n' >"$ROOT/sys/class/power_supply/usb/type"
printf 'USB_PD\n' >"$ROOT/sys/class/power_supply/usb/real_type"
out=$(run chg)
echo "$out" | grep -q 'type=USB_PD' && ok "type 原样记录" || bad "type 丢失：$out"

echo "[16b] 拔线行不臆造协议"
setup
state static 30 42 off
printf 'Discharging\n' >"$ROOT/sys/class/power_supply/battery/status"
rm -f "$ROOT/sys/class/power_supply/usb/voltage_now"
out=$(run chg)
echo "$out" | grep -q 'status=Discharging' && ok "status 如实记录" || bad "status 丢失：$out"
case "$out" in *proto=*) bad "拔线行仍带 proto：$out" ;; *) ok "拔线行不含 proto" ;; esac

echo "[17] 输入侧实测与两侧功率"
setup
state static 30 42 off
printf '2030000\n' >"$ROOT/sys/class/power_supply/usb/current_now"
printf '9000000\n' >"$ROOT/sys/class/power_supply/usb/voltage_max"
printf -- '-4000000\n' >"$ROOT/sys/class/power_supply/battery/current_now"
out=$(run chg)
echo "$out" | grep -q 'iusb=2.03A' && ok "iusb 取实测输入电流" || bad "iusb 错：$out"
echo "$out" | grep -q 'pin=18.0W'  && ok "pin = iusb×vusb"     || bad "pin 错：$out"
echo "$out" | grep -q 'pb=16.9W'   && ok "pb = |ibat|×vbat"    || bad "pb 错：$out"

echo "[18] log_level=0 时守护不写日志"
setup
state static 30 42 off
sed -i 's/^log_level=.*/log_level=0/' "$BASE/data/state.conf"
run bench 1 >/dev/null 2>&1
n=$(grep -c '\[chg\]' "$BASE/data/log.txt" 2>/dev/null)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
chk "级别 0 不落快照" "$n" "0"

setup
state static 30 42 off
run bench 1 >/dev/null 2>&1
n=$(grep -c '\[chg\]' "$BASE/data/log.txt" 2>/dev/null)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
chk "级别 4 落首帧" "$n" "1"

echo
echo "结果：通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
