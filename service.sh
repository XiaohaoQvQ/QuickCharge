#!/system/bin/sh
# service 阶段：恢复上次策略，拉起单进程守护。
#
# 守护设计：
#   * 单进程单循环，状态分发；停止只需 kill 一个 pid。
#   * 每 tick 只做一次 state.conf 的 read 循环 + 一次传感器 read，
#     不调用任何外部命令（不 cat / grep / sed），15 秒周期下 CPU 占用接近 0。
#   * zone 表缓存在内存，每 40 tick 重扫一次，兼顾热插拔。

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

# 阶段守卫：service 会等 boot_completed（最长 60 秒）。被误在 post-fs-data
# 阶段同步调用时，这 60 秒就是实打实的开机卡顿。
if [ "${SD_PHASE:-}" = "post-fs-data" ]; then
    sd_warn boot "拒绝执行：service.sh 不能在 post-fs-data 阶段运行"
    echo "QC: service.sh 不能在 post-fs-data 阶段运行，已跳过" >&2
    exit 0
fi

# ---------- 恢复状态 ----------

sd_apply_state() {
    local mode c nc
    sd_state_load
    mode=$(sd_state_get temp_mode off)

    # dyn 是旧版的"仅游戏时伪装"，依赖每 tick dumpsys，开销大且收益有限，
    # 已并入 static（temp 伪装本身几乎不耗电）。老 state 直接迁移。
    [ "$mode" = "dyn" ] && { mode=static; sd_state_set temp_mode static; }
    case "$mode" in
        static) sd_horae "$(sd_state_get horae 1)"; sd_shell_emul "$(sd_shell_target)" ;;
        charge) sd_horae 1 ;;
    esac

    # 核心/非核心是持久 bind mount，重启后必须重建。
    # 历史版本可能写下过非法值，这里顺手纠正，避免每次开机白试一遍。
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

    # settings 是持久的，正常重启不用重写；这里只处理被系统/OTA 重置的情况
    sd_hz_boot

    sd_info boot "状态恢复: temp=$mode core=$c noncore=$nc hz=$(sd_state_get hz off)"
}

# ---------- 守护 ----------

sd_daemon() {
    local lock="$SD_RUN/daemon.lock" holder tick wall aggr
    local mode last_mode="" cnt=0
    _sd_sp=""
    _sd_reload=0

    # mkdir 是原子的。先读 pidfile 再判断在两进程同时启动时都会通过检查，
    # 结果拉起两个守护而 pidfile 只记得最后一个 —— 卸载就漏杀。
    if ! mkdir "$lock" 2>/dev/null; then
        read -r holder 2>/dev/null <"$lock/pid"
        if sd_pid_alive "$holder"; then
            sd_info daemon "已有守护在运行(pid=$holder)，本实例退出"
            exit 0
        fi
        rm -rf "$lock" 2>/dev/null
        mkdir "$lock" 2>/dev/null || exit 0
    fi
    printf '%s\n' "$$" >"$lock/pid"
    printf '%s\n' "$$" >"$SD_RUN/daemon.pid"

    sd_state_load
    sd_zone_scan
    sd_session daemon "守护启动"
    sd_info daemon "守护启动 pid=$$"

    trap 'sd_info daemon "收到 TERM，退出"; rm -rf "$SD_RUN/daemon.lock"; rm -f "$SD_RUN/daemon.pid"; exit 0' TERM INT

    # USR1：参数被改过，打断 sleep 立刻进入下一轮。默认动作是终止进程，
    # 必须显式接管，否则 WebUI 一改参数守护就没了。
    trap 'sd_info daemon "收到重载信号，立即刷新参数"; [ -n "${_sd_sp:-}" ] && kill "$_sd_sp" 2>/dev/null; _sd_reload=1' USR1

    sd_wait_boot || sd_warn daemon "等待 boot_completed 超时，继续启动"

    tick=$(sd_state_int tick 15 5 300)
    wall=$(sd_state_get wall off)
    aggr=$(sd_state_int aggr 10 0 10)
    sd_info daemon "循环参数: tick=${tick}s wall=${wall} aggr=${aggr} curr_max=$(sd_state_get curr_max 0)"

    # sleep 放后台再 wait：收到信号时 wait 立即返回，sleep 子进程被 kill，
    # 不必等满 15 秒。直接把 sleep 放前台的话信号会一直压到它睡完。
    _sd_pause() {
        sleep "$1" & _sd_sp=$!
        wait $_sd_sp 2>/dev/null
        _sd_sp=""
    }

    while :; do
        # 每 tick 重新读 state：用户改完参数最多等一个 tick 生效，不用重启守护。
        # read 循环是内建的，不产生 fork。
        sd_state_load
        if [ "$_sd_reload" = 1 ]; then
            _sd_reload=0
            tick=$(sd_state_int tick 15 5 300)
            wall=$(sd_state_get wall off)
            aggr=$(sd_state_int aggr 10 0 10)
        fi

        # 模块被删除后自己退出，不用等重启
        if [ ! -f "$MODDIR/service.sh" ]; then
            sd_info daemon "模块目录已移除，守护退出"
            break
        fi

        # zone 表定期重扫：传感器可能在启动后才注册
        cnt=$((cnt + 1))
        [ $((cnt % 40)) -eq 0 ] && sd_zone_scan

        if ! sd_sentinel_guard; then
            _sd_pause "$tick"
            continue
        fi

        mode=$_st_temp_mode
        if [ "$mode" != "$last_mode" ]; then
            sd_info daemon "温度模式: ${last_mode:-<无>} → $mode"
            last_mode=$mode
            wall=$(sd_state_get wall off)
            aggr=$(sd_state_int aggr 10 0 10)
            _sd_emul_last=""
        fi

        case "$mode" in
            static)
                # 不用 $(...) 取返回值：命令替换是子 shell，会把 _sd_last_cur
                # 一起关在里面；直接调用还能省掉每 tick 一次 fork。
                sd_shell_target >/dev/null
                sd_shell_emul "$_sd_last_out"
                # 每分钟一条摘要：出问题时能看到最后的真实/上报温度，
                # 又不会像 debug 那样刷屏。
                if [ $((cnt % 12)) -eq 0 ]; then
                    sd_info daemon "摘要 真实=${_sd_last_cur:-?}℃ 上报=${_sd_last_out:-0}℃ 墙=$(sd_state_get wall off)"
                fi
                ;;
            charge)
                sd_charge_tick
                ;;
        esac

        _sd_pause "$tick"
    done

    rm -rf "$SD_RUN/daemon.lock" "$SD_RUN/daemon.pid"
    sd_info daemon "守护已停止"
}

# ---------- 入口 ----------

if [ "$1" = "--daemon" ]; then
    sd_daemon
    exit 0
fi

sd_session boot "service 阶段启动"
sd_dump_env

sd_wait_boot 60 || { sd_warn boot "boot_completed 未在 60s 内就绪，退出"; exit 0; }
[ "$(getprop sys.boot_completed)" = "1" ] || exit 0

# 走到这里说明这次没翻车，清掉自救计数
printf '0\n' 2>/dev/null >"$SD_DATA/boot.count"

# 元模块场景下 post-fs-data 可能没跑，或被安全模式跳过，这里补一次挂载。
# 判定依据是挂载此刻是否真的存在，不是清单文件是否非空。
if ! sd_mounts_alive; then
    sd_info boot "覆盖层未生效，补充挂载"
    sd_mount_overrides
fi

sd_apply_state

if sd_daemon_pid >/dev/null; then
    sd_info boot "守护已在运行，跳过"
else
    nohup sh "$MODDIR/service.sh" --daemon >/dev/null 2>&1 &
    sleep 1
    sd_info boot "守护已拉起"
fi
