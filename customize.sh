#!/system/bin/sh
# ---------------------------------------------------------------
# Quick Charge (QC) — 源码完全公开，可自由查看、修改、分发。
# 禁止商业用途，禁止用于任何违反法律法规的场景。
# Fully open source. Commercial use and any unlawful use prohibited.
# ---------------------------------------------------------------

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
ui_print "  Quick Charge  v$(sd_prop_get version)"
ui_print "  by Xiaohao"
ui_print "*******************************"

DEV_MFR=$(getprop ro.product.odm.manufacturer)
[ -n "$DEV_MFR" ] || DEV_MFR=$(getprop ro.product.vendor.manufacturer)
[ -n "$DEV_MFR" ] || DEV_MFR=$(getprop ro.product.manufacturer)
DEV_MODEL=$(getprop ro.vendor.oplus.market.name)
DEV_SOC=$(getprop ro.soc.model | tr 'a-z' 'A-Z')

ui_print "- 机型  ${DEV_MODEL:-未知} ($(getprop ro.product.model)) · ${DEV_SOC:-未知} · Android $(getprop ro.build.version.release)"

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

ui_print "- 扫描温控 / 充电配置…"
sd_state_load
# 描述里的状态靠这个标记区分「刚装完等重启」和「装好了却没跑起来」，
# 开机后由 post-fs-data 清掉；写失败也不影响功能，只是退化成靠 boot 时间判断。
# 必须写在 sd_sync_desc 之前，否则描述会先按旧状态刷一遍。
mkdir -p "$SD_DATA" 2>/dev/null
date +%s >"$SD_DATA/need_reboot" 2>/dev/null || : >"$SD_DATA/need_reboot"
sd_zone_scan
sd_umount_overrides
rm -f "$SD_BUILT"
sd_build_overrides

n=$(find "$SD_OVERRIDES" -type f 2>/dev/null | wc -l | tr -d ' ')
nm_n=0
nm_tag=""

# sd_nm_mirror 返回 2 有两种含义：有东西要镜像却没写进去（真失败），
# 以及一个覆盖文件都没产出（无事可做）。后者在源配置缺失的机器上很常见，
# 报"写入失败"会让人以为模块坏了，所以只在 n>0 时才当失败报。
if sd_nm_active; then
    sd_nm_mirror
    rc=$?
    if [ "$rc" -ne 2 ]; then
        nm_n=$(wc -l <"$SD_NM_LIST" 2>/dev/null | tr -d ' ')
        nm_tag="NoMount"
    elif [ "${n:-0}" -gt 0 ]; then
        ui_print "! NoMount 写入失败，重启后改用 bind mount"
    fi
elif sd_mm_active; then
    mmn=$(sd_mm_name)
    sd_nm_mirror
    rc=$?
    if [ "$rc" -ne 2 ]; then
        nm_n=$(wc -l <"$SD_NM_LIST" 2>/dev/null | tr -d ' ')
        nm_tag="$mmn"
    elif [ "${n:-0}" -gt 0 ]; then
        ui_print "! $mmn 写入失败，重启后改用 bind mount"
    fi
fi

SD_DEFAULTS="temp_mode=charge
shell_temp=25
core_temp=off
noncore_temp=off
chg_unlock=0
curve_offset=120
hz=off
power_scale=100
cells_mode=auto
off_manual=0
log_level=1
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
if [ "$defrev" -lt 4 ]; then
    # 3.1.0 起不再有温度墙/熔断/限流这组参数：常量伪装代替了整套退让逻辑。
    # 旧 state.conf 里的键留着只会让人误以为还能调，升级时直接清掉。
    for _k in aggr wall fast_cap sentinel_limit battery_limit curr_max curr_edge cool_guard; do
        grep -q "^$_k=" "$SD_STATE" 2>/dev/null && sed -i "/^$_k=/d" "$SD_STATE"
    done
    # 旧的 30~60℃ 基准在新模型里太高，统一收到 25℃（用户手动改过的 20~33 保留）
    _sh=$(sd_state_get shell_temp 25)
    case "$_sh" in
        ''|*[!0-9]*) sd_state_set shell_temp 25 ;;
        *) [ "$_sh" -gt 33 ] && sd_state_set shell_temp 25 ;;
    esac
    sd_state_set defrev 4
fi

[ "$(sd_state_get temp_mode off)" = "dyn" ] && {
    sd_state_set temp_mode static
    ui_print "- 旧 dyn 模式已并入 static"
}

case "$(sd_state_get temp_mode off)" in
    charge) tm_text="仅充电时改写 · 重启后自动启动" ;;
    static) tm_text="全场景改写 · 重启后自动启动" ;;
    off)    tm_text="已关闭 · 可在面板打开" ;;
    *)      tm_text="未知" ;;
esac

[ -f "$MODPATH/bin/qcmon" ] && chmod 755 "$MODPATH/bin/qcmon" 2>/dev/null

printf '%s\n' "$MODDIR" 2>/dev/null >"$SD_DATA/moddir"

for m in /data/adb/modules/*; do
    [ -f "$m/module.prop" ] || continue
    [ "$(basename "$m")" = "$(basename "$MODDIR")" ] && continue
    if grep -qE '墓碑|温控|采样率|快充|充电守护|满血' "$m/module.prop" 2>/dev/null; then
        ui_print "! 检测到可能冲突的模块: $(sd_prop_get name "$m/module.prop")"
    fi
done

sd_sync_desc

if [ "${n:-0}" -eq 0 ]; then
    ui_print "- 无可改写配置 · 运行期温度伪装照常生效"
elif [ "${nm_n:-0}" -gt 0 ]; then
    ui_print "- 覆盖  $n 个配置 · ${nm_tag:-NoMount} 接管 $nm_n 个"
else
    ui_print "- 覆盖  $n 个配置（bind mount）"
fi
ui_print "- 温控  $tm_text"
ui_print "- 反馈  QQ 群（浏览器自动打开）"
ui_print "- 完成，重启后生效"
sd_dbg install "QQ群 $SD_QQ_URL"

if command -v am >/dev/null 2>&1; then
    ( am start -a android.intent.action.VIEW \
        -d "$SD_QQ_URL" >/dev/null 2>&1 ) &
    sleep 1
fi
