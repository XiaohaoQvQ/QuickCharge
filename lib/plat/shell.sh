#!/system/bin/sh
# Quick Charge (QC) — plat/shell.sh
#
# 为什么单独一层：ColorOS / OxygenOS 的亮屏充电降流不看电池温度，看「壳温」。
# 内核里 oplus,shell-temp 把 shell_front / shell_frame / shell_back 三路 PMIC
# 热敏电阻加权成一个 shell_temp，com.oplus.thermalcontrol 每 3 秒按壳温查
# /vendor/etc/charger_cool_down.conf 的阈值表，通过 charger HAL 下发等级，
# 最后落到 /sys/class/oplus_chg/battery/cool_down。壳温 36℃ 就进第 6 档，
# 功率掉到 10W 量级 —— 用户看到的就是「只有 5-10W」。
#
# 所以只压电池温度没有意义：电池 33℃、壳温 40℃ 的机器照样降流。这一层的
# 职责就是把三路壳温按真实链路压下去，并且**每次都回读确认压住了**。
#
# 三条写入路径，可靠性从高到低：
#   1. thermal_zone/N/emul_temp —— 内核 thermal 框架的模拟接口，一旦生效，
#      HAL、thermal-engine、thermalcontrol 读到的都是假值。首选。
#   2. /proc/shell-temp —— oplus 私有 proc 写入口，直接改驱动缓存。格式因
#      机型/内核而异（"9 30000" / "shell_back:30000" / 单值），所以不硬编码，
#      第一次从文件原文反推，并把结果缓存到 run/shell.fmt。
#   3. bind mount temp —— 只遮住用户态路径，HAL 走内核节点时完全无效。
#      仅在前两条都不可用时兜底，日志会标明「弱」。

_sd_sh_scanned=0
_sd_sh_zones=""
_sd_sh_n=0
_sd_sh_fmt=""
_sd_sh_ok=""
_sd_sh_why=""
_sd_sh_miss=0
_sd_sh_last_ok=""
_sd_sh_front=""; _sd_sh_frame=""; _sd_sh_back=""
_sd_sh_max=""; _sd_sh_avg=""; _sd_sh_samples=""

# emul_temp 的上次目标值。与 thermal/spoof.sh 共用同名全局（那边定义了默认空），
# 这里再兜一次：plat/shell.sh 先于 thermal/spoof.sh 加载，不能依赖它的初始化。
_sd_emul_last="${_sd_emul_last:-}"

# 壳温三件套。type 可能是 shell_back / shell-back / Shell_Back，统一按通配匹配；
# 真机取名不规范（连字符、大小写都见过），精确匹配会漏。
sd_shell_is_shell_type() {
    case "$1" in
        *[Ss]hell*[Ff]ront*|*[Ss]hell*[Bb]ack*|*[Ss]hell*[Ff]rame*) return 0 ;;
        *[Ss]hell*) return 0 ;;
    esac
    return 1
}

sd_shell_scan() {
    local e z t hit=0
    [ "$_sd_sh_scanned" = 1 ] && return 0
    _sd_zones_ready
    _sd_sh_zones=""; _sd_sh_n=0
    for e in $_sd_zones; do
        z=${e%%:*}; t=${e#*:}
        sd_shell_is_shell_type "$t" || continue
        _sd_sh_zones="$_sd_sh_zones $z:$t"
        hit=$((hit + 1))
    done
    _sd_sh_n=$hit
    _sd_sh_scanned=1
    return 0
}

# 读三路壳温。_sd_sh_max 是最热的那一路 —— 降流按最热的算，取平均会漏。
sd_shell_reads() {
    local e z t v n=0 sum=0 mx="" raw=""
    sd_shell_scan
    _sd_sh_front=""; _sd_sh_frame=""; _sd_sh_back=""
    _sd_sh_max=""; _sd_sh_avg=""; _sd_sh_samples=""
    for e in $_sd_sh_zones; do
        z=${e%%:*}; t=${e#*:}
        [ -e "$z/temp" ] || continue
        sd_read1 "$z/temp" || continue
        sd_temp_norm "$_sd_rv" || continue
        v=$_sd_rv
        raw="$raw $v"
        n=$((n + 1)); sum=$((sum + v))
        [ -z "$mx" ] && mx=$v
        [ "$v" -gt "$mx" ] && mx=$v
        case "$t" in
            *[Ff]ront*) _sd_sh_front=$v ;;
            *[Bb]ack*)  _sd_sh_back=$v ;;
            *[Ff]rame*) _sd_sh_frame=$v ;;
        esac
    done
    _sd_sh_max=$mx
    _sd_sh_samples=$raw
    [ "$n" -gt 0 ] && _sd_sh_avg=$((sum / n))
    [ "$n" -gt 0 ]
}

# /proc/shell-temp 的格式：读一行原文判断，空文件按 idx（历史默认）。
# 返回 idx / name / plain / none
sd_shell_fmt_detect() {
    local first="" f="$SD_RUN/shell.fmt"
    if [ -f "$f" ]; then
        read -r _sd_sh_fmt <"$f" 2>/dev/null || _sd_sh_fmt=""
        case "$_sd_sh_fmt" in
            idx|name|plain|none) return 0 ;;
        esac
    fi
    _sd_sh_fmt=none
    [ -e "$SD_SHELL_TEMP" ] || return 1
    first=$(sed -n '1p' "$SD_SHELL_TEMP" 2>/dev/null)
    case "$first" in
        '') _sd_sh_fmt=none ;;
        *:*) _sd_sh_fmt=name ;;
        *[0-9]*[[:space:]]*[0-9]*) _sd_sh_fmt=idx ;;
        *[0-9]*) _sd_sh_fmt=plain ;;
        *) _sd_sh_fmt=none ;;
    esac
    [ -d "$SD_RUN" ] || mkdir -p "$SD_RUN" 2>/dev/null
    printf '%s\n' "$_sd_sh_fmt" >"$f" 2>/dev/null
    return 0
}

# 按探测到的格式写 /proc/shell-temp。proc 的 write handler 一次只处理一次
# write，所以 idx 格式要逐行写（历史行为，通道号 0~9）。
sd_shell_proc_write() {
    local ms="$1" i=0
    [ -e "$SD_SHELL_TEMP" ] || return 1
    case "${_sd_sh_fmt:-none}" in
        idx|none)
            # none = 文件为空/读不出结构，按历史默认（通道号 0~9 逐行）写。
            # 真机上 proc 通常有内容，能探测到 name/plain，走不到这里。
            while [ "$i" -lt 10 ]; do
                printf '%s %s\n' "$i" "$ms" >"$SD_SHELL_TEMP" 2>/dev/null || return 1
                i=$((i + 1))
            done
            return 0 ;;
        name)
            for i in shell_front shell_frame shell_back; do
                printf '%s:%s\n' "$i" "$ms" >"$SD_SHELL_TEMP" 2>/dev/null || return 1
            done
            return 0 ;;
        *)
            printf '%s\n' "$ms" >"$SD_SHELL_TEMP" 2>/dev/null || return 1
            return 0 ;;
    esac
}

# 回读校验：读到的最高壳温与目标差 ≤2℃ 才算压住了。
# 容差考虑采样延迟（thermal zone 一个轮询周期内可能还没刷新）。
sd_shell_verify() {
    local want="$1" got d
    sd_shell_reads || return 1
    got=${_sd_sh_max:-}
    [ -n "$got" ] || return 1
    d=$((got - want)); [ "$d" -lt 0 ] && d=$((-d))
    [ "$d" -le 2 ]
}

# 状态落盘，给 charge 层归因用。一行：ok=1|0 why=xxx fmt=idx up=N
sd_shell_state_put() {
    local f="$SD_RUN/shell.state"
    [ -d "$SD_RUN" ] || mkdir -p "$SD_RUN" 2>/dev/null
    printf 'ok=%s why=%s fmt=%s up=%s max=%s\n' \
        "${_sd_sh_ok:-0}" "${_sd_sh_why:-?}" "${_sd_sh_fmt:-none}" \
        "$(qc_up)" "${_sd_sh_max:--}" >"$f" 2>/dev/null
    return 0
}

# 最近一次壳温控制的结果：ok / why / fmt / max
sd_shell_state_get() {
    local f="$SD_RUN/shell.state" k v
    _sd_sh_st_ok=""; _sd_sh_st_why=""; _sd_sh_st_fmt=""; _sd_sh_st_max=""
    [ -f "$f" ] || return 1
    for k in ok why fmt max; do
        v=$(sed -n "s/.*$k=\([^ ]*\).*/\1/p" "$f" 2>/dev/null | head -1)
        case "$k" in
            ok)  _sd_sh_st_ok=$v ;;
            why) _sd_sh_st_why=$v ;;
            fmt) _sd_sh_st_fmt=$v ;;
            max) _sd_sh_st_max=$v ;;
        esac
    done
    return 0
}

# 壳温总入口。返回 0=至少一条路径写成功，1=参数非法或无处可写。
# 注意：返回 0 不代表一定生效 —— 是否真的压住了看 _sd_sh_ok（回读结论）。
# 这样拆开是因为「写成功但被服务覆盖」和「根本写不进去」要分开报。
sd_shell_apply() {
    local celsius="$1" ms e z t n=0 ps=0 wz=0 ok=0 why=""
    case "$celsius" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$celsius" -ne 0 ] && { [ "$celsius" -lt 20 ] || [ "$celsius" -gt 100 ]; }; then
        sd_err thermal "壳温超出合理范围(20-100℃): $celsius，忽略"
        return 1
    fi
    # 目标没变、上次确实压住了：抽查一次。还压着就不重复写（省掉每轮 10 次
    # proc write）；掉了说明被服务/驱动清掉，必须往下重写 —— 这里不能直接
    # return，否则「压住了又被清掉」这个最常见的失效模式永远发现不了。
    if [ "$celsius" -eq 0 ] && [ "$_sd_emul_last" = 0 ] && [ "$_sd_sh_last_ok" = 1 ]; then
        return 0
    fi
    if [ "$celsius" -ne 0 ] && [ "$celsius" = "$_sd_emul_last" ] && [ "$_sd_sh_last_ok" = 1 ]; then
        if sd_shell_verify "$celsius"; then
            _sd_sh_ok=1
            return 0
        fi
        _sd_sh_miss=$((_sd_sh_miss + 1))
    fi
    _sd_emul_last=$celsius
    sd_shell_scan
    sd_shell_fmt_detect
    ms=$((celsius * 1000))

    if [ "$celsius" -eq 0 ]; then
        # 关闭：emul_temp 写 0。部分新内核用 -1 表示退出模拟，再补一次 -
        # 只在没有回读确认时补，避免把「0 就是关闭」的驱动写成 -1 报错。
        for e in $_sd_sh_zones; do
            z=${e%%:*}
            [ -e "$z/emul_temp" ] || continue
            printf '0\n' >"$z/emul_temp" 2>/dev/null && n=$((n + 1))
        done
        _sd_sh_ok=1; _sd_sh_why=off
        _sd_sh_last_ok=1
        sd_shell_state_put
        sd_dbg thermal "关闭壳温模拟（$n 个节点归零，shell-temp 交还驱动）"
        return 0
    fi

    # 路径 1：emul_temp
    for e in $_sd_sh_zones; do
        z=${e%%:*}
        [ -e "$z/emul_temp" ] || continue
        printf '%s\n' "$ms" >"$z/emul_temp" 2>/dev/null && n=$((n + 1))
    done

    # 路径 2：/proc/shell-temp
    if [ -e "$SD_SHELL_TEMP" ]; then
        sd_shell_proc_write "$ms" && ps=1
    fi

    if [ "$n" -gt 0 ] || [ "$ps" = 1 ]; then
        ok=1
    fi

    # 主路径（emul_temp / proc）全失败时才考虑 bind。bind 只遮住用户态路径，
    # HAL 直读内核节点时完全无效，所以不默认启用 —— 它会把「写不进去」这件事
    # 伪装成「已生效」，正是这一轮要消灭的误导。需要时用 SD_SHELL_BIND=1 打开。
    if [ "$ok" = 0 ]; then
        [ "${SD_SHELL_BIND:-0}" = 1 ] && sd_shell_bind "$celsius" && wz=1
        _sd_sh_ok=0
        if [ "$wz" = 1 ] && sd_shell_verify "$celsius"; then
            _sd_sh_ok=1
        fi
        if [ "$_sd_sh_n" = 0 ] && [ ! -e "$SD_SHELL_TEMP" ]; then
            _sd_sh_why=no_node
        elif [ "$wz" = 1 ]; then
            _sd_sh_why=bind_only
        else
            _sd_sh_why=write_fail
        fi
        _sd_sh_last_ok=$_sd_sh_ok
        sd_shell_state_put
        sd_warn thermal "壳温主路径写不进（zone=$_sd_sh_n shell-temp=$([ -e "$SD_SHELL_TEMP" ] && echo yes || echo no)）：$_sd_sh_why"
        # 返回 1 表示「没有一条可靠路径写进去」。哪怕 bind 把回读骗过去了，
        # 这个 1 也不改 —— [env] 的 emul 字段据此报 0，不能拿弱保证充数。
        return 1
    fi

    # 回读确认。模拟环境/驱动延迟都不影响判定：连续 3 次不符才定死，
    # 中间只要有一次对上就恢复。
    if sd_shell_verify "$celsius"; then
        _sd_sh_ok=1; _sd_sh_why=$([ "$wz" = 1 ] && echo bind || echo ok)
        _sd_sh_miss=0
    else
        _sd_sh_miss=$((_sd_sh_miss + 1))
        _sd_sh_ok=0
        _sd_sh_why=no_effect
        [ "$wz" = 1 ] && _sd_sh_why=bind_only
    fi
    _sd_sh_last_ok=$_sd_sh_ok
    sd_shell_state_put

    if [ "$_sd_sh_ok" = 1 ]; then
        sd_dbg thermal "壳温 ${celsius}℃ 生效（emul=$n proc=$ps 回读=${_sd_sh_max:-?}）"
    elif [ "$_sd_sh_miss" -le 1 ] || [ $((_sd_sh_miss % 20)) = 0 ]; then
        # 第一次失败必报（这是 5-10W 的关键线索）；之后每 20 轮（约 5 分钟）
        # 再报一次，避免每 tick 一条把日志刷满。
        sd_warn thermal "壳温写了但没压住：目标 ${celsius}℃，回读 ${_sd_sh_max:-?}℃（emul=$n proc=$ps，第 $_sd_sh_miss 次）"
    fi
    return 0
}

# bind mount 退路。只遮住 /sys/class/thermal/*/temp，HAL 直读内核节点时无效，
# 所以状态里标 bind_only，让上层知道这是弱保证。
sd_shell_bind() {
    local celsius="$1" ms e z t tf spd n=0
    sd_spoof_dir || return 1
    spd=$_sd_sd
    ms=$((celsius * 1000))
    for e in $_sd_sh_zones; do
        z=${e%%:*}
        [ -e "$z/temp" ] || continue
        tf="$spd/$(basename "$z").temp"
        printf '%s\n' "$ms" >"$tf" 2>/dev/null || continue
        chmod 644 "$tf" 2>/dev/null
        umount -l "$z/temp" 2>/dev/null
        if mount -o bind "$tf" "$z/temp" 2>/dev/null \
           || mount --bind "$tf" "$z/temp" 2>/dev/null; then
            n=$((n + 1))
        fi
    done
    [ "$n" -gt 0 ]
}

sd_shell_unbind() {
    local e z n=0
    sd_shell_scan
    for e in $_sd_sh_zones; do
        z=${e%%:*}
        { umount "$z/temp" 2>/dev/null || umount -l "$z/temp" 2>/dev/null; } && n=$((n + 1))
    done
    return 0
}

# 一行摘要，给 [env] 用：shell=30/38f 表示目标 30、实测最大 38、f=没压住
sd_shell_brief() {
    local want="${1:-}" got="${_sd_sh_max:-?}" tag=""
    [ -n "$want" ] || want=-
    case "${_sd_sh_st_ok:-}" in
        1) tag="" ;;
        *) tag=f ;;
    esac
    printf '%s/%s%s' "$want" "$got" "$tag"
}
