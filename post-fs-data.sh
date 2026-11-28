#!/system/bin/sh
# ---------------------------------------------------------------
# Quick Charge (QC) — 源码完全公开，可自由查看、修改、分发。
# 禁止商业用途，禁止用于任何违反法律法规的场景。
# Fully open source. Commercial use and any unlawful use prohibited.
# ---------------------------------------------------------------

# 阶段落痕：lib 还没加载、甚至 MODDIR 都没认对时也要能写一笔。
# 管理器用相对路径执行时 `$0` 可能只有文件名，光靠 `${0%/*}` 会推导失败，
# 失败又发生在写日志之前 —— 用户侧只能看到「日志没被清」，查不出原因。
# 这里用纯 sh 先记到默认数据目录，lib 加载后再同步成真实路径。
_QC_DATA="${SD_DATA:-/data/adb/quickcharge}"
qc_phase() {
    mkdir -p "$_QC_DATA" 2>/dev/null
    # up= 用单调时钟记「写这一笔时开机多久」，service.sh 拿它判本次开机。
    # 不用 at=（墙钟）：NTP 一跳就会把「本次」判成「上次」。
    _qc_u=""
    read -r _qc_u _ 2>/dev/null </proc/uptime || _qc_u=""
    _qc_u=${_qc_u%% *}; _qc_u=${_qc_u%%.*}
    case "$_qc_u" in ''|*[!0-9]*) _qc_u=0 ;; esac
    printf 'up=%s at=%s pid=%s step=%s moddir=%s cwd=%s argv0=%s\n' \
        "$_qc_u" "$(date +%s 2>/dev/null)" "$$" "$1" "${MODDIR:-?}" \
        "$(pwd 2>/dev/null)" "$0" >"$_QC_DATA/phase.pfs" 2>/dev/null
    return 0
}

MODDIR="${SD_MODDIR:-}"
if [ -z "$MODDIR" ] || [ ! -f "$MODDIR/lib/qc.sh" ]; then
    for _c in \
        "/data/adb/modules/quickcharge" \
        "/data/adb/modules_update/quickcharge" \
        "$(cd "${0%/*}" 2>/dev/null && pwd)" \
        "$(pwd)"
    do
        [ -n "$_c" ] && [ -f "$_c/lib/qc.sh" ] && { MODDIR="$_c"; break; }
    done
fi
[ -f "$MODDIR/lib/qc.sh" ] || {
    qc_phase no-lib
    echo "QC: 找不到 lib/qc.sh" >&2
    echo "  当前推导路径: ${MODDIR:-?}" >&2
    echo "  argv0=$0 cwd=$(pwd 2>/dev/null)" >&2
    exit 1
}

qc_phase lib
. "$MODDIR/lib/qc.sh"
_QC_DATA="$SD_DATA"

export SD_PHASE=post-fs-data

qc_phase boot
sd_log_reset
rm -f "$SD_RUN/hb" "$SD_RUN/sensor" 2>/dev/null

sd_state_load

# 清理上一轮的残留锁。位置有讲究：sd_info 受 _sd_lv 控制，而 _sd_lv 要等
# sd_state_load 之后才是 1，load 之前是 0，I 级一条都写不出去 —— 放前面就是
# 「锁清了、日志里没有」。以前这里还写了两遍（先 echo 到 stderr，再 sd_info），
# 第一遍就把锁删了，第二遍的条件永远不成立，于是这条在日志里从来没出现过。
if [ -d "$SD_RUN/daemon.lock" ] || [ -f "$SD_RUN/daemon.pid" ]; then
    sd_stale_clean && sd_info boot "清理上一轮残留的守护锁(旧 pid=${_sd_stale_pid:-?})"
fi
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
qc_phase zones
sd_zone_scan

cnt=0
read -r cnt 2>/dev/null <"$SD_DATA/boot.count"
case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
cnt=$((cnt + 1))
printf '%s\n' "$cnt" 2>/dev/null >"$SD_DATA/boot.count"

if [ "$cnt" -gt 3 ]; then
    : >"$SD_MOUNTS" 2>/dev/null
    # step=safe-mode 是给 service.sh 看的：它认得这个值，不会当成「没跑完」去
    # 重建覆盖层（那等于把这里刚做的决定当场推翻）。计数由 service.sh 在
    # boot_completed 之后清零，所以只要它还能正常起来，下一轮就回到正常流程。
    qc_phase safe-mode
    echo "QC: 连续 $cnt 次开机未完成，已跳过挂载（安全模式）" >&2
    exit 0
fi

sd_session boot "post-fs-data 启动 (计数 $cnt/3)"
sd_info boot "模块=$MODDIR 覆盖层=$SD_OVERRIDES"

# 用户关掉配置改写时，覆盖层是故意空的：跳过整段生成/挂载，
# 否则每次开机都会多两行「覆盖层为空 → 已关闭」，查日志时像故障。
if [ "$(sd_state_get overrides_off 0)" = 1 ]; then
    sd_info boot "配置改写已关闭(overrides off)，跳过覆盖层"
    qc_phase done
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
    qc_phase build
    sd_build_overrides
    t1=$(date +%s)
    [ $((t1 - t0)) -gt 10 ] && sd_warn boot "配置生成耗时 $((t1 - t0))s 偏长（本阶段有超时限制）"
fi

qc_phase mount
sd_mount_overrides

# 这里不刷描述：本阶段守护还没起来，状态判定只会得出「未运行」，描述会被
# 刷成故障、几秒后 service.sh 再改回来。交给 service.sh 的 sd_apply_state 刷。

sd_dump_env

qc_phase done
sd_info boot "post-fs-data 完成"
exit 0
