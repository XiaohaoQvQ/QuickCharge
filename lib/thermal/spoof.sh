#!/system/bin/sh
# Quick Charge (QC) — thermal/spoof.sh
# 由 lib/qc.sh 拆分而来，函数体与 3.1.18 行为等价。

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
