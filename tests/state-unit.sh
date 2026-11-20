#!/bin/sh
# sd_module_state 三态：ok 运行中 / reboot 刚装完等重启 / dead 没跑起来
# 用法：sh tests/state-unit.sh
set -u
BASE=/tmp/qcs
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $3，实际 $2）"; fi; }

MOD=$(cd "$(dirname "$0")/.." && pwd)
MU=/data/adb/modules_update/quickcharge

up() { u=$(cut -d. -f1 /proc/uptime 2>/dev/null); case "$u" in ''|*[!0-9]*) u=100 ;; esac; printf '%s' "$u"; }

setup() {
    stop_daemon
    rm -rf "$BASE" "$MU"
    mkdir -p "$BASE/data/run" "$BASE/mod"
    cat >"$BASE/mod/service.sh" <<'EOF'
#!/system/bin/sh
sleep 60
EOF
}

# 起一个 cmdline 里带 service.sh 的进程，冒充守护
start_daemon() {
    sh "$BASE/mod/service.sh" &
    D_PID=$!
    sleep 0.2
    printf '%s\n' "$D_PID" >"$BASE/data/run/daemon.pid"
}

stop_daemon() {
    [ -n "${D_PID:-}" ] && kill "$D_PID" 2>/dev/null
    D_PID=""
}

hb() {  # $1=多少秒前的心跳
    printf '%s %s\n' "$(( $(up) - $1 ))" "${D_PID:-$$}" >"$BASE/data/run/hb"
}

run_sh() {
    SD_DATA=$BASE/data MODDIR=$MOD sh -c '. "$MODDIR/lib/qc.sh"; sd_state_load; '"$1" 2>/dev/null
}
state() { run_sh 'sd_module_state; printf "%s" "$_sd_ms"'; }
why()   { run_sh 'sd_module_state; printf "%s" "$_sd_ms_why"'; }

printf '模块状态三态\n'

# 1) 守护在跑、心跳新鲜 → ok
setup; start_daemon; hb 3
chk "守护存活且 3s 前心跳" "$(state)" ok
case "$(why)" in *"pid=$D_PID"*) ok "原因里带 pid" ;; *) bad "原因里没 pid：$(why)" ;; esac

# 2) 守护存活但 300s 没心跳 → dead（卡死，不该报运行中）
setup; start_daemon; hb 300
chk "守护 300s 没心跳" "$(state)" dead
case "$(why)" in *"没有心跳"*) ok "原因说明心跳停了" ;; *) bad "原因不明确：$(why)" ;; esac

# 3) pid 文件指向已死进程，但这次开机跑过启动脚本 → dead
setup
run_sh 'sd_boot_mark'
printf '999999\n' >"$BASE/data/run/daemon.pid"
chk "机跑过、守护没起" "$(state)" dead

# 4) 从没跑过启动脚本（全新安装没重启）→ reboot
setup
chk "没有 boot 标记" "$(state)" reboot

# 5) 安装脚本留了 need_reboot → reboot
setup
run_sh 'sd_boot_mark'
: >"$BASE/data/need_reboot"
chk "need_reboot 存在" "$(state)" reboot

# 6) 有 boot 标记但比本次开机早（上一轮重启留下的）→ reboot
setup
printf '%s\n' "$(( $(up) - 20 ))" >"$BASE/data/.boot_id"
chk "标记来自上一次开机" "$(state)" reboot

# 7) 更新包还在 modules_update → reboot
setup
mkdir -p "$MU" && { : >"$MU/module.prop"; } 2>/dev/null
if [ -f "$MU/module.prop" ]; then
    run_sh 'sd_boot_mark'
    chk "modules_update 在场" "$(state)" reboot
    rm -rf "$MU"
else
    printf '  skip modules_update（无法写入 %s）\n' "$MU"
fi

# 8) boot 标记正好落在本次开机 → 不会误判成 reboot
setup
run_sh 'sd_boot_mark'
chk "刚写完 boot 标记" "$(state)" dead
chk "boot_seen" "$(run_sh 'sd_boot_seen && echo 1 || echo 0')" 1

# 9) 没守护也不该把 dot 的状态搞错：ok 一定带心跳说明
setup; start_daemon; hb 1
case "$(why)" in *"心跳"*|*"刚启动"*) ok "ok 态原因可读" ;; *) bad "ok 态原因：$(why)" ;; esac

stop_daemon
rm -rf "$BASE" "$MU"
printf '\n通过 %s，失败 %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
