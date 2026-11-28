#!/system/bin/sh
# Quick Charge (QC) — feat/charge.sh
# 由 lib/qc.sh 拆分而来，函数体与 3.1.18 行为等价。

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
_sd_pwr_log=""         # 上一次的归因，归因变了也要记一条
_sd_pwr_cause=""

# ---------------------------------------------------------------- 功率归因
# 5-10W 有五种来源，日志里必须能分开，否则只能靠猜：
#   spoof_failed  壳温没压住 -> thermalcontrol 按真实壳温降流（最常见）
#   thermal       壳温压住了仍降流 -> 来源不是壳温（电池温度 / HAL / 手动）
#   low_power     cool_down=1：ColorOS 的「仅 10W 充电」开关被打开
#   ok            cool_down=0，当前没被降流
#   spoof_off     温度伪装没开，本来就不干预
# 依据：LineageOS android_hardware_oplus 的 charger-cool-down 实现与
# sys_thermal_control_config.xml 的档位表（36℃ 进第 6 档），以及
# /sys/class/oplus_chg/battery/cool_down 的实际取值。
sd_pwr_cause() {
    local cool="${1:-}" mode
    _sd_pwr_cause=""
    mode=$(sd_state_get temp_mode off)
    case "$mode" in off|'') _sd_pwr_cause=spoof_off; return 0 ;; esac
    case "$cool" in
        ''|*[!0-9]*) _sd_pwr_cause=unknown; return 0 ;;
    esac
    if [ "$cool" = 0 ]; then
        _sd_pwr_cause=ok
        return 0
    fi
    if [ "$cool" = 1 ]; then
        _sd_pwr_cause=low_power
        return 0
    fi
    sd_shell_state_get >/dev/null 2>&1
    if [ "${_sd_sh_st_ok:-0}" != 1 ]; then
        _sd_pwr_cause=spoof_failed
    else
        _sd_pwr_cause=thermal
    fi
    return 0
}

# 归因一行：[chg] cool=6 cause=spoof_failed shell=30/38
sd_pwr_brief() {
    local cool="${1:-?}"
    printf 'cool=%s cause=%s shell=%s/%s' \
        "$cool" "${_sd_pwr_cause:-?}" \
        "$(sd_state_get shell_temp 30)" "${_sd_sh_st_max:-${_sd_sh_max:-?}}"
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

    if ! sd_read1 "$SD_COOL_NODE"; then
        if [ "$_sd_cool_log" != readfail ]; then
            sd_warn charge "cool_down 节点存在但读不到（$SD_COOL_NODE），本机降流状态未知"
            _sd_cool_log=readfail
        fi
        return 0
    fi
    cur=$_sd_rv
    case "$cur" in ''|*[!0-9]*) return 0 ;; esac

    sd_pwr_cause "$cur"
    # 档位没变、归因也没变：不重复记
    [ "$cur" = "$_sd_cool_log" ] && [ "$_sd_pwr_cause" = "$_sd_pwr_log" ] && return 0
    _sd_cool_log=$cur
    _sd_pwr_log=$_sd_pwr_cause

    if [ "$cur" = 0 ]; then
        sd_info charge "$(sd_pwr_brief "$cur")（当前没被降流）"
    else
        sd_info charge "$(sd_pwr_brief "$cur")（亮屏降流档位，只记录不写入）"
    fi
    case "$_sd_pwr_cause" in
        spoof_failed)
            sd_warn charge "壳温没压住，降流是它触发的：target=$(sd_state_get shell_temp 30)℃ 实测=${_sd_sh_st_max:-?}℃ reason=${_sd_sh_st_why:-?}" ;;
        low_power)
            sd_warn charge "cool_down=1 = ColorOS 的「仅 10W 充电」开关被打开，与温度无关；关掉它才会恢复" ;;
    esac
    return 0
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
#     三秒后 18W 掉到 9.7W；3.1.13 起 sd_cool_tick 只读，一个字节都不写。
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
