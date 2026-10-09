/* ---------------------------------------------------------------------------
 * lmepisowifi — SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 The lmepisowifi Project — see AUTHORS
 * ---------------------------------------------------------------------------
 *
 * wlanapply — restart ONE radio, or ONE SSID, of the vendor WLAN pipeline
 * (Realtek luna / RTL9607C boa + libmib) instead of the whole thing.
 *
 * `wlan_apply restart` is config_WLAN(ACT_RESTART, CONFIG_SSID_ALL): it stops
 * and starts every interface of both radios.  config_WLAN() itself, however,
 * already takes a band and an SSID index (subr_wlan.c):
 *
 *     ACT_{START,STOP,RESTART}_{2G,5G}, ssid_index
 *         stopwlan(band, idx)  : kill that interface's auth/wscd, ifconfig down,
 *                                brctl delif                  (only band/idx)
 *         startWLan(band, idx) : setupWLan(idx) pushes the MIB record into the
 *                                driver, then ifconfig up + brctl addif
 *                                (+ auth only when 802.1X is on)
 *
 * and the vendor web UI uses exactly that per SSID.  The stock `wlan_apply`
 * CLI just never exposes it.  config_WLAN() lives in libmib.so (subr_wlan.o is
 * part of MIB_DEPEND_FILES), so this tiny program calls it from its own
 * process, the same way wanapply drives restartWAN().  It reads the MIB the
 * same way wlan_apply does, so run `mib set` + `mib commit` first.
 *
 * Scope rule (the vendor's own, checkWlanRootChange()): anything on the root
 * interface or in the radio table (channel, width, TX power, rates, beacon
 * interval, radio enable ...) needs the WHOLE band restarted, because the
 * VAPs hang off the root; only a change confined to one VAP's MBSSIB record
 * can restart just that VAP.  So index 0 / "root" is treated as "all" on the
 * given band, never as a root-only restart that would leave the VAPs behind.
 *
 * Every libmib symbol is resolved with dlsym() at run time, so the binary does
 * not need libmib at link time and works on any build of this SoC.
 *
 * Usage:
 *   wlanapply check
 *       load libmib, resolve config_WLAN, report preloads; changes nothing
 *   wlanapply restart <2g|5g> <idx|all|root> [-n]
 *   wlanapply stop    <2g|5g> <idx|all|root> [-n]     (VAP: MIB wlanDisabled=1 first)
 *   wlanapply start   <2g|5g> <idx|all|root> [-n]     (VAP: MIB wlanDisabled=0 first)
 *       idx 1..7 is an SSID index (1..4 = wlanN-vap0..3, 5 = wlanN-vxd);
 *       -n / --dry-run validates and prints the call without making it
 *
 * Exit: 0 ok | 2 usage | 3 libmib/symbol | 8 config_WLAN returned an error
 *       75 another wlanapply is running
 *
 * Build: see wlanapply_build.sh (msdk-linux-gcc, glibc, -ldl).
 * ------------------------------------------------------------------------- */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

/* mib.h ACT_* */
#define ACT_START_2G    4
#define ACT_STOP_2G     5
#define ACT_RESTART_2G  6
#define ACT_START_5G    7
#define ACT_STOP_5G     8
#define ACT_RESTART_5G  9

/* subr_wlan.h config_wlan_ssid: CONFIG_SSID_ALL is 8 in both enum layouts
 * (WLAN_USE_VAP_AS_SSID1 on or off); 0 is the root interface when it is off. */
#define SSID_ALL        8
#define SSID_MAX        7

#define LOCK_PATH       "/tmp/wlanapply.lock"

typedef int (*fn_config_wlan)(int action_type, int ssid_index);
typedef int (*fn_info_name)(char *name, void *info);
typedef int (*fn_total)(int id);

static fn_config_wlan p_config_wlan;
static fn_info_name   p_info_name;
static fn_total       p_total;

static int die(int code, const char *fmt, ...) __attribute__((noreturn));
static int die(int code, const char *fmt, ...)
{
    va_list ap;
    fputs("wlanapply: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(code);
}

static void *sym(void *h, const char *name)
{
    void *p = dlsym(h, name);
    if (!p)
        die(3, "libmib.so has no symbol '%s' (%s)", name, dlerror());
    return p;
}

/* libmib.so is linked without DT_NEEDED on its dependencies, so symbols it
 * uses from other vendor libs are unresolved unless the host process already
 * loaded them.  Vendor binaries (boa, cli) get them from their link line; we
 * dlopen() libmib, so load them first with RTLD_GLOBAL.  Seen so far:
 *   g_VoIP_Feature (data)        <- libvoip_manager.so
 *   sem_destroy() (for librtk)   <- libpthread.so.0 (librtk.so has no DT_NEEDED
 *                                   on it; vendor binaries add -lpthread)
 *   rt_acl_filterAndQos_del()    <- fc_api.o in libmib, defined in the RTK/FC
 *                                   user API (rtusr_rt_acl_ext.c); lib not
 *                                   confirmed, librtk.so is the first guess.
 * Override/extend without rebuilding:  WLANAPPLY_PRELOAD=librtk.so:libfoo.so
 * (names or absolute paths, colon separated; replaces the default list).
 * Missing libs are skipped.  libmib is bound LAZILY, exactly like the vendor
 * binaries: it references many functions (EPON, ...) that this GPON build's
 * librtk never exports and that are never called on the WAN path, so RTLD_NOW
 * would refuse a library that works fine.  A strict RTLD_NOW attempt is still
 * made first; if it fails, its message is kept and shown by "check" as a
 * warning (it names one unresolved symbol, not necessarily one that matters). */
static struct { char name[64]; char err[160]; int ok; } pre[16];   /* ok: 0 fail, 1 ok, 2 ok (lazy) */
static int npre;

static void preload_one(const char *name)
{
    char path[256];
    const char *cand[2];
    const char *e = NULL;
    int i, n = 0;

    if (npre >= (int)(sizeof(pre) / sizeof(pre[0])))
        return;
    snprintf(pre[npre].name, sizeof(pre[npre].name), "%s", name);
    cand[n++] = name;
    if (!strchr(name, '/')) {
        snprintf(path, sizeof(path), "/lib/%s", name);
        cand[n++] = path;
    }
    for (i = 0; i < n; i++) {
        if (dlopen(cand[i], RTLD_NOW | RTLD_GLOBAL)) {
            pre[npre++].ok = 1;
            return;
        }
        e = dlerror();
        /* strict bind refused it; function symbols may be unused on our path
         * (vendor binaries bind lazily), so accept a lazy load */
        if (dlopen(cand[i], RTLD_LAZY | RTLD_GLOBAL)) {
            snprintf(pre[npre].err, sizeof(pre[npre].err), "%s", e ? e : "");
            pre[npre++].ok = 2;
            return;
        }
        e = dlerror();
    }
    snprintf(pre[npre].err, sizeof(pre[npre].err), "%s", e ? e : "unknown");
    npre++;
}

static void preload_deps(void)
{
    static const char *const defaults[] = {
        "libpthread.so.0", "librt.so.1", "libvoip_manager.so", "libmd5.so", "librtk.so", NULL
    };
    const char *env = getenv("WLANAPPLY_PRELOAD");
    unsigned i;

    if (env && *env) {
        char buf[512], *save = NULL, *tok;

        snprintf(buf, sizeof(buf), "%s", env);
        for (tok = strtok_r(buf, ":", &save); tok; tok = strtok_r(NULL, ":", &save))
            preload_one(tok);
        return;
    }
    for (i = 0; defaults[i]; i++)
        preload_one(defaults[i]);
}

static char strict_err[256];   /* why RTLD_NOW failed, if it did */

static void load_libmib(void)
{
    static const char *const names[] = {
        "libmib.so", "/lib/libmib.so", "/usr/lib/libmib.so", "libmib.so.0", NULL
    };
    void *h = NULL;
    int i;

    preload_deps();
    for (i = 0; names[i] && !h; i++)
        h = dlopen(names[i], RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        const char *e = dlerror();

        snprintf(strict_err, sizeof(strict_err), "%s", e ? e : "unknown");
        for (i = 0; names[i] && !h; i++)
            h = dlopen(names[i], RTLD_LAZY | RTLD_GLOBAL);
        if (!h)
            die(3, "cannot load libmib.so: %s", dlerror());
    }

    p_config_wlan = (fn_config_wlan)sym(h, "config_WLAN");
    /* informational only (check): do not die if a build lacks them */
    p_info_name = (fn_info_name)dlsym(h, "mib_chain_info_name");
    p_total     = (fn_total)    dlsym(h, "mib_chain_total");
}

/* "check" diagnostics: which preloads loaded (and why not), and whether chosen
 * symbols are visible in the global scope libmib's lazy binding will search.
 * Probe more without rebuilding:  WLANAPPLY_PROBE=sym1:sym2 wlanapply check */
static void report_deps(void)
{
    static const char *const probe_default[] = { "config_WLAN", NULL };
    void *g = dlopen(NULL, RTLD_LAZY);
    const char *env = getenv("WLANAPPLY_PROBE");
    char buf[512], *save = NULL, *tok;
    int i;

    for (i = 0; i < npre; i++) {
        if (pre[i].ok == 1)
            printf("preload %s: ok\n", pre[i].name);
        else if (pre[i].ok == 2)
            printf("preload %s: ok, lazy bind (strict said: %s)\n", pre[i].name, pre[i].err);
        else
            printf("preload %s: FAILED (%s)\n", pre[i].name, pre[i].err);
    }
    for (i = 0; probe_default[i]; i++)
        printf("symbol %s: %s\n", probe_default[i],
               g && dlsym(g, probe_default[i]) ? "found" : "MISSING");
    if (env && *env) {
        snprintf(buf, sizeof(buf), "%s", env);
        for (tok = strtok_r(buf, ":", &save); tok; tok = strtok_r(NULL, ":", &save))
            printf("symbol %s: %s\n", tok, g && dlsym(g, tok) ? "found" : "MISSING");
    }
}

/* "check": also show the MBSSIB chains, if this libmib exports the lookups.
 * Informational only - chain names are per radio (WLAN0_/WLAN1_MBSSIB_TBL). */
static void report_chains(void)
{
    static const char *const names[] = { "WLAN0_MBSSIB_TBL", "WLAN1_MBSSIB_TBL", NULL };
    int i;

    if (!p_info_name || !p_total) {
        puts("chains: mib_chain_info_name/mib_chain_total not exported (skipped)");
        return;
    }
    for (i = 0; names[i]; i++) {
        union { struct { int id; int mib_type; char name[32]; int per_record_size; } h;
                unsigned char raw[512]; } info;
        char n[64];

        memset(&info, 0, sizeof(info));
        snprintf(n, sizeof(n), "%s", names[i]);
        if (p_info_name(n, &info))
            printf("chain %s: id %d, %d record(s)\n", names[i], info.h.id, p_total(info.h.id));
        else
            printf("chain %s: not known to configd\n", names[i]);
    }
}

static void usage(void)
{
    fputs("usage: wlanapply check\n"
          "       wlanapply restart|stop|start <2g|5g> <idx|all|root> [-n]\n"
          "  idx 1..7 = one SSID (1..4 = vap0..3, 5 = vxd); all/root/0 = whole band\n"
          "  -n, --dry-run   validate and print the call, do not make it\n", stderr);
    exit(2);
}

static int parse_band(const char *s)
{
    if (!strcmp(s, "2g") || !strcmp(s, "2") || !strcmp(s, "24"))
        return 2;
    if (!strcmp(s, "5g") || !strcmp(s, "5"))
        return 5;
    return 0;
}

static int parse_idx(const char *s, int *root_aliased)
{
    char *end;
    long v;

    *root_aliased = 0;
    if (!strcmp(s, "all"))
        return SSID_ALL;
    if (!strcmp(s, "root") || !strcmp(s, "0")) {
        *root_aliased = 1;
        return SSID_ALL;
    }
    v = strtol(s, &end, 10);
    if (*s == '\0' || *end != '\0' || v < 1 || v > SSID_MAX)
        return -1;
    return (int)v;
}

int main(int argc, char **argv)
{
    static const int act[2][3] = {          /* [band 2g/5g][start, stop, restart] */
        { ACT_START_2G, ACT_STOP_2G, ACT_RESTART_2G },
        { ACT_START_5G, ACT_STOP_5G, ACT_RESTART_5G },
    };
    const char *cmd;
    int kind, band, idx, aliased, action, dry = 0, lockfd, rc, i;

    if (argc < 2)
        usage();
    cmd = argv[1];

    if (!strcmp(cmd, "check")) {
        load_libmib();
        printf("config_WLAN: found\n");
        report_deps();
        if (*strict_err)
            printf("note: strict bind refused libmib (%s); using lazy bind like the vendor binaries\n",
                   strict_err);
        report_chains();
        return 0;
    }

    if (!strcmp(cmd, "start"))        kind = 0;
    else if (!strcmp(cmd, "stop"))    kind = 1;
    else if (!strcmp(cmd, "restart")) kind = 2;
    else                              usage();

    if (argc < 4)
        usage();
    band = parse_band(argv[2]);
    idx  = parse_idx(argv[3], &aliased);
    if (!band || idx < 0)
        usage();
    for (i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "-n") || !strcmp(argv[i], "--dry-run"))
            dry = 1;
        else
            usage();
    }

    action = act[band == 5][kind];
#define ANNOUNCE() \
    printf("wlanapply: %s %dg %s -> config_WLAN(%d, %d)%s%s\n", cmd, band, \
           idx == SSID_ALL ? "all SSIDs" : argv[3], action, idx, \
           aliased ? "  [root change: whole band, as the vendor does]" : "", \
           dry ? "  [dry run]" : "")
    if (dry) {
        ANNOUNCE();
        return 0;
    }

    lockfd = open(LOCK_PATH, O_CREAT | O_RDWR, 0600);
    if (lockfd >= 0 && flock(lockfd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK) {
        fputs("wlanapply: another wlanapply is running\n", stderr);
        return 75;
    }
    ANNOUNCE();

    load_libmib();
    rc = p_config_wlan(action, idx);
    printf("wlanapply: config_WLAN returned %d\n", rc);
    return rc == 0 ? 0 : 8;
}
