#!/system/bin/sh
# Quick Charge (QC) — core/state.sh
# 状态：state.conf 的唯一读写入口。
#
# 设计约束：
#   1) 键名集中定义。旧实现用 eval 无条件接住任何键，拼错一个字母既不报错
#      也读不出来，面板写进去的值等于扔进黑洞 —— 这类漂移只能靠人眼发现。
#      现在不认识的键记 W 并保留（不丢数据），但至少日志里能看见。
#   2) 读完立刻把日志级别交给 log 层（qc_log_level），否则加载之前的日志
#      全被丢弃。这是 3.1.17「清理锁日志从不出现」的直接原因。
#   3) 写入走 mkdir 锁 + 临时文件 + rename，避免 action.sh 与守护同时写
#      把文件写坏（旧代码已经在做，保留）。

# 已知键。新增键必须同时出现在这里与 sd_state_get，否则 load 时会告警。
_qc_key_known() {
    case "$1" in
        schema|temp_mode|off_manual|shell_temp|shell_temp_manual|core_temp|noncore_temp|\
curve_offset|defrev|log_level|tick|hz|hz_prev_peak|hz_prev_min|hz_hard|hz_prev_mcfr|\
power_scale|cells_mode|batt_spoof|chg_unlock|overrides_off|overrides_manual)
            return 0 ;;
    esac
    return 1
}

sd_state_load() {
    _sd_st_loaded=1
    _st_temp_mode=""; _st_off_manual=""; _st_shell_temp=""; _st_core_temp=""; _st_noncore_temp=""
    _st_curve_offset=""
    _st_log_level=""; _st_tick=""; _st_defrev=""
    _st_hz=""; _st_hz_prev_peak=""; _st_hz_prev_min=""; _st_hz_hard=""; _st_hz_prev_mcfr=""; _st_power_scale=""
    _st_cells_mode=""; _st_batt_spoof=""
    _st_schema=""
    if [ ! -f "$SD_STATE" ]; then
        _st_log_level=1
        qc_log_level 1
        return 0
    fi
    local k v _unknown=""
    while IFS='=' read -r k v; do
        case "$k" in
            ''|*[!a-z_]*) continue ;;
            schema)   _st_schema=$v ;;
            log_level) _st_log_level=$v ;;
            *)
                if _qc_key_known "$k"; then
                    eval "_st_$k=\$v"
                else
                    # 保留值，但记下来：多半是拼错或旧版本残留
                    eval "_st_$k=\$v"
                    _unknown="$_unknown $k"
                fi ;;
        esac
    done 2>/dev/null <"$SD_STATE"
    [ -n "$_unknown" ] && sd_warn state "state.conf 有未知键:$_unknown（保留但不会被读取）"
    case "$_st_log_level" in 0|1|2|3|4) ;; *) _st_log_level=1 ;; esac
    qc_log_level "$_st_log_level"
    return 0
}

sd_state_get() {
    [ "$_sd_st_loaded" = 1 ] || sd_state_load
    case "$1" in
        schema)         printf '%s' "${_st_schema:-${2:-2}}" ;;
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
    _qc_key_known "$k" || sd_warn state "写入未知键 $k=$v（该键不会被读取，检查拼写）"
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
