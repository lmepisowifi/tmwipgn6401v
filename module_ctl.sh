#!/bin/sh
# ============================================================
# module_ctl.sh — www2 module manager for lmepisowifi
# RTL9607C ONT | /lmepisowifi = ubifs (rw)
#
# Makes optional features installable + uninstallable from GitHub WITHOUT
# changing how the base OTA (ota.sh) works. Known modules:
#   hotspot    — the whole Hotspot / Piso-Wifi subsystem (ships in the base;
#                auto-marked "installed" on existing devices via migration).
#   tailscale  — Tailscale VPN (NOT in the base; never auto-installed — old
#                devices start out without it and opt in from the Modules page).
#
#   module_ctl.sh list                 # JSON: available modules + install state
#   module_ctl.sh status <id>          # JSON for one module
#   module_ctl.sh is-active <id>       # exit 0 if installed (for startup.sh)
#   module_ctl.sh install <id> [ver]   # download+verify+lay down+post-install
#   module_ctl.sh uninstall <id>       # stop+remove program files (keep data)
#   module_ctl.sh reconcile            # enforce saved state (boot + post-OTA)
#
# State (device-local, gitignored, never in any release payload, survives OTA):
#   /lmepisowifi/modules/<id>.state         -> "installed" | "uninstalled"
#   /lmepisowifi/modules/<id>.version       -> installed module version
#   /lmepisowifi/hotspot_data/<id>.assets/  -> preserved portal images/favicon/
#                                              audio (hotspot), restored on reinstall
#
# Uninstall keeps operator data: hotspot keeps hotspot_data/ (now including the
# preserved portal images/favicon/audio above) + globals.env settings; tailscale
# keeps everything under /config/ (state + config).
# ============================================================

ROOT="/lmepisowifi"
BB="busybox"
MODDIR="$ROOT/modules"
GLOBALS="$ROOT/globals.env"
ENV_FILE="$ROOT/ota.env"
DL="/tmp/module_dl"
LOG="/tmp/module_ctl.log"
TS_CTL="$ROOT/tailscale/tailscale_ctl.sh"

MODULES="hotspot tailscale"

OTA_REPO="lmepisowifi/tmwipgn6401v"
OTA_BRANCH="main"
OTA_MANIFEST_URL=""
OTA_CACERT="$ROOT/cacert.pem"
MOD_AUTO_UPDATE="1"            # default on; ota.env may set "0" to disable
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

mkdir -p "$MODDIR" 2>/dev/null
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }
json_esc() { printf '%s' "$1" | $BB sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ── Per-module definitions ──────────────────────────────────────────────────
# Files each module owns (relative to $ROOT). Operator data/config is NOT here.
hotspot_files() {
    cat <<'EOF'
hotspot
lmehspt.sh
www2/cgi-bin/hotspot.cgi
www2/hotspot.html
www2/hotspot-ifaces.html
www2/hotspot-dhcp.html
www2/hotspot-income.html
www2/hotspot-portal.html
www2/hotspot-rates.html
www2/hotspot-nodemcus.html
www2/hotspot-sessions.html
www2/hotspot-vouchers.html
www2/hotspot-whitelist.html
www2/hotspot_old.html
EOF
}
tailscale_files() {
    cat <<'EOF'
tailscale
www2/tailscale.html
www2/cgi-bin/tailscale.cgi
EOF
}
module_files() { case "$1" in hotspot) hotspot_files ;; tailscale) tailscale_files ;; esac }
module_name()  { case "$1" in hotspot) echo "Hotspot / Piso-Wifi" ;; tailscale) echo "Tailscale VPN" ;; *) echo "$1" ;; esac }

# A file that must exist in a valid payload / on a present install.
module_sentinel() { case "$1" in hotspot) echo "lmehspt.sh" ;; tailscale) echo "tailscale/tailscaled-small" ;; esac }
files_present()   { [ -e "$ROOT/$(module_sentinel "$1")" ] || { [ "$1" = hotspot ] && [ -d "$ROOT/hotspot" ]; }; }

# Should a device with NO saved state be auto-marked installed on first boot?
# hotspot: yes when the built-in files are present (don't break old devices).
# tailscale: NEVER — old devices didn't ship it, so it must be opted into.
migrate_installed() { case "$1" in hotspot) files_present hotspot ;; *) return 1 ;; esac; }

# ── Registry (modules.txt) ──────────────────────────────────────────────────
modules_url() {
    if [ -n "$OTA_MANIFEST_URL" ]; then
        echo "$OTA_MANIFEST_URL" | $BB sed 's#/manifest\.txt#/modules.txt#'
    else
        echo "https://cdn.jsdelivr.net/gh/${OTA_REPO}@${OTA_BRANCH}/modules.txt"
    fi
}
cdnify() {
    case "$1" in
        https://raw.githubusercontent.com/*)
            _rest=${1#https://raw.githubusercontent.com/}
            _o=$(echo "$_rest" | cut -d/ -f1); _r=$(echo "$_rest" | cut -d/ -f2)
            _ref=$(echo "$_rest" | cut -d/ -f3); _p=$(echo "$_rest" | cut -d/ -f4-)
            [ -n "$_o$_r$_ref$_p" ] && echo "https://cdn.jsdelivr.net/gh/${_o}/${_r}@${_ref}/${_p}" || echo "$1" ;;
        *) echo "$1" ;;
    esac
}
fetch() {
    _u=$(cdnify "$1")
    _wf="--https-only -t 3 -T 30 --retry-connrefused -U lmepisowifi-modctl"
    if [ -f "$OTA_CACERT" ]; then _wf="$_wf --ca-certificate=$OTA_CACERT"; else _wf="$_wf --no-check-certificate"; fi
    wget $_wf -q -O "$2" "$_u"
}
# fetch_large — for module tarballs on slow connections. Uses a 5-minute
# read timeout (-T 300) so a large download that would exceed the 30-second
# chunk window in fetch() doesn't produce a partial file that then fails the
# sha256 check with a misleading "checksum_mismatch" error. -c resumes from
# an existing partial file at $2 (a no-op if $2 doesn't exist yet), which is
# what lets fetch_large_retry() below continue a stalled download instead of
# restarting it from byte 0.
fetch_large() {
    _u=$(cdnify "$1")
    _wf="--https-only -c -t 2 -T 300 --retry-connrefused -U lmepisowifi-modctl"
    if [ -f "$OTA_CACERT" ]; then _wf="$_wf --ca-certificate=$OTA_CACERT"; else _wf="$_wf --no-check-certificate"; fi
    wget $_wf -q -O "$2" "$_u"
}
# fetch_large already retries transient hiccups WITHIN one connection attempt
# (-t 2 above). This retries across whole DROPPED connections — a link that
# stalls or resets for longer than that isn't rare on a weak wifi link to the
# ONT or a mobile hotspot, and previously a single such drop anywhere in the
# transfer meant giving up outright ("download_failed"), which is where most
# reports of a failed install on a bad connection came from. Three attempts
# with a short backoff, resuming via fetch_large's -c instead of paying for
# the download again from the start each time, gives a flaky link a real
# chance. This runs inside the background job modules.cgi already forks for
# install, so nothing client-side is left waiting on it.
fetch_large_retry() { # fetch_large_retry <url> <out>
    _flu="$1"; _flo="$2"; _fln=1; _flmax=3
    while [ "$_fln" -le "$_flmax" ]; do
        if [ "$_fln" -eq 1 ]; then set_mod_status "downloading"; else set_mod_status "download_retry_$((_fln - 1))"; fi
        fetch_large "$_flu" "$_flo" && return 0
        [ "$_fln" -eq "$_flmax" ] && break
        log "fetch_large_retry: attempt $_fln failed (connection dropped or stalled) — retrying"
        sleep $((_fln * 5))
        _fln=$((_fln + 1))
    done
    rm -f "$_flo" 2>/dev/null
    return 1
}
# set_mod_status — write a granular phase label to the per-module status file
# that modules.cgi set via the MOD_STATUS_FILE environment variable. No-op
# when MOD_STATUS_FILE is not set (e.g. when called from the CLI directly).
set_mod_status() { [ -n "$MOD_STATUS_FILE" ] && printf '%s' "$1" > "$MOD_STATUS_FILE" 2>/dev/null; }
reg_field() { # reg_field <file> <id> <key>
    $BB awk -v want="$2" -v key="$3" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { cur=""; next }
        { eq=index($0,"="); if(!eq) next; k=substr($0,1,eq-1); v=substr($0,eq+1);
          gsub(/^[ \t]+|[ \t]+$/,"",k); }
        k=="id" { cur=v }
        cur==want && k==key { print v; exit }
    ' "$1"
}

# ── State helpers ───────────────────────────────────────────────────────────
state_of()   { [ -f "$MODDIR/$1.state" ] && $BB tr -d ' \t\r\n' < "$MODDIR/$1.state" || echo ""; }
version_of() { [ -f "$MODDIR/$1.version" ] && $BB tr -d ' \t\r\n' < "$MODDIR/$1.version" || echo ""; }
set_state()  { printf '%s\n' "$2" > "$MODDIR/$1.state"; sync; }
set_version(){ printf '%s\n' "$2" > "$MODDIR/$1.version"; sync; }

# ── Install lock ─────────────────────────────────────────────────────────────
# Stops two installs of the SAME module from running at once — an impatient
# extra click on Install, two browser tabs open to the Modules page, or the
# 6-hour auto_update cron firing while someone is also installing that module
# by hand all used to race on the same $DL/stage and $ROOT, occasionally
# leaving the per-module result file empty when both tried to write it at the
# same moment (surfaced to the user as a bare "unknown_error"). mkdir is
# atomic on the underlying filesystem, so "did I just create this directory"
# is a safe test-and-set without needing a separate lockfile utility (flock
# isn't guaranteed to exist in a minimal BusyBox build). The pid inside lets a
# later caller tell a genuinely-still-running install apart from a stale lock
# left behind by one that was killed (SIGKILL, reboot, OOM) before it got a
# chance to clean up after itself — see install_lock_live().
lock_dir_for() { echo "$MODDIR/$1.installing"; }
install_lock_live() { # install_lock_live <id> — exit 0 iff a live process holds the lock
    _lld=$(lock_dir_for "$1")
    [ -d "$_lld" ] || return 1
    _llp=$($BB tr -d ' \t\r\n' < "$_lld/pid" 2>/dev/null)
    [ -n "$_llp" ] && kill -0 "$_llp" 2>/dev/null
}
acquire_install_lock() { # acquire_install_lock <id> — return 0 if acquired, 1 if held by a live process
    _lid="$1"; _ld=$(lock_dir_for "$_lid")
    if mkdir "$_ld" 2>/dev/null; then
        echo "$$" > "$_ld/pid" 2>/dev/null
        return 0
    fi
    install_lock_live "$_lid" && return 1
    # Lock dir exists but its owner is gone — stale, left by an install that
    # never got to clean up after itself. Reclaim it.
    rm -rf "$_ld" 2>/dev/null
    mkdir "$_ld" 2>/dev/null && { echo "$$" > "$_ld/pid" 2>/dev/null; return 0; }
    return 1
}
release_install_lock() { rm -rf "$(lock_dir_for "$1")" 2>/dev/null; }

set_global() {
    [ -f "$GLOBALS" ] || : > "$GLOBALS"
    if $BB grep -q "^$1=" "$GLOBALS" 2>/dev/null; then
        $BB sed -i "s|^$1=.*|$1=\"$2\"|" "$GLOBALS"
    else
        printf '%s="%s"\n' "$1" "$2" >> "$GLOBALS"
    fi
    sync
}

# ── hotspot lifecycle (unchanged behavior) ─────────────────────────────────
hotspot_stop() {
    [ -f /tmp/hotspot_watchdog.pid ] && { kill -9 "$(cat /tmp/hotspot_watchdog.pid)" 2>/dev/null; rm -f /tmp/hotspot_watchdog.pid; }
    [ -f /tmp/hotspot_dhcp.pid ] && { kill -9 "$(cat /tmp/hotspot_dhcp.pid)" 2>/dev/null; rm -f /tmp/hotspot_dhcp.pid; }
    for _pid in $($BB ps | $BB grep httpd | $BB grep -v grep | $BB grep -F "hotspot/httpd.conf" | $BB awk '{print $1}'); do
        kill -9 "$_pid" 2>/dev/null
    done
    rm -f /tmp/coin_enabled 2>/dev/null
}
hotspot_start() {
    [ -x "$ROOT/lmehspt.sh" ] || chmod +x "$ROOT/lmehspt.sh" 2>/dev/null
    [ -f "$ROOT/lmehspt.sh" ] && "$ROOT/lmehspt.sh" >/dev/null 2>&1 &
}
preserve_assets() {
    # Only a genuinely-installed instance can hold real, live customization
    # worth capturing. If $1's saved state isn't "installed" right now,
    # whatever's sitting in hotspot/img got there some other way — most
    # often a base OTA re-laying the hotspot component while the module is
    # uninstalled (see do_reconcile's cleanup branch below), which ships its
    # own generic default images, not anything an operator uploaded. The
    # same is true if this fires from do_install() on a fresh/reinstall
    # (state not yet "installed" at that point) rather than an in-place
    # upgrade of a live module. Snapshotting in either case would overwrite
    # the last real snapshot with junk (or emptiness), so leave the existing
    # snapshot untouched whenever there's no live install to take it from.
    [ "$(state_of "$1")" = "installed" ] || return 0
    _a="$ROOT/hotspot_data/$1.assets"
    rm -rf "$_a"; mkdir -p "$_a/img" "$_a/audio"
    if [ -d "$ROOT/hotspot/img" ]; then
        for f in "$ROOT"/hotspot/img/promo[1-5].* "$ROOT"/hotspot/img/portal_logo.* "$ROOT/hotspot/img/favicon.ico"; do
            [ -e "$f" ] && cp -a "$f" "$_a/img/" 2>/dev/null
        done
    fi
    [ -d "$ROOT/hotspot/audio" ] && cp -a "$ROOT"/hotspot/audio/* "$_a/audio/" 2>/dev/null
    sync
}
restore_assets() {
    _a="$ROOT/hotspot_data/$1.assets"
    # One-time migration: devices that uninstalled before this moved from
    # modules/<id>.assets/ into hotspot_data/ still have their preserved
    # files at the old path — bring them along instead of losing them.
    if [ ! -d "$_a" ] && [ -d "$MODDIR/$1.assets" ]; then
        mkdir -p "$ROOT/hotspot_data"
        mv "$MODDIR/$1.assets" "$_a" 2>/dev/null
    fi
    [ -d "$_a" ] || return 0
    [ -d "$_a/img" ]   && { mkdir -p "$ROOT/hotspot/img";   cp -a "$_a/img/"* "$ROOT/hotspot/img/" 2>/dev/null; }
    [ -d "$_a/audio" ] && { mkdir -p "$ROOT/hotspot/audio"; cp -a "$_a/audio/"* "$ROOT/hotspot/audio/" 2>/dev/null; }
    sync
}

# ── Generic per-module hooks ────────────────────────────────────────────────
mod_postinstall() {
    case "$1" in
        hotspot)   set_global HOTSPOT_ENABLED 1; hotspot_start ;;
        tailscale) [ -x "$TS_CTL" ] || chmod +x "$TS_CTL" 2>/dev/null
                   [ -x "$TS_CTL" ] && "$TS_CTL" postinstall >/dev/null 2>&1 ;;
    esac
}
mod_prestop() {   # stop services + rescue data BEFORE files are removed
    case "$1" in
        hotspot)   hotspot_stop; preserve_assets hotspot ;;
        tailscale) [ -x "$TS_CTL" ] && "$TS_CTL" preuninstall >/dev/null 2>&1 ;;
    esac
}
mod_postremove() {
    case "$1" in
        hotspot)   set_global HOTSPOT_ENABLED 0 ;;
        tailscale) : ;;   # /config state + config are intentionally preserved
    esac
}

remove_files() {
    module_files "$1" | while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in ""|hotspot_data|globals.env|config|.|..|/*|*..*) continue ;; esac
        rm -rf "$ROOT/$rel" 2>/dev/null
    done
    sync
}

# ============================================================
# reconcile — enforce the saved state for every module. Safe on every boot
# and after every base OTA. Migrates first-seen devices, and makes an
# uninstall stick (a base OTA that re-lays a module's files gets undone here).
# ============================================================
do_reconcile() {
    for _id in $MODULES; do
        _st=$(state_of "$_id")
        if [ -z "$_st" ]; then
            if migrate_installed "$_id"; then
                _st="installed"; set_state "$_id" installed
                [ -f "$ROOT/VERSION" ] && set_version "$_id" "$($BB tr -d ' \t\r\n' < "$ROOT/VERSION")"
                log "reconcile: $_id migrated -> installed"
            else
                _st="uninstalled"; set_state "$_id" uninstalled
                log "reconcile: $_id -> uninstalled (default)"
            fi
        fi
        if [ "$_st" = "uninstalled" ] && files_present "$_id"; then
            log "reconcile: removing $_id files (state=uninstalled)"
            mod_prestop "$_id"
            remove_files "$_id"
            mod_postremove "$_id"
        fi
    done
}

do_install() {
    _id="$1"; _reqver="$2"
    case " $MODULES " in *" $_id "*) : ;; *) echo '{"ok":false,"error":"unknown_module"}'; return 1 ;; esac

    if ! acquire_install_lock "$_id"; then
        log "install: $_id already has an install in progress — refusing to start a second one"
        echo '{"ok":false,"error":"install_in_progress"}'; return 1
    fi

    mkdir -p "$DL"; : > "$LOG"

    set_mod_status "fetching_registry"
    if ! fetch "$(modules_url)" "$DL/modules.txt"; then
        release_install_lock "$_id"; echo '{"ok":false,"error":"registry_fetch_failed"}'; return 1
    fi
    _ver=$(reg_field "$DL/modules.txt" "$_id" version)
    _url=$(reg_field "$DL/modules.txt" "$_id" url)
    _sum=$(reg_field "$DL/modules.txt" "$_id" sha256)
    [ -n "$_reqver" ] && log "install: requested $_reqver, registry has $_ver"
    if [ -z "$_url" ] || [ -z "$_sum" ]; then
        release_install_lock "$_id"; echo '{"ok":false,"error":"registry_incomplete"}'; return 1
    fi
    case "$_url" in
        "https://github.com/$OTA_REPO/releases/download/"*) : ;;
        "https://cdn.jsdelivr.net/gh/$OTA_REPO@"*) : ;;
        *) release_install_lock "$_id"; echo '{"ok":false,"error":"url_outside_repo"}'; return 1 ;;
    esac

    # fetch_large_retry sets its own "downloading"/"download_retry_N" status
    # as it goes — see its definition above for why a single stall no longer
    # means giving up immediately.
    if ! fetch_large_retry "$_url" "$DL/mod.tar.gz"; then
        release_install_lock "$_id"; echo '{"ok":false,"error":"download_failed"}'; return 1
    fi
    set_mod_status "verifying"
    _got=$(sha256sum "$DL/mod.tar.gz" 2>/dev/null | $BB awk '{print $1}')
    if [ -z "$_got" ] || [ "$_got" != "$_sum" ]; then
        rm -f "$DL/mod.tar.gz"
        release_install_lock "$_id"; echo '{"ok":false,"error":"checksum_mismatch"}'; return 1
    fi

    set_mod_status "extracting"
    rm -rf "$DL/stage"; mkdir -p "$DL/stage"
    if ! tar -xzf "$DL/mod.tar.gz" -C "$DL/stage" 2>>"$LOG"; then
        rm -rf "$DL/stage"
        release_install_lock "$_id"; echo '{"ok":false,"error":"extract_failed"}'; return 1
    fi
    _sent=$(module_sentinel "$_id")
    _base="$DL/stage"
    if [ ! -e "$_base/$_sent" ]; then
        _inner=$(find "$DL/stage" -maxdepth 3 -path "*/$_sent" 2>/dev/null | head -1)
        [ -n "$_inner" ] && _base=$(printf '%s' "$_inner" | $BB sed "s#/$_sent\$##")
    fi
    if [ ! -e "$_base/$_sent" ]; then
        rm -rf "$DL/stage"
        release_install_lock "$_id"; echo '{"ok":false,"error":"bad_module_payload"}'; return 1
    fi

    set_mod_status "applying"
    mod_prestop "$_id" 2>/dev/null
    cp -a "$_base/." "$ROOT/" 2>>"$LOG"
    chmod +x "$ROOT"/www2/cgi-bin/* 2>/dev/null
    [ "$_id" = hotspot ]   && { chmod +x "$ROOT/lmehspt.sh" "$ROOT"/hotspot/cgi-bin/*.sh 2>/dev/null; restore_assets hotspot; }
    [ "$_id" = tailscale ] && chmod +x "$ROOT"/tailscale/* 2>/dev/null
    rm -rf "$DL/stage" "$DL/mod.tar.gz"

    set_state "$_id" installed
    set_version "$_id" "${_ver:-unknown}"
    mod_postinstall "$_id"
    release_install_lock "$_id"
    log "install: $_id $_ver installed"
    printf '{"ok":true,"version":"%s"}\n' "$(json_esc "$_ver")"
}

do_uninstall() {
    _id="$1"
    case " $MODULES " in *" $_id "*) : ;; *) echo '{"ok":false,"error":"unknown_module"}'; return 1 ;; esac
    if install_lock_live "$_id"; then
        echo '{"ok":false,"error":"install_in_progress"}'; return 1
    fi
    mod_prestop "$_id"
    remove_files "$_id"
    mod_postremove "$_id"
    set_state "$_id" uninstalled
    rm -f "$MODDIR/$_id.version" 2>/dev/null
    log "uninstall: $_id removed (data/config kept)"
    echo '{"ok":true}'
}

emit_status() { # emit_status <id> [regfile]
    _id="$1"; _reg="$2"
    _st=$(state_of "$_id"); [ -z "$_st" ] && { migrate_installed "$_id" && _st=installed || _st=uninstalled; }
    _inst="false"; [ "$_st" = "installed" ] && _inst="true"
    _iv=$(version_of "$_id"); _av=""; _desc=""
    if [ -n "$_reg" ] && [ -f "$_reg" ]; then
        _av=$(reg_field "$_reg" "$_id" version); _desc=$(reg_field "$_reg" "$_id" description)
    fi
    printf '{"id":"%s","name":"%s","installed":%s,"version":"%s","available":"%s","description":"%s"}' \
        "$(json_esc "$_id")" "$(json_esc "$(module_name "$_id")")" "$_inst" \
        "$(json_esc "$_iv")" "$(json_esc "$_av")" "$(json_esc "$_desc")"
}

do_list() {
    mkdir -p "$DL"; _reg=""
    fetch "$(modules_url)" "$DL/modules.txt" 2>/dev/null && _reg="$DL/modules.txt"
    printf '{"ok":true,"modules":['
    _sep=""
    for _id in $MODULES; do printf '%s' "$_sep"; emit_status "$_id" "$_reg"; _sep=","; done
    printf ']}\n'
}

do_status() {
    mkdir -p "$DL"; _reg=""
    fetch "$(modules_url)" "$DL/modules.txt" 2>/dev/null && _reg="$DL/modules.txt"
    printf '{"ok":true,"module":'; emit_status "$1" "$_reg"; printf '}\n'
}

# ── Module auto-update ──────────────────────────────────────────────────────
# Called by ota.sh do_cron() on every 6-hour tick.  Fetches the registry once
# and installs any module whose registry version differs from the installed one.
# Controlled by MOD_AUTO_UPDATE in ota.env (default "1" = enabled; "0" = off).
do_auto_update() {
    [ "$MOD_AUTO_UPDATE" = "0" ] && { log "auto_update: disabled (MOD_AUTO_UPDATE=0)"; return 0; }
    log "auto_update: checking installed modules"
    mkdir -p "$DL"
    if ! fetch "$(modules_url)" "$DL/modules_au.txt"; then
        log "auto_update: could not fetch registry — skipping"; return 1
    fi
    for _id in $MODULES; do
        [ "$(state_of "$_id")" = "installed" ] || continue
        _iv=$(version_of "$_id")
        _av=$(reg_field "$DL/modules_au.txt" "$_id" version)
        [ -z "$_av" ] && continue
        if [ "$_av" != "$_iv" ]; then
            log "auto_update: updating $_id from ${_iv:-<unknown>} to $_av"
            do_install "$_id" >/dev/null   # silence JSON; log() captures progress
        else
            log "auto_update: $_id already at $_av — nothing to do"
        fi
    done
    rm -f "$DL/modules_au.txt" 2>/dev/null
}

do_get_mod_auto() { [ "$MOD_AUTO_UPDATE" = "0" ] && echo 0 || echo 1; }

do_set_mod_auto() {
    case "$1" in 1) _v=1 ;; *) _v=0 ;; esac
    if [ -f "$ENV_FILE" ] && $BB grep -q '^MOD_AUTO_UPDATE=' "$ENV_FILE" 2>/dev/null; then
        _tmp=$(mktemp /tmp/ota.env.XXXXXX)
        $BB sed "s/^MOD_AUTO_UPDATE=.*/MOD_AUTO_UPDATE=\"$_v\"/" "$ENV_FILE" > "$_tmp" && mv "$_tmp" "$ENV_FILE"
    else
        printf 'MOD_AUTO_UPDATE="%s"\n' "$_v" >> "$ENV_FILE"
    fi
    sync
    echo "$_v"
}

case "$1" in
    reconcile)   do_reconcile ;;
    is-active)   [ "$(state_of "${2:-hotspot}")" = "installed" ] ;;
    install)     do_install   "$2" "$3" ;;
    uninstall)   do_uninstall "$2" ;;
    list)        do_list ;;
    status)      do_status "${2:-hotspot}" ;;
    auto_update) do_auto_update ;;
    get_auto)    do_get_mod_auto ;;
    set_auto)    do_set_mod_auto "$2" ;;
    *) echo "usage: $0 {reconcile|is-active|install|uninstall|list|status|auto_update|get_auto|set_auto} [id]" >&2; exit 2 ;;
esac
