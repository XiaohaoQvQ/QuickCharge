#!/system/bin/sh
# post-fs-data：把配置覆盖层 bind mount 到系统分区。
#
# 自包含 —— 元模块只需在 post-fs-data 阶段执行
#     sh <模块目录>/post-fs-data.sh
# 即可完成全部挂载，不依赖 Magisk 自动 overlay（SKIPMOUNT=true）。

MODDIR="${SD_MODDIR:-}"
if [ -z "$MODDIR" ]; then
    MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd)
    [ -f "${MODDIR:-/nonexistent}/lib/qc.sh" ] || MODDIR=$(pwd)
fi
[ -f "$MODDIR/lib/qc.sh" ] || {
    echo "QC: 找不到 lib/qc.sh" >&2
    echo "  当前推导路径: $MODDIR" >&2
    exit 1
}

. "$MODDIR/lib/qc.sh"

# 元模块如果在同一个 shell 里接着调 service.sh，对方靠这个变量识别
# "现在是开机早期"，立即退出而不是死等 boot_completed。
export SD_PHASE=post-fs-data

sd_state_load
sd_zone_scan

# ---------- 开机循环自救 ----------
# 每次进入先累加，boot 完成后由 service 清零。连续多次没走到 service
# （说明挂在 HAL 解析或系统服务启动上）就放弃挂载，让系统能起来。
# 这是唯一不依赖 recovery 的翻车出口。
cnt=0
read -r cnt 2>/dev/null <"$SD_DATA/boot.count"
case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
cnt=$((cnt + 1))
printf '%s\n' "$cnt" 2>/dev/null >"$SD_DATA/boot.count"

if [ "$cnt" -gt 3 ]; then
    # 清单必须一起清：否则 service 看到非空清单会误判"已挂好"而不再补挂
    : 2>/dev/null >"$SD_MOUNTS"
    echo "QC: 连续 $cnt 次开机未完成，已跳过挂载（安全模式）" >&2
    exit 0
fi

sd_session boot "post-fs-data 启动 (计数 $cnt/3)"
sd_info boot "模块=$MODDIR 覆盖层=$SD_OVERRIDES"

# ---------- 覆盖层重建判断 ----------
# 两种情况必须重建：
#   1) 覆盖层为空 —— 元模块场景下 customize.sh 可能没执行过
#   2) 系统版本变了 —— OTA 后 /vendor/etc 的温控配置被整体替换，
#      继续挂旧副本等于把新系统降级回旧版本，新版 XML 新增的节点会缺失
need=0
if [ ! -d "$SD_OVERRIDES" ] || [ -z "$(ls -A "$SD_OVERRIDES" 2>/dev/null)" ]; then
    need=1
    sd_info boot "覆盖层为空，现场生成"
else
    cur=$(sd_fingerprint)
    old=$(cat "$SD_BUILT" 2>/dev/null)
    # 属性服务就绪前 getprop 返回空，指纹会退化成 "-"。
    # 这种情形不能判"版本变了"，否则每次开机都误触发重建。
    if [ -n "$cur" ] && [ "$cur" != "-" ] && [ "$cur" != "$old" ]; then
        need=1
        sd_info boot "系统版本变化(${old:-未知} → $cur)，重建覆盖层"
    fi
fi

if [ "$need" = 1 ]; then
    # 必须先解挂：sd_build_overrides 开头 rm -rf 覆盖层，
    # 源目录正被 bind mount 时删的是活 inode，后果不可预期。
    sd_umount_overrides
    t0=$(date +%s)
    sd_build_overrides
    t1=$(date +%s)
    [ $((t1 - t0)) -gt 10 ] && sd_warn boot "配置生成耗时 $((t1 - t0))s 偏长（本阶段有超时限制）"
fi

# sd_mount_overrides 内部会先解挂旧的，避免重复条目
sd_mount_overrides

# 这里 sysfs 已就绪但多数系统服务还没起，zone 列表与 later 阶段可能不同，各记一份
sd_dump_env

sd_info boot "post-fs-data 完成"
exit 0
