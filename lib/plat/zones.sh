#!/system/bin/sh
# Quick Charge (QC) — plat/zones.sh
# 由 lib/qc.sh 拆分而来，函数体与 3.1.18 行为等价。

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
