#!/system/bin/sh
# Quick Charge (QC) — feat/hz.sh
# 由 lib/qc.sh 拆分而来，函数体与 3.1.18 行为等价。

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
