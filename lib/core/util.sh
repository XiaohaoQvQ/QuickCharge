#!/system/bin/sh
# Quick Charge (QC) — core/util.sh
# 由 lib/qc.sh 拆分而来，函数体与 3.1.18 行为等价。

sd_file_sum() {
    local f="$1" h="" m=""
    [ -f "$f" ] || { printf '缺失'; return 0; }
    h=$(md5sum "$f" 2>/dev/null | cut -c1-8)
    [ -n "$h" ] || h=$(cksum "$f" 2>/dev/null | awk '{printf "%08x", $1}')
    m=$(date -r "$f" '+%m-%d %H:%M' 2>/dev/null)
    [ -n "$m" ] || m=$(stat -c %y "$f" 2>/dev/null | cut -c6-16)
    printf '%s@%s' "${h:-?}" "${m:-?}"
}

# 一份可比较的代码身份：守护启动时写进 run/daemon.ver，之后随时拿磁盘上的
# 现算值来比。bin/qcmon 也算进去 —— C 包有只重编二进制的版本，光比脚本会漏。

sd_code_ver() {
    local m s
    m="${MODDIR:-${SD_MODDIR:-}}"
    [ -n "$m" ] && [ -f "$m/service.sh" ] || { printf 'unknown'; return 0; }
    s="service.sh=$(sd_file_sum "$m/service.sh") lib/qc.sh=$(sd_file_sum "$m/lib/qc.sh")"
    [ -f "$m/bin/qcmon" ] && s="$s bin/qcmon=$(sd_file_sum "$m/bin/qcmon")"
    printf '%s' "$s"
}

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

# 单调时钟（秒）。开机阶段的「是不是本次开机」一律用它判断，不用墙钟：
# sd_boot_ts 是 now - uptime，NTP 一旦把时钟往前跳，早先写的文件就会被
# 当成「上一次开机留下的」。uptime 只增不减、重启归零，没有这个问题。
qc_up() {
    local u=""
    read -r u _ 2>/dev/null </proc/uptime || u=""
    [ -n "$u" ] || u=$(cat /proc/uptime 2>/dev/null)
    u=${u%% *}
    u=${u%%.*}
    case "$u" in ''|*[!0-9]*) u=0 ;; esac
    printf '%s' "$u"
}

# $1 = 带 up= 标记的文件。0 = 本次开机写的。
# 新格式（3.2 起）：up 不大于当前 uptime（否则说明重启过），且不过于陈旧。
# 旧格式（3.2 之前写的，没有 up=）：退回 mtime 与开机时刻比较。
# 过渡期必须留着这条回退，否则升级后第一次开机、以及任何外部构造的
# phase 文件都会被判成「不是本次」，白跑一遍重建。
qc_phase_fresh() {
    local f="${1:-$SD_DATA/phase.pfs}" up now
    [ -f "$f" ] || return 1
    up=$(sed -n 's/^up=\([0-9]\{1,\}\).*/\1/p' "$f" 2>/dev/null | head -1)
    # up= 不一定在行首（旧格式 at= 在前），再按「空白 + up=」找一次
    [ -n "$up" ] || up=$(sed -n 's/.*[[:space:]]up=\([0-9]\{1,\}\).*/\1/p' "$f" 2>/dev/null | head -1)
    if [ -z "$up" ]; then
        now=$(sd_boot_ts)
        [ "${now:-0}" -gt 0 ] || return 0
        [ "$(sd_file_mtime "$f")" -ge "$now" ]
        return $?
    fi
    now=$(qc_up)
    [ "$now" -ge "$up" ] || return 1
    [ $((now - up)) -le 86400 ] || return 1
    return 0
}

# 落一阶段痕迹。lib 还未加载也能用（post-fs-data 顶部自带一份同名简易版）。
# up= 是给 qc_phase_fresh 的判据，at= 只用于人类阅读。
qc_phase_note() {
    local file="$1" step="$2"
    mkdir -p "${file%/*}" 2>/dev/null
    printf 'up=%s at=%s pid=%s step=%s moddir=%s cwd=%s argv0=%s\n' \
        "$(qc_up)" "$(date +%s 2>/dev/null)" "$$" "$step" "${MODDIR:-?}" \
        "$(pwd 2>/dev/null)" "$0" >"$file" 2>/dev/null
    return 0
}

sd_valid_temp() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 20 ] && [ "$1" -le 100 ]
}

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

_sd_clamp() {
    local v="$1"
    case "$v" in ''|*[!0-9]*) _sd_rv="$4"; return 0 ;; esac
    if [ "$v" -lt "$2" ] || [ "$v" -gt "$3" ]; then
        _sd_rv="$4"
        return 0
    fi
    _sd_rv="$v"
}

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
