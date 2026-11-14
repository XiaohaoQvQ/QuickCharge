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

if [ "${SD_PHASE:-}" = "post-fs-data" ]; then
    sd_warn boot "拒绝执行：service.sh 不能在 post-fs-data 阶段运行"
    echo "QC: service.sh 不能在 post-fs-data 阶段运行，已跳过" >&2
    exit 0
fi

_boot_ts=$(sd_boot_ts)
if [ -f "$SD_LOG" ] && [ "$(sd_file_mtime "$SD_LOG")" -lt "$_boot_ts" ]; then
    sd_log_reset
    sd_info boot "清理上一轮日志（post-fs-data 未执行）"
fi
rm -f "$SD_RUN/curr.want" "$SD_RUN/hb" "$SD_RUN/sensor" 2>/dev/null

sd_apply_state() {
    local mode c nc
    sd_state_load
    mode=$(sd_state_get temp_mode off)

    [ "$mode" = "dyn" ] && { mode=static; sd_state_set temp_mode static; }
    case "$mode" in
        static) sd_horae "$(sd_state_get horae 1)"; sd_shell_emul "$(sd_shell_target)" ;;
        charge)
            sd_horae "$(sd_state_get horae 1)"
            sd_charge_tick ;;

    esac

    c=$(sd_state_get core_temp off)
    case "$c" in
        ''|off) ;;
        *) if sd_valid_temp "$c"; then sd_spoof_apply core "$c"
           else sd_warn state "core_temp 非法($c)，重置 off"; sd_state_set core_temp off; fi ;;
    esac

    nc=$(sd_state_get noncore_temp off)
    case "$nc" in
        ''|off) ;;
        *) if sd_valid_temp "$nc"; then sd_spoof_apply noncore "$nc"
           else sd_warn state "noncore_temp 非法($nc)，重置 off"; sd_state_set noncore_temp off; fi ;;
    esac

    sd_hz_boot
    sd_batt_sp_guard
    sd_screen_tick
    sd_scr_tick
    sd_sync_desc

    sd_info boot "状态恢复: temp=$mode core=$c noncore=$nc hz=$(sd_state_get hz off)"
}

sd_daemon() {
    local lock="$SD_RUN/daemon.lock" holder tick
    local mode last_mode="" cnt=0 _hzr=0 _hz_n=0
    local _log_out="" _log_cnt=0
    local _bst=""
    _sd_sp=""
    _sd_reload=0

    mkdir -p "$SD_RUN" 2>/dev/null

    if ! mkdir "$lock" 2>/dev/null; then
        read -r holder 2>/dev/null <"$lock/pid"
        if sd_pid_is_daemon "$holder"; then
            sd_info daemon "已有守护在运行(pid=$holder)，本实例退出"
            exit 0
        fi
        sd_info daemon "清理残留锁(pid=${holder:-空} 已不是守护)"
        rm -rf "$lock" 2>/dev/null
        mkdir "$lock" 2>/dev/null || exit 0
    fi
    printf '%s\n' "$$" >"$lock/pid"
    printf '%s\n' "$$" >"$SD_RUN/daemon.pid"
    sd_hb_write

    sd_state_load
    sd_zone_scan
    sd_session daemon "守护启动"
    sd_info daemon "守护启动 pid=$$"

    trap 'sd_info daemon "收到 TERM，退出"; rm -rf "$SD_RUN/daemon.lock"; rm -f "$SD_RUN/daemon.pid"; exit 0' TERM INT

    trap 'sd_info daemon "收到重载信号，立即刷新参数"; [ -n "${_sd_sp:-}" ] && kill "$_sd_sp" 2>/dev/null; _sd_reload=1' USR1

    sd_wait_boot || sd_warn daemon "等待 boot_completed 超时，继续启动"

    tick=$(sd_state_int tick 15 5 300)
    sd_info daemon "循环参数: tick=${tick}s wall=$(sd_state_get wall off) aggr=$(sd_state_int aggr 10 0 10) curr_max=$(sd_state_get curr_max 0)"

    _sd_pause() {
        sleep "$1" & _sd_sp=$!
        wait $_sd_sp 2>/dev/null
        _sd_sp=""
    }

    while :; do
        sd_state_load
        if [ "$_sd_reload" = 1 ]; then
            _sd_reload=0
            tick=$(sd_state_int tick 15 5 300)
        fi

        if [ ! -f "$MODDIR/service.sh" ]; then
            sd_info daemon "模块目录已移除，守护退出"
            break
        fi

        cnt=$((cnt + 1))
        if [ -z "$_sd_zones" ] || [ "$_sd_temp_fail" -ge 2 ] || [ $((cnt % 40)) -eq 0 ]; then
            sd_zone_scan
            _sd_temp_fail=0
        fi

        sd_screen_tick

        sd_batt_status_v
        case "$_sd_rv" in Charging|Full) sd_curr_keep ;; esac
        sd_scr_tick

        sd_spoof_pending
        sd_batt_sp_guard

        if ! sd_sentinel_guard; then
            _sd_last_out=0
            if sd_pick_sentinel_v; then
                _sd_last_zone=${_sd_rv##*/}
                if sd_sentinel_temp_v "$_sd_rv"; then
                    _sd_last_cur=$_sd_rv
                    sd_limit_for_type_v "$_sd_sent_type"
                    case "$_sd_rv" in ''|0|off) _sd_last_lim="" ;; *) _sd_last_lim=$_sd_rv ;; esac
                fi
            fi
            sd_hb_write
            sd_telemetry_write
            _sd_pause "$tick"
            continue
        fi

        mode=$_st_temp_mode
        if [ "$mode" != "$last_mode" ]; then
            sd_info daemon "温度模式: ${last_mode:-<无>} → $mode"
            last_mode=$mode
            _sd_emul_last=""
            _sd_wall_hold=0
            sd_sync_desc
        fi

        [ $((cnt % 12)) -eq 3 ] && sd_sync_desc

        case "$mode" in
            static)
                sd_shell_target >/dev/null
                sd_shell_emul "$_sd_last_out"
                if [ "$_sd_last_out" != "$_log_out" ]; then
                    sd_info daemon "伪装 真实=${_sd_last_cur:-?}℃ 上报=${_sd_last_out:-0}℃ 墙=${_st_wall:-off}"
                    _log_out=$_sd_last_out
                    _log_cnt=0
                else
                    _log_cnt=$((_log_cnt + 1))
                    if [ "$_log_cnt" -ge 60 ]; then
                        sd_info daemon "摘要 真实=${_sd_last_cur:-?}℃ 上报=${_sd_last_out:-0}℃ 墙=${_st_wall:-off}"
                        _log_cnt=0
                    fi
                fi
                ;;
            charge)
                sd_charge_tick
                ;;
            off)
                _sd_last_cur=""
                _sd_last_out=0
                _sd_last_lim=""
                _sd_last_zone=""
                if sd_pick_sentinel_v; then
                    _sd_last_zone=${_sd_rv##*/}
                    sd_sentinel_temp_v "$_sd_rv" && _sd_last_cur=$_sd_rv
                fi
                ;;
        esac

        sd_hb_write
        sd_telemetry_write

        sd_hz_guard; _hzr=$?
        case "$_hzr" in
            1)  _hz_n=$((_hz_n + 1))
                if [ $((_hz_n % 4)) -eq 1 ]; then
                    sd_info daemon "刷新率被系统改回，已补写（累计 ${_hz_n} 次）"
                    sd_sync_desc
                fi ;;
            2)  [ $((cnt % 40)) -eq 0 ] && \
                    sd_info daemon "刷新率写入被拒绝，已暂停补写（厂商锁定显示策略）" ;;
            3)  [ $((cnt % 40)) -eq 0 ] && \
                    sd_info daemon "省电模式开启，刷新率交回系统管理" ;;
            *)  _hz_n=0 ;;
        esac

        case "$mode" in
            charge) _sd_pause 10 ;;
            *)      _sd_pause "$tick" ;;
        esac
    done

    rm -rf "$SD_RUN/daemon.lock" "$SD_RUN/daemon.pid"
    sd_info daemon "守护已停止"
}

if [ "$1" = "--daemon" ]; then
    sd_daemon
    exit 0
fi

sd_session boot "service 阶段启动"
sd_dump_env

sd_wait_boot 60 || { sd_warn boot "boot_completed 未在 60s 内就绪，退出"; exit 0; }
[ "$(getprop sys.boot_completed)" = "1" ] || exit 0

printf '0\n' 2>/dev/null >"$SD_DATA/boot.count"

if ! sd_mounts_alive; then
    sd_info boot "覆盖层未生效，补充挂载"
    sd_mount_overrides
fi

sd_apply_state

if [ -d "$SD_RUN/daemon.lock" ] || [ -f "$SD_RUN/daemon.pid" ]; then
    sd_stale_clean && sd_warn boot "清理上一轮残留的守护锁(旧 pid=${_sd_stale_pid:-?})"
fi

if sd_daemon_pid >/dev/null; then
    sd_info boot "守护已在运行，跳过"
else
    if sd_daemon_launch; then
        sd_info boot "守护已拉起 pid=$(sd_daemon_pid 2>/dev/null)"
    else
        sd_warn boot "守护拉起失败，请查看日志"
    fi
fi
