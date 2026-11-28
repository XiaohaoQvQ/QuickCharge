#!/system/bin/sh
# Quick Charge (QC) — cfg/transform.sh
# 由 lib/qc.sh 拆分而来，函数体与 3.1.18 行为等价。

sd_count_tags() { grep -o '<[/]*[A-Za-z_]' "$1" 2>/dev/null | wc -l | tr -d ' '; }

sd_xml_balanced() {
    local o c
    o=$(grep -o '<[A-Za-z_][^<>]*>' "$1" 2>/dev/null | grep -vcE '/[[:space:]]*>$')
    c=$(grep -o '</[A-Za-z_][^<>]*>' "$1" 2>/dev/null | wc -l | tr -d ' ')
    case "$o" in ''|*[!0-9]*) o=0 ;; esac
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    [ "$o" = "$c" ]
}

# 不少 ROM 的温控 XML 带 UTF-8 BOM（EF BB BF），head -c 1 取到的是 0xEF。
# 旧实现据此判定"非 XML"并整份丢弃，日志里表现为"校验失败(非 XML)"，
# 结果 sys_thermal_control_config.xml 从未被覆盖。这里跳过 BOM 再看首字节。

sd_xml_lead_ok() {
    local c
    c=$(head -c 1 "$1" 2>/dev/null)
    [ "$c" = "<" ] && return 0
    if command -v od >/dev/null 2>&1; then
        [ "$(head -c 3 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')" = "efbbbf" ] || return 1
    fi
    [ "$(tail -c +4 "$1" 2>/dev/null | head -c 1)" = "<" ]
}

# 取参考文件的 SELinux 上下文。先取文件本身，再退到所在目录。
# ls -Z 的列序在 GNU / toybox 下不一致，所以直接按 u:object_r:xxx:sN 提串。
# SD_CTX_OVERRIDE 用于强制指定（老 ROM 的 ls 不带 -Z，或仿真测试）。

sd_file_ctx() {
    local c
    [ -n "$SD_CTX_OVERRIDE" ] && { printf '%s' "$SD_CTX_OVERRIDE"; return 0; }
    c=$(ls -Zd "$1" 2>/dev/null | grep -o 'u:object_r:[A-Za-z0-9_]*:s[0-9]*' | head -n 1)
    [ -n "$c" ] && { printf '%s' "$c"; return 0; }
    c=$(ls -Zd "${1%/*}" 2>/dev/null | grep -o 'u:object_r:[A-Za-z0-9_]*:s[0-9]*' | head -n 1)
    [ -n "$c" ] && { printf '%s' "$c"; return 0; }
    return 1
}

# toybox 的 chcon 不认 GNU 的 --reference，直接调用必然失败
# （日志里"3/3 chcon 失败"就是这条）。改成先试 --reference，不行就显式设。

sd_chcon_ref() {
    local ctx
    chcon --reference="$1" "$2" 2>/dev/null && return 0
    ctx=$(sd_file_ctx "$1") || return 1
    chcon "$ctx" "$2" 2>/dev/null
}

# chmod / chown 的 --reference 同样是 GNU 扩展，toybox 不认时退回显式值。

sd_chmod_ref() {
    local m
    chmod --reference="$1" "$2" 2>/dev/null && return 0
    m=$(stat -c %a "$1" 2>/dev/null) || return 1
    [ -n "$m" ] && chmod "$m" "$2" 2>/dev/null
}

sd_chown_ref() {
    local ug
    chown --reference="$1" "$2" 2>/dev/null && return 0
    ug=$(stat -c '%u:%g' "$1" 2>/dev/null) || return 1
    [ -n "$ug" ] && chown "$ug" "$2" 2>/dev/null
}

sd_verify_xml() {
    local a b
    [ -s "$2" ] || { sd_warn override "校验失败(空文件): $2"; return 1; }
    sd_xml_lead_ok "$2" || { sd_warn override "校验失败(非 XML): $2"; return 1; }
    sd_xml_balanced "$1" || { sd_warn override "校验失败(原件不配平，拒绝): $1"; return 1; }
    sd_xml_balanced "$2" || { sd_warn override "校验失败(产物不配平): $2"; return 1; }
    a=$(sd_count_tags "$1")
    b=$(sd_count_tags "$2")
    [ "$a" = "$b" ] || { sd_warn override "校验失败(标签数 $a → $b): $2"; return 1; }
    return 0
}

sd_verify_json() {
    local a b
    [ -s "$2" ] || return 1
    a=$(grep -o '[{}]' "$1" 2>/dev/null | wc -l | tr -d ' ')
    b=$(grep -o '[{}]' "$2" 2>/dev/null | wc -l | tr -d ' ')
    [ "$a" = "$b" ] || { sd_warn override "校验失败(括号数 $a → $b): $2"; return 1; }
    return 0
}

sd_xf_hightemp() {
    sed -e 's/\([A-Za-z_]\{1,\}="\)true\("\)/\1false\2/g' -e 's/>true</>false</g' "$1" 2>/dev/null >"$2"
}

sd_xf_control() {
    sed 's/\([A-Za-z_]\{1,\}="\)true\("\)/\1false\2/g' "$1" 2>/dev/null >"$2"
}

sd_xf_fps() {
    sed 's/fps="[0-9.]\{1,\}"/fps="144"/g' "$1" 2>/dev/null >"$2"
}

sd_xf_legacy() {
    sed '/[Ee]nable/ s/>1</>0</g' "$1" 2>/dev/null >"$2"
}

sd_xf_chargejson() {
    sed 's/150,450\]/150,550]/g' "$1" 2>/dev/null >"$2"
}

sd_xf_qega() {
    # 取样点只在电池伪装打开时才指向 battery。battery 与 xo-therm 默认都不在
    # 伪装范围（sd_zone_class 里 battery/board 两类被隔离），把取样点从前者
    # 换成后者等于「伪装白做」——3.1.0~3.1.3 的自相矛盾。batt_spoof 关闭时
    # 保持原厂链路，改写成自己等于不动。
    local sn=xo-therm
    [ "$(sd_state_get batt_spoof off)" != off ] && sn=battery
    sed \
        -e "s/\(SkinTemperatureNode:[[:space:]]*\)xo-therm/\1$sn/" \
        -e '/^100001/s/^100001\([[:space:]]\{1,\}\)hok[[:space:]]\{1,\}48000[[:space:]]\{1,\}1200/180001\1hok         55000          2000/' \
        -e '/^0[[:space:]]\{1,\}adaptive/s/50000/55000/' \
        "$1" 2>/dev/null >"$2"
}

# 返回值：0 改写完成；2 主动跳过（格式不像温度曲线，保持原厂）；1 真失败

sd_xf_curve() {
    local n
    # 先数「三列整数」的行：一条都没有说明不是这个格式，原样保留，别乱动。
    n=$(awk -F, '/^[0-9]+,[0-9]+,[0-9]+$/ {n++} END{print n+0}' "$2" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -gt 0 ] || return 2
    # 列语义探测：首列是 0.1℃ 量级的温度轴。判据放三关：
    #   1) 所有值 ≤600（0.1℃ 的 60℃ 上限）；
    #   2) 去掉 0 之后单调（升或降都行，有些机型从高温往低温排）；
    #   3) 非零部分最大值 ≥100 —— 这是区分「0.1℃」和「℃ 整数」的关键：
    #      25,30,35℃ 那种整数表最大值只有 35，+120 会变成 145，必须跳过。
    # 0 允许出现在任意位置：低温保护段常写成 0,50,250，整份跳过会白丢一台机型。
    # 拿不准就跳过：宁可保持原厂，也不要把温度轴整体错位。
    awk -F, 'BEGIN{ok=1;n=0;nz=0;mx=0;prev=-1;dir=0}
        /^[0-9]+,[0-9]+,[0-9]+$/ {
            v=$1+0; n++
            if (v>600) { ok=0; next }
            if (v==0) next
            if (nz>0) {
                if (v>prev) { if (dir<0) ok=0; dir=1 }
                else if (v<prev) { if (dir>0) ok=0; dir=-1 }
            }
            prev=v; nz++
            if (v>mx) mx=v
        }
        END{ if (n==0 || nz<2 || mx<100) ok=0; exit ok?0:1 }' "$2" 2>/dev/null || return 2
    awk -F, -v off="$1" 'BEGIN{OFS=","}
        /^[0-9]+,[0-9]+,[0-9]+$/ { $1=$1+off; if ($1>600) $1=600; print; next }
        { print }' "$2" 2>/dev/null >"$3"
}

sd_transform() {
    local src="$1" dst="$2" tmp rc=1 kind=xml bk
    tmp="$dst.sdtmp"

    # 源读不到（分区缺项、inode 已失效）属于环境问题，不是模块故障：静默跳过。
    # 以前这里会一路走到 sd_xf_* 返回非 0，然后记一条 E "改写失败"——那类机器
    # 每次开机都刷一批假错误，看起来像模块坏了，实际只是 ROM 里没有这份配置。
    [ -r "$src" ] || return 0

    bk="$SD_BACKUP$src"
    if [ ! -f "$bk" ]; then
        mkdir -p "$(dirname "$bk")" 2>/dev/null
        # 备份是给用户手取的存档（$SD_DATA/backup$src），模块不会自动回滚它。
        # 失败要留痕：以前 2>/dev/null 把错误吞了，目录建了文件没有，事后想取原件才发现是空的。
        cp -p "$src" "$bk" 2>/dev/null || sd_warn override "备份失败: $src"
    fi
    mkdir -p "$(dirname "$dst")" 2>/dev/null

    case "${src##*/}" in
        sys_high_temp_protect_*.xml)   sd_xf_hightemp "$src" "$tmp"; rc=$? ;;
        sys_thermal_control_config*.xml) sd_xf_control "$src" "$tmp"; rc=$? ;;
        thermallevel_to_fps.xml)       sd_xf_fps "$src" "$tmp"; rc=$? ;;
        sys_thermal_config.xml)        sd_xf_legacy "$src" "$tmp"; rc=$? ;;
        devices_config.json)           kind=json; sd_xf_chargejson "$src" "$tmp"; rc=$? ;;
        QEGA_Config.txt)               kind=text; sd_xf_qega "$src" "$tmp"; rc=$? ;;
        charging_*.txt)                kind=text; sd_xf_curve "$(sd_state_int curve_offset 120 0 300)" "$src" "$tmp"; rc=$? ;;
        *) return 1 ;;
    esac

    if [ "$rc" -ne 0 ]; then
        rm -f "$tmp"
        # 2 = 主动跳过：格式不是温度曲线，保持原厂，不算故障。
        [ "$rc" = 2 ] && { sd_warn override "跳过改写(格式不符): $src"; return 2; }
        sd_err override "改写失败: $src"
        return 1
    fi

    case "$kind" in
        xml)   sd_verify_xml "$src" "$tmp" || { rm -f "$tmp"; return 1; } ;;
        json)  sd_verify_json "$src" "$tmp" || { rm -f "$tmp"; return 1; } ;;
        text)  [ -s "$tmp" ] || { rm -f "$tmp"; return 1; } ;;
        empty) [ -f "$tmp" ] || { rm -f "$tmp"; return 1; } ;;
    esac

    # 产物和原件逐字节相同 = 这次什么也没改到（格式不匹配、目标串不存在、
    # 或这份配置本来就是这个值）。以前照样写进覆盖层，再被挂载存活检查当成
    # 「内容相同=还挂着」，两处一起把「改写无效」藏成了「一切正常」。
    if cmp -s "$tmp" "$src"; then
        rm -f "$tmp"
        # 两种可能：这份配置本来就是这个值（正常），或者改写规则压根没命中
        # （格式不匹配）。以前只说「格式或目标值不匹配」，把前一种也写成了故障。
        sd_warn override "改写无差异: $src（目标值已是期望值，或格式不匹配）"
        return 3
    fi

    mv -f "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

sd_fingerprint() {
    local vc off
    # 规范键名是 versionCode（Magisk/KernelSU 都按这个读），旧版曾写成全小写，
    # 这里两个都试一次，升级过程中不会因为读到空值把指纹打成 0。
    vc=$(sd_prop_get versionCode)
    [ -n "$vc" ] || vc=$(sd_prop_get versioncode)
    off=$(sd_state_int curve_offset 120 0 300)
    printf '%s-%s-%s-%s' \
        "$(getprop ro.build.display.id)" \
        "$(getprop ro.build.version.security_patch)" \
        "${vc:-0}" "$off"
}

# 产物自检：改写只是文本替换，语义可能被改坏。只查两条能确定的：
#   - 高温保护 XML 里不应再有 ="true"（否则等于没关）
#   - charging_*.txt 行数应与原件一致（改写只动第一列）
# 只记 W，不改行为：自检失败说明这份配置可能不适用，用户可从日志定位。

sd_override_selftest() {
    local f s n m
    find "$SD_OVERRIDES" -type f -name 'sys_high_temp_protect_*.xml' 2>/dev/null |
        while IFS= read -r f; do
            s=$(grep -c '="true"' "$f" 2>/dev/null)
            [ "${s:-0}" = 0 ] || sd_warn override "自检: ${f#"$SD_OVERRIDES"/} 仍有 $s 处 true"
        done
    find "$SD_OVERRIDES" -type f -name 'charging_*.txt' 2>/dev/null |
        while IFS= read -r f; do
            s="$SD_BACKUP/${f#"$SD_OVERRIDES"/}"
            [ -f "$s" ] || continue
            n=$(wc -l <"$s" 2>/dev/null | tr -d ' ')
            m=$(wc -l <"$f" 2>/dev/null | tr -d ' ')
            [ "$n" = "$m" ] || sd_warn override "自检: ${f#"$SD_OVERRIDES"/} 行数 $n → $m"
        done
    return 0
}

sd_build_overrides() {
    local fp base f rel lf ok skip fail
    fp=$(sd_fingerprint)

    # 用户用 `action.sh overrides off` 关掉配置改写时，一个文件也不生成。
    # 温度伪装走 emul_temp，与配置层无关，不受影响——这是把「配置的锅」
    # 和「伪装的锅」分开的必要开关。
    if [ "$(sd_state_get overrides_off 0)" = 1 ]; then
        sd_info override "配置改写已关闭(overrides off)，跳过生成"
        return 0
    fi

    case "$SD_OVERRIDES" in
        ""|/|/files) sd_err override "覆盖层路径异常($SD_OVERRIDES)，中止"; return 1 ;;
    esac

    if [ -f "$SD_BUILT" ] && [ "$(cat "$SD_BUILT" 2>/dev/null)" = "$fp" ] \
        && [ -n "$(ls -A "$SD_OVERRIDES" 2>/dev/null)" ]; then
        sd_info override "配置已是最新($fp)，跳过"
        return 0
    fi

    sd_info override "开始生成，指纹=$fp"
    rm -rf "$SD_OVERRIDES"
    mkdir -p "$SD_OVERRIDES" "$SD_RUN" 2>/dev/null

    lf="$SD_RUN/ovr.list"
    for base in $SD_CFG_DIRS; do
        [ -d "$base" ] || continue
        # 用文件重定向而不是管道：管道会让 while 落进子 shell，计数全丢。
        find "$base" -maxdepth 2 -type f \( \
            -name 'sys_high_temp_protect_*.xml' -o \
            -name 'sys_thermal_control_config*.xml' -o \
            -name 'thermallevel_to_fps.xml' -o \
            -name 'sys_thermal_config.xml' -o \
            -name 'devices_config.json' -o \
            -name 'QEGA_Config.txt' -o \
            -name 'charging_*.txt' \
            \) 2>/dev/null >"$lf"
        ok=0; skip=0; fail=0; same=0
        while IFS= read -r f; do
            rel="${f#/}"
            sd_transform "$f" "$SD_OVERRIDES/$rel"
            case $? in
                0) ok=$((ok + 1)) ;;
                2) skip=$((skip + 1)) ;;
                3) same=$((same + 1)) ;;
                *) fail=$((fail + 1)) ;;
            esac
        done <"$lf"
        [ $((ok + skip + same + fail)) -gt 0 ] &&
            sd_info override "${base#/}: 改写 $ok · 无差异 $same · 跳过 $skip · 失败 $fail"
    done
    rm -f "$lf" 2>/dev/null

    sd_override_selftest

    printf '%s' "$fp" 2>/dev/null >"$SD_BUILT"
    sd_info override "扫描: $(for _d in $SD_CFG_DIRS; do [ -d "$_d" ] && printf '%s ' "${_d#/}"; done)"
    sd_info override "生成完成，文件数=$(find "$SD_OVERRIDES" -type f 2>/dev/null | wc -l | tr -d ' ')"
}

SD_NM_ROOT="$MODDIR/system"
SD_NM_LIST="$SD_DATA/nm.list"
