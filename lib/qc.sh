#!/system/bin/sh
# Quick Charge (QC) 核心库 —— 单文件。
# 覆盖三条链路：系统配置改写、运行时温度伪装、充电限流。
# 全部 POSIX sh，兼容 Android mksh / busybox ash / bash。

# ============================================================================
# 路径与目录
# ============================================================================

[ -n "$MODDIR" ] || MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd)

SD_DATA="${SD_DATA:-/data/adb/quickcharge}"
# 路径保护：元模块传空或传 "/" 时，卸载的 rm -rf 会删系统
case "$SD_DATA" in
    ""|/|/data|/data/adb|/data/adb/) SD_DATA=/data/adb/quickcharge ;;
esac

SD_STATE="$SD_DATA/state.conf"
SD_LOG="$SD_DATA/log.txt"
SD_OLD="$SD_DATA/log.old.txt"
SD_MOUNTS="$SD_DATA/mounts.list"
SD_BACKUP="$SD_DATA/backup"
SD_RUN="$SD_DATA/run"
SD_BUILT="$SD_DATA/built.id"
SD_PS=/sys/class/power_supply
# 欧加真专属充电节点。bcc_parms 里有每颗电芯的电压，双电芯机型
# 只有这里能拿到真实总压；不存在时退回 SD_PS 的通用节点。
SD_OPLUS_CHG="${SD_OPLUS_CHG:-/sys/class/oplus_chg/battery}"

# 探测方式必须是 mkdir 而不是 `{ : >file; } 2>/dev/null`：
# dash / mksh 在重定向失败时会让整个 shell 以 rc=2 退出，且不打印任何错误。
SD_OVERRIDES="$MODDIR/files"
if mkdir -p "$SD_OVERRIDES/.wtest" 2>/dev/null; then
    rmdir "$SD_OVERRIDES/.wtest" 2>/dev/null
else
    SD_OVERRIDES="$SD_DATA/overrides"
fi

for _d in "$SD_DATA" "$SD_BACKUP" "$SD_RUN" "$SD_OVERRIDES"; do
    [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
done

# 温度节点根。SD_ZONE_GLOB 可覆盖，用于非标准路径机型和离线测试。
[ -n "${SD_ZONE_GLOB:-}" ] || SD_ZONE_GLOB=/sys/class/thermal/thermal_zone*

# ============================================================================
# 日志
#
# 一行格式：11-07 16:42:03 I [thermal] 伪装 core → 55℃
# 级别     E=1 失败但继续 / W=2 异常已处理 / I=3 状态变化 / D=4 每 tick 细节
# 来源     boot mount override thermal guard charge daemon cmd
# 排查     grep ' E \[' log.txt      所有失败点
#          grep '\[charge\]'        整条充电链路
# ============================================================================

_sd_lv=3
_sd_rot=0

_sd_emit() {
    local lv="$1" tag="$2" need
    shift 2
    case "$lv" in
        E) need=1 ;; W) need=2 ;; D) need=4 ;; *) need=3 ;;
    esac
    [ "$_sd_lv" -ge "$need" ] || return 0
    printf '%s %s [%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$lv" "$tag" "$*" 2>/dev/null >>"$SD_LOG"
    [ -n "${SD_VERBOSE:-}" ] && printf '%s [%s] %s\n' "$lv" "$tag" "$*"

    # 轮转：每 64 条检查一次大小，超过 512KB 换一份，只留一代。
    _sd_rot=$((_sd_rot + 1))
    if [ $((_sd_rot & 63)) -eq 0 ] && [ "$(wc -c 2>/dev/null <"$SD_LOG" || echo 0)" -gt 524288 ]; then
        mv -f "$SD_LOG" "$SD_OLD" 2>/dev/null
    fi
    return 0
}

sd_dbg()  { _sd_emit D "$@"; }
sd_info() { _sd_emit I "$@"; }
sd_warn() { _sd_emit W "$@"; }
sd_err()  { _sd_emit E "$@"; }

# 会话分隔线：一次开机 / 一条命令的起点
sd_session() {
    local tag="$1"
    shift
    printf '\n======== %s | %s | pid=%s ========\n' \
        "$(date '+%m-%d %H:%M:%S')" "$tag" "$$" 2>/dev/null >>"$SD_LOG"
    [ "$#" -gt 0 ] && printf '  %s\n' "$*" 2>/dev/null >>"$SD_LOG"
    return 0
}

# 环境快照。远程排查时缺了这段基本无法判断问题出在模块还是设备差异上。
sd_dump_env() {
    local dev rom kver zones emul sentinel stype stemp slim _e
    dev="$(getprop ro.product.odm.manufacturer 2>/dev/null) $(getprop ro.product.model 2>/dev/null)"
    dev=$(printf '%s' "$dev" | sed 's/^ *//; s/ *$//')
    rom=$(getprop ro.build.display.id 2>/dev/null)
    kver=$(uname -r 2>/dev/null)
    sd_zone_scan

    zones=0
    emul=""
    for _e in $_sd_zones; do
        zones=$((zones + 1))
        [ -e "${_e%%|*}/emul_temp" ] && emul="$emul $(basename "${_e%%|*}")"
    done
    [ -e /proc/shell-temp ] && _sh=yes || _sh=no

    sentinel=$(sd_pick_sentinel 2>/dev/null)
    if [ -n "$sentinel" ]; then
        stype=$(cat "$sentinel/type" 2>/dev/null)
        stemp=$(sd_sentinel_temp "$sentinel" 2>/dev/null)
        slim=$(sd_limit_for_zone "$sentinel" 2>/dev/null)
    fi

    _sd_emit I env "device=${dev:-?} rom=${rom:-?} kernel=${kver:-?}"
    _sd_emit I env "zones=$zones emul=[${emul# }] shell-temp=$_sh charge-nodes=$(sd_curr_nodes 2>/dev/null | wc -l | tr -d ' ')"
    if [ -n "$sentinel" ]; then
        _sd_emit I env "sentinel=$(basename "$sentinel") type=${stype:-?} temp=${stemp:-?}℃ limit=${slim:-?}℃"
    else
        _sd_emit I env "sentinel=none（未找到电池/主板温度节点，伪装无法工作）"
    fi
    _sd_emit I env "state=$(sd_state_dump)"
    return 0
}

# ============================================================================
# 状态
#
# 存放在 /data/adb/quickcharge/state.conf，卸载重装不丢。
# 读取走内存缓存：守护每 tick 要读十几个键，逐个 grep 会产生几十次 fork。
# 这里一次 read 循环把全表装进 _st_* 变量，之后 sd_state_get 是纯内建调用。
# ============================================================================

_sd_st_loaded=0
_st_temp_mode=""
_st_shell_temp=""
_st_core_temp=""
_st_noncore_temp=""
_st_horae=""
_st_sentinel_limit=""
_st_battery_limit=""
_st_fast_cap=""
_st_curve_offset=""
_st_wall=""
_st_aggr=""
_st_curr_max=""
_st_log_level=""
_st_tick=""
_st_defrev=""
_st_hz=""
_st_hz_prev_peak=""
_st_hz_prev_min=""
_st_hz_hard=""
_st_hz_prev_mcfr=""
_st_power_scale=""

sd_state_load() {
    _sd_st_loaded=1
    _st_temp_mode=""; _st_shell_temp=""; _st_core_temp=""; _st_noncore_temp=""
    _st_horae=""; _st_sentinel_limit=""; _st_battery_limit=""; _st_fast_cap=""
    _st_curve_offset=""; _st_wall=""; _st_aggr=""; _st_curr_max=""
    _st_log_level=""; _st_tick=""; _st_defrev=""
    _st_hz=""; _st_hz_prev_peak=""; _st_hz_prev_min=""; _st_hz_hard=""; _st_hz_prev_mcfr=""; _st_power_scale=""
    [ -f "$SD_STATE" ] || { _st_log_level=3; _sd_lv=3; return 0; }
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            temp_mode)      _st_temp_mode=$v ;;
            shell_temp)     _st_shell_temp=$v ;;
            core_temp)      _st_core_temp=$v ;;
            noncore_temp)   _st_noncore_temp=$v ;;
            horae)          _st_horae=$v ;;
            sentinel_limit) _st_sentinel_limit=$v ;;
            battery_limit)  _st_battery_limit=$v ;;
            fast_cap)       _st_fast_cap=$v ;;
            curve_offset)   _st_curve_offset=$v ;;
            wall)           _st_wall=$v ;;
            aggr)           _st_aggr=$v ;;
            curr_max)       _st_curr_max=$v ;;
            log_level)      _st_log_level=$v ;;
            tick)           _st_tick=$v ;;
            defrev)         _st_defrev=$v ;;
            hz)             _st_hz=$v ;;
            hz_prev_peak)   _st_hz_prev_peak=$v ;;
            hz_prev_min)    _st_hz_prev_min=$v ;;
            hz_hard)        _st_hz_hard=$v ;;
            hz_prev_mcfr)   _st_hz_prev_mcfr=$v ;;
            power_scale)    _st_power_scale=$v ;;
        esac
    done 2>/dev/null <"$SD_STATE"
    case "$_st_log_level" in 0|1|2|3|4) _sd_lv=$_st_log_level ;; *) _st_log_level=3; _sd_lv=3 ;; esac
    return 0
}

# 用户改了 log_level 后让缓存失效
sd_log_reload() { _sd_st_loaded=0; sd_state_load; }

sd_state_get() {
    [ "$_sd_st_loaded" = 1 ] || sd_state_load
    case "$1" in
        temp_mode)      printf '%s' "${_st_temp_mode:-${2:-off}}" ;;
        shell_temp)     printf '%s' "${_st_shell_temp:-${2:-30}}" ;;
        core_temp)      printf '%s' "${_st_core_temp:-${2:-off}}" ;;
        noncore_temp)   printf '%s' "${_st_noncore_temp:-${2:-off}}" ;;
        horae)          printf '%s' "${_st_horae:-${2:-1}}" ;;
        sentinel_limit) printf '%s' "${_st_sentinel_limit:-${2:-85}}" ;;
        battery_limit)  printf '%s' "${_st_battery_limit:-${2:-48}}" ;;
        fast_cap)       printf '%s' "${_st_fast_cap:-${2:-55}}" ;;
        curve_offset)   printf '%s' "${_st_curve_offset:-${2:-120}}" ;;
        wall)           printf '%s' "${_st_wall:-${2:-42}}" ;;
        aggr)           printf '%s' "${_st_aggr:-${2:-10}}" ;;
        curr_max)       printf '%s' "${_st_curr_max:-${2:-0}}" ;;
        log_level)      printf '%s' "${_st_log_level:-${2:-3}}" ;;
        tick)           printf '%s' "${_st_tick:-${2:-15}}" ;;
        defrev)         printf '%s' "${_st_defrev:-${2:-2}}" ;;
        hz)             printf '%s' "${_st_hz:-${2:-off}}" ;;
        hz_prev_peak)   printf '%s' "${_st_hz_prev_peak:-${2:-}}" ;;
        hz_prev_min)    printf '%s' "${_st_hz_prev_min:-${2:-}}" ;;
        hz_hard)        printf '%s' "${_st_hz_hard:-${2:-0}}" ;;
        hz_prev_mcfr)   printf '%s' "${_st_hz_prev_mcfr:-${2:-}}" ;;
        power_scale)    printf '%s' "${_st_power_scale:-${2:-100}}" ;;
        *)              printf '%s' "${2:-}" ;;
    esac
}

sd_state_set() {
    local k="$1" v="$2"
    [ "$_sd_st_loaded" = 1 ] || sd_state_load
    case "$k" in
        temp_mode)      _st_temp_mode=$v ;;
        shell_temp)     _st_shell_temp=$v ;;
        core_temp)      _st_core_temp=$v ;;
        noncore_temp)   _st_noncore_temp=$v ;;
        horae)          _st_horae=$v ;;
        sentinel_limit) _st_sentinel_limit=$v ;;
        battery_limit)  _st_battery_limit=$v ;;
        fast_cap)       _st_fast_cap=$v ;;
        curve_offset)   _st_curve_offset=$v ;;
        wall)           _st_wall=$v ;;
        aggr)           _st_aggr=$v ;;
        curr_max)       _st_curr_max=$v ;;
        log_level)      _st_log_level=$v
                        case "$v" in 0|1|2|3|4) _sd_lv=$v ;; esac ;;
        tick)           _st_tick=$v ;;
        defrev)         _st_defrev=$v ;;
        hz)             _st_hz=$v ;;
        hz_prev_peak)   _st_hz_prev_peak=$v ;;
        hz_prev_min)    _st_hz_prev_min=$v ;;
        hz_hard)        _st_hz_hard=$v ;;
        hz_prev_mcfr)   _st_hz_prev_mcfr=$v ;;
        power_scale)    _st_power_scale=$v ;;
    esac
    [ -f "$SD_STATE" ] || : >"$SD_STATE"
    if grep -q "^$k=" "$SD_STATE" 2>/dev/null; then
        awk -v k="$k" -v v="$v" 'BEGIN{FS="="} $1==k{print k"="v;next}{print}' \
            "$SD_STATE" >"$SD_STATE.t" && mv -f "$SD_STATE.t" "$SD_STATE"
    else
        printf '%s=%s\n' "$k" "$v" >>"$SD_STATE"
    fi
}

# 取整数状态键，非法/越界一律回落默认。集中在这里，避免每个调用点各写一遍。
sd_state_int() {
    local v
    v=$(sd_state_get "$1" "$2")
    case "$v" in ''|*[!0-9]*) v="$2" ;; esac
    [ -n "$3" ] && [ "$v" -lt "$3" ] && v="$2"
    [ -n "$4" ] && [ "$v" -gt "$4" ] && v="$2"
    printf '%s' "$v"
}

sd_state_dump() {
    [ -f "$SD_STATE" ] || { printf 'empty'; return 0; }
    awk 'BEGIN{FS="=";s=""} $1!=""&&$1!~/^#/{s=s (s==""?"":" ") $0} END{print (s==""?"empty":s)}' \
        "$SD_STATE" 2>/dev/null
}

# ============================================================================
# 进程
# ============================================================================

sd_pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

sd_daemon_pid() {
    local pid
    read -r pid 2>/dev/null <"$SD_RUN/daemon.pid"
    # pid 必须 >1 且确实是本模块的守护。文件损坏成空/乱码/1 时不能判"在跑"，
    # 否则用户改完参数却没有任何进程在执行；pid 还会被系统复用，只看存活会误判。
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] || return 1
    sd_pid_alive "$pid" || return 1
    grep -q "service\.sh" "/proc/$pid/cmdline" 2>/dev/null || return 1
    printf '%s' "$pid"
}

sd_daemon_stop() {
    local pid i=0
    pid=$(sd_daemon_pid) || { rm -f "$SD_RUN/daemon.pid"; return 0; }
    kill -TERM "$pid" 2>/dev/null
    while sd_pid_alive "$pid" && [ "$i" -lt 20 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    sd_pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null
    rm -rf "$SD_RUN/daemon.lock" "$SD_RUN/daemon.pid"
}

# 叫醒守护立刻重读 state，不用等完当前 tick。
# WebUI 改完参数后最多 15 秒才生效，用户会以为没生效而反复拖滑块。
sd_daemon_kick() {
    local pid
    pid=$(sd_daemon_pid 2>/dev/null) || return 0
    kill -USR1 "$pid" 2>/dev/null
    return 0
}

# ============================================================================
# 工具
# ============================================================================

sd_valid_temp() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 20 ] && [ "$1" -le 100 ]
}

# 上限 60 秒不是 180：late_start 到 boot_completed 通常 10~40 秒，60 秒足够；
# 万一被误在 post-fs-data 阶段调用，60 秒也远好过 3 分钟。
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

sd_batt_capacity() {
    local v=""
    read -r v 2>/dev/null <"$SD_PS/battery/capacity"
    case "$v" in ''|*[!0-9]*) echo 100 ;; *) echo "$v" ;; esac
}

sd_batt_status() {
    local v=""
    read -r v 2>/dev/null <"$SD_PS/battery/status"
    printf '%s' "${v:-Unknown}"
}

# ============================================================================
# 温度节点
#
# 扫描结果缓存在 _sd_zones（"路径|类型" 空格分隔）。守护每 tick 都要遍历设备
# 全部温区，逐个 cat type 会产生 2N 次 fork —— 这是上一版最大的开销来源。
# 缓存后 tick 内零 fork；守护每 40 tick（约 10 分钟）重扫一次，兼顾热插拔。
# ============================================================================

_sd_zones=""
_sd_scanned=0
_sd_last_cur=""
_sd_last_out=""

sd_zone_scan() {
    local z t s=""
    for z in $SD_ZONE_GLOB; do
        [ -d "$z" ] || continue
        t=""
        read -r t 2>/dev/null <"$z/type"
        [ -n "$t" ] || continue
        s="$s $z|$t"
    done
    _sd_zones="$s"
    _sd_scanned=1
}

# 惰性初始化：调用方不必记得先扫描。守护循环里已显式扫过，这里直接返回。
_sd_zones_ready() { [ "$_sd_scanned" = 1 ] || sd_zone_scan; }

sd_zone_is_core() {
    case "$1" in cpu*|gpu*|ddr*) return 0 ;; esac
    return 1
}

sd_zone_is_shell() {
    case "$1" in shell*) return 0 ;; esac
    return 1
}

# 受保护传感器：电池 NTC / 主板温度永不参与伪装，专留给安全哨兵。
# 把它们一起钉死会让充电 IC 失去温度反馈，是"充着电死机"的主要来源。
sd_zone_is_guarded() {
    case "$1" in battery|Battery|batt*|xo-therm|xtherm*) return 0 ;; esac
    return 1
}

sd_zone_in_scope() {
    case "$2" in
        core)    sd_zone_is_core "$1" ;;
        noncore) sd_zone_is_core "$1" && return 1
                 sd_zone_is_shell "$1" && return 1
                 sd_zone_is_guarded "$1" && return 1
                 return 0 ;;
        *)       return 0 ;;
    esac
}

# 哨兵优先级：电池 > 主板 > 任意非 core/shell 温区。
# 不选 cpu-0-0：CPU 正是伪装对象，钉死之后哨兵就失效了。
sd_pick_sentinel() {
    local e z t want
    _sd_zones_ready
    for want in battery Battery batt xo-therm xtherm; do
        for e in $_sd_zones; do
            z=${e%%|*}
            t=${e#*|}
            [ "$t" = "$want" ] && [ -r "$z/temp" ] && { printf '%s' "$z"; return 0; }
        done
    done
    for e in $_sd_zones; do
        z=${e%%|*}
        t=${e#*|}
        sd_zone_is_core "$t" && continue
        sd_zone_is_shell "$t" && continue
        [ -r "$z/temp" ] && { printf '%s' "$z"; return 0; }
    done
    return 1
}

# 电池 48℃ 已是严重过热，SoC 结温 85℃ 才需要干预 —— 用同一个阈值等于没保护。
# off 必须原样透传：sd_state_int 会把 off 转成默认值，让"关闭熔断"失效。
sd_limit_for_zone() {
    local t v
    _sd_zones_ready
    read -r t 2>/dev/null <"$1/type"
    # 越界回落默认，与其它参数一致：手改 state.conf 写 battery_limit=200
    # 会让熔断永不触发，等于把唯一可信的一路保护关掉。
    case "$t" in
        battery|Battery|batt*)
            v=$(sd_state_get battery_limit 48)
            [ "$v" = off ] && { printf 'off'; return 0; }
            sd_state_int battery_limit 48 30 70
            ;;
        *)
            v=$(sd_state_get sentinel_limit 85)
            [ "$v" = off ] && { printf 'off'; return 0; }
            sd_state_int sentinel_limit 85 60 110
            ;;
    esac
}

# 哨兵当前温度（℃）。失败返回非 0，由调用方决定放弃伪装。
sd_sentinel_temp() {
    local z="$1" v=""
    [ -n "$z" ] || return 1
    read -r v 2>/dev/null <"$z/temp"
    case "$v" in ''|*[!0-9-]*) return 1 ;; esac
    # -1 在部分平台表示"传感器不可用"，当温度用会把负值带进下游的 max/min
    case "$v" in -*) return 1 ;; esac
    # 有的平台给摄氏度，有的给毫摄氏度
    if [ "$v" -gt 2000 ]; then echo $((v / 1000)); else echo "$v"; fi
}

sd_wall() {
    case "$(sd_state_get wall off)" in
        off|'') printf '0' ;;
        *) sd_state_int wall 42 35 80 ;;
    esac
}

# 暴力程度 → 允许拉开的温差：0→2℃（几乎不伪装），10→12℃（默认满功率）
sd_max_gap() { printf '%s' $((2 + $(sd_state_int aggr 10 0 10))); }

# ============================================================================
# 温度决策
# ============================================================================

# ---------------------------------------------------------------------------
# 热路径取值：不产生子 shell
#
# 守护每 tick 走一遍温度决策。原先 td_state_get / td_state_int /
# td_sentinel_temp 都以 $() 取返回值，一次 tick 会 fork 二十多个子 shell；
# 每个子 shell 都要 fork 一次，真机 mksh 上单次 0.5~1.5ms，合计十几到几十
# 毫秒，还每次都把 CPU 从 idle 唤醒。
#
# 这里给热路径配一套「写全局变量」的版本，语义与原来的函数完全一致，只是
# 不再 fork。冷路径（action.sh / 开机恢复）继续用原函数 —— 那边本来就要
# 起一个进程，几个 fork 无足轻重。
# ---------------------------------------------------------------------------

_sd_rv=""
_sd_sent_type=""

# 整数校验 + 越界回落默认值，结果写 _sd_rv
_sd_clamp() {
    local v="$1"
    case "$v" in ''|*[!0-9]*) _sd_rv="$4"; return 0 ;; esac
    if [ "$v" -lt "$2" ] || [ "$v" -gt "$3" ]; then
        _sd_rv="$4"
        return 0
    fi
    _sd_rv="$v"
}

# 哨兵温度 → _sd_rv。语义同 sd_sentinel_temp：负数与不可读一律失败。
sd_sentinel_temp_v() {
    local v=""
    [ -n "$1" ] || return 1
    read -r v 2>/dev/null <"$1/temp"
    case "$v" in ''|*[!0-9-]*) return 1 ;; esac
    case "$v" in -*) return 1 ;; esac
    if [ "$v" -gt 2000 ]; then _sd_rv=$((v / 1000)); else _sd_rv=$v; fi
    return 0
}

# 选哨兵 → _sd_rv（路径）、_sd_sent_type（type）。语义同 sd_pick_sentinel。
sd_pick_sentinel_v() {
    local e z t want
    _sd_zones_ready
    for want in battery Battery batt xo-therm xtherm; do
        for e in $_sd_zones; do
            z=${e%%|*}
            t=${e#*|}
            [ "$t" = "$want" ] && [ -r "$z/temp" ] && {
                _sd_rv=$z; _sd_sent_type=$t; return 0
            }
        done
    done
    for e in $_sd_zones; do
        z=${e%%|*}
        t=${e#*|}
        sd_zone_is_core "$t" && continue
        sd_zone_is_shell "$t" && continue
        [ -r "$z/temp" ] && { _sd_rv=$z; _sd_sent_type=$t; return 0; }
    done
    return 1
}

# 按 type 算熔断上限 → _sd_rv。语义同 sd_limit_for_zone，但复用已缓存的 type，
# 不再重读 sysfs。
sd_limit_for_type_v() {
    case "$1" in
        battery|Battery|batt*)
            case "${_st_battery_limit:-48}" in
                off) _sd_rv=off; return 0 ;;
            esac
            _sd_clamp "${_st_battery_limit:-48}" 30 70 48 ;;
        *)
            case "${_st_sentinel_limit:-85}" in
                off) _sd_rv=off; return 0 ;;
            esac
            _sd_clamp "${_st_sentinel_limit:-85}" 60 110 85 ;;
    esac
    return 0
}

# 计算本次应上报的壳温。返回 0 表示关闭模拟、交还真实读数。
#
# 三条约束，每条都是实测踩出来的：
#   1. base 必须落在 [25,60]。熔断后 shell_temp 会被置 0，charge 模式初始值也是 0，
#      不纠正就会把 0℃ 喂给系统 —— 多数 thermal HAL 视为传感器故障。
#   2. 上报值绝不超过真实温度。超了不是降温伪装，而是伪造高温，系统会提前降频。
#   3. 越接近温度墙收益越小，最后 4℃ 等步长爬升到墙，与"关闭模拟"无缝衔接。
#      等步长是必须的：从 30 直跳 42 会让系统看到壳温突变 12℃，触发一次降频。
sd_shell_target() {
    local base gap wall z cur limit barrier room climb v
    _sd_last_cur=""
    _sd_last_out=0
    [ "$_sd_st_loaded" = 1 ] || sd_state_load

    _sd_clamp "${_st_shell_temp:-30}" 25 60 30
    base=$_sd_rv
    _sd_clamp "${_st_aggr:-10}" 0 10 10
    gap=$((2 + _sd_rv))
    case "${_st_wall:-off}" in
        off|'') wall=0 ;;
        *) _sd_clamp "${_st_wall:-42}" 35 80 42; wall=$_sd_rv ;;
    esac

    sd_pick_sentinel_v || { printf '0'; return 0; }
    z=$_sd_rv

    # 先读真实温度再分支：关闭熔断时同样要读，否则低温环境下会把 30℃ 报上去，
    # 伪造出偏高的壳温，系统反而提前降频，与目的相反。
    sd_sentinel_temp_v "$z" || { printf '0'; return 0; }
    cur=$_sd_rv

    sd_limit_for_type_v "$_sd_sent_type"
    limit=$_sd_rv

    case "$limit" in
        ''|0|off)
            [ "$base" -gt "$cur" ] && base=$cur
            _sd_last_cur=$cur
            _sd_last_out=$base
            printf '%s' "$base"
            return 0
            ;;
    esac

    # 屏障：设了墙用墙，没设就退到熔断阈值前 2℃
    if [ "$wall" -gt 0 ]; then
        barrier=$wall
    else
        barrier=$((limit - 2))
    fi

    # 到墙就关模拟，交还真实读数。不能把哨兵温度（电池）写进壳温节点 ——
    # 那等于伪造更高的壳温，系统会更早降频，比不干预更激进。
    if [ "$cur" -ge "$barrier" ]; then
        _sd_last_cur=$cur
        _sd_last_out=0
        printf '0'
        return 0
    fi

    room=$((barrier - cur))
    v=$base
    # 强度下限：base 与「真实-gap」取大。默认 30/12 → 38℃ 以下一律报 30℃
    [ $((cur - gap)) -gt "$v" ] && v=$((cur - gap))
    # 平滑下限：最后 4℃ 等步长爬升。必须与强度下限取大 —— aggr 调小时
    # 这条约束会比强度下限更激进（aggr=0 时 39℃ 下限 37、爬升 33，取小就成了
    # "越温和越猛"）。
    if [ "$room" -lt 4 ] && [ "$barrier" -gt "$base" ]; then
        climb=$((base + (barrier - base) * (4 - room) / 4))
        [ "$climb" -gt "$v" ] && v=$climb
    fi
    [ "$v" -gt "$cur" ] && v=$cur

    _sd_last_cur=$cur
    _sd_last_out=$v
    sd_dbg thermal "目标=${v}℃ base=${base} 真实=${cur} 屏障=${barrier} 余量=${room} gap=${gap}"
    printf '%s' "$v"
}


# ============================================================================
# 伪装应用
# ============================================================================

# 把指定范围的 temp 节点换成固定值。scope: core | noncore
# 注意不受温度墙约束：墙管的是"真实温度到哪停止伪装"，用户显式要 55 就是 55。
sd_spoof_apply() {
    local scope="$1" celsius="$2" sentinel ms e z t n=0 fail=0
    case "$celsius" in
        ''|*[!0-9]*) sd_err thermal "伪温度参数非法: $celsius"; return 1 ;;
    esac
    if [ "$celsius" -lt 20 ] || [ "$celsius" -gt 100 ]; then
        sd_err thermal "伪温度超出合理范围(20-100℃): $celsius"
        return 1
    fi

    _sd_zones_ready
    sentinel=$(sd_pick_sentinel)
    ms=$((celsius * 1000))

    for e in $_sd_zones; do
        z=${e%%|*}
        t=${e#*|}
        [ -n "$sentinel" ] && [ "$z" = "$sentinel" ] && continue
        sd_zone_in_scope "$t" "$scope" || continue
        [ -e "$z/temp" ] || continue

        umount -l "$z/temp" 2>/dev/null
        if ! printf '%s\n' "$ms" >"$SD_RUN/$(basename "$z").temp" 2>/dev/null; then
            sd_err thermal "写临时文件失败: $(basename "$z")"
            fail=$((fail + 1))
            continue
        fi
        # 不能用 [ -w ] 做前置判断：sysfs 的 temp 通常 0444，而 bind mount
        # 不需要目标可写，用 -w 会在部分 ROM 上把整段逻辑挡掉。
        if mount -o bind "$SD_RUN/$(basename "$z").temp" "$z/temp" 2>/dev/null; then
            n=$((n + 1))
            sd_dbg thermal "  ok $(basename "$z") ($t) → ${celsius}℃"
        else
            fail=$((fail + 1))
            sd_warn thermal "  挂载失败: $(basename "$z") ($t)"
        fi
    done

    sd_info thermal "伪装 $scope → ${celsius}℃，命中 $n，失败 $fail，哨兵=$(basename "${sentinel:-none}")"
    [ "$n" -gt 0 ]
}

sd_spoof_clear_scope() {
    local e z t n=0
    _sd_zones_ready
    for e in $_sd_zones; do
        z=${e%%|*}
        t=${e#*|}
        sd_zone_in_scope "$t" "$1" || continue
        umount "$z/temp" 2>/dev/null && n=$((n + 1))
    done
    sd_info thermal "撤销 $1 伪装，解除 $n 个节点"
}

sd_spoof_clear() {
    local e n=0
    _sd_zones_ready
    for e in $_sd_zones; do
        umount "${e%%|*}/temp" 2>/dev/null && n=$((n + 1))
    done
    rm -f "$SD_RUN"/*.temp 2>/dev/null
    sd_info thermal "撤销全部伪装，解除 $n 个节点"
}

# 壳温伪装：内核 emul_temp + OPPO 私有 /proc/shell-temp。0 = 关闭模拟。
# _sd_emul_last 记录上次写入值，值没变直接返回 —— 守护每 tick 都在打，避免无谓写入。
_sd_emul_last=""

sd_shell_emul() {
    local celsius="$1" ms e z t n=0
    _sd_zones_ready
    case "$celsius" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$celsius" -ne 0 ] && { [ "$celsius" -lt 20 ] || [ "$celsius" -gt 100 ]; }; then
        sd_err thermal "壳温超出合理范围(20-100℃): $celsius，忽略"
        return 1
    fi
    [ "$celsius" = "$_sd_emul_last" ] && return 0
    _sd_emul_last=$celsius
    ms=$((celsius * 1000))

    for e in $_sd_zones; do
        z=${e%%|*}
        t=${e#*|}
        sd_zone_is_shell "$t" || continue
        [ -e "$z/emul_temp" ] || continue
        # 不用 [ -w ] 判断：/proc 下的节点常是 0444，直接写、失败静默即可
        printf '%s\n' "$ms" 2>/dev/null >"$z/emul_temp" && n=$((n + 1))
    done

    if [ -e /proc/shell-temp ]; then
        t=0
        while [ "$t" -le 9 ]; do
            printf '%s %s\n' "$t" "$ms" 2>/dev/null >/proc/shell-temp
            t=$((t + 1))
        done
    fi

    if [ "$celsius" -eq 0 ]; then
        sd_dbg thermal "关闭壳温模拟，改读真实读数"
    elif [ "$n" -gt 0 ]; then
        sd_dbg thermal "壳温写 ${celsius}℃ 到 $n 个节点"
    else
        sd_warn thermal "壳温节点不可写（emul_temp 未启用？），目标 ${celsius}℃"
    fi
    return 0
}

# 单个哨兵是否越限。返回 0 表示熔断（已撤销伪装）。
# type 传空时读一次 sysfs 兜底，覆盖"没有电池/主板节点、退回首个非 core 节点"
# 的那条路径。
sd_guard_one() {
    local z="$1" t="${2:-}" limit cur
    [ -n "$t" ] || read -r t 2>/dev/null <"$z/type"
    sd_limit_for_type_v "$t"
    limit=$_sd_rv
    case "$limit" in ''|0|off) return 1 ;; esac
    sd_sentinel_temp_v "$z" || return 1
    cur=$_sd_rv
    [ "$cur" -ge "$limit" ] || return 1

    sd_warn guard "⚠ 熔断：哨兵 ${z##*/} 实测 ${cur}℃ ≥ 上限 ${limit}℃"
    sd_spoof_clear
    _sd_emul_last=""
    sd_shell_emul 0
    sd_state_set temp_mode off
    sd_state_set core_temp off
    sd_state_set noncore_temp off
    sd_state_set shell_temp 0
    sd_warn guard "已撤销全部伪装并置 off，等待温度回落"
    return 0
}

# 熔断：电池与主板两路都查。此前只查 sd_pick_sentinel 选中的那一个
# （电池优先），设备有 battery 节点时 sentinel_limit 永远不会被读到，
# WebUI 上调 SoC 阈值等于没改。现在电池走 battery_limit，
# xo-therm 等走 sentinel_limit，任一超限即熔断。
sd_sentinel_guard() {
    local e z t fb="" fb_t="" checked=0
    [ "$_sd_st_loaded" = 1 ] || sd_state_load
    # 没有伪装在生效时直接放行，否则熔断后每 tick 都重清一遍并写日志。
    # 这里直接读 _st_*，不再为三个判断 fork 三次。
    if [ "${_st_temp_mode:-off}" = "off" ] \
        && [ "${_st_core_temp:-off}" = "off" ] \
        && [ "${_st_noncore_temp:-off}" = "off" ]; then
        return 0
    fi
    _sd_zones_ready
    for e in $_sd_zones; do
        z=${e%%|*}
        t=${e#*|}
        sd_zone_is_core "$t" && continue
        sd_zone_is_shell "$t" && continue
        [ -r "$z/temp" ] || continue
        case "$t" in
            battery|Battery|batt*|xo-therm|xtherm)
                checked=1
                sd_guard_one "$z" "$t" && return 1
                ;;
            *) [ -n "$fb" ] || { fb=$z; fb_t=$t; } ;;
        esac
    done
    # 没有明确的电池/主板节点时，退回第一个非 core/shell 节点
    if [ "$checked" -eq 0 ] && [ -n "$fb" ]; then
        sd_guard_one "$fb" "$fb_t" && return 1
    fi
    return 0
}

# horae 是 OPPO/realme 自有热管理，与 thermal-engine 并行。
# 绝不能写 init.svc.*：那是 init 维护的只读状态，写了无效且会让状态机错乱。
sd_horae() {
    case "$1" in
        1) setprop persist.sys.horae.enable 1; start horae 2>/dev/null; sd_info thermal "horae 启动" ;;
        0) setprop persist.sys.horae.enable 0; stop horae 2>/dev/null; sd_info thermal "horae 停止" ;;
    esac
}

# ============================================================================
# 配置改写
#
# 三条铁律：
#   1. 只改属性值，绝不删 XML 节点。删节点会留下无主闭标签，产出结构残缺的
#      XML，thermal HAL 解析失败 → 开机循环。
#   2. 产物落地前校验结构：开闭标签必须配平，标签总数必须与原件一致，
#      不一致直接丢弃。宁可不生效也不写坏文件。
#   3. 原件备份到 backup/，保留相对路径。
# ============================================================================

# 只扫 etc，不扫整个 /vendor —— 后者会遍历 bin/lib/firmware 几万个文件，
# 在 post-fs-data（总超时 40 秒）里非常危险。
SD_CFG_DIRS="/vendor/etc /odm/etc /system/vendor/etc /system/system_ext/etc /vendor/qti/etc"

sd_count_tags() { grep -o '<[/]*[A-Za-z_]' "$1" 2>/dev/null | wc -l | tr -d ' '; }

# 开闭标签配平。只比较"改写前后总数一致"不够：输入本身残缺时两边同样不配平、
# 计数也一致，会被误判通过，结果和没校验一样。
sd_xml_balanced() {
    local o c
    o=$(grep -o '<[A-Za-z_][^<>]*>' "$1" 2>/dev/null | grep -vcE '/[[:space:]]*>$')
    c=$(grep -o '</[A-Za-z_][^<>]*>' "$1" 2>/dev/null | wc -l | tr -d ' ')
    case "$o" in ''|*[!0-9]*) o=0 ;; esac
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    [ "$o" = "$c" ]
}

sd_verify_xml() {
    local a b
    [ -s "$2" ] || { sd_warn override "校验失败(空文件): $2"; return 1; }
    case "$(head -c 1 "$2" 2>/dev/null)" in
        '<') ;;
        *) sd_warn override "校验失败(非 XML): $2"; return 1 ;;
    esac
    sd_xml_balanced "$1" || { sd_warn override "校验失败(原件不配平，拒绝): $1"; return 1; }
    sd_xml_balanced "$2" || { sd_warn override "校验失败(产物不配平): $2"; return 1; }
    a=$(sd_count_tags "$1")
    b=$(sd_count_tags "$2")
    [ "$a" = "$b" ] || { sd_warn override "校验失败(标签数 $a → $b): $2"; return 1; }
    return 0
}

sd_verify_json() {
    local a b
    [ -s "$2" ] || return 1
    a=$(grep -o '[{}]' "$1" 2>/dev/null | wc -l | tr -d ' ')
    b=$(grep -o '[{}]' "$2" 2>/dev/null | wc -l | tr -d ' ')
    [ "$a" = "$b" ] || { sd_warn override "校验失败(括号数 $a → $b): $2"; return 1; }
    return 0
}

# 高温保护：只关开关不动阈值。阈值改 0 在部分平台表示"立即触发"，反而更严。
sd_xf_hightemp() {
    sed -E -e 's/([A-Za-z_]+=")true(")/\1false\2/g' -e 's/>true</>false</g' "$1" 2>/dev/null >"$2"
}

# 温控档位：开关置 false，档位数据原样保留。整表不参与决策比删行安全得多。
sd_xf_control() {
    sed -E 's/([A-Za-z_]+=")true(")/\1false\2/g' "$1" 2>/dev/null >"$2"
}

# 温控等级 → 帧率：全部放到 144。[0-9.]+ 限定字符集，避免贪婪匹配吃掉后续属性。
sd_xf_fps() {
    sed -E 's/fps="[0-9.]+"/fps="144"/g' "$1" 2>/dev/null >"$2"
}

# 老式全局温控：只处理含 enable 的行，避免 >1< 误伤其它字段
sd_xf_legacy() {
    sed -E '/[Ee]nable/ s/>1</>0</g' "$1" 2>/dev/null >"$2"
}

# 电池充电温度窗口 15–45℃ → 15–55℃。
# 不动 high.capacity.threshold：改 99 会让满电判断永不命中。
sd_xf_chargejson() {
    sed -E 's/150,450\]/150,550]/g' "$1" 2>/dev/null >"$2"
}

# 游戏温控取样节点：主板传感器 → 电池 NTC。电芯在机身中部、热耦合慢，
# 读数天然低几度，不改任何阈值就能让系统"觉得凉"。
sd_xf_qega() {
    sed -E \
        -e 's/(SkinTemperatureNode:[[:space:]]*)xo-therm/\1battery/' \
        -e '/^100001/s/^100001([[:space:]]+)hok[[:space:]]+48000[[:space:]]+1200/180001\1hok         55000          2000/' \
        -e '/^0[[:space:]]+adaptive/s/50000/55000/' \
        "$1" 2>/dev/null >"$2"
}

# 充电曲线温度轴右移 N 个刻度（0.1℃ 单位时 120 = +12℃）。
# 截断到 600（60℃）：原表尾部就是 550~600，右移越界会被 IC 解析成无效档位。
sd_xf_curve() {
    awk -F, -v off="$1" 'BEGIN{OFS=","}
        /^[0-9]+,[0-9]+,[0-9]+$/ { $1=$1+off; if ($1>600) $1=600; print; next }
        { print }' "$2" 2>/dev/null >"$3"
}

# horae 配置置空。空文件比删除安全：SELinux 标签保留，服务能 open 但读到 0 字节，
# 走"无策略"分支而不是异常分支。
sd_xf_horae() { : >"$2"; return 0; }

sd_transform() {
    local src="$1" dst="$2" tmp rc=1 kind=xml bk
    tmp="$dst.sdtmp"

    # 原件只备份一次，避免覆盖安装时把改过的文件当原件再改一遍
    bk="$SD_BACKUP$src"
    if [ ! -f "$bk" ]; then
        mkdir -p "$(dirname "$bk")" 2>/dev/null
        cp -p "$src" "$bk" 2>/dev/null
    fi
    mkdir -p "$(dirname "$dst")" 2>/dev/null

    case "${src##*/}" in
        sys_high_temp_protect_*.xml)   sd_xf_hightemp "$src" "$tmp"; rc=$? ;;
        sys_thermal_control_config*.xml) sd_xf_control "$src" "$tmp"; rc=$? ;;
        thermallevel_to_fps.xml)       sd_xf_fps "$src" "$tmp"; rc=$? ;;
        sys_thermal_config.xml)        sd_xf_legacy "$src" "$tmp"; rc=$? ;;
        devices_config.json)           kind=json; sd_xf_chargejson "$src" "$tmp"; rc=$? ;;
        QEGA_Config.txt)               kind=text; sd_xf_qega "$src" "$tmp"; rc=$? ;;
        charging_*.txt)                kind=text; sd_xf_curve "$(sd_state_int curve_offset 120 0 300)" "$src" "$tmp"; rc=$? ;;
        horae*.conf)                   kind=empty; sd_xf_horae "$src" "$tmp"; rc=$? ;;
        *) return 1 ;;
    esac

    if [ "$rc" -ne 0 ]; then
        rm -f "$tmp"
        sd_err override "改写失败: $src"
        return 1
    fi

    case "$kind" in
        xml)   sd_verify_xml "$src" "$tmp" || { rm -f "$tmp"; return 1; } ;;
        json)  sd_verify_json "$src" "$tmp" || { rm -f "$tmp"; return 1; } ;;
        text)  [ -s "$tmp" ] || { rm -f "$tmp"; return 1; } ;;
        empty) [ -f "$tmp" ] || { rm -f "$tmp"; return 1; } ;;
    esac

    mv -f "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

# 系统指纹。OTA 后 /vendor/etc 的温控配置会被整体替换，旧副本等于把新系统
# 降级回旧版本；post-fs-data 靠这个指纹判断是否需要重建。
sd_fingerprint() {
    printf '%s-%s' "$(getprop ro.build.display.id)" "$(getprop ro.build.version.security_patch)"
}

sd_build_overrides() {
    local fp base f rel
    fp=$(sd_fingerprint)

    # 路径保护：MODDIR 推导失败时 SD_OVERRIDES 会退化成 /files，下面有 rm -rf
    case "$SD_OVERRIDES" in
        ""|/|/files) sd_err override "覆盖层路径异常($SD_OVERRIDES)，中止"; return 1 ;;
    esac

    if [ -f "$SD_BUILT" ] && [ "$(cat "$SD_BUILT" 2>/dev/null)" = "$fp" ] \
        && [ -n "$(ls -A "$SD_OVERRIDES" 2>/dev/null)" ]; then
        sd_info override "配置已是最新($fp)，跳过"
        return 0
    fi

    sd_info override "开始生成，指纹=$fp"
    rm -rf "$SD_OVERRIDES"
    mkdir -p "$SD_OVERRIDES" 2>/dev/null

    for base in $SD_CFG_DIRS; do
        [ -d "$base" ] || continue
        find "$base" -maxdepth 2 -type f \( \
            -name 'sys_high_temp_protect_*.xml' -o \
            -name 'sys_thermal_control_config*.xml' -o \
            -name 'thermallevel_to_fps.xml' -o \
            -name 'sys_thermal_config.xml' -o \
            -name 'devices_config.json' -o \
            -name 'QEGA_Config.txt' -o \
            -name 'charging_*.txt' -o \
            -name 'horae*.conf' \
            \) 2>/dev/null | while IFS= read -r f; do
            rel="${f#/}"
            sd_transform "$f" "$SD_OVERRIDES/$rel"
        done
    done

    printf '%s' "$fp" 2>/dev/null >"$SD_BUILT"
    sd_info override "生成完成，文件数=$(find "$SD_OVERRIDES" -type f 2>/dev/null | wc -l | tr -d ' ')"
}

# ============================================================================
# 挂载
# ============================================================================

sd_mount_overrides() {
    local src rel dst n=0 nchg=0 chgfail="$SD_RUN/chcon.fail" total
    [ -d "$SD_OVERRIDES" ] || return 1

    sd_umount_overrides
    : >"$chgfail"
    total=$(find "$SD_OVERRIDES" -type f 2>/dev/null | wc -l | tr -d ' ')

    ( cd "$SD_OVERRIDES" 2>/dev/null || exit 1
      find . -type f 2>/dev/null | while IFS= read -r rel; do
          rel="${rel#./}"
          src="$SD_OVERRIDES/$rel"
          dst="/$rel"
          [ -e "$dst" ] || continue
          # bind mount 保持源 inode 的标签，不跟目标一致的话 vendor 域服务会被
          # SELinux 拒绝。单条失败只记 debug，最后汇总一条 W —— 否则十几条同样
          # 的 "chcon 失败" 会把真正有用的日志埋掉。
          chmod --reference="$dst" "$src" 2>/dev/null
          chown --reference="$dst" "$src" 2>/dev/null
          chcon --reference="$dst" "$src" 2>/dev/null || { echo "$dst" >>"$chgfail"; }
          umount -l "$dst" 2>/dev/null
          if mount -o bind "$src" "$dst" 2>/dev/null; then
              echo "$dst" >>"$SD_MOUNTS"
          else
              sd_err mount "挂载失败: $dst"
          fi
      done )

    n=$(sort -u "$SD_MOUNTS" 2>/dev/null | wc -l | tr -d ' ')
    nchg=$(wc -l 2>/dev/null <"$chgfail" | tr -d ' ')
    case "$nchg" in ''|*[!0-9]*) nchg=0 ;; esac
    [ "$nchg" -gt 0 ] && sd_warn mount "$nchg/$total 个文件 chcon 失败（清单: $chgfail）"
    sd_info mount "配置覆盖已挂载，累计 $n/$total 条"
}

# 清单非空不等于挂载还在：重启后内核挂载消失但文件还在，安全模式跳过挂载时
# 也会残留旧清单。只看文件会让 service.sh 误判而不再补挂。
sd_mounts_alive() {
    [ -s "$SD_MOUNTS" ] || return 1
    awk 'NR==FNR { if ($0!="") want[$0]=1; next }
         ($2 in want) { hit[$2]=1 }
         END { exit (length(hit)>0 ? 0 : 1) }' "$SD_MOUNTS" /proc/mounts 2>/dev/null
}

sd_umount_overrides() {
    local p left n mp
    # 卸载目标 = mounts.list ∪ 覆盖层反推。只依赖清单不够：清单丢失或截断时
    # 挂载还在却不知道卸哪里，只能重启。反推按目标路径精确匹配 —— 挂载源列
    # 在不同存储栈上表示不一致（overlay 环境直接显示 overlay），不能依赖。
    mp=$(awk '{print $2}' /proc/mounts 2>/dev/null)
    {
        [ -f "$SD_MOUNTS" ] && sort -u "$SD_MOUNTS" 2>/dev/null
        if [ -d "$SD_OVERRIDES" ]; then
            ( cd "$SD_OVERRIDES" 2>/dev/null || exit 0
              find . -type f 2>/dev/null | while IFS= read -r rel; do
                  dst="/${rel#./}"
                  printf '%s\n' "$mp" | grep -qxF "$dst" && printf '%s\n' "$dst"
              done )
        fi
    } | sort -u | while IFS= read -r p; do
        [ -n "$p" ] || continue
        # 只卸"文件型"挂载点。本模块的覆盖层挂在单个文件上，目标永远是 -f；
        # 若清单被写入 /vendor、/data 这类目录，umount 会卸掉整个分区。
        [ -f "$p" ] || continue
        # 普通 umount 优先：lazy 不立即生效，紧接着删源目录会让挂载点指向
        # 已删除的 inode，之后的 bind mount 全部解析失败 —— 最难查的一种残留。
        umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null
    done

    left=""
    if [ -d "$SD_OVERRIDES" ]; then
        mp=$(awk '{print $2}' /proc/mounts 2>/dev/null)
        left=$( cd "$SD_OVERRIDES" 2>/dev/null || exit 0
                find . -type f 2>/dev/null | while IFS= read -r rel; do
                    dst="/${rel#./}"
                    printf '%s\n' "$mp" | grep -qxF "$dst" && printf '%s\n' "$dst"
                done )
    fi
    if [ -n "$left" ]; then
        printf '%s\n' "$left" >"$SD_MOUNTS"
        n=$(printf '%s\n' "$left" | wc -l | tr -d ' ')
        sd_warn mount "$n 条未卸净，清单已保留待下次重试"
    else
        : >"$SD_MOUNTS"
        sd_info mount "配置覆盖已全部卸载"
    fi
}

# ============================================================================
# 充电
#
# 关于"调电流能不能加速"：基本不能。功率由适配器、协议、电芯内阻共同决定，
# curr_max 只是上限。调高没用，调低才会真的变慢。真正能提速的是让温度反馈
# 变低（壳温伪装）。所以这个参数的定位是限流保护，不是加速。
# ============================================================================

sd_curr_nodes() {
    local n
    if [ -n "${SD_CURR_NODES:-}" ]; then
        for n in $(printf '%s' "$SD_CURR_NODES" | tr ',' ' '); do
            [ -e "$n" ] && printf '%s\n' "$n"
        done
        return 0
    fi
    for n in \
        "$SD_PS/battery/constant_charge_current_max" \
        "$SD_PS/battery/constant_charge_current" \
        "$SD_PS/battery/current_max" \
        "$SD_PS/main/constant_charge_current_max" \
        "$SD_PS/bms/current_max" \
        "$SD_PS/usb/current_max" \
        /sys/devices/virtual/oplus_chg/battery/chg_current_max \
        /sys/devices/virtual/oplus_chg/battery/current_max
    do
        [ -e "$n" ] && printf '%s\n' "$n"
    done
}

sd_batt_power() {
    local v i
    read -r v 2>/dev/null <"$SD_PS/battery/voltage_now" || return 1
    read -r i 2>/dev/null <"$SD_PS/battery/current_now" || return 1
    i=${i#-}
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
    case "$i" in ''|*[!0-9]*) return 1 ;; esac
    [ "$v" -gt 0 ] && [ "$i" -gt 0 ] || return 1
    # µV×µA = pW；mV×mA = µW。双电芯按 ×2 估算。
    if [ "$v" -gt 1000000 ] && [ "$i" -gt 100000 ]; then
        awk -v v="$v" -v i="$i" 'BEGIN { printf "%.2f", v*i/1e12*2 }'
    else
        awk -v v="$v" -v i="$i" 'BEGIN { printf "%.2f", v*i/1e6*2 }'
    fi
}

# 按温度算本轮允许的电流上限（mA）。0 = 不限制。
# 分四档而非线性插值：充电 IC 对阶跃响应更稳定，日志也便于核对。
# 电流目标 → _sd_rv。零 fork 版本，供守护每 tick 调用。
sd_curr_target_v() {
    local ma wall cur pct
    [ "$_sd_st_loaded" = 1 ] || sd_state_load
    _sd_clamp "${_st_curr_max:-0}" 0 8000 0
    ma=$_sd_rv
    [ "$ma" -gt 0 ] || { _sd_rv=0; return 0; }

    sd_pick_sentinel_v || { _sd_rv=$ma; return 0; }
    sd_sentinel_temp_v "$_sd_rv" || { _sd_rv=$ma; return 0; }
    cur=$_sd_rv

    case "${_st_wall:-off}" in
        off|'') wall=42 ;;
        *) _sd_clamp "${_st_wall:-42}" 35 80 42; wall=$_sd_rv
           [ "$wall" -gt 0 ] || wall=42 ;;
    esac

    if [ "$cur" -ge "$wall" ]; then pct=25
    elif [ "$cur" -ge $((wall - 3)) ]; then pct=50
    elif [ "$cur" -ge $((wall - 8)) ]; then pct=75
    else pct=100
    fi

    sd_dbg charge "电流目标 ${cur}℃/墙${wall}℃ → ${pct}% of ${ma}mA"
    _sd_rv=$((ma * pct / 100))
    return 0
}

sd_curr_target() { sd_curr_target_v; printf '%s' "$_sd_rv"; }

sd_curr_keep() {
    local want ua margin n cur="" n_ok=0
    sd_curr_target_v
    want=$_sd_rv
    # 未设限流时连节点都不用探 —— 原来这里每 tick 白跑一次目标计算
    [ "$want" -gt 0 ] || return 0
    ua=$((want * 1000))
    margin=$((ua * 11 / 10))

    # set -- 是内建命令，不 fork；节点表本来就是固定的几个路径
    if [ -n "${SD_CURR_NODES:-}" ]; then
        set -- $(printf '%s' "$SD_CURR_NODES" | tr ',' ' ')
    else
        set -- \
            "$SD_PS/battery/constant_charge_current_max" \
            "$SD_PS/battery/constant_charge_current" \
            "$SD_PS/battery/current_max" \
            "$SD_PS/main/constant_charge_current_max" \
            "$SD_PS/bms/current_max" \
            "$SD_PS/usb/current_max" \
            /sys/devices/virtual/oplus_chg/battery/chg_current_max \
            /sys/devices/virtual/oplus_chg/battery/current_max
    fi

    for n in "$@"; do
        [ -e "$n" ] || continue
        read -r cur 2>/dev/null <"$n"
        case "$cur" in ''|*[!0-9]*) continue ;; esac
        if [ "$cur" -gt "$margin" ]; then
            printf '%s\n' "$ua" 2>/dev/null >"$n" && n_ok=$((n_ok + 1))
        fi
    done
    [ "$n_ok" -gt 0 ] && sd_info charge "电流墙被抬高，已压回 ${want}mA（$n_ok 节点）"
    return 0
}

# ============================================================================
# charge 模式：插电才伪装，拔电立刻交回系统
# ============================================================================

# 每 tick 调用。全部走内建 read 与 sd_shell_target（写全局变量），稳态 0 fork。
#
# 注意：这段在 2.6.3 重构时被整段删掉，但 service.sh 仍在调 sd_charge_tick，
# 结果是「仅充电」档每 tick 报 not found、完全不生效。补回来，并加守护级断言。
sd_charge_tick() {
    local st="" cap=0 fast_cap

    read -r st 2>/dev/null <"$SD_PS/battery/status"
    case "$st" in
        Charging|Full) ;;
        *)
            # 拔电：直接还原，不再走一遍完整的目标温度决策
            sd_shell_emul 0
            return 0 ;;
    esac

    # 电流墙独立于电量段：只要在充电就维持
    sd_curr_keep

    read -r cap 2>/dev/null <"$SD_PS/battery/capacity"
    case "$cap" in ''|*[!0-9]*) cap=0 ;; esac
    _sd_clamp "${_st_fast_cap:-55}" 20 90 55
    fast_cap=$_sd_rv

    # fast_cap 以上不再伪装，让系统正常进恒压段
    if [ "$cap" -lt "$fast_cap" ]; then
        sd_shell_target >/dev/null
        sd_shell_emul "$_sd_last_out"
    else
        sd_shell_emul 0
    fi
}


# ============================================================================
# 刷新率
#
# 只写系统键不足以保证"不降频"。Android 由 DisplayModeDirector 用固定
# 优先级的投票决定刷新率，高优先级会直接裁掉低优先级的区间：
#
#    3  min_refresh_rate（用户下限）
#    4  应用 Window.setFrameRate / preferredMin-MaxRefreshRate
#    5  preferredDisplayModeId
#    7  peak_refresh_rate（用户上限）
#    8  省电模式                 → 强制 [0,60]
#   10  皮肤温度 CRITICAL        → 强制 [0,60]
#   12  UDFPS 屏下指纹解锁       → 临时锁帧
#
# 所以 peak/min 只能"表达偏好"：挡不住 8/10/12，也挡不住 app 的逐层帧率
# 请求。本模块按两档实现，并如实上报当前实际处在哪一档：
#
#   soft（默认）只写 peak/min，系统仍可按内容与场景降频
#   hard         额外把 match_content_frame_rate 置 1（不接受内容帧率
#                匹配），再由守护每 tick 回读，键被系统改回就立即补写
#
# 即便 hard 也绕不过 8/10/12 —— 那是系统级的安全与体验策略，硬顶只是
# 把发热推给面板。检测到省电模式、或连续三次写不进去时主动退让并上报
# 原因，而不是每 15 秒和系统打一次架。
#
# 不走 SurfaceFlinger setDisplayMode：它绕过 DisplayManager 的分辨率与
# 亮度策略，部分机型会黑屏，也没有可靠的"取消"接口。
# ============================================================================

SD_MCFR_KEY=match_content_frame_rate

sd_hz_supported() {
    local out=""
    if command -v cmd >/dev/null 2>&1; then
        out=$(cmd display get-supported-modes 0 2>/dev/null \
              | sed -n 's/.*Refresh Rate: \([0-9][0-9.]*\) Hz.*/\1/p')
    fi
    [ -n "$out" ] || out=$(dumpsys display 2>/dev/null \
        | grep -oE 'fps=[0-9]+(\.[0-9]+)?' | cut -d= -f2)
    printf '%s\n' "$out" | awk 'NF { printf "%d\n", $1 + 0.5 }' | sort -n | uniq
}

sd_hz_now() {
    local v=""
    if command -v cmd >/dev/null 2>&1; then
        v=$(cmd display get-active-mode 0 2>/dev/null \
            | sed -n 's/.*Refresh Rate: \([0-9][0-9.]*\) Hz.*/\1/p')
    fi
    [ -n "$v" ] || v=$(dumpsys display 2>/dev/null \
        | grep -oE 'fps=[0-9]+(\.[0-9]+)?' | head -n 1 | cut -d= -f2)
    case "$v" in ''|*[!0-9.]*) return 1 ;; esac
    awk -v v="$v" 'BEGIN { printf "%d", v + 0.5 }'
}

# 目标档位。off 或非法值返回非 0，调用方据此跳过全部刷新率开销。
sd_hz_want() {
    local v
    v=$(sd_state_get hz off)
    case "$v" in ''|off|*[!0-9]*) return 1 ;; esac
    printf '%s' "$v"
}

sd_hz_hard() { [ "$(sd_state_get hz_hard 0)" = "1" ]; }

sd_hz_read() {
    local k
    case "$1" in peak|max) k=peak_refresh_rate ;; *) k=min_refresh_rate ;; esac
    settings get system "$k" 2>/dev/null | tr -d '\r'
}

# 一次取回 peak + min 两个键。
#
# 真机上 `settings` 不是简单的读文件：它启动 app_process 跑 Java 命令，
# 单次冷启动 80~150ms（低端机更久）。锁定档每 tick 要对比这两个键，
# 用两次 get 就是每 15 秒启动两个 app_process，折合单核 1.5% 以上。
# `settings list system` 一次就能拿全表，筛两个键出来，进程数减半。
_hz_peak=""
_hz_min=""
sd_hz_readpair() {
    local k v out
    _hz_peak=""
    _hz_min=""
    command -v settings >/dev/null 2>&1 || return 1
    out=$(settings list system 2>/dev/null)
    if [ -n "$out" ]; then
        while IFS='=' read -r k v; do
            case "$k" in
                peak_refresh_rate) _hz_peak=$v ;;
                min_refresh_rate)  _hz_min=$v ;;
            esac
        done <<EOF
$out
EOF
    else
        # 个别 ROM 的 settings 不支持 list，退回逐个 get
        _hz_peak=$(settings get system peak_refresh_rate 2>/dev/null | tr -d '\r')
        _hz_min=$(settings get system min_refresh_rate 2>/dev/null | tr -d '\r')
    fi
    return 0
}

sd_hz_write() {
    settings put system peak_refresh_rate "$1" 2>/dev/null
    settings put system min_refresh_rate "$1" 2>/dev/null
    return 0
}

# 省电模式在投票里是第 8 级，高于用户的 peak(7)，写键一定无效。
# 只读标准键：ColorOS 的省电/超级省电最终都会落到 low_power。
sd_hz_lowpower() {
    local v
    v=$(settings get global low_power 2>/dev/null | tr -d '\r')
    [ "$v" = "1" ] && { echo 1; return 0; }
    echo 0
}

# 1=NEVER：不接受按内容帧率切换。secure 键与 cmd 双写，部分 ROM 只认其中一条。
sd_hz_mcfr_on() {
    if [ -z "$(sd_state_get hz_prev_mcfr "")" ]; then
        sd_state_set hz_prev_mcfr \
            "$(settings get secure "$SD_MCFR_KEY" 2>/dev/null | tr -d '\r')"
    fi
    settings put secure "$SD_MCFR_KEY" 1 2>/dev/null
    command -v cmd >/dev/null 2>&1 && \
        cmd display set-match-content-frame-rate-policy 1 >/dev/null 2>&1
    return 0
}

sd_hz_mcfr_off() {
    local prev p
    prev=$(sd_state_get hz_prev_mcfr "")
    case "$prev" in 1|2|3) p=$prev ;; *) p=2 ;; esac
    settings put secure "$SD_MCFR_KEY" "$p" 2>/dev/null
    command -v cmd >/dev/null 2>&1 && \
        cmd display set-match-content-frame-rate-policy "$p" >/dev/null 2>&1
    sd_state_set hz_prev_mcfr ""
    return 0
}

# 只有真的开过 hard 才需要还原，避免把用户原本的 3(always) 写成 2。
sd_hz_mcfr_relax() {
    [ -n "$(sd_state_get hz_prev_mcfr "")" ] && sd_hz_mcfr_off
    return 0
}

sd_hz_restore() {
    local p m
    p=$(sd_state_get hz_prev_peak "")
    m=$(sd_state_get hz_prev_min "")
    case "$p" in
        ''|null|*[!0-9.]*) settings delete system peak_refresh_rate 2>/dev/null ;;
        *) settings put system peak_refresh_rate "$p" 2>/dev/null ;;
    esac
    case "$m" in
        ''|null|*[!0-9.]*) settings delete system min_refresh_rate 2>/dev/null ;;
        *) settings put system min_refresh_rate "$m" 2>/dev/null ;;
    esac
    sd_hz_mcfr_relax
    sd_state_set hz off
    sd_state_set hz_hard 0
    sd_state_set hz_prev_peak ""
    sd_state_set hz_prev_min ""
    return 0
}

sd_hz_set() {
    local v="$1" force="${2:-}" sup now cur prev_p prev_m prev_hard
    if [ "$v" = "off" ]; then
        sd_hz_restore
        now=$(sd_hz_now 2>/dev/null)
        sd_info cmd "刷新率 → 系统默认${now:+（当前 ${now}Hz）}"
        echo "刷新率 -> 系统默认${now:+（当前显示 ${now}Hz）}"
        return 0
    fi
    case "$v" in ''|*[!0-9]*) echo "刷新率需为 60~165 的整数或 off"; return 1 ;; esac
    [ "$v" -ge 60 ] && [ "$v" -le 165 ] || { echo "刷新率需为 60~165 的整数或 off"; return 1; }
    command -v settings >/dev/null 2>&1 || { echo "没有 settings 命令，当前环境无法改刷新率"; return 1; }

    sup=$(sd_hz_supported)
    if [ -n "$sup" ] && ! printf '%s\n' "$sup" | grep -qx "$v"; then
        echo "本机未报告 ${v}Hz 模式（支持: $(printf '%s' "$sup" | tr '\n' ' ')Hz）"
        return 1
    fi

    # 第一次开启前记下系统原值。不能等关闭时再读 —— 那时读到的已经是
    # 自己写进去的 120，还原就成了"还原成 120"。切换档位时不要重采。
    if [ "$(sd_state_get hz off)" = "off" ]; then
        sd_state_set hz_prev_peak "$(settings get system peak_refresh_rate 2>/dev/null | tr -d '\r')"
        sd_state_set hz_prev_min  "$(settings get system min_refresh_rate 2>/dev/null | tr -d '\r')"
        sd_state_set hz_prev_mcfr ""
    fi

    # 力度必须在写 mcfr 之前定好：写不写内容帧率锁定取决于它。
    prev_hard=$(sd_state_get hz_hard 0)
    case "$force" in soft) sd_state_set hz_hard 0 ;; hard) sd_state_set hz_hard 1 ;; esac

    sd_hz_write "$v"
    if sd_hz_hard; then
        sd_hz_mcfr_on
    else
        sd_hz_mcfr_relax
    fi

    # settings put 不报错不代表写进去了：部分机型会立刻把值改回去。
    # 写不进就回滚，不留下"状态显示已开启、实际没生效"的半套配置。
    sd_hz_readpair
    cur=${_hz_peak%%.*}
    if [ "$cur" != "$v" ]; then
        prev_p=$(sd_state_get hz_prev_peak "")
        prev_m=$(sd_state_get hz_prev_min "")
        case "$prev_p" in
            ''|null|*[!0-9.]*) settings delete system peak_refresh_rate 2>/dev/null ;;
            *) settings put system peak_refresh_rate "$prev_p" 2>/dev/null ;;
        esac
        case "$prev_m" in
            ''|null|*[!0-9.]*) settings delete system min_refresh_rate 2>/dev/null ;;
            *) settings put system min_refresh_rate "$prev_m" 2>/dev/null ;;
        esac
        sd_hz_mcfr_relax
        sd_state_set hz_hard "$prev_hard"
        echo "写入失败：系统拒绝修改刷新率（厂商可能锁定了显示策略）"
        return 1
    fi

    sd_state_set hz "$v"
    now=$(sd_hz_now 2>/dev/null)
    sd_info cmd "刷新率 → ${v}Hz$(sd_hz_hard && echo '（强制）')"
    echo "刷新率 -> ${v}Hz${now:+（当前显示 ${now}Hz）}$(sd_hz_hard && echo ' 强制模式')"
}

# 守护每 tick 调用。soft 档直接返回，零开销。
#   0 = 键值正确（或无需干预）
#   1 = 检测到被改回并已补写
#   2 = 写不进去（已被压制）
#   3 = 省电模式，主动退让
_hz_bad=0
_hz_reason=""
sd_hz_guard() {
    local v peak min
    # 直接用内存里的状态，避免守护每 tick 为了判断"要不要管"fork 两个子 shell
    [ "$_sd_st_loaded" = "1" ] || sd_state_load
    [ "$_st_hz_hard" = "1" ] || return 0
    case "$_st_hz" in ''|off|*[!0-9]*) return 0 ;; esac
    v=$_st_hz
    sd_hz_readpair
    peak=${_hz_peak%%.*}
    min=${_hz_min%%.*}
    if [ "$peak" = "$v" ] && [ "$min" = "$v" ]; then
        _hz_bad=0; _hz_reason=""
        return 0
    fi
    if [ "$(sd_hz_lowpower)" = "1" ]; then
        _hz_bad=0; _hz_reason=low_power
        return 3
    fi
    # 连续三次写不回目标值，说明是硬压制，再写也是白耗 IO（也会刷日志）
    if [ "$_hz_bad" -ge 3 ]; then
        _hz_reason=blocked
        return 2
    fi
    sd_hz_write "$v"
    sd_hz_mcfr_on
    sd_hz_readpair
    peak=${_hz_peak%%.*}
    if [ "$peak" = "$v" ]; then
        _hz_bad=0; _hz_reason=""
        return 1
    fi
    _hz_bad=$((_hz_bad + 1)); _hz_reason=blocked
    return 2
}

# 给面板/简介用的一句话状态
#   off 未开启 / ok 生效中 / drift 键被系统改回 / low_power 被省电模式压制
sd_hz_state_text() {
    local v peak min
    v=$(sd_hz_want) || { echo off; return 0; }
    sd_hz_readpair
    peak=${_hz_peak%%.*}
    min=${_hz_min%%.*}
    [ "$peak" = "$v" ] && [ "$min" = "$v" ] || { echo drift; return 0; }
    [ "$(sd_hz_lowpower)" = "1" ] && { echo low_power; return 0; }
    echo ok
}

# 开机补写一次。settings 本身是持久的，只有被系统重置或 OTA 后才需要，
# 所以先比对，值一致就什么都不做，避免每次开机触发一堆监听。
sd_hz_boot() {
    local v cur
    v=$(sd_hz_want) || return 0
    sd_hz_readpair
    cur=${_hz_peak%%.*}
    if [ "$cur" = "$v" ]; then
        if sd_hz_hard; then sd_hz_mcfr_on; fi
        return 0
    fi
    sd_hz_write "$v"
    if sd_hz_hard; then sd_hz_mcfr_on; fi
    sd_info boot "刷新率被系统重置，已补写 ${v}Hz"
}

# ============================================================================
# 功耗读数
#
# 只做"读一次、算一次"，不写日志、不起进程。采样节奏完全由 WebUI 决定：
# 面板关掉就没有任何读取，不会为了一根曲线让模块常年跑后台。
# ============================================================================

sd_power_json() {
    local c mv w st cap t ma src=ps cells=1 neg="" scale
    local raw v0 v1 oifs

    read -r st 2>/dev/null <"$SD_PS/battery/status"
    read -r cap 2>/dev/null <"$SD_PS/battery/capacity"
    read -r t 2>/dev/null <"$SD_PS/battery/temp"

    # ① 欧加真原生 bcc_parms —— 唯一能看到每颗电芯电压的节点。
    #    双电芯机型里 power_supply/voltage_now 有的只报单芯（4.4V 而非 8.8V），
    #    功率会正好差一半，这类机器的快充读数一直是错的。
    #
    #    格式：逗号分隔 19 个字段
    #      [6] 电压0 (mV)   [8] 电流 (mA)   [11] 电压1 (mV)
    #    字段数不是 19 就说明驱动版本不同、索引会错位，宁可退回通用节点
    #    也不猜位置 —— 猜错会把 8.8V 读成别的数，比读不到更糟。
    raw=""
    read -r raw 2>/dev/null <"$SD_OPLUS_CHG/bcc_parms"
    if [ -n "$raw" ]; then
        oifs=$IFS
        IFS=,
        set -f
        set -- $raw
        set +f
        IFS=$oifs
        if [ "$#" -eq 19 ]; then
            # $12 必须写成 ${12}：$12 会被解析成 $1 后面跟字符 2
            v0=$7; c=$9; v1=${12}
            case "$v0" in ''|*[!0-9]*) v0=0 ;; esac
            case "$v1" in ''|*[!0-9]*) v1=0 ;; esac
            case "$c"  in ''|*[!0-9-]*) c="" ;; esac
            if [ "$v0" -gt 0 ] && [ -n "$c" ]; then
                # 1V 以上才当第二颗电芯：单电芯机型这一位是 0 或空
                if [ "$v1" -gt 1000 ]; then
                    mv=$((v0 + v1)); cells=2
                else
                    mv=$v0
                fi
                src=bcc
            else
                c=""
            fi
        else
            c=""
        fi
    fi

    # ② 通用节点。电流主流 µA、少数 mA；电压主流 µV、少数 mV。
    #    10000 / 100000 是分界：10mA 以下放电没有意义，100V 以上不存在。
    if [ "$src" = ps ]; then
        local cv vv
        cv=""; vv=""
        read -r cv 2>/dev/null <"$SD_PS/battery/current_now"
        read -r vv 2>/dev/null <"$SD_PS/battery/voltage_now"
        case "$cv" in ''|*[!0-9-]*) cv="" ;; esac
        case "$vv" in ''|*[!0-9]*) vv="" ;; esac
        if [ -n "$cv" ]; then
            case "$cv" in -*) neg=1; cv=${cv#-} ;; esac
            if [ "$cv" -ge 10000 ]; then c=$((cv / 1000)); else c=$cv; fi
            [ -n "$neg" ] && c=$((-c))
        fi
        if [ -n "$vv" ]; then
            if [ "$vv" -ge 100000 ]; then mv=$((vv / 1000)); else mv=$vv; fi
        fi
    fi

    # ③ 符号校正。各平台对"正=充电"的约定相反，以 status 为准统一成
    #    充电为正、放电为负，否则面板上充电时显示负电流很费解。
    if [ -n "$c" ]; then
        case "$st" in
            Not\ charging|*Discharging*) [ "$c" -gt 0 ] && c=$((-c)) ;;
            *Charging*|Full)             [ "$c" -lt 0 ] && c=$((-c)) ;;
        esac
        # 个别机型电流值本身带固定偏差，用倍率修正（百分比，默认 100）
        scale=$(sd_state_int power_scale 100 50 200)
        [ "$scale" -ne 100 ] && c=$((c * scale / 100))
        ma=$c
    fi

    w=""
    if [ -n "$ma" ] && [ -n "$mv" ]; then
        w=$(awk -v a="$ma" -v b="$mv" 'BEGIN { printf "%.2f", (a < 0 ? -a : a) * b / 1000000 }')
    fi

    case "$t" in ''|*[!0-9-]*) t="" ;; esac
    if [ -n "$t" ]; then
        case "$t" in -*) t="" ;; *) [ "$t" -gt 200 ] && t=$(((t + 5) / 10)) ;; esac
    fi

    case "$cap" in ''|*[!0-9]*) cap="" ;; esac
    # 防止状态字符串把 JSON 撑破，只保留常规字符
    case "$st" in *\"*|*\\*) st="" ;; esac

    printf '{"ma":%s,"mv":%s,"w":%s,"status":"%s","cap":%s,"temp":%s,"cells":%s,"src":"%s"}\n' \
        "${ma:-null}" "${mv:-null}" "${w:-null}" "${st:-Unknown}" "${cap:-null}" "${t:-null}" \
        "$cells" "$src"
}

# ---------- 模块描述同步 ----------
# 管理器（Magisk / KernelSU）的模块列表读 module.prop 的 description，
# 静态文案看不到"现在是什么状态"。这里在运行期把它改写成实时摘要：
#     QC · 温控档位 8/10 · 高刷 120Hz · 配置 9 项
#
# 三条约束：
#   * 只 replace 掉 description 那一行，其余行逐字节保留；
#   * 先与上次写入的字符串比对，相同就不碰文件 —— 闪存写入比一次 fork 贵得多；
#   * 写失败（只读挂载、模块已删）静默跳过，一句文案不能影响守护运行。

SD_DESC_LAST="$SD_RUN/desc.last"

sd_desc_text() {
    local mode gear hz n t
    # 读内存状态即可：这个函数每 3 分钟被守护调一次，四个 $(...) 换四个 fork
    # 不划算。状态刚被 sd_state_load 刷过，直接读 _st_* 与读文件等价。
    [ "$_sd_st_loaded" = 1 ] || sd_state_load
    mode=${_st_temp_mode:-off}
    [ "$mode" = dyn ] && mode=static
    _sd_clamp "${_st_aggr:-10}" 0 10 10
    gear=$_sd_rv

    case "$mode" in
        static|charge) t="温控档位 $gear/10" ;;
        *)             t="温度伪装关闭" ;;
    esac
    [ "$mode" = charge ] && t="$t（仅充电）"

    hz=${_st_hz:-off}
    case "$hz" in
        off|'') t="$t · 高刷关闭" ;;
        *)      if [ "${_st_hz_hard:-0}" = "1" ]; then
                    t="$t · 高刷 ${hz}Hz 锁定"
                else
                    t="$t · 高刷 ${hz}Hz"
                fi ;;
    esac

    n=$(sort -u "$SD_MOUNTS" 2>/dev/null | wc -l | tr -d ' ')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -gt 0 ]; then
        t="$t · 配置 $n 项"
    else
        t="$t · 未挂载"
    fi

    printf 'QC · %s' "$t"
}

sd_sync_desc() {
    [ -n "${MODDIR:-}" ] && [ -f "$MODDIR/module.prop" ] || return 0
    local d last tmp
    d=$(sd_desc_text)

    read -r last 2>/dev/null <"$SD_DESC_LAST"
    [ "$last" = "$d" ] && return 0

    # 临时文件放 /data/adb/quickcharge（与模块目录同分区），mv 是原子的：
    # 管理器即使正在读 module.prop，也只会读到旧版或新版，不会读到半截。
    # $$ 后缀：守护与 action.sh 可能同时触发，共用一个临时名会互相截断
    tmp="$SD_DATA/.module.prop.tmp.$$"
    awk -v d="$d" '
        /^description=/ { print "description=" d; seen = 1; next }
        { print }
        END { if (!seen) print "description=" d }
    ' "$MODDIR/module.prop" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    [ -s "$tmp" ] || { rm -f "$tmp"; return 0; }
    mv -f "$tmp" "$MODDIR/module.prop" 2>/dev/null || { rm -f "$tmp"; return 0; }

    printf '%s' "$d" >"$SD_DESC_LAST" 2>/dev/null
}
