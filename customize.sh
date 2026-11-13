#!/system/bin/sh

SKIPMOUNT=true
PROPFILE=false
POSTFSDATA=true
LATESTARTSERVICE=true

MODDIR="${MODPATH:-}"
if [ -z "$MODDIR" ] || [ ! -f "$MODDIR/lib/qc.sh" ]; then
    MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd)
    [ -f "${MODDIR:-/nonexistent}/lib/qc.sh" ] || MODDIR=$(pwd)
fi
[ -f "$MODDIR/lib/qc.sh" ] || { echo "找不到 lib/qc.sh" >&2; exit 1; }
. "$MODDIR/lib/qc.sh"

SD_VERBOSE=

SD_QQ_URL="https://qun.qq.com/universal-share/share?ac=1&authKey=sxretTuuUbT6DSq6WUsRcAhqpzEtEmLdUgjcJW5EFkih769NPI7mFOtBWBsiLb56&busi_data=eyJncm91cENvZGUiOiIxMDAzNDgxNjYwIiwidG9rZW4iOiJnaGZRMVVNSCtOZFNyWUV4cEk2bU9Jd05neVpwUmVkOTIxV3VpcVRwS2Iram1rNC81TmtnNUJ3MjRxYm9JcGJEIiwidWluIjoiMjExMTgzNTIyMCJ9&data=Gr9CwynFwy41T0Lgv3epv7_E3bgXVe1lKsqwWOnF338a3I7veanebrcFNu2aJI8_5AZAHr7NXTdhgkf2iFtq-g&svctype=4&tempid=h5_group_info"

ui_print "*******************************"
ui_print "  Quick Charge (QC)  v$(grep '^version=' "$MODDIR/module.prop" | cut -d= -f2)"
ui_print "  by Xiaohao"
ui_print "  代码由 AI 辅助完成"
ui_print "*******************************"

DEV_MFR=$(getprop ro.product.odm.manufacturer)
[ -n "$DEV_MFR" ] || DEV_MFR=$(getprop ro.product.vendor.manufacturer)
[ -n "$DEV_MFR" ] || DEV_MFR=$(getprop ro.product.manufacturer)
DEV_MODEL=$(getprop ro.vendor.oplus.market.name)
DEV_SOC=$(getprop ro.soc.model | tr 'a-z' 'A-Z')

ui_print "- 机型: ${DEV_MODEL:-未知} ($(getprop ro.product.model))"
ui_print "- 平台: ${DEV_SOC:-未知} · Android $(getprop ro.build.version.release) · 补丁 $(getprop ro.build.version.security_patch)"

case "$DEV_MFR" in
    OPPO|oppo|OnePlus|oneplus|realme|Realme) ;;
    *)
        ui_print "! 仅支持 OPPO / 一加 / realme（ColorOS / RealmeUI）"
        ui_print "! 当前厂商: ${DEV_MFR:-未知}"
        command -v abort >/dev/null 2>&1 && abort "不支持的机型，已中止安装"
        exit 1
        ;;
esac

for bin in mount umount sed awk; do
    command -v "$bin" >/dev/null 2>&1 || { ui_print "! 缺少 $bin，中止安装"; exit 1; }
done

ui_print "- 扫描并改写系统温控/充电配置…"
sd_state_load
sd_zone_scan
sd_umount_overrides
rm -f "$SD_BUILT"
sd_build_overrides

n=$(find "$SD_OVERRIDES" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" -eq 0 ]; then
    ui_print "! 未匹配到可改写的配置文件"
    ui_print "! 模块仍会安装，但只有运行时温度伪装可用"
else
    ui_print "- 已生成 $n 个覆盖文件"
fi

if sd_nm_active; then
    sd_nm_mirror
    rc=$?
    if [ "$rc" -ne 2 ]; then
        nl=$(wc -l <"$SD_NM_LIST" 2>/dev/null | tr -d ' ')
        ui_print "- NoMount 注入文件 ${nl:-0} 个（无挂载）"
    else
        ui_print "! NoMount 镜像写入失败，重启后会改用 bind mount"
    fi
elif sd_mm_active; then
    mmn=$(sd_mm_name)
    sd_nm_mirror
    rc=$?
    if [ "$rc" -ne 2 ]; then
        nl=$(wc -l <"$SD_NM_LIST" 2>/dev/null | tr -d ' ')
        ui_print "- $mmn 交付文件 ${nl:-0} 个（重启后由它挂载）"
    else
        ui_print "! $mmn 镜像写入失败，重启后会改用 bind mount"
    fi
fi

SD_DEFAULTS="temp_mode=charge
shell_temp=30
core_temp=off
noncore_temp=off
horae=1
sentinel_limit=85
battery_limit=48
fast_cap=55
curve_offset=120
wall=42
aggr=10
curr_max=0
hz=off
power_scale=100
cells_mode=auto
off_manual=0
log_level=3
tick=15"

[ -f "$SD_STATE" ] || : >"$SD_STATE"
OLD_IFS=$IFS
IFS='
'
for kv in $SD_DEFAULTS; do
    [ -n "$kv" ] || continue
    k=${kv%%=*}
    v=${kv#*=}
    case "$v" in *" "*) ui_print "! 内部错误：默认值格式异常，跳过 $k"; continue ;; esac
    grep -q "^$k=" "$SD_STATE" 2>/dev/null || sd_state_set "$k" "$v"
done
IFS=$OLD_IFS

_sd_st_loaded=0
if grep -q '^defrev=' "$SD_STATE" 2>/dev/null; then
    defrev=$(sd_state_get defrev 3)
    case "$defrev" in ''|*[!0-9]*) defrev=3 ;; esac
else
    sd_state_set defrev 3
    defrev=3
fi
if [ "$defrev" -lt 2 ]; then
    migrated=""
    [ "$(sd_state_get wall off)" = "off" ] && { sd_state_set wall 42; migrated="$migrated wall"; }
    [ "$(sd_state_get aggr 5)" = "5" ] && { sd_state_set aggr 10; migrated="$migrated aggr"; }
    [ "$(sd_state_get shell_temp 0)" = "0" ] && { sd_state_set shell_temp 30; migrated="$migrated shell_temp"; }
    sd_state_set defrev 2
    [ -n "$migrated" ] && ui_print "- 切换到新默认: 42℃ 以下最猛（$migrated）"
fi
if [ "$defrev" -lt 3 ]; then
    if [ "$(sd_state_get temp_mode off)" = "off" ] \
        && [ "$(sd_state_get off_manual 0)" = "0" ]; then
        sd_state_set temp_mode charge
        ui_print "- 默认改为「仅充电」自动生效，插电即改写、拔电即还原"
    fi
    sd_state_set defrev 3
fi

[ "$(sd_state_get temp_mode off)" = "dyn" ] && {
    sd_state_set temp_mode static
    ui_print "- 旧 dyn 模式已并入 static"
}

case "$(sd_state_get temp_mode off)" in
    charge) ui_print "- 温度改写: 仅充电时生效，重启后自动启动" ;;
    static) ui_print "- 温度改写: 全场景生效，重启后自动启动" ;;
    off)    ui_print "- 温度改写: 已关闭，可在 WebUI 打开" ;;
esac

ui_print "- 亮屏快充: 内置常开，亮屏不再按屏幕状态降档；息屏保留 +2℃"

printf '%s\n' "$MODDIR" 2>/dev/null >"$SD_DATA/moddir"

for m in /data/adb/modules/*; do
    [ -f "$m/module.prop" ] || continue
    [ "$(basename "$m")" = "$(basename "$MODDIR")" ] && continue
    if grep -qE '墓碑|温控|采样率|快充|充电守护|满血' "$m/module.prop" 2>/dev/null; then
        ui_print "! 检测到可能冲突的模块: $(grep '^name=' "$m/module.prop" | cut -d= -f2-)"
    fi
done

sd_sync_desc

ui_print "- 安装完成，重启后生效"
ui_print "    状态: sh $MODDIR/action.sh status"
ui_print "    配置: sh $MODDIR/action.sh temp static     # 开温度伪装"
ui_print "- 作者: Xiaohao ｜ QQ群: 点击链接加入群聊【Quick Charge】"
sd_dbg install "QQ群 $SD_QQ_URL"

if command -v am >/dev/null 2>&1; then
    ( am start -a android.intent.action.VIEW \
        -d "$SD_QQ_URL" >/dev/null 2>&1 ) &
    sleep 1
fi
