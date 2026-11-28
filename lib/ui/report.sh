#!/system/bin/sh
# Quick Charge (QC) — ui/report.sh
# 由 lib/qc.sh 拆分而来，函数体与 3.1.18 行为等价。

sd_dump_env() {
    local dev rom kver zones emul sentinel stype stemp _e _sh _emul_n _emul_head
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
    fi

    _sd_emit I env "device=${dev:-?} rom=${rom:-?} kernel=${kver:-?}"
    local mv cv
    mv=$(sd_prop_get version)
    cv=""
    sd_use_c && cv=$("$MODDIR/bin/qcmon" -v 2>/dev/null | head -1)
    _sd_emit I env "module=${mv:-?} channel=$(sd_channel) daemon=${cv:-shell}"
    # 代码指纹放在 env 里，因为这里是 boot 段每次必跑的。以前它打在 sd_daemon
    # 的启动日志里，而「守护已在运行，跳过」那条分支根本进不到 sd_daemon ——
    # 3.1.14 的 PLG110 日志（装的 3.1.14、跑的是 3.1.11）就是这么被藏的。
    _sd_emit I env "代码指纹 $(sd_code_ver)"
    sd_plat_resolve
    # 「存在/候选」两个数一起给：只写一个数时，启动早期那个 0 会被读成
    # 「这台机器没有电流节点」，3.1.12 的根因报告就是这么误判的。
    local cn ce
    # 候选表必须在本进程里填：sd_curr_nodes 跑在 $(...) 子 shell 里，
    # 它内部 _sd_curr_prepare 填的 _sd_curr_nodes 出了子 shell 就没了。
    # 只把两行顺序调过来没用 —— 3.1.13 的日志一直是 1/0，根因在这里。
    _sd_curr_prepare
    cn=$(sd_curr_nodes 2>/dev/null | wc -l | tr -d ' ')
    ce=$(printf '%s' "$_sd_curr_nodes" | wc -w | tr -d ' ')
    [ "$ce" -gt 0 ] 2>/dev/null || ce=0
    _sd_emit I env "soc=${_sd_plat}（${_sd_plat_why}） emul=$_emul_n${_emul_head} shell-temp=$_sh charge-nodes=${cn}/${ce}（存在/候选）"
    _sd_curr_ex=$cn
    # 只给数量，"fcc 节点=none" 就是一句没法追查的结论：到底是哪个节点在、
    # cool_down 能不能读，都在下面两行里。
    if [ "$cn" -gt 0 ] 2>/dev/null; then
        # 打全路径：只打文件名的话 battery/current_max 与 usb/current_max 分不开，
        # 而「输入侧节点」与「电池侧节点」正是接管成败的分界线。
        _sd_emit I env "charge nodes 命中=$(sd_curr_nodes 2>/dev/null | tr '\n' ' ')"
    fi
    if sd_cool_node; then
        if sd_read1 "$SD_COOL_NODE"; then
            _sd_emit I env "cool_down=${_sd_rv}（${SD_COOL_NODE}）"
        else
            _sd_emit W env "cool_down 节点存在但读不到（${SD_COOL_NODE}）"
        fi
    else
        _sd_emit I env "cool_down=none（本机没有这个节点，不算失败）"
    fi
    if [ -n "$sentinel" ]; then
        _sd_emit I env "sentinel=$(basename "$sentinel") type=${stype:-?} temp=${stemp:-?}℃"
    else
        _sd_emit I env "sentinel=none（未找到电池/主板温度节点，伪装无法工作）"
    fi
    _sd_emit I env "state=$(sd_state_dump)"

    # 覆盖层状态：一加 15 那次「完全不生效」只能靠「有没有那句未生效」反推，
    # 因为 env 里没有任何可对照的数字。这里直接给四个：产物数、挂载条数、
    # 注入方式、存活判定 —— 一行就能定性，不用推理。
    local _ovn _ovm _ovnm _ovalive
    _ovn=$(find "$SD_OVERRIDES" -type f 2>/dev/null | wc -l | tr -d ' ')
    [ -n "$_ovn" ] 2>/dev/null || _ovn=0
    _ovm=$(awk -v b="$SD_OVERRIDES/" '
        { i = 0
          for (k = 1; k <= NF; k++) if ($k == "-") { i = k; break }
          if (i > 0 && index($4, b) == 1) n++ }
        END { print n + 0 }' /proc/self/mountinfo 2>/dev/null)
    [ -n "$_ovm" ] 2>/dev/null || _ovm=0
    if sd_nm_active; then _ovnm=nomount; else _ovnm=bind; fi
    # 三态：yes / partial / no。partial 以前被并进 yes，看起来「已生效」，
    # 实际只挂上一部分 —— 这一行就是给那类情况留的对照数字。
    _ovalive=$(qc_overrides_state)
    _sd_emit I env "overrides=$_ovn mounts=$_ovm nm=$_ovnm alive=$_ovalive(${_qc_mnt_hit}/${_qc_mnt_all})"

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
    [ "${_sd_lv:-0}" -ge 1 ] || return 0
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
            _sd_chg_emit "定时 $line"
            _sd_chg_at=$now
        fi
        return 0
    fi
    _sd_chg_emit "$why $line"
    _sd_chg_key=$key
    _sd_chg_last=$line
    _sd_chg_at=$now
}

SD_MCFR_KEY=match_content_frame_rate

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
