/*
 * qcmon — Quick Charge 守护进程（C 版）
 *
 * 与 shell 版共用同一份 state.conf 与同一套节点路径约定。
 * 负责每轮热路径：读温区 → 写伪装 → 算限流 → 熔断。
 * 安装、卸载、WebUI、配置改写仍由 shell 侧负责，这里不碰。
 *
 * 状态文件、日志格式、节点单位判定均与 lib/qc.sh 对齐，
 * 两版可以互相替换而不用改 WebUI。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/types.h>

#define VER "2.9.43"

#define MAXZ 192
#define MAXLINE 512

/* 温区分类，与 sd_zone_class 一一对应 */
enum { C_OTHER = 0, C_BATTERY, C_SHELL, C_CORE, C_BOARD };
/* 伪装范围，独立于分类枚举：C_OTHER 是 0，不能拿 0 当「全部」 */
enum { SP_SHELL = 101, SP_CORE, SP_NONCORE, SP_BATT };

typedef struct {
    char path[256];
    char type[64];
    int cls;
    int unit;          /* 1000=毫摄氏度 10=十分之一度 1=摄氏度 */
} zone_t;

static zone_t g_z[MAXZ];
static int g_zn = 0;
static int g_scanned = 0;

/* 配置，键名与 state.conf 相同 */
typedef struct {
    char temp_mode[16];
    int shell_temp;      /* 0=off */
    int core_temp;
    int noncore_temp;
    int wall;            /* 0=off */
    int aggr;
    int curr_max;
    int curr_edge;
    int battery_limit;
    int sentinel_limit;
    int tick;
    int fast_cap;
    int horae;
} conf_t;

static conf_t g_c;
static char g_data[256] = "/data/adb/quickcharge";
static char g_state[300];
static char g_log[320];
static char g_run[300];
static char g_moddir[256] = "";
/* 测试用：把 /sys 换成别的根，真机留空 */
static char g_sys[128] = "";

static volatile sig_atomic_t g_stop = 0;
static int g_screen_on = 1;
static int g_last_pct = 100;
static int g_wall_eff = 0;
static char g_plat[8] = "";      /* qcom / mtk / other */
static int g_spoof_done_core = 0;
static int g_spoof_done_nc = 0;
static int g_tick_n = 0;

/* ------------------------------------------------------------------ 基础 */

static void on_signal(int s) { (void)s; g_stop = 1; }


static void ts_str(char *out, size_t n)
{
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(out, n, "%m-%d %H:%M:%S", &tm);
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
    ssize_t w = write(fd, s, strlen(s));
    close(fd);
    return (w == (ssize_t)strlen(s)) ? 0 : -1;
}

static void log_msg(const char *lvl, const char *tag, const char *fmt, ...)
{
    char t[32], msg[400], line[512];
    va_list ap;
    ts_str(t, sizeof t);
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    snprintf(line, sizeof line, "%s I [%s] %s\n", t, tag, msg);
    if (lvl && lvl[0] == 'W') {
        snprintf(line, sizeof line, "%s W [%s] %s\n", t, tag, msg);
    } else if (lvl && lvl[0] == 'E') {
        snprintf(line, sizeof line, "%s E [%s] %s\n", t, tag, msg);
    }
    int fd = open(g_log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) return;
    if (write(fd, line, strlen(line)) < 0) { /* 日志写失败不影响守护 */ }
    close(fd);
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

/* ------------------------------------------------------------------ 配置 */

static void conf_defaults(void)
{
    memset(&g_c, 0, sizeof g_c);
    snprintf(g_c.temp_mode, sizeof g_c.temp_mode, "off");
    g_c.shell_temp = 0;
    g_c.core_temp = 0;
    g_c.noncore_temp = 0;
    g_c.wall = 42;
    g_c.aggr = 10;
    g_c.curr_max = 0;
    g_c.curr_edge = 4;
    g_c.battery_limit = 48;
    g_c.sentinel_limit = 85;
    g_c.tick = 15;
    g_c.fast_cap = 55;
    g_c.horae = 1;
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

static void conf_load(void)
{
    FILE *f = fopen(g_state, "r");
    if (!f) return;
    char line[MAXLINE];
    while (fgets(line, sizeof line, f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || !*p) continue;
        char *eq = strchr(p, '=');
        if (!eq) continue;
        *eq = 0;
        char *k = p, *v = eq + 1;
        char *e = v + strlen(v);
        while (e > v && (e[-1] == '\n' || e[-1] == '\r' || e[-1] == ' ')) *--e = 0;

        if (!strcmp(k, "temp_mode")) snprintf(g_c.temp_mode, sizeof g_c.temp_mode, "%s", v);
        else if (!strcmp(k, "shell_temp")) g_c.shell_temp = parse_i(v, 0);
        else if (!strcmp(k, "core_temp")) g_c.core_temp = parse_i(v, 0);
        else if (!strcmp(k, "noncore_temp")) g_c.noncore_temp = parse_i(v, 0);
        else if (!strcmp(k, "wall")) g_c.wall = parse_i(v, 42);
        else if (!strcmp(k, "aggr")) g_c.aggr = parse_i(v, 10);
        else if (!strcmp(k, "curr_max")) g_c.curr_max = parse_i(v, 0);
        else if (!strcmp(k, "curr_edge")) g_c.curr_edge = parse_i(v, 4);
        else if (!strcmp(k, "battery_limit")) g_c.battery_limit = parse_i(v, 48);
        else if (!strcmp(k, "sentinel_limit")) g_c.sentinel_limit = parse_i(v, 85);
        else if (!strcmp(k, "tick")) g_c.tick = parse_i(v, 15);
        else if (!strcmp(k, "fast_cap")) g_c.fast_cap = parse_i(v, 55);
        else if (!strcmp(k, "horae")) g_c.horae = parse_i(v, 1);
    }
    fclose(f);

    if (g_c.tick < 5) g_c.tick = 5;
    if (g_c.tick > 300) g_c.tick = 300;
    if (g_c.curr_max < 0) g_c.curr_max = 0;
    if (g_c.curr_max > 8000) g_c.curr_max = 8000;
    if (g_c.curr_edge < 0) g_c.curr_edge = 0;
    if (g_c.curr_edge > 6) g_c.curr_edge = 6;
    if (g_c.battery_limit < 30) g_c.battery_limit = 30;
    if (g_c.battery_limit > 70) g_c.battery_limit = 70;
    if (g_c.wall && (g_c.wall < 35 || g_c.wall > 80)) g_c.wall = 42;
    if (g_c.aggr < 0) g_c.aggr = 0;
    if (g_c.aggr > 10) g_c.aggr = 10;
}

/* ------------------------------------------------------------------ 温区 */

static int cls_of(const char *t)
{
    if (!t || !*t) return C_OTHER;
    if (strstr(t, "hw-trip") || strstr(t, "hw_trip") ||
        strstr(t, "bcl-lvl") || strstr(t, "bcl_lvl") ||
        strstr(t, "ibat-lvl") || strstr(t, "ibat_lvl") ||
        strstr(t, "vbat")) return C_OTHER;
    if (strstr(t, "batt") || strstr(t, "Batt")) return C_BATTERY;
    if (strstr(t, "shell") || strstr(t, "Shell") || strstr(t, "back") ||
        strstr(t, "case") || strstr(t, "skin") || strstr(t, "cover") ||
        strstr(t, "frame")) return C_SHELL;
    if (strstr(t, "cpu") || strstr(t, "CPU") || strstr(t, "cpullc") ||
        strstr(t, "cpuss") || strstr(t, "gpu") || strstr(t, "GPU") ||
        strstr(t, "ddr") || strstr(t, "mtktsap") || strstr(t, "mtktsabb") ||
        strstr(t, "tzts") || strstr(t, "tsen_max") || strstr(t, "soc") ||
        strstr(t, "Soc")) return C_CORE;
    if (strstr(t, "xo-therm") || strstr(t, "xtherm") || strstr(t, "pmic") ||
        strstr(t, "charger") || strstr(t, "board") || strstr(t, "sys-therm") ||
        strstr(t, "mtktspa") || strstr(t, "mtktswmt") || strstr(t, "mtktsbtsmdpa") ||
        !strcmp(t, "pa") || (strstr(t, "pa") && t[strlen(t) - 3] == '_')) return C_BOARD;
    return C_OTHER;
}

/* 单位按当前读数推断，与 sd_zone_temp_unit 相同 */
static int temp_unit(const char *zp)
{
    char b[64];
    snprintf(b, sizeof b, "%s/temp", zp);
    int v;
    if (read_int(b, &v) < 0) return 1000;
    if (v >= 2000) return 1000;
    if (v >= 150) return 10;
    return 1;
}

static int temp_c(const zone_t *z)
{
    char b[256];
    snprintf(b, sizeof b, "%s/temp", z->path);
    int v;
    if (read_int(b, &v) < 0) return -1000;
    if (v > 0 || v == 0) {
        if (z->unit == 1000) return v / 1000;
        if (z->unit == 10) return v / 10;
        return v;
    }
    return -1000;
}

static void zones_scan(void)
{
    g_zn = 0;
    char root[256];
    snprintf(root, sizeof root, "%s/sys/class/thermal", g_sys);
    DIR *d = opendir(root);
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d)) && g_zn < MAXZ) {
        if (strncmp(de->d_name, "thermal_zone", 12)) continue;
        zone_t *z = &g_z[g_zn];
        snprintf(z->path, sizeof z->path, "%s/%s", root, de->d_name);
        char tp[256];
        snprintf(tp, sizeof tp, "%s/type", z->path);
        if (read_line(tp, z->type, sizeof z->type) < 0) continue;
        z->cls = cls_of(z->type);
        z->unit = temp_unit(z->path);
        g_zn++;
    }
    closedir(d);
    g_scanned = 1;
    log_msg("I", "scan", "温区 %d 个", g_zn);
}

/* ------------------------------------------------------------------ 伪装 */

static char g_spoof_dir[256] = "/dev/qc";

static int spoof_apply(int scope, int celsius)
{
    if (celsius < 20 || celsius > 100) return -1;
    if (g_zn == 0) zones_scan();
    mkdir_p(g_spoof_dir);
    chmod(g_spoof_dir, 0700);

    int hit = 0, fail = 0;
    for (int i = 0; i < g_zn; i++) {
        zone_t *z = &g_z[i];
        int in = 0;
        switch (scope) {
            case SP_CORE:    in = (z->cls == C_CORE); break;
            case SP_NONCORE: in = (z->cls != C_CORE && z->cls != C_SHELL); break;
            case SP_BATT:    in = (z->cls == C_BATTERY); break;
            case SP_SHELL:   in = (z->cls == C_SHELL || z->cls == C_BOARD || z->cls == C_OTHER); break;
            default:         in = 0; break;
        }
        if (!in) continue;

        int ms;
        if (z->unit == 10) ms = celsius * 10;
        else if (z->unit == 1) ms = celsius;
        else ms = celsius * 1000;

        char tf[320], tmp[400];
        snprintf(tmp, sizeof tmp, "%s/temp", z->path);
        umount2(tmp, MNT_DETACH);

        const char *base = strrchr(z->path, '/');
        base = base ? base + 1 : z->path;
        snprintf(tf, sizeof tf, "%s/%s.temp", g_spoof_dir, base);
        snprintf(tmp, sizeof tmp, "%d\n", ms);
        if (write_str(tf, tmp) < 0) {
            static int once2 = 0;
            if (!once2) { once2 = 1; log_msg("W", "thermal", "写临时文件失败 %s: %s，回退 %s", tf, strerror(errno), g_run); }
            snprintf(tf, sizeof tf, "%s/%s.temp", g_run, base);
            if (write_str(tf, tmp) < 0) { fail++; continue; }
        }
        chmod(tf, 0644);
        snprintf(tmp, sizeof tmp, "%s/temp", z->path);
        if (mount(tf, tmp, NULL, MS_BIND, NULL) == 0) {
            hit++;
        } else {
            static int once = 0;
            if (!once) { once = 1; log_msg("W", "thermal", "bind 失败 %s → %s: %s", tf, tmp, strerror(errno)); }
            fail++;
        }
    }
    const char *sn = scope == SP_CORE ? "core" : scope == SP_NONCORE ? "noncore" :
                     scope == SP_BATT ? "batt" : scope == SP_SHELL ? "shell" : "?";
    log_msg(hit ? "I" : "W", "thermal", "伪装 %s → %d℃，命中 %d，失败 %d",
            sn, celsius, hit, fail);
    return hit > 0 ? 0 : -1;
}

static void spoof_clear(void)
{
    for (int i = 0; i < g_zn; i++) {
        char p[320];
        snprintf(p, sizeof p, "%s/temp", g_z[i].path);
        umount2(p, MNT_DETACH);
    }
    g_spoof_done_core = 0;
    g_spoof_done_nc = 0;
}

/* ------------------------------------------------------------------ 电池 */

static int batt_status(char *out, size_t n)
{
    char p0[256], p1[256];
    snprintf(p0, sizeof p0, "%s/sys/class/power_supply/battery/status", g_sys);
    snprintf(p1, sizeof p1, "%s/sys/class/power_supply/bms/status", g_sys);
    const char *paths[] = { p0, p1, NULL };
    for (int i = 0; paths[i]; i++)
        if (read_line(paths[i], out, n) == 0) return 0;
    return -1;
}


static int batt_temp(void)
{
    char p0[256], p1[256];
    snprintf(p0, sizeof p0, "%s/sys/class/power_supply/battery/temp", g_sys);
    snprintf(p1, sizeof p1, "%s/sys/class/power_supply/bms/temp", g_sys);
    const char *paths[] = { p0, p1, NULL };
    int v;
    for (int i = 0; paths[i]; i++) {
        if (read_int(paths[i], &v) == 0) {
            /* 三种编码：38000=毫度、380=0.1℃、38=℃ */
            if (v >= 1000) return v / 1000;
            if (v >= 100) return v / 10;
            return v;
        }
    }
    return -1000;
}

/* ------------------------------------------------------------------ 平台 */

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
             strstr(b, "taro") || strstr(b, "sun")) snprintf(g_plat, sizeof g_plat, "qcom");
    else snprintf(g_plat, sizeof g_plat, "other");
}

/* ------------------------------------------------------------------ 哨兵 */

/* 选一个温度哨兵：battery → board → other，跳过无法读取的 */
static int sentinel_pick(zone_t **out)
{
    for (int pass = 0; pass < 3; pass++) {
        int want = pass == 0 ? C_BATTERY : (pass == 1 ? C_BOARD : C_OTHER);
        for (int i = 0; i < g_zn; i++) {
            if (g_z[i].cls != want) continue;
            if (temp_c(&g_z[i]) < -100) continue;
            *out = &g_z[i];
            return 0;
        }
    }
    return -1;
}

static int limit_for(const zone_t *z)
{
    if (z->cls == C_BATTERY) {
        if (g_c.battery_limit == 0) return -1;   /* off */
        return g_c.battery_limit;
    }
    if (g_c.sentinel_limit == 0) return -1;
    return g_c.sentinel_limit;
}

/* 哨兵温度：battery 类直接读电量计，避开自己对 thermal_zone 的伪装 */
static int sent_temp(zone_t *z)
{
    if (z->cls == C_BATTERY) {
        int bt = batt_temp();
        if (bt > -100) return bt;
    }
    return temp_c(z);
}

/* 目标电流 = curr_max 按温度阶梯打折，逻辑同 sd_curr_target_v */
static int curr_target(int *out_wall)
{
    int ma = g_c.curr_max;
    if (ma <= 0) return 0;

    zone_t *s = NULL;
    if (sentinel_pick(&s) < 0) return ma;
    int cur = sent_temp(s);
    if (cur < -100) return ma;

    int wall = g_c.wall;
    int lim = limit_for(s);
    if (wall <= 0) {
        wall = (lim > 0 ? lim : 48) - 4;
        if (wall < 35) wall = 35;
        if (wall > 80) wall = 80;
    }
    if (!g_screen_on) {
        wall += 2;
        if (lim > 0 && wall > lim - 3) wall = lim - 3;
    }
    *out_wall = wall;

    plat_resolve();
    int shift = !strcmp(g_plat, "mtk") ? 2 : 0;
    int edge = g_c.curr_edge;

    int t75 = wall - edge - shift;
    int t50 = wall - edge + 2 - shift;
    int t25 = wall - edge + 4 - shift;
    if (t75 < 30) t75 = 30;
    int l2 = lim > 0 ? lim : 48;
    if (t25 >= l2) t25 = l2 - 1;
    if (t50 >= t25) t50 = t25 - 1;
    if (t75 >= t50) t75 = t50 - 1;

    int pct = 100;
    if (cur >= t75) pct = 75;
    if (cur >= t50) pct = 50;
    if (cur >= t25) pct = 25;

    /* 滞回：升温才降档，降温要退回阈下一度才升档，避免边界抖动 */
    int last = g_last_pct;
    if (pct > last) {
        if (last == 25 && cur > t25 - 1) pct = 25;
        else if (last == 50 && cur > t50 - 1) pct = 50;
        else if (last == 75 && cur > t75 - 1) pct = 75;
    }
    g_last_pct = pct;

    return ma * pct / 100;
}

/* ------------------------------------------------------------------ 亮屏快充 */

static int scr_node(char *out, size_t n)
{
    char b0[256], b1[256], b2[256];
    snprintf(b0, sizeof b0, "%s/sys/module/oplus_chg/parameters/ignore_screen_state", g_sys);
    snprintf(b1, sizeof b1, "%s/sys/module/oplus_chg_v2/parameters/ignore_screen_state", g_sys);
    snprintf(b2, sizeof b2, "%s/sys/module/oplus_charge/parameters/ignore_screen_state", g_sys);
    const char *p[] = { b0, b1, b2, NULL };
    for (int i = 0; p[i]; i++) {
        if (access(p[i], F_OK) == 0) { snprintf(out, n, "%s", p[i]); return 0; }
    }
    return -1;
}

static int fcc_node(char *out, size_t n)
{
    char b0[256], b1[256], b2[256];
    snprintf(b0, sizeof b0, "%s/sys/class/power_supply/battery/constant_charge_current_max", g_sys);
    snprintf(b1, sizeof b1, "%s/sys/class/power_supply/battery/current_max", g_sys);
    snprintf(b2, sizeof b2, "%s/sys/class/power_supply/usb/current_max", g_sys);
    const char *p[] = { b0, b1, b2, NULL };
    for (int i = 0; p[i]; i++) {
        if (access(p[i], F_OK) == 0) { snprintf(out, n, "%s", p[i]); return 0; }
    }
    return -1;
}

static int g_fcc_norm = 0;

static void scr_tick(void)
{
    static char orig_path[256];
    static int orig_val = -1;

    char node[256];
    if (scr_node(node, sizeof node) == 0) {
        if (orig_val < 0) {
            int v = 0;
            if (read_int(node, &v) == 0) { orig_val = v; snprintf(orig_path, sizeof orig_path, "%s", node); }
        }
        if (!g_screen_on) {
            if (orig_val >= 0) { char b[16]; snprintf(b, sizeof b, "%d\n", orig_val); write_str(node, b); orig_val = -1; }
            return;
        }
        if (write_str(node, "1\n") == 0) return;
    }

    char fcc[256];
    if (fcc_node(fcc, sizeof fcc) < 0) return;

    int cur = 0;
    if (read_int(fcc, &cur) < 0) return;
    if (cur > 100000) cur /= 1000;

    if (!g_screen_on) {
        if (orig_val >= 0 && cur < orig_val) {
            char b[32]; snprintf(b, sizeof b, "%d\n", orig_val);
            write_str(fcc, b);
        }
        return;
    }

    if (cur >= 500 && (g_fcc_norm == 0 || cur > g_fcc_norm)) g_fcc_norm = cur > 8000 ? 8000 : cur;
    if (g_fcc_norm < 500) return;

    int bt = batt_temp();
    int target = g_fcc_norm;
    if (bt >= 42) return;
    if (bt >= 38) target = g_fcc_norm * 7 / 10;
    if (cur >= target) return;

    if (orig_val < 0) { orig_val = cur; snprintf(orig_path, sizeof orig_path, "%s", fcc); }
    char b[32];
    snprintf(b, sizeof b, "%d\n", cur > 100000 ? target * 1000 : target);
    write_str(fcc, b);
}

static void scr_release(void)
{
    char node[256];
    if (scr_node(node, sizeof node) == 0) write_str(node, "0\n");
}

/* ------------------------------------------------------------------ 熔断 */

static int check_fuse(zone_t *s)
{
    if (!s) return 0;
    int cur = sent_temp(s);
    if (cur < -100) return 0;
    int lim = limit_for(s);
    if (lim < 0) return 0;
    return cur >= lim ? 1 : 0;
}

/* ------------------------------------------------------------------ 主循环 */

static char g_lock[320];

static void lock_acquire(void)
{
    snprintf(g_lock, sizeof g_lock, "%s/daemon.lock", g_run);
    if (mkdir(g_lock, 0755) < 0) {
        if (errno != EEXIST) return;
        /* 已有实例：pid 还活着就直接退出，避免两个守护同时写节点 */
        char p[360], b[32] = "";
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
    char p[360], b[32];
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
    rmdir(g_lock);
    snprintf(p, sizeof p, "%s/daemon.pid", g_run);
    unlink(p);
}

static void heartbeat(void)
{
    char b[64];
    snprintf(b, sizeof b, "%ld\n", (long)time(NULL));
    char p[320];
    snprintf(p, sizeof p, "%s/hb", g_run);
    write_str(p, b);
}

static int screen_state(void)
{
    char b0[256], b1[256];
    snprintf(b0, sizeof b0, "%s/sys/class/backlight/panel0-backlight/brightness", g_sys);
    snprintf(b1, sizeof b1, "%s/sys/class/backlight/panel1-backlight/brightness", g_sys);
    const char *p[] = { b0, b1, NULL };
    int v;
    for (int i = 0; p[i]; i++) {
        if (read_int(p[i], &v) == 0) return v > 0 ? 1 : 0;
    }
    return 1;
}

static void restore_all(void)
{
    spoof_clear();
    scr_release();
    log_msg("I", "daemon", "收到退出信号，伪装与屏幕状态已还原");
}

int main(int argc, char **argv)
{
    const char *d = getenv("SD_DATA");
    if (d && *d) snprintf(g_data, sizeof g_data, "%s", d);
    const char *sr = getenv("SD_SYSROOT");
    if (sr && *sr) snprintf(g_sys, sizeof g_sys, "%s", sr);
    const char *md = getenv("SD_MODDIR");
    if (md && *md) snprintf(g_moddir, sizeof g_moddir, "%s", md);

    snprintf(g_state, sizeof g_state, "%s/state.conf", g_data);
    snprintf(g_log, sizeof g_log, "%s/log.txt", g_data);
    snprintf(g_run, sizeof g_run, "%s/run", g_data);
    mkdir_p(g_data);
    mkdir_p(g_run);

    if (argc > 1) {
        if (!strcmp(argv[1], "-v") || !strcmp(argv[1], "--version")) {
            printf("qcmon %s\n", VER);
            return 0;
        }
        if (!strcmp(argv[1], "zones")) {
            zones_scan();
            for (int i = 0; i < g_zn; i++) {
                static const char *cn[] = { "other", "battery", "shell", "core", "board" };
                printf("%-28s cls=%-8s unit=%d temp=%d\n", g_z[i].type,
                       cn[g_z[i].cls], g_z[i].unit, temp_c(&g_z[i]));
            }
            return 0;
        }
        if (!strcmp(argv[1], "once")) {
            conf_load();
            zones_scan();
            int wall = 0;
            int tgt = curr_target(&wall);
            printf("zones=%d mode=%s wall=%d target=%d\n", g_zn, g_c.temp_mode, wall, tgt);
            return 0;
        }
    }

    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGHUP, on_signal);

    conf_defaults();
    conf_load();
    lock_acquire();
    log_msg("I", "daemon", "qcmon %s 启动：tick=%ds mode=%s", VER, g_c.tick, g_c.temp_mode);

    while (!g_stop) {
        conf_load();
        g_tick_n++;

        if (!g_scanned || g_tick_n % 40 == 0) zones_scan();
        g_screen_on = screen_state();

        char st[64] = "";
        batt_status(st, sizeof st);
        int charging = !strcmp(st, "Charging") || !strcmp(st, "Full");

        if (!strcmp(g_c.temp_mode, "off")) {
            if (g_spoof_done_core || g_spoof_done_nc) {
                spoof_clear();
                log_msg("I", "thermal", "模式为关闭，伪装已撤销");
            }
        } else if (!charging) {
            if (g_spoof_done_core || g_spoof_done_nc) {
                spoof_clear();
                log_msg("I", "thermal", "未充电，伪装已撤销");
            }
        } else {
            /* 伪装：core / noncore / shell 三条独立路径 */
            if (g_c.core_temp >= 20) {
                spoof_apply(SP_CORE, g_c.core_temp);
                g_spoof_done_core = 1;
            } else if (g_spoof_done_core) {
                g_spoof_done_core = 0;
            }
            if (g_c.noncore_temp >= 20) {
                spoof_apply(SP_NONCORE, g_c.noncore_temp);
                g_spoof_done_nc = 1;
            } else if (g_spoof_done_nc) {
                g_spoof_done_nc = 0;
            }
            if (g_c.shell_temp >= 20 && !strcmp(g_c.temp_mode, "static")) {
                spoof_apply(SP_SHELL, g_c.shell_temp);
            }

            zone_t *s = NULL;
            sentinel_pick(&s);

            int wall = 0;
            int tgt = curr_target(&wall);
            g_wall_eff = wall;

            if (check_fuse(s)) {
                log_msg("W", "charge", "熔断：哨兵 %s 达 %d℃（限 %d），本轮不限流",
                        s ? s->type : "?", s ? sent_temp(s) : 0, limit_for(s));
            } else if (tgt > 0) {
                char fcc[256];
                if (fcc_node(fcc, sizeof fcc) == 0) {
                    char b[32];
                    int v = 0;
                    if (read_int(fcc, &v) == 0 && v > 100000) snprintf(b, sizeof b, "%d\n", tgt * 1000);
                    else snprintf(b, sizeof b, "%d\n", tgt);
                    if (write_str(fcc, b) == 0)
                        log_msg("I", "charge", "限流 %dmA（墙 %d℃，哨兵 %s=%d℃）",
                                tgt, wall, s ? s->type : "?", s ? sent_temp(s) : 0);
                }
            }

            scr_tick();
        }

        heartbeat();

        struct timespec ts = { g_c.tick, 0 };
        nanosleep(&ts, NULL);
    }

    restore_all();
    lock_release();
    return 0;
}
