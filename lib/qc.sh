#!/system/bin/sh
# ---------------------------------------------------------------
# Quick Charge (QC) — 源码完全公开，可自由查看、修改、分发。
# 禁止商业用途，禁止用于任何违反法律法规的场景。
# Fully open source. Commercial use and any unlawful use prohibited.
# ---------------------------------------------------------------

[ -n "$MODDIR" ] || MODDIR="${SD_MODDIR:-}"
[ -n "$MODDIR" ] || MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd)

# 加载根与配置目录分离：MODDIR 在测试里被借用成「module.prop 所在目录」，
# 不能拿它找 lib。部署时 SD_MODDIR / MODDIR 都是模块根，两者一致。
QC_LIBDIR="${SD_MODDIR:-$MODDIR}"
[ -n "$QC_LIBDIR" ] && [ -f "$QC_LIBDIR/lib/qc.sh" ] || QC_LIBDIR=""
if [ -z "$QC_LIBDIR" ]; then
    for _qc_c in "$(cd "${0%/*}" 2>/dev/null && pwd)" \
                 /data/adb/modules/quickcharge \
                 /data/adb/modules_update/quickcharge; do
        [ -f "${_qc_c:-/nonexistent}/lib/qc.sh" ] && { QC_LIBDIR="$_qc_c"; break; }
    done
    unset _qc_c
fi
if [ -z "$QC_LIBDIR" ]; then
    echo "QC: 找不到 lib/qc.sh（MODDIR=${MODDIR:-空} SD_MODDIR=${SD_MODDIR:-空}）" >&2
    exit 1
fi

SD_DATA="${SD_DATA:-/data/adb/quickcharge}"
case "$SD_DATA" in
    ""|/|/data|/data/adb|/data/adb/) SD_DATA=/data/adb/quickcharge ;;
esac

SD_STATE="$SD_DATA/state.conf"
SD_LOG="$SD_DATA/log.txt"
SD_LOG_UP="$SD_DATA/log.up"

# read 内建读到的是原样字节，节点若带 CR 需要去掉。
# 只在加载时展开一次，避免热路径里再 fork。
SD_CR=$(printf '\r')
SD_OLD="$SD_DATA/log.old.txt"
SD_MOUNTS="$SD_DATA/mounts.list"
SD_BACKUP="$SD_DATA/backup"
SD_RUN="$SD_DATA/run"
SD_SPOOF_DIR="${SD_SPOOF_DIR:-}"
SD_SPOOF_DEF="${SD_SPOOF_DEF:-/dev/qc}"
SD_SPOOF_FLAG="$SD_RUN/spoof.pending"
SD_PWR_HIST="$SD_RUN/power.hist"
SD_BUILT="$SD_DATA/built.id"
SD_PS="${SD_PS:-/sys/class/power_supply}"
SD_SHELL_TEMP="${SD_SHELL_TEMP:-/proc/shell-temp}"
SD_BL="${SD_BL:-/sys/class/backlight}"
SD_FB="${SD_FB:-/sys/class/graphics/fb0/blank}"
SD_OPLUS_CHG="${SD_OPLUS_CHG:-/sys/class/oplus_chg/battery}"
SD_MTK_CMD="${SD_MTK_CMD:-/proc/mtk_battery_cmd}"
SD_VOTABLE="${SD_VOTABLE:-/proc/oplus-votable}"

SD_OVERRIDES="$MODDIR/files"
if mkdir -p "$SD_OVERRIDES/.wtest" 2>/dev/null; then
    rmdir "$SD_OVERRIDES/.wtest" 2>/dev/null
else
    SD_OVERRIDES="$SD_DATA/overrides"
fi

for _d in "$SD_DATA" "$SD_BACKUP" "$SD_RUN" "$SD_OVERRIDES"; do
    [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
done

[ -n "${SD_ZONE_GLOB:-}" ] || SD_ZONE_GLOB=/sys/class/thermal/thermal_zone*

_sd_lv=0
_sd_rot=0

for _qc_m in core/util.sh core/log.sh core/state.sh plat/probe.sh plat/zones.sh \
             plat/shell.sh thermal/spoof.sh cfg/transform.sh cfg/mount.sh daemon/ctl.sh \
             feat/scr.sh feat/hz.sh feat/charge.sh ui/report.sh; do
    . "$QC_LIBDIR/lib/$_qc_m"
done
unset _qc_m
