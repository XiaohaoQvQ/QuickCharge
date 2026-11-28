#!/system/bin/sh
# Quick Charge (QC) — daemon/ctl.sh
# 由 lib/qc.sh 拆分而来，函数体与 3.1.18 行为等价。

sd_pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

sd_now_up() {
    _sd_uptime
}

sd_hb_write() {
    sd_now_up
    printf '%s %s\n' "$_sd_rv" "$$" >"$SD_RUN/hb" 2>/dev/null
}

sd_hb_age() {
    local t p
    _sd_hb_pid=""
    read -r t p 2>/dev/null <"$SD_RUN/hb" || return 1
    _sd_hb_pid=$p
    case "$t" in ''|*[!0-9]*) return 1 ;; esac
    sd_now_up
    _sd_rv=$((_sd_rv - t))
    [ "$_sd_rv" -ge 0 ] || return 1
    return 0
}

sd_pid_is_daemon() {
    local pid="$1"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] || return 1
    sd_pid_alive "$pid" || return 1
    if [ -r "/proc/$pid/cmdline" ]; then
        grep -q "service\.sh" "/proc/$pid/cmdline" 2>/dev/null && return 0
        # C 版守护的 cmdline 是 bin/qcmon，否则会被当成"没起来"反复拉起
        grep -q "qcmon" "/proc/$pid/cmdline" 2>/dev/null && return 0
        return 1
    fi
    sd_hb_age && [ "$_sd_rv" -le 90 ] && [ "${_sd_hb_pid:-}" = "$pid" ]
}

# 守护是不是 C 版。用来避免 shell 与 qcmon 同时写同一现场。

sd_daemon_is_c() {
    local pid
    pid=$(sd_daemon_pid 2>/dev/null) || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\000' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q qcmon
}

sd_daemon_pid() {
    local pid
    read -r pid 2>/dev/null <"$SD_RUN/daemon.pid"
    if ! sd_pid_is_daemon "$pid"; then
        read -r pid 2>/dev/null <"$SD_RUN/daemon.lock/pid"
        sd_pid_is_daemon "$pid" || return 1
        printf '%s\n' "$pid" >"$SD_RUN/daemon.pid" 2>/dev/null
    fi
    printf '%s' "$pid"
}

sd_stale_clean() {
    local h="" l=""
    _sd_stale_pid=""
    [ -f "$SD_RUN/daemon.pid" ] && read -r h 2>/dev/null <"$SD_RUN/daemon.pid"
    [ -f "$SD_RUN/daemon.lock/pid" ] && read -r l 2>/dev/null <"$SD_RUN/daemon.lock/pid"
    sd_pid_is_daemon "$h" && return 1
    sd_pid_is_daemon "$l" && return 1
    _sd_stale_pid="${l:-$h}"
    rm -rf "$SD_RUN/daemon.lock" 2>/dev/null
    rm -f "$SD_RUN/daemon.pid" "$SD_RUN/daemon.ver" "$SD_RUN/hb" "$SD_RUN/sensor" "$SD_PWR_HIST" 2>/dev/null
    return 0
}

# 守护跑的是不是磁盘上这份代码。
# 3.1.14 的 PLG110 现场：装的 3.1.14、跑的是 3.1.11 —— 覆盖文件不会动已经起来的
# 进程，boot 段看到「cmdline 里有 service.sh」就跳过，于是 3.1.13/3.1.14 的修复
# 一条都没生效，用户对着旧行为报了半个月的「功率上不去」。
# sd_pid_is_daemon 只认「是不是守护」，认不出「是不是这一份」，所以这里比指纹：
# 守护启动时写 run/daemon.ver，不一致就 TERM 旧的、清锁，让调用方重新拉起。
# 没有 daemon.ver 说明那份守护是 3.1.14 或更早起的，按旧代码处理。

sd_daemon_ver_chk() {
    local pid old now i=0
    [ "${_sd_st_loaded:-0}" = 1 ] || sd_state_load
    pid=$(sd_daemon_pid 2>/dev/null) || return 1
    now=$(sd_code_ver)
    case "$now" in unknown*) return 1 ;; esac
    old=""
    [ -f "$SD_RUN/daemon.ver" ] && old=$(cat "$SD_RUN/daemon.ver" 2>/dev/null)
    _sd_ver_old="${old:-无指纹（≤3.1.14 启动）}"
    [ "$old" = "$now" ] && return 1
    sd_warn daemon "守护(pid=$pid)跑的不是磁盘上这份代码：$_sd_ver_old → $now，收掉重起"
    kill -TERM "$pid" 2>/dev/null
    while sd_pid_alive "$pid" && [ "$i" -lt 20 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    sd_pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null
    rm -rf "$SD_RUN/daemon.lock" 2>/dev/null
    rm -f "$SD_RUN/daemon.pid" "$SD_RUN/daemon.ver" "$SD_RUN/hb" 2>/dev/null
    return 0
}

sd_daemon_launch() {
    local i=0 round=0 h="" m="${MODDIR:-${SD_MODDIR:-}}"
    [ -n "$m" ] && [ -f "$m/service.sh" ] || return 1
    # 版本换了就地换人：action.sh 的 start/restart 与 boot 段都走这里
    sd_daemon_ver_chk >/dev/null 2>&1
    sd_daemon_pid >/dev/null && return 0
    mkdir -p "$SD_RUN" 2>/dev/null
    sd_stale_clean && sd_info daemon "清理残留锁(旧 pid=${_sd_stale_pid:-?})，重新拉起"
    while [ "$round" -lt 2 ]; do
        if command -v setsid >/dev/null 2>&1; then
            setsid sh "$m/service.sh" --daemon </dev/null >/dev/null 2>&1 &
        else
            nohup sh "$m/service.sh" --daemon </dev/null >/dev/null 2>&1 &
        fi
        i=0
        while [ "$i" -lt 30 ]; do
            sd_daemon_pid >/dev/null && return 0
            sleep 0.1
            i=$((i + 1))
        done
        round=$((round + 1))
        [ "$round" -lt 2 ] && sd_stale_clean >/dev/null 2>&1
    done
    if [ -d "$SD_RUN/daemon.lock" ]; then
        read -r h 2>/dev/null <"$SD_RUN/daemon.lock/pid"
        sd_warn daemon "拉起失败：锁仍被 pid=${h:-空} 占用"
    fi
    return 1
}

sd_daemon_stop() {
    local pid i=0
    if pid=$(sd_daemon_pid); then
        kill -TERM "$pid" 2>/dev/null
        while sd_pid_alive "$pid" && [ "$i" -lt 20 ]; do
            sleep 0.1
            i=$((i + 1))
        done
        sd_pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null
    fi
    rm -rf "$SD_RUN/daemon.lock" "$SD_RUN/daemon.pid" "$SD_RUN/daemon.ver" "$SD_RUN/hb" "$SD_RUN/sensor"
}

sd_telemetry_write() {
    sd_now_up
    printf '%s %s %s %s %s %s %s\n' \
        "$_sd_rv" "${_sd_last_cur:--}" "${_sd_last_lim:--}" \
        "${_sd_last_zone:--}" "${_sd_last_out:--}" "${_st_temp_mode:-off}" \
        "${_sd_emul_ok:--1}" \
        >"$SD_RUN/sensor" 2>/dev/null
}

# 真实温度只用于面板显示（用户要看"现在到底多热"），不参与任何判断。
# 极速模式下 sd_shell_target 完全不读真实值，缓存里的真实温度就空了，
# 面板会一直显示"—"；这里单独补一次采样。

sd_telemetry_sample() {
    _sd_last_cur=""
    _sd_last_zone=""
    _sd_last_lim=""
    sd_pick_sentinel_v || return 0
    _sd_last_zone=${_sd_rv##*/}
    sd_sentinel_temp_v "$_sd_rv" && _sd_last_cur=$_sd_rv
    return 0
}

sd_telemetry_read() {
    local up real lim zone out mode emul
    read -r up real lim zone out mode emul 2>/dev/null <"$SD_RUN/sensor" || return 1
    case "$up" in ''|*[!0-9]*) return 1 ;; esac
    sd_now_up
    _sd_rv=$((_sd_rv - up))
    [ "$_sd_rv" -ge 0 ] || return 1
    [ "$_sd_rv" -le 330 ] || return 1
    _sd_tl_age=$_sd_rv
    _sd_tl_real=$real
    _sd_tl_lim=$lim
    _sd_tl_zone=$zone
    _sd_tl_out=$out
    _sd_tl_mode=$mode
    case "$emul" in 0|1) _sd_tl_emul=$emul ;; *) _sd_tl_emul=-1 ;; esac
    return 0
}

sd_daemon_kick() {
    local pid
    pid=$(sd_daemon_pid 2>/dev/null) || return 0
    kill -USR1 "$pid" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------
# 模块状态：WebUI 顶部那块牌子。三态
#   ok      守护在跑，心跳新鲜
#   reboot  模块刚装上 / 刚更新，这次开机还没加载过
#   dead    该跑没跑起来（或守护卡死）—— 让用户把日志发过来
# ---------------------------------------------------------------

sd_boot_mark() {
    mkdir -p "$SD_DATA" 2>/dev/null
    printf 'up=%s\n' "$(qc_up)" >"$SD_DATA/.boot_id" 2>/dev/null
    return 0
}

# 本次开机的 post-fs-data 跑过没有。判据与 phase.pfs / log.up 同一套：
# 单调时钟只增不减，重启归零。旧实现拿 now-uptime 比 15 秒窗口，
# NTP 一旦把墙钟往前跳，同一次开机也会被判成「刚重启」。
sd_boot_seen() {
    qc_phase_fresh "$SD_DATA/.boot_id"
}

sd_module_state() {
    local pid age mu
    _sd_ms=dead
    _sd_ms_why="守护没有启动"
    if pid=$(sd_daemon_pid 2>/dev/null); then
        if sd_hb_age; then
            age=$_sd_rv
            if [ "$age" -gt 180 ]; then
                _sd_ms=dead
                _sd_ms_why="守护 pid=$pid 已 ${age} 秒没有心跳"
            elif [ "$age" -le 5 ]; then
                _sd_ms=ok
                _sd_ms_why="守护 pid=$pid 心跳正常"
            else
                _sd_ms=ok
                _sd_ms_why="守护 pid=$pid，${age} 秒前心跳"
            fi
        else
            _sd_ms=ok
            _sd_ms_why="守护 pid=$pid 刚启动"
        fi
        return 0
    fi
    # 更新包已解包但还没重启：管理器把它放在 modules_update，重启才搬进 modules
    mu="/data/adb/modules_update/quickcharge"
    if [ -f "$mu/module.prop" ]; then
        _sd_ms=reboot
        _sd_ms_why="新版本已解包，重启后生效"
        return 0
    fi
    if [ -f "$SD_DATA/need_reboot" ]; then
        _sd_ms=reboot
        _sd_ms_why="刚安装，重启后生效"
        return 0
    fi
    if ! sd_boot_seen; then
        _sd_ms=reboot
        _sd_ms_why="这次开机还没加载过模块"
        return 0
    fi
    _sd_ms=dead
    _sd_ms_why="启动脚本跑过了，守护没起来"
    return 0
}

sd_wait_boot() {
    local max="${1:-60}" i=0
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        sleep 2
        i=$((i + 2))
        if [ "$i" -ge "$max" ]; then
            sd_warn boot "等待 boot_completed 超时(${max}s)"
            return 1
        fi
    done
    return 0
}

_sd_ps_nodes="battery mtk-battery mtk-gauge bms"
