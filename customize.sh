#!/system/bin/sh
# 安装脚本。只做设备检测、生成覆盖层、初始化参数，不做交互（菜单在 action.sh）。

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

SD_VERBOSE=1

ui_print "*******************************"
ui_print "  Quick Charge (QC)  v$(grep '^version=' "$MODDIR/module.prop" | cut -d= -f2)"
ui_print "  by https://github.com/XiaohaoQvQ"
ui_print "  代码由 AI 辅助完成"
ui_print "*******************************"

# ---------- 设备 ----------

DEV_MFR=$(getprop ro.product.odm.manufacturer)
# 部分机型 odm 属性为空，逐级回退，避免把欧加真误判成"其他厂商"直接拦掉
[ -n "$DEV_MFR" ] || DEV_MFR=$(getprop ro.product.vendor.manufacturer)
[ -n "$DEV_MFR" ] || DEV_MFR=$(getprop ro.product.manufacturer)
DEV_MODEL=$(getprop ro.vendor.oplus.market.name)
DEV_SOC=$(getprop ro.soc.model | tr 'a-z' 'A-Z')

ui_print "- 机型 : ${DEV_MODEL:-未知} ($(getprop ro.product.model))"
ui_print "- 厂商 : ${DEV_MFR:-未知}"
ui_print "- SoC  : ${DEV_SOC:-未知}"
ui_print "- 系统 : Android $(getprop ro.build.version.release) / 补丁 $(getprop ro.build.version.security_patch)"

case "$DEV_MFR" in
    OPPO|oppo|OnePlus|oneplus|realme|Realme) ;;
    *)
        ui_print "! 仅支持 OPPO / 一加 / realme（ColorOS / RealmeUI）"
        ui_print "! 当前厂商: ${DEV_MFR:-未知}"
        command -v abort >/dev/null 2>&1 && abort "不支持的机型，已中止安装"
        exit 1
        ;;
esac

# ---------- 依赖 ----------

for bin in mount umount sed awk; do
    command -v "$bin" >/dev/null 2>&1 || { ui_print "! 缺少 $bin，中止安装"; exit 1; }
done

# ---------- 生成覆盖层 ----------

ui_print "- 扫描并改写系统温控/充电配置…"
# 覆盖安装时上一版挂载可能还在，必须先解挂再读，否则把改过一次的文件
# 当原件再改一遍（充电曲线会叠加成 +240）
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
    find "$SD_OVERRIDES" -type f 2>/dev/null | sed "s|$SD_OVERRIDES||" | while IFS= read -r f; do
        ui_print "    $f"
    done
fi

# ---------- 默认参数 ----------
# 默认策略：42℃ 以下全力伪装，到 42℃ 立即收手。
#   shell_temp=30  基准压到允许值，温差才有空间拉开
#   aggr=10        可拉开温差 = 2 + 10 = 12℃
#   wall=42        真实温度到达即关闭模拟，交还系统
# 三者关系：42℃ 以下实际温差 = min(12, 42 - 真实)，30℃ 时已顶满 12℃。
SD_DEFAULTS="temp_mode=off
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
log_level=3
tick=15"

# 逐键补齐，不整文件覆盖 —— 后者会把用户调好的参数全清掉
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

# ---------- 默认值迁移 ----------
# 逐键补齐只补"缺失的键"。老用户升级时 wall/aggr/shell_temp 已存在，
# 永远拿不到新默认，所以按旧默认精确识别后升级一次。
# 只改"仍等于旧默认"的键，用户手动调过的一律保留。
_sd_st_loaded=0
defrev=$(sd_state_get defrev 1)
case "$defrev" in ''|*[!0-9]*) defrev=1 ;; esac
if [ "$defrev" -lt 2 ]; then
    migrated=""
    [ "$(sd_state_get wall off)" = "off" ] && { sd_state_set wall 42; migrated="$migrated wall"; }
    [ "$(sd_state_get aggr 5)" = "5" ] && { sd_state_set aggr 10; migrated="$migrated aggr"; }
    # 只迁 0（从未设置）。38 是旧菜单首项，视为用户主动选择，保留。
    [ "$(sd_state_get shell_temp 0)" = "0" ] && { sd_state_set shell_temp 30; migrated="$migrated shell_temp"; }
    sd_state_set defrev 2
    [ -n "$migrated" ] && ui_print "- 切换到新默认: 42℃ 以下最猛（$migrated）"
fi
# 旧版的 dyn 模式依赖每 tick dumpsys，已并入 static
[ "$(sd_state_get temp_mode off)" = "dyn" ] && {
    sd_state_set temp_mode static
    ui_print "- 旧 dyn 模式已并入 static"
}

ui_print "- 参数: aggr=$(sd_state_get aggr 10) wall=$(sd_state_get wall 42) curr_max=$(sd_state_get curr_max 0)"

printf '%s\n' "$MODDIR" 2>/dev/null >"$SD_DATA/moddir"

# ---------- 冲突提示 ----------

for m in /data/adb/modules/*; do
    [ -f "$m/module.prop" ] || continue
    [ "$(basename "$m")" = "$(basename "$MODDIR")" ] && continue
    if grep -qE '墓碑|温控|采样率|快充|充电守护|满血' "$m/module.prop" 2>/dev/null; then
        ui_print "! 检测到可能冲突的模块: $(grep '^name=' "$m/module.prop" | cut -d= -f2-)"
    fi
done

ui_print "- 安装完成，重启后生效"
ui_print "    状态: sh $MODDIR/action.sh status"
ui_print "    配置: sh $MODDIR/action.sh temp static     # 开温度伪装"
ui_print ""
ui_print "- 关注作者: https://www.coolapk.com/u/27316679"

# 刷写完成后拉起浏览器。后台执行 + 1 秒等待：recovery 或 system 未就绪时
# am 可能长时间不返回，不能让它拖住安装流程。
if command -v am >/dev/null 2>&1; then
    ( am start -a android.intent.action.VIEW \
        -d "https://www.coolapk.com/u/27316679" >/dev/null 2>&1 ) &
    sleep 1
fi
