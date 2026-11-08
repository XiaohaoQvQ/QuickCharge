#!/system/bin/sh
# Quick Charge (QC) 控制入口。
#
#   无参数     交互菜单（有终端时）；非交互环境直接打印状态
#   带子命令   供元模块 / 脚本调用
#
# 子命令：
#   status                       当前状态
#   json                         机器可读状态（JSON，供 WebUI 使用）
#   temp <off|static|charge> [℃] 温度模式（默认 static 30℃）
#   shell <℃|off>                等同 temp static
#   core <off|20-100>            CPU/GPU/DDR 固定伪装
#   noncore <off|20-100>         其它温区固定伪装（电池与壳温始终受保护）
#   aggr <0-10>                  暴力程度：可拉开温差 = 2 + aggr
#   base <25-60>                 基准温度（只改数值，不切换模式，供 WebUI 用）
#   restart                      重启守护进程（改完参数后强制立即生效）
#   wall <35-80|off>             温度墙：真实温度到此即停止伪装
#   curr <300-8000|off>          充电限流（mA），按温度联动降流
#   fast <20-90>                 快充生效的电量阈值（%）
#   sentinel <60-110|off>        SoC/主板哨兵熔断阈值
#   battery <30-70|off>          电池哨兵熔断阈值
#   horae <0|1>                  OPPO 热管理服务开关
#   level <0-4>                  日志级别 0关 1E 2W 3I 4D
#   logs [e|w|i|d|boot|daemon|N] 查看日志
#   mount | umount               手动挂载 / 卸载配置覆盖层
#   rebuild                      重新生成并挂载（OTA 后一般不用，开机自会处理）
#   reboot-safe                  退出安全模式并立即重挂
#   reset                        恢复初始状态（清空全部参数）

MODDIR="${SD_MODDIR:-}"
if [ -z "$MODDIR" ]; then
    MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd)
    [ -f "${MODDIR:-/nonexistent}/lib/qc.sh" ] || MODDIR=$(pwd)
fi
[ -f "$MODDIR/lib/qc.sh" ] || {
    echo "QC: 找不到 lib/qc.sh" >&2
    exit 1
}
. "$MODDIR/lib/qc.sh"

sd_state_load
sd_zone_scan

sd_ensure_daemon() {
    # SD_NO_DAEMON=1 时不拉起：供元模块自己管理进程，也让离线测试不留后台
    [ -n "${SD_NO_DAEMON:-}" ] && return 0
    sd_daemon_pid >/dev/null && return 0
    nohup sh "$MODDIR/service.sh" --daemon >/dev/null 2>&1 &
    sleep 1
}

# ---------- 状态 ----------

sd_do_status() {
    local mode c nc wall aggr curmax curtar sz sname real slim bc mt
    mode=$(sd_state_get temp_mode off)
    [ "$mode" = "dyn" ] && mode=static
    c=$(sd_state_get core_temp off)
    nc=$(sd_state_get noncore_temp off)
    wall=$(sd_state_get wall off)
    aggr=$(sd_state_int aggr 10 0 10)
    curmax=$(sd_state_int curr_max 0 0 8000)
    sz=$(sd_pick_sentinel)
    sname=${sz##*/}
    [ -n "$sname" ] || sname=none
    real=$(sd_sentinel_temp "$sz" 2>/dev/null)
    slim=$(sd_limit_for_zone "$sz" 2>/dev/null)
    curtar=$(sd_curr_target 2>/dev/null)
    mt=$(sort -u "$SD_MOUNTS" 2>/dev/null | wc -l | tr -d ' ')

    printf '模式      %s' "$mode"
    case "$mode" in
        static) printf ' · 基准 %s℃' "$(sd_state_int shell_temp 30 25 60)" ;;
        charge) printf ' · %s%% 以下生效' "$(sd_state_int fast_cap 55 20 90)" ;;
        off)    printf ' · 未启用（仅配置改写生效）' ;;
    esac
    printf '\n'
    printf '强度      %s/10（可拉开 %s℃）   温度墙 %s\n' "$aggr" $((2 + aggr)) \
        "$([ "$wall" = off ] && echo '关（熔断前 2℃ 停止）' || echo "${wall}℃")"
    printf '固定伪装  核心 %s   非核心 %s\n' "$c" "$nc"
    printf '哨兵      %s %s℃ / 上限 %s℃\n' "$sname" "${real:--}" "${slim:-off}"
    printf '电流上限  %s\n' "$([ "$curmax" -gt 0 ] && echo "${curmax}mA（当前允许 ${curtar}mA）" || echo '关闭')"
    printf '配置挂载  %s 个文件   守护 %s\n' "$mt" \
        "$(sd_daemon_pid >/dev/null && echo 运行中 || echo 未运行)"

    bc=0
    read -r bc 2>/dev/null <"$SD_DATA/boot.count"
    case "$bc" in ''|*[!0-9]*) bc=0 ;; esac
    [ "$bc" -gt 3 ] && printf '⚠ 安全模式：连续 %s 次开机未完成，本次未挂载配置\n' "$bc"
    printf '日志级别  %s\n' "$(sd_state_int log_level 3 0 4)"
}

# ---------- 机器可读状态 ----------

# 供 WebUI / 元模块消费。所有数值先过一遍夹紧，不会吐越界值；
# 无法读到的字段给 null，前端据此显示"—"而不是 0。
sd_do_json() {
    local mode c nc wall aggr curmax curtar sz sname real slim bc mt dm bl sl rj blj slj tgt
    mode=$(sd_state_get temp_mode off)
    [ "$mode" = "dyn" ] && mode=static
    c=$(sd_state_get core_temp off)
    nc=$(sd_state_get noncore_temp off)
    wall=$(sd_state_get wall off)
    aggr=$(sd_state_int aggr 10 0 10)
    curmax=$(sd_state_int curr_max 0 0 8000)
    sz=$(sd_pick_sentinel)
    sname=${sz##*/}
    [ -n "$sname" ] || sname=none
    real=$(sd_sentinel_temp "$sz" 2>/dev/null)
    slim=$(sd_limit_for_zone "$sz" 2>/dev/null)
    curtar=$(sd_curr_target 2>/dev/null)
    mt=$(sort -u "$SD_MOUNTS" 2>/dev/null | wc -l | tr -d ' ')
    dm=false; sd_daemon_pid >/dev/null && dm=true
    bc=0; read -r bc 2>/dev/null <"$SD_DATA/boot.count"
    case "$bc" in ''|*[!0-9]*) bc=0 ;; esac

    # 当前决策值：面板显示"上报"必须用真实计算出的目标，不能拿 shell_temp 代替
    # （渐进让步会让 41℃ 真实温度上报 39℃，与基准 30 相差很远）
    tgt=0
    if [ "$mode" = static ]; then
        sd_shell_target >/dev/null
        tgt=$_sd_last_out
    fi
    bl=$(sd_state_get battery_limit 48);  case "$bl" in off) blj='"off"' ;; *) blj=$bl ;; esac
    sl=$(sd_state_get sentinel_limit 85); case "$sl" in off) slj='"off"' ;; *) slj=$sl ;; esac
    case "$real" in ''|*[!0-9]*) rj=null ;; *) rj=$real ;; esac

    printf '{"version":"%s","mode":"%s","shell_temp":%s,"target":%s,"aggr":%s,"gap":%s,' \
        "$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)" \
        "$mode" "$(sd_state_int shell_temp 30 25 60)" "$tgt" "$aggr" "$((2 + aggr))"
    printf '"wall":"%s","core":"%s","noncore":"%s",' "$wall" "$c" "$nc"
    printf '"sentinel":"%s","real":%s,"limit":"%s",' "$sname" "$rj" "${slim:-off}"
    printf '"curr_max":%s,"curr_target":%s,"fast_cap":%s,' \
        "$curmax" "${curtar:-0}" "$(sd_state_int fast_cap 55 20 90)"
    printf '"battery_limit":%s,"sentinel_limit":%s,' "$blj" "$slj"
    printf '"log_level":%s,"tick":%s,"mounted":%s,"daemon":%s,"boot_count":%s,"safety":%s}\n' \
        "$(sd_state_int log_level 3 0 4)" "$(sd_state_int tick 15 5 300)" \
        "$mt" "$dm" "$bc" "$([ "$bc" -gt 3 ] && echo true || echo false)"
}

# ---------- 设置 ----------

sd_set_temp() {
    local mode="$1" t="${2:-}"
    [ -n "$t" ] || t=$(sd_state_int shell_temp 30 25 60)
    case "$t" in ''|*[!0-9]*) t=30 ;; esac
    if [ "$t" -lt 25 ] || [ "$t" -gt 60 ]; then
        echo "壳温需在 25~60℃ 之间，已改用 30℃"
        t=30
    fi
    case "$mode" in
        off)
            sd_shell_emul 0
            sd_state_set temp_mode off
            sd_state_set shell_temp 0
            sd_info cmd "温度模式 → off"
            echo "温度模式 -> off" ;;
        static)
            sd_state_set shell_temp "$t"
            sd_state_set temp_mode static
            _sd_emul_last=""
            sd_shell_emul "$t"
            sd_info cmd "温度模式 → static ${t}℃"
            echo "温度模式 -> static ${t}℃" ;;
        charge)
            sd_state_set temp_mode charge
            sd_info cmd "温度模式 → charge"
            echo "温度模式 -> charge（低于 $(sd_state_int fast_cap 55 20 90)% 生效）" ;;
        *) echo "未知模式: $mode（可选 off|static|charge）"; return 1 ;;
    esac
    sd_ensure_daemon
}

# 参数先校验再落地。apply 失败还照写 state 会出现"状态显示已设、实际没挂"，
# 重启后还会再试一次。
sd_set_scope() {
    local scope="$1" v="$2" label
    [ "$scope" = core ] && label=核心 || label=非核心
    if [ "$v" = "off" ]; then
        sd_spoof_clear_scope "$scope"
        sd_state_set "${scope}_temp" off
        sd_info cmd "$label 伪装 → off"
        echo "$label 伪装 -> 关闭"
        return 0
    fi
    sd_valid_temp "$v" || { echo "温度需为 20~100 的整数，收到: $v"; return 1; }
    if ! sd_spoof_apply "$scope" "$v"; then
        echo "没有节点被伪装：本机可能没有匹配节点，或内核不允许 bind mount"
        echo "  详情: sh $MODDIR/action.sh logs w"
        return 1
    fi
    sd_state_set "${scope}_temp" "$v"
    echo "$label 伪装 -> ${v}℃"
}

sd_set_aggr() {
    case "$1" in ''|*[!0-9]*) echo "暴力程度需为 0~10 的整数"; return 1 ;; esac
    [ "$1" -le 10 ] || { echo "暴力程度需为 0~10 的整数"; return 1; }
    sd_state_set aggr "$1"
    sd_info cmd "暴力程度 → $1/10（可拉开 $((2 + $1))℃）"
    sd_ensure_daemon
    echo "暴力程度 -> $1/10，允许真实与上报相差 $((2 + $1))℃"
}

sd_set_wall() {
    local v="$1" bl
    if [ "$v" = "off" ] || [ "$v" = "0" ]; then
        sd_state_set wall off
        sd_info cmd "温度墙 → off"
        echo "温度墙 -> 关闭（伪装持续到熔断阈值前 2℃）"
        return 0
    fi
    case "$v" in ''|*[!0-9]*) echo "温度墙需为 35~80 的整数或 off"; return 1 ;; esac
    [ "$v" -ge 35 ] && [ "$v" -le 80 ] || { echo "温度墙需为 35~80 的整数或 off"; return 1; }
    bl=$(sd_state_int battery_limit 48 30 70)
    [ "$v" -ge "$bl" ] && echo "注意：墙 ${v}℃ ≥ 电池熔断 ${bl}℃，墙不会生效（熔断先触发）"
    sd_state_set wall "$v"
    sd_info cmd "温度墙 → ${v}℃"
    echo "温度墙 -> ${v}℃（真实温度达到即停止伪装）"
}

sd_set_curr() {
    local v="$1" applied
    if [ "$v" = "off" ] || [ "$v" = "0" ]; then
        sd_state_set curr_max 0
        sd_info cmd "电流墙 → off"
        echo "电流墙 -> 关闭"
        return 0
    fi
    case "$v" in ''|*[!0-9]*) echo "电流需为 300~8000 的整数（mA）或 off"; return 1 ;; esac
    [ "$v" -ge 300 ] && [ "$v" -le 8000 ] || { echo "电流需为 300~8000 的整数（mA）或 off"; return 1; }
    sd_state_set curr_max "$v"
    applied=$(sd_curr_target)
    sd_info cmd "电流墙 → ${v}mA（当前允许 ${applied}mA）"
    if [ "$(sd_batt_status)" = "Charging" ]; then
        sd_curr_apply "$applied"
    else
        echo "当前未在充电，接上充电器后生效"
    fi
    echo "电流墙 -> ${v}mA，当前温度下允许 ${applied}mA"
}

sd_set_fast() {
    case "$1" in ''|*[!0-9]*) echo "电量阈值需为 20~90 的整数"; return 1 ;; esac
    [ "$1" -ge 20 ] && [ "$1" -le 90 ] || { echo "电量阈值需为 20~90 的整数"; return 1; }
    sd_state_set fast_cap "$1"
    sd_info cmd "快充阈值 → $1%"
    echo "快充阈值 -> $1%"
}

sd_set_limit() {
    local key="$1" v="$2" lo="$3" hi="$4" label="$5" dflt="$6"
    if [ "$v" = "off" ]; then
        sd_state_set "$key" off
        echo "$label -> 关闭（不建议）"
        return 0
    fi
    case "$v" in ''|*[!0-9]*) echo "$label 需为 ${lo}~${hi} 或 off"; return 1 ;; esac
    [ "$v" -ge "$lo" ] && [ "$v" -le "$hi" ] || { echo "$label 需为 ${lo}~${hi} 或 off"; return 1; }
    sd_state_set "$key" "$v"
    sd_info cmd "$label → ${v}℃"
    echo "$label -> ${v}℃（默认 ${dflt}）"
}

# ---------- 日志 ----------

sd_do_logs() {
    local arg="$1" n="${2:-60}"
    case "$arg" in
        e|E) grep ' E \[' "$SD_LOG" 2>/dev/null | tail -n "$n" ;;
        w|W) grep -E ' [EW] \[' "$SD_LOG" 2>/dev/null | tail -n "$n" ;;
        boot) awk '/======== .*\| boot \|/{f=1} f' "$SD_LOG" 2>/dev/null | tail -n 120 ;;
        daemon) awk '/======== .*\| daemon \|/{f=1} f' "$SD_LOG" 2>/dev/null | tail -n 120 ;;
        d|D) tail -n "$n" "$SD_LOG" 2>/dev/null ;;
        ''|i|I) grep -E ' [EWI] \[' "$SD_LOG" 2>/dev/null | tail -n "$n" ;;
        *[!0-9]*) tail -n 60 "$SD_LOG" 2>/dev/null ;;
        *) tail -n "$arg" "$SD_LOG" 2>/dev/null ;;
    esac
}

# ---------- 交互菜单 ----------

sd_menu_sub() {
    local t
    case "$1" in
        temp)
            printf '\n温度模式: 1) 关闭  2) 静态 30℃  3) 静态 35℃  4) 静态 40℃  5) 充电辅助  0) 返回\n选择: '
            read -r t || return 0
            case "$t" in
                1) sd_set_temp off ;; 2) sd_set_temp static 30 ;; 3) sd_set_temp static 35 ;;
                4) sd_set_temp static 40 ;; 5) sd_set_temp charge ;;
            esac ;;
        core)
            printf '\n核心伪装: 1) 关闭  2) 40℃  3) 45℃  4) 50℃  5) 55℃  6) 60℃  0) 返回\n选择: '
            read -r t || return 0
            case "$t" in
                1) sd_set_scope core off ;; 2) sd_set_scope core 40 ;; 3) sd_set_scope core 45 ;;
                4) sd_set_scope core 50 ;; 5) sd_set_scope core 55 ;; 6) sd_set_scope core 60 ;;
            esac ;;
        power)
            printf '\n1) 暴力 10  2) 暴力 8  3) 暴力 5  4) 暴力 2\n'
            printf '5) 温度墙 42℃  6) 温度墙 40℃  7) 温度墙 45℃  8) 关闭温度墙  0) 返回\n选择: '
            read -r t || return 0
            case "$t" in
                1) sd_set_aggr 10 ;; 2) sd_set_aggr 8 ;; 3) sd_set_aggr 5 ;; 4) sd_set_aggr 2 ;;
                5) sd_set_wall 42 ;; 6) sd_set_wall 40 ;; 7) sd_set_wall 45 ;; 8) sd_set_wall off ;;
            esac ;;
        charge)
            printf '\n1) 关闭限流  2) 1000mA  3) 2000mA  4) 3000mA  5) 4000mA\n'
            printf '6) 快充阈值 55%%  7) 快充阈值 70%%  0) 返回\n选择: '
            read -r t || return 0
            case "$t" in
                1) sd_set_curr off ;; 2) sd_set_curr 1000 ;; 3) sd_set_curr 2000 ;;
                4) sd_set_curr 3000 ;; 5) sd_set_curr 4000 ;;
                6) sd_set_fast 55 ;; 7) sd_set_fast 70 ;;
            esac ;;
        misc)
            printf '\n1) 日志级别 常规  2) 日志级别 调试  3) 看错误日志  4) 看开机日志  0) 返回\n选择: '
            read -r t || return 0
            case "$t" in
                1) sd_state_set log_level 3; echo "日志级别 -> 3" ;;
                2) sd_state_set log_level 4; echo "日志级别 -> 4" ;;
                3) printf '\033[H\033[J'; sd_do_logs e 40 ;;
                4) printf '\033[H\033[J'; sd_do_logs boot 80 ;;
            esac ;;
    esac
}

sd_menu() {
    local c
    while :; do
        printf '\033[H\033[J'
        printf 'Quick Charge (QC)\n'
        printf '────────────────────────\n'
        sd_do_status
        printf '\n1) 温度模式  2) 核心伪装  3) 暴力/温度墙  4) 充电限流  5) 其它  0) 退出\n选择: '
        read -r c || { echo; return 0; }
        case "$c" in
            1) sd_menu_sub temp ;;
            2) sd_menu_sub core ;;
            3) sd_menu_sub power ;;
            4) sd_menu_sub charge ;;
            5) sd_menu_sub misc ;;
            0) printf '\033[H\033[J'; return 0 ;;
        esac
        [ -n "$c" ] && [ "$c" != 0 ] && { echo; printf '按回车继续…'; read -r _c; }
    done
}

# ---------- 入口 ----------

[ -n "${1:-}" ] && sd_session cmd "命令行: $*"

# 保存命令名：各分支会 shift，末尾判断该不该叫醒守护时 $1 已经变成参数值了
_CMD="${1:-}"

case "$1" in
    status)  sd_do_status ;;
    json)    sd_do_json ;;
    env)     sd_dump_env; grep '\[env\]' "$SD_LOG" 2>/dev/null | tail -n 4 ;;
    temp)    shift; sd_set_temp "$@" ;;
    shell)   shift; sd_set_temp static "${1:-}" ;;
    core)    shift; sd_set_scope core "${1:-off}" ;;
    noncore) shift; sd_set_scope noncore "${1:-off}" ;;
    aggr)    shift; sd_set_aggr "${1:-10}" ;;
    base)    shift
             v="${1:-}"
             case "$v" in ''|*[!0-9]*) echo "基准温度需为 25~60 的整数"; exit 1 ;; esac
             { [ "$v" -ge 25 ] && [ "$v" -le 60 ]; } || { echo "基准温度需为 25~60 的整数"; exit 1; }
             sd_state_set shell_temp "$v"
             echo "基准温度 -> ${v}℃" ;;
    restart) sd_daemon_stop; sd_ensure_daemon; echo "守护已重启" ;;
    wall)    shift; sd_set_wall "${1:-off}" ;;
    curr)    shift; sd_set_curr "${1:-off}" ;;
    fast)    shift; sd_set_fast "${1:-55}" ;;
    sentinel) shift; sd_set_limit sentinel_limit "${1:-85}" 60 110 "SoC 哨兵" 85 ;;
    battery)  shift; sd_set_limit battery_limit  "${1:-48}" 30 70  "电池哨兵" 48 ;;
    horae)   shift; sd_horae "$1"; sd_state_set horae "$1" ;;
    level)   shift
             case "${1:-3}" in
                 0|1|2|3|4) sd_state_set log_level "$1"; echo "日志级别 -> $1" ;;
                 *) echo "级别需为 0~4"; exit 1 ;;
             esac ;;
    logs)    shift; sd_do_logs "${1:-i}" "${2:-60}" ;;
    charge-force) sd_charge_renegotiate ;;
    mount)   sd_mount_overrides ;;
    umount)  sd_umount_overrides ;;
    reboot-safe)
        printf '0\n' >"$SD_DATA/boot.count"
        sd_umount_overrides      # 必须先解挂，否则下面读到的是上次的假文件
        sd_build_overrides
        sd_mount_overrides
        sd_info cmd "已退出安全模式并重新挂载"
        echo "已退出安全模式并重新挂载" ;;
    rebuild)
        # 关键顺序：先解挂再重建。挂载状态下重建会读到自己上次生成的假文件，
        # 把改动叠加一次（充电曲线 +120 会变成 +240）。
        sd_umount_overrides
        rm -f "$SD_BUILT"
        sd_build_overrides
        sd_mount_overrides ;;
    reset)
        sd_daemon_stop
        sd_spoof_clear
        sd_shell_emul 0
        sd_umount_overrides
        sd_horae 1
        printf '0\n' 2>/dev/null >"$SD_DATA/boot.count"
        rm -f "$SD_STATE"
        sd_info cmd "已恢复初始状态"
        echo "已恢复初始状态，建议重启" ;;
    "")
        if [ -t 0 ]; then
            sd_menu
        else
            sd_do_status
            echo
            echo "非交互环境：用 sh action.sh <命令> 配置，sh action.sh 查看帮助"
        fi ;;
    *)
        echo "未知命令: $1"
        echo
        awk 'NR>=3 { if (/^#/) { print; next } if ($0 == "") next; exit }' "$0"
        exit 1 ;;
esac

# 参数类命令写完后立刻叫醒守护，不必等下一个 tick（最长 15 秒）。
# 守护没在跑时 sd_daemon_kick 静默返回。
# 退出码必须沿用命令本身的结果：WebUI 靠它判断成败，kick 把它覆盖成 0
# 会让 "aggr 11" 这种被拒绝的输入看起来成功。
_rc=$?
case "$_CMD" in
    temp|shell|core|noncore|aggr|base|wall|curr|fast|sentinel|battery|horae|level)
        sd_daemon_kick ;;
esac
exit "$_rc"
