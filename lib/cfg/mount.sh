#!/system/bin/sh
# Quick Charge (QC) — cfg/mount.sh
# 由 lib/qc.sh 拆分而来，函数体与 3.1.18 行为等价。

sd_nm_active() {
    local d
    for d in /data/adb/modules/meta-nomount /data/adb/modules/nomount; do
        [ -d "$d" ] || continue
        [ -f "$d/disable" ] && continue
        [ -f "$d/remove" ] && continue
        return 0
    done
    return 1
}

SD_MM_DIRS="/data/adb/modules/meta-hybrid_mount
/data/adb/modules/hybrid_mount
/data/adb/modules/meta-magic_mount
/data/adb/modules/meta-magic_mount-rs
/data/adb/modules/meta-mm
/data/adb/modules/magic_mount
/data/adb/modules/mountify"

sd_mm_active() {
    local d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        [ -d "$d" ] || continue
        [ -f "$d/disable" ] && continue
        [ -f "$d/remove" ] && continue
        _sd_mm=$d
        return 0
    done <<EOF
$SD_MM_DIRS
EOF
    return 1
}

sd_mm_name() {
    sd_mm_active || return 1
    case "${_sd_mm##*/}" in
        *hybrid*)  printf 'Hybrid Mount' ;;
        mountify*) printf 'Mountify' ;;
        *)         printf 'Magic Mount' ;;
    esac
}

sd_nm_bin() {
    local b
    for b in \
        /data/adb/modules/meta-nomount/bin/arm64-v8a/nomount \
        /data/adb/modules/meta-nomount/bin/arm64/nomount \
        /data/adb/modules/nomount/bin/arm64-v8a/nomount \
        /data/adb/modules/nomount/bin/arm64/nomount
    do
        [ -x "$b" ] && { _sd_rv=$b; return 0; }
    done
    b=$(command -v nomount 2>/dev/null)
    [ -n "$b" ] && [ -x "$b" ] && { _sd_rv=$b; return 0; }
    return 1
}

sd_nm_mirror() {
    local rel src dst cur="$SD_RUN/nm.cur" miss=0 found x
    [ -d "$SD_OVERRIDES" ] || return 2
    mkdir -p "$SD_RUN" 2>/dev/null
    : >"$cur" 2>/dev/null || return 2

    ( cd "$SD_OVERRIDES" 2>/dev/null || exit 1
      find . -type f 2>/dev/null | while IFS= read -r rel; do
          rel="${rel#./}"
          src="$SD_OVERRIDES/$rel"
          dst="$SD_NM_ROOT/$rel"
          mkdir -p "${dst%/*}" 2>/dev/null || continue
          if [ -f "$dst" ]; then
              cat "$src" >"$dst" 2>/dev/null || cp -f "$src" "$dst" 2>/dev/null
          else
              cp -f "$src" "$dst" 2>/dev/null
          fi
          [ -f "$dst" ] || continue
          if [ -e "/$rel" ]; then
              sd_chmod_ref "/$rel" "$dst"
              sd_chown_ref "/$rel" "$dst"
              sd_chcon_ref "/$rel" "$dst"
          fi
          printf '%s\n' "$rel"
      done ) >"$cur"

    if [ ! -s "$cur" ]; then
        # 一个覆盖文件都没产出：把上一轮的镜像目录和 nm.list 一起清掉。
        # 留着的话 NoMount 下次开机会照旧清单去挂已经不存在的源，留下
        # "目录项还在、stat 拿不到 inode"的断链挂载点，比不挂更糟。
        if [ -n "$(ls -A "$SD_NM_ROOT" 2>/dev/null)" ] || [ -s "$SD_NM_LIST" ]; then
            rm -rf "$SD_NM_ROOT" 2>/dev/null
            rm -f "$SD_NM_LIST" 2>/dev/null
            sd_info mount "无覆盖文件，已清空 NoMount 镜像与清单"
        fi
        return 2
    fi

    if [ -s "$SD_NM_LIST" ]; then
        while IFS= read -r rel; do
            case "$rel" in ''|*..*) continue ;; esac
            found=0
            while IFS= read -r x; do
                [ "$x" = "$rel" ] && { found=1; break; }
            done <"$cur"
            [ "$found" = 1 ] || { rm -f "$SD_NM_ROOT/$rel" 2>/dev/null; miss=1; }
        done <"$SD_NM_LIST"
    fi

    [ "$miss" = 1 ] && { cp -f "$cur" "$SD_NM_LIST" 2>/dev/null; return 0; }
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$SD_NM_LIST" "$cur" 2>/dev/null && return 1
    fi
    cp -f "$cur" "$SD_NM_LIST" 2>/dev/null
    return 0
}

sd_nm_reload() {
    local b
    sd_nm_bin || return 1
    b=$_sd_rv
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$b" reload >/dev/null 2>&1 && return 0
    else
        "$b" reload >/dev/null 2>&1 && return 0
    fi
    return 1
}

sd_nm_purge() {
    local rel
    if [ -s "$SD_NM_LIST" ]; then
        while IFS= read -r rel; do
            case "$rel" in ''|*..*) continue ;; esac
            rm -f "$SD_NM_ROOT/$rel" 2>/dev/null
        done <"$SD_NM_LIST"
    fi
    : >"$SD_NM_LIST" 2>/dev/null
    find "$SD_NM_ROOT" -type d -empty -delete 2>/dev/null
    sd_nm_active && sd_nm_reload && sd_info mount "已从 NoMount 撤下覆盖层"
    return 0
}

sd_mount_mode() {
    if sd_nm_active; then
        [ -s "$SD_NM_LIST" ] && { printf 'nomount'; return 0; }
        printf 'nomount-idle'; return 0
    fi
    if sd_mm_active; then
        [ -s "$SD_NM_LIST" ] && { printf 'meta'; return 0; }
        printf 'meta-idle'; return 0
    fi
    if sd_mounts_alive; then printf 'bind'; return 0; fi
    printf 'none'
}

sd_mount_overrides() {
    local src rel dst n=0 nchg=0 chgfail="$SD_RUN/chcon.fail" total mmn
    if [ "$(sd_state_get overrides_off 0)" = 1 ]; then
        sd_umount_overrides
        sd_info mount "配置改写已关闭(overrides off)，不挂载"
        return 0
    fi
    [ -d "$SD_OVERRIDES" ] || return 1

    # rc=2 既可能是镜像真写失败，也可能只是没有覆盖文件可镜像。后者在源配置
    # 缺失的机器上每轮都会遇到，不该报"写入失败"。先数一遍产物用来区分。
    total=$(find "$SD_OVERRIDES" -type f 2>/dev/null | wc -l | tr -d ' ')

    if sd_nm_active; then
        sd_nm_mirror
        case $? in
            1)
                : >"$SD_MOUNTS" 2>/dev/null
                sd_info mount "已交给 NoMount（内容原地更新，无挂载）"
                return 0 ;;
            0)
                : >"$SD_MOUNTS" 2>/dev/null
                if sd_nm_reload; then
                    sd_info mount "已交给 NoMount 注入，$(wc -l <"$SD_NM_LIST" 2>/dev/null | tr -d ' ') 个文件，无挂载"
                else
                    sd_warn mount "NoMount 无 reload 接口，新文件下次开机生效（当前无挂载）"
                fi
                return 0 ;;
            *)
                [ "$total" -gt 0 ] && sd_warn mount "NoMount 镜像写入失败，退回 bind mount" ;;
        esac
    fi

    if sd_mm_active; then
        mmn=$(sd_mm_name)
        sd_nm_mirror
        case $? in
            2) [ "$total" -gt 0 ] && sd_warn mount "$mmn 镜像写入失败，退回 bind mount" ;;
            *)
                : >"$SD_MOUNTS" 2>/dev/null
                sd_info mount "已交给 $mmn，system/ 下 $(wc -l <"$SD_NM_LIST" 2>/dev/null | tr -d ' ') 个文件，开机挂载"
                return 0 ;;
        esac
    fi

    sd_umount_overrides
    : >"$chgfail"

    ( cd "$SD_OVERRIDES" 2>/dev/null || exit 1
      find . -type f 2>/dev/null | while IFS= read -r rel; do
          rel="${rel#./}"
          src="$SD_OVERRIDES/$rel"
          dst="/$rel"
          [ -e "$dst" ] || continue
          sd_chmod_ref "$dst" "$src"
          sd_chown_ref "$dst" "$src"
          sd_chcon_ref "$dst" "$src" || { echo "$dst" >>"$chgfail"; }
          umount -l "$dst" 2>/dev/null
          if mount -o bind "$src" "$dst" 2>/dev/null; then
              echo "$dst" >>"$SD_MOUNTS"
          else
              sd_err mount "挂载失败: $dst"
          fi
      done )

    n=$(sort -u "$SD_MOUNTS" 2>/dev/null | wc -l | tr -d ' ')
    nchg=$(wc -l 2>/dev/null <"$chgfail" | tr -d ' ')
    case "$nchg" in ''|*[!0-9]*) nchg=0 ;; esac
    [ "$nchg" -gt 0 ] && sd_warn mount "$nchg/$total 个文件 chcon 失败（清单: $chgfail）"
    sd_info mount "配置覆盖已挂载，累计 $n/$total 条"
}

# 挂载源（mountinfo 的 root 字段）落在覆盖层目录下，才算「覆盖层真的挂上了」。
# 以前这里比的是「覆盖层文件 vs 系统同名文件内容是否相同」—— 但改写本身没产生
# 差异时两边本来就相同，于是「没改写成功」被判成「挂载还在」，一路静默到用户
# 侧；一加 15 那次「完全不生效」就是这么被藏住的。

sd_mounts_root_ok() {
    [ -d "$SD_OVERRIDES" ] || return 1
    [ -r /proc/self/mountinfo ] || return 1
    awk -v b="$SD_OVERRIDES/" '
        {
            i = 0
            for (k = 1; k <= NF; k++) if ($k == "-") { i = k; break }
            if (i > 0 && index($4, b) == 1) { f = 1; exit }
        }
        END { exit (f ? 0 : 1) }
    ' /proc/self/mountinfo 2>/dev/null
}

sd_mounts_alive() {
    case "$(qc_overrides_state)" in
        no) return 1 ;;
        *) return 0 ;;
    esac
}

# 覆盖层到底生效了多少：yes（全部挂上）/ partial（只挂上一部分）/ no。
# 3.1.18 只判「至少挂上一个」—— 8 个文件挂上 3 个也报 alive=yes，
# 用户看到「已生效」，实际还有 5 个没改。判定偏松本身就是一种误导。
# 明细放在 _qc_mnt_hit / _qc_mnt_all / _qc_mnt_why，调用方直接打日志。
qc_overrides_state() {
    _qc_mnt_hit=0; _qc_mnt_all=0; _qc_mnt_why=""
    if [ "$(sd_state_get overrides_off 0)" = 1 ]; then
        _qc_mnt_why="配置改写已关闭"
        printf 'no'; return 1
    fi
    # 元模块（NoMount / Magic Mount / Mountify）接管时没有 bind mount，
    # 判据是 nm.list 非空且 $MODDIR/system 存在，与 C 侧同一套规则。
    if sd_nm_active; then
        if [ -s "$SD_NM_LIST" ] && [ -d "$SD_NM_ROOT" ]; then
            _qc_mnt_all=$(grep -c . "$SD_NM_LIST" 2>/dev/null)
            case "$_qc_mnt_all" in ''|*[!0-9]*) _qc_mnt_all=0 ;; esac
            _qc_mnt_hit=$_qc_mnt_all
            _qc_mnt_why="元模块接管"
            printf 'yes'; return 0
        fi
        _qc_mnt_why="元模块已激活，但 nm.list 为空或 $SD_NM_ROOT 不存在"
        printf 'no'; return 1
    fi
    [ -s "$SD_MOUNTS" ] || { _qc_mnt_why="mounts.list 为空"; printf 'no'; return 1; }
    _qc_mnt_all=$(grep -c . "$SD_MOUNTS" 2>/dev/null)
    case "$_qc_mnt_all" in ''|*[!0-9]*) _qc_mnt_all=0 ;; esac
    _qc_mnt_hit=$(awk 'NR==FNR { if ($0!="") want[$0]=1; next }
                       ($2 in want) { hit[$2]=1 }
                       END { c=0; for (k in hit) c++; print c }' \
                  "$SD_MOUNTS" /proc/mounts 2>/dev/null)
    case "$_qc_mnt_hit" in ''|*[!0-9]*) _qc_mnt_hit=0 ;; esac
    if [ "$_qc_mnt_all" -gt 0 ] && [ "$_qc_mnt_hit" -ge "$_qc_mnt_all" ]; then
        _qc_mnt_why="全部挂上"
        printf 'yes'; return 0
    fi
    if [ "$_qc_mnt_hit" -gt 0 ]; then
        _qc_mnt_why="部分挂载"
        printf 'partial'; return 0
    fi
    if sd_mounts_root_ok; then
        _qc_mnt_why="mounts.list 对不上，但 mountinfo 里有本模块的挂载源"
        _qc_mnt_hit=1
        printf 'partial'; return 0
    fi
    _qc_mnt_why="没有本模块的挂载"
    printf 'no'; return 1
}

# 扫 /proc/self/mountinfo，把挂载源（root 字段）落在本模块目录下的挂载点全卸掉。
# 只靠 mounts.list 与 files/ 会漏：files/ 被清空之后两边都对不上，上一版留下的
# bind mount 就一直挂着；源被删后它变成 stat 不到的断链挂载点，umount 按路径
# 也认不出来，只能按 root 字段匹配。

sd_umount_module_mounts() {
    [ -r /proc/self/mountinfo ] || return 0
    awk '
        {
            i = 0
            for (k = 1; k <= NF; k++) if ($k == "-") { i = k; break }
            if (i > 0 && $5 != "" && $4 != "") print $5 "\t" $4
        }
    ' /proc/self/mountinfo 2>/dev/null |
    while IFS="$(printf '\t')" read -r _mp _root; do
        case "$_root" in
            "$MODDIR"/*|"$SD_BACKUP"/*)
                umount "$_mp" 2>/dev/null || umount -l "$_mp" 2>/dev/null
                ;;
        esac
    done
    return 0
}

sd_umount_overrides() {
    local p left n mp purge="${1:-}"
    sd_umount_module_mounts
    mp=$(awk '{print $2}' /proc/mounts 2>/dev/null)
    {
        [ -f "$SD_MOUNTS" ] && sort -u "$SD_MOUNTS" 2>/dev/null
        if [ -d "$SD_OVERRIDES" ]; then
            ( cd "$SD_OVERRIDES" 2>/dev/null || exit 0
              find . -type f 2>/dev/null | while IFS= read -r rel; do
                  dst="/${rel#./}"
                  printf '%s\n' "$mp" | grep -qxF "$dst" && printf '%s\n' "$dst"
              done )
        fi
    } | sort -u | while IFS= read -r p; do
        [ -n "$p" ] || continue
        [ -f "$p" ] || continue
        umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null
    done

    left=""
    if [ -d "$SD_OVERRIDES" ]; then
        mp=$(awk '{print $2}' /proc/mounts 2>/dev/null)
        left=$( cd "$SD_OVERRIDES" 2>/dev/null || exit 0
                find . -type f 2>/dev/null | while IFS= read -r rel; do
                    dst="/${rel#./}"
                    printf '%s\n' "$mp" | grep -qxF "$dst" && printf '%s\n' "$dst"
                done )
    fi
    if [ -n "$left" ]; then
        printf '%s\n' "$left" >"$SD_MOUNTS"
        n=$(printf '%s\n' "$left" | wc -l | tr -d ' ')
        # 带路径：只说"N 条"，看日志的人既不知道该重试哪，也看不出是不是双层挂载
        sd_warn mount "$n 条未卸净（$(printf '%s' "$left" | tr '\n' ' ' | sed 's/ *$//')），清单已保留待下次重试"
    else
        : >"$SD_MOUNTS"
        sd_nm_active || sd_info mount "配置覆盖已全部卸载"
    fi

    [ "$purge" = "purge" ] && sd_nm_purge
    return 0
}

# 启动瞬间 sysfs 常常还没就绪，这时探测结果是 0，几秒后就变成 8。
# 只在启动时打一次的话，日志里只剩那个 0，看日志的人会当成「永久没节点」
# —— 3.1.12 的根因报告据此写了一条并不存在的 P2。数量变了就补一条。
_sd_curr_ex=-1
