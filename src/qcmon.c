/*
 * qcmon — Quick Charge 守护进程（C 版）
 *
 * 源码完全公开 · 禁止商用与非法用途
 *
 * 与 lib/qc.sh 的 sd_daemon 一一对应，覆盖同样的热路径：
 *   温区扫描 → 屏幕状态 → 电流墙 → 亮屏快充 → 伪装补齐 → 电池伪装
 *   → 熔断/冷却恢复 → 温度模式（壳温动态上报 / 仅充电 / 关闭）
 *   → 遥测 → 高刷补写 → 描述同步
 *
 * 状态文件名、日志格式、节点单位判定与 shell 版完全一致，两版可以互换，
 * WebUI 与 action.sh 不需要区分当前跑的是哪一个。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <ctype.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/types.h>
#include <sys/wait.h>

/* 版本号由 build-qcmon.sh 从 module.prop 注入，手改源码不会再和包版本脱节 */
#ifndef QC_VER
#define QC_VER "dev"
#endif
#define VER QC_VER

#define MAXZ 192
#define MAXLINE 512
#define MAXPATH 256

/* 侵入作用域。shell 版没有单独的 shell 作用域：壳温走 emul_temp，不走 bind mount */
enum { SC_CORE = 1, SC_NONCORE, SC_BATT };

/* 温区分类，与 sd_zone_class 一一对应 */
enum { C_OTHER = 0, C_BATTERY, C_SHELL, C_CORE, C_BOARD };

static const char *CLS_NAME[] = { "other", "battery", "shell", "core", "board" };

typedef struct {
    char path[MAXPATH];
    char type[64];
    int cls;
} zone_t;

static zone_t g_z[MAXZ];
static int g_zn = 0;
static int g_scanned = 0;
static int g_temp_fail = 0;

/* 配置，键名与 state.conf 相同 */
typedef struct {
    char temp_mode[16];
    int shell_temp;      /* 0=off */
    int core_temp;
    int noncore_temp;
    int batt_spoof;      /* 0=off */
    int tick;
    int chg_unlock;       /* 1=压 0 解除 HAL 阶梯限流 */
    int log_level;
    char hz[8];          /* "off" 或数值 */
    int hz_hard;
    char hz_prev_mcfr[16];
} conf_t;

static conf_t g_c;

static char g_data[MAXPATH] = "/data/adb/quickcharge";
static char g_adb[128] = "/data/adb";   /* 元模块目录的父路径，测试可用 SD_ADB 覆盖 */
static char g_state[300];
static char g_log[320];
static char g_log_old[320];
static char g_run[300];
static char g_moddir[MAXPATH] = "";
static char g_sys[128] = "";       /* 测试用：把 / 换成别的根，真机留空 */

static char g_ps[MAXPATH];
static char g_therm[MAXPATH];
static char g_zone_pref[64] = "thermal_zone";
static char g_bl[MAXPATH];
static char g_fb[MAXPATH];
static char g_oplus[MAXPATH];
static char g_shellproc[MAXPATH];

/* 运行时状态文件，命名与 shell 版一致 */
static char g_scr_orig[320], g_scr_way[320], g_scr_fail[320], g_fcc_norm[320];
static char g_unlock_orig[320];
static char g_curr_orig[320], g_curr_want[320];
static char g_spoof_flag[320];
static char g_sensor[320];
static char g_hb[320];

static volatile sig_atomic_t g_stop = 0;
static volatile sig_atomic_t g_reload = 0;

static int g_screen_on = 1;
static int g_screen_n = 0;
static char g_bl_list[16][MAXPATH];
static int g_bl_cnt = -1;
static int g_fb_blank = -1;

static char g_plat[8] = "";
static int g_tick_n = 0;

/* 遥测字段（对应 shell 的 _sd_last_cur 等） */
static char g_tl_real[24] = "";
static char g_tl_lim[16] = "";
static char g_tl_zone[64] = "";
static char g_tl_out[16] = "";
static int g_emul_ok = -1;

/* 熔断 */

/* 上次成功应用的 core / noncore 目标，-1 表示未应用 */
static int g_core_last = -1, g_nc_last = -1;

/* 域不残留：上次伪装目标值，用来判断"这一轮要不要重做" */
static int g_spoof_val[5] = { 0, 0, 0, 0, 0 };
static int g_spoof_ok[5] = { 0, 0, 0, 0, 0 };
static int g_spoof_force = 0;

/* 电池伪装 */
static int g_batt_sp_on = 0;
static int g_batt_sp_last = 0;

/* 亮屏快充 */
static int g_scr_on = 0;
static char g_scr_way_s[16] = "";
static int g_scr_cur = 0;          /* 接管时 FCC 节点实读值，只用于日志 */
static char g_scr_node[64] = "";

/* 高刷 */
static int g_hz_bad = 0;

/* 日志轮转计数 */
static int g_log_rot = 0;

/* ------------------------------------------------------------------ 基础 */

static void on_term(int s) { (void)s; g_stop = 1; }
static void on_usr1(int s) { (void)s; g_reload = 1; }

/* 清理/熔断恢复会回写 module.prop 描述，先声明 */
static void sync_desc(void);
/* 壳温写入带缓存，模式切换时要能重置 */
static void shell_emul_reset(void);
/* 降流解除要读电池电流，定义在快照段 */
static long chg_current(void);

/* 静态二进制拿不到 Android 的时区库（没有 /usr/share/zoneinfo），
 * localtime_r 会直接落到 UTC，日志比本地时间早 8 小时，和脚本打的行对不上。
 * 启动时问一次 busybox 的日期偏移，拼成 POSIX TZ 串（+0800 → "XXX-8"），
 * 这种写法不依赖 tzdata。 */
static void tz_init(void)
{
    /* service.sh 一定跑在正常环境里，date 拿得到偏移；先认它导出的 SD_TZ，
     * 免得静态二进制里 popen 找不到 sh / date 时整份日志退回 UTC。 */
    const char *env = getenv("SD_TZ");
    char b[16] = {0};
    FILE *f = NULL;
    if (env && (env[0] == '+' || env[0] == '-')) {
        snprintf(b, sizeof b, "%s", env);
    } else {
        f = popen("/system/bin/date +%z 2>/dev/null", "r");
        if (!f) f = popen("date +%z 2>/dev/null", "r");
        if (!f) return;
        if (!fgets(b, sizeof b, f) || !(b[0] == '+' || b[0] == '-')) {
            pclose(f);
            return;
        }
    }
    if (isdigit((unsigned char)b[1]) && isdigit((unsigned char)b[2]) &&
        isdigit((unsigned char)b[3]) && isdigit((unsigned char)b[4])) {
        int hh = (b[1] - '0') * 10 + (b[2] - '0');
        int mm = (b[3] - '0') * 10 + (b[4] - '0');
        if (hh <= 14 && mm < 60) {
            char tz[32];
            /* POSIX 的符号与直觉相反：TZ="XXX-8" 表示 UTC+8 */
            snprintf(tz, sizeof tz, "XXX%c%d:%02d", b[0] == '-' ? '+' : '-', hh, mm);
            setenv("TZ", tz, 1);
            tzset();
        }
    }
    if (f) pclose(f);
}

static void ts_str(char *out, size_t n)
{
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(out, n, "%m-%d %H:%M:%S", &tm);
}

/* 拼一个以 g_sys 为根的绝对路径 */
static const char *rp(const char *rel, char *out, size_t n)
{
    snprintf(out, n, "%s%s", g_sys, rel);
    return out;
}

/* 读一行，去掉首尾空白与 CR。成功返回 0。 */
static int read_line(const char *path, char *buf, size_t n)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t r = read(fd, buf, n - 1);
    close(fd);
    if (r <= 0) return -1;
    buf[r] = 0;
    char *p = buf;
    while (*p == ' ' || *p == '\t') p++;
    char *e = p + strlen(p);
    while (e > p && (e[-1] == '\n' || e[-1] == '\r' || e[-1] == ' ' || e[-1] == '\t')) e--;
    *e = 0;
    if (p != buf) memmove(buf, p, strlen(p) + 1);
    return buf[0] ? 0 : -1;
}

static int read_int(const char *path, int *out)
{
    char b[64];
    if (read_line(path, b, sizeof b) < 0) return -1;
    char *end = NULL;
    long v = strtol(b, &end, 10);
    if (end == b) return -1;
    *out = (int)v;
    return 0;
}

static int write_str(const char *path, const char *s)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC | O_TRUNC, 0644);
    if (fd < 0) return -1;
    size_t len = strlen(s);
    ssize_t w = write(fd, s, len);
    close(fd);
    return (w == (ssize_t)len) ? 0 : -1;
}

static void log_msg(const char *lvl, const char *tag, const char *fmt, ...)
{
    char t[32], msg[400], line[512];
    va_list ap;
    const char *l = "I";
    int need = 1;

    /* 与 shell 版一致：0 关（只留 E）/ 1 事件 / 2 现场 / 3 逐轮 / 4 调试。
     * 以前 I 级不看级别，log_level=0 也照样写，用户关了日志还在长。 */
    if (lvl && lvl[0] == 'W') { l = "W"; need = 1; }
    else if (lvl && lvl[0] == 'E') { l = "E"; need = 0; }
    else if (lvl && lvl[0] == 'D') { l = "D"; need = 3; }
    else { l = "I"; need = 1; }
    if (g_c.log_level < need) return;

    ts_str(t, sizeof t);
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    snprintf(line, sizeof line, "%s %s [%s] %s\n", t, l, tag, msg);

    int fd = open(g_log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) return;
    if (write(fd, line, strlen(line)) < 0) { /* 日志写失败不影响守护 */ }
    close(fd);

    /* 与 shell 版一致：每 64 条看一次体积，超过 512KB 轮转一次 */
    g_log_rot++;
    if ((g_log_rot & 63) == 0) {
        struct stat st;
        if (stat(g_log, &st) == 0 && st.st_size > 524288) rename(g_log, g_log_old);
    }
}

static void mkdir_p(const char *p)
{
    char tmp[300];
    snprintf(tmp, sizeof tmp, "%s", p);
    for (char *s = tmp + 1; *s; s++) {
        if (*s == '/') { *s = 0; mkdir(tmp, 0755); *s = '/'; }
    }
    mkdir(tmp, 0755);
}

static int up_ticks(void)
{
    char p[MAXPATH], b[64];
    if (read_line(rp("/proc/uptime", p, sizeof p), b, sizeof b) < 0) return 0;
    return atoi(b);
}

/* ------------------------------------------------------------------ 配置 */

static void conf_defaults(void)
{
    memset(&g_c, 0, sizeof g_c);
    snprintf(g_c.temp_mode, sizeof g_c.temp_mode, "off");
    snprintf(g_c.hz, sizeof g_c.hz, "off");
    g_c.shell_temp = 30;   /* 与 shell 侧 sd_shell_target 的缺省一致 */
    g_c.tick = 15;
    g_c.chg_unlock = 0;
    /* 默认事件级：0 只留 E，日志面板会空得没法排查 */
    g_c.log_level = 1;
}

static int parse_i(const char *v, int def)
{
    if (!v || !*v) return def;
    if (!strcmp(v, "off")) return 0;
    char *e = NULL;
    long n = strtol(v, &e, 10);
    if (e == v) return def;
    return (int)n;
}

/* 只读 state.conf 里仍在用的键，删掉的键（wall/aggr/curr_max 等）出现也不认 */
static void conf_load(void)
{
    FILE *f = fopen(g_state, "r");
    if (!f) return;
    char line[MAXLINE];
    conf_defaults();
    while (fgets(line, sizeof line, f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || !*p) continue;
        char *eq = strchr(p, '=');
        if (!eq) continue;
        *eq = 0;
        char *k = p, *v = eq + 1;
        char *e = v + strlen(v);
        while (e > v && (e[-1] == '\n' || e[-1] == '\r' || e[-1] == ' ' || e[-1] == '\t')) *--e = 0;

        if (!strcmp(k, "temp_mode")) snprintf(g_c.temp_mode, sizeof g_c.temp_mode, "%s", v);
        else if (!strcmp(k, "shell_temp")) g_c.shell_temp = parse_i(v, 30);
        else if (!strcmp(k, "core_temp")) g_c.core_temp = parse_i(v, 0);
        else if (!strcmp(k, "noncore_temp")) g_c.noncore_temp = parse_i(v, 0);
        else if (!strcmp(k, "batt_spoof")) g_c.batt_spoof = parse_i(v, 0);
        else if (!strcmp(k, "tick")) g_c.tick = parse_i(v, 15);
        else if (!strcmp(k, "chg_unlock")) g_c.chg_unlock = parse_i(v, 0);
        else if (!strcmp(k, "log_level")) g_c.log_level = parse_i(v, 1);
        else if (!strcmp(k, "hz")) snprintf(g_c.hz, sizeof g_c.hz, "%s", v);
        else if (!strcmp(k, "hz_hard")) g_c.hz_hard = parse_i(v, 0);
        else if (!strcmp(k, "hz_prev_mcfr")) snprintf(g_c.hz_prev_mcfr, sizeof g_c.hz_prev_mcfr, "%s", v);
    }
    fclose(f);

    /* 与 shell 版 _sd_clamp 的兜底值保持一致 */
    if (g_c.tick < 5 || g_c.tick > 300) g_c.tick = 15;
    if (g_c.shell_temp < 20 || g_c.shell_temp > 33) g_c.shell_temp = 30;
    if (g_c.log_level < 0 || g_c.log_level > 4) g_c.log_level = 1;
    if (g_c.temp_mode[0] == 0) snprintf(g_c.temp_mode, sizeof g_c.temp_mode, "off");
    /* dyn 是旧键值，等价 static */
    if (!strcmp(g_c.temp_mode, "dyn")) snprintf(g_c.temp_mode, sizeof g_c.temp_mode, "static");
}

/* 只改一行，其余保留。用于 batt_spoof 自行关闭等场景 */
static int state_set(const char *k, const char *v)
{
    char buf[8192], out[8192], tmp[340];
    int fd = open(g_state, O_RDONLY | O_CLOEXEC);
    ssize_t r = 0;
    if (fd >= 0) {
        r = read(fd, buf, sizeof buf - 1);
        close(fd);
        if (r < 0) r = 0;
    }
    buf[r] = 0;

    size_t o = 0;
    int found = 0;
    char *p = buf;
    while (*p) {
        char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) + 1 : strlen(p);
        char tmpk[64];
        size_t kl = 0;
        while (kl < len && kl < sizeof tmpk - 1 && p[kl] != '=') kl++;
        memcpy(tmpk, p, kl);
        tmpk[kl] = 0;
        int w = (kl < len && !strcmp(tmpk, k));
        if (w) {
            o += snprintf(out + o, sizeof out - o, "%s=%s\n", k, v);
            found = 1;
        } else {
            if (o + len < sizeof out) { memcpy(out + o, p, len); o += len; }
        }
        if (!nl) break;
        p = nl + 1;
    }
    if (!found) o += snprintf(out + o, sizeof out - o, "%s=%s\n", k, v);
    out[o] = 0;

    snprintf(tmp, sizeof tmp, "%s.t.%d", g_state, (int)getpid());
    if (write_str(tmp, out) < 0) return -1;
    if (rename(tmp, g_state) < 0) { unlink(tmp); return -1; }
    return 0;
}

/* ------------------------------------------------------------------ 温区 */

/* 与 sd_zone_is_not_temp 一致：这些不是温度节点 */
static int is_not_temp(const char *t)
{
    if (!t || !*t) return 0;
    if (strstr(t, "hw-trip") || strstr(t, "hw_trip")) return 1;
    if (strstr(t, "bcl-lvl") || strstr(t, "bcl_lvl")) return 1;
    if (strstr(t, "ibat-lvl") || strstr(t, "ibat_lvl")) return 1;
    if (!strncmp(t, "vbat", 4) || !strncmp(t, "vbatt", 5)) return 1;
    return 0;
}

/* 与 sd_zone_is_hot_load 一致：充电器/无线/功放这类热点，不参与伪装 */
static int is_hot_load(const char *t)
{
    if (!t || !*t) return 0;
    size_t n = strlen(t);
    if (n >= 2 && !strcmp(t + n - 2, "pa")) return 1;
    if (n >= 3 && !strcmp(t + n - 3, "_pa")) return 1;
    if (strstr(t, "wifi") || strstr(t, "wlan")) return 1;
    if (strstr(t, "mtktswmt") || strstr(t, "mtktsbtsmdpa")) return 1;
    return 0;
}

static int cls_of(const char *t)
{
    if (!t || !*t) return C_OTHER;
    if (is_not_temp(t)) return C_OTHER;
    if (strstr(t, "batt") || strstr(t, "Batt")) return C_BATTERY;
    if (strstr(t, "shell") || strstr(t, "Shell") || strstr(t, "back") ||
        strstr(t, "case") || strstr(t, "skin") || strstr(t, "cover") ||
        strstr(t, "frame")) return C_SHELL;
    if (strstr(t, "cpu") || strstr(t, "CPU") || strstr(t, "cpullc") ||
        strstr(t, "cpuss") || strstr(t, "gpu") || strstr(t, "GPU") ||
        strstr(t, "ddr") || strstr(t, "mtktsap") || strstr(t, "mtktsabb") ||
        strstr(t, "tzts") || strstr(t, "tsen_max") || strstr(t, "soc") ||
        strstr(t, "Soc") || !strncmp(t, "ap", 2) || strstr(t, "ap0")) return C_CORE;
    if (strstr(t, "xo-therm") || strstr(t, "xtherm") || strstr(t, "pmic") ||
        strstr(t, "charger") || strstr(t, "board") || strstr(t, "sys-therm") ||
        strstr(t, "mtktspa") || strstr(t, "mtktswmt") || strstr(t, "mtktsbtsmdpa") ||
        !strcmp(t, "pa") || strstr(t, "pm") ) {
        /* pm 开头的 *_tz 也要算 board，但不能把 "pmic" 之外的杂项吞掉 */
        if (!strcmp(t, "pa") || strstr(t, "therm") || strstr(t, "pmic") ||
            strstr(t, "charger") || strstr(t, "board") || strstr(t, "mtkts") ||
            strstr(t, "pm8") || strstr(t, "pmr") || strstr(t, "pm5") ||
            strstr(t, "pm6") || strstr(t, "pm7")) return C_BOARD;
    }
    return C_OTHER;
}

/* 伪装作用域，与 sd_zone_in_scope 一致 */
static int in_scope(const char *t, int scope)
{
    if (is_not_temp(t)) return 0;
    int c = cls_of(t);
    switch (scope) {
        case SC_CORE:
            return c == C_CORE;
        case SC_BATT:
            return c == C_BATTERY && !is_hot_load(t);
        case SC_NONCORE:
            if (c == C_CORE || c == C_SHELL) return 0;
            if (c == C_BATTERY || c == C_BOARD) return 0;
            return 1;
        default:
            return 0;
    }
}

/* core 无候选时的兜底：与 _sd_spoof_fallback_ok 一致 */
static int fallback_ok(const char *t)
{
    if (is_not_temp(t)) return 0;
    int c = cls_of(t);
    if (c == C_BATTERY || c == C_BOARD || c == C_SHELL) return 0;
    if (is_hot_load(t)) return 0;
    return 1;
}

/* 温度归一：>=2000 毫度、>=150 十分之一度、其余摄氏度；负数与 >150 视为无效 */
static int temp_norm(const char *s)
{
    char t[32];
    size_t i = 0;
    if (!s || !*s) return -1000;
    while (s[i] && i < sizeof t - 1) { t[i] = s[i]; i++; }
    t[i] = 0;
    char *dot = strchr(t, '.');
    if (dot) *dot = 0;
    if (!t[0]) return -1000;
    for (char *p = t; *p; p++)
        if (*p < '0' || *p > '9') return -1000;
    long v = atol(t);
    if (v >= 2000) v /= 1000;
    else if (v >= 150) v /= 10;
    if (v > 150) return -1000;
    return (int)v;
}

static int zone_temp(const zone_t *z)
{
    char b[MAXPATH + 8], v[64];
    snprintf(b, sizeof b, "%s/temp", z->path);
    if (read_line(b, v, sizeof v) < 0) return -1000;
    return temp_norm(v);
}

/* 写伪装时按当前读数推断单位，与 sd_zone_temp_unit 一致 */
static int zone_unit(const char *zp)
{
    char b[MAXPATH + 8], v[64];
    snprintf(b, sizeof b, "%s/temp", zp);
    if (read_line(b, v, sizeof v) < 0) return 0;   /* 毫度 */
    char *dot = strchr(v, '.');
    if (dot) *dot = 0;
    long n = atol(v);
    if (n >= 2000) return 0;
    if (n >= 150) return 1;
    return 2;
}

static void zones_scan(void)
{
    g_zn = 0;
    g_temp_fail = 0;
    DIR *d = opendir(g_therm);
    if (!d) { g_scanned = 1; return; }
    struct dirent *de;
    while ((de = readdir(d)) && g_zn < MAXZ) {
        if (strncmp(de->d_name, g_zone_pref, strlen(g_zone_pref))) continue;
        zone_t *z = &g_z[g_zn];
        snprintf(z->path, sizeof z->path, "%s/%s", g_therm, de->d_name);
        char tp[MAXPATH + 8];
        snprintf(tp, sizeof tp, "%s/type", z->path);
        if (read_line(tp, z->type, sizeof z->type) < 0) continue;
        z->cls = cls_of(z->type);
        g_zn++;
    }
    closedir(d);
    g_scanned = 1;
    g_spoof_force = 1;   /* 重扫后节点可能变了，伪装必须重做一遍 */
    log_msg("D", "scan", "温区 %d 个", g_zn);
}

/* ------------------------------------------------------------------ 电池 */

static const char *PS_NODES[] = { "battery", "mtk-battery", "mtk-gauge", "bms", NULL };

static int ps_attr(const char *attr, char *out, size_t n)
{
    for (int i = 0; PS_NODES[i]; i++) {
        char p[MAXPATH + 96];
        snprintf(p, sizeof p, "%s/%s/%s", g_ps, PS_NODES[i], attr);
        if (read_line(p, out, n) == 0) return 0;
    }
    return -1;
}

static int batt_status(char *out, size_t n)
{
    if (ps_attr("status", out, n) == 0) return 0;
    snprintf(out, n, "Unknown");
    return -1;
}

/* 与 sd_batt_temp_v 一致：四个 temp 节点，再退到 uevent 的 TEMP= */
static int batt_temp_ps(void)
{
    char b[128], p[MAXPATH + 96];
    for (int i = 0; PS_NODES[i]; i++) {
        snprintf(p, sizeof p, "%s/%s/temp", g_ps, PS_NODES[i]);
        if (read_line(p, b, sizeof b) < 0) continue;
        int v = temp_norm(b);
        if (v >= 10 && v <= 120) return v;
    }
    for (int i = 0; PS_NODES[i]; i++) {
        snprintf(p, sizeof p, "%s/%s/uevent", g_ps, PS_NODES[i]);
        FILE *f = fopen(p, "r");
        if (!f) continue;
        while (fgets(b, sizeof b, f)) {
            if (!strncmp(b, "TEMP=", 5)) {
                int v = temp_norm(b + 5);
                if (v >= 10 && v <= 120) { fclose(f); return v; }
            }
        }
        fclose(f);
    }
    return -1000;
}/* ------------------------------------------------------------------ 哨兵 */

/* 电池类温区分三档：0 = 电芯本体，1 = 其它 batt*，2 = 连接器/充电侧。
 * 一加/OPPO 上 batt-therm 挂在电池连接器旁，比电芯 NTC 高 8~12℃，
 * 直接当电池用会让 real 虚高、壳温目标算高，还容易顶到温度墙熔断。 */
static int batt_rank(const char *t)
{
    if (!t || !*t) return 9;
    if (strstr(t, "therm") || strstr(t, "conn") || strstr(t, "chg")) return 2;
    if (!strcasecmp(t, "battery") || !strcasecmp(t, "batt")) return 0;
    return 1;
}

static int pick_batt_zone(int *zi)
{
    int best = -1, bestr = 9;
    for (int i = 0; i < g_zn; i++) {
        if (g_z[i].cls != C_BATTERY) continue;
        if (is_hot_load(g_z[i].type)) continue;
        if (zone_temp(&g_z[i]) < -100) continue;
        int r = batt_rank(g_z[i].type);
        if (r < bestr) { bestr = r; best = i; if (r == 0) break; }
    }
    if (best < 0) return -1;
    *zi = best;
    return 0;
}

/* 1 = 本次 real 取自电量计（温区判为连接器侧或温区不可用），遥测里的 zone 要跟着改 */
static int g_batt_ps;

/* 与 sd_batt_best_v 一致：温区值与电量计值都在合理区间时优先温区，
 * 但温区明显高于电量计（连接器侧）时改用电量计。 */
static int batt_best(int zi, int *out)
{
    int zv = -1000, pv = -1000;
    g_batt_ps = 0;
    if (zi >= 0) {
        zv = zone_temp(&g_z[zi]);
        if (zv < 8 || zv > 90) zv = -1000;
    }
    pv = batt_temp_ps();
    if (pv >= 5 && pv <= 80) { /* keep */ } else pv = -1000;

    if (zv > -100 && pv > -100) {
        if (batt_rank(g_z[zi].type) > 0 && zv - pv > 8) { g_batt_ps = 1; *out = pv; return 0; }
        *out = zv;
        return 0;
    }
    if (zv > -100) { *out = zv; return 0; }
    if (pv > -100) { g_batt_ps = 1; *out = pv; return 0; }
    return -1;
}

static int pick_sentinel(int *zi, int *cls_out)
{
    static const int PASSES[] = { C_BATTERY, C_BOARD, C_OTHER, -1 };
    for (int p = 0; PASSES[p] >= 0; p++) {
        for (int i = 0; i < g_zn; i++) {
            if (g_z[i].cls != PASSES[p]) continue;
            if (is_hot_load(g_z[i].type)) continue;
            if (zone_temp(&g_z[i]) < -100) continue;
            *zi = i;
            if (cls_out) *cls_out = g_z[i].cls;
            return 0;
        }
    }
    /* 最后一轮：热点也认，总比没有哨兵强 */
    for (int i = 0; i < g_zn; i++) {
        if (!is_hot_load(g_z[i].type)) continue;
        if (g_z[i].cls == C_CORE || g_z[i].cls == C_SHELL) continue;
        if (zone_temp(&g_z[i]) < -100) continue;
        *zi = i;
        if (cls_out) *cls_out = g_z[i].cls;
        return 0;
    }
    return -1;
}

static int batt_spoof_on(void)
{
    return g_c.batt_spoof >= 20 && g_c.batt_spoof <= 45;
}

/* 哨兵温度：电池伪装开着时必须读电量计，否则读到的就是自己写进去的假值 */
static int sentinel_temp(int zi, int *out)
{
    if (zi < 0) return -1;
    if (g_z[zi].cls == C_BATTERY) {
        if (batt_spoof_on()) {
            int v = batt_temp_ps();
            if (v > -100) { *out = v; return 0; }
        }
        return batt_best(zi, out);
    }
    int v = zone_temp(&g_z[zi]);
    if (v < -100) return -1;
    *out = v;
    return 0;
}

/* 熔断读数入口：电池类取两源较高值，其余温区只有一个源 *//* 与 sd_limit_for_type_v 一致：-1 表示关闭 */
/* ------------------------------------------------------------------ 伪装 */

static char g_spoof_dir[MAXPATH] = "/dev/qc";

/* 确保伪装落点可用；返回实际目录 */
static const char *spoof_dir(void)
{
    const char *env = getenv("SD_SPOOF_DIR");
    if (env && *env) {
        mkdir_p(env);
        chmod(env, 0700);
        if (access(env, W_OK) == 0) return env;
    }
    mkdir_p(g_spoof_dir);
    chmod(g_spoof_dir, 0700);
    if (access(g_spoof_dir, W_OK) == 0) return g_spoof_dir;
    return g_run;
}

static int spoof_one(zone_t *z, int celsius)
{
    int unit = zone_unit(z->path);
    int ms = unit == 1 ? celsius * 10 : (unit == 2 ? celsius : celsius * 1000);

    char target[MAXPATH + 8];
    snprintf(target, sizeof target, "%s/temp", z->path);
    umount2(target, MNT_DETACH);

    const char *base = strrchr(z->path, '/');
    base = base ? base + 1 : z->path;
    const char *sd = spoof_dir();

    char tf[MAXPATH + 64], body[24];
    snprintf(body, sizeof body, "%d\n", ms);
    snprintf(tf, sizeof tf, "%s/%s.temp", sd, base);
    if (write_str(tf, body) < 0) {
        snprintf(tf, sizeof tf, "%s/%s.temp", g_run, base);
        if (write_str(tf, body) < 0) return -1;
    }
    chmod(tf, 0644);
    if (mount(tf, target, NULL, MS_BIND, NULL) < 0) return -1;
    return 0;
}

/* core 分类完全没命中时（部分机型的 type 名不规范），放宽到"非电池/非板级/非壳温" */
static int scope_fallback(int scope, int sent)
{
    if (scope != SC_CORE) return 0;
    for (int i = 0; i < g_zn; i++) {
        if (i == sent) continue;
        if (in_scope(g_z[i].type, SC_CORE)) return 0;
    }
    return 1;
}

/* 作用域内是否全已达到目标值（稳态下就不用反复 umount/mount） */
static int spoof_satisfied(int scope, int celsius, int *total)
{
    int ok = 0, need = 0, sent = -1;
    pick_sentinel(&sent, NULL);
    int fallback = scope_fallback(scope, sent);
    for (int i = 0; i < g_zn; i++) {
        zone_t *z = &g_z[i];
        if (scope != SC_BATT && i == sent) continue;
        int in = in_scope(z->type, scope);
        if (!in && fallback && fallback_ok(z->type)) in = 1;
        if (!in) continue;
        int t = zone_temp(z);
        if (t < -100) continue;
        need++;
        if (t == celsius) ok++;
    }
    if (total) *total = need;
    return need > 0 && ok == need;
}

static int spoof_apply(int scope, int celsius, int quiet)
{
    if (celsius < 20 || celsius > 100) {
        log_msg("E", "thermal", "伪温度超出合理范围(20-100℃): %d", celsius);
        return -1;
    }
    if (scope == SC_BATT && celsius > 45) {
        log_msg("E", "thermal", "电池伪装上限 45℃: %d", celsius);
        return -1;
    }
    if (g_zn == 0) zones_scan();

    int total = 0;
    if (!g_spoof_force && g_spoof_ok[scope] && g_spoof_val[scope] == celsius &&
        spoof_satisfied(scope, celsius, &total)) {
        return 0;
    }

    int prev = g_spoof_val[scope] ? g_spoof_val[scope] : -1;
    int sent = -1;
    pick_sentinel(&sent, NULL);
    int fallback = scope_fallback(scope, sent);

    int hit = 0, fail = 0;
    for (int i = 0; i < g_zn; i++) {
        zone_t *z = &g_z[i];
        if (scope != SC_BATT && i == sent) continue;
        int in = in_scope(z->type, scope);
        if (!in && fallback && fallback_ok(z->type)) in = 1;
        if (!in) continue;
        int t = zone_temp(z);
        if (t < -100) continue;
        if (t == celsius) { hit++; continue; }
        if (spoof_one(z, celsius) == 0) hit++;
        else fail++;
    }

    const char *sn = scope == SC_CORE ? "core" : (scope == SC_NONCORE ? "noncore" : "batt");
    if (hit > 0) {
        g_spoof_val[scope] = celsius;
        g_spoof_ok[scope] = 1;
        /* 只有目标值变了才打日志，否则每轮刷屏 */
        if (!quiet || prev != celsius)
            log_msg("I", "thermal", "伪装 %s → %d℃，命中 %d，失败 %d", sn, celsius, hit, fail);
    } else {
        g_spoof_ok[scope] = 0;
        g_spoof_val[scope] = celsius;   /* 记住这次尝试，下一轮同值不再重复告警 */
        if (prev != celsius)
            log_msg("W", "thermal", "伪装 %s → %d℃ 未命中任何节点（失败 %d）", sn, celsius, fail);
    }
    g_spoof_force = 0;
    return hit > 0 ? 0 : -1;
}

static void spoof_clear(void)
{
    for (int i = 0; i < g_zn; i++) {
        char p[MAXPATH + 8];
        snprintf(p, sizeof p, "%s/temp", g_z[i].path);
        umount2(p, MNT_DETACH);
    }
    for (int s = 0; s < 5; s++) { g_spoof_ok[s] = 0; g_spoof_val[s] = 0; }
}

static void spoof_clear_scope(int scope)
{
    int n = 0;
    for (int i = 0; i < g_zn; i++) {
        if (!in_scope(g_z[i].type, scope)) continue;
        char p[MAXPATH + 8];
        snprintf(p, sizeof p, "%s/temp", g_z[i].path);
        if (umount2(p, MNT_DETACH) == 0) n++;
    }
    g_spoof_ok[scope] = 0;
    if (n > 0) log_msg("D", "thermal", "撤销作用域 %d 伪装，解除 %d 个节点", scope, n);
}

/* ------------------------------------------------------------------ 壳温模拟 */

/* 与 sd_shell_emul 一致：写 shell 类节点的 emul_temp，再补 /proc/shell-temp */
static int g_emul_last = -1;

static void shell_emul_reset(void) { g_emul_last = -1; }

static void shell_emul(int celsius)
{
    if (celsius == g_emul_last) return;
    g_emul_last = celsius;

    int ms = celsius * 1000, n = 0, ps = 0;
    for (int i = 0; i < g_zn; i++) {
        if (g_z[i].cls != C_SHELL) continue;
        char p[MAXPATH + 16];
        snprintf(p, sizeof p, "%s/emul_temp", g_z[i].path);
        if (access(p, W_OK) != 0) continue;
        char b[24];
        snprintf(b, sizeof b, "%d\n", ms);
        if (write_str(p, b) == 0) n++;
    }
    /* 与 sd_shell_emul 一致：/proc/shell-temp 没有「写 0 = 关闭模拟」的语义，
     * 写 0 会被读成 0℃，插电头几秒进低温保护（锁 5V/500mA）。关闭时干脆不写，
     * 交还驱动自己更新；写死 30℃ 又会让节点永久停在假值。 */
    if (celsius != 0 && access(g_shellproc, W_OK) == 0) {
        for (int t = 0; t <= 9; t++) {
            char b[32];
            snprintf(b, sizeof b, "%d %d\n", t, ms);
            if (write_str(g_shellproc, b) == 0) ps = 1;
        }
    }

    if (celsius == 0) g_emul_ok = 1;
    else if (n > 0 || ps > 0) g_emul_ok = 1;
    else {
        g_emul_ok = 0;
        log_msg("W", "thermal", "壳温节点不可写（无 emul_temp 或权限被拒），目标 %d℃", celsius);
    }
}

/* ------------------------------------------------------------------ 电流墙 */

#define MAXCURR 12
static char g_curr_nodes[MAXCURR][MAXPATH];
static int g_curr_n = 0;

static void plat_resolve(void)
{
    if (g_plat[0]) return;
    char b[128] = "";
    FILE *p = popen("getprop ro.soc.manufacturer 2>/dev/null", "r");
    if (p) { if (fgets(b, sizeof b, p)) {} pclose(p); }
    if (strstr(b, "MediaTek") || strstr(b, "MTK")) { snprintf(g_plat, sizeof g_plat, "mtk"); return; }
    if (strstr(b, "Qualcomm")) { snprintf(g_plat, sizeof g_plat, "qcom"); return; }
    b[0] = 0;
    p = popen("getprop ro.board.platform 2>/dev/null", "r");
    if (p) { if (fgets(b, sizeof b, p)) {} pclose(p); }
    if (strstr(b, "mt") || strstr(b, "MT")) snprintf(g_plat, sizeof g_plat, "mtk");
    else if (strstr(b, "sm") || strstr(b, "msm") || strstr(b, "kona") ||
             strstr(b, "taro") || strstr(b, "sun") || strstr(b, "pineapple"))
        snprintf(g_plat, sizeof g_plat, "qcom");
    else snprintf(g_plat, sizeof g_plat, "other");
}

/* 节点顺序与 _sd_curr_prepare 一致 */
static void curr_prepare(void)
{
    if (g_curr_n) return;
    const char *base[] = {
        "battery/constant_charge_current_max",
        "battery/constant_charge_current",
        "battery/current_max",
        "main/constant_charge_current_max",
        "bms/current_max",
        "usb/current_max",
        NULL
    };
    for (int i = 0; base[i] && g_curr_n < MAXCURR - 6; i++)
        snprintf(g_curr_nodes[g_curr_n++], MAXPATH, "%s/%s", g_ps, base[i]);
    {
        char p[MAXPATH];
        snprintf(p, sizeof p, "%s/chg_current_max", g_oplus);
        snprintf(g_curr_nodes[g_curr_n++], MAXPATH, "%s", p);
        snprintf(p, sizeof p, "%s/current_max", g_oplus);
        snprintf(g_curr_nodes[g_curr_n++], MAXPATH, "%s", p);
    }
    plat_resolve();
    if (!strcmp(g_plat, "mtk")) {
        const char *mtk[] = {
            "battery/input_current_limit",
            "charger/current_max",
            "mtk-master-charger/current_max",
            "mtk-slave-charger/current_max",
            "mtk-battery/current_max",
            NULL
        };
        for (int i = 0; mtk[i] && g_curr_n < MAXCURR; i++)
            snprintf(g_curr_nodes[g_curr_n++], MAXPATH, "%s/%s", g_ps, mtk[i]);
    }
}

/* 单位：读出值 >100000 视为 µA；路径特征兜底 *//* 目标电流：curr_max 按温度阶梯打折，逻辑同 sd_curr_target_v */
/* curr.orig 里已经记过这个节点就不重复记 */static void curr_restore(void)
{
    FILE *f = fopen(g_curr_orig, "r");
    int n = 0;
    if (f) {
        char line[400];
        while (fgets(line, sizeof line, f)) {
            char *bar = strchr(line, '|');
            if (!bar) continue;
            *bar = 0;
            char *val = bar + 1;
            char *e = val + strlen(val);
            while (e > val && (e[-1] == '\n' || e[-1] == '\r')) *--e = 0;
            if (!line[0] || !val[0]) continue;
            if (write_str(line, val) == 0) n++;
        }
        fclose(f);
        unlink(g_curr_orig);
    }
    unlink(g_curr_want);
    if (n) log_msg("I", "charge", "限流已关闭，还原 %d 个节点", n);
}

/* ------------------------------------------------------------------ 亮屏快充 */

static int scr_node(char *out, size_t n)
{
    const char *rel[] = {
        "/sys/module/oplus_chg/parameters/ignore_screen_state",
        "/sys/module/oplus_chg_v2/parameters/ignore_screen_state",
        "/sys/module/oplus_charge/parameters/ignore_screen_state",
        "/sys/module/oplus_chg/parameters/chg_ignore_screen_state",
        NULL
    };
    for (int i = 0; rel[i]; i++) {
        char p[MAXPATH];
        if (access(rp(rel[i], p, sizeof p), F_OK) == 0) { snprintf(out, n, "%s", p); return 0; }
    }
    return -1;
}

/* 输入侧节点：写它等于改 USB 端口/协议能力，会打断 PD/VOOC 协商。
 * 与 shell 的 sd_scr_is_input 对齐；宁可判「本机不支持」也不碰。 */
static int scr_is_input(const char *p)
{
    return strstr(p, "/usb/") || strstr(p, "/charger/") ||
           strstr(p, "/pc_port/") || strstr(p, "/wireless/") ||
           strstr(p, "input_current_limit");
}

/* 优先级：电池侧 FCC → 电池侧 current_max → 欧加 chg_current_max。
 * chg_current_max 才是欧加真正的充电电流上限；漏掉它会一路落到 usb/current_max
 * （充电器能力值，常见固定 2A），把 2A 当目标反而压功率。
 * 3.0.3 及更早把 usb/current_max 当兜底，实测 OPPO Find X8 60W→37W、
 * 一加 12 停 33W，3.0.4 在 shell 侧删掉了这个候选；C 版这里必须一致。 */
static int scr_fcc_node(char *out, size_t n)
{
    curr_prepare();
    const char *pref[] = { "constant_charge_current_max", "battery/current_max",
                           "chg_current_max", NULL };
    for (int p = 0; pref[p]; p++) {
        for (int i = 0; i < g_curr_n; i++) {
            if (!strstr(g_curr_nodes[i], pref[p])) continue;
            if (scr_is_input(g_curr_nodes[i])) continue;
            if (access(g_curr_nodes[i], F_OK) == 0) { snprintf(out, n, "%s", g_curr_nodes[i]); return 0; }
        }
    }
    for (int i = 0; i < g_curr_n; i++) {
        const char *q = g_curr_nodes[i];
        if (scr_is_input(q)) continue;
        size_t l = strlen(q);
        /* 长度要按整段后缀算："/current_max" 是 12 字节，"/constant_charge_current" 是 24，
         * 之前写成 11/21，strcmp 永远不等，这条兜底其实一直没生效过。 */
        if ((l > 12 && !strcmp(q + l - 12, "/current_max")) ||
            (l > 24 && !strcmp(q + l - 24, "/constant_charge_current"))) {
            if (access(q, F_OK) == 0) { snprintf(out, n, "%s", q); return 0; }
        }
    }
    return -1;
}

static int scr_read_ma(const char *path, int *ma)
{
    int v;
    if (read_int(path, &v) < 0) return -1;
    if (v < 0) return -1;
    *ma = v > 100000 ? v / 1000 : v;
    return 0;
}

/* 记下息屏时的正常 FCC，作为亮屏接管的目标 */
static void scr_learn(void)
{
    char fcc[MAXPATH];
    int v = 0;
    if (scr_fcc_node(fcc, sizeof fcc) < 0) return;
    if (scr_read_ma(fcc, &v) < 0) return;
    if (v < 500) return;
    if (v > 12000) v = 12000;

    int old = 0;
    char b[32];
    if (read_line(g_fcc_norm, b, sizeof b) == 0) old = atoi(b);
    if (v > old) {
        snprintf(b, sizeof b, "%d\n", v);
        write_str(g_fcc_norm, b);
    }
}

/* 0=有目标 2=还没基准 3=电池偏热 */
static int scr_target(int *tgt)
{
    char b[32];
    if (read_line(g_fcc_norm, b, sizeof b) < 0) return 2;
    int n = atoi(b);
    if (n <= 0) return 2;
    if (n > 12000) n = 12000;
    /* 不看电池温度：亮屏就按息屏学到的峰值顶回去 */
    *tgt = n;
    return *tgt >= 500 ? 0 : 2;
}

static void scr_release(void)
{
    /* 退出（拔线/关模式/熔断/高温）时按原值还原。
     * 电流类节点先看现状：驱动已经放宽（息屏边界/温控回收）就别拿旧值压回去，
     * 与 shell 的 sd_scr_release 一致；开关型参数（ignore_screen_state 的 0/1）照常还原。 */
    FILE *f = fopen(g_scr_orig, "r");
    if (f) {
        char line[400];
        while (fgets(line, sizeof line, f)) {
            char *bar = strchr(line, '|');
            if (!bar) continue;
            *bar = 0;
            char *val = bar + 1;
            char *e = val + strlen(val);
            while (e > val && (e[-1] == '\n' || e[-1] == '\r')) *--e = 0;
            if (!line[0] || !val[0]) continue;
            if (access(line, F_OK) != 0) continue;
            int orig = atoi(val);
            if (orig >= 100) {              /* 电流量级才做放宽判断 */
                int now = 0;
                if (read_int(line, &now) == 0 && now > orig) continue;
            }
            write_str(line, val);
        }
        fclose(f);
        unlink(g_scr_orig);
    }
    g_scr_on = 0;
    g_scr_way_s[0] = 0;
    unlink(g_scr_way);
}

static int scr_active(void) { return g_scr_on || access(g_scr_orig, F_OK) == 0; }

static void scr_save_orig(const char *path, const char *raw)
{
    if (access(g_scr_orig, F_OK) == 0) return;
    char line[400];
    int n = snprintf(line, sizeof line, "%s|%s\n", path, raw);
    write_str(g_scr_orig, line);
    (void)n;
}

/* 0 成功；2 没基准；3 偏热；1 不支持 */
static int scr_apply(void)
{
    char node[MAXPATH];
    if (scr_node(node, sizeof node) == 0) {
        if (access(g_scr_orig, F_OK) != 0) {
            char raw[32] = "";
            read_line(node, raw, sizeof raw);
            if (raw[0]) scr_save_orig(node, raw);
        }
        if (write_str(node, "1\n") < 0) return 1;
        int v = 0;
        if (read_int(node, &v) < 0) return 1;
        if (v != 1) return 1;
        g_scr_on = 1;
        snprintf(g_scr_way_s, sizeof g_scr_way_s, "kernel");
        write_str(g_scr_way, "kernel\n");
        unlink(g_scr_fail);
        return 0;
    }

    char fcc[MAXPATH];
    if (scr_fcc_node(fcc, sizeof fcc) < 0) return 1;
    /* 息屏也走同一条写回逻辑：驱动在息屏边界会重算 FCC，热管理也可能顺手压下来 */

    int tgt = 0;
    int rc = scr_target(&tgt);
    if (rc == 3) return 3;
    if (rc != 0) return 2;

    int cur = 0;
    if (scr_read_ma(fcc, &cur) < 0) return 1;
    /* 单位看节点原始量级，别看归一后的 cur：cur 已经是 mA，拿它判永远不成立，
     * 对 µA 节点就会写进 3000（=3mA），接管等于没接管。 */
    char raw[32] = "";
    read_line(fcc, raw, sizeof raw);
    int ua = atoi(raw) > 100000;
    g_scr_cur = cur;
    {
        const char *base = strrchr(fcc, '/');
        snprintf(g_scr_node, sizeof g_scr_node, "%s", base ? base + 1 : fcc);
    }
    if (cur >= tgt) {
        g_scr_on = 1;
        snprintf(g_scr_way_s, sizeof g_scr_way_s, "fcc");
        write_str(g_scr_way, "fcc\n");
        unlink(g_scr_fail);
        return 0;
    }
    /* 死区：离目标不到 25% 不写。驱动自己也在按温度和电压动态算 FCC，
     * 贴着目标值来回覆盖，电流就在两档之间反复跳，曲线成锯齿。 */
    if (cur >= tgt * 3 / 4) {
        g_scr_on = 1;
        snprintf(g_scr_way_s, sizeof g_scr_way_s, "fcc");
        write_str(g_scr_way, "fcc\n");
        unlink(g_scr_fail);
        return 0;
    }

    if (access(g_scr_orig, F_OK) != 0) {
        /* 复用上面为判断单位读过的同一份原文，不再重读节点 */
        if (!raw[0]) snprintf(raw, sizeof raw, "%d", cur);
        scr_save_orig(fcc, raw);
    }
    char b[32];
    snprintf(b, sizeof b, "%d\n", ua ? tgt * 1000 : tgt);
    if (write_str(fcc, b) < 0) return 1;

    int back = 0;
    if (scr_read_ma(fcc, &back) < 0) return 1;
    if (back < tgt * 8 / 10) return 1;
    g_scr_on = 1;
    snprintf(g_scr_way_s, sizeof g_scr_way_s, "fcc");
    write_str(g_scr_way, "fcc\n");
    unlink(g_scr_fail);
    return 0;
}

static void scr_tick(void)
{
    static char logged[16] = "";

    if (!strcmp(g_c.temp_mode, "off")) {
        if (scr_active()) {
            scr_release();
            logged[0] = 0;
            log_msg("I", "charge", "亮屏快充：已退出，屏幕状态恢复");
        }
        return;
    }

    char st[32];
    batt_status(st, sizeof st);
    if (strcmp(st, "Charging") && strcmp(st, "Full")) {
        if (scr_active()) { scr_release(); logged[0] = 0; }
        return;
    }

    if (!g_screen_on) {
        /* 息屏只学基准，不写任何节点：驱动在息屏边界会自己把 FCC 放到协议峰值，
         * 模块这时候回写等于替驱动踩刹车（2.9.73~3.0.4 的老 bug，实测 60W 掉 30W）。
         * 内核参数那条一写就是「永久忽略屏幕」，息屏必须还原给驱动。 */
        scr_learn();
        char node[MAXPATH];
        if (scr_node(node, sizeof node) == 0 && scr_active()) { scr_release(); logged[0] = 0; }
        return;
    }

    /* 不设温度闸：亮屏就接管，直到没在充电为止 */

    switch (scr_apply()) {
        case 0: {
            if (strcmp(g_scr_way_s, logged)) {
                if (!strcmp(g_scr_way_s, "kernel"))
                    log_msg("I", "charge", "亮屏快充：已接管（内核 ignore_screen_state）");
                else {
                    char b[32] = "";
                    read_line(g_fcc_norm, b, sizeof b);
                    log_msg("I", "charge",
                            "亮屏快充：已接管（回写 FCC，目标 %smA，节点 %s 实读 %dmA）",
                            b[0] ? b : "?", g_scr_node[0] ? g_scr_node : "?", g_scr_cur);
                }
                snprintf(logged, sizeof logged, "%s", g_scr_way_s);
            }
            break;
        }
        case 2:
            if (g_screen_on && strcmp(logged, "wait")) {
                log_msg("I", "charge", "亮屏快充：还没有基准值，先息屏充一次再亮屏");
                snprintf(logged, sizeof logged, "wait");
            }
            break;
        case 3:
            if (scr_active()) scr_release();
            if (g_screen_on && strcmp(logged, "hot")) {
                log_msg("I", "charge", "亮屏快充：电池偏热，本轮不接管");
                snprintf(logged, sizeof logged, "hot");
            }
            break;
        default:
            /* 息屏时失败不落「本机不支持」：节点偶尔读不到，落盘后要等重启才恢复 */
            if (scr_active()) scr_release();
            if (g_screen_on) {
                if (strcmp(logged, "fail")) {
                    log_msg("W", "charge", "亮屏快充：本机不支持（无屏幕状态参数，FCC 也写不进去）");
                    snprintf(logged, sizeof logged, "fail");
                }
                write_str(g_scr_fail, "1\n");
            }
            break;
    }
}

/* ------------------------------------------------------------------ 降流解除 */
/*
 * ColorOS 16 用 oplus_chg/battery/cool_down 做亮屏降流：灭屏 0，亮屏 7~13，
 * 与温度无关（实测电池 33.8℃ 照样跳到 7）。该节点可写，写 0 后满速立即恢复，
 * 驱动不会逐秒覆盖，只在屏幕状态等事件时重算，所以按 tick 复查即可。
 */

static char g_cool_path[MAXPATH];
static int g_cool_none = 0;
static int g_cool_logged = -99;

static int cool_node(char *out, size_t n)
{
    if (g_cool_none) return -1;
    if (g_cool_path[0] && access(g_cool_path, F_OK) == 0) {
        snprintf(out, n, "%s", g_cool_path);
        return 0;
    }
    static const char *cand[] = {
        "/sys/class/oplus_chg/battery/cool_down",
        "/sys/class/oplus_chg/battery/oplus_cool_down",
        "/sys/class/oplus_chg/charger/cool_down",
        NULL
    };
    for (int i = 0; cand[i]; i++) {
        char p[MAXPATH + 96];
        snprintf(p, sizeof p, "%s%s", g_sys, cand[i]);
        if (access(p, F_OK) == 0) {
            snprintf(g_cool_path, sizeof g_cool_path, "%s", p);
            snprintf(out, n, "%s", p);
            return 0;
        }
    }
    g_cool_none = 1;
    return -1;
}

/* 写 0 之后要复查：写这个动作本身会让 OPlus 重选档，压错了必须写回去。 */
static int g_cool_prev = 0;          /* 写 0 之前的档位 */
static long g_cool_prev_iab = 0;     /* 写 0 之前的电流（µA） */
static time_t g_cool_prev_at = 0;
static time_t g_cool_hold = 0;       /* 反噬后的冷却截止 */

static void cool_tick(void)
{
    char node[MAXPATH];

    if (cool_node(node, sizeof node) < 0) {
        if (g_cool_logged != -1) {
            log_msg("W", "charge", "降流解除：本机没有 cool_down 节点，跳过");
            g_cool_logged = -1;
        }
        return;
    }

    char st[32];
    batt_status(st, sizeof st);
    if (strcmp(st, "Charging") && strcmp(st, "Full")) return;

    time_t now = time(NULL);

    /* 上一轮写过 0 的，先复查。反噬时电流不会上升（PKB110 实测 18W→9.7W），
     * 这时候必须把原档位写回去，否则驱动被反复重选档，功率一路抖到 6W。 */
    if (g_cool_prev > 0) {
        if (now - g_cool_prev_at >= 20) {
            long back = chg_current();
            if (back > 0 && back <= g_cool_prev_iab * 6 / 5 && back < 2500000) {
                char b[32];
                snprintf(b, sizeof b, "%d\n", g_cool_prev);
                if (write_str(node, b) == 0) {
                    log_msg("W", "charge",
                            "降流解除反噬：写 0 后电流 %ldmA 没升，已写回档位 %d，暂停 5 分钟",
                            back / 1000, g_cool_prev);
                    g_cool_hold = now + 300;
                    g_cool_logged = -3;
                }
            }
            g_cool_prev = 0;
        } else {
            return;
        }
    }
    if (now < g_cool_hold) return;

    /* 不看温度、不看电量：节点只要被抬起来就压回 0 */
    int cur = 0;
    if (read_int(node, &cur) < 0) return;
    if (cur == 0) return;

    /* 电流已经正常就别碰这个节点：写入本身会让 OPlus 重选档。
     * 实测 PKB110：ibat 4.3A 时被写 2→0，三秒后掉到 9.7W 并一路抖到 6W。
     * 只有确实被降流（<2.5A）时，写 0 才是"解降流"；读不到一律不动。 */
    long iab = chg_current();
    if (iab <= 0) return;
    if (iab >= 2500000) return;

    int bt = batt_temp_ps();
    if (write_str(node, "0\n") == 0) {
        if (g_cool_logged != 0) {
            log_msg("I", "charge", "降流解除：cool_down %d → 0（电池 %d℃ 电流 %ldmA）",
                    cur, bt > -100 ? bt : 0, iab / 1000);
            g_cool_logged = 0;
        }
        g_cool_prev = cur;
        g_cool_prev_iab = iab;
        g_cool_prev_at = now;
    } else if (g_cool_logged != -3) {
        log_msg("W", "charge", "降流解除失败：%s 写不进去", node);
        g_cool_logged = -3;
    }
}

/* ---------------------------------------------------------------- 阶梯解锁 */
/* 系统 thermal HAL 会按温度写 charge_control_limit / thermal_charging /
 * step_charging。这里压 0 表示不限流；原值备份到 run/unlock.orig，关闭时还原。
 * 刻意不碰 usb/current_max（写它会打断 PD/VOOC 协商）与 cool_down（见 cool_tick）。 */
static void unlock_restore(void)
{
    FILE *f = fopen(g_unlock_orig, "r");
    int n = 0;
    if (f) {
        char line[400];
        while (fgets(line, sizeof line, f)) {
            char *bar = strchr(line, '|');
            if (!bar) continue;
            *bar = 0;
            char *val = bar + 1;
            char *e = val + strlen(val);
            while (e > val && (e[-1] == '\n' || e[-1] == '\r')) *--e = 0;
            if (!line[0] || !val[0]) continue;
            if (access(line, F_OK) == 0 && write_str(line, val) == 0) n++;
        }
        fclose(f);
        unlink(g_unlock_orig);
    }
    if (n) log_msg("D", "charge", "阶梯解锁：还原 %d 个节点", n);
}

static void unlock_note(const char *path, int cur)
{
    FILE *f = fopen(g_unlock_orig, "r");
    if (f) {
        char line[400];
        int dup = 0;
        while (fgets(line, sizeof line, f)) {
            char *bar = strchr(line, '|');
            if (bar) *bar = 0;
            if (!strcmp(line, path)) { dup = 1; break; }
        }
        fclose(f);
        if (dup) return;
    }
    int fd = open(g_unlock_orig, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) return;
    char line[400];
    int m = snprintf(line, sizeof line, "%s|%d\n", path, cur);
    if (write(fd, line, m) < 0) { /* 记录失败不影响限流 */ }
    close(fd);
}

static void unlock_tick(void)
{
    static const char *rel[] = {
        "battery/charge_control_limit",
        "battery/thermal_charging",
        "battery/step_charging",
        NULL
    };
    static const char *oplus[] = {
        "battery/thermal_charging",
        "battery/step_charging",
        NULL
    };

    if (g_c.chg_unlock != 1) { unlock_restore(); return; }

    int n = 0;
    char p[MAXPATH + 64];
    for (int i = 0; rel[i]; i++) {
        snprintf(p, sizeof p, "%s/%s", g_ps, rel[i]);
        if (access(p, F_OK) != 0 || access(p, W_OK) != 0) continue;
        int cur = 0;
        if (read_int(p, &cur) < 0) continue;
        if (cur == 0) continue;
        unlock_note(p, cur);
        if (write_str(p, "0\n") == 0) n++;
    }
    for (int i = 0; oplus[i]; i++) {
        snprintf(p, sizeof p, "%s/%s", g_oplus, oplus[i]);
        if (access(p, F_OK) != 0 || access(p, W_OK) != 0) continue;
        int cur = 0;
        if (read_int(p, &cur) < 0) continue;
        if (cur == 0) continue;
        unlock_note(p, cur);
        if (write_str(p, "0\n") == 0) n++;
    }

    /* HAL 可能过一轮又写回去，这里会再压 0；日志按分钟节流 */
    static long last = 0;
    long now = (long)time(NULL);
    if (n > 0 && now - last >= 60) {
        log_msg("I", "charge", "阶梯解锁：%d 个节点写 0（原值备份在 run/unlock.orig）", n);
        last = now;
    }
}

/* ---------------------------------------------------------------- 充电快照 */

/* 以前查一次充电问题，要在终端里 cat 七八个节点：usb 电压、电流上限、
 * 电池电流、cool_down、voocchg_ing、charge_technology……
 * 这里一次读齐压成一行，状态一变就落日志，充电中每 10 分钟补一条，
 * 日志自己就是时间线，排查只要一份 log。
 */
static char g_chg_last[384];
static char g_chg_key[384];
static char g_chg_last_st[24];
static long g_chg_at;
static long g_chg_scan;

static int path_num(const char *path, long *out)
{
    char b[48];
    if (read_line(path, b, sizeof b) < 0) return -1;
    char *p = b, *end = NULL;
    while (*p == ' ' || *p == '\t') p++;
    long v = strtol(p, &end, 10);
    if (end == p) return -1;
    *out = v;
    return 0;
}

static int ps_num(const char *attr, long *out)
{
    char b[48];
    if (ps_attr(attr, b, sizeof b) < 0) return -1;
    char *p = b, *end = NULL;
    while (*p == ' ' || *p == '\t') p++;
    long v = strtol(p, &end, 10);
    if (end == p) return -1;
    *out = v;
    return 0;
}

static int oplus_num(const char *attr, long *out)
{
    char p[MAXPATH + 96];
    snprintf(p, sizeof p, "%s/%s", g_oplus, attr);
    return path_num(p, out);
}

/* bcc_parms 的第 9 段是 mA、第 7 段是 mV，单位固定；但 power_supply 的
 * voltage_now / current_max 各机型不一样：多数报 µV/µA，也有的报 mV/mA
 * （PJD110 之外的机型见过 4000 表示 4.0V）。量级差 1000 倍，靠数值大小判：
 * 小于 20 的千位（即 <20V 或 <20A）先乘 1000，再看结果是否落在合理区间，
 * 这样 0.03V（30000µV）这类空载值不会被误乘。 */
static long uv_norm(long v)
{
    if (v <= 0 || v >= 20000) return v;
    long t = v * 1000;
    if (t >= 100000 && t <= 30000000) return t;
    return v;
}

static void fmt_uv(long uv, int dec, char *out, size_t n)
{
    if (uv < 0) { snprintf(out, n, "?"); return; }
    if (dec >= 3) snprintf(out, n, "%ld.%03ld", uv / 1000000, (uv % 1000000) / 1000);
    else          snprintf(out, n, "%ld.%02ld", uv / 1000000, (uv % 1000000) / 10000);
}

/* bcc_parms：19 段逗号分隔，第 7 段电芯电压 mV、第 9 段电流 mA。
 * 灭屏后 power_supply 的 current_now 常常停在 0 不刷新，而这里仍在更新。 */
static long bcc_current(void)
{
    char b[256];
    char p[MAXPATH + 64];
    snprintf(p, sizeof p, "%s/bcc_parms", g_oplus);
    if (read_line(p, b, sizeof b) < 0) return 0;
    int idx = 0;
    char *s = b;
    long ma = 0;
    for (;;) {
        idx++;
        char *c = strchr(s, ',');
        if (c) *c = 0;
        if (idx == 9) {
            char *e = NULL;
            long v = strtol(s, &e, 10);
            if (e != s) ma = v;
            break;
        }
        if (!c) break;
        s = c + 1;
    }
    return ma;
}

/* 电池电流，统一 µA：bcc 优先，再回退 current_now / bms / current_avg。
 * bcc 绝对值小于 50mA 视为噪声（有的机型第 9 段不是总电流），继续往下找更大的值。 */
/* 有的机型 current_now 报 mA、有的报 µA，判据与 shell 侧 sd_uv_norm 一致：
 * 0 < |v| < 20000 一定是 mA。不归一的话 cool_tick 的 2.5A 闸在报 mA 的机型上
 * 永远放行（3000 < 2500000），4A 正常充电也会被当成"已降流"去写 0。 */
static long ua_norm(long v)
{
    long a = v < 0 ? -v : v;
    if (a > 0 && a < 20000) {
        long t = a * 1000;
        if (t >= 100000 && t <= 30000000) return v < 0 ? -t : t;
    }
    return v;
}

static long chg_current(void)
{
    long best = 0, babs = 0;
    long ma = bcc_current();
    if (ma != 0) {
        best = ma * 1000;
        babs = best < 0 ? -best : best;
        if (babs >= 50000) return best;
    }
    long c;
    if (ps_num("current_now", &c) == 0 && c != 0) {
        c = ua_norm(c);
        long a = c < 0 ? -c : c;
        if (a > babs) { best = c; babs = a; }
    }
    char p[MAXPATH + 32];
    snprintf(p, sizeof p, "%s/bms/current_now", g_ps);
    if (path_num(p, &c) == 0 && c != 0) {
        c = ua_norm(c);
        long a = c < 0 ? -c : c;
        if (a > babs) { best = c; babs = a; }
    }
    snprintf(p, sizeof p, "%s/battery/current_avg", g_ps);
    if (path_num(p, &c) == 0 && c != 0) {
        c = ua_norm(c);
        long a = c < 0 ? -c : c;
        if (a > babs) { best = c; babs = a; }
    }
    return best;
}

/* 电流 5 点中值，只为判重和快照分档服务。
 * 欧加机器报的 bcc 电流是瞬时值，充电时在两档之间脉动，直接分档会每轮都"变化"。
 * 充电/放电切换时整组作废，避免插拔瞬间把两种工况掺在一起算。 */
static long g_pw_ring[5];
static int  g_pw_n = 0;
static int  g_pw_st = -1;

static long pw_median(long ma, int chg)
{
    int i, j, k;
    long x, v[5];

    if (chg != g_pw_st) { g_pw_n = 0; g_pw_st = chg; }
    if (g_pw_n < 5) {
        g_pw_ring[g_pw_n++] = ma;
    } else {
        for (i = 1; i < 5; i++) g_pw_ring[i - 1] = g_pw_ring[i];
        g_pw_ring[4] = ma;
    }
    k = g_pw_n;
    for (i = 0; i < k; i++) v[i] = g_pw_ring[i];
    /* 排序副本，环形数组本身必须保持插入顺序 */
    for (i = 1; i < k; i++) {
        x = v[i];
        for (j = i - 1; j >= 0 && v[j] > x; j--) v[j + 1] = v[j];
        v[j + 1] = x;
    }
    return v[k / 2];
}

/* 输入侧实测电流（µA）。usb/current_max 是充电器能力上限，不是实际输入；
 * 日志里只写 imax 会让人以为一直卡在 2A 没上去。 */
static long chg_input(void)
{
    static const char *cand[] = { "usb/current_now", "usb/input_current_now",
                                  "usb/current_avg", "usb_input/current_now", NULL };
    char p[MAXPATH];
    long best = 0;
    for (int i = 0; cand[i]; i++) {
        long v;
        snprintf(p, sizeof p, "%s/%s", g_ps, cand[i]);
        if (path_num(p, &v) < 0 || v == 0) continue;
        v = uv_norm(v);
        if (v < 0) v = -v;
        if (v > best) best = v;
    }
    return best > 0 ? best : -1;
}

/* 组装一行充电现场。sig 非空时同时输出判重签名：
 * 电量按 5%、温度按 2℃ 归并，未充电时只比它，避免电压抖几十 mV 就落一条。 */
static void chg_line(char *out, size_t n, char *sig, size_t sn)
{
    long vusb = -1, imax = -1, vbat = -1, ibat = -1;
    long cool = -1, vooc = -1, tech = -1, cap = -1;
    long vmax = -1, iusb = -1, online = -1;
    char type[32] = "", rtype[32] = "", st[32] = "?";
    char p[MAXPATH + 96];
    char a[24], b2[24], b3[24];

    batt_status(st, sizeof st);
    ps_num("capacity", &cap);
    ps_num("voltage_now", &vbat);
    ibat = chg_current();
    snprintf(p, sizeof p, "%s/usb/voltage_now", g_ps);
    path_num(p, &vusb);
    snprintf(p, sizeof p, "%s/usb/current_max", g_ps);
    path_num(p, &imax);
    snprintf(p, sizeof p, "%s/usb/voltage_max", g_ps);
    path_num(p, &vmax);
    snprintf(p, sizeof p, "%s/usb/type", g_ps);
    if (read_line(p, type, sizeof type) < 0) type[0] = 0;
    for (char *q = type; *q; q++) if (*q == '\n' || *q == '\r') *q = 0;
    snprintf(p, sizeof p, "%s/usb/real_type", g_ps);
    if (read_line(p, rtype, sizeof rtype) < 0) rtype[0] = 0;
    for (char *q = rtype; *q; q++) if (*q == '\n' || *q == '\r') *q = 0;
    snprintf(p, sizeof p, "%s/usb/online", g_ps);
    if (path_num(p, &online) < 0) {
        snprintf(p, sizeof p, "%s/usb/present", g_ps);
        path_num(p, &online);
    }
    oplus_num("cool_down", &cool);
    oplus_num("voocchg_ing", &vooc);
    oplus_num("charge_technology", &tech);

    /* 有的机型 voltage_now / current_max 报 mV/mA，不归一会让 vbat 显示成
     * 0.004V、判重功率恒 0。 */
    vbat = uv_norm(vbat);
    vusb = uv_norm(vusb);
    imax = uv_norm(imax);
    vmax = uv_norm(vmax);
    iusb = chg_input();

    int bt = batt_temp_ps();

    fmt_uv(vusb, 2, a, sizeof a);
    fmt_uv(imax, 2, b2, sizeof b2);
    fmt_uv(vbat, 3, b3, sizeof b3);
    char tb[16], ib[24], ibs[24], pins[16] = "?", pbs[16] = "?";
    if (bt >= 0) snprintf(tb, sizeof tb, "%d℃", bt);
    else snprintf(tb, sizeof tb, "?");
    if (ibat != -1) snprintf(ib, sizeof ib, "%ldmA", ibat / 1000);
    else snprintf(ib, sizeof ib, "?");
    if (iusb > 0) snprintf(ibs, sizeof ibs, "%.2f", (double)iusb / 1e6);
    else snprintf(ibs, sizeof ibs, "?");
    if (iusb > 0 && vusb > 0) snprintf(pins, sizeof pins, "%.1f", (double)iusb * (double)vusb / 1e12);
    if (ibat != -1 && vbat > 0) {
        long iabs = ibat < 0 ? -ibat : ibat;
        snprintf(pbs, sizeof pbs, "%.1f", (double)iabs * (double)vbat / 1e12);
    }
    snprintf(out, n,
             "vusb=%sV iusb=%sA imax=%sA vbat=%sV ibat=%s pin=%sW pb=%sW %ld%% %s cool=%ld vooc=%ld tech=%ld type=%s rtype=%s scr=%d cells=? status=%s",
             a, ibs, b2, b3, ib, pins, pbs,
             cap, tb,
             cool, vooc, tech, type[0] ? type : "?", rtype[0] ? rtype : "?", g_screen_on, st);
    if (sig && sn) {
        /* 判重不看 vbat/ibat 瞬时值：bcc 电流会在两档间脉动（4.4V 电芯 ~60mΩ 内阻，
         * ±600mA 正好对应 ±40mV），按 100mV/200mA 分档照样每轮跨档，日志被灌成 3 秒一条。
         * 改用 5 点中值功率分档（1W），脉动滤掉，真实降档依然跨档。 */
        long pwk = 0;
        if (ibat != -1 && vbat > 0) {
            long ibm = ibat < 0 ? -ibat / 1000 : ibat / 1000;
            int chg = strstr(st, "Charging") || !strcmp(st, "Full") ? 1 : 0;
            ibm = pw_median(ibm, chg);
            pwk = ibm * vbat / 1000000000L;
        }
        snprintf(sig, sn,
                 "st=%s pw=%ldW cap=%ld bt=%d usb=%ld imax=%s type=%s cool=%ld vooc=%ld tech=%ld scr=%d",
                 st, pwk, cap < 0 ? 0 : cap / 5 * 5, bt < 0 ? 0 : bt / 2 * 2,
                 vusb > 0 ? (vusb + 500000) / 1000000 : -1, b2, type[0] ? type : "?", cool, vooc, tech,
                 g_screen_on);
    }
}

static void chg_snapshot(int charging)
{
    char line[384], sig[384], st[32] = "?";
    long now = (long)time(NULL);

    if (g_c.log_level < 2) return;
    /* 没充电时降频，省得空跑读一堆节点 */
    if (!charging && now - g_chg_scan < 30) return;
    g_chg_scan = now;

    batt_status(st, sizeof st);
    chg_line(line, sizeof line, sig, sizeof sig);
    const char *key = sig;

    const char *why = g_chg_key[0] ? "变化" : "首帧";
    if (strcmp(g_chg_last_st, st)) {
        snprintf(g_chg_last_st, sizeof g_chg_last_st, "%s", st);
        why = g_chg_key[0] ? (charging ? "插电" : "停充") : "首帧";
    }

    if (!strcmp(key, g_chg_key)) {
        /* 值没变就只在充电中每 10 分钟补一条，避免刷屏 */
        if (charging && now - g_chg_at >= 600) {
            log_msg("I", "chg", "定时 %s", line);
            g_chg_at = now;
        }
        return;
    }
    log_msg("I", "chg", "%s %s", why, line);
    snprintf(g_chg_key, sizeof g_chg_key, "%s", key);
    snprintf(g_chg_last, sizeof g_chg_last, "%s", line);
    g_chg_at = now;
}

/* ------------------------------------------------------------------ 屏幕 */

/* 收集所有亮度节点，只扫一次。
 * 不能"取第一个存在的就完事"：PJD110 的 panel0-backlight/actual_brightness
 * 恒为 0，排在前面的节点一旦是这种，屏幕就永远判成灭屏。全部读到 0 才算灭屏。 */
static void screen_scan(void)
{
    struct dirent *de;
    DIR *d;
    int n = 0;
    char p[MAXPATH];

    if (g_bl_cnt >= 0) return;
    if ((d = opendir(g_bl))) {
        while ((de = readdir(d)) && n < 16) {
            if (de->d_name[0] == '.') continue;
            snprintf(p, sizeof p, "%s/%s/actual_brightness", g_bl, de->d_name);
            if (access(p, F_OK) == 0) { snprintf(g_bl_list[n], MAXPATH, "%s", p); n++; }
        }
        rewinddir(d);
        while ((de = readdir(d)) && n < 16) {
            if (de->d_name[0] == '.') continue;
            snprintf(p, sizeof p, "%s/%s/brightness", g_bl, de->d_name);
            if (access(p, F_OK) == 0) { snprintf(g_bl_list[n], MAXPATH, "%s", p); n++; }
        }
        closedir(d);
    }
    /* /sys/class/backlight 是空的机型（亮度走 leds 或 panel 子节点），
     * 再试几个常见落点，否则整台机器判不出屏幕状态。 */
    if (n == 0) {
        static const char *rel[] = {
            "/sys/class/leds/lcd-backlight/actual_brightness",
            "/sys/class/leds/lcd-backlight/brightness",
            "/sys/class/leds/lcd/brightness",
            "/sys/class/backlight/panel0-backlight/brightness",
            NULL
        };
        char q[MAXPATH];
        for (int i = 0; rel[i] && n < 16; i++) {
            snprintf(q, sizeof q, "%s%s", g_sys, rel[i]);
            if (access(q, F_OK) == 0) { snprintf(g_bl_list[n], MAXPATH, "%s", q); n++; }
        }
    }
    g_bl_cnt = n;
}

static int screen_sample(void)
{
    int i, v, max = -1;

    screen_scan();
    for (i = 0; i < g_bl_cnt; i++) {
        int x;
        if (read_int(g_bl_list[i], &x) != 0) continue;
        if (x > max) max = x;
    }
    if (max >= 0) return max > 0 ? 1 : 0;
    if (g_fb_blank >= 0) return g_fb_blank;   /* blank 文件里 0 才是亮 */
    {
        static const char *fb_rel[] = {
            "/sys/graphics/fb0/blank",
            "/sys/class/graphics/fb0/blank",
            "/sys/devices/virtual/graphics/fb0/blank",
            NULL
        };
        char q[MAXPATH];
        for (int k = 0; fb_rel[k]; k++) {
            if (k == 0 && g_fb[0]) snprintf(q, sizeof q, "%s", g_fb);
            else snprintf(q, sizeof q, "%s%s", g_sys, fb_rel[k]);
            if (read_int(q, &v) == 0) { g_fb_blank = v == 0 ? 1 : 0; return g_fb_blank; }
        }
    }
    return -1;
}

/* 与 sd_screen_tick 一致：连续两次读到暗才算息屏，避免息屏瞬间的抖动 */
static void screen_tick(void)
{
    int prev = g_screen_on;
    int on = screen_sample();
    if (on < 0) { g_screen_on = 1; g_screen_n = 0; }
    else if (on) { g_screen_on = 1; g_screen_n = 0; }
    else {
        g_screen_n++;
        if (g_screen_n >= 2) g_screen_on = 0;
    }
    /* 翻转记一条：延迟释放与轮询间隔都挂在屏幕状态上，出问题先看这一行 */
    if (prev != g_screen_on)
        log_msg("I", "screen", "%s（节点数=%d）", g_screen_on ? "亮屏" : "熄屏", g_bl_cnt);
}

/* ------------------------------------------------------------------ 熔断 */

/* xo-therm 或电池类才算熔断来源，与 sd_zone_is_guard_src 一致 */
/* 回差 3℃ 才恢复，且读不到温度时保持熔断（不猜安全） */
/* ------------------------------------------------------------------ 电池伪装 */

static void batt_sp_off(void)
{
    spoof_clear_scope(SC_BATT);
    g_batt_sp_on = 0;
    g_batt_sp_last = 0;
}

static void batt_sp_guard(void)
{
    int want = g_c.batt_spoof;
    if (want <= 0) {
        if (g_batt_sp_on) batt_sp_off();
        return;
    }
    if (want < 20 || want > 45) { batt_sp_off(); return; }
    if (!strcmp(g_c.temp_mode, "off")) { batt_sp_off(); return; }

    /* 不看真实温度：开着就一直伪装，满速优先 */
    if (want == g_batt_sp_last && g_batt_sp_on) return;
    if (spoof_apply(SC_BATT, want, 1) == 0) {
        g_batt_sp_last = want;
        g_batt_sp_on = 1;
    }
}

/* ------------------------------------------------------------------ 遥测 */

/* 面板靠这个文件判断"守护在跑 + 真实温度"，缺了就只能实时读，会读到伪装值 */
static void telemetry(void)
{
    char line[320];
    snprintf(line, sizeof line, "%d %s %s %s %s %s %d\n",
             up_ticks(),
             g_tl_real[0] ? g_tl_real : "-",
             g_tl_lim[0] ? g_tl_lim : "-",
             g_tl_zone[0] ? g_tl_zone : "-",
             g_tl_out[0] ? g_tl_out : "-",
             g_c.temp_mode[0] ? g_c.temp_mode : "off",
             g_emul_ok);
    write_str(g_sensor, line);
}

static void hb_write(void)
{
    char b[64];
    snprintf(b, sizeof b, "%d %d\n", up_ticks(), (int)getpid());
    write_str(g_hb, b);
}

/* ------------------------------------------------------------------ 壳温目标 */

/* 与 sd_shell_target 一致：把壳温上报压到屏障下方，留 gap 并随余量爬升 */
static int shell_target(void)
{
    int base = g_c.shell_temp;

    g_tl_out[0] = 0;
    g_tl_real[0] = 0;
    g_tl_lim[0] = 0;
    g_tl_zone[0] = 0;

    /* 真实读数只用于遥测与日志，不再参与决策 */
    int cur = -1000;
    int bz = -1;
    if (pick_batt_zone(&bz) == 0) {
        const char *nm = strrchr(g_z[bz].path, '/');
        snprintf(g_tl_zone, sizeof g_tl_zone, "%s", nm ? nm + 1 : g_z[bz].path);
        /* 电池伪装开着时要读电量计，否则拿到的是自己写的假值 */
        if (sentinel_temp(bz, &cur) < 0) cur = -1000;
        if (g_batt_ps || batt_spoof_on()) snprintf(g_tl_zone, sizeof g_tl_zone, "battery(ps)");
    } else {
        int v = batt_temp_ps();
        if (v > -100) {
            cur = v;
            snprintf(g_tl_zone, sizeof g_tl_zone, "battery(ps)");
        } else {
            int si = -1, sc = 0;
            if (pick_sentinel(&si, &sc) == 0) {
                const char *nm = strrchr(g_z[si].path, '/');
                snprintf(g_tl_zone, sizeof g_tl_zone, "%s", nm ? nm + 1 : g_z[si].path);
                if (sentinel_temp(si, &cur) < 0) cur = -1000;
            }
        }
    }
    if (cur > -100) {
        g_temp_fail = 0;
        snprintf(g_tl_real, sizeof g_tl_real, "%d", cur);
    } else {
        g_temp_fail++;
    }

    /* 极速模式：恒定伪装，不看真实温度、不设温度墙、不设熔断线。
     * 下限 20℃：再低不少平台判 NTC 开路，反而锁 5V/500mA，比不伪装更慢。 */
    if (base < 20) base = 20;
    if (base > 33) base = 33;
    snprintf(g_tl_out, sizeof g_tl_out, "%d", base);
    return base;
}

/* 与 sd_charge_tick 一致：只有电芯没到 fast_cap 才接管壳温 */
static void charge_tick(void)
{
    char st[32];
    batt_status(st, sizeof st);
    if (strcmp(st, "Charging") && strcmp(st, "Full")) {
        shell_emul(0);
        g_tl_real[0] = g_tl_out[0] = g_tl_lim[0] = g_tl_zone[0] = 0;
        return;
    }
    /* 不设电量阈值：插着电就一直伪装，充到 100% 也不再交还 */
    shell_emul(shell_target());
}

/* ------------------------------------------------------------------ 高刷 */

static int cmd_capture(const char *cmd, char *out, size_t n)
{
    out[0] = 0;
    FILE *p = popen(cmd, "r");
    if (!p) return -1;
    size_t o = 0;
    int ch;
    while ((ch = fgetc(p)) != EOF && o < n - 1) out[o++] = (char)ch;
    out[o] = 0;
    pclose(p);
    return out[0] ? 0 : -1;
}

static int hz_want(void)
{
    if (!strcmp(g_c.hz, "off") || !g_c.hz[0]) return 0;
    for (const char *p = g_c.hz; *p; p++)
        if (*p < '0' || *p > '9') return 0;
    int v = atoi(g_c.hz);
    return v > 0 ? v : 0;
}

static int hz_read_pair(int *peak, int *mn)
{
    char out[8192];
    *peak = -1;
    *mn = -1;
    if (cmd_capture("settings list system 2>/dev/null", out, sizeof out) < 0) return -1;
    char *p = out;
    while (*p) {
        char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        if (len > 17 && !strncmp(p, "peak_refresh_rate=", 18)) *peak = atoi(p + 18);
        else if (len > 16 && !strncmp(p, "min_refresh_rate=", 17)) *mn = atoi(p + 17);
        if (!nl) break;
        p = nl + 1;
    }
    return 0;
}

static int hz_lowpower(void)
{
    char out[64];
    if (cmd_capture("settings get global low_power 2>/dev/null", out, sizeof out) < 0) return 0;
    return atoi(out) == 1;
}

static void hz_mcfr_on(void)
{
    if (!g_c.hz_prev_mcfr[0]) {
        char out[64] = "";
        cmd_capture("settings get secure match_content_frame_rate 2>/dev/null", out, sizeof out);
        char *e = out + strlen(out);
        while (e > out && (e[-1] == '\n' || e[-1] == '\r' || e[-1] == ' ')) *--e = 0;
        if (!out[0]) snprintf(out, sizeof out, "none");
        snprintf(g_c.hz_prev_mcfr, sizeof g_c.hz_prev_mcfr, "%s", out);
        state_set("hz_prev_mcfr", g_c.hz_prev_mcfr);
    }
    if (system("settings put secure match_content_frame_rate 1 2>/dev/null") < 0) { /* 无 settings 命令 */ }
    if (system("cmd display set-match-content-frame-rate-policy 1 >/dev/null 2>&1") < 0) { /* 无 cmd 命令 */ }
}

/* 返回：0 无需处理 / 1 已补写 / 2 被拒绝 / 3 省电模式接管 */
static int hz_guard(void)
{
    if (!g_c.hz_hard) return 0;
    int v = hz_want();
    if (!v) return 0;

    int peak = -1, mn = -1;
    hz_read_pair(&peak, &mn);
    if (peak == v && mn == v) { g_hz_bad = 0; return 0; }
    if (hz_lowpower()) { g_hz_bad = 0; return 3; }
    if (g_hz_bad >= 3) return 2;

    char c[256];
    snprintf(c, sizeof c, "settings put system peak_refresh_rate %d 2>/dev/null", v);
    if (system(c) < 0) { /* settings 不存在时忽略 */ }
    snprintf(c, sizeof c, "settings put system min_refresh_rate %d 2>/dev/null", v);
    if (system(c) < 0) { /* settings 不存在时忽略 */ }
    hz_mcfr_on();

    hz_read_pair(&peak, &mn);
    if (peak == v) { g_hz_bad = 0; return 1; }
    g_hz_bad++;
    return 2;
}

/* ------------------------------------------------------------------ 描述同步 */

/* 元模块（NoMount / Magic Mount / Mountify / Hybrid Mount）激活时，
 * 配置文件的清单记在 nm.list 而不是 mounts.list，shell 版也是这么分的。
 * 目录名与 lib/qc.sh 里的 SD_MM_DIRS / sd_nm_active 保持一致。 */
static const char *g_nm_dirs[] = { "/modules/meta-nomount", "/modules/nomount", NULL };

static const char *g_mm_dirs[] = {
    "/modules/meta-hybrid_mount", "/modules/hybrid_mount",
    "/modules/meta-magic_mount", "/modules/meta-magic_mount-rs",
    "/modules/meta-mm", "/modules/magic_mount", "/modules/mountify",
    NULL
};

/* 目录存在、且没有 disable / remove 标记才算激活 */
static int dir_active(const char *rel)
{
    char p[MAXPATH];
    struct stat st;

    snprintf(p, sizeof p, "%s%s", g_adb, rel);
    if (stat(p, &st) < 0 || !S_ISDIR(st.st_mode)) return 0;

    snprintf(p, sizeof p, "%s%s/disable", g_adb, rel);
    if (stat(p, &st) == 0) return 0;

    snprintf(p, sizeof p, "%s%s/remove", g_adb, rel);
    if (stat(p, &st) == 0) return 0;

    return 1;
}

static int nm_or_mm_active(void)
{
    for (int i = 0; g_nm_dirs[i]; i++)
        if (dir_active(g_nm_dirs[i])) return 1;
    for (int i = 0; g_mm_dirs[i]; i++)
        if (dir_active(g_mm_dirs[i])) return 1;
    return 0;
}

/* 非空行计数（nm.list 用，shell 版是 wc -l，不去重） */
static int count_lines(const char *path)
{
    char b[512];
    FILE *f = fopen(path, "r");
    if (!f) return 0;

    int n = 0;
    while (fgets(b, sizeof b, f)) {
        char *e = b;
        while (*e && *e != '\n' && *e != '\r') e++;
        *e = 0;
        if (*b) n++;
    }
    fclose(f);
    return n;
}

/* 与 shell 版的 sort -u | wc -l 对齐：同一路径重复挂载只算一项 */
static int count_uniq(const char *path)
{
    char b[256];
    static char seen[64][MAXPATH];
    int n = 0, nseen = 0;

    FILE *f = fopen(path, "r");
    if (!f) return 0;
    while (fgets(b, sizeof b, f)) {
        char *e = b;
        while (*e && *e != '\n' && *e != '\r') e++;
        *e = 0;
        if (!b[0]) continue;

        int dup = 0;
        for (int i = 0; i < nseen; i++)
            if (!strcmp(seen[i], b)) { dup = 1; break; }
        if (dup) continue;

        if (nseen < 64) {
            snprintf(seen[nseen], MAXPATH, "%s", b);
            nseen++;
        }
        n++;
    }
    fclose(f);
    return n;
}

static int mounts_count(void)
{
    char p[MAXPATH];

    /* 与 sd_desc_text 同一套分支：元模块激活且 nm.list 非空时用它 */
    if (nm_or_mm_active()) {
        snprintf(p, sizeof p, "%s/nm.list", g_data);
        int n = count_lines(p);
        if (n > 0) return n;
    }

    snprintf(p, sizeof p, "%s/mounts.list", g_data);
    return count_uniq(p);
}

static void desc_build(char *out, size_t n)
{
    char gear[32], shape[96];
    int mode_static = !strcmp(g_c.temp_mode, "static");
    int mode_charge = !strcmp(g_c.temp_mode, "charge");

    if (mode_static || mode_charge) snprintf(gear, sizeof gear, "温度伪装 %d℃", g_c.shell_temp);
    else snprintf(gear, sizeof gear, "温度伪装关闭");

    int hv = hz_want();
    /* 没开高刷就什么都不写：描述是摘要，「高刷关闭」没有信息量 */
    if (!hv) shape[0] = 0;
    else if (g_c.hz_hard) snprintf(shape, sizeof shape, " · 高刷 %dHz 锁定", hv);
    else snprintf(shape, sizeof shape, " · 高刷 %dHz", hv);

    int mt = mounts_count();
    /* 状态段：这里只可能是「运行中」——描述是守护自己写的。刚装完/没跑起来
     * 那两种由 customize.sh 和 action.sh 走 shell 版 sd_desc_text 落下去。 */
    if (mt > 0) snprintf(out, n, "✅ 运行中 · %s%s · 配置 %d 项", gear, shape, mt);
    else snprintf(out, n, "✅ 运行中 · %s%s · 配置未挂载", gear, shape);
}

static void sync_desc(void)
{
    if (!g_moddir[0]) return;
    char prop[MAXPATH + 32];
    snprintf(prop, sizeof prop, "%s/module.prop", g_moddir);
    if (access(prop, F_OK) != 0) return;

    char want[256], cur[256] = "";
    desc_build(want, sizeof want);

    FILE *f = fopen(prop, "r");
    if (!f) return;
    char line[MAXLINE], buf[8192];
    size_t o = 0;
    while (fgets(line, sizeof line, f)) {
        if (!strncmp(line, "description=", 12)) {
            char *e = line + strlen(line);
            while (e > line && (e[-1] == '\n' || e[-1] == '\r')) *--e = 0;
            snprintf(cur, sizeof cur, "%s", line + 12);
            o += snprintf(buf + o, sizeof buf - o, "description=%s\n", want);
        } else {
            o += snprintf(buf + o, sizeof buf - o, "%s", line);
        }
        if (o >= sizeof buf - MAXLINE) break;
    }
    fclose(f);
    if (!strcmp(cur, want)) return;

    char tmp[MAXPATH + 48];
    snprintf(tmp, sizeof tmp, "%s.t.%d", prop, (int)getpid());
    if (write_str(tmp, buf) < 0) return;
    if (rename(tmp, prop) < 0) unlink(tmp);
}

/* ------------------------------------------------------------------ 伪装补齐 */

/* action.sh 在自己域里读不到温区时会把请求写进 spoof.pending，等守护补齐 */
static void spoof_pending(void)
{
    if (access(g_spoof_flag, F_OK) != 0) return;
    int n = 0;
    char b[32];
    if (read_line(g_spoof_flag, b, sizeof b) == 0) n = atoi(b);

    int ok = 1;
    if (g_c.core_temp >= 20) { if (spoof_apply(SC_CORE, g_c.core_temp, 1) < 0) ok = 0; }
    if (g_c.noncore_temp >= 20) { if (spoof_apply(SC_NONCORE, g_c.noncore_temp, 1) < 0) ok = 0; }

    if (ok) {
        unlink(g_spoof_flag);
        log_msg("I", "thermal", "守护补齐伪装请求（core=%d noncore=%d）",
                g_c.core_temp >= 20 ? g_c.core_temp : 0,
                g_c.noncore_temp >= 20 ? g_c.noncore_temp : 0);
    } else if (n >= 8) {
        unlink(g_spoof_flag);
        log_msg("W", "thermal", "伪装请求连续 8 次无法落地，已放弃");
    } else {
        snprintf(b, sizeof b, "%d\n", n + 1);
        write_str(g_spoof_flag, b);
    }
}

/* ------------------------------------------------------------------ 锁 */

static char g_lock[340];

static void lock_acquire(void)
{
    snprintf(g_lock, sizeof g_lock, "%s/daemon.lock", g_run);
    if (mkdir(g_lock, 0755) < 0) {
        if (errno != EEXIST) return;
        char p[400], b[32] = "";
        snprintf(p, sizeof p, "%s/pid", g_lock);
        if (read_line(p, b, sizeof b) == 0) {
            int pid = atoi(b);
            if (pid > 1 && pid != (int)getpid() && kill(pid, 0) == 0) {
                fprintf(stderr, "qcmon: 已有实例 pid=%d\n", pid);
                exit(0);
            }
        }
        char q[400];
        snprintf(q, sizeof q, "%s/pid", g_lock);
        unlink(q);
        rmdir(g_lock);
        if (mkdir(g_lock, 0755) < 0) return;
    }
    char p[400], b[32];
    snprintf(p, sizeof p, "%s/pid", g_lock);
    snprintf(b, sizeof b, "%d\n", (int)getpid());
    write_str(p, b);
    snprintf(p, sizeof p, "%s/daemon.pid", g_run);
    write_str(p, b);
}

static void lock_release(void)
{
    if (!g_lock[0]) return;
    char p[400];
    snprintf(p, sizeof p, "%s/pid", g_lock);
    unlink(p);
    if (rmdir(g_lock) < 0) { /* 目录里有别的东西就留着 */ }
    snprintf(p, sizeof p, "%s/daemon.pid", g_run);
    unlink(p);
}

/* ------------------------------------------------------------------ 恢复 */

static void restore_all(void)
{
    spoof_clear();
    shell_emul(0);
    scr_release();
    curr_restore();
    unlock_restore();
    g_batt_sp_on = 0;
    log_msg("I", "daemon", "收到退出信号，伪装/限流/屏幕/阶梯状态已还原");
}

/* ------------------------------------------------------------------ 主循环 */

static void paths_init(void)
{
    rp("/sys/class/power_supply", g_ps, sizeof g_ps);
    rp("/sys/class/thermal", g_therm, sizeof g_therm);

    /* 允许像 shell 版那样用 SD_ZONE_GLOB 指定温区，路径仍按 g_sys 加前缀 */
    const char *zg = getenv("SD_ZONE_GLOB");
    if (zg && *zg) {
        char tmp[MAXPATH];
        snprintf(tmp, sizeof tmp, "%s", zg);
        char *slash = strrchr(tmp, '/');
        if (slash) {
            *slash = 0;
            snprintf(g_therm, sizeof g_therm, "%s%s", g_sys, tmp);
            snprintf(g_zone_pref, sizeof g_zone_pref, "%s", slash + 1);
            char *star = strchr(g_zone_pref, '*');
            if (star) *star = 0;
        }
    }
    rp("/sys/graphics/fb0/blank", g_fb, sizeof g_fb);
    rp("/sys/class/oplus_chg/battery", g_oplus, sizeof g_oplus);
    rp("/proc/shell-temp", g_shellproc, sizeof g_shellproc);

    const char *bl = getenv("SD_BL");
    if (bl && *bl) snprintf(g_bl, sizeof g_bl, "%s", bl);
    else rp("/sys/class/backlight", g_bl, sizeof g_bl);

    const char *fb = getenv("SD_FB");
    if (fb && *fb) snprintf(g_fb, sizeof g_fb, "%s", fb);

    const char *sp = getenv("SD_SPOOF_DIR");
    if (sp && *sp) snprintf(g_spoof_dir, sizeof g_spoof_dir, "%s", sp);

    snprintf(g_state, sizeof g_state, "%s/state.conf", g_data);
    snprintf(g_log, sizeof g_log, "%s/log.txt", g_data);
    snprintf(g_log_old, sizeof g_log_old, "%s/log.old.txt", g_data);
    snprintf(g_run, sizeof g_run, "%s/run", g_data);
    snprintf(g_scr_orig, sizeof g_scr_orig, "%s/scr.orig", g_run);
    snprintf(g_scr_way, sizeof g_scr_way, "%s/scr.way", g_run);
    snprintf(g_scr_fail, sizeof g_scr_fail, "%s/scr.fail", g_run);
    snprintf(g_fcc_norm, sizeof g_fcc_norm, "%s/fcc.norm", g_run);
    snprintf(g_unlock_orig, sizeof g_unlock_orig, "%s/unlock.orig", g_run);
    snprintf(g_curr_orig, sizeof g_curr_orig, "%s/curr.orig", g_run);
    snprintf(g_curr_want, sizeof g_curr_want, "%s/curr.want", g_run);
    snprintf(g_spoof_flag, sizeof g_spoof_flag, "%s/spoof.pending", g_run);
    snprintf(g_sensor, sizeof g_sensor, "%s/sensor", g_run);
    snprintf(g_hb, sizeof g_hb, "%s/hb", g_run);
}

/* core / noncore 伪装：shell 版也只在启动与配置变化时应用，不做每轮重贴。
 * 这里按"值变了才贴"，另加每 40 轮一次兜底重试（mount 被系统清掉时能自愈）。 */
static void apply_core_nc(int force)
{
    int c = g_c.core_temp >= 20 ? g_c.core_temp : 0;
    int n = g_c.noncore_temp >= 20 ? g_c.noncore_temp : 0;

    if (c) {
        if (force || c != g_core_last) {
            spoof_apply(SC_CORE, c, 0);
            g_core_last = c;
        }
    } else {
        g_core_last = -1;
        if (g_spoof_ok[SC_CORE]) spoof_clear_scope(SC_CORE);
    }

    if (n) {
        if (force || n != g_nc_last) {
            spoof_apply(SC_NONCORE, n, 0);
            g_nc_last = n;
        }
    } else {
        g_nc_last = -1;
        if (g_spoof_ok[SC_NONCORE]) spoof_clear_scope(SC_NONCORE);
    }
}

/* 充电且开着降流解除时把 tick 压到 3s：cool_down 被驱动抬高后要尽快清零。
 * 以前只在亮屏时压，但屏幕判定靠不住，改成充电即压。 */
static int next_tick(int charging)
{
    if (charging) return 3;
    return charging ? 10 : g_c.tick;
}

/* 一轮热路径。返回本轮该睡多久。 */
static int loop_once(int *mode_changed)
{
    static char last_mode[16] = "";

    conf_load();
    g_tick_n++;

    if (!g_scanned || g_temp_fail >= 2 || g_tick_n % 40 == 0) zones_scan();
    screen_tick();
    /* 屏幕判定只影响日志与轮询间隔，不再决定是否解除降流；每轮守护启动记一次 */
    {
        static int scr_logged = 0;
        if (!scr_logged) {
            scr_logged = 1;
            if (g_bl_cnt > 0)
                log_msg("I", "daemon", "屏幕 判定=%s 节点数=%d",
                        g_screen_on ? "亮" : "灭", g_bl_cnt);
            else
                log_msg("I", "daemon", "屏幕 无亮度节点，按亮屏处理");
        }
    }

    char st[32];
    batt_status(st, sizeof st);
    int charging = !strcmp(st, "Charging") || !strcmp(st, "Full");

    scr_tick();
    cool_tick();
    unlock_tick();
    chg_snapshot(charging);
    spoof_pending();
    batt_sp_guard();

    if (strcmp(g_c.temp_mode, last_mode)) {
        log_msg("I", "daemon", "温度模式: %s → %s",
                last_mode[0] ? last_mode : "<无>", g_c.temp_mode);
        snprintf(last_mode, sizeof last_mode, "%s", g_c.temp_mode);
        /* 换模式后壳温缓存必须作废，否则新值恰好等于旧值时不写 */
        shell_emul_reset();
        if (mode_changed) *mode_changed = 1;
    }

    if (!strcmp(g_c.temp_mode, "static")) {
        int out = shell_target();
        shell_emul(out);
        apply_core_nc(g_tick_n % 40 == 0);
    } else if (!strcmp(g_c.temp_mode, "charge")) {
        if (charging) {
            charge_tick();
            apply_core_nc(g_tick_n % 40 == 0);
        } else {
            shell_emul(0);
            if (g_spoof_ok[SC_CORE] || g_spoof_ok[SC_NONCORE]) {
                spoof_clear_scope(SC_CORE);
                spoof_clear_scope(SC_NONCORE);
                g_core_last = g_nc_last = -1;
            }
            int si = -1, sc = 0;
            if (pick_sentinel(&si, &sc) == 0) {
                const char *nm = strrchr(g_z[si].path, '/');
                snprintf(g_tl_zone, sizeof g_tl_zone, "%s", nm ? nm + 1 : g_z[si].path);
                int cur = 0;
                if (sentinel_temp(si, &cur) == 0) snprintf(g_tl_real, sizeof g_tl_real, "%d", cur);
            }
        }
    } else {
        /* off：什么都不接管，但遥测要有真实温度 */
        if (g_spoof_ok[SC_CORE] || g_spoof_ok[SC_NONCORE]) {
            spoof_clear_scope(SC_CORE);
            spoof_clear_scope(SC_NONCORE);
            g_core_last = g_nc_last = -1;
        }
        shell_emul(0);
        int si = -1, sc = 0;
        if (pick_sentinel(&si, &sc) == 0) {
            const char *nm = strrchr(g_z[si].path, '/');
            snprintf(g_tl_zone, sizeof g_tl_zone, "%s", nm ? nm + 1 : g_z[si].path);
            int cur = 0;
            if (sentinel_temp(si, &cur) == 0) snprintf(g_tl_real, sizeof g_tl_real, "%d", cur);
        }
    }

    hb_write();
    telemetry();

    switch (hz_guard()) {
        case 1:
            if (g_tick_n % 4 == 1) log_msg("I", "daemon", "刷新率被系统改回，已补写");
            break;
        case 2:
            if (g_tick_n % 40 == 0) log_msg("I", "daemon", "刷新率写入被拒绝，已暂停补写（厂商锁定显示策略）");
            break;
        case 3:
            if (g_tick_n % 40 == 0) log_msg("I", "daemon", "省电模式开启，刷新率交回系统管理");
            break;
        default:
            break;
    }

    return next_tick(charging);
}

/* ---------------------------------------------------------------- 环境头 */

static void getprop_v(const char *k, char *out, size_t n)
{
    char cmd[128], b[192];
    out[0] = 0;
    snprintf(cmd, sizeof cmd, "getprop %s 2>/dev/null", k);
    FILE *p = popen(cmd, "r");
    if (!p) return;
    if (fgets(b, sizeof b, p)) {
        b[strcspn(b, "\r\n")] = 0;
        snprintf(out, n, "%s", b);
    }
    pclose(p);
}

/* 开启日志时一次性把「判断依据」写清：机型/内核/协议/屏幕/FCC。
 * 以前这些只在 daemon 启动时零散记一点，用户复现完导日志，
 * 还得回头问机型、节点、判定值，来回好几轮。 */
static void log_env(void)
{
    char model[64], rom[64], soc[64], kver[64] = "";
    char type[32] = "", rt[32] = "", p[MAXPATH];
    long vooc = -1, tech = -1, vmax = -1, cmax = -1;
    FILE *f;

    getprop_v("ro.product.model", model, sizeof model);
    getprop_v("ro.build.display.id", rom, sizeof rom);
    getprop_v("ro.soc.model", soc, sizeof soc);
    plat_resolve();
    f = popen("uname -r 2>/dev/null", "r");
    if (f) { if (fgets(kver, sizeof kver, f)) kver[strcspn(kver, "\r\n")] = 0; pclose(f); }

    log_msg("I", "env", "device=%s rom=%s kernel=%s soc=%s(%s) tick=%ds mode=%s",
            model[0] ? model : "?", rom[0] ? rom : "?", kver[0] ? kver : "?",
            soc[0] ? soc : "?", g_plat, g_c.tick, g_c.temp_mode);

    snprintf(p, sizeof p, "%s/usb/type", g_ps);
    if (read_line(p, type, sizeof type) < 0) type[0] = 0;
    type[strcspn(type, "\r\n")] = 0;
    snprintf(p, sizeof p, "%s/usb/real_type", g_ps);
    if (read_line(p, rt, sizeof rt) < 0) rt[0] = 0;
    rt[strcspn(rt, "\r\n")] = 0;
    oplus_num("voocchg_ing", &vooc);
    oplus_num("charge_technology", &tech);
    snprintf(p, sizeof p, "%s/usb/voltage_max", g_ps);
    path_num(p, &vmax);
    snprintf(p, sizeof p, "%s/usb/current_max", g_ps);
    path_num(p, &cmax);
    vmax = uv_norm(vmax);
    cmax = uv_norm(cmax);
    log_msg("I", "env", "usb type=%s real_type=%s vooc=%ld tech=%ld vmax=%ld cmax=%ld",
            type[0] ? type : "?", rt[0] ? rt : "?", vooc, tech, vmax, cmax);

    screen_scan();
    log_msg("I", "env", "screen bl=%s nodes=%d fb=%s 判定=%s",
            g_bl, g_bl_cnt, g_fb, g_screen_on ? "亮" : "灭");

    curr_prepare();
    if (g_curr_n > 0)
        log_msg("I", "env", "charge nodes=%d first=%s", g_curr_n, g_curr_nodes[0]);
    else
        log_msg("I", "env", "charge nodes=0（找不到电流节点，限流/亮屏快充都用不了）");
}

int main(int argc, char **argv)
{
    const char *d = getenv("SD_DATA");
    if (d && *d) snprintf(g_data, sizeof g_data, "%s", d);
    /* 元模块目录的父路径，测试时指到临时根，真机默认 /data/adb */
    const char *ab = getenv("SD_ADB");
    if (ab && *ab) snprintf(g_adb, sizeof g_adb, "%s", ab);
    const char *sr = getenv("SD_SYSROOT");
    if (sr && *sr) snprintf(g_sys, sizeof g_sys, "%s", sr);
    /* SD_MODDIR 是正式名；MODDIR 兼容 2.9.43 的 service.sh 只导出了 MODDIR */
    const char *md = getenv("SD_MODDIR");
    if (!md || !*md) md = getenv("MODDIR");
    if (md && *md) snprintf(g_moddir, sizeof g_moddir, "%s", md);

    paths_init();
    tz_init();
    mkdir_p(g_data);
    mkdir_p(g_run);

    if (argc > 1) {
        if (!strcmp(argv[1], "-v") || !strcmp(argv[1], "--version")) {
            printf("qcmon %s\n", VER);
            return 0;
        }
        conf_load();
        if (!strcmp(argv[1], "zones")) {
            zones_scan();
            for (int i = 0; i < g_zn; i++)
                printf("%-28s cls=%-8s temp=%d\n", g_z[i].type, CLS_NAME[g_z[i].cls], zone_temp(&g_z[i]));
            return 0;
        }
        if (!strcmp(argv[1], "bench")) {
            int n = argc > 2 ? atoi(argv[2]) : 50;
            if (n < 1) n = 1;
            zones_scan();
            struct timespec t0, t1;
            clock_gettime(CLOCK_MONOTONIC, &t0);
            for (int i = 0; i < n; i++) { int ch = 0; loop_once(&ch); }
            clock_gettime(CLOCK_MONOTONIC, &t1);
            double ms = ((t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1e6) / n;
            printf("%d 轮，平均 %.3f ms/轮（%d 温区，tick=%ds）\n", n, ms, g_zn, g_c.tick);
            return 0;
        }
        if (!strcmp(argv[1], "once")) {
            zones_scan();
            int out = shell_target();
            printf("zones=%d mode=%s real=%s lim=%s zone=%s out=%s\n",
                   g_zn, g_c.temp_mode,
                   g_tl_real[0] ? g_tl_real : "-",
                   g_tl_lim[0] ? g_tl_lim : "-",
                   g_tl_zone[0] ? g_tl_zone : "-", g_tl_out);
            (void)out;
            return 0;
        }
        if (!strcmp(argv[1], "chg")) {
            /* 现场读一次充电快照，不写日志，供 action.sh / 面板用 */
            zones_scan();
            screen_tick();
            screen_tick();
            char line[384];
            chg_line(line, sizeof line, NULL, 0);
            printf("%s\n", line);
            return 0;
        }
        if (!strcmp(argv[1], "sensor")) {
            zones_scan();
            /* 守护里靠"连续两次读到暗"确认息屏；单次命令没有历史，直接采两次 */
            screen_tick();
            screen_tick();
            char st[32];
            batt_status(st, sizeof st);
            int charging = !strcmp(st, "Charging") || !strcmp(st, "Full");
                    scr_tick();
            cool_tick();
            batt_sp_guard();
            if (!strcmp(g_c.temp_mode, "static")) shell_emul(shell_target());
            else if (!strcmp(g_c.temp_mode, "charge")) charge_tick();
            hb_write();
            telemetry();
            sync_desc();
            char b[320];
            read_line(g_sensor, b, sizeof b);
            printf("sensor: %s\nscreen=%d charging=%d emul=%d\n", b, g_screen_on, charging, g_emul_ok);
            return 0;
        }
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    sa.sa_handler = on_usr1;
    sigaction(SIGUSR1, &sa, NULL);   /* action.sh 每改一次配置都会发，不能让它退出 */

    conf_load();
    lock_acquire();
    curr_prepare();
    zones_scan();
    sync_desc();
    log_msg("I", "daemon", "qcmon %s 启动：tick=%ds mode=%s", VER, g_c.tick, g_c.temp_mode);
    if (g_c.log_level >= 1) log_env();

    while (!g_stop) {
        int changed = 0;
        int sec = loop_once(&changed);
        if (changed) sync_desc();
        if (g_tick_n % 12 == 3) sync_desc();

        struct timespec ts = { sec, 0 };
        while (!g_stop && !g_reload) {
            if (nanosleep(&ts, &ts) == 0) break;
            if (errno != EINTR) break;
        }
        if (g_reload) {
            g_reload = 0;
            log_msg("I", "daemon", "收到重载信号，立即刷新参数");
            zones_scan();
        }
    }

    restore_all();
    lock_release();
    log_msg("I", "daemon", "守护已停止");
    return 0;
}
