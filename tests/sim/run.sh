#!/bin/sh
# QC 仿真测试：alpine + tmpfs 伪造 Android 根文件系统

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$*"; }
ng()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$*"; }
eq()  { if [ "$1" = "$2" ]; then ok "$3"; else ng "$3 (want=$2 got=$1)"; fi; }

# ---------------------------------------------------------------- 桩
cat >/usr/local/bin/getprop <<'EOF'
#!/bin/sh
case "$1" in
  ro.product.odm.manufacturer)     echo "${FAKE_MFR:-OPPO}" ;;
  ro.product.vendor.manufacturer)  echo "${FAKE_MFR:-OPPO}" ;;
  ro.product.manufacturer)         echo "${FAKE_MFR:-OPPO}" ;;
  ro.product.model)                echo PJZ110 ;;
  ro.vendor.oplus.market.name)     echo "OPPO Find X8" ;;
  ro.soc.model)                    echo SM8750 ;;
  ro.build.display.id)             echo "PJZ110_16.0.1_A.1" ;;
  ro.build.version.release)        echo 16 ;;
  ro.build.version.security_patch) echo 2026-10-01 ;;
  sys.boot_completed)              echo 1 ;;
  *) echo "" ;;
esac
EOF
printf '#!/bin/sh\necho "UI: $*"\n' >/usr/local/bin/ui_print
printf '#!/bin/sh\necho "ABORT: $*" >&2\nexit 1\n' >/usr/local/bin/abort
printf '#!/bin/sh\nexit 0\n' >/usr/local/bin/start
printf '#!/bin/sh\nexit 0\n' >/usr/local/bin/stop
printf '#!/bin/sh\nexit 1\n' >/usr/local/bin/chcon   # 无 SELinux，模拟失败
printf '#!/bin/sh\necho "$@" >/tmp/am.args\n' >/usr/local/bin/am
cat >/usr/local/bin/settings <<'EOS'
#!/bin/sh
DB=/tmp/settings.db
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
    printf '  Mode ID: 1, Resolution: 1264x2780, Refresh Rate: 60.00 Hz\n'
    printf '  Mode ID: 2, Resolution: 1264x2780, Refresh Rate: 90.00 Hz\n'
    printf '  Mode ID: 3, Resolution: 1264x2780, Refresh Rate: 120.00 Hz\n'
    printf '  Mode ID: 4, Resolution: 1264x2780, Refresh Rate: 144.00 Hz\n' ;;
  get-active-mode)
    r=$(settings get system peak_refresh_rate 2>/dev/null)
    case "$r" in ''|null) r=60 ;; esac
    printf 'Active mode for display 0: Mode ID: 3, Resolution: 1264x2780, Refresh Rate: %s.00 Hz\n' "$r" ;;
esac
EOS
chmod +x /usr/local/bin/*

# ---------------------------------------------------------------- 假 sysfs
mount -t tmpfs tmpfs /sys 2>/dev/null || { echo "NO_TMPFS_SYS"; exit 1; }
mkzone() {  # dir type temp
    mkdir -p "/sys/class/thermal/$1"
    printf '%s\n' "$2" >"/sys/class/thermal/$1/type"
    printf '%s\n' "$3" >"/sys/class/thermal/$1/temp"
    : >"/sys/class/thermal/$1/emul_temp"
}
mkzone thermal_zone0 shell-back 30000
mkzone thermal_zone1 battery    46000
mkzone thermal_zone2 xo-therm   45000
mkzone thermal_zone3 cpu-0-0    50000
mkdir -p /sys/class/power_supply/battery
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '80\n'        >/sys/class/power_supply/battery/capacity

# ---------------------------------------------------------------- 假 vendor 配置
mkdir -p /vendor/etc /odm/etc
cat >/vendor/etc/sys_high_temp_protect_0.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<high_temp_protect>
    <item enable="true" threshold="65000"/>
    <item enable="true" threshold="70000"/>
</high_temp_protect>
EOF
cat >/vendor/etc/sys_thermal_control_config.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<thermal_control enable="true">
    <level value="1" enable="true"/>
    <level value="2" enable="true"/>
</thermal_control>
EOF
cat >/vendor/etc/thermallevel_to_fps.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<ThermalLevel>
    <level name="0" fps="120" temp="40000"/>
    <level name="1" fps="90.5" temp="42000"/>
    <level name="2" fps="60" temp="45000"/>
</ThermalLevel>
EOF
cat >/vendor/etc/sys_thermal_config.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<config>
    <cpu enable="1">1</cpu>
    <gpu enable="1">1</gpu>
    <other>1</other>
</config>
EOF
cat >/vendor/etc/devices_config.json <<'EOF'
{
  "battery": { "temp_window": "[150,450]", "high.capacity.threshold": "[150,450]" }
}
EOF
cat >/vendor/etc/QEGA_Config.txt <<'EOF'
SkinTemperatureNode: xo-therm
100001 hok 48000 1200
0 adaptive 50000
EOF
cat >/vendor/etc/charging_0.txt <<'EOF'
350,3000,4500
400,2500,4200
410,2000,4000
450,1000,3000
EOF
printf 'some=1\nother=2\n' >/vendor/etc/horae_0.conf

# 负例：CDATA（开闭标签计数会被误判）
cat >/vendor/etc/sys_thermal_control_config_cdata.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<root enable="true"><data><![CDATA[ a < b ]]></data></root>
EOF
# 负例：非配平
printf '<root enable="true"><item></root>\n' >/vendor/etc/sys_thermal_control_config_bad.xml

# ---------------------------------------------------------------- 模块副本
cp -a /mod /opt/qc
chmod +x /opt/qc/*.sh
SDD=/data/adb/quickcharge
mkdir -p "$SDD"

echo "===== T1 安装 ====="
MODPATH=/opt/qc sh -c '. /usr/local/bin/ui_print 2>/dev/null; MODPATH=/opt/qc . /opt/qc/customize.sh' >/tmp/install.log 2>&1
eq "$?" "0" "customize.sh 退出码 0"
grep -q "代码由 AI 辅助完成" /tmp/install.log && ok "横幅含 AI 辅助声明" || ng "缺 AI 辅助声明"
grep -q "coolapk.com/u/27316679" /tmp/install.log && ok "安装末尾显示酷安主页" || ng "缺酷安主页提示"
sleep 1
grep -q "27316679" /tmp/am.args 2>/dev/null && ok "刷写后调用 am 跳转主页" || ng "未触发主页跳转"
grep -q "已生成" /tmp/install.log && ok "安装日志有生成计数" || ng "安装日志缺生成计数"

OV=/opt/qc/files
n=$(find "$OV" -type f 2>/dev/null | wc -l | tr -d ' ')
eq "$n" "9" "生成 9 个覆盖文件"

eq "$(grep -c 'fps="144"' "$OV/vendor/etc/thermallevel_to_fps.xml" 2>/dev/null)" "3" "fps 全部改为 144"
eq "$(grep -c 'fps="90.5"' "$OV/vendor/etc/thermallevel_to_fps.xml" 2>/dev/null)" "0" "小数 fps 也被替换"
eq "$(grep -c 'enable="true"' "$OV/vendor/etc/sys_high_temp_protect_0.xml" 2>/dev/null)" "0" "高温保护 true→false"
grep -q 'threshold="65000"' "$OV/vendor/etc/sys_high_temp_protect_0.xml" && ok "高温阈值未被改动" || ng "高温阈值被改"
eq "$(grep -c 'enable="true"' "$OV/vendor/etc/sys_thermal_control_config.xml" 2>/dev/null)" "0" "温控开关 true→false"
grep -q '<level value="1"' "$OV/vendor/etc/sys_thermal_control_config.xml" && ok "温控档位数据保留" || ng "温控档位丢失"
eq "$(grep -c '>0<' "$OV/vendor/etc/sys_thermal_config.xml" 2>/dev/null)" "2" "legacy 含 enable 行的 1→0"
grep -q '<other>1</other>' "$OV/vendor/etc/sys_thermal_config.xml" && ok "legacy 非 enable 行未被误伤" || ng "legacy 误伤其他行"
grep -q '150,550\]' "$OV/vendor/etc/devices_config.json" && ok "充电窗口改到 55℃" || ng "充电窗口未改"
eq "$(grep -o '150,550\]' "$OV/vendor/etc/devices_config.json" 2>/dev/null | wc -l | tr -d ' ')" "2" "两处窗口都改"
grep -q 'SkinTemperatureNode: battery' "$OV/vendor/etc/QEGA_Config.txt" && ok "QEGA 取样节点改 battery" || ng "QEGA 未改"
eq "$(head -1 "$OV/vendor/etc/charging_0.txt")" "470,3000,4500" "充电曲线温度轴 +120"
eq "$(wc -c <"$OV/vendor/etc/horae_0.conf" | tr -d ' ')" "0" "horae 配置置空"
[ -f "$OV/vendor/etc/sys_thermal_control_config_cdata.xml" ] && ok "CDATA 文件结构可正常改写" || ng "CDATA 文件被误拒绝"
grep -q 'a < b' "$OV/vendor/etc/sys_thermal_control_config_cdata.xml" && ok "CDATA 内容未被破坏" || ng "CDATA 内容被破坏"
[ -f "$OV/vendor/etc/sys_thermal_control_config_bad.xml" ] && ng "非配平文件被误接受" || ok "非配平文件被拒绝"
[ -f "$SDD/backup/vendor/etc/thermallevel_to_fps.xml" ] && ok "原件已备份" || ng "原件未备份"
cmp -s "$SDD/backup/vendor/etc/charging_0.txt" /vendor/etc/charging_0.txt && ok "备份与原件逐字节一致" || ng "备份与原件不一致"
eq "$(grep '^temp_mode=' "$SDD/state.conf")" "temp_mode=off" "默认不开启伪装"
eq "$(grep '^wall=' "$SDD/state.conf")" "wall=42" "默认墙 42"
eq "$(grep '^aggr=' "$SDD/state.conf")" "aggr=10" "默认 aggr 10"

echo "===== T1b 覆盖安装不叠加 ====="
MODPATH=/opt/qc sh -c 'MODPATH=/opt/qc . /opt/qc/customize.sh' >/tmp/install2.log 2>&1
eq "$(head -1 "$OV/vendor/etc/charging_0.txt")" "470,3000,4500" "二次安装曲线未叠加"
eq "$(grep -c 'fps="144"' "$OV/vendor/etc/thermallevel_to_fps.xml")" "3" "二次安装 fps 未叠加"

echo "===== T1c 非欧加真拒绝 ====="
FAKE_MFR=Xiaomi MODPATH=/opt/qc sh -c 'MODPATH=/opt/qc . /opt/qc/customize.sh' >/tmp/install3.log 2>&1
eq "$?" "1" "Xiaomi 安装退出码 1"
grep -q "仅支持" /tmp/install3.log && ok "提示不支持机型" || ng "缺少不支持提示"

echo "===== T2 挂载 ====="
orig_md5=$(md5sum /vendor/etc/charging_0.txt | awk '{print $1}')
SD_MODDIR=/opt/qc sh /opt/qc/post-fs-data.sh >/tmp/pfd.log 2>&1
eq "$?" "0" "post-fs-data 退出码 0"
m=$(grep -c ' /vendor/etc/' /proc/mounts)
eq "$m" "9" "9 个 vendor 配置已挂载"
grep -q 'fps="144"' /vendor/etc/thermallevel_to_fps.xml && ok "挂载后读到的是覆盖层内容" || ng "挂载未生效"
eq "$(cat "$SDD/boot.count")" "1" "开机计数 1"

echo "===== T3 温度决策 ====="
MODDIR=/opt/qc
. /opt/qc/lib/qc.sh
sd_state_load
set_temp() { printf '%s\n' "$1" >/sys/class/thermal/thermal_zone1/temp; }
set_mode() { sd_state_set temp_mode static; sd_state_set shell_temp "$1"; sd_state_set wall "$2"; sd_state_set aggr "$3"; _sd_st_loaded=0; sd_state_load; }

set_mode 30 42 10
set_temp 38000; t=$(sd_shell_target); eq "$t" "30" "真实 38℃ → 上报 30℃"
set_temp 39000; t=$(sd_shell_target); eq "$t" "33" "真实 39℃ → 上报 33℃"
set_temp 40000; t=$(sd_shell_target); eq "$t" "36" "真实 40℃ → 上报 36℃"
set_temp 41000; t=$(sd_shell_target); eq "$t" "39" "真实 41℃ → 上报 39℃"
set_temp 42000; t=$(sd_shell_target); eq "$t" "0"  "真实 42℃ → 关闭模拟"
set_temp 30000; t=$(sd_shell_target); eq "$t" "30" "低温不伪造高温"
set_mode 30 42 0
set_temp 39000; t=$(sd_shell_target); eq "$t" "37" "aggr=0 时温差压到 2℃"

echo "===== T3b 熔断 ====="
set_mode 30 42 10
set_temp 49000
sd_sentinel_guard; r=$?
eq "$r" "1" "电池 49℃ 触发熔断"
eq "$(sd_state_get temp_mode off)" "off" "熔断后模式置 off"
eq "$(sd_state_get shell_temp 0)" "0" "熔断后 shell_temp 清 0"
set_temp 46000
sd_sentinel_guard; eq "$?" "0" "46℃ 不熔断"

echo "===== T3c 写入与守卫 ====="
set_mode 30 42 10
set_temp 38000
sd_shell_emul 30
eq "$(cat /sys/class/thermal/thermal_zone0/emul_temp)" "30000" "壳温节点写入毫摄氏度"
eq "$(cat /sys/class/thermal/thermal_zone1/emul_temp)" "" "电池节点未被写"
eq "$(cat /sys/class/thermal/thermal_zone2/emul_temp)" "" "xo-therm 未被写"
sd_shell_emul 0
eq "$(cat /sys/class/thermal/thermal_zone0/emul_temp)" "0" "0 表示关闭模拟"

echo "===== T4 参数与写入边界 ====="
eq "$(sd_state_int shell_temp 30 25 60)" "30" "shell_temp 缺省 30"
sd_state_set shell_temp 99
eq "$(sd_state_int shell_temp 30 25 60)" "30" "shell_temp=99 回落 30"
sd_state_set shell_temp abc
eq "$(sd_state_int shell_temp 30 25 60)" "30" "shell_temp=abc 回落 30"
sd_state_set shell_temp -5
eq "$(sd_state_int shell_temp 30 25 60)" "30" "shell_temp 负数回落 30"
sd_state_set aggr 99
eq "$(sd_state_int aggr 10 0 10)" "10" "aggr=99 回落 10"
sd_shell_emul 19; eq "$?" "1" "19℃ 拒绝写入"
sd_shell_emul 101; eq "$?" "1" "101℃ 拒绝写入"
sd_shell_emul 25; eq "$?" "0" "25℃ 允许写入"

echo "===== T4b 路径保护 ====="
( SD_DATA=/ ; . /opt/qc/lib/qc.sh; printf '%s' "$SD_DATA" ) >/tmp/pathguard.txt
eq "$(cat /tmp/pathguard.txt)" "/data/adb/quickcharge" "SD_DATA=/ 被纠正"

echo "===== T5 卸载还原 ====="
SD_DATA=$SDD sh /opt/qc/uninstall.sh >/tmp/unin.log 2>&1
eq "$?" "0" "卸载退出码 0"
eq "$(grep -c ' /vendor/etc/' /proc/mounts)" "0" "挂载全部解除"
after=$(md5sum /vendor/etc/charging_0.txt | awk '{print $1}')
eq "$after" "$orig_md5" "原文件逐字节恢复"
eq "$(cat /sys/class/thermal/thermal_zone0/emul_temp)" "0" "emul_temp 归零"
[ -d "$SDD" ] && ng "数据目录残留" || ok "数据目录已删除"
SD_DATA=$SDD sh /opt/qc/uninstall.sh >/dev/null 2>&1
eq "$?" "0" "重复卸载不报错"

echo "===== T5b 清单丢失反推卸载 ====="
MODPATH=/opt/qc sh -c 'MODPATH=/opt/qc . /opt/qc/customize.sh' >/dev/null 2>&1
SD_MODDIR=/opt/qc sh /opt/qc/post-fs-data.sh >/dev/null 2>&1
eq "$(grep -c ' /vendor/etc/' /proc/mounts)" "9" "重建后重新挂载"
rm -f "$SDD/mounts.list"
SD_DATA=$SDD sh /opt/qc/uninstall.sh >/dev/null 2>&1
eq "$(grep -c ' /vendor/etc/' /proc/mounts)" "0" "清单丢失时按覆盖层反推卸载"
eq "$(md5sum /vendor/etc/charging_0.txt | awk '{print $1}')" "$orig_md5" "反推卸载后原文件一致"

echo "===== T5c 守护进程清理 ====="
MODPATH=/opt/qc sh -c 'MODPATH=/opt/qc . /opt/qc/customize.sh' >/dev/null 2>&1
sd_state_set() { :; }
printf 'temp_mode=static\nshell_temp=30\ntick=5\nwall=42\naggr=10\n' >"$SDD/state.conf"
SD_MODDIR=/opt/qc sh /opt/qc/service.sh --daemon >/tmp/daemon.log 2>&1 &
DPID=$!
sleep 2
kill -0 "$DPID" 2>/dev/null && ok "守护进程已启动" || ng "守护未能启动"
SD_DATA=$SDD sh /opt/qc/uninstall.sh >/dev/null 2>&1
sleep 1
kill -0 "$DPID" 2>/dev/null && { ng "守护进程残留"; kill -9 "$DPID" 2>/dev/null; } || ok "守护进程已停止"
[ -d "$SDD" ] && ng "数据目录残留(守护轮)" || ok "数据目录已删除(守护轮)"

echo "===== T6 安全边界 ====="
MODPATH=/opt/qc sh -c 'MODPATH=/opt/qc . /opt/qc/customize.sh' >/dev/null 2>&1
SD_MODDIR=/opt/qc sh /opt/qc/post-fs-data.sh >/dev/null 2>&1
MODDIR=/opt/qc
. /opt/qc/lib/qc.sh

printf 'temp_mode=static\nshell_temp=30\nbattery_limit=200\nsentinel_limit=85\nwall=42\naggr=10\n' >"$SDD/state.conf"
_sd_st_loaded=0; sd_state_load
printf '49000\n' >/sys/class/thermal/thermal_zone1/temp
sd_sentinel_guard; eq "$?" "1" "battery_limit=200 时 49℃ 仍应熔断"

printf 'temp_mode=static\nshell_temp=30\nbattery_limit=48\nsentinel_limit=500\nwall=42\naggr=10\n' >"$SDD/state.conf"
_sd_st_loaded=0; sd_state_load
printf '90000\n' >/sys/class/thermal/thermal_zone3/temp
eq "$(sd_limit_for_zone /sys/class/thermal/thermal_zone3)" "85" "sentinel_limit=500 回落 85"

printf 'temp_mode=static\nshell_temp=30\nbattery_limit=48\nsentinel_limit=85\nwall=5\naggr=10\n' >"$SDD/state.conf"
_sd_st_loaded=0; sd_state_load
eq "$(sd_wall)" "42" "wall=5 回落默认 42"

mkdir -p /evil
mount -t tmpfs tmpfs /evil 2>/dev/null
grep -q ' /evil ' /proc/mounts && ok "测试挂载点已建立" || ng "测试挂载点未建立"
printf '/evil\n/vendor\n/data\n' >"$SDD/mounts.list"
SD_DATA=$SDD sh /opt/qc/uninstall.sh >/dev/null 2>&1
grep -q ' /evil ' /proc/mounts && ok "清单里的目录路径未被 umount" || ng "清单污染导致目录分区被卸载"
umount /evil 2>/dev/null

echo "===== T7 决策循环耗时 ====="
MODPATH=/opt/qc sh -c 'MODPATH=/opt/qc . /opt/qc/customize.sh' >/dev/null 2>&1
MODDIR=/opt/qc; . /opt/qc/lib/qc.sh
printf 'temp_mode=static\nshell_temp=30\nbattery_limit=48\nsentinel_limit=85\nwall=42\naggr=10\n' >"$SDD/state.conf"
sd_state_load
printf '38000\n' >/sys/class/thermal/thermal_zone1/temp
i=0; t0=$(date +%s)
while [ $i -lt 2000 ]; do sd_shell_target >/dev/null; i=$((i+1)); done
t1=$(date +%s)
echo "INFO  2000 次决策 $((t1-t0))s（容器 busybox ash，仅供量级参考）"
[ $((t1-t0)) -le 20 ] && ok "2000 次决策 <20s" || ng "决策循环异常缓慢"

echo "===== T8 WebUI 接口 ====="
rm -f "$SDD/state.conf"
MODPATH=/opt/qc sh -c 'MODPATH=/opt/qc . /opt/qc/customize.sh' >/dev/null 2>&1
J=$(SD_NO_DAEMON=1 sh /opt/qc/action.sh json 2>/dev/null)
echo "$J" | grep -q '^{.*}$' && ok "json 输出为单行对象" || ng "json 输出格式异常"
echo "$J" | grep -q '"aggr":10' && ok "json aggr=10" || ng "json aggr 错误"
echo "$J" | grep -q '"gap":12' && ok "json gap=12" || ng "json gap 错误"
echo "$J" | grep -q '"mode":"off"' && ok "json mode=off" || ng "json mode 错误"
echo "$J" | grep -q '"mounted":0' && ok "json mounted=0(未挂载)" || ng "json mounted 错误"
echo "$J" | grep -q '"daemon":false' && ok "json daemon=false" || ng "json daemon 错误"
V=$(grep '^version=' /opt/qc/module.prop | cut -d= -f2)
echo "$J" | grep -q "\"version\":\"$V\"" && ok "json 带版本号" || ng "json 缺版本号"
echo "$J" | grep -q '"target":0' && ok "json 关闭模式 target=0" || ng "json target 异常"
printf 'temp_mode=static\nshell_temp=30\nwall=42\naggr=10\n' >"$SDD/state.conf"
printf '41000\n' >/sys/class/thermal/thermal_zone1/temp
J2=$(SD_NO_DAEMON=1 sh /opt/qc/action.sh json 2>/dev/null)
echo "$J2" | grep -q '"target":39' && ok "json 上报值按渐进让步算(41→39)" || ng "json target 未按决策计算: $J2"

SD_NO_DAEMON=1 sh /opt/qc/action.sh base 35 >/dev/null 2>&1
eq "$?" "0" "base 35 执行成功"
eq "$(grep '^shell_temp=' "$SDD/state.conf")" "shell_temp=35" "base 写入 35"
SD_NO_DAEMON=1 sh /opt/qc/action.sh base 99 >/dev/null 2>&1
eq "$?" "1" "base 99 被拒绝"
eq "$(grep '^shell_temp=' "$SDD/state.conf")" "shell_temp=35" "拒绝后原值不变"

SD_NO_DAEMON=1 sh /opt/qc/action.sh aggr 4 >/dev/null 2>&1
eq "$(grep '^aggr=' "$SDD/state.conf")" "aggr=4" "WebUI 可改 aggr"
SD_NO_DAEMON=1 sh /opt/qc/action.sh aggr 11 >/dev/null 2>&1
eq "$?" "1" "aggr 11 被拒绝"

echo "===== T9 参数即时生效 ====="
SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/uninstall.sh >/dev/null 2>&1
sleep 1
MODPATH=/opt/qc sh -c 'MODPATH=/opt/qc . /opt/qc/customize.sh' >/dev/null 2>&1
printf 'temp_mode=static\nshell_temp=30\nsentinel_limit=110\nbattery_limit=48\nwall=42\naggr=10\ntick=300\ndefrev=2\n' >"$SDD/state.conf"
printf '46000\n' >/sys/class/thermal/thermal_zone1/temp
printf '100000\n' >/sys/class/thermal/thermal_zone2/temp
SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/service.sh --daemon >/tmp/d9.log 2>&1 &
D9=$!
sleep 3
eq "$(grep '^temp_mode=' "$SDD/state.conf")" "temp_mode=static" "soc=110 时主板 100℃ 不熔断"
J9=$(SD_NO_DAEMON=1 sh /opt/qc/action.sh json 2>/dev/null)
echo "$J9" | grep -q '"sentinel_limit":110' && ok "json 回读 soc=110" || ng "json 未保存 soc=110"
SD_MODDIR=/opt/qc sh /opt/qc/action.sh sentinel 85 >/dev/null 2>&1
sleep 2
eq "$(grep '^temp_mode=' "$SDD/state.conf")" "temp_mode=off" "soc 改回 85 后 2 秒内熔断（tick=300，只能靠 kick）"
grep -q '熔断' "$SD_LOG" 2>/dev/null && ok "熔断已写日志" || ng "熔断未写日志"
kill -TERM "$D9" 2>/dev/null; sleep 1

# 对照：直接改文件、不发信号，300 秒 tick 未到就不该熔断
printf 'temp_mode=static\nshell_temp=30\nsentinel_limit=110\nbattery_limit=48\nwall=42\naggr=10\ntick=300\ndefrev=2\n' >"$SDD/state.conf"
SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/service.sh --daemon >/tmp/d9b.log 2>&1 &
D9B=$!
sleep 3
sed -i 's/^sentinel_limit=110/sentinel_limit=85/' "$SDD/state.conf"
sleep 2
eq "$(grep '^temp_mode=' "$SDD/state.conf")" "temp_mode=static" "未发信号时守护仍在睡（对照）"
kill -USR1 "$D9B" 2>/dev/null
sleep 2
eq "$(grep '^temp_mode=' "$SDD/state.conf")" "temp_mode=off" "USR1 唤醒后立即按新阈值熔断"
kill -TERM "$D9B" 2>/dev/null; sleep 1
printf '46000\n' >/sys/class/thermal/thermal_zone2/temp

echo "===== T10 升级保留配置 ====="
printf 'temp_mode=static\nshell_temp=38\nsentinel_limit=95\nbattery_limit=52\nwall=45\naggr=3\ncurr_max=2500\nfast_cap=70\ncurve_offset=200\nlog_level=4\ntick=20\ndefrev=2\n' >"$SDD/state.conf"
MODPATH=/opt/qc sh -c 'MODPATH=/opt/qc . /opt/qc/customize.sh' >/tmp/install5.log 2>&1
eq "$(grep '^shell_temp=' "$SDD/state.conf")" "shell_temp=38" "升级保留 shell_temp"
eq "$(grep '^aggr=' "$SDD/state.conf")" "aggr=3" "升级保留 aggr"
eq "$(grep '^wall=' "$SDD/state.conf")" "wall=45" "升级保留 wall"
eq "$(grep '^sentinel_limit=' "$SDD/state.conf")" "sentinel_limit=95" "升级保留 sentinel_limit"
eq "$(grep '^battery_limit=' "$SDD/state.conf")" "battery_limit=52" "升级保留 battery_limit"
eq "$(grep '^curr_max=' "$SDD/state.conf")" "curr_max=2500" "升级保留 curr_max"
eq "$(grep '^fast_cap=' "$SDD/state.conf")" "fast_cap=70" "升级保留 fast_cap"
eq "$(grep '^temp_mode=' "$SDD/state.conf")" "temp_mode=static" "升级保留 temp_mode"
eq "$(grep '^curve_offset=' "$SDD/state.conf")" "curve_offset=200" "升级保留 curve_offset"
eq "$(head -1 /opt/qc/files/vendor/etc/charging_0.txt)" "550,3000,4500" "覆盖层按用户 curve_offset 重建"

echo "===== T11 刷新率 ====="
rm -f /tmp/settings.db
MODPATH=/opt/qc sh -c 'MODPATH=/opt/qc . /opt/qc/customize.sh' >/dev/null 2>&1
printf 'peak_refresh_rate=90\n' >/tmp/settings.db
SD_MODDIR=/opt/qc sh /opt/qc/action.sh hz 120 >/tmp/hz.log 2>&1
eq "$?" "0" "hz 120 执行成功"
eq "$(settings get system peak_refresh_rate)" "120" "peak 写入 120"
eq "$(settings get system min_refresh_rate)" "120" "min 写入 120"
eq "$(grep '^hz=' "$SDD/state.conf")" "hz=120" "state 记录 hz=120"
eq "$(grep '^hz_prev_peak=' "$SDD/state.conf")" "hz_prev_peak=90" "备份原值 90"
J=$(SD_NO_DAEMON=1 sh /opt/qc/action.sh json 2>/dev/null)
echo "$J" | grep -q '"hz":"120"' && ok "json hz=120" || ng "json hz 错误"
echo "$J" | grep -q '"hz_now":120' && ok "json hz_now=120" || ng "json hz_now 错误"
SD_MODDIR=/opt/qc sh /opt/qc/action.sh hz 75 >/dev/null 2>&1
eq "$?" "1" "不支持的 75Hz 被拒绝"
eq "$(settings get system peak_refresh_rate)" "120" "拒绝后原值不变"
SD_MODDIR=/opt/qc sh /opt/qc/action.sh hz off >/dev/null 2>&1
eq "$(settings get system peak_refresh_rate)" "90" "关闭后还原到 90"
eq "$(grep '^hz=' "$SDD/state.conf")" "hz=off" "state hz=off"

rm -f /tmp/settings.db
SD_MODDIR=/opt/qc sh /opt/qc/action.sh hz 144 >/dev/null 2>&1
eq "$(grep '^hz_prev_peak=' "$SDD/state.conf")" "hz_prev_peak=" "原值为空时备份为空"
SD_MODDIR=/opt/qc sh /opt/qc/action.sh hz off >/dev/null 2>&1
eq "$(settings get system peak_refresh_rate)" "" "原值为空时关闭即删除"

echo "===== T12 功耗读数 ====="
printf '%s\n' '-1500000' >/sys/class/power_supply/battery/current_now
printf '%s\n' '4200000' >/sys/class/power_supply/battery/voltage_now
printf 'Discharging\n' >/sys/class/power_supply/battery/status
printf '80\n' >/sys/class/power_supply/battery/capacity
printf '380\n' >/sys/class/power_supply/battery/temp
P=$(sh /opt/qc/action.sh power 2>/dev/null)
echo "$P" | grep -q '"ma":-1500' && ok "电流 µA→mA" || ng "电流换算错误: $P"
echo "$P" | grep -q '"mv":4200' && ok "电压 µV→mV" || ng "电压换算错误: $P"
echo "$P" | grep -q '"w":6.30' && ok "功率 6.30W" || ng "功率计算错误: $P"
echo "$P" | grep -q '"temp":38' && ok "温度 380→38℃" || ng "温度换算错误"
echo "$P" | grep -q '"cap":80' && ok "电量 80" || ng "电量错误"
echo "$P" | grep -q '"status":"Discharging"' && ok "状态字段" || ng "状态字段错误"
printf '%s\n' '1200' >/sys/class/power_supply/battery/current_now
printf '%s\n' '4200' >/sys/class/power_supply/battery/voltage_now
P2=$(sh /opt/qc/action.sh power 2>/dev/null)
echo "$P2" | grep -q '"ma":-1200' && ok "mA 单位保留，放电符号归一为负" || ng "mA 单位误判: $P2"
echo "$P2" | grep -q '"w":5.04' && ok "mA×mV 功率 5.04W" || ng "mA 功率错误"
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '%s\n' '-1500000' >/sys/class/power_supply/battery/current_now
printf '%s\n' '4200000' >/sys/class/power_supply/battery/voltage_now

echo "===== T13 模块描述同步 ====="
SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/uninstall.sh >/dev/null 2>&1
sleep 1
MODPATH=/opt/qc sh -c 'MODPATH=/opt/qc . /opt/qc/customize.sh' >/dev/null 2>&1
SD_MODDIR=/opt/qc sh /opt/qc/post-fs-data.sh >/dev/null 2>&1

# 装机默认 temp_mode=off，描述应如实写"关闭"
D=$(sed -n 's/^description=//p' /opt/qc/module.prop)
case "$D" in *"温度伪装关闭"*) ok "默认关闭状态写进描述" ;; *) ng "默认状态不符: $D" ;; esac
case "$D" in *"配置 9 项"*) ok "描述含挂载数" ;; *) ng "描述缺挂载数: $D" ;; esac
eq "$(grep -c '^description=' /opt/qc/module.prop)" "1" "description 只有一行"
eq "$(grep '^version=' /opt/qc/module.prop)" "version=2.4.0" "版本行未被改写"
eq "$(grep '^author=' /opt/qc/module.prop)" "author=https://github.com/XiaohaoQvQ" "作者行未被改写"
eq "$(grep '^id=' /opt/qc/module.prop)" "id=quickcharge" "id 行未被改写"

# 幂等：状态没变时不该再写盘
M1=$(md5sum /opt/qc/module.prop | awk '{print $1}')
MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_sync_desc' >/dev/null 2>&1
M2=$(md5sum /opt/qc/module.prop | awk '{print $1}')
eq "$M2" "$M1" "状态未变时不重写 module.prop"

SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh temp static >/dev/null 2>&1
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh gear 4 >/dev/null 2>&1
D=$(sed -n 's/^description=//p' /opt/qc/module.prop)
case "$D" in *"温控档位 4/10"*) ok "gear 4 同步到描述" ;; *) ng "档位未同步: $D" ;; esac

SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh aggr 9 >/dev/null 2>&1
D=$(sed -n 's/^description=//p' /opt/qc/module.prop)
case "$D" in *"温控档位 9/10"*) ok "旧命令 aggr 仍可用且同步" ;; *) ng "aggr 别名失效: $D" ;; esac

SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hz 120 >/dev/null 2>&1
D=$(sed -n 's/^description=//p' /opt/qc/module.prop)
case "$D" in *"高刷 120Hz"*) ok "高刷状态同步" ;; *) ng "高刷未同步: $D" ;; esac
case "$D" in *"配置 9 项"*) ok "改高刷后挂载数仍在" ;; *) ng "挂载数丢失: $D" ;; esac

SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh temp off >/dev/null 2>&1
D=$(sed -n 's/^description=//p' /opt/qc/module.prop)
case "$D" in *"温度伪装关闭"*) ok "关闭伪装后描述改为温度伪装关闭" ;; *) ng "关闭状态未同步: $D" ;; esac

SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh temp charge >/dev/null 2>&1
D=$(sed -n 's/^description=//p' /opt/qc/module.prop)
case "$D" in *"仅充电"*) ok "仅充电模式有标注" ;; *) ng "仅充电未标注: $D" ;; esac

# 越界命令不写盘：描述应保持上一条
B1=$(md5sum /opt/qc/module.prop | awk '{print $1}')
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh gear 11 >/dev/null 2>&1
B2=$(md5sum /opt/qc/module.prop | awk '{print $1}')
eq "$B2" "$B1" "被拒绝的 gear 11 不改描述"

# 管理器列表会截断长描述，档位必须排在最前面
case "$D" in "QC · 温控档位"*) ok "描述以档位开头，截断时仍可见" ;; *) ng "描述格式异常: $D" ;; esac

echo "===== T14 功耗读取（bcc_parms 双电芯）====="
mkdir -p /sys/class/oplus_chg/battery
: >/sys/class/oplus_chg/battery/bcc_parms

# 双电芯串联：每芯 4.4V、电流 3A → 总压 8.8V、26.40W。
# power_supply 故意只报单芯 4.4V，用来验证确实走了 bcc_parms。
printf '0,0,0,0,0,0,4400,0,3000,0,0,4400,0,0,0,0,0,0,0\n' >/sys/class/oplus_chg/battery/bcc_parms
printf 'Charging\n'       >/sys/class/power_supply/battery/status
printf '4400000\n'        >/sys/class/power_supply/battery/voltage_now
printf '3000000\n'        >/sys/class/power_supply/battery/current_now
printf '370\n'            >/sys/class/power_supply/battery/temp
printf '66\n'             >/sys/class/power_supply/battery/capacity
P=$(SD_NO_DAEMON=1 sh /opt/qc/action.sh power 2>/dev/null)
echo "$P"
echo "$P" | grep -q '"ma":3000'    && ok "bcc 电流原值取用"      || ng "电流错误: $P"
echo "$P" | grep -q '"mv":8800'    && ok "双电芯电压相加 8.8V"   || ng "电压未相加: $P"
echo "$P" | grep -q '"w":26.40'    && ok "功率 26.40W"          || ng "功率错误: $P"
echo "$P" | grep -q '"cells":2'    && ok "标记双电芯"            || ng "cells 错误: $P"
echo "$P" | grep -q '"src":"bcc"'  && ok "数据来源 bcc"          || ng "来源错误: $P"
echo "$P" | grep -q '"temp":37'    && ok "温度仍走 power_supply" || ng "温度错误: $P"

# 单电芯：第二位电压为 0，不该相加
printf '0,0,0,0,0,0,4400,0,3000,0,0,0,0,0,0,0,0,0,0\n' >/sys/class/oplus_chg/battery/bcc_parms
P=$(SD_NO_DAEMON=1 sh /opt/qc/action.sh power 2>/dev/null)
echo "$P" | grep -q '"mv":4400'   && ok "单电芯不相加"  || ng "单芯电压错误: $P"
echo "$P" | grep -q '"w":13.20'   && ok "单芯功率 13.20W" || ng "单芯功率错误: $P"
echo "$P" | grep -q '"cells":1'   && ok "标记单电芯"    || ng "单芯 cells 错误: $P"

# 字段数不对就必须放弃，不能拿错位的索引去算
printf '0,0,0,0,0,0,4400,0,3000,0,0,0,0,0,0,0,0,0\n' >/sys/class/oplus_chg/battery/bcc_parms
P=$(SD_NO_DAEMON=1 sh /opt/qc/action.sh power 2>/dev/null)
echo "$P" | grep -q '"src":"ps"' && ok "字段数不符时退回通用节点" || ng "未退回: $P"
echo "$P" | grep -q '"w":13.20'  && ok "退回后按 µV/µA 换算"      || ng "退回功率错误: $P"

# 第一路电压为 0 → 同样放弃
printf '0,0,0,0,0,0,0,0,3000,0,0,4400,0,0,0,0,0,0,0\n' >/sys/class/oplus_chg/battery/bcc_parms
P=$(SD_NO_DAEMON=1 sh /opt/qc/action.sh power 2>/dev/null)
echo "$P" | grep -q '"src":"ps"' && ok "电压为 0 时退回通用节点" || ng "v0=0 未退回: $P"

# 符号校正：充电状态给负电流，应翻正
printf '0,0,0,0,0,0,4400,0,-3000,0,0,4400,0,0,0,0,0,0,0\n' >/sys/class/oplus_chg/battery/bcc_parms
printf 'Charging\n' >/sys/class/power_supply/battery/status
P=$(SD_NO_DAEMON=1 sh /opt/qc/action.sh power 2>/dev/null)
echo "$P" | grep -q '"ma":3000' && ok "充电时负电流翻正" || ng "符号未校正: $P"

# 放电状态给正电流，应翻负
printf '0,0,0,0,0,0,4400,0,2000,0,0,4400,0,0,0,0,0,0,0\n' >/sys/class/oplus_chg/battery/bcc_parms
printf 'Discharging\n' >/sys/class/power_supply/battery/status
P=$(SD_NO_DAEMON=1 sh /opt/qc/action.sh power 2>/dev/null)
echo "$P" | grep -q '"ma":-2000' && ok "放电时正电流翻负" || ng "放电符号未校正: $P"
echo "$P" | grep -q '"w":17.60' && ok "功率用绝对值 17.60W" || ng "放电功率错误: $P"

# 校准倍率
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh pscale 200 >/dev/null 2>&1
P=$(SD_NO_DAEMON=1 sh /opt/qc/action.sh power 2>/dev/null)
echo "$P" | grep -q '"ma":-4000' && ok "校准 200% 电流翻倍" || ng "校准未生效: $P"
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh pscale 49 >/dev/null 2>&1
eq "$?" "1" "pscale 49 被拒绝"
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh pscale 100 >/dev/null 2>&1

rm -rf /sys/class/oplus_chg
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '%s\n' '-1500000' >/sys/class/power_supply/battery/current_now
printf '%s\n' '4200000' >/sys/class/power_supply/battery/voltage_now
P=$(SD_NO_DAEMON=1 sh /opt/qc/action.sh power 2>/dev/null)
echo "$P" | grep -q '"src":"ps"' && ok "无 bcc 节点时走通用路径" || ng "降级失败: $P"

echo
echo "===== 结果: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
