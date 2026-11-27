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

# 先读一次配置：日志级别在 state.conf 里，晚读一步，`service 阶段启动` 这类
# 会话标记就会因为 _sd_lv 还是 0 被吞掉，日志只剩后面的 env 头。
sd_state_load

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
rm -f "$SD_RUN/hb" "$SD_RUN/sensor" 2>/dev/null

sd_apply_state() {
    local mode c nc
    sd_state_load
    mode=$(sd_state_get temp_mode off)

    [ "$mode" = "dyn" ] && { mode=static; sd_state_set temp_mode static; }
    case "$mode" in
        static) sd_shell_emul "$(sd_shell_target)" ;;
        charge)
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
    local mode last_mode="" cnt=0 _hzr=0 _hz_n=0 _sd_chg=0 _ws=0
    local _log_out="" _log_cnt=0 _sd_scr_once=0 _pid=""
    local _bst=""
    _sd_sp=""
    _sd_reload=0

    mkdir -p "$SD_RUN" 2>/dev/null

    # C 守护包：把热路径整个交给 qcmon，不再走下面的 shell 循环。
    # 只认 module.prop 的 channel=c：3.1.2/3.1.3 的 shell 包误带了二进制，
    # 只看「文件在不在」会让 shell 版偷偷跑 C 守护，脚本侧的修复全部失效。
    # 二进制缺失、不可执行或跑不起来时照旧走 shell 版本。
    if sd_use_c && [ "${SD_SHELL_DAEMON:-0}" != 1 ]; then
        if "$MODDIR/bin/qcmon" -v >/dev/null 2>&1; then
            # qcmon 读 SD_MODDIR（用于回写 module.prop 描述），MODDIR 是兼容旧名
            export SD_DATA
            export SD_MODDIR="$MODDIR"
            export MODDIR
            # 静态守护没有 tzdata，localtime_r 会落 UTC；这里把当前偏移交过去，
            # 日志时间才和脚本行一致（+0800）。
            SD_TZ=$(date +%z 2>/dev/null)
            [ -n "$SD_TZ" ] && export SD_TZ
            sd_info daemon "切换到 C 守护 qcmon（shell 版本仍可用 SD_SHELL_DAEMON=1 强制）"
            rm -rf "$lock" 2>/dev/null
            exec "$MODDIR/bin/qcmon"
        fi
        sd_warn daemon "bin/qcmon 无法执行，回退 shell 守护"
    fi

    # 非 C 通道却有个 qcmon 在跑（旧包残留、C 包装过又刷回 shell 包、手动执行过）：
    # 两个守护共用 run/ 下的 scr.orig / fcc.norm / unlock.orig 备份，会互相覆盖；
    # ≤3.1.12 的 qcmon 还会写 cool_down，能把 VOOC 直接打到 2W 档。
    if [ "$(sd_channel)" != c ] || [ "${SD_SHELL_DAEMON:-0}" = 1 ]; then
        for _p in /proc/[0-9]*; do
            _pid=${_p#/proc/}
            [ "$_pid" = "$$" ] && continue
            grep -qa 'bin/qcmon' "$_p/cmdline" 2>/dev/null || continue
            if kill "$_pid" 2>/dev/null; then
                sd_warn daemon "收掉并存的 qcmon(pid=$_pid)：channel=$(sd_channel)，不该跑 C 守护"
            fi
        done
    fi

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
    sd_info daemon "循环参数: tick=${tick}s temp=$(sd_state_get temp_mode off) shell=$(sd_state_int shell_temp 30 20 33)℃ channel=$(sd_channel)"
    # 混合安装（module.prop 是新的、service.sh 是旧的）在日志里只能靠节拍猜，
    # 把两个文件的指纹写下来，以后一眼能看出跑的是不是包里的那份。
    sd_info daemon "代码指纹 service.sh=$(sd_file_sum "$MODDIR/service.sh") lib/qc.sh=$(sd_file_sum "$MODDIR/lib/qc.sh")"

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

        # 电流节点在启动早期可能还没就绪，数量变了补一条（见 sd_curr_watch）
        if [ $((cnt % 4)) -eq 1 ]; then sd_curr_watch; fi

        # 屏幕判定只影响日志与轮询间隔，不再影响是否解除降流。
        # 但判错了会影响读数，所以每轮守护启动记一次，排查时一眼能看出。
        # 这个开关以前叫 _sd_scr_log，和 sd_scr_tick 的「上次记过的状态」共用一个
        # 变量，两边每轮互相踩：这里记一条、把它置 1，那边发现 1≠fail 又记一条。
        # 3.1.13 的 PLG110 日志里「屏幕 判定」77 条就是这么刷出来的。
        if [ "$_sd_scr_once" != 1 ]; then
            _sd_scr_once=1
            if [ -n "${_sd_bl_nodes# }" ]; then
                sd_info daemon "屏幕 判定=$([ "$_sd_screen_on" = 1 ] && echo 亮 || echo 灭) 节点=[${_sd_bl_nodes# }]"
            else
                sd_info daemon "屏幕 无亮度节点，按亮屏处理"
            fi
        fi

        _sd_chg=0
        sd_batt_status_v
        case "$_sd_rv" in Charging|Full) _sd_chg=1 ;; esac
        sd_scr_tick
        sd_cool_tick
        sd_unlock_tick
        sd_chg_snapshot "$_sd_chg"

        sd_spoof_pending
        sd_batt_sp_guard

        mode=$_st_temp_mode
        if [ "$mode" != "$last_mode" ]; then
            sd_info daemon "温度模式: ${last_mode:-<无>} → $mode"
            last_mode=$mode
            _sd_emul_last=""
            sd_sync_desc
        fi

        [ $((cnt % 12)) -eq 3 ] && sd_sync_desc

        case "$mode" in
            static)
                sd_shell_target >/dev/null
                sd_shell_emul "$_sd_last_out"
                if [ "$_sd_last_out" != "$_log_out" ]; then
                    sd_info daemon "伪装 上报=${_sd_last_out:-0}℃（恒定）"
                    _log_out=$_sd_last_out
                    _log_cnt=0
                else
                    _log_cnt=$((_log_cnt + 1))
                    if [ "$_log_cnt" -ge 60 ]; then
                        sd_info daemon "摘要 上报=${_sd_last_out:-0}℃（恒定）"
                        _log_cnt=0
                    fi
                fi
                ;;
            charge)
                sd_charge_tick
                ;;
            off)
                _sd_last_out=0
                ;;
        esac

        # 以前充电时压到 3s，为的是尽快把 cool_down 清零。3.1.13 起 cool_down
        # 只读（写它会让 OPlus 重选档），3 秒一次只剩耗电，所以改回按配置走。
        # 但「有东西在位」时必须留一个短周期：拔电、改模式要尽快还原，
        # 不能因为用户把 tick 设成 60 就干等一分钟。
        # 这一段必须放在模式处理之后 —— 刚启动时 _sd_last_out 还是空的，
        # 放在前面会让第一轮就睡满 tick，拔电要等到一分钟以后才发现。
        _ws=$tick
        if [ "$_ws" -gt 10 ]; then
            if { [ -n "$_sd_last_out" ] && [ "$_sd_last_out" != 0 ]; } ||
               [ -f "$SD_UNLOCK_ORIG" ]; then
                _ws=10
            fi
        fi

        sd_telemetry_sample
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

        _sd_pause "$_ws"
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
