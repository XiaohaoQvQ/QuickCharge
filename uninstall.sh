#!/system/bin/sh
# 卸载脚本。目标：卸载后系统回到安装前的样子，不留挂载、不留进程、不留数据。
#
# 本脚本不引用 lib/ —— 那时模块目录可能已被 Magisk 移走，
# 所以路径常量和卸载逻辑都在这里自带一份。

SD_DATA="${SD_DATA:-/data/adb/quickcharge}"
case "$SD_DATA" in ""|/|/data|/data/adb|/data/adb/) SD_DATA=/data/adb/quickcharge ;; esac

SD_MOUNTS="$SD_DATA/mounts.list"
SD_RUN="$SD_DATA/run"

# 模块目录：优先用安装时记录的位置，其次按本脚本自身路径推导
MODDIR=""
read -r MODDIR 2>/dev/null <"$SD_DATA/moddir"
if [ -z "$MODDIR" ] || [ ! -d "$MODDIR/files" ]; then
    MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd)
fi

# ---------- 1. 停守护 ----------
# 必须校验 pid：daemon.pid 损坏成 1 时会直接杀掉 init，表现为"卸载模块导致重启"。
pid=""
read -r pid 2>/dev/null <"$SD_RUN/daemon.pid"
case "$pid" in
    ''|*[!0-9]*) ;;
    *)
        if [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null
            i=0
            while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
                sleep 0.1
                i=$((i + 1))
            done
            kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
        fi
        ;;
esac
rm -rf "$SD_RUN/daemon.lock" "$SD_RUN/daemon.pid" 2>/dev/null

# ---------- 2. 卸配置覆盖 ----------
# 两个来源：
#   a) mounts.list —— 挂载记录
#   b) 覆盖层目录反推 —— 清单丢失/截断时的兜底，否则不知道往哪卸，只能重启
#
# 反推按「目标路径精确匹配」，不看挂载源：源列在不同存储栈上表示不一致
# （overlay 环境直接显示 overlay），不可依赖。
# 只卸确实出现在 /proc/mounts 里的路径，不会误动其它模块的挂载。
unmount_one() {
    [ -n "$1" ] || return 0
    # 普通 umount 优先。lazy 不立即生效，随后的 rm -rf 会让挂载点指向
    # 已删除的 inode，表现就是"模块已卸载但配置还是改过的"。
    umount "$1" 2>/dev/null || umount -l "$1" 2>/dev/null
}

if [ -s "$SD_MOUNTS" ]; then
    sort -u "$SD_MOUNTS" 2>/dev/null | while IFS= read -r p; do
        unmount_one "$p"
    done
fi

if [ -n "$MODDIR" ] && [ -d "$MODDIR/files" ]; then
    mp=$(awk '{print $2}' /proc/mounts 2>/dev/null)
    ( cd "$MODDIR/files" 2>/dev/null || exit 0
      find . -type f 2>/dev/null | while IFS= read -r rel; do
          dst="/${rel#./}"
          printf '%s\n' "$mp" | grep -qxF "$dst" && unmount_one "$dst"
      done )
fi

# ---------- 3. 撤销温度伪装 ----------
# emul_temp 写 0 = 关闭模拟；temp 节点的 bind mount 逐个卸掉。
for z in /sys/class/thermal/thermal_zone*; do
    [ -d "$z" ] || continue
    [ -e "$z/emul_temp" ] && printf '0\n' 2>/dev/null >"$z/emul_temp"
    unmount_one "$z/temp"
done

# OPPO 私有节点：10 个壳温通道全部归零
if [ -e /proc/shell-temp ]; then
    t=0
    while [ "$t" -le 9 ]; do
        printf '%s 0\n' "$t" 2>/dev/null >/proc/shell-temp
        t=$((t + 1))
    done
fi

# ---------- 4. 清理数据 ----------
# 备份目录一并删除。想保留原始配置做排查，注释掉这一行。
rm -rf "$SD_DATA" 2>/dev/null

exit 0
