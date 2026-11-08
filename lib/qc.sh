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

sd_state_load() {
    _sd_st_loaded=1
    _st_temp_mode=""; _st_shell_temp=""; _st_core_temp=""; _st_noncore_temp=""
    _st_horae=""; _st_sentinel_limit=""; _st_battery_limit=""; _st_fast_cap=""
    _st_curve_offset=""; _st_wall=""; _st_aggr=""; _st_curr_max=""
    _st_log_level=""; _st_tick=""; _st_defrev=""
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

# 计算本次应上报的壳温。返回 0 表示关闭模拟、交还真实读数。
#
# 三条约束，每条都是实测踩出来的：
#   1. base 必须落在 [30,60]。熔断后 shell_temp 会被置 0，charge 模式初始值也是 0，
#      不纠正就会把 0℃ 喂给系统 —— 多数 thermal HAL 视为传感器故障。
#   2. 上报值绝不超过真实温度。超了不是降温伪装，而是伪造高温，系统会提前降频。
#   3. 越接近温度墙收益越小，最后 4℃ 等步长爬升到墙，与"关闭模拟"无缝衔接。
#      等步长是必须的：从 30 直跳 42 会让系统看到壳温突变 12℃，触发一次降频。
sd_shell_target() {
    local base limit cur gap z v wall barrier room climb
    _sd_last_cur=""
    _sd_last_out=0

    base=$(sd_state_int shell_temp 30 25 60)
    gap=$(sd_max_gap)
    wall=$(sd_wall)

    # 拿不到哨兵就放弃伪装。绝不能"读不到就按设定值报" ——
    # 那等于在完全看不见真实温度的情况下继续骗系统。
    z=$(sd_pick_sentinel) || { printf '0'; return 0; }

    # 先读真实温度再分支：关闭熔断时同样要读，否则低温环境下会把 30℃ 报上去，
    # 伪造出偏高的壳温，系统反而提前降频，与目的相反。
    cur=$(sd_sentinel_temp "$z" 2>/dev/null)
    case "$cur" in ''|*[!0-9]*) printf '0'; return 0 ;; esac

    limit=$(sd_limit_for_zone "$z")
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
sd_guard_one() {
    local z="$1" limit cur
    limit=$(sd_limit_for_zone "$z")
    case "$limit" in ''|0|off) return 1 ;; esac
    cur=$(sd_sentinel_temp "$z" 2>/dev/null) || return 1
    case "$cur" in ''|*[!0-9]*) return 1 ;; esac
    [ "$cur" -ge "$limit" ] || return 1

    sd_warn guard "⚠ 熔断：哨兵 $(basename "$z") 实测 ${cur}℃ ≥ 上限 ${limit}℃"
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
    local e z t fb="" checked=0
    # 没有伪装在生效时直接放行，否则熔断后每 tick 都重清一遍并写日志
    if [ "$(sd_state_get temp_mode off)" = "off" ] \
        && [ "$(sd_state_get core_temp off)" = "off" ] \
        && [ "$(sd_state_get noncore_temp off)" = "off" ]; then
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
                sd_guard_one "$z" && return 1
                ;;
            *) [ -n "$fb" ] || fb=$z ;;
        esac
    done
    # 没有明确的电池/主板节点时，退回第一个非 core/shell 节点
    if [ "$checked" -eq 0 ] && [ -n "$fb" ]; then
        sd_guard_one "$fb" && return 1
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
sd_curr_target() {
    local ma wall cur pct
    ma=$(sd_state_int curr_max 0 0 8000)
    [ "$ma" -gt 0 ] || { printf '0'; return 0; }

    cur=$(sd_sentinel_temp "$(sd_pick_sentinel)" 2>/dev/null)
    case "$cur" in ''|*[!0-9]*) printf '%s' "$ma"; return 0 ;; esac

    wall=$(sd_wall)
    [ "$wall" -gt 0 ] || wall=42

    if [ "$cur" -ge "$wall" ]; then pct=25
    elif [ "$cur" -ge $((wall - 3)) ]; then pct=50
    elif [ "$cur" -ge $((wall - 8)) ]; then pct=75
    else pct=100
    fi

    sd_dbg charge "电流目标 ${cur}℃/墙${wall}℃ → ${pct}% of ${ma}mA"
    printf '%s' $((ma * pct / 100))
}

sd_curr_apply() {
    local ma="$1" ua n total=0 ok=0 cur=""
    [ "$ma" -gt 0 ] || return 1
    ua=$((ma * 1000))
    for n in $(sd_curr_nodes); do
        total=$((total + 1))
        read -r cur 2>/dev/null <"$n"
        if printf '%s\n' "$ua" 2>/dev/null >"$n"; then
            ok=$((ok + 1))
            sd_dbg charge "  写入 $(basename "$n"): ${cur:-?} → ${ua}µA"
        else
            sd_warn charge "  节点不可写: $n"
        fi
    done
    if [ "$total" -eq 0 ]; then
        sd_warn charge "未找到任何电流节点，curr_max 不生效"
        return 1
    fi
    sd_info charge "电流上限 ${ma}mA 已写入 $ok/$total 个节点"
    [ "$ok" -gt 0 ]
}

# 系统/IC 会自己往上调，每次 tick 检查。只在超出目标 10% 时重写 ——
# 否则每秒都在和 IC 打架，日志也会刷屏。
sd_curr_keep() {
    local want ua margin n cur="" n_ok=0
    want=$(sd_curr_target)
    [ "$want" -gt 0 ] || return 0
    ua=$((want * 1000))
    margin=$((ua * 11 / 10))
    for n in $(sd_curr_nodes); do
        read -r cur 2>/dev/null <"$n"
        case "$cur" in ''|*[!0-9]*) continue ;; esac
        if [ "$cur" -gt "$margin" ]; then
            printf '%s\n' "$ua" 2>/dev/null >"$n" && n_ok=$((n_ok + 1))
        fi
    done
    [ "$n_ok" -gt 0 ] && sd_info charge "电流墙被抬高，已压回 ${want}mA（$n_ok 节点）"
    return 0
}

sd_charge_renegotiate() {
    local node=/sys/devices/virtual/oplus_chg/battery/mmi_charging_enable i=0
    [ -w "$node" ] || { sd_warn charge "充电使能节点不可写，跳过重握手"; return 1; }
    sd_info charge "开始重新握手（3 轮 × 5s）"
    while [ "$i" -lt 3 ]; do
        printf '0\n' 2>/dev/null >"$node"
        sleep 5
        printf '1\n' 2>/dev/null >"$node"
        sleep 5
        i=$((i + 1))
    done
    sd_info charge "重握手结束，当前 $(sd_batt_power 2>/dev/null || echo '?') W"
}

sd_charge_tick() {
    local cap st target fast_cap
    cap=$(sd_batt_capacity)
    st=$(sd_batt_status)
    target=$(sd_shell_target)
    fast_cap=$(sd_state_int fast_cap 55 20 90)

    case "$st" in
        Charging|Full) ;;
        *) sd_shell_emul 0; return 0 ;;
    esac

    # 电流墙独立于电量段：只要在充电就维持
    sd_curr_keep

    # fast_cap 以上不再伪装，让系统正常进恒压段
    if [ "$cap" -lt "$fast_cap" ]; then
        sd_shell_emul "$target"
    else
        sd_shell_emul 0
    fi
}
