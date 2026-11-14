#!/system/bin/sh
# ---------------------------------------------------------------
# Quick Charge (QC) — 源码完全公开，可自由查看、修改、分发。
# 禁止商业用途，禁止用于任何违反法律法规的场景。
# Fully open source. Commercial use and any unlawful use prohibited.
# ---------------------------------------------------------------

[ -n "$MODDIR" ] || MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd)

SD_DATA="${SD_DATA:-/data/adb/quickcharge}"
case "$SD_DATA" in
    ""|/|/data|/data/adb|/data/adb/) SD_DATA=/data/adb/quickcharge ;;
esac

SD_STATE="$SD_DATA/state.conf"
SD_LOG="$SD_DATA/log.txt"
SD_OLD="$SD_DATA/log.old.txt"
SD_MOUNTS="$SD_DATA/mounts.list"
SD_BACKUP="$SD_DATA/backup"
SD_RUN="$SD_DATA/run"
SD_SPOOF_DIR="${SD_SPOOF_DIR:-}"
SD_SPOOF_DEF="${SD_SPOOF_DEF:-/dev/qc}"
SD_SPOOF_FLAG="$SD_RUN/spoof.pending"
SD_BUILT="$SD_DATA/built.id"
SD_PS=/sys/class/power_supply
SD_BL="${SD_BL:-/sys/class/backlight}"
SD_FB="${SD_FB:-/sys/class/graphics/fb0/blank}"
SD_OPLUS_CHG="${SD_OPLUS_CHG:-/sys/class/oplus_chg/battery}"
SD_MTK_CMD="${SD_MTK_CMD:-/proc/mtk_battery_cmd}"
SD_VOTABLE="${SD_VOTABLE:-/proc/oplus-votable}"

SD_OVERRIDES="$MODDIR/files"
if mkdir -p "$SD_OVERRIDES/.wtest" 2>/dev/null; then
    rmdir "$SD_OVERRIDES/.wtest" 2>/dev/null
else
    SD_OVERRIDES="$SD_DATA/overrides"
fi

for _d in "$SD_DATA" "$SD_BACKUP" "$SD_RUN" "$SD_OVERRIDES"; do
    [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
done

[ -n "${SD_ZONE_GLOB:-}" ] || SD_ZONE_GLOB=/sys/class/thermal/thermal_zone*

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

_sd_uptime() {
    local u="" rest=""
    read -r u rest 2>/dev/null </proc/uptime || u=""
    case "$u" in
        ''|*[!0-9.]*)
            u=$(cat /proc/uptime 2>/dev/null)
            u=${u%% *}
            ;;
    esac
    u=${u%%.*}
    case "$u" in ''|*[!0-9]*) u=0 ;; esac
    _sd_rv=$u
}

sd_boot_ts() {
    local up now
    _sd_uptime
    up=$_sd_rv
    now=$(date +%s 2>/dev/null) || now=0
    [ "${now:-0}" -gt 0 ] || { printf '0'; return 0; }
    [ "$up" -gt 0 ] || { printf '0'; return 0; }
    printf '%s' $((now - up))
}

sd_file_mtime() {
    local t
    t=$(stat -c %Y "$1" 2>/dev/null) || t=""
    case "$t" in
        ''|*[!0-9]*) t=$(date +%s 2>/dev/null || printf '0') ;;
    esac
    printf '%s' "$t"
}

sd_log_reset() {
    rm -f "$SD_LOG" "$SD_OLD" 2>/dev/null
    return 0
}

sd_session() {
    local tag="$1"
    shift
    printf '\n======== %s | %s | pid=%s ========\n' \
        "$(date '+%m-%d %H:%M:%S')" "$tag" "$$" 2>/dev/null >>"$SD_LOG"
    [ "$#" -gt 0 ] && printf '  %s\n' "$*" 2>/dev/null >>"$SD_LOG"
    return 0
}

sd_dump_env() {
    local dev rom kver zones emul sentinel stype stemp slim _e _sh
    dev="$(getprop ro.product.odm.manufacturer 2>/dev/null) $(getprop ro.product.model 2>/dev/null)"
    dev=$(printf '%s' "$dev" | sed 's/^ *//; s/ *$//')
    rom=$(getprop ro.build.display.id 2>/dev/null)
    kver=$(uname -r 2>/dev/null)
    [ "$_sd_st_loaded" = 1 ] || sd_state_load
    sd_zone_scan

    zones=0
    emul=""
    for _e in $_sd_zones; do
        zones=$((zones + 1))
        [ -e "${_e%%:*}/emul_temp" ] && emul="$emul $(basename "${_e%%:*}")"
    done
    [ -e /proc/shell-temp ] && _sh=yes || _sh=no

    sentinel=""
    if sd_pick_sentinel_v; then
        sentinel=$_sd_rv
        stype=$_sd_sent_type
        sd_sentinel_temp_v "$sentinel" && stemp=$_sd_rv
        sd_limit_for_type_v "$stype"; slim=$_sd_rv
    fi

    _sd_emit I env "device=${dev:-?} rom=${rom:-?} kernel=${kver:-?}"
    sd_plat_resolve
    sd_proto_resolve
    _sd_emit I env "soc=${_sd_plat}（${_sd_plat_why}） proto=${_sd_proto}（${_sd_proto_why}）"
    _sd_emit I env "zones=$zones emul=[${emul# }] shell-temp=$_sh charge-nodes=$(sd_curr_nodes 2>/dev/null | wc -l | tr -d ' ')"
    if [ -n "$sentinel" ]; then
        _sd_emit I env "sentinel=$(basename "$sentinel") type=${stype:-?} temp=${stemp:-?}℃ limit=${slim:-?}℃"
    else
        _sd_emit I env "sentinel=none（未找到电池/主板温度节点，伪装无法工作）"
    fi
    _sd_emit I env "state=$(sd_state_dump)"
    return 0
}

sd_check() {
    local n=0 ok=0 emul="" sh="" cfg=0 cur="" cells=1 why="" grade="" note=""
    local temp_ok=0 sname="" e z t pt pr ncur=0

    printf '== Quick Charge 适配检查 ==\n'
    printf '模块: v%s · %s / Android %s\n' \
        "$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)" \
        "$(getprop ro.soc.model 2>/dev/null || echo '?')" \
        "$(getprop ro.build.version.release 2>/dev/null || echo '?')"

    _sd_scanned=0
    sd_zone_scan
    for e in $_sd_zones; do
        z=${e%%:*}
        n=$((n + 1))
        if _sd_temp_readable "$z"; then
            ok=$((ok + 1))
            if [ -z "$emul" ] && [ -e "$z/emul_temp" ]; then emul=$z; fi
        fi
    done
    if sd_pick_batt_zone_v; then
        sname=${_sd_rv##*/}
    elif sd_batt_temp_v; then
        sname="battery(ps)"
    else
        sd_pick_sentinel_v && sname=${_sd_rv##*/}
    fi
    [ -e /proc/shell-temp ] && sh=yes

    cfg=$(find "$SD_OVERRIDES" -type f 2>/dev/null | wc -l | tr -d ' ')
    [ -n "$cfg" ] || cfg=0
    cur=$(sd_curr_nodes 2>/dev/null)
    [ -n "$cur" ] && ncur=$(printf '%s\n' "$cur" | grep -c .)

    sd_bcc_parse
    if [ "$_sd_cell_ok" = 1 ]; then
        sd_cells_resolve "$_sd_cell_v0" "$_sd_cell_v1"
    else
        sd_cells_resolve
    fi
    cells=$_sd_rv
    case "$_sd_cell_src" in
        aging)  why="aging 直报" ;;
        bcc)    why="bcc 电压推算" ;;
        volt)   why="整包电压" ;;
        manual) why="手动指定" ;;
        *)      why="无依据，按单芯" ;;
    esac

    [ -n "$emul" ] && temp_ok=1
    [ "$sh" = yes ] && temp_ok=1

    if [ "$ok" -eq 0 ]; then
        printf '[--] 温区     %s 个 · 一个都读不到\n' "$n"
        z=$(printf '%s' "$_sd_zones" | awk '{print $1}')
        z=${z%%:*}
        if [ -n "$z" ]; then
            printf '     首个温区 %s · type=%s\n' "${z##*/}" \
                "$(tr -d '\r\n' <"$z/type" 2>/dev/null)"
            printf '     temp 原始: %s\n' \
                "$(od -An -c "$z/temp" 2>/dev/null | head -1 | tr -s ' ')"
        fi
    else
        printf '[ok] 温区     %s 个 · 可读 %s 个%s\n' "$n" "$ok" \
            "${sname:+ · 哨兵 $sname}"
    fi
    if [ -n "$emul" ]; then
        printf '[ok] 温度改写 emul_temp（%s）\n' "${emul##*/}"
    elif [ "$sh" = yes ]; then
        printf '[ok] 温度改写 /proc/shell-temp\n'
    else
        printf '[--] 温度改写 不可用（无 emul_temp，也无 shell-temp）\n'
    fi
    if [ "$cfg" -gt 0 ]; then
        printf '[ok] 配置改写 命中 %s 个\n' "$cfg"
    else
        printf '[--] 配置改写 未命中本机型的配置文件\n'
    fi
    if [ -n "$cur" ]; then
        printf '[ok] 限流     %s\n' "$(printf '%s\n' "$cur" | head -n 1)"
        [ "$ncur" -gt 1 ] && printf '             共 %s 个可写节点\n' "$ncur"
    else
        printf '[--] 限流     没找到可写的电流节点\n'
    fi
    case "$_sd_cell_src" in
        aging|bcc|manual) printf '[ok] 电芯     %s 芯 · %s\n' "$cells" "$why" ;;
        *)                printf '[--] 电芯     %s 芯 · %s\n' "$cells" "$why" ;;
    esac

    sd_plat_resolve
    sd_proto_resolve
    pt=$(sd_plat_text)
    pr=$(sd_proto_text)
    if [ "$_sd_plat" = mtk ]; then
        printf '[ok] 平台     %s · %s · 降档提前 2℃\n' "$pt" "$_sd_plat_why"
    else
        printf '[ok] 平台     %s · %s\n' "$pt" "$_sd_plat_why"
    fi
    case "$_sd_proto" in
        unknown) printf '[--] 协议     %s（%s）\n' "$pr" "$_sd_proto_why" ;;
        *)       printf '[ok] 协议     %s（%s）\n' "$pr" "$_sd_proto_why" ;;
    esac
    if [ -d "$SD_VOTABLE" ]; then
        printf '[ok] 投票     %s 存在 · 仅 UFCS/PPS 有效，本模块不写入\n' "$SD_VOTABLE"
    else
        printf '[--] 投票     %s 不存在 · 私有协议下本来也不适用\n' "$SD_VOTABLE"
    fi

    if [ "$ok" -eq 0 ]; then
        grade=D; note="温区读不到，伪装与熔断都没有依据"
    elif [ "$temp_ok" = 1 ] && [ "$cfg" -gt 0 ]; then
        grade=A; note="全功能可用"
    elif [ "$temp_ok" = 1 ]; then
        grade=B; note="仅运行时温度改写，本机型配置格式未适配"
    elif [ "$cfg" -gt 0 ]; then
        grade=C; note="仅配置文件改写，内核未开温度模拟"
    else
        grade=D; note="没有可用的改写路径"
    fi
    printf '结论: %s（%s）\n' "$note" "$grade"
    case "$_sd_plat:$_sd_proto" in
        mtk:vooc)
            printf '建议: MTK + 私有快充由内核 charger-manager 独立限温，温度墙设 40-42℃ 更稳\n' ;;
        mtk:*)
            printf '建议: MTK 温度编码与命名都已归一，若限流不生效先确认 constant_charge_current_max\n' ;;
    esac
    return 0
}

sd_probe() {
    local z t v n=0 ok=0 p line pid s up r lim zn out md em a why zv pd
    printf '== Quick Charge probe ==\n'
    printf '模块: %s  %s\n' "$MODDIR" "$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null)"
    v=""; read -r v 2>/dev/null < /proc/self/attr/current
    printf 'SELinux: %s · %s\n' "${v:-未知}" "$(getenforce 2>/dev/null || echo '?')"
    if pid=$(sd_daemon_pid 2>/dev/null); then
        printf '守护: 运行中 pid=%s\n' "$pid"
    else
        printf '守护: 未运行\n'
    fi

    printf '\n== 温区 ==\n'
    _sd_zones_ready
    for z in $SD_ZONE_GLOB; do
        [ -d "$z" ] || continue
        n=$((n + 1))
        t=""; sd_read1 "$z/type" && t=$_sd_rv
        v=""; sd_read1 "$z/temp" && v=$_sd_rv
        if [ -n "$v" ]; then ok=$((ok + 1)); s=ok; else s=读不到; fi
        sd_zone_class "${t:-}"
        printf '  %-20s %-14s %-10s %-8s %s\n' "${z##*/}" "${t:-?}" "${v:--}" "$_sd_zc" "$s"
    done
    printf '  合计 %s 个，可读 %s 个\n' "$n" "$ok"
    if [ "$n" -eq 0 ]; then
        printf '  -> 没找到 %s，确认机型的温区路径\n' "$SD_ZONE_GLOB"
    elif [ "$ok" -eq 0 ]; then
        printf '  -> 温区存在但一个都读不到，多半是 SELinux 挡住了执行域\n'
    fi

    printf '\n== 电池节点 ==\n'
    for p in battery/temp battery/status battery/capacity mtk-battery/temp mtk-gauge/temp; do
        [ -e "$SD_PS/$p" ] || continue
        v=""; sd_read1 "$SD_PS/$p" && v=$_sd_rv
        printf '  %-18s %s\n' "$p" "${v:-读不到}"
    done
    for p in "$SD_PS/battery/uevent" "$SD_PS/bms/uevent"; do
        [ -f "$p" ] || continue
        while read -r line; do
            case "$line" in
                TEMP=*|STATUS=*|POWER_SUPPLY_TEMP=*)
                    printf '  %s: %s\n' "${p##*/}" "$line" ;;
            esac
        done <"$p"
    done
    if sd_batt_temp_v; then
        pd=$_sd_rv
        printf '  兜底读数: %s℃（温区全挂时用这个）\n' "$pd"
    else
        pd=""
        printf '  兜底读数: 无\n'
    fi
    if [ -n "$pd" ] && sd_pick_sentinel_v; then
        z=$_sd_rv
        if sd_sentinel_temp_v "$z"; then
            zv=$_sd_rv
            if [ "$zv" -lt 8 ] || [ "$zv" -gt 90 ]; then
                printf '  !! 温区 %s 报 %s℃（不在 8-90℃）→ 判定未初始化，改用电量计 %s℃\n' \
                    "${z##*/}" "$zv" "$pd"
            fi
        fi
    fi

    printf '\n== 平台 / 协议 ==\n'
    sd_plat_resolve
    sd_proto_resolve
    printf '  平台: %s（依据 %s）\n' "$(sd_plat_text)" "$_sd_plat_why"
    printf '  协议: %s（依据 %s）\n' "$(sd_proto_text)" "$_sd_proto_why"
    if [ -e "$SD_MTK_CMD/current_cmd" ]; then
        printf '  mtk_battery_cmd: 存在 · 开关接口（"0 0"/"0 1"），不能设电流，本模块不写\n'
    else
        printf '  mtk_battery_cmd: 无\n'
    fi
    if [ -d "$SD_VOTABLE" ]; then
        printf '  oplus-votable: 存在 · 仅 UFCS/PPS 有效，本模块只探测不写\n'
    else
        printf '  oplus-votable: 无\n'
    fi

    printf '\n== oplus_chg ==\n'
    if [ -d "$SD_OPLUS_CHG" ]; then
        for p in chg_enable chg_current_max current_max batt_temp fastcharge_mode; do
            [ -e "$SD_OPLUS_CHG/$p" ] || continue
            v=""; sd_read1 "$SD_OPLUS_CHG/$p" && v=$_sd_rv
            printf '  %-16s %s\n' "$p" "${v:-—}"
        done
    else
        printf '  %s 不存在（非欧加真，或走通用 power_supply 路径）\n' "$SD_OPLUS_CHG"
    fi

    printf '\n== 电芯 ==\n'
    sd_bcc_parse
    printf '  bcc_parms: %s\n' "${_sd_cell_raw:-读不到}"
    [ "$_sd_cell_ok" = 1 ] && printf '  解析: v0=%smV v1=%smV 电流=%smA\n' \
        "$_sd_cell_v0" "$_sd_cell_v1" "$_sd_cell_ma"
    a=""; sd_read1 "$SD_OPLUS_CHG/aging_ffc_data" && a=$_sd_rv
    printf '  aging_ffc_data: %s\n' "${a:-读不到}"
    if [ "$_sd_cell_ok" = 1 ]; then
        sd_cells_resolve "$_sd_cell_v0" "$_sd_cell_v1"
    else
        sd_cells_resolve
    fi
    case "$_sd_cell_src" in
        aging)  why="aging_ffc_data 直报" ;;
        bcc)    why="bcc_parms 电压推算" ;;
        volt)   why="整包电压 >6V" ;;
        manual) why="手动 cells $(sd_state_get cells_mode auto)" ;;
        *)      why="无可用依据，按单芯" ;;
    esac
    printf '  判定: %s 芯（%s）\n' "$_sd_rv" "$why"

    printf '\n== 缓存 ==\n'
    v=""; read -r v 2>/dev/null <"$SD_RUN/sensor"
    printf '  run/sensor: %s\n' "${v:-无}"
    if sd_hb_age; then
        printf '  心跳: %s 秒前\n' "$_sd_rv"
    else
        printf '  心跳: 无\n'
    fi

    printf '\n== 决策 ==\n'
    em=-1
    read -r up r lim zn out md em 2>/dev/null <"$SD_RUN/sensor" && {
        case "$em" in 0|1) _sd_emul_ok=$em ;; esac
    }
    sd_shell_target >/dev/null
    printf '  目标=%s℃ 真实=%s 上限=%s 温区=%s 停止线=%s 写入=%s\n' \
        "${_sd_last_out:-0}" "${_sd_last_cur:--}" "${_sd_last_lim:--}" \
        "${_sd_last_zone:--}" "${_sd_last_barrier:--}" "$_sd_emul_ok"
    if [ "${_sd_last_out:-0}" = "0" ]; then
        printf '  -> 目标为 0 表示关闭模拟：要么读到温度失败，要么真实温度已到停止线\n'
    fi

    printf '\n== 状态 ==\n'
    sd_state_dump
}

_sd_st_loaded=0
_st_temp_mode=""
_st_off_manual=""
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
_st_curr_edge=""
_st_log_level=""
_st_tick=""
_st_defrev=""
_st_hz=""
_st_hz_prev_peak=""
_st_hz_prev_min=""
_st_hz_hard=""
_st_hz_prev_mcfr=""
_st_power_scale=""
_st_batt_spoof=""

sd_state_load() {
    _sd_st_loaded=1
    _st_temp_mode=""; _st_off_manual=""; _st_shell_temp=""; _st_core_temp=""; _st_noncore_temp=""
    _st_horae=""; _st_sentinel_limit=""; _st_battery_limit=""; _st_fast_cap=""
    _st_curve_offset=""; _st_wall=""; _st_aggr=""; _st_curr_max=""
    _st_curr_edge=""
    _st_log_level=""; _st_tick=""; _st_defrev=""
    _st_hz=""; _st_hz_prev_peak=""; _st_hz_prev_min=""; _st_hz_hard=""; _st_hz_prev_mcfr=""; _st_power_scale=""
    _st_cells_mode=""; _st_batt_spoof=""
    [ -f "$SD_STATE" ] || { _st_log_level=3; _sd_lv=3; return 0; }
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            ''|*[!a-z_]*) continue ;;
            log_level) _st_log_level=$v ;;
            *) eval "_st_$k=\$v" ;;
        esac
    done 2>/dev/null <"$SD_STATE"
    case "$_st_log_level" in 0|1|2|3|4) _sd_lv=$_st_log_level ;; *) _st_log_level=3; _sd_lv=3 ;; esac
    return 0
}

sd_state_get() {
    [ "$_sd_st_loaded" = 1 ] || sd_state_load
    case "$1" in
        temp_mode)      printf '%s' "${_st_temp_mode:-${2:-off}}" ;;
        off_manual)     printf '%s' "${_st_off_manual:-${2:-0}}" ;;
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
        curr_edge)      printf '%s' "${_st_curr_edge:-${2:-4}}" ;;
        defrev)         printf '%s' "${_st_defrev:-${2:-2}}" ;;
        log_level)      printf '%s' "${_st_log_level:-${2:-3}}" ;;
        tick)           printf '%s' "${_st_tick:-${2:-15}}" ;;
        hz)             printf '%s' "${_st_hz:-${2:-off}}" ;;
        hz_prev_peak)   printf '%s' "${_st_hz_prev_peak:-${2:-}}" ;;
        hz_prev_min)    printf '%s' "${_st_hz_prev_min:-${2:-}}" ;;
        hz_hard)        printf '%s' "${_st_hz_hard:-${2:-0}}" ;;
        hz_prev_mcfr)   printf '%s' "${_st_hz_prev_mcfr:-${2:-}}" ;;
        power_scale)    printf '%s' "${_st_power_scale:-${2:-100}}" ;;
        cells_mode)     printf '%s' "${_st_cells_mode:-${2:-auto}}" ;;
        batt_spoof)     printf '%s' "${_st_batt_spoof:-${2:-off}}" ;;
        *)              printf '%s' "${2:-}" ;;
    esac
}

sd_state_set() {
    local k="$1" v="$2"
    [ "$_sd_st_loaded" = 1 ] || sd_state_load
    case "$k" in
        ''|*[!a-z_]*) return 1 ;;
        log_level) _st_log_level=$v
                   case "$v" in 0|1|2|3|4) _sd_lv=$v ;; esac ;;
        *) eval "_st_$k=\$v" ;;
    esac
    [ -f "$SD_STATE" ] || : >"$SD_STATE"

    local _lk="$SD_DATA/.state.lock" _i=0 _tmp
    while ! mkdir "$_lk" 2>/dev/null; do
        _i=$((_i + 1))
        if [ "$_i" -gt 100 ]; then
            rmdir "$_lk" 2>/dev/null
            break
        fi
        [ $((_i % 10)) -eq 0 ] && sleep 0.01 2>/dev/null
    done

    if grep -q "^$k=" "$SD_STATE" 2>/dev/null; then
        _tmp="$SD_STATE.t.$$"
        if awk -v k="$k" -v v="$v" 'BEGIN{FS="="} $1==k{print k"="v;next}{print}' \
                "$SD_STATE" >"$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
            mv -f "$_tmp" "$SD_STATE"
        fi
        rm -f "$_tmp" 2>/dev/null
    else
        printf '%s=%s\n' "$k" "$v" >>"$SD_STATE"
    fi
    rmdir "$_lk" 2>/dev/null
    return 0
}

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
        return 1
    fi
    sd_hb_age && [ "$_sd_rv" -le 90 ] && [ "${_sd_hb_pid:-}" = "$pid" ]
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
    rm -f "$SD_RUN/daemon.pid" "$SD_RUN/hb" "$SD_RUN/sensor" 2>/dev/null
    return 0
}

sd_daemon_launch() {
    local i=0 round=0 h="" m="${MODDIR:-${SD_MODDIR:-}}"
    [ -n "$m" ] && [ -f "$m/service.sh" ] || return 1
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
    rm -rf "$SD_RUN/daemon.lock" "$SD_RUN/daemon.pid" "$SD_RUN/hb" "$SD_RUN/sensor"
}

sd_telemetry_write() {
    sd_now_up
    printf '%s %s %s %s %s %s %s\n' \
        "$_sd_rv" "${_sd_last_cur:--}" "${_sd_last_lim:--}" \
        "${_sd_last_zone:--}" "${_sd_last_out:--}" "${_st_temp_mode:-off}" \
        "${_sd_emul_ok:--1}" \
        >"$SD_RUN/sensor" 2>/dev/null
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

sd_valid_temp() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 20 ] && [ "$1" -le 100 ]
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

sd_ps_attr_v() {
    local a="$1" p v
    for p in $_sd_ps_nodes; do
        sd_read1 "$SD_PS/$p/$a" || continue
        v=$_sd_rv
        _sd_rv=$v
        return 0
    done
    return 1
}

sd_batt_status_v() {
    sd_ps_attr_v status || _sd_rv=Unknown
    return 0
}

sd_batt_status() { sd_batt_status_v; printf '%s' "$_sd_rv"; }

sd_read1() {
    local v
    [ -e "$1" ] || return 1
    v=$(tr -d ' \t\r\n' <"$1" 2>/dev/null) || return 1
    [ -n "$v" ] || return 1
    _sd_rv=$v
    return 0
}

sd_temp_norm() {
    local v="$1"
    case "$v" in *.*) v=${v%%.*} ;; esac
    case "$v" in ''|*[!0-9-]*) return 1 ;; esac
    case "$v" in -*) return 1 ;; esac
    if [ "$v" -ge 2000 ]; then v=$((v / 1000))
    elif [ "$v" -ge 150 ]; then v=$((v / 10))
    fi
    [ "$v" -le 150 ] || return 1
    _sd_rv=$v
    return 0
}

_sd_batt_temp_norm() {
    sd_temp_norm "$1" || return 1
    [ "$_sd_rv" -ge 10 ] && [ "$_sd_rv" -le 120 ] || return 1
    return 0
}

SD_BATT_TEMP_NODES="${SD_PS}/battery/temp ${SD_PS}/mtk-battery/temp ${SD_PS}/mtk-gauge/temp ${SD_PS}/bms/temp"
SD_BATT_UEVENT_NODES="${SD_PS}/battery/uevent ${SD_PS}/mtk-gauge/uevent ${SD_PS}/bms/uevent"

sd_batt_temp_v() {
    local p line v
    for p in $SD_BATT_TEMP_NODES; do
        [ -f "$p" ] || continue
        sd_read1 "$p" || continue
        _sd_batt_temp_norm "$_sd_rv" && return 0
    done
    for p in $SD_BATT_UEVENT_NODES; do
        [ -f "$p" ] || continue
        while read -r line; do
            case "$line" in
                TEMP=*) _sd_batt_temp_norm "${line#TEMP=}" && return 0 ;;
            esac
        done <"$p"
    done
    return 1
}

sd_batt_real_v() {
    sd_batt_temp_v || return 1
    sd_temp_norm "$_sd_rv"
}

_sd_batt_spoof_on() {
    local v
    v=$(sd_state_get batt_spoof off)
    case "$v" in ''|off|0) return 1 ;; esac
    case "$v" in *[!0-9]*) return 1 ;; esac
    [ "$v" -ge 20 ] && [ "$v" -le 45 ] || return 1
    return 0
}

_sd_plat=""
_sd_plat_why=""

sd_plat_resolve() {
    [ -n "$_sd_plat" ] && return 0
    local bp sm hw hwline
    bp=$(getprop ro.board.platform 2>/dev/null)
    sm=$(getprop ro.soc.manufacturer 2>/dev/null)
    hw=$(getprop ro.hardware 2>/dev/null)
    case "$sm" in
        *[Mm]edia[Tt]ek*|*MTK*) _sd_plat=mtk; _sd_plat_why="${bp:-$sm}"; return 0 ;;
        *[Qq]ualcomm*)          _sd_plat=qcom; _sd_plat_why="${bp:-$sm}"; return 0 ;;
    esac
    case "$bp$hw" in
        *mt[0-9][0-9][0-9][0-9]*|*MT[0-9][0-9][0-9][0-9]*|*MTK*)
            _sd_plat=mtk
            _sd_plat_why="${bp:-$hw}" ;;
        *qcom*|*sm[0-9][0-9][0-9][0-9]*|*SM[0-9][0-9][0-9][0-9]*|*msm[0-9]*|*MSM[0-9]*|*kona*|*taro*|*kalama*|*crow*|*pineapple*|*canoe*|sun*)
            _sd_plat=qcom
            _sd_plat_why="${bp:-$hw}" ;;
        *)
            hwline=""
            hwline=$(grep -m1 -i '^Hardware' /proc/cpuinfo 2>/dev/null)
            case "$hwline" in
                *MT[0-9]*|*[Mm]edia[Tt]ek*)
                    _sd_plat=mtk; _sd_plat_why="cpuinfo:${hwline#*: }" ;;
                *[Qq]ualcomm*)
                    _sd_plat=qcom; _sd_plat_why="cpuinfo:${hwline#*: }" ;;
                *)
                    _sd_plat=other
                    _sd_plat_why="${bp:-${sm:-未知}}" ;;
            esac ;;
    esac
    [ -n "$_sd_plat_why" ] || _sd_plat_why="未知"
    return 0
}

sd_plat_text() {
    sd_plat_resolve
    case "$_sd_plat" in
        mtk)   printf 'MediaTek（MTK）' ;;
        qcom)  printf 'Qualcomm（高通）' ;;
        *)     printf '其他' ;;
    esac
}

_sd_proto=""
_sd_proto_why=""

sd_proto_resolve() {
    [ -n "$_sd_proto" ] && return 0
    local t="" v="" c="" p
    for p in "$SD_PS/usb/real_type" "$SD_PS/usb/type" "$SD_PS/battery/charge_type"; do
        [ -e "$p" ] || continue
        sd_read1 "$p" || continue
        t=$_sd_rv
        [ -n "$t" ] && { _sd_proto_why="${p##*/}=$t"; break; }
    done
    case "$t" in
        *VOOC*|*vooc*|*SVOOC*|*SuperDart*|*DART*|*Flash*|*SUPERVOOC*)
            _sd_proto=vooc; return 0 ;;
        *PPS*|*pps*)
            _sd_proto=pps; return 0 ;;
        *UFCS*|*ufcs*)
            _sd_proto=ufcs; return 0 ;;
        *PD*|*pd*)
            _sd_proto=pd; return 0 ;;
    esac

    v=""; sd_read1 "$SD_PS/usb/voltage_max" && v=$_sd_rv
    c=""; sd_read1 "$SD_PS/usb/current_max" && c=$_sd_rv
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    if [ "$v" -ge 8000 ] && [ "$c" -ge 5000000 ]; then
        _sd_proto=vooc
        _sd_proto_why="协商 $((v / 1000000))V/$((c / 1000))mA"
    elif [ "$v" -ge 8000 ] && [ "$c" -ge 2000000 ]; then
        _sd_proto=pps
        _sd_proto_why="协商 $((v / 1000000))V/$((c / 1000))mA"
    elif [ "$v" -gt 0 ] || [ "$c" -gt 0 ]; then
        _sd_proto=pd
        _sd_proto_why="协商 $((v / 1000000))V/$((c / 1000))mA"
    else
        _sd_proto=unknown
        _sd_proto_why="无适配器类型与协商值"
    fi
    return 0
}

sd_proto_text() {
    sd_proto_resolve
    case "$_sd_proto" in
        vooc)    printf 'VOOC / SuperVOOC 私有快充' ;;
        ufcs)    printf 'UFCS 公有快充' ;;
        pps)     printf 'PPS 公有快充' ;;
        pd)      printf 'PD / 普通快充' ;;
        *)       printf '未识别' ;;
    esac
}

_sd_zones=""
_sd_scanned=0
_sd_temp_fail=0
_sd_last_cur=""
_sd_last_out=""
_sd_wall_hold=0

sd_zone_scan() {
    local z t s=""
    for z in $SD_ZONE_GLOB; do
        [ -d "$z" ] || continue
        sd_read1 "$z/type" || continue
        s="$s $z:$_sd_rv"
    done
    _sd_zones="$s"
    _sd_scanned=1
    _sd_emul_last=""
}

_sd_zones_ready() { [ "$_sd_scanned" = 1 ] || sd_zone_scan; }

_sd_zc=""

sd_zone_class() {
    case "$1" in
        '') _sd_zc=other ;;
        *hw-trip*|*hw_trip*|*bcl-lvl*|*bcl_lvl*|*ibat-lvl*|*ibat_lvl*|vbat|vbatt|vbat*|vbatt*)
            _sd_zc=other ;;
        battery*|Battery*|batt*|*batt*|*battery*)
            _sd_zc=battery ;;
        shell*|Shell*|back*|case*|skin*|cover*|frame*)
            _sd_zc=shell ;;
        cpu*|CPU*|cpullc*|cpuss*|gpu*|GPU*|ddr*|*cpu*|*gpu*|mtktsap*|mtktsAP*|mtktsabb*|tzts*|tsen_max|ap[0-9]*|soc*|*soc*)
            _sd_zc=core ;;
        xo-therm*|xtherm*|*pmic*|*charger*|mtktspa|mtktswmt|mtktsbtsmdpa|pa|*_pa|board*|sys-therm*|pm[hr][0-9]*_tz|pm[0-9]*_tz)
            _sd_zc=board ;;
        *) _sd_zc=other ;;
    esac
    return 0
}

sd_zone_is_core() { sd_zone_class "$1"; [ "$_sd_zc" = core ]; }

sd_zone_is_shell() { sd_zone_class "$1"; [ "$_sd_zc" = shell ]; }

sd_zone_is_guarded() {
    sd_zone_class "$1"
    [ "$_sd_zc" = battery ] || [ "$_sd_zc" = board ]
}

sd_zone_is_guard_src() {
    case "$1" in
        xo-therm*|xtherm*) return 0 ;;
    esac
    sd_zone_class "$1"
    [ "$_sd_zc" = battery ]
}

sd_zone_is_hot_load() {
    case "$1" in
        *pa|*_pa|*wifi*|*wlan*|*mtktswmt*|*mtktsbtsmdpa*) return 0 ;;
    esac
    return 1
}

sd_zone_is_not_temp() {
    case "$1" in
        *hw-trip*|*hw_trip*|*bcl-lvl*|*bcl_lvl*|*ibat-lvl*|*ibat_lvl*|vbat|vbatt|vbat*|vbatt*)
            return 0 ;;
    esac
    return 1
}

sd_zone_in_scope() {
    sd_zone_is_not_temp "$1" && return 1
    case "$2" in
        core)    sd_zone_is_core "$1" ;;
        batt)    sd_zone_class "$1"
                 [ "$_sd_zc" = battery ] && ! sd_zone_is_hot_load "$1" ;;
        noncore) sd_zone_is_core "$1" && return 1
                 sd_zone_is_shell "$1" && return 1
                 sd_zone_is_guarded "$1" && return 1
                 return 0 ;;
        *)       return 0 ;;
    esac
}

_sd_spoof_fallback_ok() {
    sd_zone_is_not_temp "$1" && return 1
    sd_zone_class "$1"
    case "$_sd_zc" in
        battery|board|shell) return 1 ;;
    esac
    sd_zone_is_hot_load "$1" && return 1
    return 0
}

sd_zones_report() {
    local e z t c=0 n=0 cls mark sname
    _sd_zones_ready
    if [ -z "$_sd_zones" ]; then
        echo "温区表为空：当前执行域读不到 $SD_ZONE_GLOB"
        echo "（WebUI 通道与终端 su 的 SELinux 域不同，属正常；守护在自己的域里不受影响）"
        return 1
    fi
    for e in $_sd_zones; do
        z=${e%%:*}
        t=${e#*:}
        n=$((n + 1))
        if sd_zone_is_not_temp "$t"; then
            printf '%-26s %-8s %-5s %s\n' "${t:-?}" "非温度" "-" "${z##*/}"
            continue
        fi
        sd_zone_class "$t"
        cls=$_sd_zc
        if sd_zone_in_scope "$t" core; then
            mark=core
            c=$((c + 1))
        else
            mark=-
        fi
        printf '%-26s %-8s %-5s %s\n' "${t:-?}" "$cls" "$mark" "${z##*/}"
    done
    sname=none
    if sd_pick_batt_zone_v; then
        sname=${_sd_rv##*/}
    elif sd_batt_temp_v; then
        sname="battery(ps)"
    elif sd_pick_sentinel_v; then
        sname=${_sd_rv##*/}
    fi
    echo "共 $n 个温区，core 候选 $c 个，哨兵 $sname"
    [ "$c" -gt 0 ]
}

_sd_temp_readable() {
    sd_read1 "$1/temp" || return 1
    sd_temp_norm "$_sd_rv"
}

sd_temp_any() {
    local e z
    _sd_zones_ready
    for e in $_sd_zones; do
        z=${e%%:*}
        if sd_sentinel_temp_v "$z"; then
            _sd_rv_name=${z##*/}
            return 0
        fi
    done
    return 1
}

sd_read_real() {
    local z v
    _sd_rr_real=""
    _sd_rr_lim=""
    _sd_rr_zone=""
    _sd_rr_src=""
    _sd_rr_why=""
    _sd_rr_emul=-1
    [ "$_sd_st_loaded" = 1 ] || sd_state_load
    if sd_telemetry_read; then
        case "$_sd_tl_real" in
            ''|-) ;;
            *)
                _sd_rr_real=$_sd_tl_real
                _sd_rr_lim=$_sd_tl_lim
                _sd_rr_zone=$_sd_tl_zone
                _sd_rr_src="cache"
                _sd_rr_emul=${_sd_tl_emul:--1}
                return 0 ;;
        esac
    fi
    if sd_pick_batt_zone_v; then
        z=$_sd_rv
        _sd_rr_zone=${z##*/}
        sd_sentinel_temp_v "$z" && v=$_sd_rv
        sd_limit_for_type_v "$_sd_sent_type"; _sd_rr_lim=$_sd_rv
    elif sd_batt_temp_v; then
        _sd_rr_zone="battery(ps)"
        _sd_rr_real=$_sd_rv
        sd_limit_for_type_v battery; _sd_rr_lim=$_sd_rv
        _sd_rr_src="live"
        return 0
    elif sd_pick_sentinel_v; then
        z=$_sd_rv
        _sd_rr_zone=${z##*/}
        sd_sentinel_temp_v "$z" && v=$_sd_rv
        sd_limit_for_type_v "$_sd_sent_type"; _sd_rr_lim=$_sd_rv
    fi
    _sd_rr_src="live"
    if [ -n "$v" ]; then
        _sd_rr_real=$v
        return 0
    fi
    if sd_temp_any; then
        _sd_rr_real=$_sd_rv
        _sd_rr_zone=${_sd_rv_name:-$_sd_rr_zone}
        _sd_rr_src="live/备用"
        return 0
    fi
    if sd_batt_temp_v; then
        _sd_rr_real=$_sd_rv
        _sd_rr_zone="battery(ps)"
        _sd_rr_src="live/电池节点"
        sd_limit_for_type_v battery
        _sd_rr_lim=$_sd_rv
        return 0
    fi
    if [ -z "$_sd_zones" ]; then
        _sd_rr_why="没有温区节点"
    else
        _sd_rr_why="被 SELinux 挡住"
    fi
    return 0
}

_sd_rv=""
_sd_sent_type=""

_sd_clamp() {
    local v="$1"
    case "$v" in ''|*[!0-9]*) _sd_rv="$4"; return 0 ;; esac
    if [ "$v" -lt "$2" ] || [ "$v" -gt "$3" ]; then
        _sd_rv="$4"
        return 0
    fi
    _sd_rv="$v"
}

sd_sentinel_temp_v() {
    [ -n "$1" ] || return 1
    sd_read1 "$1/temp" || return 1
    sd_temp_norm "$_sd_rv"
}

_sd_temp_src=""
sd_batt_best_v() {
    local z="$1" zv="" pv=""
    if [ -n "$z" ] && sd_sentinel_temp_v "$z"; then
        zv=$_sd_rv
        if [ "$zv" -lt 8 ] || [ "$zv" -gt 90 ]; then zv=""; fi
    fi
    if sd_batt_temp_v; then
        pv=$_sd_rv
        if [ "$pv" -lt 5 ] || [ "$pv" -gt 80 ]; then pv=""; fi
    fi

    if [ -n "$zv" ] && [ -n "$pv" ]; then
        _sd_rv=$zv; _sd_temp_src=both
    elif [ -n "$zv" ]; then
        _sd_rv=$zv; _sd_temp_src=zone
    elif [ -n "$pv" ]; then
        _sd_rv=$pv; _sd_temp_src=ps
    else
        return 1
    fi
    return 0
}

sd_sentinel_best_v() {
    local z="$1" t="${2:-}"
    if [ -z "$t" ]; then sd_read1 "$z/type" && t=$_sd_rv; fi
    sd_zone_class "$t"
    if [ "$_sd_zc" = battery ]; then
        if _sd_batt_spoof_on; then
            sd_batt_real_v
            return $?
        fi
        sd_batt_best_v "$z"
        return $?
    fi
    sd_sentinel_temp_v "$z"
}

sd_pick_batt_zone_v() {
    local e z t
    _sd_zones_ready
    for e in $_sd_zones; do
        z=${e%%:*}
        t=${e#*:}
        sd_zone_class "$t"
        [ "$_sd_zc" = battery ] || continue
        sd_zone_is_hot_load "$t" && continue
        _sd_temp_readable "$z" && { _sd_rv=$z; _sd_sent_type=$t; return 0; }
    done
    return 1
}

sd_pick_sentinel_v() {
    local e z t pass
    _sd_zones_ready
    for pass in battery board other hot; do
        for e in $_sd_zones; do
            z=${e%%:*}
            t=${e#*:}
            if [ "$pass" = hot ]; then
                sd_zone_is_hot_load "$t" || continue
            else
                sd_zone_class "$t"
                [ "$_sd_zc" = "$pass" ] || continue
                sd_zone_is_hot_load "$t" && continue
            fi
            _sd_temp_readable "$z" && { _sd_rv=$z; _sd_sent_type=$t; return 0; }
        done
    done
    return 1
}

sd_limit_for_type_v() {
    sd_zone_class "$1"
    case "$_sd_zc" in
        battery)
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

sd_shell_target() {
    local base gap wall z cur limit barrier room climb v
    _sd_last_cur=""
    _sd_last_out=0
    _sd_last_base=""
    _sd_last_barrier=""
    _sd_base_clamped=0
    _sd_last_lim=""
    _sd_last_zone=""
    [ "$_sd_st_loaded" = 1 ] || sd_state_load

    _sd_clamp "${_st_shell_temp:-30}" 25 60 30
    base=$_sd_rv
    _sd_clamp "${_st_aggr:-10}" 0 10 10
    gap=$((2 + _sd_rv))
    case "${_st_wall:-off}" in
        off|'') wall=0 ;;
        *) _sd_clamp "${_st_wall:-42}" 35 80 42; wall=$_sd_rv ;;
    esac

    cur=""
    limit=""
    if sd_pick_batt_zone_v; then
        z=$_sd_rv
        _sd_last_zone=${z##*/}
        sd_sentinel_best_v "$z" "$_sd_sent_type" && cur=$_sd_rv
        sd_limit_for_type_v "$_sd_sent_type"
        limit=$_sd_rv
    elif sd_batt_temp_v; then
        cur=$_sd_rv
        _sd_last_zone="battery(ps)"
        _sd_sent_type=battery
        sd_limit_for_type_v battery
        limit=$_sd_rv
    elif sd_pick_sentinel_v; then
        z=$_sd_rv
        _sd_last_zone=${z##*/}
        sd_sentinel_best_v "$z" "$_sd_sent_type" && cur=$_sd_rv
        sd_limit_for_type_v "$_sd_sent_type"
        limit=$_sd_rv
    fi

    if [ -z "$cur" ]; then
        _sd_temp_fail=$((_sd_temp_fail + 1))
        printf '0'
        return 0
    fi
    _sd_temp_fail=0
    case "$limit" in ''|0|off) _sd_last_lim="" ;; *) _sd_last_lim=$limit ;; esac

    case "$limit" in
        ''|0|off)
            [ "$base" -gt "$cur" ] && base=$cur
            _sd_last_cur=$cur
            _sd_last_out=$base
            _sd_wall_hold=0
            printf '%s' "$base"
            return 0
            ;;
    esac

    if [ "$wall" -gt 0 ]; then
        barrier=$wall
    else
        barrier=$((limit - 2))
    fi
    _sd_last_barrier=$barrier

    if [ "$base" -ge "$barrier" ]; then
        base=$((barrier - 2))
        [ "$base" -lt 25 ] && base=25
        _sd_base_clamped=1
    fi
    _sd_last_base=$base

    if [ "$cur" -ge "$barrier" ] || { [ "$_sd_wall_hold" = 1 ] && [ "$cur" -gt $((barrier - 2)) ]; }; then
        _sd_wall_hold=1
        _sd_last_cur=$cur
        _sd_last_out=0
        printf '0'
        return 0
    fi
    _sd_wall_hold=0

    room=$((barrier - cur))
    v=$base
    [ $((cur - gap)) -gt "$v" ] && v=$((cur - gap))
    if [ "$room" -lt 4 ] && [ "$barrier" -gt "$base" ]; then
        climb=$((base + (barrier - base) * (4 - room) / 4))
        [ "$climb" -gt "$v" ] && v=$climb
    fi
    [ "$v" -gt "$cur" ] && v=$cur

    if [ "$v" -lt 20 ]; then
        _sd_last_cur=$cur
        _sd_last_out=0
        printf '0'
        return 0
    fi

    _sd_last_cur=$cur
    _sd_last_out=$v
    sd_dbg thermal "目标=${v}℃ base=${base} 真实=${cur} 屏障=${barrier} 余量=${room} gap=${gap}"
    printf '%s' "$v"
}

sd_zone_temp_unit() {
    local z="$1" v=""
    _sd_tu=mc
    sd_read1 "$z/temp" || return 1
    v=$_sd_rv
    case "$v" in *.*) v=${v%%.*} ;; esac
    case "$v" in ''|*[!0-9-]*) return 1 ;; esac
    if [ "$v" -ge 2000 ]; then _sd_tu=mc
    elif [ "$v" -ge 150 ]; then _sd_tu=d1
    else _sd_tu=c; fi
    return 0
}

sd_spoof_dir() {
    local d
    if [ -n "$SD_SPOOF_DIR" ]; then
        [ -d "$SD_SPOOF_DIR" ] || mkdir -p "$SD_SPOOF_DIR" 2>/dev/null
        if [ -d "$SD_SPOOF_DIR" ]; then
            chmod 700 "$SD_SPOOF_DIR" 2>/dev/null
            _sd_sd=$SD_SPOOF_DIR; return 0
        fi
    fi
    d=$SD_SPOOF_DEF
    if [ ! -d "$d" ]; then
        mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null
    fi
    if [ -d "$d" ]; then _sd_sd=$d; return 0; fi
    _sd_sd=$SD_RUN
    return 1
}

sd_spoof_file() {
    local b
    b=$(basename "$1")
    _sd_sf="$SD_RUN/$b.temp"
    [ -f "$_sd_sf" ] && return 0
    [ -n "$SD_SPOOF_DIR" ] && [ -f "$SD_SPOOF_DIR/$b.temp" ] && { _sd_sf="$SD_SPOOF_DIR/$b.temp"; return 0; }
    [ -f "$SD_SPOOF_DEF/$b.temp" ] && { _sd_sf="$SD_SPOOF_DEF/$b.temp"; return 0; }
    return 1
}

sd_spoof_unlink() {
    local b
    b=$(basename "$1")
    rm -f "$SD_RUN/$b.temp" "$SD_SPOOF_DEF/$b.temp" 2>/dev/null
    [ -n "$SD_SPOOF_DIR" ] && rm -f "$SD_SPOOF_DIR/$b.temp" 2>/dev/null
    rmdir "$SD_SPOOF_DEF" 2>/dev/null
    [ -n "$SD_SPOOF_DIR" ] && rmdir "$SD_SPOOF_DIR" 2>/dev/null
    return 0
}

sd_spoof_apply() {
    local scope="$1" celsius="$2" sentinel ms e z t n=0 fail=0 spd tf
    case "$celsius" in
        ''|*[!0-9]*) sd_err thermal "伪温度参数非法: $celsius"; return 1 ;;
    esac
    if [ "$celsius" -lt 20 ] || [ "$celsius" -gt 100 ]; then
        sd_err thermal "伪温度超出合理范围(20-100℃): $celsius"
        return 1
    fi
    if [ "$scope" = batt ] && [ "$celsius" -gt 45 ]; then
        sd_err thermal "电池伪装上限 45℃（再高就失去意义且危险）: $celsius"
        return 1
    fi

    _sd_zones_ready
    [ -d "$SD_RUN" ] || mkdir -p "$SD_RUN" 2>/dev/null
    if sd_spoof_dir; then
        spd=$_sd_sd
    else
        spd=$_sd_sd
        [ "${_sd_spd_warned:-0}" = 0 ] && {
            _sd_spd_warned=1
            sd_warn thermal "临时文件落点不可用，回退到 $SD_RUN"
        }
    fi
    _sd_spoof_total=0
    _sd_spoof_fail=0
    _sd_spoof_need=0
    _sd_spoof_sample=""
    sentinel=""
    sd_pick_sentinel_v && sentinel=$_sd_rv
    ms=$((celsius * 1000))

    _sd_spoof_fallback=0
    if [ "$scope" = core ]; then
        _sd_cand=0
        for e in $_sd_zones; do
            z=${e%%:*}
            t=${e#*:}
            if [ -n "$sentinel" ] && [ "$z" = "$sentinel" ]; then
                continue
            fi
            sd_zone_in_scope "$t" core && { _sd_cand=1; break; }
        done
        [ "$_sd_cand" = 1 ] || _sd_spoof_fallback=1
    fi

    for e in $_sd_zones; do
        z=${e%%:*}
        t=${e#*:}
        if [ "$scope" != batt ] && [ -n "$sentinel" ] && [ "$z" = "$sentinel" ]; then
            continue
        fi
        if ! sd_zone_in_scope "$t" "$scope"; then
            if [ "$_sd_spoof_fallback" = 1 ] && _sd_spoof_fallback_ok "$t"; then
                :
            else
                if [ "${#_sd_spoof_sample}" -lt 120 ]; then
                    if sd_zone_is_not_temp "$t"; then
                        _sd_spoof_sample="$_sd_spoof_sample ${t:-空}→非温度"
                    else
                        sd_zone_class "$t"
                        _sd_spoof_sample="$_sd_spoof_sample ${t:-空}→$_sd_zc"
                    fi
                fi
                continue
            fi
        fi
        if ! sd_read1 "$z/temp"; then
            _sd_spoof_need=$((_sd_spoof_need + 1))
            [ "${#_sd_spoof_sample}" -lt 120 ] &&
                _sd_spoof_sample="$_sd_spoof_sample ${t:-空}→温度读不到"
            continue
        fi
        _sd_spoof_total=$((_sd_spoof_total + 1))

        if [ ! -f "$SD_RUN/$(basename "$z").real" ]; then
            _sd_diag_temp "$z" >"$SD_RUN/$(basename "$z").real" 2>/dev/null
        fi
        sd_zone_temp_unit "$z"
        case "$_sd_tu" in
            d1) ms=$((celsius * 10)) ;;
            c)  ms=$celsius ;;
            *)  ms=$((celsius * 1000)) ;;
        esac

        umount -l "$z/temp" 2>/dev/null
        tf="$spd/$(basename "$z").temp"
        if ! printf '%s\n' "$ms" >"$tf" 2>/dev/null; then
            tf="$SD_RUN/$(basename "$z").temp"
            if ! printf '%s\n' "$ms" >"$tf" 2>/dev/null; then
                sd_err thermal "写临时文件失败: $(basename "$z")"
                fail=$((fail + 1))
                continue
            fi
        fi
        chmod 644 "$tf" 2>/dev/null
        umount -l "$z/temp" 2>/dev/null
        if mount -o bind "$tf" "$z/temp" 2>/dev/null \
           || mount --bind "$tf" "$z/temp" 2>/dev/null; then
            n=$((n + 1))
            sd_dbg thermal "  ok $(basename "$z") ($t) → ${celsius}℃（编码 $_sd_tu）"
        else
            fail=$((fail + 1))
            sd_warn thermal "  挂载失败: $(basename "$z") ($t)"
        fi
    done

    _sd_spoof_fail=$fail
    sd_info thermal "伪装 $scope → ${celsius}℃，命中 $n，失败 $fail，哨兵=$(basename "${sentinel:-none}")"
    [ "$n" -gt 0 ]
}

sd_spoof_clear_scope() {
    local e z t n=0
    _sd_zones_ready
    for e in $_sd_zones; do
        z=${e%%:*}
        t=${e#*:}
        sd_zone_in_scope "$t" "$1" || continue
        { umount "$z/temp" 2>/dev/null || umount -l "$z/temp" 2>/dev/null; } && n=$((n + 1))
        sd_spoof_unlink "$z"
    done
    sd_info thermal "撤销 $1 伪装，解除 $n 个节点"
}

sd_spoof_clear() {
    local e n=0
    _sd_zones_ready
    for e in $_sd_zones; do
        { umount "${e%%:*}/temp" 2>/dev/null || umount -l "${e%%:*}/temp" 2>/dev/null; } \
            && n=$((n + 1))
    done
    rm -f "$SD_RUN"/*.temp "$SD_RUN"/*.real 2>/dev/null
    rm -f "$SD_SPOOF_DEF"/*.temp 2>/dev/null
    [ -n "$SD_SPOOF_DIR" ] && rm -f "$SD_SPOOF_DIR"/*.temp 2>/dev/null
    rmdir "$SD_SPOOF_DEF" 2>/dev/null
    [ -n "$SD_SPOOF_DIR" ] && rmdir "$SD_SPOOF_DIR" 2>/dev/null
    sd_info thermal "撤销全部伪装，解除 $n 个节点"
}

_sd_emul_last=""
_sd_emul_ok=-1

_sd_guard_paused=0

sd_shell_emul() {
    local celsius="$1" ms e z t n=0 ps=0
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
        z=${e%%:*}
        t=${e#*:}
        sd_zone_is_shell "$t" || continue
        [ -e "$z/emul_temp" ] || continue
        printf '%s\n' "$ms" 2>/dev/null >"$z/emul_temp" && n=$((n + 1))
    done

    if [ -e /proc/shell-temp ]; then
        t=0
        while [ "$t" -le 9 ]; do
            printf '%s %s\n' "$t" "$ms" 2>/dev/null >/proc/shell-temp && ps=1
            t=$((t + 1))
        done
    fi

    if [ "$celsius" -eq 0 ]; then
        _sd_emul_ok=1
        sd_dbg thermal "关闭壳温模拟，改读真实读数"
    elif [ "$n" -gt 0 ] || [ "$ps" = 1 ]; then
        _sd_emul_ok=1
        sd_dbg thermal "壳温写 ${celsius}℃ 到 $n 个节点"
    else
        _sd_emul_ok=0
        sd_warn thermal "壳温节点不可写（无 emul_temp 或权限被拒），目标 ${celsius}℃"
    fi
    return 0
}

sd_guard_one() {
    local z="$1" t="${2:-}" limit cur
    [ -n "$t" ] || { sd_read1 "$z/type" && t=$_sd_rv; }
    sd_limit_for_type_v "$t"
    limit=$_sd_rv
    case "$limit" in ''|0|off) return 1 ;; esac
    sd_sentinel_best_v "$z" "$t" || return 1
    cur=$_sd_rv
    [ "$cur" -ge "$limit" ] || return 1

    sd_warn guard "⚠ 熔断：哨兵 ${z##*/} 实测 ${cur}℃ ≥ 上限 ${limit}℃"
    sd_spoof_clear
    _sd_emul_last=""
    sd_shell_emul 0
    _sd_guard_paused=1
    sd_warn guard "已暂停伪装，温度回落后自动恢复（配置未改动）"
    return 0
}

sd_guard_cooled() {
    local e z t limit cur ok=1 checked=0 blind=0
    _sd_zones_ready
    for e in $_sd_zones; do
        z=${e%%:*}; t=${e#*:}
        sd_zone_is_guard_src "$t" || continue
        sd_limit_for_type_v "$t"; limit=$_sd_rv
        case "$limit" in ''|0|off) continue ;; esac
        checked=$((checked + 1))
        if ! sd_sentinel_best_v "$z" "$t"; then
            ok=0; blind=1
            continue
        fi
        cur=$_sd_rv
        [ $((cur + 3)) -le "$limit" ] || ok=0
    done
    if [ "$checked" -eq 0 ]; then
        sd_limit_for_type_v battery; limit=$_sd_rv
        case "$limit" in
            ''|0|off) ;;
            *)
                if sd_batt_temp_v; then
                    checked=1
                    [ $((_sd_rv + 3)) -le "$limit" ] || ok=0
                else
                    ok=0; blind=1
                fi ;;
        esac
    fi
    if [ "$blind" = 1 ] && [ "$ok" = 0 ]; then
        if [ "${_sd_cool_blind:-0}" = 0 ]; then
            _sd_cool_blind=1
            sd_warn guard "熔断复查读不到温度，暂时保持熔断（不猜安全）"
        fi
    else
        _sd_cool_blind=0
    fi
    [ "$checked" -gt 0 ] && [ "$ok" = 1 ]
}

SD_BATT_HARD=46
_sd_batt_sp_last=""
_sd_batt_sp_on=0
_sd_batt_sp_hold=0

sd_spoof_batt_off() {
    local e z t n=0
    _sd_zones_ready
    for e in $_sd_zones; do
        z=${e%%:*}
        t=${e#*:}
        sd_zone_in_scope "$t" batt || continue
        { umount "$z/temp" 2>/dev/null || umount -l "$z/temp" 2>/dev/null; } && n=$((n + 1))
        sd_spoof_unlink "$z"
    done
    _sd_batt_sp_last=""
    _sd_batt_sp_on=0
    [ "$n" -gt 0 ] && sd_dbg thermal "撤销电池温区伪装 $n 个"
    return 0
}

sd_batt_sp_guard() {
    local want real now
    want=$(sd_state_get batt_spoof off)
    case "$want" in
        ''|off|0)
            [ "${_sd_batt_sp_on:-0}" = 1 ] && sd_spoof_batt_off
            return 0 ;;
        *[!0-9]*) return 0 ;;
    esac
    [ "$want" -ge 20 ] && [ "$want" -le 45 ] || { sd_spoof_batt_off; return 1; }
    [ "${_st_temp_mode:-}" = off ] && { sd_spoof_batt_off; return 0; }

    if ! sd_batt_real_v; then
        sd_spoof_batt_off
        sd_state_set batt_spoof off
        sd_warn guard "读不到真实电池温度（power_supply），已关闭电池伪装"
        return 1
    fi
    real=$_sd_rv
    now=$(date +%s)
    if [ "$real" -ge "$SD_BATT_HARD" ]; then
        sd_spoof_batt_off
        _sd_batt_sp_hold=$((now + 120))
        sd_warn guard "真实电池 ${real}℃ ≥ 硬上限 ${SD_BATT_HARD}℃，撤销电池伪装并冷却 120s"
        return 1
    fi
    if [ "$_sd_batt_sp_hold" -gt "$now" ]; then
        sd_spoof_batt_off
        return 1
    fi
    [ "$want" = "$_sd_batt_sp_last" ] && [ "${_sd_batt_sp_on:-0}" = 1 ] && return 0
    if sd_spoof_apply batt "$want" >/dev/null 2>&1; then
        _sd_batt_sp_last=$want
        _sd_batt_sp_on=1
    fi
    return 0
}

sd_spoof_reapply() {
    local c nc b_
    c=$(sd_state_get core_temp off)
    case "$c" in ''|off) ;; *) sd_valid_temp "$c" && sd_spoof_apply core "$c" ;; esac
    nc=$(sd_state_get noncore_temp off)
    case "$nc" in ''|off) ;; *) sd_valid_temp "$nc" && sd_spoof_apply noncore "$nc" ;; esac
    b_=$(sd_state_get batt_spoof off)
    case "$b_" in ''|off|0) ;; *) sd_batt_sp_guard ;; esac
}

sd_spoof_request() {
    [ -d "$SD_RUN" ] || mkdir -p "$SD_RUN" 2>/dev/null
    : >"$SD_SPOOF_FLAG" 2>/dev/null
}

sd_spoof_pending() {
    [ -f "$SD_SPOOF_FLAG" ] || return 0
    local c nc ok=1 n=0
    read -r n 2>/dev/null <"$SD_SPOOF_FLAG"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac

    c=${_st_core_temp:-off}
    case "$c" in ''|off) ;; *)
        sd_valid_temp "$c" && sd_spoof_apply core "$c" || ok=0 ;;
    esac
    nc=${_st_noncore_temp:-off}
    case "$nc" in ''|off) ;; *)
        sd_valid_temp "$nc" && sd_spoof_apply noncore "$nc" || ok=0 ;;
    esac

    if [ "$ok" = 1 ]; then
        rm -f "$SD_SPOOF_FLAG" 2>/dev/null
        sd_info thermal "守护补齐伪装请求（core=${c:-off} noncore=${nc:-off}）"
    elif [ "$n" -ge 8 ]; then
        rm -f "$SD_SPOOF_FLAG" 2>/dev/null
        sd_warn thermal "伪装请求连续 8 次无法落地，已放弃；用 diag 看温区是否可读"
    else
        printf '%s\n' "$((n + 1))" >"$SD_SPOOF_FLAG" 2>/dev/null
    fi
    return 0
}

sd_sentinel_guard() {
    local e z t fb="" fb_t="" checked=0
    [ "$_sd_st_loaded" = 1 ] || sd_state_load

    if [ "$_sd_guard_paused" = 1 ]; then
        if sd_guard_cooled; then
            _sd_guard_paused=0
            sd_info guard "温度已回落，恢复伪装"
            sd_spoof_reapply
            sd_sync_desc
        else
            return 1
        fi
    fi

    if [ "${_st_temp_mode:-off}" = "off" ] \
        && [ "${_st_core_temp:-off}" = "off" ] \
        && [ "${_st_noncore_temp:-off}" = "off" ]; then
        return 0
    fi
    _sd_zones_ready
    for e in $_sd_zones; do
        z=${e%%:*}
        t=${e#*:}
        [ -r "$z/temp" ] || continue
        if sd_zone_is_guard_src "$t"; then
            checked=1
            sd_guard_one "$z" "$t" && return 1
            continue
        fi
        sd_zone_is_core "$t" && continue
        sd_zone_is_shell "$t" && continue
        [ -z "$fb" ] && ! sd_zone_is_hot_load "$t" && { fb=$z; fb_t=$t; }
    done
    if [ "$checked" -eq 0 ] && sd_batt_temp_v; then
        checked=1
        sd_guard_one "$SD_PS/battery" battery && return 1
    fi
    if [ "$checked" -eq 0 ] && [ -n "$fb" ]; then
        sd_guard_one "$fb" "$fb_t" && return 1
    fi
    return 0
}

sd_horae() {
    case "$1" in
        1) setprop persist.sys.horae.enable 1; start horae 2>/dev/null; sd_info thermal "horae 启动" ;;
        0) setprop persist.sys.horae.enable 0; stop horae 2>/dev/null; sd_info thermal "horae 停止" ;;
    esac
}

SD_CFG_DIRS="/vendor/etc /odm/etc /system/vendor/etc /system/system_ext/etc /vendor/qti/etc"

sd_count_tags() { grep -o '<[/]*[A-Za-z_]' "$1" 2>/dev/null | wc -l | tr -d ' '; }

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

sd_xf_hightemp() {
    sed -E -e 's/([A-Za-z_]+=")true(")/\1false\2/g' -e 's/>true</>false</g' "$1" 2>/dev/null >"$2"
}

sd_xf_control() {
    sed -E 's/([A-Za-z_]+=")true(")/\1false\2/g' "$1" 2>/dev/null >"$2"
}

sd_xf_fps() {
    sed -E 's/fps="[0-9.]+"/fps="144"/g' "$1" 2>/dev/null >"$2"
}

sd_xf_legacy() {
    sed -E '/[Ee]nable/ s/>1</>0</g' "$1" 2>/dev/null >"$2"
}

sd_xf_chargejson() {
    sed -E 's/150,450\]/150,550]/g' "$1" 2>/dev/null >"$2"
}

sd_xf_qega() {
    sed -E \
        -e 's/(SkinTemperatureNode:[[:space:]]*)xo-therm/\1battery/' \
        -e '/^100001/s/^100001([[:space:]]+)hok[[:space:]]+48000[[:space:]]+1200/180001\1hok         55000          2000/' \
        -e '/^0[[:space:]]+adaptive/s/50000/55000/' \
        "$1" 2>/dev/null >"$2"
}

sd_xf_curve() {
    awk -F, -v off="$1" 'BEGIN{OFS=","}
        /^[0-9]+,[0-9]+,[0-9]+$/ { $1=$1+off; if ($1>600) $1=600; print; next }
        { print }' "$2" 2>/dev/null >"$3"
}

sd_xf_horae() { : >"$2"; return 0; }

sd_transform() {
    local src="$1" dst="$2" tmp rc=1 kind=xml bk
    tmp="$dst.sdtmp"

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

sd_fingerprint() {
    local vc off
    vc=$(grep '^versioncode=' "${MODDIR:-.}/module.prop" 2>/dev/null | cut -d= -f2)
    off=$(sd_state_int curve_offset 120 0 300)
    printf '%s-%s-%s-%s' \
        "$(getprop ro.build.display.id)" \
        "$(getprop ro.build.version.security_patch)" \
        "${vc:-0}" "$off"
}

sd_build_overrides() {
    local fp base f rel
    fp=$(sd_fingerprint)

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

SD_NM_ROOT="$MODDIR/system"
SD_NM_LIST="$SD_DATA/nm.list"

sd_nm_active() {
    local d
    for d in /data/adb/modules/meta-nomount /data/adb/modules/nomount; do
        [ -d "$d" ] || continue
        [ -f "$d/disable" ] && continue
        [ -f "$d/remove" ] && continue
        return 0
    done
    return 1
}

SD_MM_DIRS="/data/adb/modules/meta-hybrid_mount
/data/adb/modules/hybrid_mount
/data/adb/modules/meta-magic_mount
/data/adb/modules/meta-magic_mount-rs
/data/adb/modules/meta-mm
/data/adb/modules/magic_mount
/data/adb/modules/mountify"

sd_mm_active() {
    local d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        [ -d "$d" ] || continue
        [ -f "$d/disable" ] && continue
        [ -f "$d/remove" ] && continue
        _sd_mm=$d
        return 0
    done <<EOF
$SD_MM_DIRS
EOF
    return 1
}

sd_mm_name() {
    sd_mm_active || return 1
    case "${_sd_mm##*/}" in
        *hybrid*)  printf 'Hybrid Mount' ;;
        mountify*) printf 'Mountify' ;;
        *)         printf 'Magic Mount' ;;
    esac
}

sd_nm_bin() {
    local b
    for b in \
        /data/adb/modules/meta-nomount/bin/arm64-v8a/nomount \
        /data/adb/modules/meta-nomount/bin/arm64/nomount \
        /data/adb/modules/nomount/bin/arm64-v8a/nomount \
        /data/adb/modules/nomount/bin/arm64/nomount
    do
        [ -x "$b" ] && { _sd_rv=$b; return 0; }
    done
    b=$(command -v nomount 2>/dev/null)
    [ -n "$b" ] && [ -x "$b" ] && { _sd_rv=$b; return 0; }
    return 1
}

sd_nm_mirror() {
    local rel src dst cur="$SD_RUN/nm.cur" miss=0 found x
    [ -d "$SD_OVERRIDES" ] || return 2
    mkdir -p "$SD_RUN" 2>/dev/null
    : >"$cur" 2>/dev/null || return 2

    ( cd "$SD_OVERRIDES" 2>/dev/null || exit 1
      find . -type f 2>/dev/null | while IFS= read -r rel; do
          rel="${rel#./}"
          src="$SD_OVERRIDES/$rel"
          dst="$SD_NM_ROOT/$rel"
          mkdir -p "${dst%/*}" 2>/dev/null || continue
          if [ -f "$dst" ]; then
              cat "$src" >"$dst" 2>/dev/null || cp -f "$src" "$dst" 2>/dev/null
          else
              cp -f "$src" "$dst" 2>/dev/null
          fi
          [ -f "$dst" ] || continue
          if [ -e "/$rel" ]; then
              chmod --reference="/$rel" "$dst" 2>/dev/null
              chown --reference="/$rel" "$dst" 2>/dev/null
              chcon --reference="/$rel" "$dst" 2>/dev/null
          fi
          printf '%s\n' "$rel"
      done ) >"$cur"

    [ -s "$cur" ] || return 2

    if [ -s "$SD_NM_LIST" ]; then
        while IFS= read -r rel; do
            case "$rel" in ''|*..*) continue ;; esac
            found=0
            while IFS= read -r x; do
                [ "$x" = "$rel" ] && { found=1; break; }
            done <"$cur"
            [ "$found" = 1 ] || { rm -f "$SD_NM_ROOT/$rel" 2>/dev/null; miss=1; }
        done <"$SD_NM_LIST"
    fi

    [ "$miss" = 1 ] && { cp -f "$cur" "$SD_NM_LIST" 2>/dev/null; return 0; }
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$SD_NM_LIST" "$cur" 2>/dev/null && return 1
    fi
    cp -f "$cur" "$SD_NM_LIST" 2>/dev/null
    return 0
}

sd_nm_reload() {
    local b
    sd_nm_bin || return 1
    b=$_sd_rv
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$b" reload >/dev/null 2>&1 && return 0
    else
        "$b" reload >/dev/null 2>&1 && return 0
    fi
    return 1
}

sd_nm_purge() {
    local rel
    if [ -s "$SD_NM_LIST" ]; then
        while IFS= read -r rel; do
            case "$rel" in ''|*..*) continue ;; esac
            rm -f "$SD_NM_ROOT/$rel" 2>/dev/null
        done <"$SD_NM_LIST"
    fi
    : >"$SD_NM_LIST" 2>/dev/null
    find "$SD_NM_ROOT" -type d -empty -delete 2>/dev/null
    sd_nm_active && sd_nm_reload && sd_info mount "已从 NoMount 撤下覆盖层"
    return 0
}

sd_mount_mode() {
    if sd_nm_active; then
        [ -s "$SD_NM_LIST" ] && { printf 'nomount'; return 0; }
        printf 'nomount-idle'; return 0
    fi
    if sd_mm_active; then
        [ -s "$SD_NM_LIST" ] && { printf 'meta'; return 0; }
        printf 'meta-idle'; return 0
    fi
    if sd_mounts_alive; then printf 'bind'; return 0; fi
    printf 'none'
}

sd_mount_overrides() {
    local src rel dst n=0 nchg=0 chgfail="$SD_RUN/chcon.fail" total mmn
    [ -d "$SD_OVERRIDES" ] || return 1

    if sd_nm_active; then
        sd_nm_mirror
        case $? in
            1)
                : >"$SD_MOUNTS" 2>/dev/null
                sd_info mount "已交给 NoMount（内容原地更新，无挂载）"
                return 0 ;;
            0)
                : >"$SD_MOUNTS" 2>/dev/null
                if sd_nm_reload; then
                    sd_info mount "已交给 NoMount 注入，$(wc -l <"$SD_NM_LIST" 2>/dev/null | tr -d ' ') 个文件，无挂载"
                else
                    sd_warn mount "NoMount 无 reload 接口，新文件下次开机生效（当前无挂载）"
                fi
                return 0 ;;
            *)
                sd_warn mount "NoMount 镜像写入失败，退回 bind mount" ;;
        esac
    fi

    if sd_mm_active; then
        mmn=$(sd_mm_name)
        sd_nm_mirror
        case $? in
            2) sd_warn mount "$mmn 镜像写入失败，退回 bind mount" ;;
            *)
                : >"$SD_MOUNTS" 2>/dev/null
                sd_info mount "已交给 $mmn，system/ 下 $(wc -l <"$SD_NM_LIST" 2>/dev/null | tr -d ' ') 个文件，开机挂载"
                return 0 ;;
        esac
    fi

    sd_umount_overrides
    : >"$chgfail"
    total=$(find "$SD_OVERRIDES" -type f 2>/dev/null | wc -l | tr -d ' ')

    ( cd "$SD_OVERRIDES" 2>/dev/null || exit 1
      find . -type f 2>/dev/null | while IFS= read -r rel; do
          rel="${rel#./}"
          src="$SD_OVERRIDES/$rel"
          dst="/$rel"
          [ -e "$dst" ] || continue
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

sd_mounts_alive() {
    if sd_nm_active; then
        [ -s "$SD_NM_LIST" ] && [ -d "$SD_NM_ROOT" ] && return 0
        return 1
    fi
    [ -s "$SD_MOUNTS" ] || return 1
    awk 'NR==FNR { if ($0!="") want[$0]=1; next }
         ($2 in want) { hit[$2]=1 }
         END { exit (length(hit)>0 ? 0 : 1) }' "$SD_MOUNTS" /proc/mounts 2>/dev/null
}

sd_umount_overrides() {
    local p left n mp purge="${1:-}"
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
        [ -f "$p" ] || continue
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
        sd_nm_active || sd_info mount "配置覆盖已全部卸载"
    fi

    [ "$purge" = "purge" ] && sd_nm_purge
    return 0
}

sd_curr_nodes() {
    local n
    _sd_curr_prepare
    for n in $_sd_curr_nodes; do
        [ -e "$n" ] && printf '%s\n' "$n"
    done
    return 0
}

_sd_curr_pct=""
_sd_wall_eff=""

_sd_bl_node=""
_sd_screen_on=1
_sd_screen_n=0
_sd_screen_ticks=0

sd_screen_node() {
    local p
    if [ -n "$_sd_bl_node" ]; then
        [ "$_sd_bl_node" = none ] && return 1
        [ -e "$_sd_bl_node" ] && return 0
        _sd_bl_node=""
    fi
    for p in "$SD_BL/panel0-backlight/actual_brightness" \
             "$SD_BL"/*/actual_brightness \
             "$SD_BL"/*/brightness; do
        [ -e "$p" ] && { _sd_bl_node="$p"; return 0; }
    done
    _sd_bl_node="none"
    return 1
}

sd_screen_sample_v() {
    local v
    if sd_screen_node; then
        sd_read1 "$_sd_bl_node" || return 1
        v=$_sd_rv
        case "$v" in ''|*[!0-9]*) return 1 ;; esac
        [ "$v" -gt 0 ] && _sd_screen_raw=1 || _sd_screen_raw=0
        return 0
    fi
    if [ -e "$SD_FB" ]; then
        sd_read1 "$SD_FB" || return 1
        v=$_sd_rv
        case "$v" in ''|*[!0-9]*) return 1 ;; esac
        [ "$v" -eq 0 ] && _sd_screen_raw=1 || _sd_screen_raw=0
        return 0
    fi
    return 1
}

sd_screen_tick() {
    _sd_screen_ticks=1
    if ! sd_screen_sample_v; then
        _sd_screen_on=1
        _sd_screen_n=0
        return 0
    fi
    if [ "$_sd_screen_raw" = 1 ]; then
        _sd_screen_on=1
        _sd_screen_n=0
    else
        _sd_screen_n=$((_sd_screen_n + 1))
        [ "$_sd_screen_n" -ge 2 ] && _sd_screen_on=0
    fi
    return 0
}

sd_curr_target_v() {
    local ma wall cur pct last shift=0 t75 t50 t25 edge lim
    [ "$_sd_st_loaded" = 1 ] || sd_state_load
    _sd_clamp "${_st_curr_max:-0}" 0 8000 0
    ma=$_sd_rv
    [ "$ma" -gt 0 ] || { _sd_rv=0; return 0; }

    sd_pick_sentinel_v || { _sd_rv=$ma; return 0; }
    sd_sentinel_best_v "$_sd_rv" "$_sd_sent_type" || { _sd_rv=$ma; return 0; }
    cur=$_sd_rv

    case "${_st_wall:-off}" in
        off|'')
            sd_limit_for_type_v "${_sd_sent_type:-battery}"
            wall=$_sd_rv
            case "$wall" in ''|0|off) wall=48 ;; esac
            wall=$((wall - 4))
            [ "$wall" -lt 35 ] && wall=35
            [ "$wall" -gt 80 ] && wall=80 ;;
        *) _sd_clamp "${_st_wall:-42}" 35 80 42; wall=$_sd_rv
           [ "$wall" -gt 0 ] || wall=42 ;;
    esac

    _sd_sb_note=""
    [ "$_sd_screen_ticks" -gt 0 ] || sd_screen_tick
    if [ "$_sd_screen_on" = 0 ]; then
        wall=$((wall + 2))
        sd_limit_for_type_v "${_sd_sent_type:-battery}"
        case "$_sd_rv" in
            ''|0|off) ;;
            *) [ "$wall" -gt $((_sd_rv - 3)) ] && wall=$((_sd_rv - 3)) ;;
        esac
        _sd_sb_note="（息屏 +2℃）"
    fi
    _sd_wall_eff=$wall

    sd_plat_resolve
    [ "$_sd_plat" = mtk ] && shift=2
    _sd_shift_note=""
    [ "$shift" -gt 0 ] && _sd_shift_note="（MTK 提前 ${shift}℃）"

    _sd_clamp "${_st_curr_edge:-4}" 0 6 4
    edge=$_sd_rv
    t75=$((wall - edge - shift))
    t50=$((wall - edge + 2 - shift))
    t25=$((wall - edge + 4 - shift))
    [ "$t75" -lt 30 ] && t75=30
    sd_limit_for_type_v "${_sd_sent_type:-battery}"
    lim=$_sd_rv
    case "$lim" in ''|0|off) lim=48 ;; esac
    [ "$t25" -ge "$lim" ] && t25=$((lim - 1))
    [ "$t50" -ge "$t25" ] && t50=$((t25 - 1))
    [ "$t75" -ge "$t50" ] && t75=$((t50 - 1))

    pct=100
    [ "$cur" -ge "$t75" ] && pct=75
    [ "$cur" -ge "$t50" ] && pct=50
    [ "$cur" -ge "$t25" ] && pct=25

    last=${_sd_curr_pct:-100}
    case "$last" in ''|*[!0-9]*) last=100 ;; esac
    if [ "$pct" -gt "$last" ]; then
        case "$last" in
            25) [ "$cur" -le $((t25 - 1)) ] || pct=25 ;;
            50) [ "$cur" -le $((t50 - 1)) ] || pct=50 ;;
            75) [ "$cur" -le $((t75 - 1)) ] || pct=75 ;;
        esac
    fi
    _sd_curr_pct=$pct

    sd_dbg charge "电流目标 ${cur}℃/墙${wall}℃ → ${pct}% of ${ma}mA${_sd_shift_note}${_sd_sb_note}"
    _sd_rv=$((ma * pct / 100))
    return 0
}

sd_curr_target() { sd_curr_target_v; printf '%s' "$_sd_rv"; }

# ---------------------------------------------------------------- 亮屏快充
# 亮屏掉功率的落点在内核充电驱动的 fb_notifier：
#   亮屏 → reset_max_fcc_ma(chip, SCREEN_ON_MAX_FCC_MA, true)
# 屏幕一亮就把 FCC 压到 1500~2000mA（≈7~9W），与温度无关。
# 按优先级做两件事：
#   1) 有 ignore_screen_state → 置 1，让驱动忽略屏幕状态
#   2) 没有 → 记住息屏充电时的 FCC，亮屏被压低后写回
# 只在「充电中 + 开关开 + 未限流 + 未熔断 + 电池不烫」时接管，退出即还原。

SD_SCR_NODE=""
SD_SCR_ORIG="$SD_RUN/scr.orig"
SD_SCR_WAY="$SD_RUN/scr.way"
SD_SCR_FAIL="$SD_RUN/scr.fail"
SD_FCC_NORM="$SD_RUN/fcc.norm"
_sd_scr_on=0
_sd_scr_way=""
_sd_scr_log=""

sd_scr_node() {
    if [ -n "$SD_SCR_NODE" ]; then
        [ "$SD_SCR_NODE" = none ] && return 1
        [ -e "$SD_SCR_NODE" ] && return 0
        SD_SCR_NODE=""
    fi
    local p
    for p in /sys/module/oplus_chg/parameters/ignore_screen_state \
             /sys/module/oplus_chg_v2/parameters/ignore_screen_state \
             /sys/module/oplus_charge/parameters/ignore_screen_state \
             /sys/module/oplus_chg/parameters/chg_ignore_screen_state ; do
        [ -e "$p" ] && { SD_SCR_NODE=$p; return 0; }
    done
    SD_SCR_NODE=none
    return 1
}

sd_scr_fcc_node() {
    _sd_curr_prepare
    local n pref
    # 优先级：电池侧 FCC → 电池侧 current_max → USB 输入上限
    # 有些欧加机只暴露 usb/current_max（模块的限流也走它），不能漏
    for pref in constant_charge_current_max battery/current_max usb/current_max; do
        for n in $_sd_curr_nodes; do
            case "$n" in
                *"$pref") [ -e "$n" ] && { _sd_sf=$n; return 0; } ;;
            esac
        done
    done
    for n in $_sd_curr_nodes; do
        case "$n" in
            */current_max|*/constant_charge_current) [ -e "$n" ] && { _sd_sf=$n; return 0; } ;;
        esac
    done
    return 1
}

sd_scr_read_ma() {
    local v
    sd_read1 "$1" || return 1
    v=$_sd_rv
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$v" -gt 100000 ]; then _sd_rv=$((v / 1000)); else _sd_rv=$v; fi
    return 0
}

sd_scr_learn() {
    local v old=0
    sd_scr_fcc_node || return 1
    sd_scr_read_ma "$_sd_sf" || return 1
    v=$_sd_rv
    [ "$v" -ge 500 ] || return 1
    [ "$v" -gt 8000 ] && v=8000
    if [ -f "$SD_FCC_NORM" ]; then
        old=$(cat "$SD_FCC_NORM" 2>/dev/null)
        case "$old" in ''|*[!0-9]*) old=0 ;; esac
    fi
    [ "$v" -gt "$old" ] && printf '%s\n' "$v" >"$SD_FCC_NORM" 2>/dev/null
    return 0
}

# 目标电流：正常值，按真实电池温度打折；≥42℃ 直接不接管
sd_scr_target() {
    local n bt
    _sd_rv=0
    [ -f "$SD_FCC_NORM" ] || return 1
    n=$(cat "$SD_FCC_NORM" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    [ "$n" -gt 8000 ] && n=8000
    bt=""
    sd_batt_temp_v && bt=$_sd_rv
    case "$bt" in
        ''|*[!0-9]*) _sd_rv=$((n * 7 / 10)) ;;
        *) if [ "$bt" -le 38 ]; then _sd_rv=$n
           elif [ "$bt" -le 41 ]; then _sd_rv=$((n * 7 / 10))
           else _sd_rv=0; return 3; fi ;;
    esac
    [ "$_sd_rv" -ge 500 ]
}

# 返回值：0 成功；2 还没学到正常值；1 本机不支持
sd_scr_apply() {
    local tgt cur raw
    if sd_scr_node; then
        if [ ! -f "$SD_SCR_ORIG" ]; then
            sd_read1 "$SD_SCR_NODE" && printf '%s|%s\n' "$SD_SCR_NODE" "$_sd_rv" >"$SD_SCR_ORIG" 2>/dev/null
        fi
        printf '1\n' >"$SD_SCR_NODE" 2>/dev/null || return 1
        sd_read1 "$SD_SCR_NODE" || return 1
        [ "$_sd_rv" = 1 ] || return 1
        _sd_scr_on=1; _sd_scr_way=kernel
        printf 'kernel\n' >"$SD_SCR_WAY" 2>/dev/null
        rm -f "$SD_SCR_FAIL" 2>/dev/null
        return 0
    fi

    sd_scr_fcc_node || return 1
    [ "$_sd_screen_on" = 1 ] || return 1
    sd_scr_target
    case $? in
        0) ;;
        3) return 3 ;;      # 电池偏热，本轮不接管
        *) return 2 ;;      # 还没有基准
    esac
    tgt=$_sd_rv
    sd_scr_read_ma "$_sd_sf" || return 1
    cur=$_sd_rv
    if [ "$cur" -ge "$tgt" ]; then
        _sd_scr_on=1; _sd_scr_way=fcc
        printf 'fcc\n' >"$SD_SCR_WAY" 2>/dev/null
        rm -f "$SD_SCR_FAIL" 2>/dev/null
        return 0
    fi
    if [ ! -f "$SD_SCR_ORIG" ]; then
        raw=""
        sd_read1 "$_sd_sf" && raw=$_sd_rv
        case "$raw" in ''|*[!0-9]*) raw=$cur ;; esac
        printf '%s|%s\n' "$_sd_sf" "$raw" >"$SD_SCR_ORIG" 2>/dev/null
    fi
    _sd_curr_unit "$_sd_sf" "$cur"
    if [ "$_sd_unit" = ua ]; then
        printf '%s\n' "$((tgt * 1000))" >"$_sd_sf" 2>/dev/null
    else
        printf '%s\n' "$tgt" >"$_sd_sf" 2>/dev/null
    fi
    sd_scr_read_ma "$_sd_sf" || return 1
    [ "$_sd_rv" -ge $((tgt * 8 / 10)) ] || return 1
    _sd_scr_on=1; _sd_scr_way=fcc
    printf 'fcc\n' >"$SD_SCR_WAY" 2>/dev/null
    rm -f "$SD_SCR_FAIL" 2>/dev/null
    return 0
}

# 接管状态要跨进程可判：守护、action.sh、卸载脚本各自起进程，
# 只靠 _sd_scr_on 会让"关开关"这一下落在新进程里判成没接管过。
sd_scr_active() { [ "$_sd_scr_on" = 1 ] || [ -f "$SD_SCR_ORIG" ]; }

sd_scr_release() {
    local p v
    if [ -f "$SD_SCR_ORIG" ]; then
        while IFS='|' read -r p v; do
            [ -n "$p" ] && [ -e "$p" ] || continue
            printf '%s\n' "$v" >"$p" 2>/dev/null
        done <"$SD_SCR_ORIG"
        rm -f "$SD_SCR_ORIG" 2>/dev/null
    fi
    _sd_scr_on=0; _sd_scr_way=""
    rm -f "$SD_SCR_WAY" 2>/dev/null
    return 0
}

sd_scr_state() {
    [ "$(sd_state_get temp_mode off)" = off ] && { printf 'disabled'; return 0; }
    [ -f "$SD_SCR_FAIL" ] && { printf 'none'; return 0; }
    if [ -f "$SD_SCR_WAY" ]; then
        local w=""
        read -r w 2>/dev/null <"$SD_SCR_WAY"
        [ -n "$w" ] && { printf '%s' "$w"; return 0; }
    fi
    printf 'idle'
}

sd_scr_tick() {
    local mode bt
    [ "$_sd_st_loaded" = 1 ] || sd_state_load
    mode=$(sd_state_get temp_mode off)

    if [ "$mode" = off ]; then
        if sd_scr_active; then
            sd_scr_release
            _sd_scr_log=""
            sd_info charge "亮屏快充：已退出，屏幕状态恢复"
        fi
        return 0
    fi

    sd_batt_status_v
    case "$_sd_rv" in
        Charging|Full) ;;
        *) if sd_scr_active; then sd_scr_release; _sd_scr_log=""; fi
           return 0 ;;
    esac

    if [ "${_sd_guard_paused:-0}" = 1 ] || [ "$(sd_state_int curr_max 0 0 8000)" -gt 0 ]; then
        if sd_scr_active; then sd_scr_release; _sd_scr_log=""; fi
        return 0
    fi

    if [ "$_sd_screen_on" = 0 ]; then
        sd_scr_learn
        if sd_scr_active; then sd_scr_release; _sd_scr_log=""; fi
        return 0
    fi

    # 默认开启后所有人都会走到这里，两条路径共用一道温度闸：
    # 内核参数那条一写就是「永远不看屏幕」，高温时更不能开。
    bt=""
    sd_batt_temp_v && bt=$_sd_rv
    case "$bt" in
        ''|*[!0-9]*) ;;
        *) if [ "$bt" -ge 42 ]; then
               sd_scr_active && sd_scr_release
               if [ "$_sd_scr_log" != hot ]; then
                   sd_warn charge "亮屏快充：电池 ${bt}℃ 偏高，暂停接管"
                   _sd_scr_log=hot
               fi
               return 0
           fi ;;
    esac
    [ "$_sd_scr_log" = hot ] && _sd_scr_log=""

    sd_scr_apply
    case "$?" in
        0)
            if [ "$_sd_scr_way" != "$_sd_scr_log" ]; then
                case "$_sd_scr_way" in
                    kernel) sd_info charge "亮屏快充：已接管（内核 ignore_screen_state）" ;;
                    fcc)    sd_info charge "亮屏快充：已接管（回写 FCC，目标 $(cat "$SD_FCC_NORM" 2>/dev/null)mA）" ;;
                esac
                _sd_scr_log=$_sd_scr_way
            fi ;;
        2)
            if [ "$_sd_scr_log" != "wait" ]; then
                sd_info charge "亮屏快充：还没有基准值，先息屏充一次再亮屏"
                _sd_scr_log=wait
            fi ;;
        3)
            sd_scr_active && sd_scr_release
            if [ "$_sd_scr_log" != "hot" ]; then
                sd_info charge "亮屏快充：电池偏热，本轮不接管"
                _sd_scr_log=hot
            fi ;;
        *)
            sd_scr_active && sd_scr_release
            if [ "$_sd_scr_log" != "fail" ]; then
                sd_warn charge "亮屏快充：本机不支持（无屏幕状态参数，FCC 也写不进去）"
                _sd_scr_log=fail
            fi
            printf '1\n' >"$SD_SCR_FAIL" 2>/dev/null ;;
    esac
    return 0
}


_sd_curr_nodes=""

SD_CURR_ORIG="$SD_RUN/curr.orig"
SD_CURR_MARK="$SD_RUN/curr.want"

_sd_curr_unit() {
    local p="$1" cur="${2:-}"
    case "$cur" in
        ''|*[!0-9]*) ;;
        *) [ "$cur" -gt 100000 ] && { _sd_unit=ua; return 0; } ;;
    esac
    case "$p" in
        */oplus_chg/*|*/input_current_limit|*/charger/current_max) _sd_unit=ma ;;
        *) _sd_unit=ua ;;
    esac
}

_sd_curr_save_orig() {
    local p="$1" v="$2"
    [ -f "$SD_CURR_ORIG" ] || : >"$SD_CURR_ORIG" 2>/dev/null || return 0
    awk -F'|' -v p="$p" '$1==p{f=1} END{exit !f}' "$SD_CURR_ORIG" 2>/dev/null && return 0
    printf '%s|%s\n' "$p" "$v" >>"$SD_CURR_ORIG" 2>/dev/null
}

sd_curr_restore() {
    local p o n=0
    if [ -f "$SD_CURR_ORIG" ]; then
        while IFS='|' read -r p o; do
            [ -n "$p" ] && [ -e "$p" ] || continue
            printf '%s\n' "$o" >"$p" 2>/dev/null && n=$((n + 1))
        done <"$SD_CURR_ORIG"
        rm -f "$SD_CURR_ORIG" 2>/dev/null
    fi
    rm -f "$SD_CURR_MARK" 2>/dev/null
    [ "$n" -gt 0 ] && sd_info charge "限流已关闭，还原 $n 个节点"
    return 0
}

_sd_curr_prepare() {
    [ -n "$_sd_curr_nodes" ] && return 0
    if [ -n "${SD_CURR_NODES:-}" ]; then
        _sd_curr_nodes=$(printf '%s' "$SD_CURR_NODES" | tr ',' ' ')
    else
        _sd_curr_nodes="$SD_PS/battery/constant_charge_current_max \
$SD_PS/battery/constant_charge_current \
$SD_PS/battery/current_max \
$SD_PS/main/constant_charge_current_max \
$SD_PS/bms/current_max \
$SD_PS/usb/current_max \
$SD_OPLUS_CHG/chg_current_max \
$SD_OPLUS_CHG/current_max \
/sys/devices/virtual/oplus_chg/battery/chg_current_max \
/sys/devices/virtual/oplus_chg/battery/current_max"
        sd_plat_resolve
        if [ "$_sd_plat" = mtk ]; then
            _sd_curr_nodes="$SD_PS/battery/input_current_limit \
$SD_PS/charger/current_max \
$SD_PS/mtk-master-charger/current_max \
$SD_PS/mtk-slave-charger/current_max \
$SD_PS/mtk-battery/current_max \
$_sd_curr_nodes"
        fi
    fi
    return 0
}

sd_curr_apply() {
    local want="$1" n cur v n_ok=0
    case "$want" in ''|*[!0-9]*) return 1 ;; esac
    [ "$want" -gt 0 ] || { sd_curr_restore; return 0; }
    _sd_curr_prepare
    for n in $_sd_curr_nodes; do
        [ -e "$n" ] || continue
        sd_read1 "$n" || continue
        cur=$_sd_rv
        case "$cur" in ''|*[!0-9]*) continue ;; esac
        _sd_curr_unit "$n" "$cur"
        if [ "$_sd_unit" = ua ]; then v=$((want * 1000)); else v=$want; fi
        [ "$cur" -eq "$v" ] && { n_ok=$((n_ok + 1)); continue; }
        _sd_curr_save_orig "$n" "$cur"
        printf '%s\n' "$v" >"$n" 2>/dev/null && n_ok=$((n_ok + 1))
    done
    [ "$n_ok" -gt 0 ] && printf '%s\n' "$want" >"$SD_CURR_MARK" 2>/dev/null
    [ "$n_ok" -gt 0 ]
}

sd_curr_keep() {
    local want cur v n n_ok=0 last=""
    sd_curr_target_v
    want=$_sd_rv

    if [ "$want" -eq 0 ]; then
        if [ -f "$SD_CURR_ORIG" ]; then
            sd_curr_restore
        elif [ -f "$SD_CURR_MARK" ]; then
            rm -f "$SD_CURR_MARK" 2>/dev/null
        fi
        return 0
    fi

    read -r last 2>/dev/null <"$SD_CURR_MARK"
    case "$last" in ''|*[!0-9]*) last="" ;; esac

    _sd_curr_prepare
    for n in $_sd_curr_nodes; do
        [ -e "$n" ] || continue
        sd_read1 "$n" || continue
        cur=$_sd_rv
        case "$cur" in ''|*[!0-9]*) continue ;; esac
        _sd_curr_unit "$n" "$cur"
        if [ "$_sd_unit" = ua ]; then v=$((want * 1000)); else v=$want; fi
        if [ "$want" != "$last" ] || [ "$cur" -gt $((v * 11 / 10)) ]; then
            [ "$cur" -eq "$v" ] && continue
            _sd_curr_save_orig "$n" "$cur"
            printf '%s\n' "$v" >"$n" 2>/dev/null && n_ok=$((n_ok + 1))
        fi
    done
    [ "$want" != "$last" ] && printf '%s\n' "$want" >"$SD_CURR_MARK" 2>/dev/null
    [ "$n_ok" -gt 0 ] && sd_info charge "电流墙 → ${want}mA（$n_ok 节点）"
    return 0
}

sd_charge_tick() {
    local cap=0 fast_cap

    sd_batt_status_v
    case "$_sd_rv" in
        Charging|Full) ;;
        *)
            sd_shell_emul 0
            _sd_last_cur=""
            _sd_last_out=0
            _sd_last_lim=""
            _sd_last_zone=""
            return 0 ;;
    esac

    cap=""
    sd_ps_attr_v capacity && cap=$_sd_rv
    case "$cap" in ''|*[!0-9]*) cap=0 ;; esac
    _sd_clamp "${_st_fast_cap:-55}" 20 90 55
    fast_cap=$_sd_rv

    if [ "$cap" -lt "$fast_cap" ]; then
        sd_shell_target >/dev/null
        sd_shell_emul "$_sd_last_out"
    else
        sd_shell_emul 0
    fi
}

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

_sd_hz_list() {
    local f="$SD_RUN/hz.list" v
    if [ -s "$f" ]; then cat "$f"; return 0; fi
    v=$(sd_hz_supported 2>/dev/null | tr '\n' ' ')
    v=${v% }
    [ -n "$v" ] && printf '%s' "$v" >"$f" 2>/dev/null
    printf '%s' "$v"
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

sd_hz_want() {
    local v
    v=$(sd_state_get hz off)
    case "$v" in ''|off|*[!0-9]*) return 1 ;; esac
    printf '%s' "$v"
}

sd_hz_hard() { [ "$(sd_state_get hz_hard 0)" = "1" ]; }

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

sd_hz_lowpower() {
    local v
    v=$(settings get global low_power 2>/dev/null | tr -d '\r')
    [ "$v" = "1" ] && { echo 1; return 0; }
    echo 0
}

sd_hz_mcfr_on() {
    if [ -z "$(sd_state_get hz_prev_mcfr "")" ]; then
        local pv
        pv=$(settings get secure "$SD_MCFR_KEY" 2>/dev/null | tr -d '\r')
        case "$pv" in ''|null) pv=none ;; esac
        sd_state_set hz_prev_mcfr "$pv"
    fi
    settings put secure "$SD_MCFR_KEY" 1 2>/dev/null
    command -v cmd >/dev/null 2>&1 && \
        cmd display set-match-content-frame-rate-policy 1 >/dev/null 2>&1
    return 0
}

sd_hz_mcfr_off() {
    local prev
    prev=$(sd_state_get hz_prev_mcfr "")
    case "$prev" in
        none|'')
                  settings delete secure "$SD_MCFR_KEY" 2>/dev/null
                  command -v cmd >/dev/null 2>&1 && \
                      cmd display set-match-content-frame-rate-policy 2 >/dev/null 2>&1 ;;
        1|2|3)    settings put secure "$SD_MCFR_KEY" "$prev" 2>/dev/null
                  command -v cmd >/dev/null 2>&1 && \
                      cmd display set-match-content-frame-rate-policy "$prev" >/dev/null 2>&1 ;;
        *)        settings put secure "$SD_MCFR_KEY" 2 2>/dev/null
                  command -v cmd >/dev/null 2>&1 && \
                      cmd display set-match-content-frame-rate-policy 2 >/dev/null 2>&1 ;;
    esac
    sd_state_set hz_prev_mcfr ""
    return 0
}

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
    case "$v" in ''|*[!0-9]*) echo "刷新率需为 60~185 的整数或 off"; return 1 ;; esac
    [ "$v" -ge 60 ] && [ "$v" -le 185 ] || { echo "刷新率需为 60~185 的整数或 off"; return 1; }
    command -v settings >/dev/null 2>&1 || { echo "没有 settings 命令，当前环境无法改刷新率"; return 1; }

    sup=$(sd_hz_supported)
    if [ -n "$sup" ] && ! printf '%s\n' "$sup" | grep -qx "$v"; then
        echo "本机未报告 ${v}Hz 模式（支持: $(printf '%s' "$sup" | tr '\n' ' ')Hz）"
        return 1
    fi

    if [ "$(sd_state_get hz off)" = "off" ]; then
        sd_state_set hz_prev_peak "$(settings get system peak_refresh_rate 2>/dev/null | tr -d '\r')"
        sd_state_set hz_prev_min  "$(settings get system min_refresh_rate 2>/dev/null | tr -d '\r')"
        sd_state_set hz_prev_mcfr ""
    fi

    prev_hard=$(sd_state_get hz_hard 0)
    case "$force" in soft) sd_state_set hz_hard 0 ;; hard) sd_state_set hz_hard 1 ;; esac

    sd_hz_write "$v"
    if sd_hz_hard; then
        sd_hz_mcfr_on
    else
        sd_hz_mcfr_relax
    fi

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

_hz_bad=0
_hz_reason=""
sd_hz_guard() {
    local v peak min
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

sd_bcc_parse() {
    local raw oifs
    _sd_cell_ok=0
    _sd_cell_v0=0
    _sd_cell_v1=0
    _sd_cell_ma=""
    _sd_cell_raw=""
    raw=""
    sd_read1 "$SD_OPLUS_CHG/bcc_parms" && raw=$_sd_rv
    _sd_cell_raw=$raw
    [ -n "$raw" ] || return 0
    oifs=$IFS
    IFS=,
    set -f
    set -- $raw
    set +f
    IFS=$oifs
    [ "$#" -eq 19 ] || return 0
    _sd_cell_v0=$7
    _sd_cell_ma=$9
    _sd_cell_v1=${12}
    case "$_sd_cell_v0" in ''|*[!0-9]*) _sd_cell_v0=0 ;; esac
    case "$_sd_cell_v1" in ''|*[!0-9]*) _sd_cell_v1=0 ;; esac
    case "$_sd_cell_ma" in ''|*[!0-9-]*) _sd_cell_ma="" ;; esac
    [ "$_sd_cell_v0" -gt 0 ] && [ -n "$_sd_cell_ma" ] && _sd_cell_ok=1
    return 0
}

sd_cells_count_v() {
    local v0="$1" v1="$2" d sum
    _sd_rv=1
    [ "$v0" -ge 2500 ] && [ "$v0" -le 5000 ] || return 0
    [ "$v1" -ge 2500 ] && [ "$v1" -le 5000 ] || return 0
    d=$((v0 - v1)); [ "$d" -lt 0 ] && d=$((-d))
    [ "$d" -le 500 ] || return 0
    sum=$((v0 + v1))
    [ "$sum" -ge 7000 ] && [ "$sum" -le 9600 ] || return 0
    _sd_rv=2
    return 0
}

sd_cells_resolve() {
    local v0="${1:-}" v1="${2:-}" raw rest n mode pv=""
    _sd_cell_src=default
    _sd_rv=1
    mode=$(sd_state_get cells_mode auto)
    case "$mode" in
        1) _sd_rv=1; _sd_cell_src=manual; return 0 ;;
        2) _sd_rv=2; _sd_cell_src=manual; return 0 ;;
    esac
    raw=""
    sd_read1 "$SD_OPLUS_CHG/aging_ffc_data" && raw=$_sd_rv
    if [ -n "$raw" ]; then
        rest=${raw#*,}
        n=${rest%%,*}
        case "$n" in
            1) _sd_rv=1; _sd_cell_src=aging; return 0 ;;
            2) _sd_rv=2; _sd_cell_src=aging; return 0 ;;
        esac
    fi
    if [ -n "$v0" ]; then
        sd_cells_count_v "$v0" "$v1"
        _sd_cell_src=bcc
        return 0
    fi
    pv=""
    sd_ps_attr_v voltage_now && pv=$_sd_rv
    case "$pv" in ''|*[!0-9]*) pv="" ;; esac
    if [ -n "$pv" ]; then
        [ "$pv" -ge 100000 ] && pv=$((pv / 1000))
        if [ "$pv" -ge 6000 ] && [ "$pv" -le 9600 ]; then
            _sd_rv=2; _sd_cell_src=volt; return 0
        fi
    fi
    _sd_rv=1
    return 0
}

sd_volt_pack() {
    local mv="${1:-}" n="${2:-2}" b=""
    _sd_vsrc=""
    case "$mv" in ''|*[!0-9]*) _sd_rv=""; return 0 ;; esac
    [ "$n" = 2 ] || { _sd_rv=$mv; _sd_vsrc=raw; return 0; }
    [ "$mv" -ge 6000 ] && { _sd_rv=$mv; _sd_vsrc=raw; return 0; }
    [ "$mv" -ge 2500 ] || { _sd_rv=$mv; _sd_vsrc=raw; return 0; }

    local p
    for p in "$SD_PS/bms/voltage_now" "$SD_PS/mtk-gauge/voltage_now"; do
        sd_read1 "$p" || continue
        b=$_sd_rv
        case "$b" in ''|*[!0-9]*) continue ;; esac
        [ "$b" -ge 100000 ] && b=$((b / 1000))
        if [ "$b" -ge 6000 ] && [ "$b" -le 9600 ]; then
            _sd_rv=$b; _sd_vsrc=bms; return 0
        fi
    done
    _sd_rv=$((mv * n)); _sd_vsrc=scale
    return 0
}

sd_power_json() {
    local c mv w st cap t ma src=ps cells=1 neg="" scale
    local v0 v1 bv pv

    st=""
    sd_ps_attr_v status && st=$_sd_rv
    cap=""
    sd_ps_attr_v capacity && cap=$_sd_rv
    t=""
    sd_batt_temp_v && t=$_sd_rv

    sd_bcc_parse
    if [ "$_sd_cell_ok" = 1 ]; then
        v0=$_sd_cell_v0
        v1=$_sd_cell_v1
        c=$_sd_cell_ma
        sd_cells_resolve "$v0" "$v1"
        cells=$_sd_rv
        if [ "$cells" = 2 ]; then
            if [ "$v1" -ge 2500 ] && [ "$v1" -le 5000 ]; then
                mv=$((v0 + v1))
            else
                mv=$((v0 * 2))
            fi
        else
            mv=$v0
        fi
        src=bcc
    else
        c=""
    fi

    if [ "$src" = ps ]; then
        local cv vv
        cv=""; vv=""
        sd_ps_attr_v current_now && cv=$_sd_rv
        sd_ps_attr_v voltage_now && vv=$_sd_rv
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

    if [ "$src" = ps ]; then
        sd_cells_resolve
        cells=$_sd_rv
        if [ -n "$mv" ]; then
            sd_volt_pack "$mv" "$cells"
            mv=$_sd_rv
        else
            for pv in "$SD_PS/bms/voltage_now" "$SD_PS/mtk-gauge/voltage_now"; do
                sd_read1 "$pv" || continue
                bv=$_sd_rv
                case "$bv" in ''|*[!0-9]*) continue ;; esac
                [ "$bv" -ge 100000 ] && bv=$((bv / 1000))
                [ "$bv" -ge 3000 ] && [ "$bv" -le 9600 ] && { mv=$bv; break; }
            done
        fi
    fi

    if [ -n "$c" ]; then
        case "$st" in
            Not\ charging|*Discharging*) [ "$c" -gt 0 ] && c=$((-c)) ;;
            *Charging*|Full)             [ "$c" -lt 0 ] && c=$((-c)) ;;
        esac
        scale=$(sd_state_int power_scale 100 50 200)
        [ "$scale" -ne 100 ] && c=$((c * scale / 100))
        ma=$c
    fi

    w=""
    if [ -n "$ma" ] && [ -n "$mv" ]; then
        w=$(awk -v a="$ma" -v b="$mv" 'BEGIN { printf "%.2f", (a < 0 ? -a : a) * b / 1000000 }')
    fi

    case "$t" in ''|*[!0-9]*) t="" ;; esac
    [ -n "$t" ] && { [ "$t" -ge 1 ] && [ "$t" -le 120 ] || t=""; }

    case "$cap" in ''|*[!0-9]*) cap="" ;; esac
    case "$st" in *\"*|*\\*) st="" ;; esac

    sd_plat_resolve
    sd_proto_resolve

    printf '{"ma":%s,"mv":%s,"w":%s,"status":"%s","cap":%s,"temp":%s,"cells":%s,"cells_src":"%s","src":"%s","plat":"%s","proto":"%s"}\n' \
        "${ma:-null}" "${mv:-null}" "${w:-null}" "${st:-Unknown}" "${cap:-null}" "${t:-null}" \
        "$cells" "${_sd_cell_src:-default}" "$src" "$_sd_plat" "$_sd_proto"
}

SD_DESC_LAST="$SD_RUN/desc.last"

sd_desc_text() {
    local mode gear hz n t
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

    n=0
    if { sd_nm_active || sd_mm_active; } && [ -s "$SD_NM_LIST" ]; then
        n=$(wc -l <"$SD_NM_LIST" 2>/dev/null | tr -d ' ')
    else
        n=$(sort -u "$SD_MOUNTS" 2>/dev/null | wc -l | tr -d ' ')
    fi
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -gt 0 ]; then
        t="$t · 配置 $n 项"
    else
        t="$t · 未生效"
    fi

    printf 'QC · %s' "$t"
}

sd_sync_desc() {
    [ -n "${MODDIR:-}" ] && [ -f "$MODDIR/module.prop" ] || return 0
    local d cur="" line tmp
    d=$(sd_desc_text)

    while IFS= read -r line; do
        case "$line" in
            description=*) cur=${line#description=}; break ;;
        esac
    done <"$MODDIR/module.prop" 2>/dev/null

    if [ "$cur" = "$d" ]; then
        printf '%s' "$d" >"$SD_DESC_LAST" 2>/dev/null
        return 0
    fi

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

_sd_diag_temp() {
    local z="$1"
    sd_read1 "$z/temp" || return 1
    sd_temp_norm "$_sd_rv" || return 1
    printf '%s' "$_sd_rv"
}

_sd_diag_zone_line() {
    local cls="$1" e z t v r out=""
    for e in $_sd_zones; do
        z=${e%%:*}; t=${e#*:}
        sd_zone_class "$t"
        [ "$_sd_zc" = "$cls" ] || continue
        v=$(_sd_diag_temp "$z") || continue
        if sd_spoof_file "$z"; then
            r=""
            read -r r 2>/dev/null <"$SD_RUN/$(basename "$z").real"
            case "$r" in ''|*[!0-9]*) out="$out ${t##*/}=${v}*" ;;
                         *) out="$out ${t##*/}=${v}(真实${r})*" ;; esac
        else
            out="$out ${t##*/}=${v}"
        fi
    done
    printf '%s' "${out# }"
}

sd_diag() {
    local dur="${1:-120}" iv="${2:-2}" i=0 t0 line f st bt ci cv cim cvm lim tgt pct
    case "$dur" in ''|*[!0-9]*) dur=120 ;; esac
    case "$iv"  in ''|*[!0-9]*) iv=2 ;; esac
    [ "$iv" -lt 1 ] && iv=1
    [ "$dur" -gt 1800 ] && dur=1800

    _sd_st_loaded=0
    sd_state_load
    sd_zone_scan

    if [ -d /sdcard/Download ] && [ -w /sdcard/Download ]; then
        f="/sdcard/Download/qc-diag-$(date '+%Y%m%d-%H%M%S').txt"
    else
        f="$SD_DATA/qc-diag-$(date '+%Y%m%d-%H%M%S').txt"
    fi

    {
        printf '# Quick Charge 诊断采样\n'
        printf '# 开始: %s  时长: %ss  间隔: %ss\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$dur" "$iv"
        printf '# 设备: %s\n' "$(getprop ro.product.model 2>/dev/null) $(getprop ro.build.display.id 2>/dev/null)"
        sd_plat_resolve
        printf '# 平台: %s  温度模式: %s  wall: %s  aggr: %s  curr_max: %s  core: %s  noncore: %s\n' \
            "$_sd_plat" "$(sd_state_get temp_mode off)" "$(sd_state_get wall off)" \
            "$(sd_state_int aggr 10 0 10)" "$(sd_state_int curr_max 0 0 8000)" \
            "$(sd_state_get core_temp off)" "$(sd_state_get noncore_temp off)"
        printf '# 带 * 的温区表示 temp 已被 bind mount 顶成固定值（系统读到的不是真实温度）\n'
    } | tee "$f" 2>/dev/null

    t0=$(date '+%s')
    while :; do
        i=$(( $(date '+%s') - t0 ))
        [ "$i" -ge "$dur" ] && break

        sd_batt_status_v; st=$_sd_rv
        bt=""; ci=""; cv=""
        sd_batt_temp_v && bt=$_sd_rv
        sd_ps_attr_v current_now && ci=$_sd_rv
        sd_ps_attr_v voltage_now && cv=$_sd_rv
        case "$ci" in ''|*[!0-9-]*) ci=0 ;; esac
        case "$cv" in ''|*[!0-9-]*) cv=0 ;; esac
        [ "${ci#-}" -gt 100000 ] 2>/dev/null && cim=$((ci / 1000)) || cim=$ci
        [ "$cv" -gt 100000 ] 2>/dev/null && cvm=$((cv / 1000)) || cvm=$cv
        lim=$(( (cim < 0 ? -cim : cim) * cvm / 1000000 ))

        sd_curr_target_v; tgt=$_sd_rv
        pct=${_sd_curr_pct:-100}

        line=$(printf '[%4ss] %-9s 电池 %3s℃  %5smA  %5smV  %4sW' \
            "$i" "${st:-?}" "${bt:--}" "$cim" "$cvm" "$lim")
        if [ "$tgt" -gt 0 ]; then
            line="$line  限流 目标${tgt}mA(${pct}%)"
        else
            line="$line  限流 不限"
        fi

        {
            printf '%s\n' "$line"
            printf '        core : %s\n' "$(_sd_diag_zone_line core)"
            printf '        board: %s\n' "$(_sd_diag_zone_line board)"
            printf '        shell: %s\n' "$(_sd_diag_zone_line shell)"
            printf '        其它 : %s\n' "$(_sd_diag_zone_line other)"
        } | tee -a "$f" 2>/dev/null

        sleep "$iv"
    done

    printf '\n采样结束，文件: %s\n' "$f"
    printf '判读要点:\n'
    printf '  1. 电池温度远低于墙、限流却已 <100%% → 档位触发点太靠前\n'
    printf '  2. 电流一次次掉到同一档再爬回 → 温度在阈值上来回跨档（缺回差）\n'
    printf '  3. core 全是固定值且充电时电流持续偏低 → 核心伪装让系统放开 CPU，真实功耗抢了充电功率\n'
    printf '  4. board 里 charger-therm 接近 80-85℃ 而电池才 35℃ → 降档来自充电 IC 自身保护，不是温度墙\n'
}
