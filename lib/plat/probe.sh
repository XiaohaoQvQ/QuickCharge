#!/system/bin/sh
# Quick Charge (QC) — plat/probe.sh
# 由 lib/qc.sh 拆分而来，函数体与 3.1.18 行为等价。

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

sd_plat_resolve() {
    _sd_plat_probe
    # 平台从 other 认对之后，候选表要重算。_sd_curr_prepare 只填一次，第一次
    # 填的时候 plat 若还是 other，MTK 那 5 个候选（input_current_limit、
    # charger/current_max、mtk-master/slave-charger、mtk-battery）就永久缺失，
    # 之后认对也不补 —— 8 次重试看起来在、实际被缓存让成了空转。
    # 只在「建表时 plat 是 other/未知」时重算，SD_CURR_NODES 覆盖的表不动。
    [ -n "$_sd_curr_nodes" ] || return 0
    [ "$_sd_plat" = other ] && return 0
    case "$_sd_curr_plat" in
        other|"")
            _sd_curr_nodes=""; _sd_curr_plat=""
            # 重建成功不留痕的话，日志里和「压根没重建」长得一模一样，
            # 现场没法判断这次修复到底跑起来没有。
            sd_info charge "平台已认对（$_sd_plat ${_sd_plat_why:-}），候选表按新平台重算" ;;
    esac
    return 0
}

_sd_plat_probe() {
    # 认出 mtk/qcom 就定死；other 多半是启动早期 getprop 还没就绪，不缓存。
    # 3.1.12 及以前 `[ -n "$_sd_plat" ]` 把 other 也定死，于是 MTK 那 5 个候选
    # 节点永远拿不到 —— 这才是真正的"缓存了坏结果"。试满 8 次还是 other 才认命。
    case "$_sd_plat" in mtk|qcom) return 0 ;; esac
    # 预算按「时间窗」不按「调用次数」：_sd_curr_prepare 一轮可能被调多次
    # （sd_scr_fcc_node 每轮都调），按次数算 8 次在一个 tick 内就烧完，等于
    # 没给启动早期留窗口 —— 3.1.15 的 P2 只修了「建表前先 resolve」，这一半没修。
    local _now
    _now=$(date +%s 2>/dev/null)
    case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
    [ -n "${_sd_plat_t0:-}" ] || _sd_plat_t0=$_now
    [ "$_now" -gt 0 ] && [ $((_now - ${_sd_plat_t0:-0})) -ge 300 ] && return 0
    [ "${_sd_plat_try:-0}" -ge 400 ] && return 0
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

sd_curr_watch() {
    local n ce
    _sd_curr_prepare
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
    # 早退不能挡在 sd_plat_resolve 前面：表建好之后平台才认对的话，MTK 那 5 个
    # 候选节点就永久缺失。3.1.15 只把 resolve 挪到建表之前，管不到这种情形。
    # SD_CURR_NODES 是用户显式覆盖，不探测。
    if [ -z "${SD_CURR_NODES:-}" ]; then
        case "$_sd_plat" in
            mtk|qcom) ;;
            *) sd_plat_resolve ;;
        esac
    fi
    [ -n "$_sd_curr_nodes" ] && return 0
    if [ -n "${SD_CURR_NODES:-}" ]; then
        _sd_curr_nodes=$(printf '%s' "$SD_CURR_NODES" | tr ',' ' ')
        _sd_curr_plat=override
    else
        # 先定平台再建表：sd_plat_resolve 会在平台从 other 认对时把旧表清掉，
        # 建完再调它等于刚填好就被清空（_sd_curr_plat 那时还是空）。
        sd_plat_resolve
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
        if [ "$_sd_plat" = mtk ]; then
            _sd_curr_nodes="$SD_PS/battery/input_current_limit \
$SD_PS/charger/current_max \
$SD_PS/mtk-master-charger/current_max \
$SD_PS/mtk-slave-charger/current_max \
$SD_PS/mtk-battery/current_max \
$_sd_curr_nodes"
        fi
        _sd_curr_plat=$_sd_plat
    fi
    return 0
}

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
