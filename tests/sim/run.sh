#!/bin/sh
# QC 仿真测试：alpine + tmpfs 伪造 Android 根文件系统

PASS=0; FAIL=0; T0=$(date +%s); FAILED=""

SD_SPOOF_DIR="${SD_SPOOF_DIR:-/tmp/qc-sim-spoof}"
export SD_SPOOF_DIR

# 超长实际值截断：守护日志、整段 JSON 都可能几百字符，一条失败不该刷屏
_short() {
    local v="$1"
    [ -n "$v" ] || { printf '<空>'; return 0; }
    if [ ${#v} -gt 160 ]; then printf '%s…' "$(printf '%s' "$v" | cut -c1-160)"
    else printf '%s' "$v"; fi
}
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$*"; }
ng()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$*"; FAILED="${FAILED}  $*
"; }
eq()  { if [ "$1" = "$2" ]; then ok "$3"; else ng "$3 (want=$(_short "$2") got=$(_short "$1"))"; fi; }
# 子串断言。之前这两个函数只在机型号矩阵里有定义，run.sh 里写了调用却是
# "command not found" —— 不计入 PASS 也不计入 FAIL，静默失效了三条。
has()   { case "$1" in *"$2"*) ok "$3" ;; *) ng "$3 (缺: $2)";; esac; }
hasnt() { case "$1" in *"$2"*) ng "$3 (不该出现: $2)" ;; *) ok "$3" ;; esac; }

# ---------------------------------------------------------------- 轮询等待
# 守护第一次 tick 落在 0~tick 秒之间，固定 sleep 只能按最坏情况取值：
# 要么白等十几秒，要么偶发不够。轮询到条件成立就返回，总耗时从
# "用例数 × 固定秒数"降到"实际生效所需的时间"。
_GAP=0.2
wait_eq() {   # 文件 期望 [超时] 描述
    local f="$1" want="$2" to="${3:-25}" d="$4" i=0 max got=""
    max=$((to * 5))
    while [ "$i" -lt "$max" ]; do
        got=$(cat "$f" 2>/dev/null)
        [ "$got" = "$want" ] && { ok "$d"; return 0; }
        sleep $_GAP; i=$((i + 1))
    done
    ng "$d (want=$(_short "$want") got=$(_short "$got")；等满 ${to}s)"
    return 1
}
wait_grep() { # 文件 模式 [超时] 描述
    local f="$1" pat="$2" to="${3:-25}" d="$4" i=0 max
    max=$((to * 5))
    while [ "$i" -lt "$max" ]; do
        grep -q "$pat" "$f" 2>/dev/null && { ok "$d"; return 0; }
        sleep $_GAP; i=$((i + 1))
    done
    ng "$d（${to}s 内未出现 $pat）"
    return 1
}
wait_hold() { # 文件 模式 持续秒 描述：整段时间内都不能出现
    local f="$1" pat="$2" secs="${3:-10}" d="$4" i=0 max
    max=$((secs * 5))
    while [ "$i" -lt "$max" ]; do
        grep -q "$pat" "$f" 2>/dev/null && { ng "$d（出现了 $pat）"; return 1; }
        sleep $_GAP; i=$((i + 1))
    done
    ok "$d"
    return 0
}
wait_dead() { # pid [超时]：等进程真正退出，替代 kill 后 sleep 1
    local p="$1" to="${2:-5}" i=0 max
    max=$((to * 10))
    while kill -0 "$p" 2>/dev/null && [ "$i" -lt "$max" ]; do sleep 0.1; i=$((i + 1)); done
    return 0
}

# ---------------------------------------------------------------- 重跑清理
# 套件在同一台机器上跑第二遍时，上一遍留下的 bind mount、数据目录与残留
# 守护会让"备份与原件一致"、"开机计数 1"这些用例必挂。先拆干净再开始。
# pkill 的模式要宽：手工联调时装进 /data/adb/modules 的模块也会起守护，
# 和套件共用 /data/adb/quickcharge，抢锁、抢写 run 文件，污染一切。
pkill -f 'service[.]sh --daemon' 2>/dev/null && sleep 1
rm -rf /data/adb/modules/quickcharge /data/adb/modules_update/quickcharge
for _m in $(awk '$2 ~ "^/vendor/etc/" {print $2}' /proc/mounts 2>/dev/null); do
    umount "$_m" 2>/dev/null || umount -l "$_m" 2>/dev/null
done
rm -rf /data/adb/quickcharge /opt/qc

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
  ro.board.platform)               echo "${FAKE_PLAT-}" ;;
  ro.soc.manufacturer)             echo "${FAKE_SOCMFR-Qualcomm}" ;;
  ro.hardware)                     echo "${FAKE_HW-qcom}" ;;
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
    printf '  Mode ID: 4, Resolution: 1264x2780, Refresh Rate: 144.00 Hz\n'
    printf '  Mode ID: 5, Resolution: 1264x2780, Refresh Rate: 165.00 Hz\n'
    printf '  Mode ID: 6, Resolution: 1264x2780, Refresh Rate: 185.00 Hz\n' ;;
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
rm -f /tmp/am.args
MODPATH=/opt/qc sh -c '. /usr/local/bin/ui_print 2>/dev/null; MODPATH=/opt/qc . /opt/qc/customize.sh' >/tmp/install.log 2>&1
eq "$?" "0" "customize.sh 退出码 0"
grep -q "代码由 AI 辅助完成" /tmp/install.log && ok "横幅含 AI 辅助声明" || ng "缺 AI 辅助声明"
grep -q "作者: Xiaohao" /tmp/install.log && ok "安装末尾显示作者" || ng "缺作者提示"
grep -q "QQ群: 点击链接加入群聊" /tmp/install.log && ok "安装末尾显示 QQ 群" || ng "缺 QQ 群提示"
case "$(cat /tmp/install.log)" in *coolapk*) ng "安装输出仍有酷安链接" ;; *) ok "安装输出已无酷安链接" ;; esac
sleep 1
# 链接含 & 与 +，必须整串传给 am；被截断就说明少加了引号
grep -q 'qun.qq.com/universal-share/share?ac=1&authKey=' /tmp/am.args 2>/dev/null && ok "刷写后调用 am 跳转加群页" || ng "未触发加群跳转"
grep -q 'svctype=4&tempid=h5_group_info' /tmp/am.args 2>/dev/null && ok "加群链接完整未被 & 截断" || ng "加群链接被截断"
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
eq "$(grep '^temp_mode=' "$SDD/state.conf")" "temp_mode=charge" "默认仅充电时生效"
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
# 熔断只暂停，不能改用户配置：旧实现会落盘 temp_mode=off，重启后仍是 off，
# 用户看到的就是"模式始终 off、开不起来"。
eq "$(sd_state_get temp_mode off)" "static" "熔断后模式保持不变"
eq "$(sd_state_get shell_temp 0)" "30" "熔断后档位保留"
sd_sentinel_guard; eq "$?" "1" "熔断期间持续暂停"
set_temp 46000
sd_sentinel_guard; eq "$?" "1" "46℃ 未进回差，仍暂停"
set_temp 44000
sd_sentinel_guard; eq "$?" "0" "44℃ 回落后自动解除"
eq "$(sd_state_get temp_mode off)" "static" "解除后仍是用户选定的模式"
_sd_guard_paused=0

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
sd_limit_for_type_v cpu-0-0
eq "$_sd_rv" "85" "sentinel_limit=500 回落 85"

printf 'temp_mode=static\nshell_temp=30\nbattery_limit=48\nsentinel_limit=85\nwall=5\naggr=10\n' >"$SDD/state.conf"
_sd_st_loaded=0; sd_state_load
eq "$(sd_state_int wall 42 35 80)" "42" "wall=5 回落默认 42"

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
printf 'Discharging\n' >/sys/class/power_supply/battery/status
J=$(SD_NO_DAEMON=1 sh /opt/qc/action.sh json 2>/dev/null)
echo "$J" | grep -q '^{.*}$' && ok "json 输出为单行对象" || ng "json 输出格式异常"
echo "$J" | grep -q '"aggr":10' && ok "json aggr=10" || ng "json aggr 错误"
echo "$J" | grep -q '"gap":12' && ok "json gap=12" || ng "json gap 错误"
echo "$J" | grep -q '"mode":"charge"' && ok "json mode=charge" || ng "json mode 错误"
echo "$J" | grep -q '"charging":false' && ok "json charging=false" || ng "json charging 错误"
echo "$J" | grep -q '"mounted":0' && ok "json mounted=0(未挂载)" || ng "json mounted 错误"
echo "$J" | grep -q '"daemon":false' && ok "json daemon=false" || ng "json daemon 错误"
V=$(grep '^version=' /opt/qc/module.prop | cut -d= -f2)
echo "$J" | grep -q "\"version\":\"$V\"" && ok "json 带版本号" || ng "json 缺版本号"
# 仅充电档未插电：不算目标温度，target 保持 0
echo "$J" | grep -q '"target":0' && ok "json 未插电 target=0" || ng "json target 异常"
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
# 熔断不改配置，改为检查"伪装确实被撤掉了"
eq "$(grep '^temp_mode=' "$SDD/state.conf")" "temp_mode=static" "熔断不改 temp_mode（只暂停伪装）"
grep -q '熔断' "$SD_LOG" 2>/dev/null && ok "熔断已写日志" || ng "熔断未写日志"
kill -TERM "$D9" 2>/dev/null; wait_dead "$D9"

# 对照：直接改文件、不发信号，300 秒 tick 未到就不该熔断
printf 'temp_mode=static\nshell_temp=30\nsentinel_limit=110\nbattery_limit=48\nwall=42\naggr=10\ntick=300\ndefrev=2\n' >"$SDD/state.conf"
SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/service.sh --daemon >/tmp/d9b.log 2>&1 &
D9B=$!
sleep 3
sed -i 's/^sentinel_limit=110/sentinel_limit=85/' "$SDD/state.conf"
sleep 2
eq "$(grep '^temp_mode=' "$SDD/state.conf")" "temp_mode=static" "未发信号时守护仍在睡（对照）"
: >"$SD_LOG"
kill -USR1 "$D9B" 2>/dev/null
sleep 2
grep -q '熔断' "$SD_LOG" && ok "USR1 唤醒后立即熔断" || ng "USR1 唤醒后未熔断"
kill -TERM "$D9B" 2>/dev/null; wait_dead "$D9B"
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

# 手动关过（off_manual=1）：升级不能把用户重新打开
printf 'temp_mode=off\nshell_temp=30\nwall=42\naggr=10\noff_manual=1\ndefrev=2\ntick=15\n' >"$SDD/state.conf"
MODPATH=/opt/qc sh -c 'MODPATH=/opt/qc . /opt/qc/customize.sh' >/dev/null 2>&1
eq "$(grep '^temp_mode=' "$SDD/state.conf")" "temp_mode=off" "手动关闭的用户升级后仍保持 off"

# 旧版被熔断写成 off（没有 off_manual 标记）：升级回到默认值
# 这是用户实际遇到的情况——一次过热就永久 off，重装也回不来。
printf 'temp_mode=off\nshell_temp=30\nwall=42\naggr=10\ndefrev=2\ntick=15\n' >"$SDD/state.conf"
MODPATH=/opt/qc sh -c 'MODPATH=/opt/qc . /opt/qc/customize.sh' >/dev/null 2>&1
eq "$(grep '^temp_mode=' "$SDD/state.conf")" "temp_mode=charge" "被熔断改成 off 的升级后自动恢复"
eq "$(grep '^off_manual=' "$SDD/state.conf")" "off_manual=0" "恢复后写入 off_manual=0"

# 手动关闭会留下标记，下次升级不再覆盖
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh temp off >/dev/null 2>&1
eq "$(grep '^off_manual=' "$SDD/state.conf")" "off_manual=1" "手动关闭写入标记"
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh temp charge >/dev/null 2>&1
eq "$(grep '^off_manual=' "$SDD/state.conf")" "off_manual=0" "重新开启清除标记"

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
# WebUI 靠 hz_list 把本机没有的档位灰掉、拖不过去。顺序必须和
# get-supported-modes 一致（按 Hz 升序），否则前端格子和实际档位会错位。
eq "$(echo "$J" | sed -n 's/.*"hz_list":"\([^"]*\)".*/\1/p')"    "60 90 120 144 165 185" "json hz_list 是本机模式表"
# 缓存：第二次不能再拉一次 app_process（json 每秒被拉一次）
rm -f "$SDD/run/hz.list" 2>/dev/null
SD_NO_DAEMON=1 sh /opt/qc/action.sh json >/dev/null 2>&1
[ -s "$SDD/run/hz.list" ] && ok "hz_list 落盘缓存" || ng "hz_list 没缓存"
eq "$(cat "$SDD/run/hz.list" 2>/dev/null)" "60 90 120 144 165 185" "缓存内容完整"
SD_MODDIR=/opt/qc sh /opt/qc/action.sh hz 75 >/dev/null 2>&1
eq "$?" "1" "不支持的 75Hz 被拒绝（不在设备模式表里）"
eq "$(settings get system peak_refresh_rate)" "120" "拒绝后原值不变"
# 165 / 185 是 2025 年机型的主力档，必须能写进去；186 超出范围要拦
SD_MODDIR=/opt/qc sh /opt/qc/action.sh hz 165 >/dev/null 2>&1
eq "$?" "0" "hz 165 执行成功"
eq "$(settings get system peak_refresh_rate)" "165" "peak 写入 165"
SD_MODDIR=/opt/qc sh /opt/qc/action.sh hz 185 >/dev/null 2>&1
eq "$?" "0" "hz 185 执行成功"
eq "$(settings get system peak_refresh_rate)" "185" "peak 写入 185"
eq "$(grep '^hz=' "$SDD/state.conf")" "hz=185" "state 记录 hz=185"
SD_MODDIR=/opt/qc sh /opt/qc/action.sh hz 186 >/dev/null 2>&1
eq "$?" "1" "186 超出范围被拒绝"
eq "$(settings get system peak_refresh_rate)" "185" "拒绝后仍是 185"
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

# 装机默认 temp_mode=charge，描述应如实写"仅充电"
D=$(sed -n 's/^description=//p' /opt/qc/module.prop)
case "$D" in *"仅充电"*) ok "默认仅充电状态写进描述" ;; *) ng "默认状态不符: $D" ;; esac
case "$D" in *"配置 9 项"*) ok "描述含挂载数" ;; *) ng "描述缺挂载数: $D" ;; esac
eq "$(grep -c '^description=' /opt/qc/module.prop)" "1" "description 只有一行"
eq "$(grep '^version=' /opt/qc/module.prop)" "$(grep '^version=' /mod/module.prop)" "版本行未被改写"
eq "$(grep '^author=' /opt/qc/module.prop)" "author=Xiaohao" "作者行未被改写"
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

# 切到「仅充电」时若没插电，已写入的伪装必须立刻撤掉。
# 不能等下一个 tick —— tick 调到 300 秒时就是五分钟的高温伪装。
printf 'Discharging\n' >/sys/class/power_supply/battery/status
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh temp static 30 >/dev/null 2>&1
eq "$(cat /sys/class/thermal/thermal_zone0/emul_temp)" "30000" "static 立即写入伪装"
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh temp charge >/dev/null 2>&1
eq "$(cat /sys/class/thermal/thermal_zone0/emul_temp)" "0" "未插电切仅充电：立即撤掉伪装"
eq "$(SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_state_get temp_mode off')" "charge" "未插电切仅充电：模式已记录"

printf 'Charging\n' >/sys/class/power_supply/battery/status
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh temp static 30 >/dev/null 2>&1
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh temp charge >/dev/null 2>&1
eq "$(cat /sys/class/thermal/thermal_zone0/emul_temp)" "30000" "插电切仅充电：保留伪装"

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

echo "===== T15 全局高刷：稳定性 / 覆盖场景 / 安全边界 ====="

# 升级 settings 桩：区分 system / secure / global 命名空间（真机就是这样），
# 并加两个开关：reject 模拟厂商锁死写入，writes 记录实际尝试写入的次数。
cat >/usr/local/bin/settings <<'EOS'
#!/bin/sh
DB=/tmp/settings.db
ns=$2; k=$3; v=$4
key="$ns/$k"
case "$1" in
  get)
    r=$(grep "^$key=" "$DB" 2>/dev/null | cut -d= -f2-)
    printf '%s\n' "${r:-null}" ;;
  put)
    printf '%s\n' "$key" >>/tmp/settings.writes
    [ -f /tmp/settings.reject ] && exit 0
    grep -v "^$key=" "$DB" 2>/dev/null >"$DB.t"
    printf '%s=%s\n' "$key" "$v" >>"$DB.t"
    mv -f "$DB.t" "$DB" ;;
  delete)
    grep -v "^$key=" "$DB" 2>/dev/null >"$DB.t"; mv -f "$DB.t" "$DB" ;;
  list)
    # 真机 settings list system 输出 key=value；模块用它一次取回 peak+min
    [ "$ns" = "system" ] && sed -n 's|^system/||p' "$DB" ;;
esac
EOS
chmod +x /usr/local/bin/settings

# 清掉 T13 留下的高刷状态，重置成"系统原本 120Hz 智能切换"
sed -i '/^hz=/d;/^hz_hard=/d;/^hz_prev_/d' "$SDD/state.conf" 2>/dev/null
printf 'system/peak_refresh_rate=120\nsystem/min_refresh_rate=60\nsecure/match_content_frame_rate=3\nglobal/low_power=0\n' >/tmp/settings.db
rm -f /tmp/settings.reject /tmp/settings.writes

cat >/tmp/hzenv <<'EOS'
. /opt/qc/lib/qc.sh
EOS

# --- soft 档：只表达偏好
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hz 144 >/dev/null 2>&1
eq "$(settings get system peak_refresh_rate)" "144" "soft: peak 写 144"
eq "$(settings get system min_refresh_rate)" "144" "soft: min 写 144"
eq "$(settings get secure match_content_frame_rate)" "3" "soft: 不碰内容帧率策略"
eq "$(SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_state_get hz_hard 0')" "0" "soft: hz_hard=0"

# --- hard 档：额外的内容帧率锁定
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hz 144 hard >/dev/null 2>&1
eq "$(settings get secure match_content_frame_rate)" "1" "hard: 内容帧率置 NEVER"
eq "$(SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_state_get hz_hard 0')" "1" "hard: hz_hard=1"
eq "$(SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_state_get hz_prev_mcfr')" "3" "hard: 记住原始偏好 3"

# --- 系统把键改回 60：看护必须补写
settings put system peak_refresh_rate 60
settings put system min_refresh_rate 60
R=$(SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_hz_guard; echo $?')
eq "$R" "1" "hard: 检测到改回并补写"
eq "$(settings get system peak_refresh_rate)" "144" "hard: peak 补回 144"
eq "$(settings get system min_refresh_rate)" "144" "hard: min 补回 144"

R=$(SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_hz_guard; echo $?')
eq "$R" "0" "hard: 键值正确时零写入"

# --- 省电模式：投票优先级高于用户设置，主动退让
settings put global low_power 1
settings put system peak_refresh_rate 60
R=$(SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_hz_guard; echo $?')
eq "$R" "3" "省电模式: 返回 3 并退让"
eq "$(settings get system peak_refresh_rate)" "60" "省电模式: 不与系统抢写"
settings put global low_power 0

# --- 厂商锁死写入：连续失败后必须停手，不能每 tick 打一次架
settings put system peak_refresh_rate 60
rm -f /tmp/settings.writes
touch /tmp/settings.reject
R=$(SD_MODDIR=/opt/qc sh -c '
    . /opt/qc/lib/qc.sh
    sd_hz_guard; a=$?
    sd_hz_guard; b=$?
    sd_hz_guard; c=$?
    sd_hz_guard; d=$?
    echo "$a$b$c$d"')
eq "$R" "2222" "写不进去: 始终报 2"
eq "$(grep -c 'system/peak_refresh_rate' /tmp/settings.writes)" "3" "写不进去: 第 4 次起停止写入"
rm -f /tmp/settings.reject

# --- 状态文本
settings put system peak_refresh_rate 144
settings put system min_refresh_rate 144
eq "$(SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_hz_state_text')" "ok" "状态: ok"
settings put system peak_refresh_rate 60
eq "$(SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_hz_state_text')" "drift" "状态: drift"
settings put system peak_refresh_rate 144
settings put global low_power 1
eq "$(SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_hz_state_text')" "low_power" "状态: low_power"
settings put global low_power 0

# --- JSON 契约
J=$(SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh json)
echo "$J" | grep -q '"hz":"144"'        && ok "JSON: hz=144"       || ng "JSON hz: $J"
echo "$J" | grep -q '"hz_hard":1'       && ok "JSON: hz_hard=1"    || ng "JSON hz_hard: $J"
echo "$J" | grep -q '"hz_state":"ok"'   && ok "JSON: hz_state=ok"  || ng "JSON hz_state: $J"

# --- 描述
D=$(sed -n 's/^description=//p' /opt/qc/module.prop)
case "$D" in *"高刷 144Hz 锁定"*) ok "描述标注「锁定」" ;; *) ng "描述缺锁定: $D" ;; esac

# --- 关闭强制锁定：档位保留，内容帧率交还系统
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hzguard off >/dev/null 2>&1
eq "$(settings get secure match_content_frame_rate)" "3" "关闭锁定: 内容帧率还原 3"
eq "$(settings get system peak_refresh_rate)" "144" "关闭锁定: 档位仍是 144Hz"
D=$(sed -n 's/^description=//p' /opt/qc/module.prop)
case "$D" in *"锁定"*) ng "关闭锁定后描述仍写锁定" ;; *) ok "关闭锁定后描述不再写锁定" ;; esac

# --- 完全关闭：逐键还原
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hz off >/dev/null 2>&1
eq "$(settings get system peak_refresh_rate)" "120" "关闭: peak 还原 120"
eq "$(settings get system min_refresh_rate)" "60" "关闭: min 还原 60"
eq "$(settings get secure match_content_frame_rate)" "3" "关闭: 内容帧率还原 3"
eq "$(SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_state_get hz off')" "off" "关闭: 状态 off"

# --- 原本没有该键：关闭必须是 delete，不能留下 "null" 字符串
printf 'global/low_power=0\n' >/tmp/settings.db
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hz 120 >/dev/null 2>&1
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hz off >/dev/null 2>&1
eq "$(settings get system peak_refresh_rate)" "null" "原值为空: 关闭后回到 null"

# --- 写失败必须回滚，不留"显示已开、实际没开"的半套状态
printf 'system/peak_refresh_rate=120\nsystem/min_refresh_rate=60\nglobal/low_power=0\n' >/tmp/settings.db
touch /tmp/settings.reject
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hz 144 >/tmp/hzset.log 2>&1
eq "$?" "1" "写失败: 退出码 1"
grep -q "写入失败" /tmp/hzset.log && ok "写失败: 有明确提示" || ng "写失败: 无提示"
eq "$(SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_state_get hz off')" "off" "写失败: 状态未开启"
rm -f /tmp/settings.reject

# --- 非法档位
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hz 30 >/dev/null 2>&1
eq "$?" "1" "30Hz 被拒绝"
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hz 200 >/dev/null 2>&1
eq "$?" "1" "200Hz 被拒绝"
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hz abc >/dev/null 2>&1
eq "$?" "1" "非数字被拒绝"

# --- 重启后 hard 档要连内容帧率一起补
printf 'system/peak_refresh_rate=60\nsystem/min_refresh_rate=60\nsecure/match_content_frame_rate=2\nglobal/low_power=0\n' >/tmp/settings.db
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hz 144 hard >/dev/null 2>&1
settings put system peak_refresh_rate 60
settings put secure match_content_frame_rate 2
SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_hz_boot'
eq "$(settings get system peak_refresh_rate)" "144" "开机: peak 补写"
eq "$(settings get secure match_content_frame_rate)" "1" "开机: 内容帧率策略补写"

# --- soft 档守护零干预
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hzguard off >/dev/null 2>&1
settings put system peak_refresh_rate 60
R=$(SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_hz_guard; echo $?')
eq "$R" "0" "soft: 守护不干预"
eq "$(settings get system peak_refresh_rate)" "60" "soft: 保留系统选择"

echo "===== T16 仅充电模式：守护级验证 ====="

# 这个模式的每 tick 实现曾在 2.6.3 重构时被整段删掉，但 service.sh 仍在调
# sd_charge_tick —— 结果是每 tick 报 not found，「仅充电」完全不生效。
# 这里直接跑真守护，不调函数，防的是同一种回归。

: >/sys/class/thermal/thermal_zone0/emul_temp
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '50\n'       >/sys/class/power_supply/battery/capacity
printf '38000\n'    >/sys/class/thermal/thermal_zone1/temp
printf '40000\n'    >/sys/class/thermal/thermal_zone2/temp
printf 'temp_mode=charge\nshell_temp=28\nfast_cap=55\nwall=off\naggr=10\ntick=5\nbattery_limit=48\nsentinel_limit=85\ndefrev=3\n' >"$SDD/state.conf"
SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/service.sh --daemon >/tmp/d16.log 2>&1 &
D16=$!
wait_eq "/sys/class/thermal/thermal_zone0/emul_temp" "28000" 4 "仅充电+插电：写入伪装"
grep -q 'sd_charge_tick: not found' /tmp/d16.log && ng "守护调用 sd_charge_tick 失败" || ok "守护无 not found"

# 拔电：下一 tick 必须归零，交回系统真实读数
printf 'Discharging\n' >/sys/class/power_supply/battery/status
# charge 档内部固定 10 秒一轮，不受 tick 影响；超时按这个周期给足，
# 不能按"守护 tick=5"拍脑袋，否则偶发挂在启动相位上。
wait_eq "/sys/class/thermal/thermal_zone0/emul_temp" "0" 14 "仅充电+拔电：还原真实读数"

# 重新插电：伪装恢复（charge 档内部 10 秒一轮，等待要够两个周期）
printf 'Charging\n' >/sys/class/power_supply/battery/status
wait_eq "/sys/class/thermal/thermal_zone0/emul_temp" "28000" 14 "仅充电+重新插电：恢复伪装"

# 电量过 fast_cap：进恒压段，不再伪装
printf '60\n' >/sys/class/power_supply/battery/capacity
wait_eq "/sys/class/thermal/thermal_zone0/emul_temp" "0" 14 "仅充电+电量过阈值：停止伪装"
kill -TERM "$D16" 2>/dev/null; wait_dead "$D16"

# 全局方案：拔电也继续伪装（与仅充电的差别就在这一条）
: >/sys/class/thermal/thermal_zone0/emul_temp
printf 'temp_mode=static\nshell_temp=28\nfast_cap=55\nwall=off\naggr=10\ntick=5\nbattery_limit=48\nsentinel_limit=85\ndefrev=3\n' >"$SDD/state.conf"
printf 'Discharging\n' >/sys/class/power_supply/battery/status
SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/service.sh --daemon >/tmp/d16b.log 2>&1 &
D16B=$!
wait_eq "/sys/class/thermal/thermal_zone0/emul_temp" "28000" 4 "全局运行+拔电：仍伪装"
kill -TERM "$D16B" 2>/dev/null; wait_dead "$D16B"

# 关闭再开启不能丢壳温档位（原来 off 会把 shell_temp 清零，再开回落 30℃）
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh temp static 38 >/dev/null 2>&1
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh temp off >/dev/null 2>&1
eq "$(SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_state_get shell_temp')" "38" "关闭后保留壳温档位"
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh temp static >/dev/null 2>&1
eq "$(cat /sys/class/thermal/thermal_zone0/emul_temp)" "38000" "重新开启用回 38℃"

# 开机恢复：charge 档在位时不能等第一个 tick（tick=30，3 秒内不可能轮到）。
# 必须走无参启动：--daemon 会直接进循环，跳过 sd_apply_state。
: >/sys/class/thermal/thermal_zone0/emul_temp
printf 'temp_mode=charge\nshell_temp=28\nfast_cap=55\nwall=off\naggr=10\ntick=30\nbattery_limit=48\nsentinel_limit=85\ndefrev=3\n' >"$SDD/state.conf"
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '50\n'     >/sys/class/power_supply/battery/capacity
SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/service.sh >/tmp/d16c.log 2>&1 &
wait_eq "/sys/class/thermal/thermal_zone0/emul_temp" "28000" 3 "开机即伪装：不等 tick"
[ -f "$SDD/run/daemon.pid" ] && kill -TERM "$(cat "$SDD/run/daemon.pid")" 2>/dev/null
sleep 1

# tick 很大时，仅充电档也必须尽快感知拔电（内部周期固定 10 秒，不受 tick 拖累）
: >/sys/class/thermal/thermal_zone0/emul_temp
printf 'temp_mode=charge\nshell_temp=28\nfast_cap=55\nwall=off\naggr=10\ntick=60\nbattery_limit=48\nsentinel_limit=85\ndefrev=3\n' >"$SDD/state.conf"
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '50\n'       >/sys/class/power_supply/battery/capacity
SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/service.sh --daemon >/tmp/d16d.log 2>&1 &
D16D=$!
wait_eq "/sys/class/thermal/thermal_zone0/emul_temp" "28000" 4 "tick=60 插电仍伪装"
printf 'Discharging\n' >/sys/class/power_supply/battery/status
wait_eq "/sys/class/thermal/thermal_zone0/emul_temp" "0" 12 "tick=60 拔电 12 秒内还原"
kill -TERM "$D16D" 2>/dev/null; wait_dead "$D16D"

# ============================================================ T17 真实温度与限流
echo
echo "===== T17 传感器容错 / 限流落盘 ====="
printf 'battery\n' >/sys/class/thermal/thermal_zone1/type
printf '46000\n'   >/sys/class/thermal/thermal_zone1/temp
printf 'xo-therm\n' >/sys/class/thermal/thermal_zone2/type
printf '45000\n'   >/sys/class/thermal/thermal_zone2/temp
printf 'temp_mode=charge\nwall=42\naggr=10\ncurr_max=0\ndefrev=3\n' >"$SDD/state.conf"

# 小数温度：部分平台 temp 写成 45.000，按整数校验会整条读不到
printf '47.000\n' >/sys/class/thermal/thermal_zone1/temp
eq "$(SD_MODDIR=/opt/qc sh /opt/qc/action.sh json | sed 's/.*"real":\([^,]*\).*/\1/')" "47" "小数温度被正确解析"

# 电池温区读不到时，必须换一个可用来源，而不是返回空。
# 顺序是电池温区 → 电量计 → 其余温区：电量计本身就在测电池，比板温准，
# 所以这里先落到 battery(ps)。
rm -f /sys/class/thermal/thermal_zone1/temp
J=$(SD_MODDIR=/opt/qc sh /opt/qc/action.sh json)
eq "$(printf '%s' "$J" | sed 's/.*"sentinel":"\([^"]*\)".*/\1/')" "battery(ps)" "坏温区被跳过（先接电量计）"
eq "$(printf '%s' "$J" | sed 's/.*"real":\([^,]*\).*/\1/')" "37" "坏温区改用可读来源的读数"
# 电量计也读不到时，才轮到备用温区
mv /sys/class/power_supply/battery/temp /tmp/batt.temp.bak
J=$(SD_MODDIR=/opt/qc sh /opt/qc/action.sh json)
eq "$(printf '%s' "$J" | sed 's/.*"sentinel":"\([^"]*\)".*/\1/')" "thermal_zone2" "电量计也没有时退到备用温区"
eq "$(printf '%s' "$J" | sed 's/.*"real":\([^,]*\).*/\1/')" "45" "备用温区读数 45℃"
mv /tmp/batt.temp.bak /sys/class/power_supply/battery/temp
printf '46000\n' >/sys/class/thermal/thermal_zone1/temp

# 限流：µA 节点写 µA，mA 节点写 mA，不能差一个数量级
mkdir -p /sys/class/power_supply/battery
printf '30000\n'   >/sys/class/thermal/thermal_zone1/temp
printf '6000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '50\n'       >/sys/class/power_supply/battery/capacity
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh curr 2000 >/tmp/t17a.log 2>&1
eq "$(cat /sys/class/power_supply/battery/constant_charge_current_max)" "2000000" "µA 节点写入 µA"

mkdir -p /sys/devices/virtual/oplus_chg/battery
printf '6000\n' >/sys/devices/virtual/oplus_chg/battery/chg_current_max
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh curr 1500 >/tmp/t17b.log 2>&1
eq "$(cat /sys/devices/virtual/oplus_chg/battery/chg_current_max)" "1500" "mA 节点写入 mA"

# 高温按档位降流：46℃ 已过 42℃ 墙 → 只放行 25%
printf '46000\n'   >/sys/class/thermal/thermal_zone1/temp
printf '6000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh curr 2000 >/tmp/t17d.log 2>&1
eq "$(cat /sys/class/power_supply/battery/constant_charge_current_max)" "500000" "高温按 25% 降流"
printf '30000\n' >/sys/class/thermal/thermal_zone1/temp

# 未插电时只记录，不写节点
printf 'Discharging\n' >/sys/class/power_supply/battery/status
printf '6000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh curr 3000 >/tmp/t17c.log 2>&1
eq "$(cat /sys/class/power_supply/battery/constant_charge_current_max)" "6000000" "未插电不动节点"
grep -q "接上充电器后生效" /tmp/t17c.log && ok "未插电给出提示" || ng "未插电没有提示"

# 守护复查：系统把上限抬回去时压回
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '6000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
MODDIR=/opt/qc SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_state_set curr_max 2000; _sd_st_loaded=0; sd_state_load; sd_curr_keep'
eq "$(cat /sys/class/power_supply/battery/constant_charge_current_max)" "2000000" "守护把抬高的上限压回"

printf 'temp_mode=charge\ncurr_max=0\nwall=42\naggr=10\ndefrev=3\n' >"$SDD/state.conf"
printf 'Discharging\n' >/sys/class/power_supply/battery/status

# ============================================================ T18 NoMount 适配
echo
echo "===== T18 NoMount 注入 / 零挂载 ====="

NMD=/data/adb/modules/meta-nomount
mkdir -p "$NMD/bin/arm64-v8a"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>/tmp/nm.calls\nexit 0\n' >"$NMD/bin/arm64-v8a/nomount"
chmod +x "$NMD/bin/arm64-v8a/nomount"
rm -f /tmp/nm.calls

# 干净重装：customize 阶段就应该把镜像写进模块目录，开机不用再 reload
rm -rf "$SDD" /opt/qc
cp -a /mod /opt/qc && chmod +x /opt/qc/*.sh
MODPATH=/opt/qc sh -c 'MODPATH=/opt/qc . /opt/qc/customize.sh' >/tmp/t18inst.log 2>&1
eq "$?" "0" "NoMount 环境下安装成功"
eq "$(find /opt/qc/system -type f 2>/dev/null | wc -l | tr -d ' ')" "9" "安装即生成 9 个注入文件"
eq "$(wc -l <"$SDD/nm.list" 2>/dev/null | tr -d ' ')" "9" "注入清单 9 行"
grep -q "无挂载" /tmp/t18inst.log && ok "安装日志说明无挂载" || ng "安装日志未说明无挂载"
eq "$(find /opt/qc/system -name "*.xml" | wc -l | tr -d " ")" "5" "注入路径结构与系统一致"

# 简介：NoMount 下 mounts.list 恒空，必须按注入数算，否则管理器里永远写"未挂载"
grep -q '配置 9 项' /opt/qc/module.prop && ok "简介显示配置 9 项" || ng "简介未按注入数显示"
grep -q '未挂载' /opt/qc/module.prop && ng "简介仍写未挂载" || ok "简介不再写未挂载"

# post-fs-data：走注入，一条 bind mount 都不产生
SD_MODDIR=/opt/qc sh /opt/qc/post-fs-data.sh >/tmp/t18pfd.log 2>&1
eq "$(wc -l <"$SDD/mounts.list" 2>/dev/null | tr -d ' ')" "0" "开机零挂载（mounts.list 为空）"
[ -f /tmp/nm.calls ] && ng "文件集合没变却触发了 reload" || ok "集合未变不 reload"

# 内容变更：必须原地覆盖（inode 不变），否则内核 rule 失效且要重扫
INO1=$(stat -c %i /opt/qc/system/vendor/etc/thermallevel_to_fps.xml 2>/dev/null)
printf '<x/>' >>/opt/qc/files/vendor/etc/thermallevel_to_fps.xml
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh mount >/tmp/t18m1.log 2>&1
INO2=$(stat -c %i /opt/qc/system/vendor/etc/thermallevel_to_fps.xml 2>/dev/null)
eq "$INO2" "$INO1" "内容更新保持 inode"
grep -q '<x/>' /opt/qc/system/vendor/etc/thermallevel_to_fps.xml && ok "新内容已同步" || ng "新内容未同步"
[ -f /tmp/nm.calls ] && ng "仅内容变化就 reload 了" || ok "仅内容变化不 reload"

# 删掉一个覆盖文件：镜像要跟着删，并且必须 reload 一次
rm -f /opt/qc/files/vendor/etc/horae_0.conf
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh mount >/tmp/t18m2.log 2>&1
[ -f /opt/qc/system/vendor/etc/horae_0.conf ] && ng "多余注入文件没删" || ok "多余注入文件已删"
grep -q "reload" /tmp/nm.calls 2>/dev/null && ok "集合变化触发 reload" || ng "集合变化未 reload"
eq "$(wc -l <"$SDD/nm.list" 2>/dev/null | tr -d ' ')" "8" "清单同步为 8 行"

# json 暴露生效方式，面板靠它区分"没挂"和"用注入代替挂载"
J=$(SD_MODDIR=/opt/qc sh /opt/qc/action.sh json)
printf '%s' "$J" | grep -q '"mount_mode":"nomount"' && ok "json 标注 nomount" || ng "json 未标注 nomount"
printf '%s' "$J" | grep -q '"nm_files":8' && ok "json 注入文件数正确" || ng "json 注入文件数错误"

# 彻底撤下：system 镜像清空，再 reload
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh umount >/tmp/t18um.log 2>&1
eq "$(find /opt/qc/system -type f 2>/dev/null | wc -l | tr -d ' ')" "0" "purge 清空镜像"
eq "$(wc -l <"$SDD/nm.list" 2>/dev/null | tr -d ' ')" "0" "purge 清空清单"

# NoMount 被禁用时不能走注入，要回到 bind
printf '' >"$NMD/disable"
rm -f /tmp/nm.calls
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh mount >/tmp/t18m3.log 2>&1
SD_MODDIR=/opt/qc sh /opt/qc/action.sh json | grep -q '"mount_mode":"bind"' && ok "NoMount 禁用后回到 bind" || ng "NoMount 禁用后仍走注入"
rm -f "$NMD/disable"
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh umount >/dev/null 2>&1
rm -rf "$NMD"

# ============================================================ T19 守护可观测性
echo
echo "===== T19 心跳 / 读数缓存 / 无参数入口 ====="

# 无参数必须直接出状态。KernelSU 的执行环境没有 tty，进菜单只会卡住，
# 用户看到的就是"执行了但只有一堆选择:"。
printf 'temp_mode=static\nshell_temp=30\nwall=off\naggr=10\ntick=5\ndefrev=3\n' >"$SDD/state.conf"
OUT=$(SD_DATA=$SDD SD_MODDIR=/opt/qc timeout 10 sh /opt/qc/action.sh </dev/null 2>&1)
printf '%s' "$OUT" | grep -q '模式' && ok "无参数直接打印状态" || ng "无参数没打印状态"
printf '%s' "$OUT" | grep -q '选择:' && ng "无参数仍进交互菜单" || ok "无参数不进菜单"
printf '%s' "$OUT" | grep -q 'WebUI' && ok "提示改用 WebUI" || ng "没有提示 WebUI"

# 心跳 + 读数缓存：页面要靠它们判断"守护活着"并显示真实温度
printf '38000\n' >/sys/class/thermal/thermal_zone1/temp
rm -f "$SDD/run/hb" "$SDD/run/sensor"
SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/service.sh --daemon >/tmp/d19.log 2>&1 &
D19=$!
_i=0
while [ "$_i" -lt 50 ]; do
    [ -s "$SDD/run/hb" ] && [ -s "$SDD/run/sensor" ] && break
    sleep 0.2; _i=$((_i + 1))
done
[ -s "$SDD/run/hb" ] && ok "守护写心跳" || ng "没有心跳文件"
[ -s "$SDD/run/sensor" ] && ok "守护写读数缓存" || ng "没有读数缓存"

J=$(SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/action.sh json)
printf '%s' "$J" | grep -q '"real_src":"cache"' && ok "json 优先用缓存" || ng "json 没用缓存"
printf '%s' "$J" | grep -q '"daemon":true' && ok "json 认定守护在跑" || ng "json 没认出守护"
printf '%s' "$J" | grep -q '"daemon_age":[0-9-]' && ok "json 给出心跳年龄" || ng "json 缺心跳年龄"
printf '%s' "$J" | grep -q '"real":38' && ok "缓存里是守护读到的真实温度" || ng "缓存温度不对"

# 缓存过期后必须回退现场读，不能拿旧值冒充"现在"。
# 用"当前 uptime - 400 秒"构造，不能写 0：机器刚开机时 uptime 本身就小于
# 阈值，0 会被当成刚写过，测试自己骗自己。
UP=$(cut -d. -f1 /proc/uptime)
printf '%s 0 0 - 0 off\n' "$((UP - 400))" >"$SDD/run/sensor"
J=$(SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/action.sh json)
printf '%s' "$J" | grep -q '"real_src":"live"' && ok "缓存过期回退现场读" || ng "过期缓存仍被采用"
kill -TERM "$D19" 2>/dev/null; wait_dead "$D19"

# 拉起方式：必须真的脱离会话，否则脚本一退出就被管理器收走
rm -f "$SDD/run/daemon.pid" "$SDD/run/hb"
SD_DATA=$SDD SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_daemon_launch; echo rc=$?' >/tmp/d19b.log 2>&1
grep -q 'rc=0' /tmp/d19b.log && ok "sd_daemon_launch 起得来" || ng "sd_daemon_launch 失败"
J=$(SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/action.sh json)
printf '%s' "$J" | grep -q '"daemon":true' && ok "launch 后守护在跑" || ng "launch 后守护不在"
SD_DATA=$SDD SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_daemon_stop'
sleep 1
J=$(SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/action.sh json)
printf '%s' "$J" | grep -q '"daemon":false' && ok "停止后状态同步" || ng "停止后仍报在跑"

printf 'temp_mode=static\ncurr_max=0\nwall=off\naggr=10\ndefrev=3\n' >"$SDD/state.conf"

# ============================================================ T21 电流墙跨模式
echo
echo "===== T21 电流墙：static / off 模式下充电也要维持 ====="

# 电流墙原先只在 charge 模式的 tick 里被执行；static / off 下充电时
# 没有任何进程压电流，面板却显示"已生效"。
mkdir -p /sys/class/power_supply/battery
printf 'battery\n' >/sys/class/thermal/thermal_zone1/type
printf '30000\n'  >/sys/class/thermal/thermal_zone1/temp
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '50\n'       >/sys/class/power_supply/battery/capacity
printf 'temp_mode=static\nshell_temp=30\nwall=42\naggr=10\ntick=5\ncurr_max=2000\ndefrev=3\nbattery_limit=48\nsentinel_limit=85\n' >"$SDD/state.conf"
printf '6000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/service.sh --daemon >/tmp/d21a.log 2>&1 &
D21A=$!
wait_eq "/sys/class/power_supply/battery/constant_charge_current_max" "2000000" 7 "static 模式充电：守护压回电流墙"
kill -TERM "$D21A" 2>/dev/null; wait_dead "$D21A"

printf 'temp_mode=off\nwall=42\naggr=10\ntick=5\ncurr_max=2000\ndefrev=3\nbattery_limit=48\nsentinel_limit=85\n' >"$SDD/state.conf"
printf '6000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/service.sh --daemon >/tmp/d21b.log 2>&1 &
D21B=$!
wait_eq "/sys/class/power_supply/battery/constant_charge_current_max" "2000000" 7 "off 模式充电：守护压回电流墙"
kill -TERM "$D21B" 2>/dev/null; wait_dead "$D21B"

# 未插电时不写节点（限流是天花板，不充电时没必要动）
printf 'temp_mode=off\ntick=5\ncurr_max=3000\ndefrev=3\nbattery_limit=48\nsentinel_limit=85\n' >"$SDD/state.conf"
printf 'Discharging\n' >/sys/class/power_supply/battery/status
printf '6000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/service.sh --daemon >/tmp/d21c.log 2>&1 &
D21C=$!
wait_eq "/sys/class/power_supply/battery/constant_charge_current_max" "6000000" 7 "off 模式未插电：不动节点"
kill -TERM "$D21C" 2>/dev/null; wait_dead "$D21C"

# ============================================================ T22 熔断暂停期可观测
echo
echo "===== T22 熔断暂停期：心跳与读数不能断 ====="

# 暂停分支原先直接 continue，跳过了 hb / sensor 落盘。过热恰恰是最需要
# 观察的几分钟，缓存过期后面板"真实"变 —、心跳年龄无限增长像守护死了。
printf 'temp_mode=static\nshell_temp=30\nwall=off\naggr=10\ntick=5\ncurr_max=0\ndefrev=3\nbattery_limit=48\nsentinel_limit=85\n' >"$SDD/state.conf"
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '30000\n'  >/sys/class/thermal/thermal_zone1/temp
: >/sys/class/thermal/thermal_zone0/emul_temp
rm -f "$SDD/run/hb" "$SDD/run/sensor"
SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/service.sh --daemon >/tmp/d22a.log 2>&1 &
D22A=$!
wait_eq "/sys/class/thermal/thermal_zone0/emul_temp" "30000" 6 "常温下正常伪装"
# 推到电池熔断线以上 → 进入暂停分支（tick=5，等两轮确保已判定）
printf '49000\n' >/sys/class/thermal/thermal_zone1/temp
wait_grep "$SDD/log.txt" "熔断" 15 "过热触发熔断"
# 暂停期第二个 tick：hb 与 sensor 必须仍在更新。
# hb 内容是 "uptime pid"，部分容器的 /proc/uptime 不支持 read(2)（恒读 0），
# 内容比对会失真，用 mtime 判定更可靠。
HB1=$(stat -c %Y "$SDD/run/hb" 2>/dev/null)
SN1=$(cat "$SDD/run/sensor" 2>/dev/null)
# 等心跳真的翻过一次，而不是死等 6 秒：tick=5 时两者等价，tick 调大也不会假通过
_i=0
while [ "$_i" -lt 60 ]; do
    HB2=$(stat -c %Y "$SDD/run/hb" 2>/dev/null)
    [ -n "$HB2" ] && [ "$HB2" != "$HB1" ] && break
    sleep 0.2; _i=$((_i + 1))
done
HB2=$(stat -c %Y "$SDD/run/hb" 2>/dev/null)
[ -n "$HB1" ] && [ "$HB1" != "$HB2" ] && ok "暂停期心跳仍在更新" || ng "暂停期心跳停写"
# 心跳与读数缓存是两次 write，不是原子操作：心跳 mtime 变了、sensor 还是
# 上一轮的情况真实存在（本轮偶发读到 "… 30 static 1" 的旧行）。再等读数
# 自己落盘，别把两个文件当成同一瞬间写完的。
_i=0
while [ "$_i" -lt 40 ]; do
    SN2=$(cat "$SDD/run/sensor" 2>/dev/null)
    case "$SN2" in *"49 48 thermal_zone1 0"*) break ;; esac
    sleep 0.2; _i=$((_i + 1))
done
SN2=$(cat "$SDD/run/sensor" 2>/dev/null)
case "$SN2" in
  *"49 48 thermal_zone1 0"*) ok "暂停期读数照常落盘（真实49 上限48 上报0）" ;;
  *) ng "暂停期读数异常: $SN2" ;;
esac
J=$(SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/action.sh json)
printf '%s' "$J" | grep -q '"real":49' && ok "暂停期面板仍能看到真实温度" || ng "暂停期面板读不到温度"
printf '%s' "$J" | grep -q '"real_src":"cache"' && ok "暂停期读数走缓存" || ng "暂停期缓存未命中"
# 回落 3℃ 后自动恢复（等两轮）
printf '40000\n' >/sys/class/thermal/thermal_zone1/temp
wait_eq "/sys/class/thermal/thermal_zone0/emul_temp" "30000" 7 "温度回落后自动恢复伪装"
kill -TERM "$D22A" 2>/dev/null; wait_dead "$D22A"

# ============================================================ T23 卸载还原系统设置
echo
echo "===== T23 卸载：刷新率锁定 / horae 必须还原 ====="

# 高刷锁定写的是持久键（peak/min_refresh_rate、secure 的内容帧率匹配），
# 卸载脚本删掉 state.conf 前必须先还原，否则系统永远锁在最后一档。
# T15 起的桩按命名空间存键（system/xxx），get 缺键返回 null（同真机）。
rm -f /tmp/settings.db
printf 'system/peak_refresh_rate=60\nsystem/min_refresh_rate=60\nsecure/match_content_frame_rate=3\n' >/tmp/settings.db
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hz 120 >/dev/null 2>&1
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh hzguard on >/dev/null 2>&1
SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh horae 0 >/dev/null 2>&1
eq "$(settings get system peak_refresh_rate)" "120" "锁定已写入 120"
eq "$(settings get secure match_content_frame_rate)" "1" "内容帧率匹配已锁 1"
SD_DATA=$SDD sh /opt/qc/uninstall.sh >/dev/null 2>&1
eq "$(settings get system peak_refresh_rate)" "60" "卸载还原 peak_refresh_rate"
eq "$(settings get system min_refresh_rate)" "60" "卸载还原 min_refresh_rate"
eq "$(settings get secure match_content_frame_rate)" "3" "卸载还原内容帧率匹配"
[ -d "$SDD" ] && ng "数据目录残留(T23)" || ok "数据目录已删除(T23)"
# ============================================================ T24 基准与墙打架
echo
echo "===== T24 基准 ≥ 温度墙：必须收敛，不能静默失效 ====="
# T23 把数据目录删了，先建回来，否则下面的 state.conf 重定向会失败
mkdir -p "$SDD"

# 基准 45 + 墙 42 是很容易拖出来的组合：目标算成 45，又被"不伪造更高温度"
# 钳回真实值，结果全程不改写，面板永远显示"未改写"。运行时要收敛。
printf 'temp_mode=static\nshell_temp=45\nwall=42\naggr=10\nbattery_limit=48\nsentinel_limit=85\n' >"$SDD/state.conf"
printf '41000\n' >/sys/class/thermal/thermal_zone1/temp
J=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh json)
printf '%s' "$J" | grep -q '"base_clamped":true' && ok "基准高于墙时标记 base_clamped" || ng "未标记 base_clamped: $J"
printf '%s' "$J" | grep -q '"shell_temp":40' && ok "生效基准收敛到墙下 2℃" || ng "生效基准未收敛: $J"
printf '%s' "$J" | grep -q '"shell_set":45' && ok "保留用户原值供面板解释" || ng "原值丢失: $J"

# 设墙时顺手把基准压下来，state 保持自洽，不留矛盾配置
printf 'temp_mode=static\nshell_temp=45\nwall=off\naggr=10\n' >"$SDD/state.conf"
SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh wall 42 >/dev/null 2>&1
eq "$(SD_DATA=$SDD SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_state_int shell_temp 30 25 60')" "40" "设墙后基准自动降到 40"

# 基准低于墙时才是正常改写区间
printf 'temp_mode=static\nshell_temp=30\nwall=42\naggr=10\nbattery_limit=48\nsentinel_limit=85\n' >"$SDD/state.conf"
printf '36000\n' >/sys/class/thermal/thermal_zone1/temp
J=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh json)
printf '%s' "$J" | grep -q '"target":30' && ok "基准 30 时正常压到 30" || ng "基准 30 未生效: $J"
printf '%s' "$J" | grep -q '"base_clamped":false' && ok "正常配置不误报" || ng "正常配置被误报: $J"

# T20 要往 state.conf 写，先补回目录
mkdir -p "$SDD/run"

# ============================================================ T20 简介同步
echo
echo "===== T20 覆盖安装后简介恢复 ====="

printf 'temp_mode=charge\naggr=10\nhz=off\ncurr_max=0\ndefrev=3\n' >"$SDD/state.conf"
mkdir -p "$SDD/run"
rm -f "$SDD/run/desc.last"
# 出厂状态：module.prop 是安装包里的原始文案，从未同步过
cp /mod/module.prop /opt/qc/module.prop
MODDIR=/opt/qc SD_DATA=$SDD sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_sync_desc'
grep -q '温控档位 10/10' /opt/qc/module.prop && ok "首次同步写入实际状态" || ng "首次同步没写"
grep -q '欧加真温控' /opt/qc/module.prop && ng "简介仍是出厂文案" || ok "出厂文案已被替换"

# 覆盖安装：新包的 module.prop 把 description 换回出厂文案，
# 而 desc.last 在 /data 下、升级不清 —— 只比缓存会误判"已同步"。
cp /mod/module.prop /opt/qc/module.prop
[ -s "$SDD/run/desc.last" ] && ok "升级后 desc.last 仍保留" || ng "desc.last 缺失，用例无效"
MODDIR=/opt/qc SD_DATA=$SDD sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_sync_desc'
grep -q '温控档位 10/10' /opt/qc/module.prop && ok "覆盖安装后简介自动改回状态" || ng "升级后简介停在出厂文案"

# 已经一致时不该重写：闪存写入比一次字符串比较贵得多
T1=$(stat -c '%y' /opt/qc/module.prop)
sleep 1
MODDIR=/opt/qc SD_DATA=$SDD sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_sync_desc'
T2=$(stat -c '%y' /opt/qc/module.prop)
eq "$T2" "$T1" "内容一致时不重写"

# ============================================================ T25 温度源兜底
echo
echo "===== T25 温区读不到时：电池节点兜底 / 面板要说原因 ====="

printf 'temp_mode=static\nshell_temp=30\nwall=42\naggr=10\nbattery_limit=48\ntick=15\n' >"$SDD/state.conf"
# 温区全部消失，只留 power_supply —— ColorOS 上 SELinux 挡住温区的典型现场
mount -t tmpfs tmpfs /sys 2>/dev/null
mkdir -p /sys/class/power_supply/battery
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '380\n' >/sys/class/power_supply/battery/temp
J=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh json)
printf '%s' "$J" | grep -q '"real":38' && ok "温区缺失时用电池节点读数" || ng "电池节点兜底失败: $J"
printf '%s' "$J" | grep -q '"target":30' && ok "兜底读数参与改写决策" || ng "兜底后仍不改写: $J"

# 两条路都断：real 为 null，并且必须给出原因，不能只丢一句"未改写"
rm -f /sys/class/power_supply/battery/temp
J=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh json)
printf '%s' "$J" | grep -q '"real":null' && ok "全断时 real 为 null" || ng "全断时仍有温度: $J"
printf '%s' "$J" | grep -q '"real_why":"' && ok "给出读取失败原因" || ng "没有失败原因: $J"
printf '%s' "$J" | grep -q '"target":0' && ok "读不到温度时不乱报" || ng "读不到还给了目标: $J"

P=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh probe)
case "$P" in *"== 温区 =="*) ok "probe 输出温区段" ;; *) ng "probe 缺温区段" ;; esac
case "$P" in *"== 决策 =="*) ok "probe 输出决策段" ;; *) ng "probe 缺决策段" ;; esac

# ============================================================ T26 写入回执
echo
echo "===== T26 emul_temp 写不进去时必须报出来 ====="

mkdir -p /sys/class/thermal/thermal_zone0 /sys/class/thermal/thermal_zone1
printf 'shell_back\n' >/sys/class/thermal/thermal_zone0/type
printf '36000\n' >/sys/class/thermal/thermal_zone0/temp
: >/sys/class/thermal/thermal_zone0/emul_temp
printf 'battery\n' >/sys/class/thermal/thermal_zone1/type
printf '38000\n' >/sys/class/thermal/thermal_zone1/temp

OUT=$(SD_DATA=$SDD SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_zone_scan; sd_shell_emul 30; echo ok=$_sd_emul_ok')
case "$OUT" in *ok=1*) ok "写得进去时回执 1" ;; *) ng "写成功却报失败: $OUT" ;; esac

# 把 emul_temp 换成目录：节点还在，但写入必然失败
rm -f /sys/class/thermal/thermal_zone0/emul_temp
mkdir -p /sys/class/thermal/thermal_zone0/emul_temp
OUT=$(SD_DATA=$SDD SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_zone_scan; sd_shell_emul 30; echo ok=$_sd_emul_ok')
case "$OUT" in *ok=0*) ok "写不进去时回执 0" ;; *) ng "写失败仍报成功: $OUT" ;; esac

# 面板从缓存读回执，不能把"算出来的目标"当成"已经生效"。
# UP 必须用模块自己的 sd_now_up 取：部分容器的 /proc/uptime 不支持 read(2)，
# 模块内读到的是 0，手写真实 uptime 反而会让缓存"来自未来"而被丢弃。
UP=$(SD_DATA=$SDD SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_now_up; echo $_sd_rv')
printf '%s 36 48 thermal_zone1 30 static 0\n' "$UP" >"$SDD/run/sensor"
J=$(SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/action.sh json)
printf '%s' "$J" | grep -q '"emul_ok":0' && ok "面板显示写入失败" || ng "面板没显示写入失败: $J"

printf '%s 36 48 thermal_zone1 30 static 1\n' "$UP" >"$SDD/run/sensor"
J=$(SD_DATA=$SDD SD_MODDIR=/opt/qc sh /opt/qc/action.sh json)
printf '%s' "$J" | grep -q '"emul_ok":1' && ok "写得进去时面板显示正常" || ng "正常写入被误报: $J"

# ============================================================ T27 电芯数判定
echo
echo "===== T27 单电芯不能被认成双电芯 ====="
# bcc_parms 的第二颗电压槽位在单电芯机型上不是恒为 0：有的驱动留残值，
# 有的把 mAh 之类的量塞进同一字段。旧判据只看 v1>1000mV，会把单芯认成
# 双芯，总压和功率一起翻倍。
mkdir -p /sys/class/oplus_chg/battery "$SDD"
# 本节验证的是"没有直报值时"的电压判据，先把直报节点摘掉
rm -f /sys/class/oplus_chg/battery/aging_ffc_data

printf '0,0,0,0,0,0,4400,0,3000,0,0,1500,0,0,0,0,0,0,0\n' >/sys/class/oplus_chg/battery/bcc_parms
P=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh power)
echo "$P" | grep -q '"cells":1' && ok "v1 残值 1500mV 不判双芯" || ng "仍误判双芯: $P"
echo "$P" | grep -q '"mv":4400'  && ok "单芯总压不被相加" || ng "电压错误: $P"

printf '0,0,0,0,0,0,4400,0,3000,0,0,5000,0,0,0,0,0,0,0\n' >/sys/class/oplus_chg/battery/bcc_parms
P=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh power)
echo "$P" | grep -q '"cells":1' && ok "v1 非电压量不判双芯" || ng "仍误判: $P"

# 真双芯：两颗接近、总压 8.8V，必须仍然认得出
printf '0,0,0,0,0,0,4400,0,3000,0,0,4420,0,0,0,0,0,0,0\n' >/sys/class/oplus_chg/battery/bcc_parms
P=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh power)
echo "$P" | grep -q '"cells":2' && ok "真双芯仍识别" || ng "双芯漏判: $P"
echo "$P" | grep -q '"mv":8820'  && ok "双芯总压相加" || ng "总压错误: $P"

# 自动判断仍不准的机型，用 cells 强制覆盖
SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh cells 1 >/dev/null 2>&1
P=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh power)
echo "$P" | grep -q '"cells":1' && ok "cells 1 强制单芯" || ng "强制单芯失败: $P"
echo "$P" | grep -q '"mv":4400'  && ok "强制单芯后取单芯电压" || ng "强制后电压错误: $P"

printf '0,0,0,0,0,0,4400,0,3000,0,0,0,0,0,0,0,0,0,0\n' >/sys/class/oplus_chg/battery/bcc_parms
SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh cells 2 >/dev/null 2>&1
P=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh power)
echo "$P" | grep -q '"cells":2' && ok "cells 2 强制双芯" || ng "强制双芯失败: $P"

SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh cells auto >/dev/null 2>&1
SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh cells 3 >/dev/null 2>&1 \
    && ng "非法参数未拒绝" || ok "非法参数被拒绝"

# 用户回报时只要能贴这一段，就能判断是驱动槽位问题还是判据问题
P=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh probe)
case "$P" in *"== 电芯 =="*) ok "probe 输出电芯段" ;; *) ng "probe 缺电芯段" ;; esac

# ============================================================ T28 直报优先与适配检查
echo
echo "===== T28 aging_ffc_data 直报优先 / check 一次采样 ====="

B=/sys/class/oplus_chg/battery
mkdir -p "$B"

# 驱动自己数出来的电芯数最可靠，哪怕 bcc 两路电压看起来像双芯也要听它的。
# 单电芯骁龙机型上 bcc 第二槽位常留残值，只靠电压推会误判。
printf '0,1,0,0,186,4550,4490,4520,4475\n' >"$B/aging_ffc_data"
printf '0,0,0,0,0,0,4420,0,2950,0,0,4420,0,0,0,0,0,0,0\n' >"$B/bcc_parms"
P=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh power)
echo "$P" | grep -q '"cells":1' && ok "直报单芯压过电压判据" || ng "未听直报: $P"
echo "$P" | grep -q '"cells_src":"aging"' && ok "标注依据 aging" || ng "依据错误: $P"
echo "$P" | grep -q '"mv":4420' && ok "单芯电压不相加" || ng "电压错误: $P"

# 直报双芯但第二槽位没填：按单芯电压翻倍，不能只报一半
printf '0,2,0,0,186,4550,4490,4520,4475\n' >"$B/aging_ffc_data"
printf '0,0,0,0,0,0,4420,0,2950,0,0,0,0,0,0,0,0,0,0\n' >"$B/bcc_parms"
P=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh power)
echo "$P" | grep -q '"cells":2' && ok "直报双芯被采用" || ng "双芯漏判: $P"
echo "$P" | grep -q '"mv":8840' && ok "第二路空时按单芯翻倍" || ng "总压错误: $P"

# 手动指定优先级最高：现场觉得直报也不对时能立刻纠正
SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh cells 1 >/dev/null 2>&1
P=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh power)
echo "$P" | grep -q '"cells":1' && ok "手动压过直报" || ng "手动未生效: $P"
echo "$P" | grep -q '"cells_src":"manual"' && ok "标注依据 manual" || ng "依据错误: $P"
SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh cells auto >/dev/null 2>&1

# check：一次采样给结论，不需要守护、不需要等 tick
C=$(SD_DATA=$SDD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 sh /opt/qc/action.sh check)
case "$C" in *"[ok] 温区"*) ok "check 报告温区" ;; *) ng "check 缺温区: $C" ;; esac
case "$C" in *"电芯"*) ok "check 报告电芯" ;; *) ng "check 缺电芯: $C" ;; esac
case "$C" in *"结论:"*) ok "check 给出结论" ;; *) ng "check 缺结论: $C" ;; esac
# 版本号从 module.prop 读，避免每次发版都要回来改断言
_V=$(sed -n 's/^version=//p' /opt/qc/module.prop)
case "$C" in *"v$_V"*) ok "check 打印版本 v$_V" ;; *) ng "check 缺版本: $C" ;; esac


# ---------------------------------------------------------------- T29 MTK
# 天玑机的四件事：温区叫 mtkts*、电池 mC 编码、限流节点在 power_supply、
# 内核另有一套 charger-manager 温控。逐条验证，不能只看"能跑起来"。
echo
echo "===== T29 MTK 适配 ====="
rm -rf /sys/class/thermal/thermal_zone*
mkzone thermal_zone0 shell-back   30000
mkzone thermal_zone1 mtktsbattery 26000
mkzone thermal_zone2 mtktscpu     40000
mkzone thermal_zone3 mtktspmic    38000
mkzone thermal_zone4 tzts1        39000
printf '3000000\n' >/sys/class/power_supply/battery/input_current_limit
mkdir -p /tmp/mtk_battery_cmd /tmp/oplus-votable/UFCS_CURR
printf '0 0\n' >/tmp/mtk_battery_cmd/current_cmd
MTKD=/data/adb/qc-mtk
rm -rf "$MTKD"; mkdir -p "$MTKD"
mtk() {
    env SD_DATA=$MTKD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 \
        SD_MTK_CMD=/tmp/mtk_battery_cmd SD_VOTABLE=/tmp/oplus-votable \
        FAKE_PLAT=mt6895 FAKE_SOCMFR=MediaTek "$@"
}

C=$(mtk sh /opt/qc/action.sh check)
case "$C" in *"哨兵 thermal_zone1"*) ok "MTK 电池温区被选为哨兵" ;; *) ng "哨兵选错: $C" ;; esac
case "$C" in *"MediaTek（MTK）"*) ok "check 识别 MTK 平台" ;; *) ng "平台未识别: $C" ;; esac
case "$C" in *"降档提前 2℃"*) ok "check 报告 MTK 降档策略" ;; *) ng "缺降档提示: $C" ;; esac
case "$C" in *"[ok] 投票"*) ok "check 报告投票接口存在" ;; *) ng "投票未报告: $C" ;; esac

P=$(mtk sh /opt/qc/action.sh probe)
case "$P" in *"== 平台 / 协议 =="*) ok "probe 输出平台段" ;; *) ng "probe 缺平台段" ;; esac
case "$P" in *"mtk_battery_cmd: 存在"*) ok "probe 标注 MTK 开关接口" ;; *) ng "probe 缺 mtk 提示" ;; esac
case "$P" in *"mtktsbattery"*"battery"*) ok "probe 标注温区语义类" ;; *) ng "probe 缺语义列: $P" ;; esac

# 熔断阈值必须按电池算，不能落到 SoC 结温的 85℃
R=$(mtk sh -c '. /opt/qc/lib/qc.sh; sd_zone_scan; sd_limit_for_type_v mtktsbattery; echo $_sd_rv')
eq "$R" "48" "MTK 电池温区按 48℃ 熔断"
R=$(mtk sh -c '. /opt/qc/lib/qc.sh; sd_zone_scan; sd_limit_for_type_v mtktscpu; echo $_sd_rv')
eq "$R" "85" "MTK CPU 温区按 85℃ 熔断"

# 三种温度编码并存
R=$(mtk sh -c '. /opt/qc/lib/qc.sh; sd_sentinel_temp_v /sys/class/thermal/thermal_zone1; echo $_sd_rv')
eq "$R" "26" "mC 编码 26000 → 26℃"
printf '450\n' >/sys/class/thermal/thermal_zone1/temp
R=$(mtk sh -c '. /opt/qc/lib/qc.sh; sd_sentinel_temp_v /sys/class/thermal/thermal_zone1; echo $_sd_rv')
eq "$R" "45" "0.1℃ 编码 450 → 45℃"
printf '45\n' >/sys/class/thermal/thermal_zone1/temp
R=$(mtk sh -c '. /opt/qc/lib/qc.sh; sd_sentinel_temp_v /sys/class/thermal/thermal_zone1; echo $_sd_rv')
eq "$R" "45" "整数摄氏度 45 → 45℃"
printf '999999\n' >/sys/class/thermal/thermal_zone1/temp
R=$(mtk sh -c '. /opt/qc/lib/qc.sh; sd_sentinel_temp_v /sys/class/thermal/thermal_zone1; echo rc=$?')
case "$R" in *"rc=1"*) ok "无法识别的编码判为读不到" ;; *) ng "异常编码被接受: $R" ;; esac
printf '26000\n' >/sys/class/thermal/thermal_zone1/temp

# 伪装范围：core 能写 mtktscpu，但电池 NTC 必须原样不动
mtk sh -c '. /opt/qc/lib/qc.sh; sd_zone_scan; sd_spoof_apply core 50' >/dev/null 2>&1
eq "$(cat /sys/class/thermal/thermal_zone2/temp)" "50000" "core 伪装写入 mtktscpu"
eq "$(cat /sys/class/thermal/thermal_zone1/temp)" "26000" "电池温区不被 core 伪装覆盖"
mtk sh -c '. /opt/qc/lib/qc.sh; sd_zone_scan; sd_spoof_apply noncore 55' >/dev/null 2>&1
eq "$(cat /sys/class/thermal/thermal_zone1/temp)" "26000" "noncore 伪装不碰电池"
eq "$(cat /sys/class/thermal/thermal_zone3/temp)" "38000" "PMIC 温区不被 noncore 覆盖"

# 限流节点：MTK 的 power_supply 节点进表，开关接口绝不进表
N=$(mtk sh -c '. /opt/qc/lib/qc.sh; sd_curr_nodes' | grep -c 'input_current_limit')
eq "$N" "1" "MTK input_current_limit 进入限流节点表"
N=$(mtk sh -c '. /opt/qc/lib/qc.sh; sd_curr_nodes' | grep -c 'mtk_battery_cmd')
eq "$N" "0" "充电开关接口不进入限流节点表"

# 协议：10V/7.3A 只能是私有快充
mkdir -p /sys/class/power_supply/usb
printf '10000000\n' >/sys/class/power_supply/usb/voltage_max
printf '7300000\n' >/sys/class/power_supply/usb/current_max
C=$(mtk sh /opt/qc/action.sh check)
case "$C" in *"私有快充"*) ok "协商 10V/7.3A 判为私有快充" ;; *) ng "协议误判: $C" ;; esac

# 降档点：同样 40℃，MTK 提前到 25%，高通仍是 50%
printf '40000\n' >/sys/class/thermal/thermal_zone1/temp
T=$(mtk sh -c '. /opt/qc/lib/qc.sh; sd_state_set curr_max 3000; sd_state_set wall 42; sd_zone_scan; sd_curr_target_v; echo $_sd_rv')
eq "$T" "750" "MTK 40℃ 提前降到 25%"
T=$(env SD_DATA=$MTKD SD_MODDIR=/opt/qc SD_NO_DAEMON=1 FAKE_PLAT=sm8750 FAKE_SOCMFR=Qualcomm \
    sh -c '. /opt/qc/lib/qc.sh; sd_state_set curr_max 3000; sd_state_set wall 42; sd_zone_scan; sd_curr_target_v; echo $_sd_rv')
eq "$T" "1500" "高通同温度只降到 50%"
printf '26000\n' >/sys/class/thermal/thermal_zone1/temp


# ---------------------------------------------------------------- T30 天玑 8100
# 真我 GT Neo3（RMX3562 / mt6895 / 天玑 8100）的节点布局，顺序故意做成
# "电池温区排在最后"：按名字列表匹配的实现会先撞上 PMIC，然后拿 PMIC 当哨兵，
# 电池 50℃ 也不熔断。这里跑真守护，不调单函数。
echo
echo "===== T30 天玑 8100 / GT Neo3 全链路 ====="
# 上一组用例可能还挂着 bind mount，直接 rm 会 "Device or resource busy"，
# 残留的温区会带进这一组，先卸再删。
for _m in /sys/class/thermal/*/temp; do umount -l "$_m" 2>/dev/null; done
rm -rf /sys/class/thermal/thermal_zone*
mkzone thermal_zone0 mtktscpu      42000
mkzone thermal_zone1 mtktspmic     40000
mkzone thermal_zone2 mtktswmt      45000
mkzone thermal_zone3 shell-back    31000
mkzone thermal_zone4 tzts1         41000
mkzone thermal_zone5 mtktsbattery  40000
mkzone thermal_zone6 mtktsbtsmdpa  43000

rm -rf /sys/class/power_supply/battery /sys/class/power_supply/usb
mkdir -p /sys/class/power_supply/battery /sys/class/power_supply/usb
printf 'Charging\n'   >/sys/class/power_supply/battery/status
printf '62\n'         >/sys/class/power_supply/battery/capacity
printf '400\n'        >/sys/class/power_supply/battery/temp          # 0.1℃
printf '4400000\n'    >/sys/class/power_supply/battery/voltage_now
printf '7300000\n'    >/sys/class/power_supply/battery/input_current_limit
printf '7300000\n'    >/sys/class/power_supply/battery/current_now
printf 'USB_DCP\n'    >/sys/class/power_supply/usb/real_type
printf '10000000\n'   >/sys/class/power_supply/usb/voltage_max
printf '7300000\n'    >/sys/class/power_supply/usb/current_max

rm -rf /sys/class/oplus_chg
mkdir -p /sys/class/oplus_chg/battery /sys/class/oplus_chg/charger
for f in chg_enable chg_current_max current_max batt_temp fastcharge_mode; do
    printf '0\n' >"/sys/class/oplus_chg/battery/$f"
done
printf '1\n'    >/sys/class/oplus_chg/battery/chg_enable
printf '400\n'  >/sys/class/oplus_chg/battery/batt_temp
printf '7300000\n' >/sys/class/oplus_chg/battery/chg_current_max

GT=/data/adb/qc-gt
rm -rf "$GT"; mkdir -p "$GT"
gt() {
    env SD_DATA=$GT SD_MODDIR=/opt/qc SD_NO_DAEMON=1 \
        FAKE_MFR=realme FAKE_PLAT=mt6895 FAKE_SOCMFR=MediaTek FAKE_HW=mt6895 "$@"
}

C=$(gt sh /opt/qc/action.sh check)
case "$C" in *"MediaTek（MTK） · mt6895 · 降档提前 2℃"*) ok "GT Neo3 识别为 MTK 且带降档提示" ;; *) ng "平台行不符: $C" ;; esac
case "$C" in *"哨兵 thermal_zone5"*) ok "哨兵选中 mtktsbattery（不是 PMIC/CPU）" ;; *) ng "哨兵选错: $(printf '%s' "$C" | grep 哨兵)" ;; esac
case "$C" in *"私有快充"*) ok "10V/7.3A 判为私有快充" ;; *) ng "协议误判" ;; esac
case "$C" in *"10V/7300mA"*) ok "协议电压按 V 显示（不是 10000V）" ;; *) ng "电压单位错: $(printf '%s' "$C" | grep 协议)" ;; esac

P=$(gt sh /opt/qc/action.sh probe)
case "$P" in *"mtktsbattery"*"battery"*) ok "probe 把 mtktsbattery 归到 battery 类" ;; *) ng "probe 语义列缺失" ;; esac
case "$P" in *"== oplus_chg =="*) ok "probe 输出 oplus_chg 现场" ;; *) ng "probe 缺 oplus_chg" ;; esac
case "$P" in *"batt_temp"*"400"*) ok "probe 读到 oplus_chg 的 batt_temp" ;; *) ng "oplus_chg 读数缺失" ;; esac

# 守护：真实 40℃、基准 30℃、不设墙（屏障 = 熔断值 - 2 = 46）
printf 'temp_mode=static\nshell_temp=30\nwall=off\naggr=10\ntick=5\nbattery_limit=48\nsentinel_limit=85\ncurr_max=0\ndefrev=3\n' >"$GT/state.conf"
gt sh /opt/qc/service.sh --daemon >/tmp/gt.log 2>&1 &
GTP=$!
wait_eq "/sys/class/thermal/thermal_zone3/emul_temp" "30000" 7 "MTK 壳温伪装落到 shell-back"
eq "$(cat /sys/class/thermal/thermal_zone5/temp)" "40000" "电池 NTC 未被伪装改写"
eq "$(cat /sys/class/thermal/thermal_zone1/temp)" "40000" "PMIC 未被伪装改写"
eq "$(cat /sys/class/power_supply/battery/temp)" "400" "battery/temp 原样保留"
eq "$(cat /sys/class/power_supply/battery/input_current_limit)" "7300000" "未设 curr_max 时不动 MTK 限流节点"

# 设 3000mA：MTK 在 40℃ 提前降到 25%
# 注意这里必须显式设墙。墙 off 时联动起点改成"熔断阈值前 4℃"（48-4=44），
# 40℃ 只到 50%，那是另一条保护曲线，下面单独验。
gt sh -c '. /opt/qc/lib/qc.sh; sd_state_set wall 42; sd_state_set curr_max 3000' >/dev/null 2>&1
wait_eq "/sys/class/power_supply/battery/input_current_limit" "750000" 7 "MTK 限流节点被压到 750mA（墙 42℃）"
gt sh -c '. /opt/qc/lib/qc.sh; sd_state_set wall off' >/dev/null 2>&1
wait_eq "/sys/class/power_supply/battery/input_current_limit" "1500000" 7 "墙关闭时按熔断-4℃ 联动，40℃ 只降到 50%"

# 熔断：电池 50℃ ≥ 48℃，下一 tick 必须停伪装
printf '50000\n' >/sys/class/thermal/thermal_zone5/temp
wait_eq "/sys/class/thermal/thermal_zone3/emul_temp" "0" 7 "电池 50℃ 触发熔断，伪装撤销"
grep -q '熔断' "$GT/log.txt" && grep -q 'thermal_zone5' "$GT/log.txt" && ok "熔断日志指向电池温区" || ng "熔断未指向电池"
eq "$(grep '^temp_mode=' "$GT/state.conf")" "temp_mode=static" "熔断不改用户配置"

# 回落 40℃：40+3 ≤ 48，必须自动恢复
printf '40000\n' >/sys/class/thermal/thermal_zone5/temp
wait_eq "/sys/class/thermal/thermal_zone3/emul_temp" "30000" 13 "温度回落后自动恢复伪装"
kill -TERM "$GTP" 2>/dev/null; wait_dead "$GTP"

# core / noncore 伪装都不能碰电池与 PMIC
gt sh -c '. /opt/qc/lib/qc.sh; sd_zone_scan; sd_spoof_apply core 50' >/dev/null 2>&1
eq "$(cat /sys/class/thermal/thermal_zone0/temp)" "50000" "core 伪装命中 mtktscpu"
eq "$(cat /sys/class/thermal/thermal_zone5/temp)" "40000" "core 伪装跳过电池"
eq "$(cat /sys/class/thermal/thermal_zone1/temp)" "40000" "core 伪装跳过 PMIC"
gt sh -c '. /opt/qc/lib/qc.sh; sd_zone_scan; sd_spoof_clear' >/dev/null 2>&1

# ---------------------------------------------------------------- T31 平台判定
# 判定顺序：厂商字段 > 板级/硬件型号 > cpuinfo 兜底。逐条过一遍，
# 并锁死"高通拿到的限流节点表与 2.7.x 完全一致"。
echo
echo "===== T31 平台判定矩阵 / 骁龙无回归 ====="
plat() {
    env SD_DATA=$GT SD_MODDIR=/opt/qc SD_NO_DAEMON=1 \
        FAKE_PLAT="$1" FAKE_SOCMFR="$2" FAKE_HW="$3" \
        sh -c '. /opt/qc/lib/qc.sh; sd_plat_resolve; printf "%s" "$_sd_plat"'
}
eq "$(plat mt6895 MediaTek mt6895)"  "mtk"  "天玑 8100（mt6895）判 MTK"
eq "$(plat mt6983 MediaTek mt6983)"  "mtk"  "天玑 9000（mt6983）判 MTK"
eq "$(plat mt6989 MediaTek mt6989)"  "mtk"  "天玑 9300（mt6989）判 MTK"
eq "$(plat mt6991 "" mt6991)"        "mtk"  "天玑 9400（mt6991）只有硬件字段也判 MTK"
eq "$(plat '' MediaTek '')"          "mtk"  "只有厂商字段也判 MTK"
eq "$(plat '' '' mt6833)"            "mtk"  "只有 ro.hardware 型号也判 MTK"
eq "$(plat MT6895 '' '')"            "mtk"  "大写 MT6895 判 MTK"
eq "$(plat sm8750 Qualcomm qcom)"    "qcom" "骁龙 8 Elite（sm8750）判高通"
eq "$(plat sun '' hw-unknown)"       "qcom" "板级代号 sun（8 Elite）判高通"
eq "$(plat canoe '' hw-unknown)"     "qcom" "板级代号 canoe（SM8850）判高通"
eq "$(plat taro Qualcomm qcom)"      "qcom" "骁龙 8 Gen1（taro）判高通"
eq "$(plat msm8998 '' qcom)"         "qcom" "msm8998 判高通"
eq "$(plat '' '' qcom)"              "qcom" "只有 ro.hardware=qcom 也判高通"
eq "$(plat '' Xiaomi hw-unknown)"    "other" "识别不了不硬猜，落 other"

# 限流节点表：高通名单必须与 2.7.x 逐项一致，不能多出 MTK 专属项。
# 造一套两个平台都有的节点，只让平台字段不同，才能证明差异只来自判定。
rm -rf /sys/class/power_supply/*
for d in battery main bms usb charger; do mkdir -p "/sys/class/power_supply/$d"; done
printf '7300000\n' >/sys/class/power_supply/battery/constant_charge_current_max
printf '7300000\n' >/sys/class/power_supply/battery/constant_charge_current
printf '7300000\n' >/sys/class/power_supply/battery/current_max
printf '7300000\n' >/sys/class/power_supply/battery/input_current_limit
printf '3000000\n' >/sys/class/power_supply/main/constant_charge_current_max
printf '3000000\n' >/sys/class/power_supply/bms/current_max
printf '3000000\n' >/sys/class/power_supply/usb/current_max
printf '3000000\n' >/sys/class/power_supply/charger/current_max
nl() {
    env SD_DATA=$GT SD_MODDIR=/opt/qc SD_NO_DAEMON=1 SD_OPLUS_CHG=/nonexistent/oplus \
        FAKE_PLAT="$1" FAKE_SOCMFR="$2" FAKE_HW="$3" \
        sh -c '. /opt/qc/lib/qc.sh; sd_curr_nodes' | sed 's#^/sys/class/power_supply/##' | tr '\n' '|'
}
QN=$(nl sm8750 Qualcomm qcom)
EQ_Q="battery/constant_charge_current_max|battery/constant_charge_current|battery/current_max|main/constant_charge_current_max|bms/current_max|usb/current_max|"
eq "$QN" "$EQ_Q" "高通限流名单与旧版逐项一致"
MN=$(nl mt6895 MediaTek mt6895)
eq "$MN" "battery/input_current_limit|charger/current_max|${EQ_Q}" "MTK 名单只多两项专属节点且排在最前"
# 平台判不出来时按通用名单走：高通的 input_current_limit 是输入电流，
# 多写一个就等于额外砍功率，宁可少写。
ON=$(nl "" Xiaomi hw-unknown)
eq "$ON" "$EQ_Q" "other 平台不追加 MTK 节点"

# 熔断候选：与 2.7.x 一致 —— 电池类 + xo-therm。
# 充电 IC / PMIC 不算：100W 机型充电时充电 IC 本身就 85℃ 上下，算进去
# 会让熔断在充电全程反复触发，伪装开关一次，功率就打一次锯齿。
gs() {
    env SD_DATA=$GT SD_MODDIR=/opt/qc SD_NO_DAEMON=1 \
        FAKE_PLAT=sm8750 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom \
        sh -c '. /opt/qc/lib/qc.sh; sd_zone_is_guard_src "$1" && echo yes || echo no' _ "$1"
}
eq "$(gs xo-therm)"      "yes" "xo-therm 参与熔断"
eq "$(gs pmic-therm)"    "no"  "PMIC 不参与熔断（正常就 60~80℃）"
eq "$(gs charger-therm)" "no"  "充电 IC 不参与熔断（100W 时 85℃ 上下）"
eq "$(gs battery)"       "yes" "电池温区参与熔断"
eq "$(gs wlan)"        "no"  "WiFi 温区不参与熔断"
eq "$(gs pa-therm0)"   "no"  "PA 温区不参与熔断"
eq "$(gs cpu-0-0)"     "no"  "CPU 温区不参与熔断"

# other 平台不吃 MTK 的提前降档
printf '40000\n' >/sys/class/thermal/thermal_zone5/temp
T=$(env SD_DATA=$GT SD_MODDIR=/opt/qc SD_NO_DAEMON=1 FAKE_PLAT= FAKE_SOCMFR=Xiaomi FAKE_HW=hw-unknown \
    sh -c '. /opt/qc/lib/qc.sh; sd_state_set curr_max 3000; sd_state_set wall 42; sd_zone_scan; sd_curr_target_v; echo $_sd_rv')
eq "$T" "1500" "other 平台按通用 50% 降档，不吃 MTK 的提前量"

# 骁龙侧熔断不变：battery 温区 50℃ 照样熔断
rm -rf /sys/class/thermal/thermal_zone*
mkzone thermal_zone0 shell-back 30000
mkzone thermal_zone1 battery    50000
mkzone thermal_zone2 xo-therm   45000
mkzone thermal_zone3 cpu-0-0    50000
printf '500\n' >/sys/class/power_supply/battery/temp
Q=/data/adb/qc-q
rm -rf "$Q"; mkdir -p "$Q"
printf 'temp_mode=static\nshell_temp=30\nwall=off\naggr=10\ntick=5\nbattery_limit=48\nsentinel_limit=85\ncurr_max=0\ndefrev=3\n' >"$Q/state.conf"
env SD_DATA=$Q SD_MODDIR=/opt/qc FAKE_PLAT=sm8750 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom \
    sh /opt/qc/service.sh --daemon >/tmp/q.log 2>&1 &
QP=$!
wait_eq "/sys/class/thermal/thermal_zone0/emul_temp" "0" 7 "骁龙：电池 50℃ 同样熔断"
grep -q 'thermal_zone1' "$Q/log.txt" && ok "骁龙熔断仍指向 battery 温区" || ng "骁龙熔断节点变了"
kill -TERM "$QP" 2>/dev/null; wait_dead "$QP"
rm -f /sys/class/power_supply/battery/input_current_limit


# ---------------------------------------------------------------- T32 真机布局
# 用户实测输出的 GT Neo3 节点表：电池温区叫 mtk-battery（不是 mtktsbattery），
# 读数是 2000；shell_* 全是 0；两个 div-charger 是 -40000；电源节点是
# mtk-battery / mtk-gauge。这套名字和数值跟仿真假设都不一致，按真机复刻。
echo
echo "===== T32 GT Neo3 实测节点布局 ====="
for _m in /sys/class/thermal/*/temp; do umount -l "$_m" 2>/dev/null; done
rm -rf /sys/class/thermal/thermal_zone*
mkzone thermal_zone0 cpu_big1           43786
mkzone thermal_zone1 cpu_big2           46842
mkzone thermal_zone2 mtk-mst-div-charger -40000
mkzone thermal_zone3 mtk-slv-div-charger -40000
mkzone thermal_zone4 mtk-battery          2000
mkzone thermal_zone5 shell_front             0
mkzone thermal_zone6 shell_frame             0
mkzone thermal_zone7 shell_back              0

rm -rf /sys/class/power_supply/*
for d in battery mtk-battery mtk-gauge usb; do mkdir -p "/sys/class/power_supply/$d"; done
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '69\n'       >/sys/class/power_supply/battery/capacity
printf '350\n'      >/sys/class/power_supply/battery/temp
printf '350\n'      >/sys/class/power_supply/mtk-battery/temp
printf '350\n'      >/sys/class/power_supply/mtk-gauge/temp
printf 'USB_DCP\n'  >/sys/class/power_supply/usb/real_type
printf '10000000\n' >/sys/class/power_supply/usb/voltage_max
printf '7300000\n'  >/sys/class/power_supply/usb/current_max

G2=/data/adb/qc-gt2
rm -rf "$G2"; mkdir -p "$G2"
# 真机跑一遍 check/probe 需要的数据目录
printf 'temp_mode=static\nshell_temp=30\nwall=off\naggr=10\ntick=5\nbattery_limit=48\nsentinel_limit=85\ncurr_max=0\ndefrev=3\n' >"$G2/state.conf"
g2() {
    env SD_DATA=$G2 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 \
        FAKE_MFR=realme FAKE_PLAT=mt6895 FAKE_SOCMFR=MediaTek FAKE_HW=mt6895 "$@"
}

C=$(g2 sh /opt/qc/action.sh check)
case "$C" in *"哨兵 thermal_zone4"*) ok "mtk-battery 被选为哨兵" ;; *) ng "哨兵没选中 mtk-battery: $(printf '%s' "$C" | grep 哨兵)" ;; esac
case "$C" in *"可读 6 个"*) ok "-40000 的 div-charger 不计入可读" ;; *) ng "无效温度被当成可读: $(printf '%s' "$C" | grep 温区)" ;; esac

P=$(g2 sh /opt/qc/action.sh probe)
case "$P" in *"mtk-battery/temp"*"350"*) ok "probe 列出 mtk-battery 电量计" ;; *) ng "probe 没列 mtk-battery" ;; esac
case "$P" in *"mtk-gauge/temp"*"350"*) ok "probe 列出 mtk-gauge 电量计" ;; *) ng "probe 没列 mtk-gauge" ;; esac
case "$P" in *"不在 8-90℃"*) ok "probe 标出温区读数未初始化" ;; *) ng "probe 未提示未初始化读数" ;; esac

# MTK 分体充电 IC 的 current_max 也要进表（GT Neo3 是主从两路）
mkdir -p /sys/class/power_supply/mtk-master-charger /sys/class/power_supply/mtk-slave-charger
printf '7300000\n' >/sys/class/power_supply/mtk-master-charger/current_max
printf '7300000\n' >/sys/class/power_supply/mtk-slave-charger/current_max
printf '7300000\n' >/sys/class/power_supply/mtk-battery/current_max
N=$(g2 sh -c '. /opt/qc/lib/qc.sh; sd_curr_nodes' | grep -c 'mtk-master-charger/current_max')
eq "$N" "1" "主充电 IC 的 current_max 进入限流表"
# 30℃ 时是满功率档，直接验证节点值，不掺降档比例
printf '300\n' >/sys/class/power_supply/battery/temp
printf '300\n' >/sys/class/power_supply/mtk-battery/temp
printf '300\n' >/sys/class/power_supply/mtk-gauge/temp
g2 sh -c '. /opt/qc/lib/qc.sh; sd_state_set curr_max 2000; sd_curr_keep' >/dev/null 2>&1
eq "$(cat /sys/class/power_supply/mtk-master-charger/current_max)" "2000000" "主充电 IC 被压到 2000mA"
eq "$(cat /sys/class/power_supply/mtk-slave-charger/current_max)" "2000000" "从充电 IC 同步压到 2000mA"
g2 sh -c '. /opt/qc/lib/qc.sh; sd_state_set curr_max 0' >/dev/null 2>&1
printf '350\n' >/sys/class/power_supply/battery/temp
printf '350\n' >/sys/class/power_supply/mtk-battery/temp
printf '350\n' >/sys/class/power_supply/mtk-gauge/temp

# 温区 2℃、电量计 35℃ → 目标必须按 35℃ 算，得到 30
T=$(g2 sh -c '. /opt/qc/lib/qc.sh; sd_shell_target')
eq "$T" "30" "决策采信电量计（35℃），不是温区的 2℃"

g2 sh /opt/qc/service.sh --daemon >/tmp/gt2.log 2>&1 &
G2P=$!
wait_eq "/sys/class/thermal/thermal_zone7/emul_temp" "30000" 7 "shell_back 写入伪装"
eq "$(cat /sys/class/thermal/thermal_zone4/temp)" "2000" "mtk-battery 温区不被改写"
eq "$(cat /sys/class/thermal/thermal_zone2/temp)" "-40000" "div-charger 不被改写"
eq "$(cat /sys/class/thermal/thermal_zone0/temp)" "43786" "cpu_big1 不被壳温伪装碰到"

# 温区一直是 2000（未初始化），电量计 50℃：熔断必须靠电量计兜住，
# 否则这块屏上永远不会因为电池过热而停手。
printf '500\n' >/sys/class/power_supply/battery/temp
printf '500\n' >/sys/class/power_supply/mtk-battery/temp
printf '500\n' >/sys/class/power_supply/mtk-gauge/temp
wait_eq "/sys/class/thermal/thermal_zone7/emul_temp" "0" 8 "温区失准时靠电量计熔断"
grep -q 'thermal_zone4' "$G2/log.txt" && ok "熔断日志指向 mtk-battery" || ng "熔断日志没指向电池温区"
kill -TERM "$G2P" 2>/dev/null; wait_dead "$G2P"

# 真的冷（电量计 18℃）：没有伪造的必要，关模拟而不是往写入层塞 18℃
printf '2000\n' >/sys/class/thermal/thermal_zone4/temp
printf '180\n'  >/sys/class/power_supply/battery/temp
printf '180\n'  >/sys/class/power_supply/mtk-battery/temp
printf '180\n'  >/sys/class/power_supply/mtk-gauge/temp
: >"$G2/log.txt"
g2 sh /opt/qc/service.sh --daemon >/tmp/gt2b.log 2>&1 &
G2B=$!
wait_eq "/sys/class/thermal/thermal_zone7/emul_temp" "0" 7 "低温时不写入伪装"
grep -q '超出合理范围' "$G2/log.txt" && ng "低温值被送进写入层刷错误日志" || ok "低温不走写入层"
kill -TERM "$G2B" 2>/dev/null; wait_dead "$G2B"

echo

# ---------------------------------------------------------------- T33 电芯判定
# 判据顺序与加加电池一致：驱动直报 > bcc 电压 > 整包电压 > 单芯。
# 同时锁死"单芯机型读数一个字节都不变"——这是高通侧的回归底线。
echo
echo "===== T33 单双电芯：加加电池判据 ====="
rm -rf /sys/class/power_supply/*
mkdir -p /sys/class/power_supply/battery /sys/class/power_supply/bms
printf 'Charging\n'  >/sys/class/power_supply/battery/status
printf '50\n'        >/sys/class/power_supply/battery/capacity
printf '4400000\n'   >/sys/class/power_supply/battery/voltage_now
printf '2000000\n'   >/sys/class/power_supply/battery/current_now
G3=/data/adb/qc-g3
rm -rf "$G3"; mkdir -p "$G3"
printf 'cells_mode=auto\npower_scale=100\n' >"$G3/state.conf"
p3() {
    env SD_DATA=$G3 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 \
        FAKE_PLAT=sm8750 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom "$@"
}
pj()     { p3 sh -c '. /opt/qc/lib/qc.sh; sd_power_json'; }
cellof() { pj | sed 's/.*"cells":\([0-9]*\).*/\1/'; }
mvof()   { pj | sed 's/.*"mv":\([0-9]*\).*/\1/'; }

# 1 单芯：只有 power_supply，4.4V × 2000mA = 8.80W
eq "$(cellof)" "1" "单芯：判 1 芯"
eq "$(mvof)"   "4400" "单芯：电压原样 4400mV"
case "$(pj)" in *'"w":8.80'*) ok "单芯 2000mA×4.4V = 8.80W" ;; *) ng "单芯功率错: $(pj)" ;; esac

# 2 单芯 + 电量计报 8.8V（异常）：不能因此翻倍
printf '8800000\n' >/sys/class/power_supply/bms/voltage_now
eq "$(mvof)"   "4400" "单芯：电量计异常 8.8V 也不翻倍"
eq "$(cellof)" "1"    "单芯：电量计异常不改判定"

# 3 双芯（aging 直报）+ 单节电压 + 电量计整包 8600
rm -rf /sys/class/oplus_chg; mkdir -p /sys/class/oplus_chg/battery
printf '0,2,0,0,186,4550,4400,4400,2000,0,0,4400,0,0,0,0,0,0,0\n' >/sys/class/oplus_chg/battery/aging_ffc_data
printf '8600000\n' >/sys/class/power_supply/bms/voltage_now
eq "$(cellof)" "2" "aging 第二位=2 → 双芯"
eq "$(mvof)"   "8600" "双芯：优先用电量计整包读数（不是 ×2 的 8800）"
case "$(pj)" in *'"cells_src":"aging"'*) ok "来源标 aging" ;; *) ng "来源不是 aging" ;; esac

# 4 双芯但电量计读不到：按串联数折算
rm -f /sys/class/power_supply/bms/voltage_now
eq "$(mvof)" "8800" "双芯：无整包读数时单节 ×2"

# 5 双芯且 voltage_now 已是整包：不能再乘一次
printf '8800000\n' >/sys/class/power_supply/battery/voltage_now
eq "$(mvof)" "8800" "双芯：已是整包电压不重复翻倍"
printf '4400000\n' >/sys/class/power_supply/battery/voltage_now

# 6 aging 不可用：整包电压 >6V 反推双芯
rm -f /sys/class/oplus_chg/battery/aging_ffc_data
printf '8800000\n' >/sys/class/power_supply/battery/voltage_now
eq "$(cellof)" "2" "无 aging：整包电压反推 2 芯"
case "$(pj)" in *'"cells_src":"volt"'*) ok "来源标 volt" ;; *) ng "来源不是 volt" ;; esac
printf '4400000\n' >/sys/class/power_supply/battery/voltage_now

# 7 手动指定压过一切
p3 sh -c '. /opt/qc/lib/qc.sh; sd_state_set cells_mode 1' >/dev/null 2>&1
eq "$(cellof)" "1" "手动 cells 1 压过驱动推断"
p3 sh -c '. /opt/qc/lib/qc.sh; sd_state_set cells_mode 2' >/dev/null 2>&1
eq "$(cellof)" "2" "手动 cells 2 压过驱动推断"
p3 sh -c '. /opt/qc/lib/qc.sh; sd_state_set cells_mode auto' >/dev/null 2>&1

# ============================================================ T34 温度墙滞回
echo
echo "===== T34 温度墙滞回：真实温度在墙附近不能来回切 ====="
# 前面的 MTK 用例把 zone 表换成了天玑布局，这里重建高通夹具
rm -rf /sys/class/thermal/thermal_zone*
mkzone thermal_zone0 shell-back 30000
mkzone thermal_zone1 battery    42000
mkzone thermal_zone2 xo-therm   45000
mkzone thermal_zone3 cpu-0-0    50000
printf 'temp_mode=static\nshell_temp=30\nwall=42\naggr=10\nbattery_limit=48\nsentinel_limit=85\n' >"$G3/state.conf"
printf '30000\n' >/sys/class/thermal/thermal_zone0/temp

# 同一次进程里连调三次：只有保住状态，滞回才成立
TV=$(p3 sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_zone_scan;
    printf "42000\n" >/sys/class/thermal/thermal_zone1/temp; sd_shell_target; printf ",";
    printf "41000\n" >/sys/class/thermal/thermal_zone1/temp; sd_shell_target; printf ",";
    printf "39500\n" >/sys/class/thermal/thermal_zone1/temp; sd_shell_target')
eq "$(printf '%s' "$TV" | cut -d, -f1)" "0" "真实 42℃ 到墙：关模拟"
eq "$(printf '%s' "$TV" | cut -d, -f2)" "0" "回落到 41℃（墙下 1℃）：滞回期内不恢复"
case "$(printf '%s' "$TV" | cut -d, -f3)" in
    ''|0) ng "回落到 39℃（墙下 3℃）应恢复伪装，实际 $TV" ;;
    *)    ok "回落到 39℃ 后恢复伪装 ($TV)" ;;
esac

# 未到墙时行为不变，别把滞回做成"必须降 2℃ 才干活"
printf '36000\n' >/sys/class/thermal/thermal_zone1/temp
eq "$(p3 sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_zone_scan; sd_shell_target')" "30" \
   "真实 36℃：照常压到基准 30℃"
printf '46000\n' >/sys/class/thermal/thermal_zone1/temp

# ============================================================ T35 开机清日志
echo
echo "===== T35 每次开机清理上一轮日志 ====="
D5=/data/adb/qc-g5
rm -rf "$D5"; mkdir -p "$D5/run"
printf 'OLD-ROUND-MARK\n' >"$D5/log.txt"
printf 'OLD-ROUND-MARK\n' >"$D5/log.old.txt"
# 时间要拉到"上一轮开机"之外，不能只往前推 2 小时：sd_boot_ts 是
# now - uptime，仿真宿主的 uptime 超过 2 小时后，2 小时前会被判成本轮，
# 用例就会假失败。3 天前对任何真实开机间隔都成立。
touch -d '3 days ago' "$D5/log.txt" 2>/dev/null || touch -t 202001010000 "$D5/log.txt"

# service.sh 兜底路径：post-fs-data 没跑时，日志的 mtime 早于本次开机
SD_DATA=$D5 SD_MODDIR=/opt/qc sh /opt/qc/service.sh >/tmp/d35.log 2>&1
grep -q 'OLD-ROUND-MARK' "$D5/log.txt" 2>/dev/null && ng "上一轮日志未被清理" || ok "上一轮日志已清理"
grep -q 'service 阶段启动' "$D5/log.txt" 2>/dev/null && ok "本轮记录从 boot 段落开始" || ng "本轮日志缺失: $(head -3 "$D5/log.txt" 2>/dev/null)"
[ -f "$D5/log.old.txt" ] && ng "轮转旧档未清理" || ok "轮转旧档一并删除"

# 本轮日志（刚写的）不能被二次清理误删
_b=$(SD_DATA=$D5 SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_boot_ts; printf " "; sd_file_mtime "$SD_LOG"')
case "$_b" in
    *" "*) _bt=${_b% *}; _mt=${_b#* }; \
           [ "$_mt" -ge "$_bt" ] && ok "本轮日志晚于开机时刻（不会被误清）" \
                                 || ng "时间判据异常: $_b" ;;
    *) ng "sd_boot_ts / sd_file_mtime 无输出" ;;
esac

# 直接调用也要真的删掉
SD_DATA=$D5 SD_MODDIR=/opt/qc sh -c '. /opt/qc/lib/qc.sh; sd_log_reset'
[ -f "$D5/log.txt" ] && ng "sd_log_reset 未删除日志" || ok "sd_log_reset 删除日志文件"
pkill -f 'service[.]sh --daemon' 2>/dev/null
sleep 1

# ============================================================ T36 充电 IC 高温
echo
echo "===== T36 充电 IC 85℃+ 不能触发熔断 ====="
rm -rf /sys/class/thermal/thermal_zone*
mkzone thermal_zone0 shell_back    40000
mkzone thermal_zone1 battery       42000
mkzone thermal_zone2 charger-therm 88000
mkzone thermal_zone3 xo-therm      50000
mkzone thermal_zone4 pmic-therm    70000
D6=/data/adb/qc-g6
rm -rf "$D6"; mkdir -p "$D6"
printf 'temp_mode=static\nshell_temp=30\nwall=48\naggr=9\nbattery_limit=48\nsentinel_limit=85\n' >"$D6/state.conf"
g6() {
    SD_DATA=$D6 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 \
        FAKE_PLAT=sm8850 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom "$@"
}

# 100W 机型充电时充电 IC 到 85℃ 是常态。它一旦进熔断候选，整个充电过程
# 就是"熔断→降档→凉下来→恢复→满功率"的循环，用户看到的就是功率锯齿。
eq "$(g6 sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_zone_scan; sd_sentinel_guard; echo $?')" "0" \
   "充电 IC 88℃：不熔断，伪装继续"
eq "$(g6 sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_zone_scan; sd_shell_target')" "31" \
   "充电 IC 88℃：目标温度照常 31℃"
printf '49000\n' >/sys/class/thermal/thermal_zone1/temp
eq "$(g6 sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_zone_scan; sd_sentinel_guard; echo $?')" "1" \
   "电池 49℃：照样熔断"

# ============================================================ T37 隐性缺陷
# 这一组针对"不报错、但行为是错的"的路径：限流只压不抬、关闭后不还原、
# 状态写入内存不同步、熔断复查把"读不到"当成"已降温"、兜底候选选中 WiFi。
echo
echo "===== T37 限流恢复 / 状态同步 / 熔断复查 ====="
D7=/data/adb/qc-g7
rm -rf "$D7"; mkdir -p "$D7"
printf 'temp_mode=static\nshell_temp=30\nwall=42\naggr=10\ncurr_max=4000\nbattery_limit=48\n' >"$D7/state.conf"
g7() {
    SD_DATA=$D7 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 \
        FAKE_PLAT=sm8750 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom "$@"
}

eq "$(g7 sh -c '. /opt/qc/lib/qc.sh; sd_state_set cells_mode 2; sd_state_get cells_mode auto')" "2" \
   "cells_mode 写入后内存同步"

rm -rf /sys/class/thermal/thermal_zone*
mkzone thermal_zone0 shell-back 30000
mkzone thermal_zone1 battery     40000
rm -rf /sys/class/power_supply
mkdir -p /sys/class/power_supply/battery
printf '8000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
printf '8000000\n' >/sys/class/power_supply/battery/current_max
printf '4200000\n' >/sys/class/power_supply/battery/voltage_now
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '50\n'      >/sys/class/power_supply/battery/capacity
printf '400\n'     >/sys/class/power_supply/battery/temp
CCM=/sys/class/power_supply/battery/constant_charge_current_max

g7 sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_zone_scan; sd_curr_keep' >/dev/null 2>&1
eq "$(cat $CCM)" "2000000" "40℃：限流压到 2000mA"

# 温度回落必须抬回去。旧实现"只压不抬"，节点会永远停在低档，
# 用户看到的是"温度降了，功率却没恢复"。
printf '30000\n' >/sys/class/thermal/thermal_zone1/temp
g7 sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_zone_scan; sd_curr_keep' >/dev/null 2>&1
eq "$(cat $CCM)" "4000000" "降到 30℃：限流抬回 4000mA"

g7 sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_state_set curr_max 0; sd_curr_keep' >/dev/null 2>&1
eq "$(cat $CCM)" "8000000" "关闭限流：节点还原为原值"

# 熔断复查：读不到温度不能当"凉了"，否则一次 EIO 就解开熔断、下一轮又熔断
rm -f /sys/class/thermal/thermal_zone1/temp /sys/class/power_supply/battery/temp
eq "$(g7 sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_zone_scan; sd_guard_cooled; echo $?')" "1" \
   "熔断复查读不到温度：维持熔断"
printf '38000\n' >/sys/class/thermal/thermal_zone1/temp
eq "$(g7 sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_zone_scan; sd_guard_cooled; echo $?')" "0" \
   "熔断复查 38℃：正常解除"

# 没有电池节点时，兜底候选不能选 WiFi / PA —— 它们正常就 90℃+
rm -rf /sys/class/thermal/thermal_zone*
mkzone thermal_zone0 mtktswmt 95000
eq "$(g7 sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_zone_scan; sd_sentinel_guard; echo $?')" "0" \
   "无电池节点：WiFi 95℃ 不触发熔断"

# 单芯时电芯数不能被 sd_ps_attr_v 留在 _sd_rv 里的微伏值污染
# 前面把 cells_mode 设成 2 了，这里先恢复 auto
g7 sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_state_set cells_mode auto' >/dev/null 2>&1
rm -rf /sys/class/power_supply
mkdir -p /sys/class/power_supply/battery
printf '4400000\n' >/sys/class/power_supply/battery/voltage_now
eq "$(g7 sh -c '. /opt/qc/lib/qc.sh; sd_cells_resolve; echo $_sd_rv')" "1" \
   "单芯：电芯数不被电压值污染"

# 天玑机型：status / capacity / temp / 电流 / 电压 都在 mtk-* 节点下
rm -rf /sys/class/power_supply
mkdir -p /sys/class/power_supply/mtk-battery /sys/class/power_supply/mtk-gauge
printf 'Charging\n' >/sys/class/power_supply/mtk-battery/status
printf '62\n'       >/sys/class/power_supply/mtk-battery/capacity
printf '350\n'      >/sys/class/power_supply/mtk-gauge/temp
printf '8800000\n'  >/sys/class/power_supply/mtk-gauge/voltage_now
printf '2000000\n'  >/sys/class/power_supply/mtk-gauge/current_now
PJ=$(g7 sh -c '. /opt/qc/lib/qc.sh; sd_power_json')
case "$PJ" in *'"mv":8800'*) ok "天玑节点：电压读到 8800mV" ;;
              *) ng "天玑节点：电压 ($(_short "$PJ"))" ;; esac
case "$PJ" in *'"ma":2000'*) ok "天玑节点：电流读到 2000mA" ;;
              *) ng "天玑节点：电流 ($(_short "$PJ"))" ;; esac
case "$PJ" in *'"w":17.60'*) ok "天玑节点：功率 17.60W" ;;
              *) ng "天玑节点：功率 ($(_short "$PJ"))" ;; esac
case "$PJ" in *'"cells":2'*) ok "天玑节点：整包 8.8V 判双芯" ;;
              *) ng "天玑节点：电芯数 ($(_short "$PJ"))" ;; esac
eq "$(g7 sh -c '. /opt/qc/lib/qc.sh; sd_batt_status')" "Charging" "天玑节点：status 走 mtk-battery"

# 并发写两个键：读-改-写不加锁会丢掉其中一个
printf 'temp_mode=static\n' >"$D7/state.conf"
i=0
while [ "$i" -lt 8 ]; do
    g7 sh -c '. /opt/qc/lib/qc.sh; sd_state_set aggr 7' &
    g7 sh -c '. /opt/qc/lib/qc.sh; sd_state_set wall 45' &
    wait
    i=$((i + 1))
done
eq "$(grep -cE '^(aggr=7|wall=45)$' "$D7/state.conf")" "2" "并发写两个键不丢更新"


# ---------------------------------------------------------------- T38 限流档位
# 2.9.5 及之前：wall-8 / wall-3 / wall 三档，墙 42℃ 时 34℃ 就砍到 75%。
# 用户看到的是"离墙还有 8℃，功率已经掉了"，而且三个阈值上每跨一次档
# 充电 IC 就重新调节一次输入电流，曲线像波浪。这里把档位钉死成
# wall-4 / wall-2 / wall，34℃ 必须还是满功率。
echo
echo "===== T38 限流档位贴着墙 ====="
for _m in /sys/class/thermal/*/temp; do umount -l "$_m" 2>/dev/null; done
rm -rf /sys/class/thermal/thermal_zone*
mkzone thermal_zone0 battery 34000
D8=/data/adb/qc-t38
rm -rf "$D8"; mkdir -p "$D8"
printf 'temp_mode=off\nwall=42\ncurr_max=4000\nbattery_limit=48\nsentinel_limit=85\naggr=10\ndefrev=3\n' >"$D8/state.conf"
q8() {
    env SD_DATA=$D8 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 FAKE_PLAT=sm8750 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom \
        sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_zone_scan; sd_curr_target_v; echo $_sd_rv'
}
printf '34000\n' >/sys/class/thermal/thermal_zone0/temp
eq "$(q8)" "4000" "34℃：满功率（旧版此时已砍到 75%）"
printf '37000\n' >/sys/class/thermal/thermal_zone0/temp
eq "$(q8)" "4000" "37℃：仍满功率"
printf '38000\n' >/sys/class/thermal/thermal_zone0/temp
eq "$(q8)" "3000" "38℃：75%（距墙 4℃ 才开始降）"
printf '40000\n' >/sys/class/thermal/thermal_zone0/temp
eq "$(q8)" "2000" "40℃：50%"
printf '42000\n' >/sys/class/thermal/thermal_zone0/temp
eq "$(q8)" "1000" "42℃：25%（撞墙）"
# 墙关掉后联动点退到电池熔断阈值前 4℃（48-4=44），不再是写死的 42
printf 'wall=off\n' >>"$D8/state.conf"
printf '38000\n' >/sys/class/thermal/thermal_zone0/temp
eq "$(q8)" "4000" "墙关闭 + 38℃：不降流（联动点在 44℃）"
printf '44000\n' >/sys/class/thermal/thermal_zone0/temp
eq "$(q8)" "1000" "墙关闭 + 44℃：才降到 25%"


# edge=0：一直顶到墙才降流。墙 42℃ 时 41℃ 仍 100%，42℃ 才 75%。
# 这条是 curredge 0 的核心，破了就等于用户白设。
printf 'wall=42\ncurr_edge=0\n' >>"$D8/state.conf"
printf '41000\n' >/sys/class/thermal/thermal_zone0/temp
eq "$(q8)" "4000" "顶墙模式 41℃：满功率"
printf '42000\n' >/sys/class/thermal/thermal_zone0/temp
eq "$(q8)" "3000" "顶墙模式 42℃：75%"
printf '44000\n' >/sys/class/thermal/thermal_zone0/temp
eq "$(q8)" "2000" "顶墙模式 44℃：50%"
printf '46000\n' >/sys/class/thermal/thermal_zone0/temp
eq "$(q8)" "1000" "顶墙模式 46℃：25%"
# 不能压到熔断线上：48℃ 熔断，t25 最晚只能到 47
printf 'wall=44\n' >>"$D8/state.conf"
printf '43000\n' >/sys/class/thermal/thermal_zone0/temp
eq "$(q8)" "4000" "墙 44℃ + 顶墙模式：43℃ 仍满功率"
printf '45000\n' >/sys/class/thermal/thermal_zone0/temp
eq "$(q8)" "3000" "墙 44℃ + 顶墙模式：45℃ 降到 75%"
printf '47000\n' >/sys/class/thermal/thermal_zone0/temp
eq "$(q8)" "1000" "墙 44℃ + 顶墙模式：47℃ 才到 25%（不压到 48 熔断线）"

# ============================================================ T39 暴力模式 / CPU 伪装
# 两者都是 WebUI 直接调用的组合命令，最容易在改按钮时断掉却没人发现：
# 页面上点得到，命令行却没有对应分支。
echo "===== T39 暴力模式与 CPU 伪装 ====="
for _m in /sys/class/thermal/*/temp; do umount -l "$_m" 2>/dev/null; done
rm -rf /sys/class/thermal/*
mkzone thermal_zone0 cpu-0-0   50000
mkzone thermal_zone1 battery    40000
mkzone thermal_zone2 shell-back 30000

D9=/data/adb/qc-t39
rm -rf "$D9"; mkdir -p "$D9"
printf 'temp_mode=off\nshell_temp=30\nwall=42\naggr=3\ncurr_max=0\ncurr_edge=4\nfast_cap=55\n' >"$D9/state.conf"
q9() {
    env SD_DATA=$D9 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 FAKE_PLAT=sm8750 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom \
        sh /opt/qc/action.sh "$@"
}

eq "$(q9 boost on)" "暴力模式 -> 开启（顶墙才降流 · 档位 10 · 快充阈值 85%）" "boost on 回执"
eq "$(sed -n 's/^curr_edge=//p' "$D9/state.conf")" "0"  "boost on：限流提前量归零"
eq "$(sed -n 's/^aggr=//p'      "$D9/state.conf")" "10" "boost on：档位回满 10"
eq "$(sed -n 's/^fast_cap=//p'  "$D9/state.conf")" "85" "boost on：快充阈值 85%"
eq "$(q9 boost off)" "暴力模式 -> 关闭（距墙 4℃ 降流 · 档位 10 · 快充阈值 55%）" "boost off 回执"
eq "$(sed -n 's/^curr_edge=//p' "$D9/state.conf")" "4"  "boost off：限流提前量回到 4"
eq "$(sed -n 's/^fast_cap=//p'  "$D9/state.conf")" "55" "boost off：快充阈值回到 55%"
case "$(q9 boost xx)" in *用法*) ok "boost 非法参数被拒" ;; *) ng "boost 非法参数被拒" ;; esac

# 守护没跑时 $SD_RUN 可能还不存在。旧版所有节点在"写临时文件"这一步失败，
# 最后报的却是"没有节点被伪装"，被误判成机型不支持。
rm -rf "$D9/run"
eq "$(q9 core 45)" "核心 伪装 -> 45℃" "core 45 回执（SD_RUN 不存在）"
eq "$(sed -n 's/^core_temp=//p' "$D9/state.conf")" "45" "core 45 写入状态"
eq "$(cat /sys/class/thermal/thermal_zone0/temp)" "45000" "core 45：核心节点被顶成 45000"
eq "$(cat /sys/class/thermal/thermal_zone1/temp)" "40000" "core 45：电池温区不动"
case "$(q9 json)" in *'"core":"45"'*) ok "json 带出 core=45" ;;
                     *) ng "json 带出 core ($(_short "$(q9 json)"))" ;; esac
eq "$(q9 core off)" "核心 伪装 -> 关闭" "core off 回执"
eq "$(sed -n 's/^core_temp=//p' "$D9/state.conf")" "off" "core off 写入状态"
eq "$(cat /sys/class/thermal/thermal_zone0/temp)" "50000" "core off：核心节点还原 50000"
case "$(q9 core 15)" in *"20~100"*) ok "core 15 越界被拒" ;; *) ng "core 15 越界被拒" ;; esac

# ============================================================ T39b WebUI 通道读不到温区
# 真实场景：ksu.exec / apatch.exec 的 SELinux 域读不到 /sys/class/thermal，
# 页面上温度正常（走守护缓存），但 core 命令扫到 0 个温区。旧实现直接报
# "没有节点被伪装"，用户会以为机型不支持。正确行为是落状态、留条子、
# 由守护补挂。
echo "===== T39b 执行域读不到温区 ====="
D10=/data/adb/qc-t39b
rm -rf "$D10"; mkdir -p "$D10"
printf 'temp_mode=off\nwall=42\n' >"$D10/state.conf"
q10() {
    env SD_DATA=$D10 SD_ZONE_GLOB=/nonexistent-zone SD_MODDIR=/opt/qc SD_NO_DAEMON=1 \
        FAKE_PLAT=sm8750 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom sh /opt/qc/action.sh "$@"
}
eq "$(q10 core 50)" "核心 伪装 -> 50℃（当前通道读不到温度节点，已交给守护应用）" "读不到温区：命令不报错"
eq "$(sed -n 's/^core_temp=//p' "$D10/state.conf")" "50" "读不到温区：状态照写"
if [ -f "$D10/run/spoof.pending" ]; then ok "读不到温区：留下待落地标记"
else ng "读不到温区：缺待落地标记"; fi

# 守护用自己的域扫温区，补挂必须成功并把标记清掉，否则每 tick 都会重试。
# 先把真实值改成 55℃，挂上之后读到的必须是 50℃ —— 同一个值分不出"挂上了"
# 还是"压根没挂"。
printf '55000\n' >/sys/class/thermal/thermal_zone0/temp
Q10() {
    env SD_DATA=$D10 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 \
        FAKE_PLAT=sm8750 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom \
        sh -c '. /opt/qc/lib/qc.sh; sd_state_load; sd_zone_scan; sd_spoof_pending'
}
Q10 >/dev/null 2>&1
eq "$(cat /sys/class/thermal/thermal_zone0/temp)" "50000" "守护补齐：核心节点被顶成 50000"
if [ -f "$D10/run/spoof.pending" ]; then ng "守护补齐后标记仍残留"
else ok "守护补齐后标记已清"; fi

# 温区表能读但没有 core 类型：这是真的不支持，必须明确说类型缺失，
# 不能再混成"内核禁止挂载"。
q10n() {
    env SD_DATA=$D10 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 \
        FAKE_PLAT=sm8750 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom sh /opt/qc/action.sh "$@"
}
for _m in /sys/class/thermal/*/temp; do umount -l "$_m" 2>/dev/null; done
rm -rf /sys/class/thermal/*
mkzone thermal_zone0 battery 40000
q10n core off >/dev/null 2>&1
eq "$(q10n core 50 | tail -1)" "核心 伪装失败：本机 1 个温区里没有 core 类型" "无 core 温区：报类型缺失"
has "$(q10n core 50)" "action.sh zones" "无 core 温区：提示可用 zones 看全表"
eq "$(q10n zones | tail -1)" "共 1 个温区，core 候选 0 个，哨兵 thermal_zone0" "zones：列出温区数与候选数"

# ============================================================ T39c 温区表解析 + 温度读不到
# GT8 Pro 的现场：check 说"99 个温区"，probe 每一行 ok，core 45 却报
# "99 个温区里没有 core 类型（样例 /sys/.../thermal_zone0|cpullc-0-0→temp缺失）"。
# 样例里带着路径和竖线，说明 ${e%%|*} 压根没切开 —— mksh 把模式里的 |
# 当成"或"，最短匹配是空串，整条原样返回。于是 z 变成"路径|类型"，
# 每个节点都被判成没有 temp。分隔符改冒号之后这类解析不会再翻车。
echo "===== T39c 温区表解析与温度读不到 ====="
qp() {
    env SD_DATA=$D10 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 \
        FAKE_PLAT=sm8850 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom sh /opt/qc/action.sh "$@"
}
rm -rf /sys/class/thermal/*
mkzone thermal_zone0 cpullc-0-0 54800
mkzone thermal_zone1 gpuss-0    48600

# 每一项都必须是"真实存在的路径:类型"：切完能 stat 到目录，且没有残留竖线
_bad=$(qp zones 2>/dev/null >/dev/null; sh -c '. /opt/qc/lib/qc.sh; sd_zone_scan;
    for e in $_sd_zones; do
        z=${e%%:*}
        [ -d "$z" ] || echo "坏路径:$e"
        case "$e" in *"|"*) echo "含竖线:$e" ;; esac
    done' 2>/dev/null)
eq "$_bad" "" "温区表：每项都能切成存在的路径"
eq "$(qp zones | tail -1)" "共 2 个温区，core 候选 2 个，哨兵 battery(ps)" "温区表：core 候选被正确数出来"

# 分类命中、温度读不到（执行域把 temp 挡住的情形）：不能说成"没有 core 类型"，
# 要落状态并交给守护。用目录顶替 temp 文件来模拟"读不到"——
# 换成真实文件时 root 读得到，模拟不出被挡的效果。
for _z in /sys/class/thermal/*; do rm -f "$_z/temp"; mkdir -p "$_z/temp"; done
out=$(qp core 45 2>&1 | tail -1)
has "$out" "已交给守护应用" "温度读不到：交守护而不是报类型缺失"
hasnt "$out" "没有 core 类型" "温度读不到：不再误报成类型缺失"
eq "$(sed -n 's/^core_temp=//p' "$D10/state.conf")" "45" "温度读不到：状态照写"

# 页面结构：按钮少一个 / 跨列类丢了，编译期发现不了，只能在这里钉住
H=/opt/qc/webroot/index.html
for _p in 'id="boost" class="wide"' 'id="coreT"' 'acts button.wide{grid-column:1/-1}' \
          'id="joinQun"' 'id="followAuthor"' 'android.intent.action.VIEW' \
          'coolapk.com/u/27316679'; do
    grep -qF "$_p" "$H" && ok "页面含 $_p" || ng "页面缺 $_p"
done

# ============================================================ T40 残留守护锁
# 现场（OPPO Find X8 Pro / 天玑）：面板"守护停止"，点启动回
# "已有守护在运行(pid=5821)"，日志里既没有"守护启动 pid="，也没有一条 tick
# —— 5821 是重启后被系统进程复用的号，而锁里存的是上一轮异常退出时的旧号码。
# 旧逻辑只做 kill -0，于是整轮开机都在"停止"和"已有守护"之间打转。
echo
echo "===== T40 残留锁：pid 被复用后仍能启动 ====="
D40=/data/adb/qc-t40
rm -rf "$D40"; mkdir -p "$D40/run/daemon.lock"
sleep 600 &
FOREIGN=$!
printf '%s\n' "$FOREIGN" >"$D40/run/daemon.lock/pid"
printf '%s\n' "$FOREIGN" >"$D40/run/daemon.pid"

t40() { env SD_DATA=$D40 SD_MODDIR=/opt/qc FAKE_PLAT=sm8850 FAKE_SOCMFR=Qualcomm \
        FAKE_HW=qcom "$@"; }
t40q() { env SD_DATA=$D40 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 FAKE_PLAT=sm8850 \
        FAKE_SOCMFR=Qualcomm FAKE_HW=qcom "$@"; }

eq "$(t40q sh /opt/qc/action.sh json | grep -o '"daemon":[a-z]*')" \
   '"daemon":false' "被复用的 pid 不算守护"
# 面板靠这一项决定"运行/停止"，判错就是"显示停止、又拒绝启动"的根源
eq "$(t40q sh /opt/qc/action.sh status | grep -c '^守护  *未运行')" \
   "1" "状态条：如实写未运行"

# 拉起：必须能起，且不能顺手杀掉那个陌生进程
out=$(t40 sh /opt/qc/action.sh restart 2>&1)
has "$out" "守护已重启" "残留锁：restart 能真正拉起守护"
kill -0 "$FOREIGN" 2>/dev/null && ok "残留锁：没有误杀被复用的 pid" || ng "残留锁：误杀了陌生进程"
_p=$(cat "$D40/run/daemon.pid" 2>/dev/null)
[ -n "$_p" ] && [ "$_p" != "$FOREIGN" ] && ok "残留锁：pid 文件换成真守护" || ng "pid 文件没更新($_p)"
grep -q '清理残留锁' "$D40/log.txt" 2>/dev/null && ok "日志写明清理了残留锁" || ng "日志没有清理记录"

# 真守护在跑时，第二个实例必须让位，不能把锁抢走
t40 sh /opt/qc/service.sh --daemon >/tmp/t40b.log 2>&1
eq "$(cat "$D40/run/daemon.pid" 2>/dev/null)" "$_p" "第二个实例让位，pid 文件没被改写"
kill -0 "$_p" 2>/dev/null && ok "原守护仍在跑" || ng "原守护被第二个实例挤掉了"

# 停止只清锁，不碰陌生进程
t40 sh -c '. /opt/qc/lib/qc.sh; sd_daemon_stop' >/dev/null 2>&1
kill -0 "$FOREIGN" 2>/dev/null && ok "停止：陌生进程没被 TERM 掉" || ng "停止：误杀了陌生进程"
[ -d "$D40/run/daemon.lock" ] && ng "停止：锁目录残留" || ok "停止：锁目录一起清掉"

# 只剩残留锁（没有真守护）时，停止也必须清干净 —— 这正是"启动失败"的直接原因
mkdir -p "$D40/run/daemon.lock"
printf '%s\n' "$FOREIGN" >"$D40/run/daemon.lock/pid"
printf '%s\n' "$FOREIGN" >"$D40/run/daemon.pid"
t40 sh -c '. /opt/qc/lib/qc.sh; sd_daemon_stop' >/dev/null 2>&1
[ -d "$D40/run/daemon.lock" ] && ng "残留锁：停止后仍留着锁" || ok "残留锁：停止后清干净，下次能起"
kill -0 "$FOREIGN" 2>/dev/null && ok "残留锁：仍然没误杀" || ng "残留锁：误杀"
kill -TERM "$FOREIGN" 2>/dev/null; wait_dead "$FOREIGN"
rm -rf "$D40"

# ---------------------------------------------------------------- T41 息屏快充
# 判据只是"背光是不是 0"。仿真用 SD_BL 指到临时目录，真机是 /sys/class/backlight。
D41=/tmp/qc41; rm -rf "$D41"; mkdir -p "$D41"
B41=/tmp/qc41-bl; rm -rf "$B41"; mkdir -p "$B41/panel0-backlight"
B41F="$B41/panel0-backlight/actual_brightness"
printf '200\n' >"$B41F"

t41() { env SD_DATA=$D41 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 SD_BL=$B41 SD_FB=/nonexistent \
        FAKE_PLAT=sm8850 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom "$@"; }

# 温区重建：哨兵必须是唯一的 battery 且温度确定，否则前面用例留下的
# 多个电池类温区会让 _sd_wall_eff 的对比失去意义。
rm -rf /sys/class/thermal/thermal_zone*
mkzone thermal_zone0 battery 40000
mkdir -p /sys/class/power_supply/battery
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '80\n'       >/sys/class/power_supply/battery/capacity

eq "$(t41 sh -c '. /opt/qc/lib/qc.sh
sd_state_set curr_max 3000; sd_state_set wall 40; sd_state_set curr_edge 0
sd_curr_target_v; echo "$_sd_wall_eff/$_sd_screen_on"')" \
   "40/1" "亮屏：墙不动"

eq "$(t41 sh -c ". /opt/qc/lib/qc.sh
printf '0\n' >'$B41F'
sd_screen_tick
echo \"\$_sd_screen_on\"")" \
   "1" "首次读到 0 仍算亮屏（AOD 防抖）"

eq "$(t41 sh -c ". /opt/qc/lib/qc.sh
printf '0\n' >'$B41F'
sd_screen_tick; sd_screen_tick
sd_state_set curr_max 3000; sd_state_set wall 40; sd_state_set curr_edge 0
sd_curr_target_v; echo \"\$_sd_wall_eff/\$_sd_screen_on\"")" \
   "42/0" "息屏两次：墙 +2℃"

eq "$(t41 sh -c ". /opt/qc/lib/qc.sh
printf '0\n' >'$B41F'
sd_screen_tick; sd_screen_tick
printf '200\n' >'$B41F'
sd_screen_tick
sd_state_set curr_max 3000; sd_state_set wall 40; sd_state_set curr_edge 0
sd_curr_target_v; echo \"\$_sd_wall_eff/\$_sd_screen_on\"")" \
   "40/1" "亮屏立即恢复，不等下一轮"

# 关墙时 wall 本来是 熔断-4=44，+2 变 46 —— 必须夹回 48-3=45
eq "$(t41 sh -c ". /opt/qc/lib/qc.sh
printf '0\n' >'$B41F'
sd_screen_tick; sd_screen_tick
sd_state_set curr_max 3000; sd_state_set wall off; sd_state_set curr_edge 0
sd_curr_target_v; echo \"\$_sd_wall_eff\"")" \
   "45" "关墙+息屏：夹在熔断(48)前 3℃"

eq "$(env SD_DATA=$D41 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 SD_BL=/nonexistent SD_FB=/nonexistent \
       sh -c '. /opt/qc/lib/qc.sh; sd_screen_tick; echo $_sd_screen_on')" \
   "1" "读不到屏幕：按亮屏处理"

# json 要能分开报"开关开着"和"此刻是不是真的息屏"
eq "$(t41 sh /opt/qc/action.sh json | grep -c '"screen":[01],"screen_mode":"[a-z]*"')" \
   "1" "json：屏幕状态与接管模式分开报"

# ---------------------------------------------------------------- T42 电池 NTC 伪装
# 电池是最后一条真实传感器：伪装后温区读到的是假值，熔断必须改读 power_supply，
# 硬上限 46℃ 不开放给用户，到点就撤。
D42=/tmp/qc42; rm -rf "$D42"; mkdir -p "$D42"
t42() { env SD_DATA=$D42 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 SD_BL=/nonexistent SD_FB=/nonexistent \
        FAKE_PLAT=sm8850 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom "$@"; }

for z in /sys/class/thermal/thermal_zone*; do umount -l "$z/temp" 2>/dev/null; done
rm -rf /sys/class/thermal/thermal_zone*
mkzone thermal_zone0 battery 38000
mkdir -p /sys/class/power_supply/battery
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '380\n'       >/sys/class/power_supply/battery/temp

eq "$(t42 sh /opt/qc/action.sh json | grep -o '"batt_spoof":"[a-z0-9]*"')" \
   '"batt_spoof":"off"' "默认：电池 NTC 不伪装"

eq "$(t42 sh /opt/qc/action.sh batt 30 2>&1 | grep -c '真实 38')" \
   "1" "batt 30：回显真实温度"

eq "$(t42 cat /sys/class/thermal/thermal_zone0/temp)" \
   "30000" "batt 30：温区读到 30℃"

eq "$(t42 sh /opt/qc/action.sh json | grep -o '"batt_spoof":"[a-z0-9]*","batt_real":[0-9]*')" \
   '"batt_spoof":"30","batt_real":38' "json：伪装值与真实值分开报"

eq "$(t42 sh -c '. /opt/qc/lib/qc.sh
sd_sentinel_best_v /sys/class/thermal/thermal_zone0 battery; echo $_sd_rv')" \
   "38" "熔断读真实值，不读被伪装的 30"

printf '470\n' >/sys/class/power_supply/battery/temp
eq "$(t42 sh /opt/qc/action.sh batt 35 2>&1 | grep -c '已 ≥ 46')" \
   "1" "真实 47℃：拒绝开启"

eq "$(t42 sh -c '. /opt/qc/lib/qc.sh
sd_state_set temp_mode static
sd_batt_sp_guard >/dev/null 2>&1; echo "$?"')" \
   "1" "真实 47℃：守护自动撤销"

eq "$(t42 cat /sys/class/thermal/thermal_zone0/temp)" \
   "38000" "撤销后温区恢复真实读数"

printf '380\n' >/sys/class/power_supply/battery/temp
eq "$(t42 sh /opt/qc/action.sh batt off 2>&1 | grep -c '关闭')" \
   "1" "batt off：关闭"

eq "$(t42 sh /opt/qc/action.sh thermal off 2>&1 | grep -c '停止')" \
   "1" "thermal off：停 horae"

eq "$(t42 sh /opt/qc/action.sh json | grep -o '"thermal":"[a-z]*"')" \
   '"thermal":"off"' "json：热管理状态"

eq "$(t42 sh /opt/qc/action.sh thermal on 2>&1 | grep -c '开启')" \
   "1" "thermal on：恢复"

# ---------------------------------------------------------------- T44 元模块接管挂载
# Hybrid Mount / Magic Mount / Mountify 都在 metamount（KSU）或 post-mount（APatch）
# 阶段挂载，晚于所有模块的 post-fs-data。这时自己 bind 会被它们的 OverlayFS 覆盖，
# 所以检测到其中任一个在位就只交付 system/，把挂载权让出去。
D44=/tmp/qc44; rm -rf "$D44"; mkdir -p "$D44"
t44() { env SD_DATA=$D44 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 SD_BL=/nonexistent SD_FB=/nonexistent \
        FAKE_PLAT=sm8850 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom "$@"; }
HMD=/data/adb/modules/hybrid_mount
rm -rf "$HMD" /opt/qc/system

eq "$(t44 sh -c '. /opt/qc/lib/qc.sh; sd_mm_active; echo $?')" \
   "1" "没装 Hybrid Mount：不误判"

mkdir -p "$HMD"
eq "$(t44 sh -c '. /opt/qc/lib/qc.sh; sd_mm_active; echo $?')" \
   "0" "识别 Hybrid Mount"

t44 sh /opt/qc/action.sh rebuild >/tmp/t44r.log 2>&1
eq "$(t44 sh -c '. /opt/qc/lib/qc.sh; sd_mount_mode')" \
   "meta" "挂载模式 meta"

eq "$(wc -l <"$D44/mounts.list" 2>/dev/null | tr -d ' ')" \
   "0" "meta 下一条 bind 都不产生"

eq "$(find /opt/qc/system -type f 2>/dev/null | wc -l | tr -d ' ')" \
   "9" "9 个文件交付到 system/"

has "$(cat "$D44/log.txt" 2>/dev/null)" "已交给 Hybrid Mount" "日志写明交给 Hybrid"

has "$(t44 sh /opt/qc/action.sh status 2>&1)" "Hybrid Mount 托管" "status 标出 Hybrid 托管"

printf '' >"$HMD/disable"
eq "$(t44 sh -c '. /opt/qc/lib/qc.sh; sd_mm_active; echo $?')" \
   "1" "disable 的 Hybrid 不接管"
rm -f "$HMD/disable"

rm -rf /opt/qc/system
: >"$D44/nm.list"
eq "$(t44 sh -c '. /opt/qc/lib/qc.sh; sd_mount_mode')" \
   "meta-idle" "没有交付文件时是 meta-idle"

rm -rf "$HMD"

# ---------------------------------------------------------------- T45 Magic Mount / Mountify
# 三家元模块读的是同一个交付区（含 system/ 的模块目录），所以共用一条分支，
# 只有显示名不同。这一组确认名字映射、零 bind、以及没装时的空名字。
D45=/tmp/qc45; rm -rf "$D45"; mkdir -p "$D45"
t45() { env SD_DATA=$D45 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 SD_BL=/nonexistent SD_FB=/nonexistent \
        FAKE_PLAT=sm8850 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom "$@"; }
MD=/data/adb/modules
rm -rf "$MD/meta-magic_mount" "$MD/meta-magic_mount-rs" "$MD/meta-mm" "$MD/magic_mount" "$MD/mountify" /opt/qc/system
rm -rf "$D45"; mkdir -p "$D45"

eq "$(t45 sh -c '. /opt/qc/lib/qc.sh; sd_mm_active; echo $?')" \
   "1" "Magic Mount / Mountify 都没装：不接管"
eq "$(t45 sh -c '. /opt/qc/lib/qc.sh; sd_mm_name' 2>/dev/null)" \
   "" "没接管时名字为空"

mkdir -p "$MD/meta-magic_mount"
eq "$(t45 sh -c '. /opt/qc/lib/qc.sh; sd_mm_name')" \
   "Magic Mount" "meta-magic_mount -> Magic Mount"
rm -rf "$MD/meta-magic_mount"

mkdir -p "$MD/meta-mm"
eq "$(t45 sh -c '. /opt/qc/lib/qc.sh; sd_mm_name')" \
   "Magic Mount" "meta-mm -> Magic Mount"
rm -rf "$MD/meta-mm"

mkdir -p "$MD/mountify"
eq "$(t45 sh -c '. /opt/qc/lib/qc.sh; sd_mm_name')" \
   "Mountify" "mountify -> Mountify"

t45 sh /opt/qc/action.sh rebuild >/dev/null 2>&1
eq "$(t45 sh -c '. /opt/qc/lib/qc.sh; sd_mount_mode')" \
   "meta" "Mountify 在位：挂载模式 meta"
eq "$(wc -l <"$D45/mounts.list" 2>/dev/null | tr -d ' ')" \
   "0" "Mountify 下一条 bind 都不产生"
eq "$(find /opt/qc/system -type f 2>/dev/null | wc -l | tr -d ' ')" \
   "9" "9 个文件交付到 system/"

has "$(cat "$D45/log.txt" 2>/dev/null)" "已交给 Mountify" "日志写明交给 Mountify"
has "$(t45 sh /opt/qc/action.sh status 2>&1)" "Mountify 托管" "status 标出 Mountify 托管"
eq "$(t45 sh /opt/qc/action.sh json | grep -o '"mm_name":"[^"]*"')" \
   '"mm_name":"Mountify"' "json 带 mm_name"

printf '' >"$MD/mountify/disable"
eq "$(t45 sh -c '. /opt/qc/lib/qc.sh; sd_mm_active; echo $?')" \
   "1" "disable 的 Mountify 不接管"
eq "$(t45 sh -c '. /opt/qc/lib/qc.sh; sd_mount_mode')" \
   "none" "停用后不再算 meta（本轮没有 bind）"
rm -f "$MD/mountify/disable"

rm -rf "$MD/mountify" /opt/qc/system
: >"$D45/nm.list"
eq "$(t45 sh /opt/qc/action.sh json | grep -o '"mm_name":"[^"]*"')" \
   '"mm_name":""' "没元模块时 json 的 mm_name 为空"

# ---------------------------------------------------------------- T46 伪装落点挪出 /data/adb
# 假温度文件原来写在 /data/adb/quickcharge/run，bind 之后 mountinfo 第 4 段就是
# /adb/quickcharge/run/xxx.temp，普通 App 读 mountinfo 就能看见这个 root 目录。
# 改放 tmpfs（默认 /dev/qc）：记录变成 tmpfs /qc/xxx.temp。目录 700 挡列目录，
# 文件必须 644 —— 读方不一定是 root，收紧到 600 会让伪装"成功但没人读到"。
D46=/tmp/qc46; rm -rf "$D46"; mkdir -p "$D46"
t46() { env SD_DATA=$D46 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 SD_BL=/nonexistent SD_FB=/nonexistent \
        SD_SPOOF_DIR="$D46/spoof" FAKE_PLAT=sm8850 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom "$@"; }
t46f() { env SD_DATA=$D46 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 SD_BL=/nonexistent SD_FB=/nonexistent \
         SD_SPOOF_DIR=/proc/qc-nope SD_SPOOF_DEF=/proc/qc-nope \
         FAKE_PLAT=sm8850 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom "$@"; }

for z in /sys/class/thermal/thermal_zone*; do umount -l "$z/temp" 2>/dev/null; done
rm -rf /sys/class/thermal/thermal_zone* /dev/qc
mkzone thermal_zone0 battery 38000
mkdir -p /sys/class/power_supply/battery
printf '380\n' >/sys/class/power_supply/battery/temp

t46 sh /opt/qc/action.sh batt 30 >/dev/null 2>&1
eq "$(cat /sys/class/thermal/thermal_zone0/temp)" "30000" "改落点后伪装照旧生效"
eq "$(ls "$D46/spoof" 2>/dev/null | tr -d '\n')" "thermal_zone0.temp" "临时文件落在指定目录"
eq "$(stat -c %a "$D46/spoof" 2>/dev/null)" "700" "落点目录 700"
eq "$(stat -c %a "$D46/spoof/thermal_zone0.temp" 2>/dev/null)" "644" "临时文件 644（读方不一定是 root）"
eq "$(ls "$D46/run"/*.temp 2>/dev/null | wc -l | tr -d ' ')" "0" "不再写进 /data/adb 下的 run"
has "$(grep -F 'thermal_zone0/temp ' /proc/self/mountinfo 2>/dev/null)" \
    "$D46/spoof/thermal_zone0.temp" "mountinfo 的源路径就是落点"

t46 sh /opt/qc/action.sh batt off >/dev/null 2>&1
eq "$(cat /sys/class/thermal/thermal_zone0/temp)" "38000" "撤销后回真实读数"
eq "$(ls -A "$D46/spoof" 2>/dev/null | wc -l | tr -d ' ')" "0" "撤销后临时文件清掉"

# 落点全不可用（只读分区、SELinux 拒绝）→ 回退 run，功能不能丢
t46f sh -c '. /opt/qc/lib/qc.sh; sd_zone_scan; sd_spoof_apply batt 31' >/dev/null 2>&1
eq "$(cat /sys/class/thermal/thermal_zone0/temp)" "31000" "落点不可用：回退 run 也能伪装"
eq "$(ls "$D46/run"/*.temp 2>/dev/null | wc -l | tr -d ' ')" "1" "回退时写进 run"
t46f sh -c '. /opt/qc/lib/qc.sh; sd_spoof_clear' >/dev/null 2>&1

# 不指定落点：默认 /dev/qc，mountinfo 里不该再有 /adb/
env -u SD_SPOOF_DIR SD_DATA=$D46 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 SD_BL=/nonexistent SD_FB=/nonexistent \
    FAKE_PLAT=sm8850 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom sh /opt/qc/action.sh batt 32 >/dev/null 2>&1
eq "$(stat -c %a /dev/qc 2>/dev/null)" "700" "默认落点 /dev/qc，目录 700"
eq "$(cat /dev/qc/thermal_zone0.temp 2>/dev/null)" "32000" "默认落点写出假温度"
hasnt "$(grep -F 'thermal_zone0/temp ' /proc/self/mountinfo 2>/dev/null)" "/adb/" \
      "mountinfo 里不再出现 /adb/"

# 卸载要顺手清掉落点目录，否则留下一个空目录
SD_DATA=$D46 SD_MODDIR=/opt/qc sh /opt/qc/uninstall.sh >/dev/null 2>&1
eq "$(ls -d /dev/qc 2>/dev/null | wc -l | tr -d ' ')" "0" "卸载脚本清掉落点目录"
eq "$(cat /sys/class/thermal/thermal_zone0/temp)" "38000" "卸载后温区回真实读数"

# ---------------------------------------------------------------- T47 亮屏快充
# 亮屏掉功率的落点在 kernel fb_notifier：亮屏 → reset_max_fcc_ma(SCREEN_ON_MAX_FCC_MA)。
# 模块两条路：写 ignore_screen_state；没有就记住息屏时的 FCC，亮屏被压低后写回。
D47=/tmp/qc47; rm -rf "$D47"; mkdir -p "$D47/bl"
printf '200\n' >"$D47/bl/brightness"
t47() { env SD_DATA=$D47 SD_MODDIR=/opt/qc SD_NO_DAEMON=1 SD_BL="$D47/bl" SD_FB=/nonexistent \
        SD_SPOOF_DIR="$D47/spoof" FAKE_PLAT=sm8850 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom "$@"; }

rm -rf /sys/module/oplus_chg
mkdir -p /sys/class/power_supply/battery
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '380\n' >/sys/class/power_supply/battery/temp
printf '6000000\n' >/sys/class/power_supply/battery/constant_charge_current_max

# A. 有 ignore_screen_state：直接置 1，切「关闭」模式还原
mkdir -p /sys/module/oplus_chg/parameters
printf '0\n' >/sys/module/oplus_chg/parameters/ignore_screen_state
t47 sh -c '. /opt/qc/lib/qc.sh; sd_state_set temp_mode charge; sd_scr_tick' >/dev/null 2>&1
eq "$(cat /sys/module/oplus_chg/parameters/ignore_screen_state)" "1" "有内核参数：置 1 接管"
t47 sh -c '. /opt/qc/lib/qc.sh; sd_state_set temp_mode off; sd_scr_tick' >/dev/null 2>&1
eq "$(cat /sys/module/oplus_chg/parameters/ignore_screen_state)" "0" "切关闭模式：参数还原 0"
hasnt "$(cat "$D47/run/scr.orig" 2>/dev/null)" "ignore" "退出后临时备份已清"

# B. 没有该参数：息屏学基准，亮屏被压后写回
rm -rf /sys/module/oplus_chg
t47 sh -c '. /opt/qc/lib/qc.sh; sd_state_set temp_mode charge; _sd_screen_on=0; sd_scr_tick' >/dev/null 2>&1
eq "$(cat "$D47/run/fcc.norm" 2>/dev/null)" "6000" "息屏充电：记录基准 6000mA"
printf '2000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
t47 sh -c '. /opt/qc/lib/qc.sh; sd_state_set temp_mode charge; _sd_screen_on=1; sd_scr_tick' >/dev/null 2>&1
eq "$(cat /sys/class/power_supply/battery/constant_charge_current_max)" "6000000" "亮屏被压到 2A 后写回 6A"
eq "$(t47 sh /opt/qc/action.sh json | grep -o '"screen_mode":"[^"]*"')" \
   '"screen_mode":"fcc"' "json 报 fcc 模式"

# C. 电池 43℃：不接管
printf '430\n' >/sys/class/power_supply/battery/temp
printf '2000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
rm -f "$D47/run/scr.orig" "$D47/run/scr.way"
t47 sh -c '. /opt/qc/lib/qc.sh; sd_state_set temp_mode charge; _sd_screen_on=1; sd_scr_tick' >/dev/null 2>&1
eq "$(cat /sys/class/power_supply/battery/constant_charge_current_max)" "2000000" "43℃ 不接管"

# D. 用户自己开了限流：两边都写同一节点，让限流优先
printf '380\n' >/sys/class/power_supply/battery/temp
t47 sh -c '. /opt/qc/lib/qc.sh; sd_state_set curr_max 3000; _sd_screen_on=1; sd_scr_tick' >/dev/null 2>&1
eq "$(cat /sys/class/power_supply/battery/constant_charge_current_max)" "2000000" "开了限流就不接管"

# E. 拔线：立即还原
t47 sh -c '. /opt/qc/lib/qc.sh; sd_state_set curr_max 0; _sd_screen_on=1; sd_scr_tick' >/dev/null 2>&1
eq "$(cat /sys/class/power_supply/battery/constant_charge_current_max)" "6000000" "接管后恢复原值 6A"
printf 'Discharging\n' >/sys/class/power_supply/battery/status
printf '2000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
t47 sh -c '. /opt/qc/lib/qc.sh; _sd_screen_on=1; sd_scr_tick' >/dev/null 2>&1
eq "$(cat /sys/class/power_supply/battery/constant_charge_current_max)" "2000000" "未充电不接管"
printf 'Charging\n' >/sys/class/power_supply/battery/status

# F. 卸载：参数归零 + 按备份还原
mkdir -p /sys/module/oplus_chg/parameters
printf '1\n' >/sys/module/oplus_chg/parameters/ignore_screen_state
printf '/sys/module/oplus_chg/parameters/ignore_screen_state|0\n' >"$D47/run/scr.orig"
SD_DATA=$D47 SD_MODDIR=/opt/qc sh /opt/qc/uninstall.sh >/dev/null 2>&1
eq "$(cat /sys/module/oplus_chg/parameters/ignore_screen_state)" "0" "卸载后屏幕状态参数归 0"

# G. 只暴露 usb/current_max 的机型（模块限流本来也走这个节点）
D47b=/tmp/qc47b; rm -rf "$D47b"; mkdir -p "$D47b/bl" "$D47b/run"
printf '200\n' >"$D47b/bl/brightness"
rm -rf /sys/module/oplus_chg
rm -f /sys/class/power_supply/battery/constant_charge_current_max
mkdir -p /sys/class/power_supply/usb
printf '6000000\n' >/sys/class/power_supply/usb/current_max
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '380\n' >/sys/class/power_supply/battery/temp
t47b() { env SD_DATA=$D47b SD_MODDIR=/opt/qc SD_NO_DAEMON=1 SD_BL="$D47b/bl" SD_FB=/nonexistent \
         SD_CURR_NODES=/sys/class/power_supply/usb/current_max \
         FAKE_PLAT=sm8850 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom "$@"; }
t47b sh -c '. /opt/qc/lib/qc.sh; sd_state_set temp_mode charge; _sd_screen_on=0; sd_scr_tick' >/dev/null 2>&1
eq "$(cat "$D47b/run/fcc.norm" 2>/dev/null)" "6000" "只有 usb 节点：也记基准 6000mA"
printf '2000000\n' >/sys/class/power_supply/usb/current_max
t47b sh -c '. /opt/qc/lib/qc.sh; sd_state_set temp_mode charge; _sd_screen_on=1; sd_scr_tick' >/dev/null 2>&1
eq "$(cat /sys/class/power_supply/usb/current_max)" "6000000" "只有 usb 节点：亮屏写回 6A"
t47b sh -c '. /opt/qc/lib/qc.sh; sd_state_set temp_mode off; _sd_screen_on=1; sd_scr_tick' >/dev/null 2>&1
eq "$(cat /sys/class/power_supply/usb/current_max)" "2000000" "切关闭模式：usb 节点还原 2A"

# H. 常开：状态文件里什么都没写，也要接管
D47c=/tmp/qc47c; rm -rf "$D47c"; mkdir -p "$D47c/bl"
printf '200\n' >"$D47c/bl/brightness"
rm -rf /sys/module/oplus_chg
mkdir -p /sys/class/power_supply/battery
printf '6000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
printf 'Charging\n' >/sys/class/power_supply/battery/status
printf '380\n' >/sys/class/power_supply/battery/temp
t47c() { env SD_DATA=$D47c SD_MODDIR=/opt/qc SD_NO_DAEMON=1 SD_BL="$D47c/bl" SD_FB=/nonexistent \
         SD_CURR_NODES=/sys/class/power_supply/battery/constant_charge_current_max \
         FAKE_PLAT=sm8850 FAKE_SOCMFR=Qualcomm FAKE_HW=qcom "$@"; }

t47c sh -c '. /opt/qc/lib/qc.sh; sd_state_set temp_mode charge' >/dev/null 2>&1
hasnt "$(t47c sh /opt/qc/action.sh json 2>/dev/null)" "screen_boost" "常开：不再输出开关字段"

t47c sh -c '. /opt/qc/lib/qc.sh; _sd_screen_on=0; sd_scr_tick' >/dev/null 2>&1
eq "$(cat "$D47c/run/fcc.norm" 2>/dev/null)" "6000" "默认开启：息屏自动记基准"
printf '2000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
t47c sh -c '. /opt/qc/lib/qc.sh; _sd_screen_on=1; sd_scr_tick' >/dev/null 2>&1
eq "$(cat /sys/class/power_supply/battery/constant_charge_current_max)" "6000000" \
   "默认开启：亮屏自动写回 6A"

# 43℃：两条路径都不接管，且不能写成「本机不支持」
printf '430\n' >/sys/class/power_supply/battery/temp
printf '2000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
rm -f "$D47c/run/scr.orig" "$D47c/run/scr.way" "$D47c/run/scr.fail"
t47c sh -c '. /opt/qc/lib/qc.sh; _sd_screen_on=1; sd_scr_tick' >/dev/null 2>&1
eq "$(cat /sys/class/power_supply/battery/constant_charge_current_max)" "2000000" "默认开启：43℃ 不接管"
hasnt "$(cat "$D47c/run/scr.fail" 2>/dev/null)" "1" "高温只暂停，不标记本机不支持"
eq "$(t47c sh /opt/qc/action.sh json 2>/dev/null | grep -o '"screen_mode":"[a-z]*"')" \
   '"screen_mode":"idle"' "高温时面板不报不支持"

mkdir -p /sys/module/oplus_chg/parameters
printf '0\n' >/sys/module/oplus_chg/parameters/ignore_screen_state
t47c sh -c '. /opt/qc/lib/qc.sh; _sd_screen_on=1; sd_scr_tick' >/dev/null 2>&1
eq "$(cat /sys/module/oplus_chg/parameters/ignore_screen_state)" "0" "内核参数路径：43℃ 也不写 1"

# 温度降回来要能重新接管
printf '380\n' >/sys/class/power_supply/battery/temp
printf '2000000\n' >/sys/class/power_supply/battery/constant_charge_current_max
t47c sh -c '. /opt/qc/lib/qc.sh; _sd_screen_on=1; sd_scr_tick' >/dev/null 2>&1
eq "$(cat /sys/module/oplus_chg/parameters/ignore_screen_state)" "1" "降温后恢复接管（内核参数）"
rm -rf /sys/module/oplus_chg

# 失败清单放在最后统一列一遍：滚动日志里翻不到的那几条，这里能一次看全
if [ "$FAIL" -gt 0 ]; then
    printf '\n===== 失败清单 =====\n%s' "$FAILED"
fi
echo "===== 结果: PASS=$PASS FAIL=$FAIL 用时=$(( $(date +%s) - T0 ))s ====="
[ "$FAIL" -eq 0 ]
