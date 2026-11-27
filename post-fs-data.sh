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
rm -f "$SD_RUN/hb" "$SD_RUN/sensor" 2>/dev/null
if [ -d "$SD_RUN/daemon.lock" ] || [ -f "$SD_RUN/daemon.pid" ]; then
    sd_stale_clean && echo "QC: 清理上一轮残留的守护锁(旧 pid=${_sd_stale_pid:-?})" >&2
fi
if [ -d "$SD_RUN/daemon.lock" ] || [ -f "$SD_RUN/daemon.pid" ]; then
    sd_stale_clean && sd_info boot "清理上一轮残留的守护锁(旧 pid=${_sd_stale_pid:-?})"
fi

sd_state_load
# 3.0.8 删掉了 horae 开关（它只管性能/亮度，与充电无关）。老用户若把它停在 0，
# 这里恢复系统默认并把状态行清掉，否则入口没了，horae 会一直停着。
if [ -f "$SD_STATE" ] && grep -q '^horae=' "$SD_STATE" 2>/dev/null; then
    if [ "$(sed -n 's/^horae=//p' "$SD_STATE" | head -1)" = 0 ]; then
        setprop persist.sys.horae.enable 1 2>/dev/null
        start horae 2>/dev/null
        sd_info boot "horae 开关已移除，恢复系统默认"
    fi
    sed -i '/^horae=/d' "$SD_STATE" 2>/dev/null
fi
sd_boot_mark
rm -f "$SD_DATA/need_reboot" 2>/dev/null
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

# 用户关掉配置改写时，覆盖层是故意空的：跳过整段生成/挂载，
# 否则每次开机都会多两行「覆盖层为空 → 已关闭」，查日志时像故障。
if [ "$(sd_state_get overrides_off 0)" = 1 ]; then
    sd_info boot "配置改写已关闭(overrides off)，跳过覆盖层"
    sd_dump_env
    exit 0
fi

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

# 这里不刷描述：本阶段守护还没起来，状态判定只会得出「未运行」，描述会被
# 刷成故障、几秒后 service.sh 再改回来。交给 service.sh 的 sd_apply_state 刷。

sd_dump_env

sd_info boot "post-fs-data 完成"
exit 0
