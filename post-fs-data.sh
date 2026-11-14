#!/system/bin/sh
# ---------------------------------------------------------------
# Quick Charge (QC) — 源码完全公开，可自由查看、修改、分发。
# 禁止商业用途，禁止用于任何违反法律法规的场景。
# Fully open source. Commercial use and any unlawful use prohibited.
# ---------------------------------------------------------------

MODDIR="${SD_MODDIR:-}"
if [ -z "$MODDIR" ]; then
    MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd)
    [ -f "${MODDIR:-/nonexistent}/lib/qc.sh" ] || MODDIR=$(pwd)
fi
[ -f "$MODDIR/lib/qc.sh" ] || {
    echo "QC: 找不到 lib/qc.sh" >&2
    echo "  当前推导路径: $MODDIR" >&2
    exit 1
}

. "$MODDIR/lib/qc.sh"

export SD_PHASE=post-fs-data

sd_log_reset
rm -f "$SD_RUN/curr.orig" "$SD_RUN/curr.want" "$SD_RUN/hb" "$SD_RUN/sensor" 2>/dev/null
if [ -d "$SD_RUN/daemon.lock" ] || [ -f "$SD_RUN/daemon.pid" ]; then
    sd_stale_clean && echo "QC: 清理上一轮残留的守护锁(旧 pid=${_sd_stale_pid:-?})" >&2
fi
if [ -d "$SD_RUN/daemon.lock" ] || [ -f "$SD_RUN/daemon.pid" ]; then
    sd_stale_clean && sd_info boot "清理上一轮残留的守护锁(旧 pid=${_sd_stale_pid:-?})"
fi

sd_state_load
sd_zone_scan

cnt=0
read -r cnt 2>/dev/null <"$SD_DATA/boot.count"
case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
cnt=$((cnt + 1))
printf '%s\n' "$cnt" 2>/dev/null >"$SD_DATA/boot.count"

if [ "$cnt" -gt 3 ]; then
    : >"$SD_MOUNTS" 2>/dev/null
    echo "QC: 连续 $cnt 次开机未完成，已跳过挂载（安全模式）" >&2
    exit 0
fi

sd_session boot "post-fs-data 启动 (计数 $cnt/3)"
sd_info boot "模块=$MODDIR 覆盖层=$SD_OVERRIDES"

need=0
if [ ! -d "$SD_OVERRIDES" ] || [ -z "$(ls -A "$SD_OVERRIDES" 2>/dev/null)" ]; then
    need=1
    sd_info boot "覆盖层为空，现场生成"
else
    cur=$(sd_fingerprint)
    old=$(cat "$SD_BUILT" 2>/dev/null)
    case "$cur" in ''|-*) cur="" ;; esac
    if [ -n "$cur" ] && [ "$cur" != "$old" ]; then
        need=1
        sd_info boot "系统版本变化(${old:-未知} → $cur)，重建覆盖层"
    fi
fi

if [ "$need" = 1 ]; then
    sd_umount_overrides
    t0=$(date +%s)
    sd_build_overrides
    t1=$(date +%s)
    [ $((t1 - t0)) -gt 10 ] && sd_warn boot "配置生成耗时 $((t1 - t0))s 偏长（本阶段有超时限制）"
fi

sd_mount_overrides

sd_sync_desc

sd_dump_env

sd_info boot "post-fs-data 完成"
exit 0
