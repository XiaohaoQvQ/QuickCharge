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
  temp <off|static|charge> [℃] 温度模式（默认 static 30℃）
  shell <℃|off>                等同 temp static
  core <off|20-100>            CPU/GPU/DDR 固定伪装
  noncore <off|20-100>         其它温区固定伪装（电池 NTC 要单独用 batt 开）
  batt <off|20-45>             电池 NTC 伪装（默认关；真实 ≥46℃ 自动撤销并冷却）
  gear <0-10>                  温控档位：越高越激进，可拉开温差 = 2 + 档位（aggr 为旧名）
  base <25-60>                 基准温度（只改数值，不切换模式，供 WebUI 用）
  restart                      重启守护进程（改完参数后强制立即生效）
  wall <35-80|off>             温度墙：真实温度到此即停止伪装
  curr <300-8000|off>          充电限流（mA），按温度联动降流
  curredge <0-6>               限流距墙几度开始降：0=顶到墙才降，4=默认
  boost <on|off>               暴力模式：顶墙才降流 + 档位 10 + 快充阈值 85%
  hz <60-185|off> [soft|hard]  设置刷新率；hard 额外锁定内容帧率匹配
  hzguard <on|off>             开关强制锁定（档位不变，只切换力度）
  power                        电流 / 电压 / 功率读数（JSON，供面板采样）
  pscale <50-200>              电流校准百分比，读数偏低/偏高时微调（默认 100）
  fast <20-90>                 快充生效的电量阈值（%）
  sentinel <60-110|off>        SoC/主板哨兵熔断阈值
  battery <30-70|off>          电池哨兵熔断阈值
  cells <auto|1|2>             电芯数：自动判断 / 强制单芯 / 强制双芯
  horae <0|1>                  OPPO 热管理服务开关（thermal on|off 为同义）
  thermal <on|off>             系统热管理总开关：off 停 horae，不再按温度降频
  level <0-4>                  日志级别 0关 1E 2W 3I 4D
  logs [e|w|i|d|boot|daemon|N] 查看日志
  mount | umount               手动挂载 / 卸载配置覆盖层
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
    local mode c nc wall aggr curmax curtar sz real slim bc mt src dpid nmn _ce _sb bs
    mode=$(sd_state_get temp_mode off)
    [ "$mode" = "dyn" ] && mode=static
    c=$(sd_state_get core_temp off)
    nc=$(sd_state_get noncore_temp off)
    wall=$(sd_state_get wall off)
    aggr=$(sd_state_int aggr 10 0 10)
    curmax=$(sd_state_int curr_max 0 0 8000)
    sd_read_real
    sz=${_sd_rr_zone:-none}
    real=$_sd_rr_real
    slim=$_sd_rr_lim
    src=$_sd_rr_src
    [ -n "$sz" ] || sz=none
    curtar=$(sd_curr_target 2>/dev/null)
    mt=$(sort -u "$SD_MOUNTS" 2>/dev/null | wc -l | tr -d ' ')

    printf '模式      %s' "$mode"
    case "$mode" in
        static) printf ' · 基准 %s℃' "$(sd_state_int shell_temp 30 25 60)" ;;
        charge) printf ' · %s%% 以下生效' "$(sd_state_int fast_cap 55 20 90)" ;;
        off)    printf ' · 未启用（仅配置改写生效）' ;;
    esac
    printf '\n'
    printf '温控档位  %s/10（可拉开 %s℃）   温度墙 %s\n' "$aggr" $((2 + aggr)) \
        "$([ "$wall" = off ] && echo '关（熔断前 2℃ 停止）' || echo "${wall}℃")"
    printf '固定伪装  核心 %s   非核心 %s\n' "$c" "$nc"
    bs=$(sd_state_get batt_spoof off)
    if [ "$bs" != off ]; then
        if sd_batt_real_v; then
            printf '电池伪装  %s℃ · 真实 %s℃（≥46℃ 自动撤销）\n' "$bs" "$_sd_rv"
        else
            printf '电池伪装  %s℃ · 真实温度读不到\n' "$bs"
        fi
    else
        printf '电池伪装  关闭（电池 NTC 真实）\n'
    fi
    printf '热管理    %s\n' "$([ "$(sd_state_get horae 1)" = 0 ] && echo '已停用（horae 停止）' || echo '系统默认')"
    printf '哨兵      %s %s℃ / 上限 %s℃  [%s]\n' "$sz" "${real:--}" "${slim:-off}" "${src:-未读到}"
    _ce=$(sd_state_int curr_edge 4 0 6)
    printf '电流上限  %s\n' "$([ "$curmax" -gt 0 ] && echo "${curmax}mA（当前允许 ${curtar}mA，$([ "$_ce" -eq 0 ] && echo '顶墙才降' || echo "距墙 ${_ce}℃ 开始降")）" || echo '关闭')"
    [ "$_sd_screen_ticks" -gt 0 ] || sd_screen_tick
    case "$(sd_scr_state)" in
        kernel) printf '亮屏快充  已接管（内核 ignore_screen_state）\n' ;;
        fcc)    printf '亮屏快充  已接管（回写 FCC）\n' ;;
        none)   printf '亮屏快充  本机不支持（无屏幕状态参数）\n' ;;
        disabled) printf '亮屏快充  当前「关闭」模式，不接管\n' ;;
        *)      if [ "$_sd_screen_on" = 0 ]; then
                    printf '亮屏快充  已记基准，亮屏后接管\n'
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
        *)            printf '配置      未生效（0 个文件）\n' ;;
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
    printf '日志级别  %s\n' "$(sd_state_int log_level 3 0 4)"
}

sd_do_json() {
    local mode c nc wall aggr curmax curtar sz sname real slim bc mt dm bl sl rj blj slj tgt hz hzn zc _e src rage dage shv shset _cacheout mmn
    local chg=false _bst=
    mode=$(sd_state_get temp_mode off)
    [ "$mode" = "dyn" ] && mode=static
    c=$(sd_state_get core_temp off)
    nc=$(sd_state_get noncore_temp off)
    wall=$(sd_state_get wall off)
    aggr=$(sd_state_int aggr 10 0 10)
    curmax=$(sd_state_int curr_max 0 0 8000)
    _sd_lv=3
    sd_read_real
    sname=${_sd_rr_zone:-none}
    [ -n "$sname" ] || sname=none
    real=$_sd_rr_real
    slim=$_sd_rr_lim
    src=$_sd_rr_src
    rage=-1
    [ "$src" = "cache" ] && rage=$_sd_tl_age
    curtar=$(sd_curr_target 2>/dev/null)
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
    shv=$(sd_state_int shell_temp 30 25 60)
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
    bl=$(sd_state_get battery_limit 48);  case "$bl" in off) blj='"off"' ;; *) blj=$bl ;; esac
    sl=$(sd_state_get sentinel_limit 85); case "$sl" in off) slj='"off"' ;; *) slj=$sl ;; esac
    case "$real" in ''|*[!0-9]*) rj=null ;; *) rj=$real ;; esac

    printf '{"version":"%s","mode":"%s","shell_temp":%s,"shell_set":%s,"target":%s,"aggr":%s,"gap":%s,' \
        "$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)" \
        "$mode" "$shv" "$shset" "$tgt" "$aggr" "$((2 + aggr))"
    printf '"wall":"%s","core":"%s","noncore":"%s",' "$wall" "$c" "$nc"
    printf '"sentinel":"%s","real":%s,"limit":"%s","real_src":"%s","real_age":%s,"real_why":"%s","emul_ok":%s,' \
        "$sname" "$rj" "${slim:-off}" "$src" "$rage" "${_sd_rr_why:-}" "${_sd_rr_emul:--1}"
    printf '"curr_max":%s,"curr_target":%s,"curr_edge":%s,"fast_cap":%s,' \
        "$curmax" "${curtar:-0}" "$(sd_state_int curr_edge 4 0 6)" "$(sd_state_int fast_cap 55 20 90)"
    [ "$_sd_screen_ticks" -gt 0 ] || sd_screen_tick
    _sbase=0
    [ -f "$SD_FCC_NORM" ] && _sbase=$(tr -d '\r\n' <"$SD_FCC_NORM" 2>/dev/null)
    case "$_sbase" in ''|*[!0-9]*) _sbase=0 ;; esac
    printf '"screen":%s,"screen_mode":"%s","screen_base":%s,' \
        "$([ "$_sd_screen_on" = 0 ] && echo 0 || echo 1)" \
        "$(sd_scr_state)" "$_sbase"
    printf '"batt_spoof":"%s","batt_real":%s,"thermal":"%s",' \
        "$(sd_state_get batt_spoof off)" \
        "$(sd_batt_real_v && printf '%s' "$_sd_rv" || printf 'null')" \
        "$([ "$(sd_state_get horae 1)" = 0 ] && echo off || echo on)"
    printf '"battery_limit":%s,"sentinel_limit":%s,' "$blj" "$slj"
    printf '"log_level":%s,"tick":%s,"mounted":%s,"daemon":%s,"daemon_age":%s,"boot_count":%s,"safety":%s,' \
        "$(sd_state_int log_level 3 0 4)" "$(sd_state_int tick 15 5 300)" \
        "$mt" "$dm" "$dage" "$bc" "$([ "$bc" -gt 3 ] && echo true || echo false)"
    zc=0; for _e in $_sd_zones; do zc=$((zc + 1)); done
    nmn=0
    [ -s "$SD_NM_LIST" ] && nmn=$(wc -l <"$SD_NM_LIST" 2>/dev/null | tr -d ' ')
    case "$nmn" in ''|*[!0-9]*) nmn=0 ;; esac
    printf '"hz":"%s","hz_now":%s,"hz_hard":%s,"hz_state":"%s","hz_list":"%s","charging":%s,"zones":%s,' \
        "$hz" "$hzn" "$hzh" "$hzs" "$(_sd_hz_list)" "$chg" "$zc"
    mmn=""
    sd_mm_active && mmn=$(sd_mm_name)
    printf '"mount_mode":"%s","mm_name":"%s","nm_files":%s,"barrier":%s,"base_clamped":%s}\n' \
        "$(sd_mount_mode)" "$mmn" "$nmn" "${_sd_last_barrier:-0}" \
        "$([ "$_sd_base_clamped" = 1 ] && echo true || echo false)"
}

sd_set_temp() {
    local mode="$1" t="${2:-}"
    [ -n "$t" ] || t=$(sd_state_int shell_temp 30 25 60)
    case "$t" in ''|*[!0-9]*) t=30 ;; esac
    if [ "$t" -lt 25 ] || [ "$t" -gt 60 ]; then
        echo "壳温需在 25~60℃ 之间，已改用 30℃"
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
            echo "温度模式 -> charge（低于 $(sd_state_int fast_cap 55 20 90)% 生效）" ;;
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

sd_set_aggr() {
    case "$1" in ''|*[!0-9]*) echo "温控档位需为 0~10 的整数"; return 1 ;; esac
    [ "$1" -le 10 ] || { echo "温控档位需为 0~10 的整数"; return 1; }
    sd_state_set aggr "$1"
    sd_info cmd "温控档位 → $1/10（可拉开 $((2 + $1))℃）"
    sd_ensure_daemon
    echo "温控档位 -> $1/10，允许真实与上报相差 $((2 + $1))℃"
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

sd_set_wall() {
    local v="$1" bl base nb
    if [ "$v" = "off" ] || [ "$v" = "0" ]; then
        sd_state_set wall off
        sd_info cmd "温度墙 → off"
        echo "温度墙 -> 关闭（伪装持续到熔断阈值前 2℃）"
        return 0
    fi
    case "$v" in ''|*[!0-9]*) echo "温度墙需为 35~80 的整数或 off"; return 1 ;; esac
    [ "$v" -ge 35 ] && [ "$v" -le 80 ] || { echo "温度墙需为 35~80 的整数或 off"; return 1; }
    bl=$(sd_state_int battery_limit 48 30 70)
    [ "$v" -ge "$bl" ] && echo "注意：墙 ${v}℃ ≥ 电池熔断 ${bl}℃，墙不会生效（熔断先触发）"

    base=$(sd_state_int shell_temp 30 25 60)
    if [ "$base" -ge "$v" ]; then
        nb=$((v - 2))
        [ "$nb" -lt 25 ] && nb=25
        sd_state_set shell_temp "$nb"
        sd_info cmd "墙 ${v}℃ ≤ 基准 ${base}℃，基准自动下调 → ${nb}℃"
        echo "基准 ${base}℃ 不低于墙 ${v}℃，已自动调到 ${nb}℃（否则整个伪装区间为空）"
    fi
    sd_state_set wall "$v"
    sd_info cmd "温度墙 → ${v}℃"
    echo "温度墙 -> ${v}℃（真实温度达到即停止伪装）"
}

sd_set_curr() {
    local v="$1" applied
    if [ "$v" = "off" ] || [ "$v" = "0" ]; then
        sd_curr_restore
        sd_state_set curr_max 0
        sd_info cmd "电流墙 → off"
        echo "电流墙 -> 关闭，限流节点已还原"
        return 0
    fi
    case "$v" in ''|*[!0-9]*) echo "电流需为 300~8000 的整数（mA）或 off"; return 1 ;; esac
    [ "$v" -ge 300 ] && [ "$v" -le 8000 ] || { echo "电流需为 300~8000 的整数（mA）或 off"; return 1; }
    sd_state_set curr_max "$v"
    applied=$(sd_curr_target)
    sd_info cmd "电流墙 → ${v}mA（当前允许 ${applied}mA）"
    if [ "$(sd_batt_status)" = "Charging" ]; then
        if sd_curr_apply "$applied"; then
            echo "电流墙 -> ${v}mA，已写入（当前温度下允许 ${applied}mA）"
        else
            echo "电流墙 -> ${v}mA 已记录，但没有可写的限流节点"
            echo "  本机可能不开放充电限流；充电时守护仍会持续尝试"
        fi
    else
        echo "电流墙 -> ${v}mA，未在充电，接上充电器后生效"
    fi
}

sd_set_fast() {
    case "$1" in ''|*[!0-9]*) echo "电量阈值需为 20~90 的整数"; return 1 ;; esac
    [ "$1" -ge 20 ] && [ "$1" -le 90 ] || { echo "电量阈值需为 20~90 的整数"; return 1; }
    sd_state_set fast_cap "$1"
    sd_info cmd "快充阈值 → $1%"
    echo "快充阈值 -> $1%"
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
    if ! sd_batt_real_v; then
        echo "读不到真实电池温度（power_supply），拒绝开启电池伪装"
        return 1
    fi
    real=$_sd_rv
    if [ "$real" -ge "$SD_BATT_HARD" ]; then
        echo "真实电池 ${real}℃ 已 ≥ ${SD_BATT_HARD}℃，先降温再开"
        return 1
    fi
    sd_state_set batt_spoof "$v"
    if sd_spoof_apply batt "$v" >/dev/null 2>&1; then
        sd_info cmd "电池 NTC 伪装 → ${v}℃（真实 ${real}℃）"
        echo "电池 NTC 伪装 -> ${v}℃（真实 ${real}℃；≥${SD_BATT_HARD}℃ 自动撤销）"
    else
        echo "电池伪装写入失败：本机电池温区没有可挂载的 temp 节点"
        sd_state_set batt_spoof off
        return 1
    fi
    return 0
}

sd_set_limit() {
    local key="$1" v="$2" lo="$3" hi="$4" label="$5" dflt="$6"
    if [ "$v" = "off" ]; then
        sd_state_set "$key" off
        echo "$label -> 关闭（不建议）"
        return 0
    fi
    case "$v" in ''|*[!0-9]*) echo "$label 需为 ${lo}~${hi} 或 off"; return 1 ;; esac
    [ "$v" -ge "$lo" ] && [ "$v" -le "$hi" ] || { echo "$label 需为 ${lo}~${hi} 或 off"; return 1; }
    sd_state_set "$key" "$v"
    sd_info cmd "$label → ${v}℃"
    echo "$label -> ${v}℃（默认 ${dflt}）"
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
            printf '\n温度模式: 1) 关闭  2) 静态 30℃  3) 静态 35℃  4) 静态 40℃  5) 充电辅助  0) 返回\n选择: '
            read -r t || return 0
            case "$t" in
                1) sd_set_temp off ;; 2) sd_set_temp static 30 ;; 3) sd_set_temp static 35 ;;
                4) sd_set_temp static 40 ;; 5) sd_set_temp charge ;;
            esac ;;
        core)
            printf '\n核心伪装: 1) 关闭  2) 40℃  3) 45℃  4) 50℃  5) 55℃  6) 60℃  0) 返回\n选择: '
            read -r t || return 0
            case "$t" in
                1) sd_set_scope core off ;; 2) sd_set_scope core 40 ;; 3) sd_set_scope core 45 ;;
                4) sd_set_scope core 50 ;; 5) sd_set_scope core 55 ;; 6) sd_set_scope core 60 ;;
            esac ;;
        power)
            printf '\n1) 档位 10  2) 档位 8  3) 档位 5  4) 档位 2\n'
            printf '5) 温度墙 42℃  6) 温度墙 40℃  7) 温度墙 45℃  8) 关闭温度墙  0) 返回\n选择: '
            read -r t || return 0
            case "$t" in
                1) sd_set_aggr 10 ;; 2) sd_set_aggr 8 ;; 3) sd_set_aggr 5 ;; 4) sd_set_aggr 2 ;;
                5) sd_set_wall 42 ;; 6) sd_set_wall 40 ;; 7) sd_set_wall 45 ;; 8) sd_set_wall off ;;
            esac ;;
        charge)
            printf '\n1) 关闭限流  2) 1000mA  3) 2000mA  4) 3000mA  5) 4000mA\n'
            printf '6) 快充阈值 55%%  7) 快充阈值 70%%  0) 返回\n选择: '
            read -r t || return 0
            case "$t" in
                1) sd_set_curr off ;; 2) sd_set_curr 1000 ;; 3) sd_set_curr 2000 ;;
                4) sd_set_curr 3000 ;; 5) sd_set_curr 4000 ;;
                6) sd_set_fast 55 ;; 7) sd_set_fast 70 ;;
            esac ;;
        misc)
            printf '\n1) 日志级别 常规  2) 日志级别 调试  3) 看错误日志  4) 看开机日志  0) 返回\n选择: '
            read -r t || return 0
            case "$t" in
                1) sd_state_set log_level 3; echo "日志级别 -> 3" ;;
                2) sd_state_set log_level 4; echo "日志级别 -> 4" ;;
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
        printf '\n1) 温度模式  2) 核心伪装  3) 档位/温度墙  4) 充电限流  5) 其它  0) 退出\n选择: '
        read -r c || { echo; return 0; }
        case "$c" in
            1) sd_menu_sub temp ;;
            2) sd_menu_sub core ;;
            3) sd_menu_sub power ;;
            4) sd_menu_sub charge ;;
            5) sd_menu_sub misc ;;
            0) printf '\033[H\033[J'; return 0 ;;
        esac
        [ -n "$c" ] && [ "$c" != 0 ] && { echo; printf '按回车继续…'; read -r _c; }
    done
}

[ -n "${1:-}" ] && sd_session cmd "命令行: $*"

_CMD="${1:-}"

case "$1" in
    status)  sd_do_status ;;
    json)    sd_do_json ;;
    env)     sd_dump_env; grep '\[env\]' "$SD_LOG" 2>/dev/null | tail -n 4 ;;
    probe)   sd_probe ;;
    zones)   sd_zones_report ;;
    check)   sd_check ;;
    diag)    shift; sd_diag "${1:-120}" "${2:-2}" ;;
    temp)    shift; sd_set_temp "$@" ;;
    shell)   shift; sd_set_temp static "${1:-}" ;;
    core)    shift; sd_set_scope core "${1:-off}" ;;
    noncore) shift; sd_set_scope noncore "${1:-off}" ;;
    gear|aggr) shift; sd_set_aggr "${1:-10}" ;;
    base)    shift
             v="${1:-}"
             case "$v" in ''|*[!0-9]*) echo "基准温度需为 25~60 的整数"; exit 1 ;; esac
             { [ "$v" -ge 25 ] && [ "$v" -le 60 ]; } || { echo "基准温度需为 25~60 的整数"; exit 1; }
             w=$(sd_state_get wall off)
             case "$w" in
                 off|''|0) ;;
                 *)
                     if [ "$v" -ge "$w" ]; then
                         nb=$((w - 2)); [ "$nb" -lt 25 ] && nb=25
                         sd_info cmd "基准 ${v}℃ ≥ 墙 ${w}℃，收敛 → ${nb}℃"
                         echo "基准 ${v}℃ 不低于温度墙 ${w}℃，按 ${nb}℃ 生效（基准必须低于墙，否则全程不改写）"
                         v=$nb
                     fi ;;
             esac
             sd_state_set shell_temp "$v"
             echo "基准温度 -> ${v}℃" ;;
    restart) sd_daemon_stop
             if sd_ensure_daemon; then
                 echo "守护已重启"
             else
                 echo "守护启动失败（残留锁已清）。再执行一次 restart；仍失败用 sh action.sh logs e 20 查看原因"
                 exit 1
             fi ;;
    wall)    shift; sd_set_wall "${1:-off}" ;;
    curr)    shift; sd_set_curr "${1:-off}" ;;
    curredge) shift
             case "${1:-}" in
                 ''|*[!0-9]*) echo "用法: curredge 0-6（0=顶到墙才降流）"; exit 1 ;;
             esac
             [ "$1" -le 6 ] || { echo "用法: curredge 0-6（0=顶到墙才降流）"; exit 1; }
             sd_state_set curr_edge "$1"
             if [ "$1" -eq 0 ]; then
                 echo "限流 -> 顶到墙才降"
             else
                 echo "限流 -> 距墙 $1℃ 开始降"
             fi ;;
    boost)   shift
             case "${1:-on}" in
                 on|1)
                     sd_state_set curr_edge 0
                     sd_state_set aggr 10
                     sd_state_set fast_cap 85
                     echo "暴力模式 -> 开启（顶墙才降流 · 档位 10 · 快充阈值 85%）" ;;
                 off|0)
                     sd_state_set curr_edge 4
                     sd_state_set aggr 10
                     sd_state_set fast_cap 55
                     echo "暴力模式 -> 关闭（距墙 4℃ 降流 · 档位 10 · 快充阈值 55%）" ;;
                 *)  echo "用法: boost on|off"; exit 1 ;;
             esac ;;
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
    pscale)  shift; sd_set_pscale "${1:-100}" ;;
    fast)    shift; sd_set_fast "${1:-55}" ;;
    sentinel) shift; sd_set_limit sentinel_limit "${1:-85}" 60 110 "SoC 哨兵" 85 ;;
    battery)  shift; sd_set_limit battery_limit  "${1:-48}" 30 70  "电池哨兵" 48 ;;
    batt)     shift; sd_set_batt "${1:-off}" ;;
    thermal)  shift
              case "${1:-}" in
                  on|1)  sd_horae 1; sd_state_set horae 1; echo "系统热管理 -> 开启" ;;
                  off|0) sd_horae 0; sd_state_set horae 0; echo "系统热管理 -> 停止（horae 已关，温度不再触发系统降频）" ;;
                  *)     echo "用法: thermal on|off"; exit 1 ;;
              esac ;;
    cells)    shift
              case "${1:-auto}" in
                  auto|1|2) sd_state_set cells_mode "${1:-auto}"
                            echo "电芯数: ${1:-auto}（auto=按 bcc_parms 自动判断）" ;;
                  *)        echo "用法: cells auto|1|2"; exit 1 ;;
              esac ;;
    horae)   shift
             case "${1:-}" in
                 0|1) sd_horae "$1"; sd_state_set horae "$1"
                       echo "horae -> $([ "$1" = 1 ] && echo 开启 || echo 停止)" ;;
                 *)   echo "用法: horae 0|1"; exit 1 ;;
             esac ;;
    level)   shift
             case "${1:-3}" in
                 0|1|2|3|4) sd_state_set log_level "$1"; echo "日志级别 -> $1" ;;
                 *) echo "级别需为 0~4"; exit 1 ;;
             esac ;;
    logs)    shift; sd_do_logs "${1:-i}" "${2:-60}" ;;
    mount)   sd_mount_overrides ;;
    umount)  sd_umount_overrides purge ;;
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
        sd_horae 1
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
    temp|shell|core|noncore|gear|aggr|base|wall|curr|curredge|boost|fast|screen|sentinel|battery|horae|level|hz|hzguard)
        sd_ensure_daemon >/dev/null 2>&1
        sd_daemon_kick ;;
esac
case "$_CMD" in
    temp|shell|core|noncore|gear|aggr|base|wall|curr|curredge|boost|fast|screen|sentinel|battery|horae|level|hz|hzguard|\
    mount|umount|rebuild|reboot-safe|reset)
        [ "$_rc" = "0" ] && sd_sync_desc ;;
esac
exit "$_rc"
