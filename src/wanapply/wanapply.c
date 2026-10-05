/* ---------------------------------------------------------------------------
 * lmepisowifi — SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 The lmepisowifi Project — see AUTHORS
 * ---------------------------------------------------------------------------
 *
 * wanapply — live-apply helper for the vendor WAN pipeline (Realtek luna /
 * RTL9607C boa + libmib).  The vendor web page multi_wan_generic.asp does
 *
 *     deleteConnection(CONFIGONE, &old);   // tear down using the OLD record
 *     mib_chain_update(...) / _add / _delete
 *     restartWAN(CONFIGONE, &new);         // create nas0_N, smux rules, dhcp/ppp, NAT
 *     Commit(); fork+exec /bin/firewall.sh
 *
 * all inside boa.  deleteConnection() and restartWAN() live in libmib.so
 * (utility.o is part of MIB_DEPEND_FILES), and the vendor `cli` binary calls
 * them from its own process (cfgutility.c), so a separate process can drive the
 * same sequence.  `mib set` cannot: it only edits configd's copy of the chain.
 *
 * Nothing here depends on the layout of MIB_CE_ATM_VC_T.  The record is read
 * into an opaque buffer sized from the chain table's own per_record_size and
 * handed straight back to libmib.  Every libmib symbol is resolved with
 * dlsym() at run time, so the binary does not need libmib at link time and
 * `wanapply check` tells you immediately if a firmware build lacks one.
 *
 * Usage (run order matters, see the comments in wan-profile.cgi):
 *   wanapply check                     resolve symbols + chain table, change nothing
 *   wanapply info  <idx>               print ifIndex of ATM_VC_TBL.<idx>
 *   wanapply stop  <idx> [--expect-ifindex N]
 *                                      deleteConnection(CONFIGONE, current record)
 *                                      -> run BEFORE changing the record
 *   wanapply start <idx> [--expect-ifindex N] [--no-firewall]
 *                                      restartWAN(CONFIGONE, current record), then
 *                                      /bin/firewall.sh like boa does
 *   wanapply refresh [--no-firewall]   restartWAN(CONFIGONE, NULL)  (after a delete)
 *   wanapply all     [--no-firewall]   restartWAN(CONFIGALL, NULL)
 *   wanapply delete <idx> [--expect-ifindex N] [--no-firewall]
 *                                      deleteConnection + mib_chain_delete +
 *                                      restartWAN(CONFIGONE, NULL)  — full remove
 *
 * Exit: 0 ok | 2 usage | 3 libmib/symbol | 4 chain table | 5 record read
 *       6 ifIndex mismatch | 7 chain delete failed | 75 another wanapply is running
 *
 * Build: see build.sh (msdk-linux-gcc, uClibc, -ldl).
 * ------------------------------------------------------------------------- */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define CONFIGONE 0   /* utility.h */
#define CONFIGALL 1

#define CHAIN_NAME    "ATM_VC_TBL"
#define LOCK_PATH     "/tmp/wanapply.lock"
#define FIREWALL_PROG "/bin/firewall.sh"   /* _CONFIG_SCRIPT_PATH/_FIREWALL_SCRIPT_PROG */

/* Leading fields of mib_chain_record_table_entry_T (mibtbl.h).  Only the
 * prefix is used; the real struct is copied into a larger scratch buffer.   */
struct chain_head {
    int  id;
    int  mib_type;
    char name[32];
    int  per_record_size;
};

typedef int  (*fn_info_name)(char *name, void *info);
typedef int  (*fn_total)(int id);
typedef int  (*fn_get)(int id, unsigned int idx, void *rec);
typedef int  (*fn_delconn)(int configAll, void *entry);
typedef void (*fn_restart)(int configAll, void *entry);
typedef int  (*fn_chain_del)(int id, unsigned int idx);

static fn_info_name p_info_name;
static fn_total     p_total;
static fn_get       p_get;
static fn_delconn   p_delconn;
static fn_restart   p_restart;
static fn_chain_del p_chain_del;

static int chain_id, rec_size;

static int die(int code, const char *fmt, ...) __attribute__((noreturn));
#include <stdarg.h>
static int die(int code, const char *fmt, ...)
{
    va_list ap;
    fputs("wanapply: ", stderr);
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
 * Override/extend without rebuilding:  WANAPPLY_PRELOAD=librtk.so:libfoo.so
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
    const char *env = getenv("WANAPPLY_PRELOAD");
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

    p_info_name = (fn_info_name)sym(h, "mib_chain_info_name");
    p_total     = (fn_total)    sym(h, "mib_chain_total");
    p_get       = (fn_get)      sym(h, "mib_chain_get");
    p_delconn   = (fn_delconn)  sym(h, "deleteConnection");
    p_restart   = (fn_restart)  sym(h, "restartWAN");
    p_chain_del = (fn_chain_del)sym(h, "mib_chain_delete");
}

/* "check" diagnostics: which preloads loaded (and why not), and whether chosen
 * symbols are visible in the global scope libmib's lazy binding will search.
 * Probe more without rebuilding:  WANAPPLY_PROBE=sym1:sym2 wanapply check */
static void report_deps(void)
{
    static const char *const probe_default[] = { "rt_acl_filterAndQos_del", NULL };
    void *g = dlopen(NULL, RTLD_LAZY);
    const char *env = getenv("WANAPPLY_PROBE");
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

static void load_chain(void)
{
    /* mib_chain_info_name() memcpy()s sizeof(mib_chain_record_table_entry_T)
     * (~70 bytes) into the buffer; 512 is generous and 8-aligned.            */
    union { struct chain_head h; unsigned char raw[512]; } info;
    char name[64];

    memset(&info, 0, sizeof(info));
    snprintf(name, sizeof(name), "%s", CHAIN_NAME);
    if (!p_info_name(name, &info))
        die(4, "configd does not know chain %s (is configd running?)", CHAIN_NAME);
    if (strncmp(info.h.name, CHAIN_NAME, sizeof(info.h.name)) != 0)
        die(4, "chain lookup returned '%.32s', expected %s", info.h.name, CHAIN_NAME);
    if (info.h.per_record_size < 64 || info.h.per_record_size > 65536)
        die(4, "implausible %s record size %d", CHAIN_NAME, info.h.per_record_size);
    chain_id = info.h.id;
    rec_size = info.h.per_record_size;
}

/* Read ATM_VC_TBL.<idx> into a zeroed, padded buffer.  ifIndex is the first
 * member of struct atmvc_entry (mib.h), a host-endian unsigned int.         */
static void *fetch(unsigned int idx, unsigned int *ifindex_out)
{
    int total = p_total(chain_id);
    void *buf;

    if (total < 0 || idx >= (unsigned int)total)
        die(5, "%s.%u does not exist (total %d)", CHAIN_NAME, idx, total);
    buf = calloc(1, (size_t)rec_size + 1024);
    if (!buf)
        die(5, "out of memory");
    if (!p_get(chain_id, idx, buf))
        die(5, "mib_chain_get(%s, %u) failed", CHAIN_NAME, idx);
    memcpy(ifindex_out, buf, sizeof(*ifindex_out));
    return buf;
}

static void run_firewall(void)
{
    pid_t pid;

    if (access(FIREWALL_PROG, X_OK) != 0) {
        fprintf(stderr, "wanapply: %s not found, skipping\n", FIREWALL_PROG);
        return;
    }
    pid = fork();
    if (pid == 0) {
        execl(FIREWALL_PROG, "firewall.sh", (char *)NULL);
        _exit(127);
    }
    if (pid > 0)
        waitpid(pid, NULL, 0);
}

static int take_lock(void)
{
    int fd = open(LOCK_PATH, O_RDWR | O_CREAT, 0600);
    if (fd < 0)
        return 0;                       /* no lock is better than no WAN edit */
    if (flock(fd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK)
        die(75, "another wanapply is already running");
    return fd;                          /* held until exit */
}

int main(int argc, char **argv)
{
    const char *cmd;
    unsigned int idx = 0, got, expect = 0;
    int have_expect = 0, no_fw = 0, need_idx, i;
    void *rec;

    if (argc < 2)
        die(2, "usage: wanapply check|info|stop|start|refresh|all|delete [idx] [options]");
    cmd = argv[1];
    need_idx = !strcmp(cmd, "info") || !strcmp(cmd, "stop") || !strcmp(cmd, "start")
            || !strcmp(cmd, "delete");

    i = 2;
    if (need_idx) {
        char *end;
        if (argc < 3)
            die(2, "%s needs a record index", cmd);
        idx = (unsigned int)strtoul(argv[2], &end, 10);
        if (*argv[2] == '\0' || *end != '\0')
            die(2, "bad index '%s'", argv[2]);
        i = 3;
    }
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "--no-firewall")) {
            no_fw = 1;
        } else if (!strcmp(argv[i], "--expect-ifindex") && i + 1 < argc) {
            expect = (unsigned int)strtoul(argv[++i], NULL, 0);
            have_expect = 1;
        } else {
            die(2, "unknown argument '%s'", argv[i]);
        }
    }

    load_libmib();
    load_chain();

    if (!strcmp(cmd, "check")) {
        printf("ok chain=%s id=%d record_size=%d total=%d\n",
               CHAIN_NAME, chain_id, rec_size, p_total(chain_id));
        if (strict_err[0])
            printf("warn: strict bind failed, using lazy bind like boa/cli: %s\n",
                   strict_err);
        report_deps();
        return 0;
    }

    if (!strcmp(cmd, "info")) {
        rec = fetch(idx, &got);
        printf("ok idx=%u ifIndex=%u\n", idx, got);
        free(rec);
        return 0;
    }

    take_lock();

    if (!strcmp(cmd, "stop") || !strcmp(cmd, "start")) {
        rec = fetch(idx, &got);
        if (have_expect && got != expect)
            die(6, "%s.%u has ifIndex %u, expected %u — refusing", CHAIN_NAME, idx, got, expect);
        if (!strcmp(cmd, "stop")) {
            p_delconn(CONFIGONE, rec);
        } else {
            p_restart(CONFIGONE, rec);
            if (!no_fw)
                run_firewall();
        }
        printf("ok %s idx=%u ifIndex=%u\n", cmd, idx, got);
        free(rec);
        return 0;
    }

    if (!strcmp(cmd, "refresh")) {
        p_restart(CONFIGONE, NULL);
        if (!no_fw)
            run_firewall();
        printf("ok refresh\n");
        return 0;
    }

    if (!strcmp(cmd, "all")) {
        p_restart(CONFIGALL, NULL);
        if (!no_fw)
            run_firewall();
        printf("ok all\n");
        return 0;
    }

    /* Full remove: tear down live state, drop the MIB row, refresh residual
     * WAN state.  Order matches boa's checkAction(action==0) in fmwan.c:
     *   deleteConnection → mib_chain_delete → restartWAN(CONFIGONE, NULL)
     * resolveServiceDependency() is not exported; callers that care about
     * port-forwards / DNS-bind-PVC must clean those up themselves. */
    if (!strcmp(cmd, "delete")) {
        rec = fetch(idx, &got);
        if (have_expect && got != expect)
            die(6, "%s.%u has ifIndex %u, expected %u — refusing",
                CHAIN_NAME, idx, got, expect);
        p_delconn(CONFIGONE, rec);
        free(rec);
        if (p_chain_del(chain_id, idx) != 1)
            die(7, "mib_chain_delete(%s, %u) failed", CHAIN_NAME, idx);
        p_restart(CONFIGONE, NULL);
        if (!no_fw)
            run_firewall();
        printf("ok delete idx=%u ifIndex=%u\n", idx, got);
        return 0;
    }

    die(2, "unknown command '%s'", cmd);
}
