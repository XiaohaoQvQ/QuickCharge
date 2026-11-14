#!/system/bin/sh
# ---------------------------------------------------------------
# Quick Charge (QC) — 源码完全公开，可自由查看、修改、分发。
# 禁止商业用途，禁止用于任何违反法律法规的场景。
# Fully open source. Commercial use and any unlawful use prohibited.
# ---------------------------------------------------------------

SD_DATA="${SD_DATA:-/data/adb/quickcharge}"
case "$SD_DATA" in ""|/|/data|/data/adb|/data/adb/) SD_DATA=/data/adb/quickcharge ;; esac

SD_MOUNTS="$SD_DATA/mounts.list"
SD_RUN="$SD_DATA/run"

MODDIR=""
read -r MODDIR 2>/dev/null <"$SD_DATA/moddir"
if [ -z "$MODDIR" ] || [ ! -d "$MODDIR/files" ]; then
    MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd)
fi

pid=""
read -r pid 2>/dev/null <"$SD_RUN/daemon.pid"
case "$pid" in
    ''|*[!0-9]*) ;;
    *)
        if [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null; then
            if [ -r "/proc/$pid/cmdline" ] && ! grep -q "service\.sh" "/proc/$pid/cmdline" 2>/dev/null; then
                :
            else
                kill -TERM "$pid" 2>/dev/null
                i=0
                while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
                    sleep 0.1
                    i=$((i + 1))
                done
                kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
            fi
        fi
        ;;
esac
rm -rf "$SD_RUN/daemon.lock" "$SD_RUN/daemon.pid" 2>/dev/null

unmount_one() {
    [ -n "$1" ] || return 0
    umount "$1" 2>/dev/null || umount -l "$1" 2>/dev/null
}

if [ -s "$SD_MOUNTS" ]; then
    sort -u "$SD_MOUNTS" 2>/dev/null | while IFS= read -r p; do
        case "$p" in /*) [ -f "$p" ] || continue ;; *) continue ;; esac
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

for z in /sys/class/thermal/thermal_zone*; do
    [ -d "$z" ] || continue
    [ -e "$z/emul_temp" ] && printf '0\n' 2>/dev/null >"$z/emul_temp"
    unmount_one "$z/temp"
done

for d in /dev/qc "${SD_SPOOF_DIR:-}"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    for f in "$d"/*.temp; do
        [ -f "$f" ] && rm -f "$f" 2>/dev/null
    done
    rmdir "$d" 2>/dev/null
done

if [ -e /proc/shell-temp ]; then
    t=0
    while [ "$t" -le 9 ]; do
        printf '%s 0\n' "$t" 2>/dev/null >/proc/shell-temp
        t=$((t + 1))
    done
fi

if [ -d /data/adb/modules/meta-nomount ] || [ -d /data/adb/modules/nomount ]; then
    for b in \
        /data/adb/modules/meta-nomount/bin/arm64-v8a/nomount \
        /data/adb/modules/nomount/bin/arm64-v8a/nomount
    do
        [ -x "$b" ] || continue
        if command -v timeout >/dev/null 2>&1; then
            timeout 20 "$b" reload >/dev/null 2>&1
        else
            "$b" reload >/dev/null 2>&1
        fi
        break
    done
fi

ST="$SD_DATA/state.conf"
if [ -f "$ST" ]; then
    sget() { sed -n "s/^$1=//p" "$ST" | tail -n 1; }
    if command -v settings >/dev/null 2>&1; then
        p=$(sget hz_prev_peak)
        m=$(sget hz_prev_min)
        case "$p" in
            ''|null|*[!0-9.]*) settings delete system peak_refresh_rate 2>/dev/null ;;
            *)                  settings put system peak_refresh_rate "$p" 2>/dev/null ;;
        esac
        case "$m" in
            ''|null|*[!0-9.]*) settings delete system min_refresh_rate 2>/dev/null ;;
            *)                  settings put system min_refresh_rate "$m" 2>/dev/null ;;
        esac
        pm=$(sget hz_prev_mcfr)
        case "$pm" in
            ''|none)
                settings delete secure match_content_frame_rate 2>/dev/null
                command -v cmd >/dev/null 2>&1 && \
                    cmd display set-match-content-frame-rate-policy 2 >/dev/null 2>&1 ;;
            1|2|3)
                settings put secure match_content_frame_rate "$pm" 2>/dev/null
                command -v cmd >/dev/null 2>&1 && \
                    cmd display set-match-content-frame-rate-policy "$pm" >/dev/null 2>&1 ;;
            *)
                settings put secure match_content_frame_rate 2 2>/dev/null
                command -v cmd >/dev/null 2>&1 && \
                    cmd display set-match-content-frame-rate-policy 2 >/dev/null 2>&1 ;;
        esac
    fi
    if [ "$(sget horae)" = "0" ] && command -v setprop >/dev/null 2>&1; then
        setprop persist.sys.horae.enable 1 2>/dev/null
        command -v start >/dev/null 2>&1 && start horae 2>/dev/null
    fi
fi

if [ -f "$SD_RUN/curr.orig" ]; then
    while IFS='|' read -r p o; do
        [ -n "$p" ] && [ -e "$p" ] || continue
        printf '%s\n' "$o" 2>/dev/null >"$p"
    done <"$SD_RUN/curr.orig"
fi

# 亮屏快充：屏幕状态参数先复位，再按 scr.orig 还原被回写过的节点
for p in /sys/module/oplus_chg/parameters/ignore_screen_state \
         /sys/module/oplus_chg_v2/parameters/ignore_screen_state \
         /sys/module/oplus_charge/parameters/ignore_screen_state \
         /sys/module/oplus_chg/parameters/chg_ignore_screen_state; do
    [ -e "$p" ] && printf '0\n' 2>/dev/null >"$p"
done
if [ -f "$SD_RUN/scr.orig" ]; then
    while IFS='|' read -r p o; do
        [ -n "$p" ] && [ -e "$p" ] || continue
        printf '%s\n' "$o" 2>/dev/null >"$p"
    done <"$SD_RUN/scr.orig"
fi

rm -rf "$SD_DATA" 2>/dev/null

exit 0
