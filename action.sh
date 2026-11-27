#!/system/bin/sh
# ---------------------------------------------------------------
# Quick Charge (QC) — 源码完全公开，可自由查看、修改、分发。
# 禁止商业用途，禁止用于任何违反法律法规的场景。
# Fully open source. Commercial use and any unlawful use prohibited.
# ---------------------------------------------------------------

sd_usage() {
    cat <<'EOF'
Quick Charge (QC) 控制入口。

  无参数     打印状态（不进入菜单：管理器里执行时没有终端）
  带子命令   供元模块 / 脚本 / WebUI 调用

子命令：
  help                         显示这段帮助
  status                       当前状态
  json                         机器可读状态（JSON，供 WebUI 使用）
  probe                        温度读取自检（温区/电池节点/缓存/决策现场）
  zones                        温区判定全表：type / 语义类 / 是否 core 候选
  check                        适配检查：一次采样，直接给出能用哪些功能
  diag [秒] [间隔]             现场诊断采样（默认 120s/2s），排查掉功率用
  temp <off|static|charge> [℃] 温度模式（默认 charge 30℃）
  shell <℃|off>                等同 temp static
  core <off|20-100>            CPU/GPU/DDR 固定伪装
  noncore <off|20-100>         其它温区固定伪装（电池 NTC 要单独用 batt 开）
  batt <off|20-45>             电池 NTC 伪装（默认关；开着就一直伪装）
  base <20-33>                 伪装温度（只改数值，不切换模式，供 WebUI 用）
  restart                      重启守护进程（改完参数后强制立即生效）
  hz <60-185|off> [soft|hard]  设置刷新率；hard 额外锁定内容帧率匹配
  hzguard <on|off>             开关强制锁定（档位不变，只切换力度）
  power                        电流 / 电压 / 功率读数（JSON，供面板采样）
  pscale <50-200>              电流校准百分比，读数偏低/偏高时微调（默认 100）
  cells <auto|1|2>             电芯数：自动判断 / 强制单芯 / 强制双芯
  unlock <on|off>              取消充电阶梯限流（写 thermal HAL 的限流节点，不按温度撤销）
  tiers                        充电阶梯诊断：列出所有能限流的节点与当前值
  level <0-4>                  日志 0关（默认） 1事件 2详细 3逐轮 4调试；开 1/2 会先写环境头
  logs [e|w|i|d|boot|daemon|N] 查看日志
  mount | umount               手动挂载 / 卸载配置覆盖层
  overrides <on|off>           配置改写总开关（off 只卸覆盖层，温度伪装照常）
  rebuild                      重新生成并挂载（OTA 后一般不用，开机自会处理）
  reboot-safe                  退出安全模式并立即重挂
  reset                        恢复初始状态（清空全部参数）
  menu                         交互菜单（仅限有终端的终端模拟器里使用）
EOF
}
PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:${PATH:-/system/bin}"
export PATH

MODDIR="${SD_MODDIR:-}"
if [ -z "$MODDIR" ] || [ ! -f "$MODDIR/lib/qc.sh" ]; then
    _d=$(cd "${0%/*}" 2>/dev/null && pwd)
    [ -n "$_d" ] && [ -f "$_d/lib/qc.sh" ] || _d=$(pwd)
    [ -f "$_d/lib/qc.sh" ] || _d=/data/adb/modules/quickcharge
    MODDIR=$_d
fi
[ -f "$MODDIR/lib/qc.sh" ] || {
    echo "QC: 找不到 lib/qc.sh" >&2
    exit 1
}
. "$MODDIR/lib/qc.sh"

sd_state_load
[ "${1:-}" = "power" ] || sd_zone_scan

sd_ensure_daemon() {
    [ -n "${SD_NO_DAEMON:-}" ] && return 0
    sd_daemon_launch
}

sd_do_status() {
    local mode c nc sz real bc mt src dpid nmn bs
    mode=$(sd_state_get temp_mode off)
    [ "$mode" = "dyn" ] && mode=static
    c=$(sd_state_get core_temp off)
    nc=$(sd_state_get noncore_temp off)
    sd_read_real
    sz=${_sd_rr_zone:-none}
    real=$_sd_rr_real
    src=$_sd_rr_src
    [ -n "$sz" ] || sz=none
    mt=$(sort -u "$SD_MOUNTS" 2>/dev/null | wc -l | tr -d ' ')

    printf '模式      %s' "$mode"
    case "$mode" in
        static) printf ' · 恒定 %s℃' "$(sd_state_int shell_temp 30 20 33)" ;;
        charge) printf ' · 恒定 %s℃（插电即写，不设电量阈值）' "$(sd_state_int shell_temp 30 20 33)" ;;
        off)    printf ' · 未启用（仅配置改写生效）' ;;
    esac
    printf '\n'
    printf '固定伪装  核心 %s   非核心 %s\n' "$c" "$nc"
    bs=$(sd_state_get batt_spoof off)
    if [ "$bs" != off ]; then
        if sd_batt_real_v; then
            printf '电池伪装  %s℃ · 真实 %s℃\n' "$bs" "$_sd_rv"
        else
            printf '电池伪装  %s℃ · 真实温度读不到\n' "$bs"
        fi
    else
        printf '电池伪装  关闭（电池 NTC 真实）\n'
    fi
    if [ "$(sd_state_get chg_unlock 0)" = 1 ]; then
        printf '阶梯解锁  已开启（写 0 解除 HAL 限流，不按温度撤销）\n'
    else
        printf '阶梯解锁  关闭（系统按温度分档；unlock on 可解除）\n'
    fi
    printf '温度哨兵  %s %s℃  [%s]\n' "$sz" "${real:--}" "${src:-未读到}"
    [ "$_sd_screen_ticks" -gt 0 ] || sd_screen_tick
    case "$(sd_scr_state)" in
        kernel) printf '亮屏快充  已接管（内核 ignore_screen_state）\n' ;;
        fcc)    if [ "$_sd_screen_on" = 0 ]; then
                    printf '亮屏快充  息屏交还驱动（下次亮屏再接管）\n'
                else
                    printf '亮屏快充  已接管（回写 FCC）\n'
                fi ;;
        none)   printf '亮屏快充  本机不支持（无屏幕状态参数，也没有电池侧电流节点）\n' ;;
        disabled) printf '亮屏快充  当前「关闭」模式，不接管\n' ;;
        *)      if [ "$_sd_screen_on" = 0 ]; then
                    printf '亮屏快充  已记基准，等待接管\n'
                else
                    printf '亮屏快充  等待充电\n'
                fi ;;
    esac
    dpid=$(sd_daemon_pid 2>/dev/null)
    case "$(sd_mount_mode)" in
        nomount)      nmn=$(wc -l <"$SD_NM_LIST" 2>/dev/null | tr -d ' ')
                      printf '配置      %s（NoMount 注入，无挂载）\n' "注入 ${nmn:-0} 个文件" ;;
        nomount-idle) printf '配置      NoMount 在位，但没有注入文件\n' ;;
        meta)         nmn=$(wc -l <"$SD_NM_LIST" 2>/dev/null | tr -d ' ')
                      printf '配置      %s（%s 托管，开机挂载）\n' "${nmn:-0} 个文件" "$(sd_mm_name)" ;;
        meta-idle)    printf '配置      %s 在位，但没有交付文件\n' "$(sd_mm_name)" ;;
        bind)         printf '配置      挂载 %s 个文件\n' "$mt" ;;
        *)            if [ "${mt:-0}" -gt 0 ]; then
                          printf '配置      %s 条记录，一条也没挂上\n' "$mt"
                      else
                          printf '配置      无需覆盖系统文件\n'
                      fi ;;
    esac
    if [ -n "$dpid" ]; then
        if sd_hb_age; then
            printf '守护      运行中 pid=%s（%s 秒前心跳）\n' "$dpid" "$_sd_rv"
        else
            printf '守护      运行中 pid=%s（尚未写心跳）\n' "$dpid"
        fi
    else
        printf '守护      未运行\n'
    fi

    bc=0
    read -r bc 2>/dev/null <"$SD_DATA/boot.count"
    case "$bc" in ''|*[!0-9]*) bc=0 ;; esac
    [ "$bc" -gt 3 ] && printf '⚠ 安全模式：连续 %s 次开机未完成，本次未挂载配置\n' "$bc"
    printf '日志级别  %s\n' "$(sd_state_int log_level 0 0 4)"
}

sd_do_json() {
    local mode c nc sz sname real bc mt dm hz hzn zc _e src rage dage shv shset _cacheout mmn
    local chg=false ms mw rj tgt
    mode=$(sd_state_get temp_mode off)
    [ "$mode" = "dyn" ] && mode=static
    c=$(sd_state_get core_temp off)
    nc=$(sd_state_get noncore_temp off)
    _sd_lv=0
    sd_read_real
    sname=${_sd_rr_zone:-none}
    [ -n "$sname" ] || sname=none
    real=$_sd_rr_real
    src=$_sd_rr_src
    rage=-1
    [ "$src" = "cache" ] && rage=$_sd_tl_age
    mt=$(sort -u "$SD_MOUNTS" 2>/dev/null | wc -l | tr -d ' ')
    dm=false; sd_daemon_pid >/dev/null && dm=true
    dage=-1
    sd_hb_age && dage=$_sd_rv
    bc=0; read -r bc 2>/dev/null <"$SD_DATA/boot.count"
    case "$bc" in ''|*[!0-9]*) bc=0 ;; esac

    sd_batt_status_v
    case "$_sd_rv" in Charging|Full) chg=true ;; esac

    tgt=0
    _cacheout=""
    if [ "$src" = "cache" ] && [ -n "$_sd_tl_out" ] && [ "$_sd_tl_out" != "-" ]; then
        _cacheout=$_sd_tl_out
    fi
    if [ "$mode" = static ] || { [ "$mode" = charge ] && [ "$chg" = true ]; }; then
        sd_shell_target >/dev/null
        if [ -n "$_cacheout" ]; then tgt=$_cacheout; else tgt=$_sd_last_out; fi
    fi
    shv=$(sd_state_int shell_temp 30 20 33)
    shset=$shv
    [ -n "$_sd_last_base" ] && shv=$_sd_last_base
    hz=$(sd_state_get hz off)
    hzn=0; hzh=0; hzs=off
    case "$hz" in
        off|'') hz=off ;;
        *) hzn=$(sd_hz_now 2>/dev/null || echo 0)
           hzh=$(sd_state_get hz_hard 0)
           hzs=$(sd_hz_state_text) ;;
    esac
    case "$real" in ''|*[!0-9]*) rj=null ;; *) rj=$real ;; esac

    printf '{"version":"%s","mode":"%s","shell_temp":%s,"shell_set":%s,"target":%s,' \
        "$(sd_prop_get version)" \
        "$mode" "$shv" "$shset" "$tgt"
    printf '"core":"%s","noncore":"%s","level":"%s",' \
        "$c" "$nc" "$(sd_state_get log_level 0)"
    printf '"sentinel":"%s","real":%s,"real_src":"%s","real_age":%s,"real_why":"%s","emul_ok":%s,' \
        "$sname" "$rj" "$src" "$rage" "${_sd_rr_why:-}" "${_sd_rr_emul:--1}"
    [ "$_sd_screen_ticks" -gt 0 ] || sd_screen_tick
    _sbase=0
    [ -f "$SD_FCC_NORM" ] && _sbase=$(tr -d '\r\n' <"$SD_FCC_NORM" 2>/dev/null)
    case "$_sbase" in ''|*[!0-9]*) _sbase=0 ;; esac
    printf '"screen":%s,"screen_mode":"%s","screen_base":%s,' \
        "$([ "$_sd_screen_on" = 0 ] && echo 0 || echo 1)" \
        "$(sd_scr_state)" "$_sbase"
    printf '"batt_spoof":"%s","batt_real":%s,"unlock":%s,' \
        "$(sd_state_get batt_spoof off)" \
        "$(sd_batt_real_v && printf '%s' "$_sd_rv" || printf 'null')" \
        "$([ "$(sd_state_get chg_unlock 0)" = 1 ] && echo true || echo false)"
    printf '"log_level":%s,"tick":%s,"mounted":%s,"daemon":%s,"daemon_age":%s,"boot_count":%s,"safety":%s,' \
        "$(sd_state_int log_level 0 0 4)" "$(sd_state_int tick 15 5 300)" \
        "$mt" "$dm" "$dage" "$bc" "$([ "$bc" -gt 3 ] && echo true || echo false)"
    zc=0; for _e in $_sd_zones; do zc=$((zc + 1)); done
    nmn=0
    [ -s "$SD_NM_LIST" ] && nmn=$(wc -l <"$SD_NM_LIST" 2>/dev/null | tr -d ' ')
    case "$nmn" in ''|*[!0-9]*) nmn=0 ;; esac
    printf '"hz":"%s","hz_now":%s,"hz_hard":%s,"hz_state":"%s","hz_list":"%s","charging":%s,"zones":%s,' \
        "$hz" "$hzn" "$hzh" "$hzs" "$(_sd_hz_list)" "$chg" "$zc"
    mmn=""
    sd_mm_active && mmn=$(sd_mm_name)
    sd_module_state
    ms=$_sd_ms
    mw=$(printf '%s' "$_sd_ms_why" | tr -d '"\\')
    printf '"mount_mode":"%s","mm_name":"%s","nm_files":%s,' \
        "$(sd_mount_mode)" "$mmn" "$nmn"
    printf '"module_state":"%s","module_why":"%s"}\n' "$ms" "$mw"
}

sd_set_temp() {
    local mode="$1" t="${2:-}"
    [ -n "$t" ] || t=$(sd_state_int shell_temp 30 20 33)
    case "$t" in ''|*[!0-9]*) t=30 ;; esac
    if [ "$t" -lt 20 ] || [ "$t" -gt 33 ]; then
        echo "壳温需在 20~33℃ 之间，已改用 30℃"
        t=30
    fi
    case "$mode" in
        off)
            sd_shell_emul 0
            sd_state_set temp_mode off
            sd_state_set off_manual 1
            sd_info cmd "温度模式 → off"
            echo "温度模式 -> off" ;;
        static)
            sd_state_set shell_temp "$t"
            [ -n "${2:-}" ] && sd_state_set shell_temp_manual 1
            sd_state_set temp_mode static
            sd_state_set off_manual 0
            _sd_emul_last=""
            sd_shell_emul "$t"
            sd_info cmd "温度模式 → static ${t}℃"
            echo "温度模式 -> static ${t}℃" ;;
        charge)
            sd_state_set temp_mode charge
            sd_state_set off_manual 0
            sd_batt_status_v
            case "$_sd_rv" in
                Charging|Full) sd_shell_emul "$t" ;;
                *)             sd_shell_emul 0 ;;
            esac
            sd_info cmd "温度模式 → charge"
            echo "温度模式 -> charge（插电即写，不设电量阈值）" ;;
        *) echo "未知模式: $mode（可选 off|static|charge）"; return 1 ;;
    esac
    sd_ensure_daemon
}

sd_set_scope() {
    local scope="$1" v="$2" label e zn
    [ "$scope" = core ] && label=核心 || label=非核心
    if [ "$v" = "off" ]; then
        sd_spoof_clear_scope "$scope"
        sd_state_set "${scope}_temp" off
        rm -f "$SD_SPOOF_FLAG" 2>/dev/null
        sd_info cmd "$label 伪装 → off"
        echo "$label 伪装 -> 关闭"
        return 0
    fi
    sd_valid_temp "$v" || { echo "温度需为 20~100 的整数，收到: $v"; return 1; }
    if sd_spoof_apply "$scope" "$v"; then
        sd_state_set "${scope}_temp" "$v"
        rm -f "$SD_SPOOF_FLAG" 2>/dev/null
        if [ "${_sd_spoof_fallback:-0}" = 1 ]; then
            echo "$label 伪装 -> ${v}℃（分类未命中，按节点兜底 ${_sd_spoof_total} 个）"
        else
            echo "$label 伪装 -> ${v}℃"
        fi
        return 0
    fi
    if [ -z "$_sd_zones" ] || { [ "${_sd_spoof_total:-0}" -eq 0 ] && [ "${_sd_spoof_need:-0}" -gt 0 ]; }; then
        sd_state_set "${scope}_temp" "$v"
        sd_spoof_request
        sd_info cmd "$label 伪装 → ${v}℃（待守护应用，本通道读不到温度节点）"
        echo "$label 伪装 -> ${v}℃（当前通道读不到温度节点，已交给守护应用）"
        return 0
    fi
    if [ "${_sd_spoof_total:-0}" -eq 0 ]; then
        zn=0
        for e in $_sd_zones; do zn=$((zn + 1)); done
        echo "全表判定: sh $MODDIR/action.sh zones"
        if [ -n "${_sd_spoof_sample:-}" ]; then
            echo "$label 伪装失败：本机 $zn 个温区里没有 $scope 类型（样例${_sd_spoof_sample}）"
        else
            echo "$label 伪装失败：本机 $zn 个温区里没有 $scope 类型"
        fi
    else
        echo "$label 伪装失败：${_sd_spoof_total} 个候选温区全部被拒（内核禁止 bind mount）"
    fi
    return 1
}

sd_set_pscale() {
    local v="$1"
    case "$v" in ''|*[!0-9]*) echo "校准值需为 50~200 的整数"; return 1 ;; esac
    if [ "$v" -lt 50 ] || [ "$v" -gt 200 ]; then
        echo "校准值需为 50~200 的整数"; return 1
    fi
    sd_state_set power_scale "$v"
    sd_info cmd "电流校准 → $v%"
    echo "电流校准 -> $v%（100 为原始读数）"
}


sd_set_batt() {
    local v="$1" real
    case "$v" in
        off|0)
            sd_state_set batt_spoof off
            sd_spoof_batt_off
            sd_info cmd "电池 NTC 伪装 → 关闭"
            echo "电池 NTC 伪装 -> 关闭（电池温度恢复真实）"
            return 0 ;;
    esac
    case "$v" in
        ''|*[!0-9]*) echo "用法: batt off|20-45"; return 1 ;;
    esac
    if [ "$v" -lt 20 ] || [ "$v" -gt 45 ]; then
        echo "电池伪装只能 20-45℃（上限 45，再高既无意义又危险）"
        return 1
    fi
    real=--
    sd_batt_real_v && real=$_sd_rv
    sd_state_set batt_spoof "$v"
    if sd_spoof_apply batt "$v" >/dev/null 2>&1; then
        sd_info cmd "电池 NTC 伪装 → ${v}℃（真实 ${real}℃）"
        echo "电池 NTC 伪装 -> ${v}℃（真实 ${real}℃；不按温度撤销）"
    else
        echo "电池伪装写入失败：本机电池温区没有可挂载的 temp 节点"
        sd_state_set batt_spoof off
        return 1
    fi
    return 0
}

sd_do_logs() {
    local arg="$1" n="${2:-60}"
    case "$arg" in
        e|E) grep ' E \[' "$SD_LOG" 2>/dev/null | tail -n "$n" ;;
        w|W) grep -E ' [EW] \[' "$SD_LOG" 2>/dev/null | tail -n "$n" ;;
        boot) awk '/======== .*\| boot \|/{f=1} f' "$SD_LOG" 2>/dev/null | tail -n 120 ;;
        daemon) awk '/======== .*\| daemon \|/{f=1} f' "$SD_LOG" 2>/dev/null | tail -n 120 ;;
        d|D) tail -n "$n" "$SD_LOG" 2>/dev/null ;;
        ''|i|I) grep -E ' [EWI] \[' "$SD_LOG" 2>/dev/null | tail -n "$n" ;;
        *[!0-9]*) tail -n 60 "$SD_LOG" 2>/dev/null ;;
        *) tail -n "$arg" "$SD_LOG" 2>/dev/null ;;
    esac
}

sd_menu_sub() {
    local t
    case "$1" in
        temp)
            printf '\n温度模式: 1) 关闭  2) 静态 22℃  3) 静态 25℃  4) 静态 28℃  5) 仅充电 30℃  0) 返回\n选择: '
            read -r t || return 0
            case "$t" in
                1) sd_set_temp off ;; 2) sd_set_temp static 22 ;; 3) sd_set_temp static 25 ;;
                4) sd_set_temp static 28 ;; 5) sd_set_temp charge ;;
            esac ;;
        core)
            printf '\n核心伪装: 1) 关闭  2) 40℃  3) 45℃  4) 50℃  5) 55℃  6) 60℃  0) 返回\n选择: '
            read -r t || return 0
            case "$t" in
                1) sd_set_scope core off ;; 2) sd_set_scope core 40 ;; 3) sd_set_scope core 45 ;;
                4) sd_set_scope core 50 ;; 5) sd_set_scope core 55 ;; 6) sd_set_scope core 60 ;;
            esac ;;
        misc)
            printf '\n1) 日志：事件级（量小，可长期开）  2) 日志：详细（复现一次就能定位）  3) 看错误日志  4) 看开机日志  0) 返回\n选择: '
            read -r t || return 0
            case "$t" in
                1) sd_set_log 1; echo "日志 -> 事件级" ;;
                2) sd_set_log 2; echo "日志 -> 详细" ;;
                3) printf '\033[H\033[J'; sd_do_logs e 40 ;;
                4) printf '\033[H\033[J'; sd_do_logs boot 80 ;;
            esac ;;
    esac
}

sd_menu() {
    local c
    while :; do
        printf '\033[H\033[J'
        printf 'Quick Charge (QC)\n'
        printf '────────────────────────\n'
        sd_do_status
        printf '\n1) 温度模式  2) 核心伪装  3) 其它  0) 退出\n选择: '
        read -r c || { echo; return 0; }
        case "$c" in
            1) sd_menu_sub temp ;;
            2) sd_menu_sub core ;;
            3) sd_menu_sub misc ;;
            0) printf '\033[H\033[J'; return 0 ;;
        esac
        [ -n "$c" ] && [ "$c" != 0 ] && { echo; printf '按回车继续…'; read -r _c; }
    done
}

# 只给会改状态的命令写段头。power/json/status 这些面板每 3 秒就要调一次，
# 每次写 6 行会把日志刷满，真正有用的记录全被埋掉。
case "${1:-}" in
    ''|power|json|status|log|dump|diag|chg|env|zones|probe|check|ver|version|help) ;;
    *) [ "${_sd_lv:-3}" -ge 3 ] && sd_session cmd "命令行: $*" ;;
esac

_CMD="${1:-}"

case "$1" in
    status)  sd_do_status ;;
    json)    sd_do_json
             # 面板每次拉状态顺手校正一次描述：守护被外部杀掉后，模块页那边
             # 没人再写 module.prop，只能靠这次刷新把「未运行」落下去
             sd_sync_desc ;;
    env)     sd_dump_env; grep '\[env\]' "$SD_LOG" 2>/dev/null | tail -n 4 ;;
    probe)   sd_probe ;;
    zones)   sd_zones_report ;;
    check)   sd_check ;;
    diag)    shift; sd_diag "${1:-120}" "${2:-2}" ;;
    temp)    shift; sd_set_temp "$@" ;;
    shell)   shift; sd_set_temp static "${1:-}" ;;
    core)    shift; sd_set_scope core "${1:-off}" ;;
    noncore) shift; sd_set_scope noncore "${1:-off}" ;;
    base)    shift
             v="${1:-}"
             case "$v" in ''|*[!0-9]*) echo "伪装温度需为 20~33 的整数"; exit 1 ;; esac
             { [ "$v" -ge 20 ] && [ "$v" -le 33 ]; } || { echo "伪装温度需为 20~33 的整数"; exit 1; }
             sd_state_set shell_temp "$v"
             # 手改标记：升级迁移只改「从没被用户动过」的值，
             # 否则把人家专门调好的 25 静默改成 30，升级即变慢。
             sd_state_set shell_temp_manual 1
             echo "伪装温度 -> ${v}℃" ;;
    restart) sd_daemon_stop
             if sd_ensure_daemon; then
                 echo "守护已重启"
             else
                 sd_sync_desc
                 echo "守护启动失败（残留锁已清）。再执行一次 restart；仍失败用 sh action.sh logs e 20 查看原因"
                 exit 1
             fi ;;
    hz)      shift; sd_hz_set "${1:-}" "${2:-}" ;;
    hzguard) shift
             case "${1:-}" in
                 on|hard|1)  v=$(sd_hz_want) || { echo "先选一个刷新率档位"; exit 1; }
                             sd_state_set hz_hard 1
                             sd_hz_write "$v"; sd_hz_mcfr_on
                             sd_hz_readpair
                             cur=${_hz_peak%%.*}
                             if [ "$cur" != "$v" ]; then
                                 sd_state_set hz_hard 0; sd_hz_mcfr_relax
                                 echo "写入失败：系统拒绝修改刷新率"
                                 exit 1
                             fi
                             echo "强制锁定已开启（${v}Hz）" ;;
                 off|soft|0) sd_state_set hz_hard 0
                             sd_hz_mcfr_relax
                             echo "强制锁定已关闭，交回系统策略" ;;
                 *)          echo "用法: hzguard on|off"; exit 1 ;;
             esac ;;
    power)   sd_power_json ;;
    chg)     if sd_use_c; then
                 "$MODDIR/bin/qcmon" chg 2>/dev/null || sd_chg_line
             else
                 sd_chg_line
             fi
             echo ;;
    snap)    sd_chg_snapshot 1; echo "已写入日志：$(sd_chg_line)" ;;
    pscale)  shift; sd_set_pscale "${1:-100}" ;;
    batt)     shift; sd_set_batt "${1:-off}" ;;
    unlock)  shift
             case "${1:-}" in
                 on|1)
                     sd_state_set chg_unlock 1
                     sd_unlock_tick
                     echo "阶梯解锁 -> 开启（写 0 解除 HAL 限流；不按温度撤销）"
                     echo "原值备份在 $SD_UNLOCK_ORIG；unlock off 还原" ;;
                 off|0)
                     sd_state_set chg_unlock 0
                     sd_unlock_restore
                     echo "阶梯解锁 -> 关闭（已还原原值）" ;;
                 *)  echo "用法: unlock on|off"; exit 1 ;;
             esac ;;
    tiers)   sd_tier_report ;;
    cells)    shift
              case "${1:-auto}" in
                  auto|1|2) sd_state_set cells_mode "${1:-auto}"
                            echo "电芯数: ${1:-auto}（auto=按 bcc_parms 自动判断）" ;;
                  *)        echo "用法: cells auto|1|2"; exit 1 ;;
              esac ;;
    level)   shift
             if sd_set_log "${1:-2}"; then
                 echo "日志级别 -> $(sd_state_int log_level 0 0 4)（0 关 / 1 事件 / 2 详细 / 3 逐轮 / 4 调试）"
             else
                 exit 1
             fi ;;
    logs)    shift; sd_do_logs "${1:-i}" "${2:-60}" ;;
    mount)   sd_mount_overrides ;;
    umount)  sd_umount_overrides purge ;;
    overrides)
             shift
             case "${1:-}" in
                 on|1)
                     sd_state_set overrides_off 0
                     # 用户明确表达过意图，升级时按标记判断，不再靠 defrev 猜
                     sd_state_set overrides_manual 1
                     rm -f "$SD_BUILT" 2>/dev/null
                     sd_build_overrides
                     sd_mount_overrides
                     echo "配置改写 -> 开启（温度伪装不受影响）" ;;
                 off|0)
                     sd_state_set overrides_off 1
                     sd_state_set overrides_manual 1
                     sd_umount_overrides
                     # 镜像与清单一起清掉：留着会让 NoMount 下次开机继续挂旧产物。
                     rm -rf "$SD_OVERRIDES" "$SD_NM_ROOT" 2>/dev/null
                     rm -f "$SD_BUILT" "$SD_NM_LIST" 2>/dev/null
                     echo "配置改写 -> 关闭（已卸覆盖层；温度伪装照常工作）" ;;
                 *)  echo "用法: overrides on|off"; exit 1 ;;
             esac ;;
    reboot-safe)
        printf '0\n' >"$SD_DATA/boot.count"
        sd_umount_overrides
        sd_build_overrides
        sd_mount_overrides
        sd_info cmd "已退出安全模式并重新挂载"
        echo "已退出安全模式并重新挂载" ;;
    rebuild)
        sd_umount_overrides
        rm -f "$SD_BUILT"
        sd_build_overrides
        sd_mount_overrides ;;
    reset)
        sd_daemon_stop
        sd_spoof_clear
        sd_shell_emul 0
        sd_umount_overrides purge
        printf '0\n' 2>/dev/null >"$SD_DATA/boot.count"
        rm -f "$SD_STATE"
        sd_info cmd "已恢复初始状态"
        echo "已恢复初始状态，建议重启" ;;
    "")
        sd_do_status
        echo
        echo "配置请打开模块的 WebUI（管理器里点模块 → 打开）。"
        echo "命令行：sh action.sh <命令>，全部命令见 sh action.sh help"
        ;;
    menu)    [ -t 0 ] && sd_menu || {
        echo "当前环境没有终端，交互菜单不可用。"
        echo "请用 WebUI，或 sh action.sh <命令> 直接设置。"
        exit 1
    } ;;
    help)
        sd_usage
        ;;
    *)
        echo "未知命令: $1"
        echo
        sd_usage
        exit 1 ;;
esac

_rc=$?
case "$_CMD" in
    temp|shell|core|noncore|base|unlock|level|hz|hzguard)
        sd_ensure_daemon >/dev/null 2>&1
        sd_daemon_kick ;;
esac
case "$_CMD" in
    temp|shell|core|noncore|base|unlock|level|hz|hzguard|\
    mount|umount|rebuild|reboot-safe|reset)
        [ "$_rc" = "0" ] && sd_sync_desc ;;
esac
exit "$_rc"
