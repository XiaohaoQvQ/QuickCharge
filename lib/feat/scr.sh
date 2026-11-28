#!/system/bin/sh
# Quick Charge (QC) — feat/scr.sh
# 由 lib/qc.sh 拆分而来，函数体与 3.1.18 行为等价。

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
    local mode bt rc key hot_lim now
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
        Charging) ;;
        Full)
            # 满电时系统自己就在收电流，「亮屏快充」接管或解除都没有意义。
            # 也不能算「本机不支持」：插着线满电放一夜，日志会被这条 W 淹掉
            # （3.1.13 的 PLG110 那 78 条里就混着满电态的）。
            if sd_scr_active; then sd_scr_release; _sd_scr_log=""; fi
            return 0 ;;
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
            _sd_scr_fail_at=0          # 这次成功了，下次失败要立刻记，不用等兜底
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
                # 状态变了记一条；一直不支持就每 30 分钟兜底一条。
                # 按轮记会把日志占满（3.1.13 实测 78 条），按「只记一次」又会
                # 让后来看日志的人以为这事早就过去了。
                now=$(date +%s)
                if [ "$_sd_scr_log" != "fail" ] || \
                   [ $((now - ${_sd_scr_fail_at:-0})) -ge 1800 ]; then
                    sd_warn charge "亮屏快充：本机不支持（无屏幕状态参数，也没有电池侧电流节点）"
                    _sd_scr_log=fail
                    _sd_scr_fail_at=$now
                fi
                printf '1\n' >"$SD_SCR_FAIL" 2>/dev/null
            fi ;;
    esac
    return 0
}


_sd_curr_nodes=""
_sd_curr_plat=""      # 建表时的平台判定；other/空 说明这张表可能是早产的
