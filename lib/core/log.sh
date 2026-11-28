#!/system/bin/sh
# Quick Charge (QC) — core/log.sh
# 日志：唯一写入口。级别 0~4，见下。
#
# 设计约束（3.1.17 的教训）：
#   原来的 _sd_lv 默认 0，要等 sd_state_load 读完 state.conf 才是 1。
#   在这之前调 sd_info 全部被静默丢弃 —— post-fs-data 清理残留锁那段
#   写在 load 之前，日志里永远看不到，看起来像「这段代码没跑」。
#
#   现在：级别未就绪时先按 need 分级攒在内存，qc_log_level 定级后一次性
#   补写。E 级（need=0）不等，立刻落盘 —— 启动早期的错误最需要留证据。
#
# 级别：
#   0 关闭：只有 E 落盘
#   1 事件：启停、插拔、协议/屏幕切换、降流与回写
#   2 详细：每个状态变化一条完整现场
#   3 逐轮：每 tick 的判定细节
#   4 调试：节点级 trace

_qc_log_ready=0
_qc_buf0=""; _qc_buf1=""; _qc_buf2=""; _qc_buf3=""
_qc_buf_n=0
_qc_buf_max=64

# 落盘 + 轮转。need 已由调用方判过。
_qc_log_write() {
    printf '%s\n' "$1" 2>/dev/null >>"$SD_LOG"
    _sd_rot=$(( ${_sd_rot:-0} + 1 ))
    if [ $((_sd_rot & 63)) -eq 0 ] && \
       [ "$(wc -c 2>/dev/null <"$SD_LOG" || echo 0)" -gt 524288 ]; then
        mv -f "$SD_LOG" "$SD_OLD" 2>/dev/null
    fi
    return 0
}

# need 0/1/2/3，text 可多行。
_qc_log_put() {
    local need="$1" text="$2"
    if [ "${_qc_log_ready:-0}" != 1 ]; then
        case "$need" in
            0) _qc_buf0="${_qc_buf0}${text}
" ;;
            1) _qc_buf1="${_qc_buf1}${text}
" ;;
            2) _qc_buf2="${_qc_buf2}${text}
" ;;
            *) _qc_buf3="${_qc_buf3}${text}
" ;;
        esac
        _qc_buf_n=$(( ${_qc_buf_n:-0} + 1 ))
        # 早期刷屏保护：超过上限就丢最细的那档，E/W 永远保留
        if [ "$_qc_buf_n" -gt "$_qc_buf_max" ]; then
            _qc_buf3=""
            _qc_buf_n=$_qc_buf_max
        fi
        [ -n "${SD_VERBOSE:-}" ] && printf '%s\n' "$text"
        return 0
    fi
    [ "${_sd_lv:-0}" -ge "$need" ] || return 0
    _qc_log_write "$text"
    [ -n "${SD_VERBOSE:-}" ] && printf '%s\n' "$text"
    return 0
}

# 级别就绪：把攒下的按级别补写。sd_state_load 读完 state.conf 后调用。
qc_log_level() {
    local v="$1"
    case "$v" in 0|1|2|3|4) ;; *) v=1 ;; esac
    _sd_lv=$v
    _qc_log_ready=1
    [ -n "$_qc_buf0" ] && printf '%s' "$_qc_buf0" >>"$SD_LOG" 2>/dev/null
    [ "$v" -ge 1 ] && [ -n "$_qc_buf1" ] && printf '%s' "$_qc_buf1" >>"$SD_LOG" 2>/dev/null
    [ "$v" -ge 2 ] && [ -n "$_qc_buf2" ] && printf '%s' "$_qc_buf2" >>"$SD_LOG" 2>/dev/null
    [ "$v" -ge 3 ] && [ -n "$_qc_buf3" ] && printf '%s' "$_qc_buf3" >>"$SD_LOG" 2>/dev/null
    _qc_buf0=""; _qc_buf1=""; _qc_buf2=""; _qc_buf3=""; _qc_buf_n=0
    return 0
}

# E=0 W=1 S=2(显示为 I) D=3 I=1
_sd_emit() {
    local lv="$1" tag="$2" need plv
    shift 2
    plv=$lv
    case "$lv" in
        E) need=0 ;;
        W) need=1 ;;
        S) need=2; plv=I ;;
        D) need=3 ;;
        *) need=1 ;;
    esac
    _qc_log_put "$need" "$(date '+%m-%d %H:%M:%S' 2>/dev/null) $plv [$tag] $*"
}

# 充电快照在 2 级是 S（现场），1 级降成 I：用户默认 1 级，把插电/停充锁在
# 2 级等于每份功率反馈的日志里都没有功率（3.1.13 的 PLG110 就是这样）。
_sd_chg_emit() {
    if [ "${_sd_lv:-0}" -ge 2 ]; then _sd_emit S chg "$1"; else _sd_emit I chg "$1"; fi
}

sd_dbg()  { _sd_emit D "$@"; }
sd_info() { _sd_emit I "$@"; }
sd_warn() { _sd_emit W "$@"; }
sd_err()  { _sd_emit E "$@"; }

sd_log_reset() {
    rm -f "$SD_LOG" "$SD_OLD" 2>/dev/null
    # 记下「这份日志从本次开机第几秒开始」。service 靠它判断日志是不是上一轮
    # 留下的 —— 用文件 mtime 比墙钟会在 NTP 跳变时误删或误留。
    printf 'up=%s\n' "$(qc_up)" >"$SD_LOG_UP" 2>/dev/null
    # reset 的语义是「从这一刻重新记录」，攒着的早期行也一并丢掉
    _qc_buf0=""; _qc_buf1=""; _qc_buf2=""; _qc_buf3=""; _qc_buf_n=0
    return 0
}

# 会话分隔。开启时先写会话头，复现完直接导出就是一份能定位的日志。
sd_session() {
    local tag="$1" block
    shift
    block="
======== $(date '+%m-%d %H:%M:%S' 2>/dev/null) | $tag | pid=$$ ========"
    [ "$#" -gt 0 ] && block="$block
  $*"
    _qc_log_put 1 "$block"
    return 0
}

# 当前这份日志是否属于本次开机。
# 有 log.up 就按单调时钟判；没有（升级后第一次、或外部写入）就退回 mtime
# 与开机时刻比较 —— 不能因为「缺少标记」就认定是旧的，否则会把刚写的
# 日志连同「清理残留锁」一起删掉，看起来像那段代码没跑。
sd_log_is_current() {
    [ -f "$SD_LOG" ] || return 0
    if [ -f "$SD_LOG_UP" ]; then
        qc_phase_fresh "$SD_LOG_UP"
        return $?
    fi
    local b
    b=$(sd_boot_ts)
    [ "${b:-0}" -gt 0 ] || return 0
    [ "$(sd_file_mtime "$SD_LOG")" -ge "$b" ]
}

# 切换级别。开启时补一份环境头 + 当前现场，不用等下一次状态变化。
sd_set_log() {
    local v="$1"
    case "$v" in 0|1|2|3|4) ;; *) printf '级别需为 0~4\n'; return 1 ;; esac
    if [ "$v" = 0 ]; then
        sd_info log "日志关闭（级别 0）"
        sd_state_set log_level 0
        qc_log_level 0
        return 0
    fi
    sd_state_set log_level "$v"
    qc_log_level "$v"
    sd_session log "日志开启 level=$v"
    sd_dump_env
    # C 守护下一拍就会打首帧，shell 再打一条只会在同一秒里重复
    if ! sd_daemon_is_c; then
        sd_chg_snapshot 1
    fi
    return 0
}
