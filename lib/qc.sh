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

# read 内建读到的是原样字节，节点若带 CR 需要去掉。
# 只在加载时展开一次，避免热路径里再 fork。
SD_CR=$(printf '\r')
SD_OLD="$SD_DATA/log.old.txt"
SD_MOUNTS="$SD_DATA/mounts.list"
SD_BACKUP="$SD_DATA/backup"
SD_RUN="$SD_DATA/run"
SD_SPOOF_DIR="${SD_SPOOF_DIR:-}"
SD_SPOOF_DEF="${SD_SPOOF_DEF:-/dev/qc}"
SD_SPOOF_FLAG="$SD_RUN/spoof.pending"
SD_PWR_HIST="$SD_RUN/power.hist"
SD_BUILT="$SD_DATA/built.id"
SD_PS="${SD_PS:-/sys/class/power_supply}"
SD_SHELL_TEMP="${SD_SHELL_TEMP:-/proc/shell-temp}"
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

_sd_lv=0
_sd_rot=0

# 日志分级（log_level）：
#   0 关闭（默认）：只有 E 落盘，其余一律不写
#   1 事件：启停、插拔、协议/屏幕切换、降流与回写，量小，适合长期开
#   2 详细：在事件基础上，每个状态变化记一条完整现场（一次定位用的就是这级）
#   3 逐轮：每轮 tick 的判定细节
#   4 调试：节点级 trace
_sd_emit() {
    local lv="$1" tag="$2" need plv
    shift 2
    plv=$lv
    case "$lv" in
        E) need=0 ;;               # 错误：关闭状态下也留一条
        W) need=1 ;;               # 告警：事件级起
        S) need=2; plv=I ;;        # 现场快照：详细级起，日志里仍显示为 I
        D) need=3 ;;               # 逐轮细节：调试级
        *) need=1 ;;               # I：事件
    esac
    [ "$_sd_lv" -ge "$need" ] || return 0
    printf '%s %s [%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$plv" "$tag" "$*" 2>/dev/null >>"$SD_LOG"
    [ -n "${SD_VERBOSE:-}" ] && printf '%s [%s] %s\n' "$plv" "$tag" "$*"

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

# 切换日志级别。开启时先写会话头 + 环境 + 当前现场，
# 复现完直接导出就是一份能定位的日志，不用再等下一次变化。
sd_set_log() {
    local v="$1"
    case "$v" in 0|1|2|3|4) ;; *) printf '级别需为 0~4\n'; return 1 ;; esac
    if [ "$v" = 0 ]; then
        sd_info log "日志关闭（级别 0）"
        sd_state_set log_level 0
        _sd_lv=0
        return 0
    fi
    sd_state_set log_level "$v"
    _sd_lv=$v
    sd_session log "日志开启 level=$v"
    sd_dump_env
    # C 守护下一拍就会打首帧，shell 再打一条只会在同一秒里重复一遍
    if [ "$v" -ge 2 ] && ! sd_daemon_is_c; then
        sd_chg_snapshot 1
    fi
    return 0
}

sd_session() {
    [ "${_sd_lv:-0}" -ge 1 ] || return 0
    local tag="$1"
    shift
    printf '\n======== %s | %s | pid=%s ========\n' \
        "$(date '+%m-%d %H:%M:%S')" "$tag" "$$" 2>/dev/null >>"$SD_LOG"
    [ "$#" -gt 0 ] && printf '  %s\n' "$*" 2>/dev/null >>"$SD_LOG"
    return 0
}

sd_dump_env() {
    local dev rom kver zones emul sentinel stype stemp slim _e _sh _emul_n _emul_head
    dev="$(getprop ro.product.odm.manufacturer 2>/dev/null) $(getprop ro.product.model 2>/dev/null)"
    dev=$(printf '%s' "$dev" | sed 's/^ *//; s/ *$//')
    rom=$(getprop ro.build.display.id 2>/dev/null)
    kver=$(uname -r 2>/dev/null)
    [ "$_sd_st_loaded" = 1 ] || sd_state_load
    sd_zone_scan

    zones=0
    emul=""
    _emul_n=0
    for _e in $_sd_zones; do
        zones=$((zones + 1))
        [ -e "${_e%%:*}/emul_temp" ] || continue
        _emul_n=$((_emul_n + 1))
        [ "$_emul_n" -le 3 ] && emul="$emul $(basename "${_e%%:*}")"
    done
    # 80 个温区名铺一行会把日志冲成几百字符，只留数量和前三个
    _emul_head=""
    [ "$_emul_n" -gt 3 ] && _emul_head="（${emul# } …）"
    [ -e "$SD_SHELL_TEMP" ] && _sh=yes || _sh=no

    sentinel=""
    if sd_pick_sentinel_v; then
        sentinel=$_sd_rv
        stype=$_sd_sent_type
        sd_sentinel_temp_v "$sentinel" && stemp=$_sd_rv
        sd_limit_for_type_v "$stype"; slim=$_sd_rv
    fi

    _sd_emit I env "device=${dev:-?} rom=${rom:-?} kernel=${kver:-?}"
    local mv cv
    mv=$(sd_prop_get version)
    cv=""
    sd_use_c && cv=$("$MODDIR/bin/qcmon" -v 2>/dev/null | head -1)
    _sd_emit I env "module=${mv:-?} channel=$(sd_channel) daemon=${cv:-shell}"
    sd_plat_resolve
    # 「存在/候选」两个数一起给：只写一个数时，启动早期那个 0 会被读成
    # 「这台机器没有电流节点」，3.1.12 的根因报告就是这么误判的。
    local cn ce
    ce=$(printf '%s' "$_sd_curr_nodes" | wc -w | tr -d ' ')
    cn=$(sd_curr_nodes 2>/dev/null | wc -l | tr -d ' ')
    [ "$ce" -gt 0 ] 2>/dev/null || ce=0
    _sd_emit I env "soc=${_sd_plat}（${_sd_plat_why}） emul=$_emul_n${_emul_head} shell-temp=$_sh charge-nodes=${cn}/${ce}（存在/候选）"
    _sd_curr_ex=$cn
    if [ -n "$sentinel" ]; then
        _sd_emit I env "sentinel=$(basename "$sentinel") type=${stype:-?} temp=${stemp:-?}℃"
    else
        _sd_emit I env "sentinel=none（未找到电池/主板温度节点，伪装无法工作）"
    fi
    _sd_emit I env "state=$(sd_state_dump)"

    # 下面三行是「一次定位」的关键：协议、屏幕、FCC 三处判定的原始输入。
    # 没有它们，日志里只能看到结论（公有快充 / scr=0 / 写不进去），看不出为什么。
    local et ert ev ec
    sd_read1 "$SD_PS/usb/type" && et=$_sd_rv
    sd_read1 "$SD_PS/usb/real_type" && ert=$_sd_rv
    sd_read1 "$SD_OPLUS_CHG/voocchg_ing" && ev=$_sd_rv
    sd_read1 "$SD_OPLUS_CHG/charge_technology" && ec=$_sd_rv
    _sd_emit I env "usb type=${et:-?} real_type=${ert:-?} voocchg_ing=${ev:-?} tech=${ec:-?}"

    sd_screen_nodes
    _sd_emit I env "screen bl=${SD_BL} 节点=$(printf '%s' "$_sd_bl_nodes" | wc -w | tr -d ' ') fb=${SD_FB}"
    if sd_scr_fcc_node; then
        _sd_emit I env "fcc 节点=${_sd_sf} 目标=$(cat "$SD_FCC_NORM" 2>/dev/null || printf '未学')"
    else
        _sd_emit I env "fcc 节点=none（只有输入侧节点 usb/current_max 之类，写它会打断 PD/VOOC 协商，不接管）"
    fi
    return 0
}

sd_check() {
    local n=0 ok=0 emul="" sh="" cfg=0 cur="" cells=1 why="" grade="" note=""
    local temp_ok=0 sname="" e z t pt pr ncur=0

    printf '== Quick Charge 适配检查 ==\n'
    printf '模块: v%s · %s / Android %s\n' \
        "$(sd_prop_get version)" \
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
    [ -e "$SD_SHELL_TEMP" ] && sh=yes

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
        printf '[ok] 温度改写 %s\n' "$SD_SHELL_TEMP"
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
    printf '[ok] 平台     %s · %s\n' "$pt" "$_sd_plat_why"
    case "$_sd_proto" in
        unknown|none) printf '[--] 协议     %s（%s）\n' "$pr" "$_sd_proto_why" ;;
        *)            printf '[ok] 协议     %s（%s）\n' "$pr" "$_sd_proto_why" ;;
    esac
    if [ -d "$SD_VOTABLE" ]; then
        printf '[ok] 投票     %s 存在 · 仅 UFCS/PPS 有效，本模块不写入\n' "$SD_VOTABLE"
    else
        printf '[--] 投票     %s 不存在 · 私有协议下本来也不适用\n' "$SD_VOTABLE"
    fi

    if [ "$ok" -eq 0 ]; then
        grade=D; note="温区读不到，伪装没有依据"
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
            printf '建议: MTK + 私有快充由内核 charger-manager 独立限温；模块不设温度墙，热量交给系统与硬件保护\n' ;;
        mtk:*)
            printf '建议: MTK 温度编码与命名都已归一；unlock 不生效时先确认 constant_charge_current_max\n' ;;
    esac
    return 0
}

sd_probe() {
    local z t v n=0 ok=0 p line pid s up r lim zn out md em a why zv pd
    printf '== Quick Charge probe ==\n'
    printf '模块: %s  %s\n' "$MODDIR" "v$(sd_prop_get version)"
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
_st_curve_offset=""
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
    _st_curve_offset=""
    _st_log_level=""; _st_tick=""; _st_defrev=""
    _st_hz=""; _st_hz_prev_peak=""; _st_hz_prev_min=""; _st_hz_hard=""; _st_hz_prev_mcfr=""; _st_power_scale=""
    _st_cells_mode=""; _st_batt_spoof=""
    [ -f "$SD_STATE" ] || { _st_log_level=1; _sd_lv=1; return 0; }
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            ''|*[!a-z_]*) continue ;;
            log_level) _st_log_level=$v ;;
            *) eval "_st_$k=\$v" ;;
        esac
    done 2>/dev/null <"$SD_STATE"
    case "$_st_log_level" in 0|1|2|3|4) _sd_lv=$_st_log_level ;; *) _st_log_level=1; _sd_lv=1 ;; esac
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
        curve_offset)   printf '%s' "${_st_curve_offset:-${2:-120}}" ;;
        defrev)         printf '%s' "${_st_defrev:-${2:-2}}" ;;
        log_level)      printf '%s' "${_st_log_level:-${2:-1}}" ;;
        tick)           printf '%s' "${_st_tick:-${2:-15}}" ;;
        hz)             printf '%s' "${_st_hz:-${2:-off}}" ;;
        hz_prev_peak)   printf '%s' "${_st_hz_prev_peak:-${2:-}}" ;;
        hz_prev_min)    printf '%s' "${_st_hz_prev_min:-${2:-}}" ;;
        hz_hard)        printf '%s' "${_st_hz_hard:-${2:-0}}" ;;
        hz_prev_mcfr)   printf '%s' "${_st_hz_prev_mcfr:-${2:-}}" ;;
        power_scale)    printf '%s' "${_st_power_scale:-${2:-100}}" ;;
        cells_mode)     printf '%s' "${_st_cells_mode:-${2:-auto}}" ;;
        batt_spoof)     printf '%s' "${_st_batt_spoof:-${2:-off}}" ;;
        chg_unlock)     printf '%s' "${_st_chg_unlock:-${2:-0}}" ;;
        shell_temp_manual) printf '%s' "${_st_shell_temp_manual:-${2:-0}}" ;;
        overrides_off)  printf '%s' "${_st_overrides_off:-${2:-0}}" ;;
        overrides_manual) printf '%s' "${_st_overrides_manual:-${2:-0}}" ;;
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
    rm -f "$SD_RUN/daemon.pid" "$SD_RUN/hb" "$SD_RUN/sensor" "$SD_PWR_HIST" 2>/dev/null
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
    sd_boot_ts 2>/dev/null >"$SD_DATA/.boot_id"
    return 0
}

# 本次开机的 post-fs-data 跑过没有。开机时刻由 uptime 反推，同一轮里稳定，
# 两次算出来只会差 1s 以内；连续两次开机不可能只隔 15s，所以直接比时间戳。
sd_boot_seen() {
    local cur old d
    cur=$(sd_boot_ts)
    case "$cur" in ''|*[!0-9]*) return 0 ;; esac
    [ "$cur" -gt 0 ] || return 0
    # 用 cat 而不是 <file：文件不在时重定向本身就会往 stderr 甩一行
    # "cannot open"，2>/dev/null 压不住（它在重定向之后才生效）
    old=$(cat "$SD_DATA/.boot_id" 2>/dev/null | tr -d '\r\n')
    case "$old" in ''|*[!0-9]*) return 1 ;; esac
    d=$((cur - old))
    [ "$d" -lt 0 ] && d=$((-d))
    [ "$d" -le 15 ]
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
    local v=""
    [ -e "$1" ] || return 1
    # 热路径：read 是 shell 内建，不像 $(tr ...) 那样每次 fork 一个进程。
    # 每轮要读几十个节点，这一处省掉的 fork 占守护总开销的八成以上。
    IFS= read -r v <"$1" 2>/dev/null || :
    v=${v%"$SD_CR"}
    # 极少数节点没有换行结尾，read 会返回非 0 但仍赋值，所以按内容判断；
    # 真读到空内容时再用 tr 兜底（不常见，且只在异常节点上发生）。
    if [ -z "$v" ] && [ -s "$1" ]; then
        v=$(tr -d ' \t\r\n' <"$1" 2>/dev/null) || return 1
    fi
    # 去两端空白，纯参数展开，不 fork
    while :; do case "$v" in " "*|"	"*) v=${v#?} ;; *) break ;; esac; done
    while :; do case "$v" in *" "|*"	") v=${v%?} ;; *) break ;; esac; done
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

_sd_plat=""
_sd_plat_why=""

sd_plat_resolve() {
    # 认出 mtk/qcom 就定死；other 多半是启动早期 getprop 还没就绪，不缓存。
    # 3.1.12 及以前 `[ -n "$_sd_plat" ]` 把 other 也定死，于是 MTK 那 5 个候选
    # 节点永远拿不到 —— 这才是真正的"缓存了坏结果"。试满 8 次还是 other 才认命。
    case "$_sd_plat" in mtk|qcom) return 0 ;; esac
    [ "${_sd_plat_try:-0}" -ge 8 ] && return 0
    _sd_plat_try=$(( ${_sd_plat_try:-0} + 1 ))
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

# 适配器在不在位。usb/voltage_max、current_max 报的是「端口能力上限」，
# 拔线后仍常驻 5V/500mA（标准 SDP 的值），拿它判协议会把没插电显示成 PD。
# 有 online/present 就照它；没有就看实测输入，再退到电池状态。
sd_usb_present() {
    local o="" v="" i="" st=""
    sd_read1 "$SD_PS/usb/online" && o=$_sd_rv
    [ -n "$o" ] || { sd_read1 "$SD_PS/usb/present" && o=$_sd_rv; }
    case "$o" in
        1|Y|y|yes|true)  return 0 ;;
        0|N|n|no|false) return 1 ;;
    esac
    v=""; sd_read1 "$SD_PS/usb/voltage_now" && v=$_sd_rv
    [ -n "$v" ] && sd_uv_norm "$v" && v=$_sd_rv
    i=""; sd_chg_input_v && i=$_sd_rv
    case "$i" in -*) i=${i#-} ;; esac
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    case "$i" in ''|*[!0-9]*) i=0 ;; esac
    [ "$v" -ge 4000000 ] && [ "$i" -ge 100000 ] && return 0
    st=""; sd_batt_status_v && st=$_sd_rv
    case "$st" in *Charging*|*Full*) return 0 ;; esac
    return 1
}

sd_proto_resolve() {
    [ -n "$_sd_proto" ] && return 0
    local t="" v="" c="" p tech="" vooc="" why=""

    # 0) 没插适配器就没有协议可言
    if ! sd_usb_present; then
        _sd_proto=none; _sd_proto_why="未接适配器"; return 0
    fi

    # 1) 欧加的 charge_technology 是驱动自己维护的档位：1~13 私有，14 起公有。
    #    usb/type 在私有协议在线时也可能写 USB_PD（充电器先 PD 握手再切 VOOC），
    #    以前先看 type 串，一个 USB_PD 就把 30W VOOC 判成 PD，永远回不来。
    sd_read1 "$SD_OPLUS_CHG/charge_technology" && tech=$_sd_rv
    sd_read1 "$SD_OPLUS_CHG/voocchg_ing" && vooc=$_sd_rv
    case "$tech" in
        ''|*[!0-9]*) ;;
        *)
            if [ -e "$SD_OPLUS_CHG/charge_technology" ] &&
               [ "$tech" -ge 1 ] && [ "$tech" -le 13 ]; then
                _sd_proto=vooc
                _sd_proto_why="tech=$tech"
                return 0
            fi ;;
    esac

    # 2) 类型串里的私有协议字样同样是硬证据，能压过 tech=14（降档时 type 还留着旧值）。
    #    三个节点全部读出来一起匹配：real_type 常是 Unknown，只取第一个会把 type 丢掉。
    for p in "$SD_PS/usb/real_type" "$SD_PS/usb/type" "$SD_PS/battery/charge_type"; do
        [ -e "$p" ] || continue
        sd_read1 "$p" || continue
        [ -n "$_sd_rv" ] || continue
        t="$t $_sd_rv"
        why="$why ${p##*/}=$_sd_rv"
    done
    why=${why# }
    case "$t" in
        *VOOC*|*vooc*|*SVOOC*|*SuperDart*|*DART*|*Flash*|*SUPERVOOC*)
            _sd_proto=vooc; _sd_proto_why=${why:-type}; return 0 ;;
    esac

    # 3) 驱动自己置的「正在 VOOC 充电」
    case "$vooc" in
        1) _sd_proto=vooc; _sd_proto_why="voocchg_ing=1"; return 0 ;;
    esac

    # 4) 公有协议字样
    case "$t" in
        *PPS*|*pps*)
            _sd_proto=pps; _sd_proto_why=${why:-type}; return 0 ;;
        *UFCS*|*ufcs*)
            _sd_proto=ufcs; _sd_proto_why=${why:-type}; return 0 ;;
    esac

    # 5) 到这一步 tech 只剩 ≥14：私有档已退，按公有档记
    case "$tech" in
        ''|*[!0-9]*) ;;
        *)
            if [ -e "$SD_OPLUS_CHG/charge_technology" ] && [ "$tech" -ge 14 ]; then
                _sd_proto=pd
                _sd_proto_why="tech=$tech（私有档已退）"
                return 0
            fi ;;
    esac

    # 6) 最后才信类型串里的 PD
    case "$t" in
        *PD*|*pd*)
            _sd_proto=pd; _sd_proto_why=${why:-type}; return 0 ;;
    esac

    v=""; sd_read1 "$SD_PS/usb/voltage_max" && v=$_sd_rv
    c=""; sd_read1 "$SD_PS/usb/current_max" && c=$_sd_rv
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    if [ "$v" -ge 8000000 ] && [ "$c" -ge 5000000 ]; then
        _sd_proto=vooc
        _sd_proto_why="协商 $((v / 1000000))V/$((c / 1000))mA"
    elif [ "$v" -gt 5000000 ]; then
        # 升压了说明确实在协商，但没有 VOOC/PPS/UFCS/PD 字样、也没有 tech 证据。
        # 9V/2A 既可能是 PD 固定档，也可能是 VOOC 掉档——不能断言是 PD。
        _sd_proto=unknown
        _sd_proto_why="协商 $((v / 1000000))V/$((c / 1000))mA，无协议字样"
    else
        _sd_proto=unknown
        _sd_proto_why="普通 USB 口（$((v / 1000000))V/$((c / 1000))mA）"
    fi
    return 0
}

sd_proto_text() {
    sd_proto_resolve
    case "$_sd_proto" in
        none)    printf '未接适配器' ;;
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
    elif sd_batt_temp_v; then
        _sd_rr_zone="battery(ps)"
        _sd_rr_real=$_sd_rv
        _sd_rr_src="live"
        return 0
    elif sd_pick_sentinel_v; then
        z=$_sd_rv
        _sd_rr_zone=${z##*/}
        sd_sentinel_temp_v "$z" && v=$_sd_rv
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

# 电池类温区优先级：0 = 电芯本体，1 = 其它 batt*，2 = 连接器/充电侧。
# 一加/OPPO 上 batt-therm 挂在电池连接器旁，比电芯 NTC 高 8~12℃，
# 直接当电池用会让 real 虚高、壳温目标算高，还容易顶到系统温度墙。
sd_batt_rank() {
    case "$1" in
        battery|batt|BATTERY|BATT) printf '0' ;;
        *therm*|*Therm*|*conn*|*Conn*|*chg*|*Chg*) printf '2' ;;
        *) printf '1' ;;
    esac
}

sd_pick_batt_zone_v() {
    local e z t r best="" bestr=9
    _sd_zones_ready
    for e in $_sd_zones; do
        z=${e%%:*}
        t=${e#*:}
        sd_zone_class "$t"
        [ "$_sd_zc" = battery ] || continue
        sd_zone_is_hot_load "$t" && continue
        _sd_temp_readable "$z" || continue
        r=$(sd_batt_rank "$t")
        if [ "$r" -lt "$bestr" ]; then
            bestr=$r; best=$z; _sd_sent_type=$t
            [ "$r" = 0 ] && break
        fi
    done
    [ -n "$best" ] || return 1
    _sd_rv=$best
    return 0
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

sd_shell_target() {
    local v
    _sd_last_cur=""
    _sd_last_out=0
    _sd_last_base=""
    _sd_last_barrier=""
    _sd_base_clamped=0
    _sd_last_lim=""
    _sd_last_zone=""
    _sd_wall_hold=0
    [ "$_sd_st_loaded" = 1 ] || sd_state_load

    # 极速模式：恒定写同一个伪装温度。不看真实读数、不设温度墙、
    # 不按电量退出——插着电就一直让系统以为电池很凉。
    # 下限 20℃：再低不少平台会把 NTC 判成开路，反而锁 5V/500mA。
    v=${_st_shell_temp:-30}
    case "$v" in ''|*[!0-9]*) v=30 ;; esac
    [ "$v" -lt 20 ] && v=20
    [ "$v" -gt 33 ] && v=33
    _sd_last_out=$v
    _sd_last_base=$v
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
        sd_err thermal "电池伪装只能设 20-45℃（超出范围拒绝写入）: $celsius"
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

    # /proc/shell-temp 是欧加自定义 proc 接口，没有 emul_temp 那种「写 0 = 关闭
    # 模拟」的语义：写 0 会被读成 0℃，插电头几秒进低温保护（锁 5V/500mA）。
    # 但也不能像 3.1.4 那样在关闭时写死 30℃ —— 那会让这个节点永久停在假值，
    # 和「关闭」的语义相反。关闭时干脆不写，把它交还驱动自己更新。
    if [ "$celsius" -ne 0 ] && [ -e "$SD_SHELL_TEMP" ]; then
        t=0
        while [ "$t" -le 9 ]; do
            printf '%s %s\n' "$t" "$ms" 2>/dev/null >"$SD_SHELL_TEMP" && ps=1
            t=$((t + 1))
        done
    fi

    if [ "$celsius" -eq 0 ]; then
        _sd_emul_ok=1
        sd_dbg thermal "关闭壳温模拟：emul_temp 归零，shell-temp 交还驱动"
    elif [ "$n" -gt 0 ] || [ "$ps" = 1 ]; then
        _sd_emul_ok=1
        sd_dbg thermal "壳温写 ${celsius}℃ 到 $n 个节点"
    else
        _sd_emul_ok=0
        sd_warn thermal "壳温节点不可写（无 emul_temp 或权限被拒），目标 ${celsius}℃"
    fi
    return 0
}

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
    local want
    want=$(sd_state_get batt_spoof off)
    case "$want" in
        ''|off|0)
            [ "${_sd_batt_sp_on:-0}" = 1 ] && sd_spoof_batt_off
            return 0 ;;
        *[!0-9]*) return 0 ;;
    esac
    [ "$want" -ge 20 ] && [ "$want" -le 45 ] || { sd_spoof_batt_off; return 1; }
    [ "${_st_temp_mode:-}" = off ] && { sd_spoof_batt_off; return 0; }

    # 不看真实温度：开着就一直伪装，满速优先。
    [ "$want" = "$_sd_batt_sp_last" ] && [ "${_sd_batt_sp_on:-0}" = 1 ] && return 0
    if sd_spoof_apply batt "$want" >/dev/null 2>&1; then
        _sd_batt_sp_last=$want
        _sd_batt_sp_on=1
    fi
    return 0
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

# /my_stock 与 /my_product 是 ColorOS 14+ 新起的配置分区，OPPO 把一半温控表
# 挪到了这里。以前只扫 vendor/odm，这些表从未被改写，高温保护照旧生效。
SD_CFG_DIRS="/vendor/etc /odm/etc /my_stock/etc /my_product/etc /system/vendor/etc /system/system_ext/etc /vendor/qti/etc"

sd_count_tags() { grep -o '<[/]*[A-Za-z_]' "$1" 2>/dev/null | wc -l | tr -d ' '; }

sd_xml_balanced() {
    local o c
    o=$(grep -o '<[A-Za-z_][^<>]*>' "$1" 2>/dev/null | grep -vcE '/[[:space:]]*>$')
    c=$(grep -o '</[A-Za-z_][^<>]*>' "$1" 2>/dev/null | wc -l | tr -d ' ')
    case "$o" in ''|*[!0-9]*) o=0 ;; esac
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    [ "$o" = "$c" ]
}

# 不少 ROM 的温控 XML 带 UTF-8 BOM（EF BB BF），head -c 1 取到的是 0xEF。
# 旧实现据此判定"非 XML"并整份丢弃，日志里表现为"校验失败(非 XML)"，
# 结果 sys_thermal_control_config.xml 从未被覆盖。这里跳过 BOM 再看首字节。
sd_xml_lead_ok() {
    local c
    c=$(head -c 1 "$1" 2>/dev/null)
    [ "$c" = "<" ] && return 0
    if command -v od >/dev/null 2>&1; then
        [ "$(head -c 3 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')" = "efbbbf" ] || return 1
    fi
    [ "$(tail -c +4 "$1" 2>/dev/null | head -c 1)" = "<" ]
}

# 取参考文件的 SELinux 上下文。先取文件本身，再退到所在目录。
# ls -Z 的列序在 GNU / toybox 下不一致，所以直接按 u:object_r:xxx:sN 提串。
# SD_CTX_OVERRIDE 用于强制指定（老 ROM 的 ls 不带 -Z，或仿真测试）。
sd_file_ctx() {
    local c
    [ -n "$SD_CTX_OVERRIDE" ] && { printf '%s' "$SD_CTX_OVERRIDE"; return 0; }
    c=$(ls -Zd "$1" 2>/dev/null | grep -o 'u:object_r:[A-Za-z0-9_]*:s[0-9]*' | head -n 1)
    [ -n "$c" ] && { printf '%s' "$c"; return 0; }
    c=$(ls -Zd "${1%/*}" 2>/dev/null | grep -o 'u:object_r:[A-Za-z0-9_]*:s[0-9]*' | head -n 1)
    [ -n "$c" ] && { printf '%s' "$c"; return 0; }
    return 1
}

# toybox 的 chcon 不认 GNU 的 --reference，直接调用必然失败
# （日志里"3/3 chcon 失败"就是这条）。改成先试 --reference，不行就显式设。
sd_chcon_ref() {
    local ctx
    chcon --reference="$1" "$2" 2>/dev/null && return 0
    ctx=$(sd_file_ctx "$1") || return 1
    chcon "$ctx" "$2" 2>/dev/null
}

# chmod / chown 的 --reference 同样是 GNU 扩展，toybox 不认时退回显式值。
sd_chmod_ref() {
    local m
    chmod --reference="$1" "$2" 2>/dev/null && return 0
    m=$(stat -c %a "$1" 2>/dev/null) || return 1
    [ -n "$m" ] && chmod "$m" "$2" 2>/dev/null
}

sd_chown_ref() {
    local ug
    chown --reference="$1" "$2" 2>/dev/null && return 0
    ug=$(stat -c '%u:%g' "$1" 2>/dev/null) || return 1
    [ -n "$ug" ] && chown "$ug" "$2" 2>/dev/null
}

sd_verify_xml() {
    local a b
    [ -s "$2" ] || { sd_warn override "校验失败(空文件): $2"; return 1; }
    sd_xml_lead_ok "$2" || { sd_warn override "校验失败(非 XML): $2"; return 1; }
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
    sed -e 's/\([A-Za-z_]\{1,\}="\)true\("\)/\1false\2/g' -e 's/>true</>false</g' "$1" 2>/dev/null >"$2"
}

sd_xf_control() {
    sed 's/\([A-Za-z_]\{1,\}="\)true\("\)/\1false\2/g' "$1" 2>/dev/null >"$2"
}

sd_xf_fps() {
    sed 's/fps="[0-9.]\{1,\}"/fps="144"/g' "$1" 2>/dev/null >"$2"
}

sd_xf_legacy() {
    sed '/[Ee]nable/ s/>1</>0</g' "$1" 2>/dev/null >"$2"
}

sd_xf_chargejson() {
    sed 's/150,450\]/150,550]/g' "$1" 2>/dev/null >"$2"
}

sd_xf_qega() {
    # 取样点只在电池伪装打开时才指向 battery。battery 与 xo-therm 默认都不在
    # 伪装范围（sd_zone_class 里 battery/board 两类被隔离），把取样点从前者
    # 换成后者等于「伪装白做」——3.1.0~3.1.3 的自相矛盾。batt_spoof 关闭时
    # 保持原厂链路，改写成自己等于不动。
    local sn=xo-therm
    [ "$(sd_state_get batt_spoof off)" != off ] && sn=battery
    sed \
        -e "s/\(SkinTemperatureNode:[[:space:]]*\)xo-therm/\1$sn/" \
        -e '/^100001/s/^100001\([[:space:]]\{1,\}\)hok[[:space:]]\{1,\}48000[[:space:]]\{1,\}1200/180001\1hok         55000          2000/' \
        -e '/^0[[:space:]]\{1,\}adaptive/s/50000/55000/' \
        "$1" 2>/dev/null >"$2"
}

# 返回值：0 改写完成；2 主动跳过（格式不像温度曲线，保持原厂）；1 真失败
sd_xf_curve() {
    local n
    # 先数「三列整数」的行：一条都没有说明不是这个格式，原样保留，别乱动。
    n=$(awk -F, '/^[0-9]+,[0-9]+,[0-9]+$/ {n++} END{print n+0}' "$2" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -gt 0 ] || return 2
    # 列语义探测：首列是 0.1℃ 量级的温度轴。判据放三关：
    #   1) 所有值 ≤600（0.1℃ 的 60℃ 上限）；
    #   2) 去掉 0 之后单调（升或降都行，有些机型从高温往低温排）；
    #   3) 非零部分最大值 ≥100 —— 这是区分「0.1℃」和「℃ 整数」的关键：
    #      25,30,35℃ 那种整数表最大值只有 35，+120 会变成 145，必须跳过。
    # 0 允许出现在任意位置：低温保护段常写成 0,50,250，整份跳过会白丢一台机型。
    # 拿不准就跳过：宁可保持原厂，也不要把温度轴整体错位。
    awk -F, 'BEGIN{ok=1;n=0;nz=0;mx=0;prev=-1;dir=0}
        /^[0-9]+,[0-9]+,[0-9]+$/ {
            v=$1+0; n++
            if (v>600) { ok=0; next }
            if (v==0) next
            if (nz>0) {
                if (v>prev) { if (dir<0) ok=0; dir=1 }
                else if (v<prev) { if (dir>0) ok=0; dir=-1 }
            }
            prev=v; nz++
            if (v>mx) mx=v
        }
        END{ if (n==0 || nz<2 || mx<100) ok=0; exit ok?0:1 }' "$2" 2>/dev/null || return 2
    awk -F, -v off="$1" 'BEGIN{OFS=","}
        /^[0-9]+,[0-9]+,[0-9]+$/ { $1=$1+off; if ($1>600) $1=600; print; next }
        { print }' "$2" 2>/dev/null >"$3"
}

sd_transform() {
    local src="$1" dst="$2" tmp rc=1 kind=xml bk
    tmp="$dst.sdtmp"

    # 源读不到（分区缺项、inode 已失效）属于环境问题，不是模块故障：静默跳过。
    # 以前这里会一路走到 sd_xf_* 返回非 0，然后记一条 E "改写失败"——那类机器
    # 每次开机都刷一批假错误，看起来像模块坏了，实际只是 ROM 里没有这份配置。
    [ -r "$src" ] || return 0

    bk="$SD_BACKUP$src"
    if [ ! -f "$bk" ]; then
        mkdir -p "$(dirname "$bk")" 2>/dev/null
        # 备份是给用户手取的存档（$SD_DATA/backup$src），模块不会自动回滚它。
        # 失败要留痕：以前 2>/dev/null 把错误吞了，目录建了文件没有，事后想取原件才发现是空的。
        cp -p "$src" "$bk" 2>/dev/null || sd_warn override "备份失败: $src"
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
        *) return 1 ;;
    esac

    if [ "$rc" -ne 0 ]; then
        rm -f "$tmp"
        # 2 = 主动跳过：格式不是温度曲线，保持原厂，不算故障。
        [ "$rc" = 2 ] && { sd_warn override "跳过改写(格式不符): $src"; return 2; }
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
    # 规范键名是 versionCode（Magisk/KernelSU 都按这个读），旧版曾写成全小写，
    # 这里两个都试一次，升级过程中不会因为读到空值把指纹打成 0。
    vc=$(sd_prop_get versionCode)
    [ -n "$vc" ] || vc=$(sd_prop_get versioncode)
    off=$(sd_state_int curve_offset 120 0 300)
    printf '%s-%s-%s-%s' \
        "$(getprop ro.build.display.id)" \
        "$(getprop ro.build.version.security_patch)" \
        "${vc:-0}" "$off"
}

# 产物自检：改写只是文本替换，语义可能被改坏。只查两条能确定的：
#   - 高温保护 XML 里不应再有 ="true"（否则等于没关）
#   - charging_*.txt 行数应与原件一致（改写只动第一列）
# 只记 W，不改行为：自检失败说明这份配置可能不适用，用户可从日志定位。
sd_override_selftest() {
    local f s n m
    find "$SD_OVERRIDES" -type f -name 'sys_high_temp_protect_*.xml' 2>/dev/null |
        while IFS= read -r f; do
            s=$(grep -c '="true"' "$f" 2>/dev/null)
            [ "${s:-0}" = 0 ] || sd_warn override "自检: ${f#"$SD_OVERRIDES"/} 仍有 $s 处 true"
        done
    find "$SD_OVERRIDES" -type f -name 'charging_*.txt' 2>/dev/null |
        while IFS= read -r f; do
            s="$SD_BACKUP/${f#"$SD_OVERRIDES"/}"
            [ -f "$s" ] || continue
            n=$(wc -l <"$s" 2>/dev/null | tr -d ' ')
            m=$(wc -l <"$f" 2>/dev/null | tr -d ' ')
            [ "$n" = "$m" ] || sd_warn override "自检: ${f#"$SD_OVERRIDES"/} 行数 $n → $m"
        done
    return 0
}

sd_build_overrides() {
    local fp base f rel lf ok skip fail
    fp=$(sd_fingerprint)

    # 用户用 `action.sh overrides off` 关掉配置改写时，一个文件也不生成。
    # 温度伪装走 emul_temp，与配置层无关，不受影响——这是把「配置的锅」
    # 和「伪装的锅」分开的必要开关。
    if [ "$(sd_state_get overrides_off 0)" = 1 ]; then
        sd_info override "配置改写已关闭(overrides off)，跳过生成"
        return 0
    fi

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
    mkdir -p "$SD_OVERRIDES" "$SD_RUN" 2>/dev/null

    lf="$SD_RUN/ovr.list"
    for base in $SD_CFG_DIRS; do
        [ -d "$base" ] || continue
        # 用文件重定向而不是管道：管道会让 while 落进子 shell，计数全丢。
        find "$base" -maxdepth 2 -type f \( \
            -name 'sys_high_temp_protect_*.xml' -o \
            -name 'sys_thermal_control_config*.xml' -o \
            -name 'thermallevel_to_fps.xml' -o \
            -name 'sys_thermal_config.xml' -o \
            -name 'devices_config.json' -o \
            -name 'QEGA_Config.txt' -o \
            -name 'charging_*.txt' \
            \) 2>/dev/null >"$lf"
        ok=0; skip=0; fail=0
        while IFS= read -r f; do
            rel="${f#/}"
            sd_transform "$f" "$SD_OVERRIDES/$rel"
            case $? in
                0) ok=$((ok + 1)) ;;
                2) skip=$((skip + 1)) ;;
                *) fail=$((fail + 1)) ;;
            esac
        done <"$lf"
        [ $((ok + skip + fail)) -gt 0 ] &&
            sd_info override "${base#/}: 改写 $ok · 跳过 $skip · 失败 $fail"
    done
    rm -f "$lf" 2>/dev/null

    sd_override_selftest

    printf '%s' "$fp" 2>/dev/null >"$SD_BUILT"
    sd_info override "扫描: $(for _d in $SD_CFG_DIRS; do [ -d "$_d" ] && printf '%s ' "${_d#/}"; done)"
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
              sd_chmod_ref "/$rel" "$dst"
              sd_chown_ref "/$rel" "$dst"
              sd_chcon_ref "/$rel" "$dst"
          fi
          printf '%s\n' "$rel"
      done ) >"$cur"

    if [ ! -s "$cur" ]; then
        # 一个覆盖文件都没产出：把上一轮的镜像目录和 nm.list 一起清掉。
        # 留着的话 NoMount 下次开机会照旧清单去挂已经不存在的源，留下
        # "目录项还在、stat 拿不到 inode"的断链挂载点，比不挂更糟。
        if [ -n "$(ls -A "$SD_NM_ROOT" 2>/dev/null)" ] || [ -s "$SD_NM_LIST" ]; then
            rm -rf "$SD_NM_ROOT" 2>/dev/null
            rm -f "$SD_NM_LIST" 2>/dev/null
            sd_info mount "无覆盖文件，已清空 NoMount 镜像与清单"
        fi
        return 2
    fi

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
    if [ "$(sd_state_get overrides_off 0)" = 1 ]; then
        sd_umount_overrides
        sd_info mount "配置改写已关闭(overrides off)，不挂载"
        return 0
    fi
    [ -d "$SD_OVERRIDES" ] || return 1

    # rc=2 既可能是镜像真写失败，也可能只是没有覆盖文件可镜像。后者在源配置
    # 缺失的机器上每轮都会遇到，不该报"写入失败"。先数一遍产物用来区分。
    total=$(find "$SD_OVERRIDES" -type f 2>/dev/null | wc -l | tr -d ' ')

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
                [ "$total" -gt 0 ] && sd_warn mount "NoMount 镜像写入失败，退回 bind mount" ;;
        esac
    fi

    if sd_mm_active; then
        mmn=$(sd_mm_name)
        sd_nm_mirror
        case $? in
            2) [ "$total" -gt 0 ] && sd_warn mount "$mmn 镜像写入失败，退回 bind mount" ;;
            *)
                : >"$SD_MOUNTS" 2>/dev/null
                sd_info mount "已交给 $mmn，system/ 下 $(wc -l <"$SD_NM_LIST" 2>/dev/null | tr -d ' ') 个文件，开机挂载"
                return 0 ;;
        esac
    fi

    sd_umount_overrides
    : >"$chgfail"

    ( cd "$SD_OVERRIDES" 2>/dev/null || exit 1
      find . -type f 2>/dev/null | while IFS= read -r rel; do
          rel="${rel#./}"
          src="$SD_OVERRIDES/$rel"
          dst="/$rel"
          [ -e "$dst" ] || continue
          sd_chmod_ref "$dst" "$src"
          sd_chown_ref "$dst" "$src"
          sd_chcon_ref "$dst" "$src" || { echo "$dst" >>"$chgfail"; }
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

# 挂载可能发生在别的 mount namespace（KSU 的 su 会话常常如此），
# /proc/mounts 里看不到逐文件 bind。用一个内容比对兜底：
# 抽样若干条，改写版与系统里的目标文件完全一致，就说明覆盖真实生效。
sd_mounts_content_ok() {
    local rel n=0 ok=0 root="${SD_ROOT:-}"
    [ -d "$SD_OVERRIDES" ] || return 1
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        rel="${rel#/}"
        [ -f "$SD_OVERRIDES/$rel" ] || continue
        n=$((n + 1))
        cmp -s "$SD_OVERRIDES/$rel" "$root/$rel" && ok=$((ok + 1))
        [ "$n" -ge 5 ] && break
    done <"$SD_MOUNTS"
    [ "$n" -gt 0 ] && [ "$ok" -eq "$n" ]
}

sd_mounts_alive() {
    if sd_nm_active; then
        [ -s "$SD_NM_LIST" ] && [ -d "$SD_NM_ROOT" ] && return 0
        return 1
    fi
    [ -s "$SD_MOUNTS" ] || return 1
    if awk 'NR==FNR { if ($0!="") want[$0]=1; next }
            ($2 in want) { hit[$2]=1 }
            END { exit (length(hit)>0 ? 0 : 1) }' "$SD_MOUNTS" /proc/mounts 2>/dev/null; then
        return 0
    fi
    sd_mounts_content_ok
}

# 扫 /proc/self/mountinfo，把挂载源（root 字段）落在本模块目录下的挂载点全卸掉。
# 只靠 mounts.list 与 files/ 会漏：files/ 被清空之后两边都对不上，上一版留下的
# bind mount 就一直挂着；源被删后它变成 stat 不到的断链挂载点，umount 按路径
# 也认不出来，只能按 root 字段匹配。
sd_umount_module_mounts() {
    [ -r /proc/self/mountinfo ] || return 0
    awk '
        {
            i = 0
            for (k = 1; k <= NF; k++) if ($k == "-") { i = k; break }
            if (i > 0 && $5 != "" && $4 != "") print $5 "\t" $4
        }
    ' /proc/self/mountinfo 2>/dev/null |
    while IFS="$(printf '\t')" read -r _mp _root; do
        case "$_root" in
            "$MODDIR"/*|"$SD_BACKUP"/*)
                umount "$_mp" 2>/dev/null || umount -l "$_mp" 2>/dev/null
                ;;
        esac
    done
    return 0
}

sd_umount_overrides() {
    local p left n mp purge="${1:-}"
    sd_umount_module_mounts
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

# 启动瞬间 sysfs 常常还没就绪，这时探测结果是 0，几秒后就变成 8。
# 只在启动时打一次的话，日志里只剩那个 0，看日志的人会当成「永久没节点」
# —— 3.1.12 的根因报告据此写了一条并不存在的 P2。数量变了就补一条。
_sd_curr_ex=-1
sd_curr_watch() {
    local n ce
    n=$(sd_curr_nodes 2>/dev/null | wc -l | tr -d ' ')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" = "$_sd_curr_ex" ] && return 0
    _sd_curr_ex=$n
    ce=$(printf '%s' "$_sd_curr_nodes" | wc -w | tr -d ' ')
    [ "$ce" -gt 0 ] 2>/dev/null || ce=0
    sd_info env "charge-nodes=${n}/${ce}（存在/候选，启动后重新探测）"
}

sd_curr_nodes() {
    local n
    _sd_curr_prepare
    for n in $_sd_curr_nodes; do
        [ -e "$n" ] && printf '%s\n' "$n"
    done
    return 0
}


_sd_bl_nodes=""
_sd_screen_on=1
_sd_screen_n=0
_sd_screen_ticks=0
_sd_scr_log=0
_sd_screen_node=""
_sd_screen_val=""

# 把候选亮度节点收成一份列表，只扫一次目录。
# 不能"取第一个存在的节点就完事"：PJD110 的 panel0-backlight/actual_brightness
# 恒为 0，排在前面的节点一旦是这种，屏幕就永远判成灭屏。全部读到 0 才算灭屏。
sd_screen_nodes() {
    local p
    [ -n "$_sd_bl_nodes" ] && return 0
    for p in "$SD_BL"/*/actual_brightness "$SD_BL"/*/brightness \
             /sys/class/leds/lcd-backlight/brightness; do
        [ -e "$p" ] && _sd_bl_nodes="$_sd_bl_nodes $p"
    done
    [ -n "$_sd_bl_nodes" ]
}

sd_screen_sample_v() {
    local p v max=0 any=0 hit=""
    if sd_screen_nodes; then
        for p in $_sd_bl_nodes; do
            sd_read1 "$p" || continue
            v=$_sd_rv
            case "$v" in ''|*[!0-9]*) continue ;; esac
            any=1
            [ "$v" -gt "$max" ] && { max=$v; hit=$p; }
        done
        [ "$any" = 1 ] || return 1
        [ "$max" -gt 0 ] && _sd_screen_raw=1 || _sd_screen_raw=0
        _sd_screen_node=${hit:-${_sd_bl_nodes%% *}}
        _sd_screen_val=$max
        return 0
    fi
    if [ -e "$SD_FB" ]; then
        sd_read1 "$SD_FB" || return 1
        v=$_sd_rv
        case "$v" in ''|*[!0-9]*) return 1 ;; esac
        [ "$v" -eq 0 ] && _sd_screen_raw=1 || _sd_screen_raw=0
        _sd_screen_node=$SD_FB
        _sd_screen_val=$v
        return 0
    fi
    return 1
}

sd_screen_tick() {
    local prev="$_sd_screen_on"
    _sd_screen_ticks=1
    if ! sd_screen_sample_v; then
        _sd_screen_on=1
        _sd_screen_n=0
    elif [ "$_sd_screen_raw" = 1 ]; then
        _sd_screen_on=1
        _sd_screen_n=0
    else
        _sd_screen_n=$((_sd_screen_n + 1))
        [ "$_sd_screen_n" -ge 2 ] && _sd_screen_on=0
    fi
    # 状态翻转记一条：熄屏/亮屏相关的判断（延迟释放、轮询间隔）都挂在这上面
    if [ "$prev" != "$_sd_screen_on" ]; then
        sd_info screen "$( [ "$_sd_screen_on" = 1 ] && printf '亮屏' || printf '熄屏' )（节点 ${_sd_screen_node:-?}=${_sd_screen_val:-?}）"
    fi
    return 0
}


# ---------------------------------------------------------------- 亮屏快充
# 亮屏掉功率的落点在内核充电驱动的 fb_notifier：
#   亮屏 → reset_max_fcc_ma(chip, SCREEN_ON_MAX_FCC_MA, true)
# 屏幕一亮就把 FCC 压到 1500~2000mA（≈7~9W），与温度无关。
# 按优先级做两件事：
#   1) 有 ignore_screen_state → 置 1，让驱动忽略屏幕状态
#   2) 没有 → 记住息屏充电时的 FCC，亮屏被压低后写回
# 只在「充电中 + 开关开 + 温度模式不是关闭」时接管，退出即还原。

SD_SCR_NODE=""
SD_SCR_ORIG="$SD_RUN/scr.orig"
SD_SCR_WAY="$SD_RUN/scr.way"
SD_SCR_FAIL="$SD_RUN/scr.fail"
SD_FCC_NORM="$SD_RUN/fcc.norm"
SD_FCC_NORM_NODE="$SD_RUN/fcc.node"
_sd_scr_on=0
_sd_scr_way=""
_sd_scr_log=""
_sd_scr_cur=0
_sd_scr_node=""

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

# 输入侧节点：USB 端口能力、充电器能力、MTK 输入限流。写这些会重新协商 PD/VOOC，
# 不是改电池充电电流，绝不能拿来当屏幕快充的回写目标。
sd_scr_is_input() {
    case "$1" in
        */usb/*|*/charger/*|*/pc_port/*|*/wireless/*|*input_current_limit*) return 0 ;;
    esac
    return 1
}

sd_scr_fcc_node() {
    _sd_curr_prepare
    local n pref
    # 优先级：电池侧 FCC → 电池侧 current_max → 欧加 chg_current_max。
    # 3.0.3 及更早把 usb/current_max 当兜底，那是 USB 端口能力上限（PD 协商用，
    # 常见固定 2000mA），往里写会让充电器重新协商，实测 OPPO/一加从 60W 掉到
    # 37W，用户看到的就是「功率锁 30W」。宁可判定不支持，也不碰输入侧节点。
    for pref in constant_charge_current_max battery/current_max chg_current_max; do
        for n in $_sd_curr_nodes; do
            case "$n" in
                *"$pref"*)
                    sd_scr_is_input "$n" && continue
                    [ -e "$n" ] && { _sd_sf=$n; return 0; }
                    ;;
            esac
        done
    done
    for n in $_sd_curr_nodes; do
        sd_scr_is_input "$n" && continue
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
    local v old=0 nprev=""
    sd_scr_fcc_node || return 1
    sd_scr_read_ma "$_sd_sf" || return 1
    v=$_sd_rv
    [ "$v" -ge 500 ] || return 1
    [ "$v" -gt 12000 ] && v=12000
    # 基线必须绑在节点上：换了节点（例如从 usb/current_max 换到电池侧 FCC）
    # 就把旧基线作废重学，否则会拿旧节点的历史最大值去压新节点。
    [ -f "$SD_FCC_NORM_NODE" ] && nprev=$(cat "$SD_FCC_NORM_NODE" 2>/dev/null)
    if [ "$nprev" != "$_sd_sf" ]; then
        rm -f "$SD_FCC_NORM" 2>/dev/null
        printf '%s\n' "$_sd_sf" >"$SD_FCC_NORM_NODE" 2>/dev/null
    fi
    if [ -f "$SD_FCC_NORM" ]; then
        old=$(cat "$SD_FCC_NORM" 2>/dev/null)
        case "$old" in ''|*[!0-9]*) old=0 ;; esac
    fi
    [ "$v" -gt "$old" ] && printf '%s\n' "$v" >"$SD_FCC_NORM" 2>/dev/null
    return 0
}

# 目标电流：正常值，按真实电池温度打折；≥42℃ 直接不接管
sd_scr_target() {
    local n
    _sd_rv=0
    [ -f "$SD_FCC_NORM" ] || return 1
    n=$(cat "$SD_FCC_NORM" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    [ "$n" -gt 12000 ] && n=12000
    # 不看电池温度：亮屏就按息屏学到的峰值顶回去。
    _sd_rv=$n
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
    # 只在亮屏时调用（息屏由 sd_scr_tick 直接返回，把 FCC 交还驱动）。
    # 亮屏后驱动会把 FCC 压到 SCREEN_ON_MAX_FCC_MA，这里按息屏学到的峰值顶回去。
    sd_scr_target
    case $? in
        0) ;;
        *) return 2 ;;      # 还没有基准
    esac
    tgt=$_sd_rv
    sd_scr_read_ma "$_sd_sf" || return 1
    cur=$_sd_rv
    _sd_scr_cur=$cur
    _sd_scr_node=${_sd_sf##*/}
    if [ "$cur" -ge "$tgt" ]; then
        _sd_scr_on=1; _sd_scr_way=fcc
        printf 'fcc\n' >"$SD_SCR_WAY" 2>/dev/null
        rm -f "$SD_SCR_FAIL" 2>/dev/null
        return 0
    fi
    # 死区：离目标不到 25% 不写。驱动自己也在按温度和电压动态算 FCC，
    # 贴着目标值来回覆盖，电流就在两档之间反复跳，曲线成锯齿。
    if [ "$cur" -ge $((tgt * 3 / 4)) ]; then
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

# 退出（拔线/关模式）时按原值还原。息屏时 FCC 路径根本不写，
# 内核参数路径才在这里还原，避免把「永远忽略屏幕」留到下次。
sd_scr_release() {
    local p v now
    if [ -f "$SD_SCR_ORIG" ]; then
        while IFS='|' read -r p v; do
            [ -n "$p" ] && [ -e "$p" ] || continue
            # 电流类节点：驱动已经放宽（息屏边界/温控回收）就别用旧值压回去。
            # 只对 mA/uA 量级生效，开关型参数（ignore_screen_state 的 0/1）照常还原。
            now=""
            case "$v" in
                ''|*[!0-9]*) ;;
                *) if [ "$v" -ge 100 ]; then
                       sd_read1 "$p" && now=$_sd_rv
                       case "$now" in
                           ''|*[!0-9]*) ;;
                           *) [ "$now" -gt "$v" ] && continue ;;
                       esac
                   fi ;;
            esac
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
    local mode bt rc key hot_lim
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

    if [ "$_sd_screen_on" = 0 ]; then
        # 息屏只更新基准（记录驱动在息屏放开的峰值），不写任何节点。
        # 驱动在息屏边界会自己把 FCC 放开到协议允许的峰值，模块这时候写回
        # 等于替驱动踩刹车：实测 OPPO/一加 60W 直接掉到 30W 档，而且压住之后
        # 驱动没机会放开，基准也就永远学不到真实峰值（2.9.73 起的回退）。
        # 内核参数那条一写就是「永久忽略屏幕」，息屏还原给驱动走正常 FCC。
        sd_scr_learn
        if sd_scr_node && sd_scr_active; then
            sd_scr_release; _sd_scr_log=""
        fi
        return 0
    fi

    # 不设温度闸：亮屏就接管，直到没在充电为止。

    sd_scr_apply
    rc=$?
    key=$_sd_scr_way
    case "$rc" in
        0)
            if [ "$key" != "$_sd_scr_log" ]; then
                case "$_sd_scr_way" in
                    kernel) sd_info charge "亮屏快充：已接管（内核 ignore_screen_state）" ;;
                    fcc)    sd_info charge "亮屏快充：已接管（回写 FCC，目标 $(cat "$SD_FCC_NORM" 2>/dev/null)mA，节点 ${_sd_scr_node:-?} 实读 ${_sd_scr_cur:-?}mA）" ;;
                esac
                _sd_scr_log=$key
            fi ;;
        2)
            if [ "$_sd_screen_on" = 1 ] && [ "$_sd_scr_log" != "wait" ]; then
                sd_info charge "亮屏快充：还没有基准值，先息屏充一次再亮屏"
                _sd_scr_log=wait
            fi ;;
        *)
            # 息屏时 apply 失败不落「本机不支持」：息屏边缘节点偶尔读不到，
            # 落盘后要等重启才恢复，亮屏那次才是可信的判定。
            sd_scr_active && sd_scr_release
            if [ "$_sd_screen_on" = 1 ]; then
                if [ "$_sd_scr_log" != "fail" ]; then
                    sd_warn charge "亮屏快充：本机不支持（无屏幕状态参数，也没有电池侧电流节点）"
                    _sd_scr_log=fail
                fi
                printf '1\n' >"$SD_SCR_FAIL" 2>/dev/null
            fi ;;
    esac
    return 0
}


_sd_curr_nodes=""

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

sd_charge_tick() {
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

    # 不设电量阈值：插着电就一直伪装，充到 100% 也不再交还。
    sd_shell_target >/dev/null
    sd_shell_emul "$_sd_last_out"
}

# -------------------------------------------------------------- cool_down 只读
# ColorOS 16/17 用 oplus_chg/battery/cool_down 做亮屏降流：灭屏 0，亮屏 3~13，
# 与温度无关（实测电池 33.8℃ 照样跳到 7）。它是「结果」，不是开关。
#
# 3.0~3.1.12 这里往它写过 0（"降流解除"），三次实测全是净损失：
#   PKB110 写 2→0：18W → 9.7W，一路抖到 6W
#   PKX110 写 0→1：32W → 9W，tech 7→14
#   PJD110 写 3→0：33.6W → 2.2W，随后 45 分钟没回到 10W 以上
#     （同一秒 vusb 8V→5.15V、imax 2.00A→0.50A、vooc 1→0、type→Unknown，
#      也就是写入这个动作让驱动重选档、重走协议协商，只能拔插线恢复）。
# 对照组在同一分钟里：驱动自己把 cool_down 清到 0 时功率 31.5W 正常 ——
# 同一个值、同一台机器，差别只在"谁写的"。所以这里只读不写。
SD_COOL_NODE=""
_sd_cool_none=0
_sd_cool_log=""        # 上一次记下的档位；""=还没记过，none=本机没节点

sd_cool_node() {
    local p
    [ "$_sd_cool_none" = 1 ] && return 1
    if [ -n "$SD_COOL_NODE" ] && [ -e "$SD_COOL_NODE" ]; then return 0; fi
    for p in "$SD_OPLUS_CHG/cool_down" "$SD_OPLUS_CHG/oplus_cool_down" \
             /sys/class/oplus_chg/charger/cool_down; do
        [ -e "$p" ] && { SD_COOL_NODE=$p; return 0; }
    done
    _sd_cool_none=1
    return 1
}

sd_cool_tick() {
    local cur

    if ! sd_cool_node; then
        if [ "$_sd_cool_log" != none ]; then
            sd_warn charge "cool_down：本机没有这个节点，跳过"
            _sd_cool_log=none
        fi
        return 0
    fi

    sd_batt_status_v
    case "$_sd_rv" in Charging|Full) ;; *) return 0 ;; esac

    sd_read1 "$SD_COOL_NODE" || return 0
    cur=$_sd_rv
    case "$cur" in ''|*[!0-9]*) return 0 ;; esac
    [ "$cur" = "$_sd_cool_log" ] && return 0
    _sd_cool_log=$cur
    if [ "$cur" = 0 ]; then
        sd_info charge "cool_down=0（当前没被降流）"
    else
        sd_info charge "cool_down=$cur（亮屏降流标记，只记录不写入）"
    fi
}

# ---------------------------------------------------------------- 充电阶梯解锁
# 「阶梯」的两个来源：系统 thermal HAL 按温度写 charge_control_limit /
# thermal_charging，以及驱动按电池温度自己分档。unlock 只动 HAL 侧——
# 写 0 表示不限流——并在写之前把原值备份到 run/unlock.orig，关闭、卸载时
# 还原。
#
# 刻意不碰两处：
#   - usb/current_max：输入侧能力上限，写它会打断 PD/VOOC 协商（3.0.4 的教训）；
#   - cool_down：写它会让 OPlus 重选档。PKB110 实测 ibat 4.3A 时写 2→0，
#     三秒后 18W 掉到 9.7W；交给 sd_cool_tick 只在真被降流时写。
SD_UNLOCK_ORIG="$SD_RUN/unlock.orig"
_sd_unlock_log=""
_sd_unlock_at=0

sd_unlock_list() {
    printf '%s\n' \
        "$SD_PS/battery/charge_control_limit" \
        "$SD_PS/battery/thermal_charging" \
        "$SD_PS/battery/step_charging" \
        "$SD_OPLUS_CHG/thermal_charging" \
        "$SD_OPLUS_CHG/step_charging"
}

sd_unlock_restore() {
    local p v n=0
    [ -f "$SD_UNLOCK_ORIG" ] || return 0
    while IFS='|' read -r p v; do
        [ -n "$p" ] && [ -e "$p" ] || continue
        printf '%s\n' "$v" >"$p" 2>/dev/null && n=$((n + 1))
    done <"$SD_UNLOCK_ORIG"
    rm -f "$SD_UNLOCK_ORIG"
    _sd_unlock_log=""
    [ "$n" -gt 0 ] && sd_dbg charge "阶梯解锁：还原 $n 个节点"
    return 0
}

sd_unlock_tick() {
    local on p cur n=0 now
    on=$(sd_state_get chg_unlock 0)
    if [ "$on" != 1 ]; then
        sd_unlock_restore
        return 0
    fi

    # 不看温度：开着就一直压 0，HAL 写回来也再压。
    for p in $(sd_unlock_list); do
        [ -e "$p" ] && [ -w "$p" ] || continue
        sd_read1 "$p" || continue
        cur=$_sd_rv
        [ "$cur" = 0 ] && continue
        grep -qxF "$p|$cur" "$SD_UNLOCK_ORIG" 2>/dev/null ||
            printf '%s|%s\n' "$p" "$cur" >>"$SD_UNLOCK_ORIG"
        if printf '0\n' >"$p" 2>/dev/null; then
            n=$((n + 1))
        elif [ "$_sd_unlock_log" != fail ]; then
            sd_warn charge "阶梯解锁失败：${p#$SD_PS/} 写不进去"
            _sd_unlock_log=fail
        fi
    done

    # HAL 可能过一轮又写回去，这里会再压 0；日志按分钟节流，免得刷屏。
    now=$(date +%s)
    if [ "$n" -gt 0 ] && [ $((now - _sd_unlock_at)) -ge 60 ]; then
        sd_info charge "阶梯解锁：$n 个节点写 0（原值备份在 run/unlock.orig）"
        _sd_unlock_at=$now
    fi
    return 0
}

# ---------------------------------------------------------------- 充电快照

# 以前查一次充电问题要 cat 七八个节点：usb 电压、电流上限、电池电流、
# cool_down、voocchg_ing、charge_technology…… 这里压成一行，状态一变就落
# 日志，充电中每 10 分钟补一条，日志自己就是时间线。
# 判重一律用"状态签名"：
#   电量 5%、温度 2℃、电池电压 20mV、电池电流 200mA 归并，其余状态字段原样。
#   整行比较会把 vbat 几十 mV、ibat 几十 mA 的抖动当成变化，充电时每 3 秒落
#   一条，日志全被这种噪声占满；档位切换（几百 mA 以上）仍然照记。
_sd_chg_last=""
_sd_chg_last_st=""
_sd_chg_at=0
_sd_chg_scan=0
_sd_chg_key=""
_sd_chg_line_v=""
_sd_chg_sig_v=""

# 有的机型 power_supply 的 voltage_now / current_max 报 mV/mA（4000 表示 4.0V），
# 多数报 µV/µA，两者差 1000 倍。按量级归一：小于 20000 的先乘 1000，再看结果
# 是否落在合理区间，避免把 0.03V（30000µV）这种空载值也乘上去。
sd_uv_norm() {
    local v="$1"
    case "$v" in ''|*[!0-9-]*) _sd_rv=$v; return 1 ;; esac
    if [ "$v" -gt 0 ] && [ "$v" -lt 20000 ]; then
        local t=$((v * 1000))
        if [ "$t" -ge 100000 ] && [ "$t" -le 30000000 ]; then _sd_rv=$t; return 0; fi
    fi
    _sd_rv=$v
    return 0
}

_sd_chg_fmt() {
    awk -v a="$1" -v b="$2" -v c="$3" -v d="$4" 'BEGIN {
        printf "%s %s %s %s",
            (a ~ /^-?[0-9]+$/ ? sprintf("%.2f", a / 1000000) : "?"),
            (b ~ /^-?[0-9]+$/ ? sprintf("%.2f", b / 1000000) : "?"),
            (c ~ /^-?[0-9]+$/ ? sprintf("%.3f", c / 1000000) : "?"),
            (d ~ /^-?[0-9]+$/ ? sprintf("%d", d / 1000) : "?")
    }'
}

# 输入侧实测电流（µA）。usb/current_max 是充电器能力上限，不是实际输入，
# 日志里只写 imax 会让人以为一直卡在 2A。这里优先读实测值。
sd_chg_input_v() {
    local p v abs best=0 babs=0
    for p in "$SD_PS/usb/current_now" "$SD_PS/usb/input_current_now" \
             "$SD_PS/usb/current_avg" "$SD_PS/usb_input/current_now" \
             "$SD_OPLUS_CHG/charger/current_now" "$SD_OPLUS_CHG/current_now" \
             "$SD_PS/charger/current_now" "$SD_PS/battery/input_current_now"; do
        [ -e "$p" ] || continue
        sd_read1 "$p" || continue
        v=$_sd_rv
        case "$v" in ''|*[!0-9-]*) continue ;; esac
        sd_uv_norm "$v" && v=$_sd_rv
        abs=$v; [ "$abs" -lt 0 ] && abs=$((-abs))
        [ "$abs" -eq 0 ] && continue
        if [ "$abs" -gt "$babs" ]; then best=$abs; babs=$abs; fi
    done
    [ "$babs" -gt 0 ] && { _sd_rv=$best; return 0; }
    return 1
}

# 电池电流，统一换算成 µA。灭屏后 power_supply 的 current_now 常停在 0 不刷新，
# 而 bcc_parms 仍在更新，所以先问 bcc，再回退 current_now / bms / current_avg。
sd_chg_current_v() {
    local v abs babs=0 best=0 have=0
    sd_bcc_parse
    if [ "$_sd_cell_ok" = 1 ] && [ -n "$_sd_cell_ma" ]; then
        best=$((_sd_cell_ma * 1000))
        case "$best" in ''|*[!0-9-]*) best=0 ;; esac
        have=1
        babs=$best; [ "$babs" -lt 0 ] && babs=$((-babs))
        # 绝对值 ≥50mA 才认 bcc 的第 9 段；有的机型这一段不是总电流，
        # 读出来就是 -1~-5mA 这种噪声，会盖掉真实值。
        [ "$babs" -ge 50000 ] && { _sd_rv=$best; return 0; }
    fi
    for v in current_now bms/current_now battery/current_avg; do
        case "$v" in
            current_now)
                sd_ps_attr_v current_now || sd_read1 "$SD_PS/battery/current_now" || continue
                ;;
            *)
                sd_read1 "$SD_PS/$v" || continue
                ;;
        esac
        v=$_sd_rv
        case "$v" in ''|*[!0-9-]*) continue ;; esac
        # 单位归一在这里做：有的机型 current_now 报 mA，有的报 µA。
        # 不归一的话 2500000 这道闸永远放行，normal 状态也会去写 cool_down。
        abs=$v; [ "$abs" -lt 0 ] && abs=$((-abs))
        sd_uv_norm "$abs" && abs=$_sd_rv
        [ "$abs" -eq 0 ] && continue
        have=1
        if [ "$best" -eq 0 ] || [ "$abs" -gt "$babs" ]; then
            if [ "$v" -lt 0 ]; then best=$((-abs)); else best=$abs; fi
            babs=$abs
        fi
    done
    [ "$have" = 1 ] && { _sd_rv=$best; return 0; }
    return 1
}

# 填 _sd_chg_line_v（日志行）与 _sd_chg_sig_v（判重签名）。
# 用全局变量而不是命令替换，两个结果才都留得住。
sd_chg_line_fill() {
    local cap vbat ibat vusb iusb imax type rtype cool vooc tech bt st f capk btk pwk pwc ibm usbk
    local pin pb cells ibs
    st=""; sd_batt_status_v && st=$_sd_rv
    cap=""; sd_ps_attr_v capacity && cap=$_sd_rv
    vbat=""; sd_ps_attr_v voltage_now && vbat=$_sd_rv
    ibat=""; sd_chg_current_v && ibat=$_sd_rv
    vusb=""; sd_read1 "$SD_PS/usb/voltage_now" && vusb=$_sd_rv
    iusb=""; sd_chg_input_v && iusb=$_sd_rv
    imax=""; sd_read1 "$SD_PS/usb/current_max" && imax=$_sd_rv
    type=""; sd_read1 "$SD_PS/usb/type" && type=$_sd_rv
    rtype=""; sd_read1 "$SD_PS/usb/real_type" && rtype=$_sd_rv
    cool=""; sd_read1 "$SD_OPLUS_CHG/cool_down" && cool=$_sd_rv
    vooc=""; sd_read1 "$SD_OPLUS_CHG/voocchg_ing" && vooc=$_sd_rv
    tech=""; sd_read1 "$SD_OPLUS_CHG/charge_technology" && tech=$_sd_rv
    bt=""; sd_batt_temp_v && bt=$_sd_rv
    # 归一单位，否则报 mV 的机型日志里 vbat=0.004V、判重功率恒 0
    [ -n "$vbat" ] && sd_uv_norm "$vbat" && vbat=$_sd_rv
    [ -n "$vusb" ] && sd_uv_norm "$vusb" && vusb=$_sd_rv
    [ -n "$imax" ] && sd_uv_norm "$imax" && imax=$_sd_rv

    cells=1
    sd_cells_resolve && cells=$_sd_rv

    # 输入侧与电池侧功率都算出来：输入掉、电池不掉是充电器/线的问题；
    # 两边一起掉才是负载或降档。日志里没有这两个数就只能猜。
    pin=-1; pb=-1
    if [ -n "$iusb" ] && [ -n "$vusb" ]; then
        pin=$(awk -v i="$iusb" -v v="$vusb" 'BEGIN{ printf "%.1f", (i<0?-i:i)*v/1e12 }' 2>/dev/null)
    fi
    if [ -n "$ibat" ] && [ -n "$vbat" ]; then
        pb=$(awk -v i="$ibat" -v v="$vbat" \
            'BEGIN{ printf "%.1f", (i<0?-i:i)*v/1e12 }' 2>/dev/null)
    fi
    case "$pin" in ''|*[!0-9.]*|-1) pin="?" ;; esac
    case "$pb"  in ''|*[!0-9.]*|-1) pb="?"  ;; esac

    f=$(_sd_chg_fmt "$vusb" "$imax" "$vbat" "$ibat")
    # shellcheck disable=SC2086
    set -- $f
    if [ -n "$iusb" ]; then
        ibs=$(awk -v x="$iusb" 'BEGIN{ printf "%.2f", (x<0?-x:x)/1e6 }' 2>/dev/null)
    else
        ibs="?"
    fi
    case "$ibs" in ''|*[!0-9.]*) ibs="?" ;; esac
    _sd_chg_line_v=$(printf 'vusb=%sV iusb=%sA imax=%sA vbat=%sV ibat=%smA pin=%sW pb=%sW %s%% %s℃ cool=%s vooc=%s tech=%s type=%s rtype=%s scr=%s cells=%s status=%s' \
        "$1" "$ibs" "$2" "$3" "$4" "$pin" "$pb" "${cap:-?}" "${bt:-?}" "${cool:-?}" "${vooc:-?}" \
        "${tech:-?}" "${type:-?}" "${rtype:-?}" "${_sd_screen_on:-?}" "$cells" "${st:-?}")

    capk=${cap:-0}; btk=${bt:-0}
    case "$capk" in ''|*[!0-9]*) capk=0 ;; esac
    case "$btk" in ''|*[!0-9]*) btk=0 ;; esac

    # 判重不再看 vbat/ibat 的瞬时值：它们每 3 秒就掉一次档再弹回来（见 sd_power_median
    # 的注释），按 100mV/200mA 分档照样每轮跨档，日志会被灌成 3 秒一条。
    # 改用中值功率分档（1W），脉动被滤掉，真实降档依然跨档。
    pwk=0
    if [ -n "$ibat" ] && [ -n "$vbat" ]; then
        case "$st" in *Charging*|Full) pwc=1 ;; *) pwc=0 ;; esac
        ibm=$ibat
        [ "$ibm" -lt 0 ] && ibm=$((-ibm))
        ibm=$((ibm / 1000))
        sd_power_median "$ibm" "$pwc" && ibm=$_sd_rv
        case "$ibm" in ''|*[!0-9]*) ibm=0 ;; esac
        pwk=$(( ibm * vbat / 1000000000 ))
    fi

    usbk=-1
    case "${vusb:-}" in ''|*[!0-9]*) ;; *) usbk=$(( (${vusb} + 500000) / 1000000 )) ;; esac
    _sd_chg_sig_v="st=${st:-?} pw=${pwk}W cap=$((capk / 5 * 5)) bt=$((btk / 2 * 2)) usb=$usbk imax=${imax:-?} type=${type:-?} cool=${cool:-?} vooc=${vooc:-?} tech=${tech:-?} scr=${_sd_screen_on:-?}"
}

sd_chg_line() {
    sd_chg_line_fill
    printf '%s' "$_sd_chg_line_v"
}

# 电流节点统一显示成 mA：7 位以上按 µA 换算，cool_down 这类小整数原样输出。
_sd_tier_val() {
    local v=$1
    case "$v" in
        ''|*[!0-9-]*) printf '%s' "$v"; return 0 ;;
    esac
    if [ "${#v}" -ge 7 ]; then
        printf '%smA' "$((v / 1000))"
    else
        printf '%s' "$v"
    fi
}

_sd_tier_row() {
    local p=$1 hint=$2 v w
    [ -e "$p" ] || return 1
    sd_read1 "$p" || return 1
    v=$(_sd_tier_val "$_sd_rv")
    [ -w "$p" ] && w=yes || w=no
    printf '  %-38s %-11s %-4s %s\n' "${p#$SD_PS/}" "$v" "$w" "$hint"
    _sd_tier_hit=$((_sd_tier_hit + 1))
    return 0
}

# 把真正能改充电电流的节点全列出来，谁在限一眼可见。
# 3.0.8 删掉了 horae 开关：它只管 CPU/GPU 降频与亮度，跟充电无关。
sd_tier_report() {
    local bt="" tech="" st="" cool=""
    _sd_tier_hit=0

    sd_batt_temp_v && bt=$_sd_rv
    sd_read1 "$SD_PS/battery/charge_technology" 2>/dev/null && tech=$_sd_rv
    sd_batt_status_v && st=$_sd_rv

    printf '充电阶梯诊断（能左右充电电流的节点）\n\n'
    printf '  %-38s %-11s %-4s %s\n' "node" "value" "wr" "note"

    _sd_tier_row "$SD_PS/battery/charge_control_limit"    "thermal HAL 额外限流，0=未限"
    _sd_tier_row "$SD_PS/battery/charge_control_limit_max" "thermal HAL 可写到这个上限"
    _sd_tier_row "$SD_PS/battery/thermal_charging"        "1=系统温控正在限充"
    _sd_tier_row "$SD_PS/battery/step_charging"           "阶梯充电开关（部分机型有）"
    _sd_tier_row "$SD_PS/battery/constant_charge_current_max" "电池侧 FCC，驱动当前允许值"
    _sd_tier_row "$SD_PS/battery/constant_charge_current" "同上（瞬时目标）"
    _sd_tier_row "$SD_PS/battery/current_max"             "电池侧上限"
    _sd_tier_row "$SD_PS/battery/input_current_limit"     "MTK 输入限流"
    _sd_tier_row "$SD_PS/usb/current_max"                 "输入侧上限，写它会打断 PD/VOOC"
    _sd_tier_row "$SD_PS/battery/bcc_current"             "分电流档（双电芯）"
    _sd_tier_row "$SD_OPLUS_CHG/cool_down"                "亮屏降流档，0=不降"

    if [ "$_sd_tier_hit" -eq 0 ]; then
        printf '  （一个都没找到：这台机的限流在驱动内部，没有对外节点）\n'
    fi

    printf '\n电池 %s℃  协议 %s  状态 %s\n' "${bt:-?}" "${tech:-?}" "${st:-?}"

    printf '\n判读：\n'
    printf '  阶梯来自两处：系统 thermal HAL 写 charge_control_limit / thermal_charging，\n'
    printf '  以及充电驱动按电池温度自己分档（oplus 的 cool_down）。\n'
    printf '  取消这些限制：unlock on（写入前备份原值；不看电池温度，要还原得手动 unlock off）\n'
    printf '  只想看当前谁在限：保持现状，用 diag 采样对比 unlock 前后。\n'
}

sd_chg_snapshot() {
    local charging="${1:-0}" line st now why key
    [ "${_sd_lv:-0}" -ge 2 ] || return 0
    now=$(date +%s)
    # 插拔的瞬间必须记下来，只有"状态没变"时才按 30s 节流
    if [ "$charging" = "${_sd_chg_last_chg:-x}" ] && [ "$charging" != 1 ] && \
       [ $((now - _sd_chg_scan)) -lt 30 ]; then
        return 0
    fi
    _sd_chg_scan=$now
    _sd_chg_last_chg=$charging

    st=""; sd_batt_status_v && st=$_sd_rv
    sd_chg_line_fill
    line=$_sd_chg_line_v
    key=$_sd_chg_sig_v

    why=变化
    if [ -z "$_sd_chg_key" ]; then
        why=首帧                      # 开启日志后第一帧必须是完整现场，否则要看历史得等下一次变化
    elif [ "$st" != "$_sd_chg_last_st" ]; then
        _sd_chg_last_st=$st
        if [ "$charging" = 1 ]; then why=插电; else why=停充; fi
    fi
    _sd_chg_last_st=$st

    if [ "$key" = "$_sd_chg_key" ]; then
        if [ "$charging" = 1 ] && [ $((now - _sd_chg_at)) -ge 600 ]; then
            _sd_emit S chg "定时 $line"
            _sd_chg_at=$now
        fi
        return 0
    fi
    _sd_emit S chg "$why $line"
    _sd_chg_key=$key
    _sd_chg_last=$line
    _sd_chg_at=$now
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

# 电池电流的 5 点中值。
# 欧加机器的 bcc 电流是瞬时值，充电时会在两档之间来回脉动：4.4V 电芯内阻约 60mΩ，
# 电流 ±600mA 恰好对应 ±40mV 的 vbat 摆动，读数看着像"乱跳"，其实是真实脉动。
# 面板要的是平均功率，取最近 5 次的中值既能压住脉动，又不会掩盖真实降档（2 个采样就跟上）。
# 充电/放电切换时旧样本全部作废，避免插拔瞬间的中值被两组数据掺在一起。
sd_power_median() {
    local raw="$1" code="$2" now t c v tmp n sorted mid
    _sd_rv=""
    case "$raw" in ''|*[!0-9-]*) return 1 ;; esac
    now=$(date +%s)
    tmp="$SD_RUN/power.tmp.$$"
    : >"$tmp" 2>/dev/null || return 1
    if [ -f "$SD_PWR_HIST" ]; then
        while read -r t c v; do
            case "$t" in ''|*[!0-9]*) continue ;; esac
            [ "$c" = "$code" ] || continue
            case "$v" in ''|*[!0-9-]*) continue ;; esac
            # 时间戳必须落在最近 60 秒内。开机后 RTC 才校准的机器时钟会往回跳，
            # 只做 now-t<=60 会把"未来"的旧样本一直留在窗口里。
            [ "$t" -le "$now" ] && [ "$t" -ge $((now - 60)) ] || continue
            printf '%s %s %s\n' "$t" "$c" "$v"
        done <"$SD_PWR_HIST" >>"$tmp" 2>/dev/null
    fi
    printf '%s %s %s\n' "$now" "$code" "$raw" >>"$tmp"

    n=$(wc -l <"$tmp" 2>/dev/null | tr -d ' \t')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    # 只留最近 5 条
    if [ "$n" -gt 5 ]; then
        sed -n "$((n - 4)),\$p" "$tmp" >"$tmp.2" 2>/dev/null && mv "$tmp.2" "$tmp"
        n=5
    fi
    mv "$tmp" "$SD_PWR_HIST" 2>/dev/null || rm -f "$tmp" 2>/dev/null

    if [ "$n" -lt 3 ]; then _sd_rv="$raw"; return 0; fi
    sorted=$(sed -n 's/^[0-9]* [0-9]* //p' "$SD_PWR_HIST" 2>/dev/null | sort -n)
    n=$(printf '%s' "$sorted" | grep -c . 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -ge 3 ] || { _sd_rv="$raw"; return 0; }
    mid=$(( (n + 1) / 2 ))
    _sd_rv=$(printf '%s\n' "$sorted" | sed -n "${mid}p")
    [ -n "$_sd_rv" ] || _sd_rv="$raw"
    return 0
}

sd_power_json() {
    local c mv w st cap t ma src=ps cells=1 neg="" scale
    local v0 v1 bv pv ma_raw="" w_raw="" pw_code=0

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
        ma_raw=$c
        # 充电记 1、其余记 0：插拔那一刻两组样本不能混着算中值
        case "$st" in *Charging*|Full) pw_code=1 ;; *) pw_code=0 ;; esac
        sd_power_median "$ma" "$pw_code" && ma=$_sd_rv
    fi

    w=""
    if [ -n "$ma" ] && [ -n "$mv" ]; then
        w=$(awk -v a="$ma" -v b="$mv" 'BEGIN { printf "%.2f", (a < 0 ? -a : a) * b / 1000000 }')
    fi
    if [ -n "$ma_raw" ] && [ -n "$mv" ]; then
        w_raw=$(awk -v a="$ma_raw" -v b="$mv" 'BEGIN { printf "%.2f", (a < 0 ? -a : a) * b / 1000000 }')
    fi

    case "$t" in ''|*[!0-9]*) t="" ;; esac
    [ -n "$t" ] && { [ "$t" -ge 1 ] && [ "$t" -le 120 ] || t=""; }

    case "$cap" in ''|*[!0-9]*) cap="" ;; esac
    case "$st" in *\"*|*\\*) st="" ;; esac

    sd_plat_resolve

    # 不再输出 protocol：面板 2.9.67 起就不显示，"未接充电器"由 status 判断。
    printf '{"ma":%s,"mv":%s,"w":%s,"wr":%s,"status":"%s","cap":%s,"temp":%s,"cells":%s,"cells_src":"%s","src":"%s","plat":"%s"}\n' \
        "${ma:-null}" "${mv:-null}" "${w:-null}" "${w_raw:-null}" "${st:-Unknown}" "${cap:-null}" "${t:-null}" \
        "$cells" "${_sd_cell_src:-default}" "$src" "$_sd_plat"
}

SD_DESC_LAST="$SD_RUN/desc.last"

sd_desc_text() {
    local mode t
    [ "$_sd_st_loaded" = 1 ] || sd_state_load
    mode=${_st_temp_mode:-off}
    [ "$mode" = dyn ] && mode=static
    _sd_clamp "${_st_shell_temp:-30}" 20 33 30

    case "$mode" in
        static|charge) t="温度伪装 $_sd_rv℃" ;;
        *)             t="温度伪装关闭" ;;
    esac
    [ "$mode" = charge ] && t="$t（仅充电）"

    hz=${_st_hz:-off}
    case "$hz" in
        # 没开高刷就什么都不写：描述是给面板/管理器看的摘要，
        # 只有「开了」才值得占一段位置
        off|'') ;;
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
        t="$t · 配置未挂载"
    fi

    # 状态段放在最前面：管理器模块页第一眼看到的就是跑没跑。
    # 管理器把 description 当纯文本渲染（KernelSU 的 ModuleMaterial 直接 Text()），
    # 所以颜色只能靠 emoji 自带的那一层，字体设不了色。
    sd_module_state
    case "$_sd_ms" in
        ok)     t="✅ 运行中 · $t" ;;
        reboot) t="❌ 请重启 · 重启后开始工作" ;;
        *)      t="❌ 未运行 · 把 /data/adb/quickcharge/ 的日志发给作者" ;;
    esac

    printf '%s' "$t"
}

# module.prop 被编辑器按 UTF-16 存过时，每个字符后面跟一个 NUL，整份文件在
# grep 眼里就是二进制，输出 "Binary file ... matches" 而不是内容——面板版本号
# 于是显示成 "vBinary file /data/adb/modules/quickcharge/module.prop matches"。
sd_prop_has_nul() {
    local f="$1"
    [ -f "$f" ] || return 1
    [ "$(tr -d '\000' <"$f" 2>/dev/null | wc -c)" -ne "$(wc -c <"$f" 2>/dev/null)" ]
}

# 有 NUL 就转回 UTF-8。BOM 有无、大小端都可能，逐个试；iconv 缺失或全失败时
# 退化成删 NUL（只对纯 ASCII 内容正确）。原文件留一份 .utf16.bak。
sd_prop_fix() {
    local f="${1:-$MODDIR/module.prop}" t enc="" ok=0
    sd_prop_has_nul "$f" || return 0
    mkdir -p "$SD_DATA" 2>/dev/null
    t="$SD_DATA/.prop.$$.tmp"
    if command -v iconv >/dev/null 2>&1; then
        for enc in UTF-16 UTF-16LE UTF-16BE; do
            iconv -f "$enc" -t UTF-8 "$f" >"$t" 2>/dev/null || continue
            [ -s "$t" ] || continue
            sd_prop_has_nul "$t" && continue
            # U+FFFD 说明编码猜错了，中文会变问号，宁可换下一种
            grep -q "$(printf '\357\277\275')" "$t" 2>/dev/null && continue
            ok=1; break
        done
    fi
    if [ "$ok" != 1 ]; then
        enc=""
        tr -d '\000' <"$f" >"$t" 2>/dev/null
        if [ -s "$t" ] && ! sd_prop_has_nul "$t"; then ok=1; fi
    fi
    if [ "$ok" = 1 ]; then
        cp -f "$f" "$f.utf16.bak" 2>/dev/null
        mv -f "$t" "$f" 2>/dev/null
        _sd_emit W prop "module.prop 不是 UTF-8（${enc:-删 NUL}），已转回，原件存为 module.prop.utf16.bak"
    fi
    rm -f "$t" 2>/dev/null
    return 0
}

# 统一走 -a：即使修复失败也不让 "Binary file ... matches" 混进版本号
sd_prop_get() {
    local k="$1" f="${2:-$MODDIR/module.prop}"
    [ -f "$f" ] || return 1
    sd_prop_fix "$f"
    grep -a "^$k=" "$f" 2>/dev/null | head -1 | cut -d= -f2-
}

# 通道判定：两个包共用同一份脚本，靠 module.prop 的 channel 决定谁来跑。
# 3.1.2~3.1.3 的 shell 包误带了 bin/qcmon，service.sh 见到就 exec，
# 结果 shell 版实际跑的是 C 守护，shell 侧的修复对这批用户完全没生效。
# 现在只认显式 channel=c，残留的二进制一律不碰。
sd_channel() {
    local c=""
    [ -n "${SD_CHANNEL:-}" ] || SD_CHANNEL=$(sd_prop_get channel)
    c=$SD_CHANNEL
    case "$c" in c|C) printf 'c' ;; *) printf 'shell' ;; esac
}

sd_use_c() {
    [ "$(sd_channel)" = c ] || return 1
    [ -x "$MODDIR/bin/qcmon" ] || return 1
    "$MODDIR/bin/qcmon" -v >/dev/null 2>&1
}

sd_sync_desc() {
    [ -n "${MODDIR:-}" ] && [ -f "$MODDIR/module.prop" ] || return 0
    sd_prop_fix
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
        printf '# 平台: %s  温度模式: %s  伪装: %s℃  core: %s  noncore: %s\n' \
            "$_sd_plat" "$(sd_state_get temp_mode off)" \
            "$(sd_state_int shell_temp 30 20 33)" \
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

        line=$(printf '[%4ss] %-9s 电池 %3s℃  %5smA  %5smV  %4sW' \
            "$i" "${st:-?}" "${bt:--}" "$cim" "$cvm" "$lim")

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
    printf '  1. 电池远低于墙、电流却比同电量的平时低 → 跑 tiers，看是 thermal HAL 还是 cool_down 在压\n'
    printf '  2. 电流隔几秒掉一截再爬回 → 对照 board 里的 charger-therm，多半是充电 IC 自己收的\n'
    printf '  3. core 全是固定值且充电时电流持续偏低 → 核心伪装让系统放开 CPU，真实功耗抢了充电功率\n'
    printf '  4. board 里 charger-therm 接近 80-85℃ 而电池才 35℃ → 降档来自充电 IC 自身保护，不是温度墙\n'
}
