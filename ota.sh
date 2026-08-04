#!/bin/sh
# ============================================================
# ota.sh — GitHub-based OTA updater for lmepisowifi
# RTL9607C ONT | rootfs = squashfs (ro) | /lmepisowifi = ubifs (rw)
# Metadata (manifest + changelog) is fetched through the jsDelivr CDN
# (cdn.jsdelivr.net/gh/...) instead of raw.githubusercontent.com to avoid
# GitHub's raw-file rate limit (HTTP 429). See cdnify()/fetch() below. The
# release tarball itself still comes from GitHub Releases (jsDelivr does not
# serve release binaries) and its sha256 is always verified.
#
# This is a FILE-SYNC OTA (not a firmware flash): it downloads a release
# tarball from GitHub, verifies its sha256, atomically swaps the app trees
# under /lmepisowifi, restarts the portal + admin httpd + hotspot watchdog,
# health-checks them, and auto-rolls-back if anything is unhealthy.
#
# Usage:
#   ota.sh check           # print JSON: current/latest/update_available/notes
#   ota.sh apply [VERSION] # download+verify+swap+restart (VERSION optional = latest)
#   ota.sh rollback        # restore the previous version kept from the last apply
#   ota.sh cron            # scheduled check; notify, and apply if OTA_AUTO=1
#   ota.sh status          # print the current status token
#
# Only uses tools present on the device: wget(GNU), sha256sum, tar, gzip,
# sed, awk, grep, mv, cp, rm, mkdir.
# ============================================================

ROOT="/lmepisowifi"
ENV_FILE="$ROOT/ota.env"
VERSION_FILE="$ROOT/VERSION"
STAGE="$ROOT/.ota_stage"          # MUST be on the same fs as ROOT (ubifs) for atomic mv
BAK_SUFFIX=".ota_old"             # <component>.ota_old kept for rollback
DL="/tmp/ota"                     # downloads live in RAM (ramfs) — no flash wear
LOG="/tmp/ota.log"
STATUS_FILE="/tmp/ota_status"
LOCK="/tmp/ota.lock"
BB="busybox"

# Components (top-level items) delivered by a release and swapped wholesale.
# Runtime state (hotspot_data/, globals.env, ota.env) is NOT in the payload,
# so it is never touched. User-customised files that live *inside* a replaced
# component are listed in PRESERVE below and carried across the swap.
# defaults.env is a tracked component: it holds canonical default values and is
# replaced on every update. globals.env (user settings) is NOT a component, so
# it is preserved; lmehspt.sh's seed_globals() merges any new default keys into
# it on boot after the swap.
COMPONENTS="hotspot www2 lmehspt.sh ota.sh defaults.env startup.sh module_ctl.sh"
# NOTE: portal images (hotspot/img/promo1..5.* and portal_logo.*) are NOT
# listed here as fixed paths, because hotspot.cgi lets the admin upload any
# of jpg/jpeg/png/ico/gif/webp per slot — a fixed "promo1.jpg" entry would
# silently fail to match a "promo1.png" upload. See the glob-based preserve
# step below (preserve_portal_images) instead.
# www2/tailscale.html + www2/cgi-bin/tailscale.cgi: the tailscale MODULE's own
# www2 files. The base bundle deliberately excludes them (see release.yml) so
# a device that never opted into the module doesn't get a Tailscale page it
# can't use — module_ctl.sh install lays them down instead. But "www2" above
# is still swapped wholesale on every base OTA, and the freshly-downloaded
# bundle's www2 never contains these two files, so without preserving them
# here a device that HAS the module installed loses the page + its cgi to
# every base update (nav.js still shows "Tailscale", since that reads the
# module's install state, not these files — hence the page 404ing while the
# nav item stays). reconcile() doesn't catch this either: tailscale's sentinel
# is the daemon binary (tailscale/tailscaled-small), which lives outside www2
# and is untouched by this swap, so reconcile never sees these two as
# missing. On a device that never installed the module, $ROOT/$rel doesn't
# exist, so the preserve loop below is a no-op for both — they only get
# carried forward when they were actually there to begin with.
PRESERVE="www2/data/dashboard_layout.json www2/uploads hotspot/audio www2/tailscale.html www2/cgi-bin/tailscale.cgi"

# ---- config ----------------------------------------------------------------
OTA_REPO=""
OTA_BRANCH="main"
OTA_MANIFEST_URL=""
OTA_CHANGELOG_URL=""
OTA_AUTO="0"
OTA_CACERT="$ROOT/cacert.pem"
OTA_NOTIFY="1"
OTA_NODEMCU="1"                    # 1 = also push firmware to the coin-slot NodeMCU
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

# ---- helpers ---------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }
set_status() { printf '%s' "$1" > "$STATUS_FILE"; }
now_ver() { [ -f "$VERSION_FILE" ] && tr -d ' \t\r\n' < "$VERSION_FILE" || echo "0.0.0"; }

notify() {
    [ "$OTA_NOTIFY" = "1" ] || return 0
    [ -x "$ROOT/hotspot/notify.sh" ] || return 0
    ( "$ROOT/hotspot/notify.sh" "$1" >/dev/null 2>&1 </dev/null & )
}

# ---- one-time repo migration (lmepisowifi/lmepisowifi -> lmepisowifi/tmwim2-2050-g40) ----
# ota.env is device-local and NEVER touched by an update (see its own header),
# so a bare GitHub rename would leave every already-deployed device pointing
# at the old OWNER/REPO forever — OTA_MANIFEST_URL/OTA_CHANGELOG_URL are
# separately hardcoded full URLs there too, not derived from OTA_REPO at
# runtime. This self-heals it the first time a migrated ota.sh runs: rewrite
# all three repo-baked keys in ota.env in place, atomically (same
# mktemp+sed+mv pattern do_set_auto() uses further down). Once OTA_REPO no
# longer matches OLD_REPO this block is a permanent no-op, so it's safe to
# leave in place after the migration is done.
OLD_REPO="lmepisowifi/lmepisowifi"
NEW_REPO="lmepisowifi/tmwim2-2050-g40"
if [ "$OTA_REPO" = "$OLD_REPO" ] && [ -f "$ENV_FILE" ]; then
    _tmp=$(mktemp /tmp/ota.env.XXXXXX)
    sed -e "s#^OTA_REPO=.*#OTA_REPO=\"$NEW_REPO\"#" \
        -e "s#cdn\.jsdelivr\.net/gh/${OLD_REPO}@#cdn.jsdelivr.net/gh/${NEW_REPO}@#g" \
        "$ENV_FILE" > "$_tmp" && mv "$_tmp" "$ENV_FILE"
    . "$ENV_FILE"
    log "migrated ota.env: OTA_REPO $OLD_REPO -> $NEW_REPO"
fi

# JSON string escaper (backslash + double-quote only — enough for our fields).
json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Route GitHub raw-file URLs through the jsDelivr CDN to dodge
# raw.githubusercontent.com's rate limit (HTTP 429). jsDelivr caches raw repo
# files globally and does not rate-limit like GitHub raw does.
#   https://raw.githubusercontent.com/OWNER/REPO/REF/PATH
#     -> https://cdn.jsdelivr.net/gh/OWNER/REPO@REF/PATH
# Only raw.githubusercontent.com is rewritten. Release-asset URLs
# (github.com/.../releases/download/...) are left untouched because jsDelivr's
# /gh/ endpoint does NOT serve GitHub release binaries, and those downloads are
# not subject to the raw rate limit anyway.
cdnify() { # cdnify <url> -> prints CDN url (or the original url unchanged)
    case "$1" in
        https://raw.githubusercontent.com/*)
            _rest=${1#https://raw.githubusercontent.com/}
            _owner=$(echo "$_rest" | cut -d/ -f1)
            _repo=$(echo  "$_rest" | cut -d/ -f2)
            _ref=$(echo   "$_rest" | cut -d/ -f3)
            _path=$(echo  "$_rest" | cut -d/ -f4-)
            if [ -n "$_owner" ] && [ -n "$_repo" ] && [ -n "$_ref" ] && [ -n "$_path" ]; then
                echo "https://cdn.jsdelivr.net/gh/${_owner}/${_repo}@${_ref}/${_path}"
            else
                echo "$1"
            fi
            ;;
        *) echo "$1" ;;
    esac
}

# wget wrapper: HTTPS-only, retries, timeouts, writable -O target, cert handling.
fetch() { # fetch <url> <outfile>
    _u=$(cdnify "$1")
    _wf="--https-only -t 3 -T 30 --retry-connrefused -U lmepisowifi-ota"
    if [ -f "$OTA_CACERT" ]; then
        _wf="$_wf --ca-certificate=$OTA_CACERT"
    else
        _wf="$_wf --no-check-certificate"
    fi
    wget $_wf -q -O "$2" "$_u"
}

# Ensure hotspot/img/favicon.ico exists, fetching the repo's default from
# GitHub (via the same jsDelivr-cdnified raw-file path as the manifest) when
# it's missing. favicon.ico is the default PORTAL_LOGO target (see
# hotspot/cgi-bin/portal_config.sh) and is not part of PRESERVE's glob-rescue
# fallback path, so a device that never had one locally — a fresh install, or
# one whose hotspot.ota_old backup also lacked it — would otherwise be stuck
# without a tab icon / card header logo until an admin uploads one manually.
# Called from self_heal(), so it runs on every apply AND every 6-hour cron
# tick; safe to call anytime since it's a strict no-op once the file exists,
# and any download failure just leaves it missing to retry next tick.
ensure_default_favicon() {
    [ -e "$ROOT/hotspot/img/favicon.ico" ] && return 0
    [ -n "$OTA_REPO" ] || return 0
    _fi_branch="${OTA_BRANCH:-main}"
    _fi_url="https://raw.githubusercontent.com/$OTA_REPO/$_fi_branch/hotspot/img/favicon.ico"
    _fi_tmp="$DL/favicon.ico.tmp"
    mkdir -p "$DL"
    if fetch "$_fi_url" "$_fi_tmp" && [ -s "$_fi_tmp" ]; then
        # Guard against a CDN/GitHub error page (HTML) saved with HTTP 200 —
        # same class of check used for the manifest in do_check(). A real
        # favicon.ico is binary and won't match this text pattern.
        if grep -Eqi '<html|rate.limit|Too Many Requests|404: Not Found' "$_fi_tmp" 2>/dev/null; then
            log "ensure_default_favicon: fetch returned an error page — leaving favicon.ico missing (will retry)"
            rm -f "$_fi_tmp"
            return 1
        fi
        mkdir -p "$ROOT/hotspot/img"
        mv "$_fi_tmp" "$ROOT/hotspot/img/favicon.ico"
        log "ensure_default_favicon: fetched default favicon.ico from GitHub ($OTA_REPO@$_fi_branch)"
        notify "OTA: restored the default portal favicon from GitHub"
        return 0
    fi
    rm -f "$_fi_tmp"
    log "ensure_default_favicon: could not fetch default favicon.ico (will retry next cron tick)"
    return 1
}

# Same class of gap as ensure_default_favicon(), but for module_ctl.sh itself.
# module_ctl.sh is a brand-new top-level component (introduced alongside the
# www2 Modules page) — it has no .ota_old backup to rescue from like the
# startup.sh markers or portal images above, because it never existed in any
# prior release. The OLD ota.sh that ran THIS delivering update doesn't have
# "module_ctl.sh" in its COMPONENTS list yet, so even though the downloaded
# bundle contains it, that old swap loop never lays it down — it's simply
# dropped when $STAGE is cleared. Fetching it directly from GitHub (same
# idiom as the favicon) sidesteps needing another release: called from
# self_heal(), so a device nobody can walk up to heals itself within one
# cron tick, and both the Modules page (modules.cgi hard-requires this file)
# and startup.sh's hotspot-launch gate (STEP 1.5, "is-active hotspot") start
# working again without waiting on a new version.
ensure_module_ctl() {
    [ -x "$ROOT/module_ctl.sh" ] && return 0
    [ -n "$OTA_REPO" ] || return 0
    _mc_branch="${OTA_BRANCH:-main}"
    _mc_url="https://raw.githubusercontent.com/$OTA_REPO/$_mc_branch/module_ctl.sh"
    _mc_tmp="$DL/module_ctl.sh.tmp"
    mkdir -p "$DL"
    if fetch "$_mc_url" "$_mc_tmp" && [ -s "$_mc_tmp" ]; then
        # Same error-page guard as ensure_default_favicon: a shell script this
        # size won't ever legitimately match these patterns.
        if grep -Eqi '<html|rate.limit|Too Many Requests|404: Not Found' "$_mc_tmp" 2>/dev/null; then
            log "ensure_module_ctl: fetch returned an error page — leaving module_ctl.sh missing (will retry)"
            rm -f "$_mc_tmp"
            return 1
        fi
        mv "$_mc_tmp" "$ROOT/module_ctl.sh"
        chmod +x "$ROOT/module_ctl.sh"
        log "ensure_module_ctl: fetched module_ctl.sh from GitHub ($OTA_REPO@$_mc_branch) — a pre-fix OTA run never delivered it"
        notify "OTA: restored module_ctl.sh — a previous update failed to deliver it; the Modules page and hotspot autostart work again"
        # First run on this device: persist install state immediately. list/status
        # already fall back to migrate_installed() on the fly, but reconcile makes
        # it durable right away instead of only for this one request.
        "$ROOT/module_ctl.sh" reconcile >/dev/null 2>&1
        return 0
    fi
    rm -f "$_mc_tmp"
    log "ensure_module_ctl: could not fetch module_ctl.sh (will retry next cron tick)"
    return 1
}

# Same class of gap as ensure_default_favicon()/ensure_module_ctl(), but for
# the tailscale MODULE's own www2 files (www2/tailscale.html +
# www2/cgi-bin/tailscale.cgi). PRESERVE (above) stops a device from losing
# them to any FUTURE base OTA, but that's no help to a device that already
# lost both to an older do_apply() before PRESERVE covered this — and
# there's no .ota_old backup left to rescue from like the startup.sh
# markers or portal images get, because do_apply() rotates those backups
# away on every subsequent run. Reinstalling the module is the only way
# back for a device already in that state, so hand it to module_ctl.sh,
# which already knows how to fetch+verify+lay its files down again. Same
# "heals within one cron tick, no reboot, no visit to the Modules page
# needed" idiom as ensure_module_ctl.
ensure_tailscale_www2() {
    [ -x "$ROOT/module_ctl.sh" ] || return 0
    "$ROOT/module_ctl.sh" is-active tailscale >/dev/null 2>&1 || return 0
    [ -f "$ROOT/www2/tailscale.html" ] && [ -f "$ROOT/www2/cgi-bin/tailscale.cgi" ] && return 0
    log "ensure_tailscale_www2: tailscale installed but www2 page/cgi missing — reinstalling module"
    if "$ROOT/module_ctl.sh" install tailscale >/dev/null 2>&1 && \
       [ -f "$ROOT/www2/tailscale.html" ] && [ -f "$ROOT/www2/cgi-bin/tailscale.cgi" ]; then
        log "ensure_tailscale_www2: restored www2/tailscale.html + cgi-bin/tailscale.cgi"
        notify "OTA: restored the Tailscale page — an earlier update had removed it"
        return 0
    fi
    log "ensure_tailscale_www2: reinstall failed (will retry next cron tick)"
    return 1
}

# parse a key=value line from the manifest (strips CR)
mval() { sed -n "s/^$1=//p" "$DL/manifest.txt" | tr -d '\r' | head -1; }

# strictly-newer compare using dotted numeric fields: ver_gt A B  -> true if A>B
ver_gt() {
    _a="$1"; _b="$2"
    _i=1
    while [ "$_i" -le 4 ]; do
        _x=$(printf '%s' "$_a" | cut -d. -f$_i); _x=${_x:-0}
        _y=$(printf '%s' "$_b" | cut -d. -f$_i); _y=${_y:-0}
        # non-numeric guard
        case "$_x" in ''|*[!0-9]*) _x=0 ;; esac
        case "$_y" in ''|*[!0-9]*) _y=0 ;; esac
        [ "$_x" -gt "$_y" ] && return 0
        [ "$_x" -lt "$_y" ] && return 1
        _i=$((_i+1))
    done
    return 1
}

# ---- check -----------------------------------------------------------------
# Fetches the manifest and prints a JSON object. Returns 0 always (errors are
# reported inside the JSON so the CGI can render them).
do_check() {
    mkdir -p "$DL"
    _cur=$(now_ver)
    if [ -z "$OTA_MANIFEST_URL" ]; then
        printf '{"error":"OTA_MANIFEST_URL not set","current":"%s"}\n' "$(json_esc "$_cur")"
        return 0
    fi
    if ! fetch "$OTA_MANIFEST_URL" "$DL/manifest.txt"; then
        if grep -Eqi 'rate.limit|Too Many Requests|terms.*service' "$DL/manifest.txt" 2>/dev/null; then
            printf '{"error":"update server rate limited - wait a few minutes and try again","current":"%s"}\n' "$(json_esc "$_cur")"
        else
            printf '{"error":"could not reach update server (jsDelivr/GitHub)","current":"%s"}\n' "$(json_esc "$_cur")"
        fi
        return 0
    fi
    # Guard: the CDN/GitHub may return an error body with HTTP 200 (wget exits 0
    # but the file is an error page, not a real manifest).
    if grep -Eqi 'rate.limit|Too Many Requests|terms.*service' "$DL/manifest.txt" 2>/dev/null; then
        printf '{"error":"update server rate limited - wait a few minutes and try again","current":"%s"}\n' "$(json_esc "$_cur")"
        return 0
    fi
    _lat=$(mval version)
    _url=$(mval url)
    _notes=$(mval notes)
    if [ -z "$_lat" ] || [ -z "$_url" ]; then
        printf '{"error":"manifest missing version/url","current":"%s"}\n' "$(json_esc "$_cur")"
        return 0
    fi
    if ver_gt "$_lat" "$_cur"; then _upd=true; else _upd=false; fi
    printf '{"current":"%s","latest":"%s","update_available":%s,"notes":"%s"}\n' \
        "$(json_esc "$_cur")" "$(json_esc "$_lat")" "$_upd" "$(json_esc "$_notes")"
    return 0
}

# Block until a currently-running `ota.sh apply` has fully exited (its lock
# file is gone), or until the safety cap elapses. Only used by the self-
# relaunch at the end of do_apply(): that relaunch starts life while the
# *original* apply is still finishing up (restart_services/health_ok/
# sync_nodemcu/notify), and must not touch $DL/$STAGE — or run a second
# do_apply() — until the original process, and its lock, are completely gone.
_wait_for_unlock() {
    _wfu_i=0
    while [ -f "$LOCK" ] && [ "$_wfu_i" -lt 90 ]; do sleep 1; _wfu_i=$((_wfu_i + 1)); done
}

# ---- apply -----------------------------------------------------------------
do_apply() {
    _want="$1"   # optional explicit version; default = manifest latest

    # single-instance lock
    if ! ( set -C; : > "$LOCK" ) 2>/dev/null; then
        log "another OTA run is in progress — aborting"; return 1
    fi
    trap 'rm -f "$LOCK"' EXIT

    : > "$LOG"
    set_status "checking"
    log "OTA apply started (installed=$(now_ver))"
    mkdir -p "$DL"

    # Rescue anything a pre-fix ota.sh run left stranded in www2.ota_old/
    # hotspot.ota_old before the swap below clears those backups.
    self_heal

    if ! fetch "$OTA_MANIFEST_URL" "$DL/manifest.txt"; then
        set_status "failed"; log "ERROR: cannot fetch manifest"; return 1
    fi
    _lat=$(mval version); _url=$(mval url); _sum=$(mval sha256); _notes=$(mval notes)
    [ -n "$_want" ] && [ "$_want" != "$_lat" ] && {
        log "NOTE: requested $_want but manifest latest is $_lat — installing manifest version"
    }
    if [ -z "$_lat" ] || [ -z "$_url" ] || [ -z "$_sum" ]; then
        set_status "failed"; log "ERROR: manifest incomplete (need version/url/sha256)"; return 1
    fi

    # SECURITY: pin the download to our own repo. Accept both a GitHub Release
    # asset and a jsDelivr-served file from the same repo tree
    # (cdn.jsdelivr.net/gh/OWNER/REPO@...), so tarballs can be moved onto the CDN
    # later without touching this guard. The manifest sha256 is verified below
    # regardless of source, so a tampered download is always rejected.
    case "$_url" in
        "https://github.com/$OTA_REPO/releases/download/"*) : ;;
        "https://cdn.jsdelivr.net/gh/$OTA_REPO@"*) : ;;
        *) set_status "failed"; log "ERROR: refusing url outside repo (Releases or jsDelivr): $_url"; return 1 ;;
    esac

    set_status "downloading"; log "downloading $_lat"
    if ! fetch "$_url" "$DL/bundle.tar.gz"; then
        set_status "failed"; log "ERROR: download failed"; notify "OTA: download of $_lat failed"; return 1
    fi

    set_status "verifying"; log "verifying sha256"
    _got=$(sha256sum "$DL/bundle.tar.gz" 2>/dev/null | awk '{print $1}')
    if [ -z "$_got" ] || [ "$_got" != "$_sum" ]; then
        set_status "failed"
        log "ERROR: sha256 MISMATCH — want=$_sum got=${_got:-<empty>} — discarding download"
        rm -f "$DL/bundle.tar.gz"; notify "OTA: $_lat FAILED checksum (rejected)"; return 1
    fi

    set_status "staging"; log "extracting"
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    if ! tar -xzf "$DL/bundle.tar.gz" -C "$STAGE" 2>>"$LOG"; then
        set_status "failed"; log "ERROR: extract failed"; rm -rf "$STAGE"; return 1
    fi
    # Some tarballs wrap everything in a single top dir — flatten if so.
    if [ ! -f "$STAGE/lmehspt.sh" ]; then
        _inner=$(find "$STAGE" -maxdepth 2 -name lmehspt.sh 2>/dev/null | head -1)
        [ -n "$_inner" ] && STAGE=$(dirname "$_inner")
    fi
    # sanity-check the payload
    if [ ! -f "$STAGE/lmehspt.sh" ] || [ ! -d "$STAGE/www2" ] || [ ! -d "$STAGE/hotspot" ]; then
        set_status "failed"; log "ERROR: bundle missing expected files (lmehspt.sh/www2/hotspot)"
        rm -rf "$STAGE"; return 1
    fi

    # Carry user-customised files (inside replaced components) into the stage.
    log "preserving local customisations"
    for rel in $PRESERVE; do
        if [ -e "$ROOT/$rel" ]; then
            mkdir -p "$STAGE/$(dirname "$rel")"
            # Audio needs slot-aware copying: the bundle ships coin_sound.mp3 and
            # insert_bg_music.mp3 as defaults. A plain cp -a merge leaves the
            # bundle's .mp3 alongside a user-uploaded .ogg, and portal_config.sh
            # checks mp3 first — so the user's custom audio is silently ignored.
            # Fix: for each audio file the user has, remove any same-slot file
            # (regardless of extension) that the bundle already placed in the stage
            # before copying, so only the user's version survives.
            if [ "$rel" = "hotspot/audio" ]; then
                mkdir -p "$STAGE/hotspot/audio"
                for _af in "$ROOT/hotspot/audio"/*; do
                    [ -e "$_af" ] || continue
                    _abase=$(basename "$_af")
                    _aslot="${_abase%.*}"
                    rm -f "$STAGE/hotspot/audio/${_aslot}".* 2>/dev/null
                    cp -a "$_af" "$STAGE/hotspot/audio/" 2>/dev/null
                    log "  preserving audio $_abase"
                done
            else
                cp -a "$ROOT/$rel" "$STAGE/$(dirname "$rel")/" 2>/dev/null
            fi
        fi
    done
    # Portal carousel images (promo1..5.<ext>) and the portal logo
    # (portal_logo.<ext>) can be any of jpg/jpeg/png/ico/gif/webp (see
    # hotspot.cgi action=portal_upload), so preserve them by glob rather
    # than by fixed filename — a fixed "promo1.jpg" entry misses a
    # "promo1.png" upload entirely and it gets replaced by whatever (or
    # nothing) the new release ships in hotspot/img/.
    # favicon.ico is the default PORTAL_LOGO target; include it explicitly
    # so a user-customised favicon survives the hotspot component swap.
    if [ -d "$ROOT/hotspot/img" ]; then
        mkdir -p "$STAGE/hotspot/img"
        for f in "$ROOT"/hotspot/img/promo[1-5].* "$ROOT"/hotspot/img/portal_logo.* "$ROOT/hotspot/img/favicon.ico"; do
            [ -e "$f" ] || continue
            cp -a "$f" "$STAGE/hotspot/img/" 2>/dev/null
            log "  preserving portal image $(basename "$f")"
        done
    fi

    # ---- atomic swap (rename within the same ubifs volume) ----
    set_status "applying"; log "swapping components"
    # clear any stale backups from a previous run
    for c in $COMPONENTS; do rm -rf "$ROOT/$c$BAK_SUFFIX"; done
    _swapped=""
    for c in $COMPONENTS; do
        if [ ! -e "$STAGE/$c" ]; then
            log "  skip $c (not in bundle)"; continue
        fi
        [ -e "$ROOT/$c" ] && mv "$ROOT/$c" "$ROOT/$c$BAK_SUFFIX"
        if mv "$STAGE/$c" "$ROOT/$c"; then
            _swapped="$_swapped $c"; log "  swapped $c"
        else
            log "  ERROR swapping $c — rolling back"
            _do_rollback_set "$_swapped"; set_status "rolledback"; rm -rf "$STAGE"; return 1
        fi
    done
    chmod +x "$ROOT/lmehspt.sh" "$ROOT/ota.sh" "$ROOT/startup.sh" "$ROOT/module_ctl.sh" 2>/dev/null
    chmod +x "$ROOT"/hotspot/cgi-bin/*.sh "$ROOT"/www2/cgi-bin/* "$ROOT"/www2/sh/*.sh 2>/dev/null

    # Restore runtime-persisted WAN-repurpose/reboot-sched/LAN-speed settings
    # into the freshly-swapped www2/sh/startup.sh (see function comment).
    case "$_swapped" in *www2*) merge_startup_markers ;; esac

    # Re-assert module install/uninstall state after the swap: the base bundle
    # always ships the hotspot files, so a device that had the hotspot module
    # UNINSTALLED would otherwise silently get it back on every update. reconcile
    # removes the re-laid hotspot files again (keeping hotspot_data + settings)
    # when the saved state is "uninstalled", and is a no-op when it's installed.
    [ -x "$ROOT/module_ctl.sh" ] && "$ROOT/module_ctl.sh" reconcile >/dev/null 2>&1

    # record new version early so health-checked processes see it
    # (back up the old VERSION so a failed health check can restore it)
    cp -a "$VERSION_FILE" "$ROOT/VERSION$BAK_SUFFIX" 2>/dev/null
    printf '%s\n' "$_lat" > "$VERSION_FILE"

    # ---- restart services ----
    set_status "restarting"; log "restarting services"
    restart_services

    # ---- health check ----
    log "health check"
    if health_ok; then
        rm -rf "$STAGE"
        # Keep the previous version as *.ota_old (and VERSION.ota_old) so the
        # admin can MANUALLY roll back until the next update, which rotates
        # these backups (see "clear any stale backups" above).
        set_status "success"; log "OTA success — now on $_lat (previous version kept for rollback)"
        notify "OTA: updated to $_lat"
        # Coin-slot firmware: version-gated, so a portal-only release that didn't
        # bump nodemcu_version is a no-op here. Never fails the portal OTA.
        sync_nodemcu

        # If THIS apply swapped in a different ota.sh, any new self-heal fixes it
        # carries (like ensure_module_ctl above) ran under the OLD script for
        # this apply's own self_heal call at the top — they don't take effect
        # until ota.sh executes again, normally up to a 6h wait for the next
        # cron tick. Skip the wait: relaunch the just-installed ota.sh's own
        # `cron` path (via _postapply_cron, which waits for this process's lock
        # to clear first) so it self-heals under its own new code right away.
        # Gated on ota.sh actually differing, so a release that doesn't touch
        # ota.sh doesn't do a pointless extra relaunch.
        if [ -f "$ROOT/ota.sh$BAK_SUFFIX" ]; then
            _pac_new=$(sha256sum "$ROOT/ota.sh" 2>/dev/null | awk '{print $1}')
            _pac_old=$(sha256sum "$ROOT/ota.sh$BAK_SUFFIX" 2>/dev/null | awk '{print $1}')
            if [ -n "$_pac_new" ] && [ "$_pac_new" != "$_pac_old" ]; then
                log "ota.sh changed by this update — relaunching it for an immediate post-apply cron tick"
                ( setsid "$ROOT/ota.sh" _postapply_cron >/dev/null 2>&1 & ) 2>/dev/null || \
                    ( "$ROOT/ota.sh" _postapply_cron >/dev/null 2>&1 & )
            fi
        fi
        return 0
    fi

    log "health check FAILED — rolling back"
    _do_rollback_set "$_swapped"
    [ -f "$ROOT/VERSION$BAK_SUFFIX" ] && mv "$ROOT/VERSION$BAK_SUFFIX" "$VERSION_FILE"
    restart_services
    set_status "rolledback"; log "rolled back after failed health check"
    notify "OTA: $_lat unhealthy — rolled back"
    return 1
}

# Carry forward the runtime-populated marker sections of
# www2/sh/startup.sh across a www2 component swap.
#
# www2/sh/startup.sh ships as part of the "www2" component and gets
# wholesale replaced on every OTA — but three of its sections are not
# static boilerplate, they're rewritten at runtime by the admin CGIs
# whenever the user changes a setting:
#   BEGIN_LAN_SPEEDS    (lme.cgi: per-port link speed persistence)
#   BEGIN_REBOOT_SCHED   (lme.cgi: scheduled auto-reboot)
#   BEGIN_WAN_REPURPOSE  (wan-repurpose.cgi: repurpose LAN/WLAN as WAN)
# Swapping www2 wholesale silently resets all three to empty (their
# shipped default), which is what caused WAN-repurpose (and reboot
# schedule / port speed) to revert to "off" after an update. This runs
# right after the component swap, while the old www2 is still sitting at
# www2.ota_old (this OTA run's own backup) so we can pull the old runtime
# values back out of it and splice them into the freshly-shipped file.
# (BEGIN_IPACL / BEGIN_BANDSTEER_WD are intentionally NOT merged here —
# their content is regenerated boilerplate, not user-set state, and
# should always come from the new release.)
# ---- self-heal: rescue state stranded by a pre-fix ota.sh run -------------
# This function exists to solve a bootstrapping problem: ota.sh is itself
# one of the swapped COMPONENTS, so the update that DELIVERS the preserve/
# merge fix above is still carried out by whatever OLDER (unfixed) ota.sh
# is already on the device — the new logic isn't running yet during that
# specific swap. That old run still leaves the pre-swap www2/hotspot
# sitting untouched in www2.ota_old/hotspot.ota_old, right up until the
# NEXT apply clears stale backups. This rescues from those backups into
# the currently-live tree — filling in only what's blank/missing, never
# overwriting anything already live (whether that's a value the user set
# since, or one an earlier heal pass already restored) — so it's safe to
# call unconditionally and repeatedly. Wired into do_cron (runs every 6h
# regardless of whether a new version is available) and the start of
# do_apply, so a device nobody can walk up to heals itself within one
# cron tick of receiving this fix, with no further release required.
self_heal() {
    _SH_OLD_S="$ROOT/www2$BAK_SUFFIX/sh/startup.sh"
    _SH_NEW_S="$ROOT/www2/sh/startup.sh"
    if [ -f "$_SH_OLD_S" ] && [ -f "$_SH_NEW_S" ]; then
        for _SH_NAME in LAN_SPEEDS REBOOT_SCHED WAN_REPURPOSE; do
            _SH_LIVE_C="/tmp/ota_heal_live_${_SH_NAME}.$$"
            awk -v beg="# --- BEGIN_${_SH_NAME} ---" -v end="# --- END_${_SH_NAME} ---" '
                $0==beg { insec=1; next }
                $0==end { insec=0; next }
                insec   { print }
            ' "$_SH_NEW_S" > "$_SH_LIVE_C"
            # Live already has content for this marker — leave it alone.
            if [ -s "$_SH_LIVE_C" ]; then rm -f "$_SH_LIVE_C"; continue; fi
            rm -f "$_SH_LIVE_C"

            _SH_BAK_C="/tmp/ota_heal_bak_${_SH_NAME}.$$"
            awk -v beg="# --- BEGIN_${_SH_NAME} ---" -v end="# --- END_${_SH_NAME} ---" '
                $0==beg { insec=1; next }
                $0==end { insec=0; next }
                insec   { print }
            ' "$_SH_OLD_S" > "$_SH_BAK_C"
            if [ ! -s "$_SH_BAK_C" ]; then rm -f "$_SH_BAK_C"; continue; fi

            _SH_TMP="/tmp/ota_heal_startup_sh.$$"
            awk -v beg="# --- BEGIN_${_SH_NAME} ---" -v end="# --- END_${_SH_NAME} ---" \
                -v contentfile="$_SH_BAK_C" '
                $0==beg {
                    print; insec=1
                    while ((getline line < contentfile) > 0) print line
                    close(contentfile)
                    next
                }
                $0==end { insec=0; print; next }
                insec   { next }
                { print }
            ' "$_SH_NEW_S" > "$_SH_TMP" && mv "$_SH_TMP" "$_SH_NEW_S"
            rm -f "$_SH_BAK_C"
            chmod 755 "$_SH_NEW_S" 2>/dev/null
            log "self-heal: recovered $_SH_NAME from www2.ota_old (lost by a pre-fix OTA run)"
            notify "OTA: recovered a $_SH_NAME setting a previous update had reset — please double-check it"

            # For WAN_REPURPOSE specifically: if the daemon was absent (device
            # rebooted after the broken apply before self_heal got to run), the
            # fixed startup.sh is now on disk but nothing re-executes it until
            # the next reboot. Parse the interface name from the recovered line
            # and launch repurposeaswan.sh right now so the setting takes effect
            # immediately — no second reboot required.
            # Line format produced by wan-repurpose.cgi:
            #   ( sh /lmepisowifi/www2/sh/repurposeaswan.sh IFACE ) &
            # Fields:  1:(  2:sh  3:/path  4:IFACE  5:)  6:&  → NF-2 = IFACE
            if [ "$_SH_NAME" = "WAN_REPURPOSE" ]; then
                _SH_IFACE=$(awk \
                    -v beg="# --- BEGIN_WAN_REPURPOSE ---" \
                    -v end="# --- END_WAN_REPURPOSE ---" \
                    '$0==beg{s=1;next} $0==end{s=0;next} s && /repurposeaswan\.sh/{print $(NF-2); exit}' \
                    "$_SH_NEW_S" | busybox tr -d '\r\n')
                if [ -n "$_SH_IFACE" ]; then
                    if [ ! -f "/tmp/repurpose_${_SH_IFACE}.pid" ] || \
                       ! kill -0 "$(busybox tr -d '\r\n' < "/tmp/repurpose_${_SH_IFACE}.pid" 2>/dev/null)" 2>/dev/null; then
                        ( sh "$ROOT/www2/sh/repurposeaswan.sh" "$_SH_IFACE" ) &
                        log "self-heal: launched repurposeaswan.sh $_SH_IFACE immediately (was not running after OTA reboot)"
                        notify "OTA: WAN-repurpose on $_SH_IFACE re-started — no reboot needed"
                    else
                        log "self-heal: repurposeaswan.sh $_SH_IFACE already running — startup.sh fix will take effect on next reboot"
                    fi
                fi
            fi
        done
    fi

    _SH_OLD_IMG="$ROOT/hotspot$BAK_SUFFIX/img"
    if [ -d "$_SH_OLD_IMG" ]; then
        mkdir -p "$ROOT/hotspot/img"
        # favicon.ico is the default PORTAL_LOGO target; include it alongside
        # promo images and portal_logo so devices broken by a pre-fix OTA run
        # get their user-customised favicon rescued on the next cron tick.
        for f in "$_SH_OLD_IMG"/promo[1-5].* "$_SH_OLD_IMG"/portal_logo.* "$_SH_OLD_IMG/favicon.ico"; do
            [ -e "$f" ] || continue
            _SH_BASE=$(basename "$f")
            # Only rescue if that exact filename isn't already sitting live —
            # never clobber a file that's already there.
            if [ ! -e "$ROOT/hotspot/img/$_SH_BASE" ]; then
                cp -a "$f" "$ROOT/hotspot/img/" 2>/dev/null
                log "self-heal: recovered hotspot/img/$_SH_BASE from hotspot.ota_old"
                notify "OTA: recovered portal image $_SH_BASE that a previous update had removed"
            fi
        done
    fi

    # Last-resort tier: no local backup existed to rescue favicon.ico from
    # (fresh install, or hotspot.ota_old itself never had one), so pull the
    # canonical default straight from the GitHub repo instead of leaving the
    # portal without a tab icon / PORTAL_LOGO target.
    ensure_default_favicon

    # Same last-resort tier as the favicon: module_ctl.sh has never existed on
    # this device before, so there's no .ota_old copy anywhere to rescue it
    # from — fetch it straight from GitHub instead (see ensure_module_ctl()).
    ensure_module_ctl

    # Repair a device whose tailscale module www2 page/cgi were wiped by an
    # older do_apply() that pre-dates PRESERVE covering them (see PRESERVE
    # above and ensure_tailscale_www2()).
    ensure_tailscale_www2

    # Audio rescue: recover user-uploaded audio stranded in hotspot.ota_old/audio/
    # by a pre-fix OTA run that either lacked hotspot/audio in PRESERVE or had the
    # same-extension-conflict bug. Uses slot-aware logic: a slot (e.g. coin_sound)
    # is only rescued when NO live file for that slot (any extension) currently
    # exists — this safely skips bundle-shipped defaults (coin_sound.mp3,
    # insert_bg_music.mp3) which the swap always places back in hotspot/audio/,
    # while still rescuing user-only slots (e.g. bg_music.*) that the bundle never
    # ships. For bundle-shipped slots the do_apply PRESERVE fix (slot-aware copy)
    # handles future runs correctly; self-heal covers the gap for the transition.
    _SH_OLD_AUD="$ROOT/hotspot$BAK_SUFFIX/audio"
    if [ -d "$_SH_OLD_AUD" ]; then
        mkdir -p "$ROOT/hotspot/audio"
        for f in "$_SH_OLD_AUD"/*; do
            [ -e "$f" ] || continue
            _SH_AUD_BASE=$(basename "$f")
            _SH_AUD_SLOT="${_SH_AUD_BASE%.*}"
            # Check whether any live file for this slot (any extension) exists
            _SH_AUD_LIVE=0
            for _l in "$ROOT/hotspot/audio/${_SH_AUD_SLOT}".*; do
                [ -e "$_l" ] && _SH_AUD_LIVE=1 && break
            done
            if [ "$_SH_AUD_LIVE" -eq 0 ]; then
                cp -a "$f" "$ROOT/hotspot/audio/" 2>/dev/null
                log "self-heal: recovered hotspot/audio/$_SH_AUD_BASE from hotspot.ota_old"
                notify "OTA: recovered portal audio $_SH_AUD_BASE that a previous update had removed"
            fi
        done
    fi

    # Patch older startup.sh files (pre-STEP-1.5b) to add the power-outage coin
    # session replay block. startup.sh is now a managed OTA component, so future
    # releases swap it wholesale, but this bridges the bootstrapping window: the
    # OLD ota.sh that delivers THIS ota.sh doesn't know about startup.sh yet, so
    # the first OTA won't swap it. The SECOND run (6h cron with the new ota.sh)
    # patches it in-place via heal_main_startup instead.
    heal_main_startup
}

# ---------------------------------------------------------------------------
# heal_main_startup — inject the STEP 1.5b power-outage coin-session-replay
# block into /lmepisowifi/startup.sh if it is absent (older devices that
# pre-date startup.sh becoming a managed OTA component).
#
# Detection:  COIN_PENDING_DIR= is unique to STEP 1.5b; its absence means
#             the block has never been added.
# Anchor:     "# --- STEP 1.6:" marks the start of the crond section, which
#             exists on every startup.sh since the original release.
# Strategy:   split the file at the STEP 1.6 anchor with awk, inject the
#             patch block in the gap, then stitch back together atomically.
# ---------------------------------------------------------------------------
heal_main_startup() {
    _HMS_FILE="$ROOT/startup.sh"
    [ -f "$_HMS_FILE" ] || return 0
    grep -q 'COIN_PENDING_DIR=' "$_HMS_FILE" && return 0   # already patched
    grep -q '# --- STEP 1\.6:' "$_HMS_FILE" || return 0    # unrecognised format

    _HMS_PATCH="/tmp/ota_heal_startup_patch.$$"
    _HMS_TMP="/tmp/ota_heal_startup.$$"

    # Write the STEP 1.5b block verbatim.  The heredoc label is single-quoted so
    # shell variables inside ($COIN_PENDING_DIR etc.) are NOT expanded here — they
    # must appear as literal text in the generated startup.sh.
    cat > "$_HMS_PATCH" << '__COIN_REPLAY_EOF__'
    # --- STEP 1.5b: Replay power-outage coin sessions ---
    # A Piso-Wifi unit and its coin slot share a power brick, so a blackout kills
    # both mid-session. The NodeMCU is now stateless (it no longer wears out its
    # flash mirroring coins), so the router owns crash recovery: coin.sh mirrors
    # each PSK-verified poll total to the non-volatile partition below (since
    # /tmp is tmpfs and dies in a blackout). On boot we grant the customer the
    # time they already paid for by re-running coin_result.sh's exact grant logic
    # locally, then drop the mirror. Backgrounded so it can wait for lmehspt.sh
    # to (re)publish /tmp/coin_config.env — which holds COIN_PSK, needed to sign
    # the grant — after that script's boot-time wipe of /tmp/coin_sessions.
    (
        COIN_PENDING_DIR="/lmepisowifi/hotspot_data/coin_pending"
        [ -d "$COIN_PENDING_DIR" ] || exit 0

        # Wait (up to ~90s) for lmehspt.sh to publish the runtime coin config.
        i=0
        while [ ! -f /tmp/coin_config.env ] && [ "$i" -lt 90 ]; do
            sleep 1
            i=$((i + 1))
        done
        [ -f /tmp/coin_config.env ] || exit 0
        . /tmp/coin_config.env
        [ -n "$COIN_PSK" ] || exit 0

        for f in "$COIN_PENDING_DIR"/*; do
            [ -f "$f" ] || continue          # empty dir → literal glob, skip
            case "$f" in *.tmp) continue ;; esac  # skip half-written mirrors

            # Mirror format written by coin.sh: "SID MAC AMOUNT CREATED_AT"
            read -r P_SID P_MAC P_AMOUNT P_CREATED < "$f"

            # Validate the mirrored fields before trusting them; drop junk.
            printf '%s' "$P_SID"    | grep -qE '^[0-9a-f]{16}$'  || { rm -f "$f"; continue; }
            printf '%s' "$P_MAC"    | grep -qE '^[0-9a-f:]{17}$' || { rm -f "$f"; continue; }
            printf '%s' "$P_AMOUNT" | grep -qE '^[0-9]+$'        || { rm -f "$f"; continue; }
            [ "${P_AMOUNT:-0}" -gt 0 ] || { rm -f "$f"; continue; }

            # Sign exactly as the NodeMCU recovery POST did:
            #   sig = md5(PSK:SID:AMOUNT:MAC:recover)
            # coin_result.sh re-verifies this (defense in depth) and clears the
            # mirror itself on a successful/duplicate grant.
            P_SIG=$(printf '%s' "${COIN_PSK}:${P_SID}:${P_AMOUNT}:${P_MAC}:recover" \
                    | md5sum | awk '{print $1}')

            # Reuse coin_result.sh's grant/extend logic via a direct LOCAL exec
            # (not HTTP). REMOTE_ADDR is empty for a local root invocation, which
            # is exactly what its boot-replay guard requires — a network caller
            # can neither blank REMOTE_ADDR nor set COIN_BOOT_REPLAY.
            COIN_BOOT_REPLAY=1 REMOTE_ADDR="" \
            SID="$P_SID" AMOUNT="$P_AMOUNT" SIG="$P_SIG" RECOVER_MAC="$P_MAC" \
                /bin/sh /lmepisowifi/hotspot/cgi-bin/coin_result.sh >/dev/null 2>&1

            # Safety net: if coin_result.sh couldn't clear it (e.g. a transient
            # failure) the mirror stays and is retried on the next boot. A
            # successful grant already removed it, so this is a no-op then.
        done
    ) &

__COIN_REPLAY_EOF__

    # First awk pass: everything BEFORE the STEP 1.6 anchor (exits without
    # printing it, so we can inject the patch in between).
    awk '/# --- STEP 1\.6:/{exit} {print}' "$_HMS_FILE" > "$_HMS_TMP"
    cat "$_HMS_PATCH" >> "$_HMS_TMP"
    # Second awk pass: STEP 1.6 anchor line and everything that follows.
    awk 'found || /# --- STEP 1\.6:/ { found=1; print }' "$_HMS_FILE" >> "$_HMS_TMP"

    rm -f "$_HMS_PATCH"
    mv "$_HMS_TMP" "$_HMS_FILE"
    chmod 755 "$_HMS_FILE" 2>/dev/null
    log "self-heal: injected STEP 1.5b coin-replay block into startup.sh"
    notify "OTA: updated startup.sh to add power-outage coin session recovery (takes effect on next reboot)"
}

merge_startup_markers() {
    _MSM_OLD="$ROOT/www2$BAK_SUFFIX/sh/startup.sh"
    _MSM_NEW="$ROOT/www2/sh/startup.sh"
    [ -f "$_MSM_OLD" ] && [ -f "$_MSM_NEW" ] || return 0

    # Markers whose content is regenerated boilerplate — rebuilt from MIB or
    # other persistent state on every boot, never user-set via a CGI — must
    # always come from the new release, not be carried forward. Everything
    # else discovered below is treated as persisted per-device runtime state.
    _MSM_EXCLUDE="IPACL BANDSTEER_WD OTA_CHECK"

    # A marker line is identified by normalizing away ONLY the decorative
    # characters around it (#, -, space, tab) and requiring what's left to
    # equal the bare marker name exactly — not merely contain it as a
    # substring. This tolerates cosmetic reformatting of the real
    # "# --- BEGIN_X ---" line (dash count, spacing) while refusing to be
    # fooled by a prose comment that happens to mention the marker name in a
    # sentence — e.g. this very file's own "The section between
    # BEGIN_LAN_SPEEDS and END_LAN_SPEEDS is managed automatically..." line.
    # A plain substring match treats that sentence itself as the anchor and
    # swallows everything up to the real marker, deleting the wait_for_iface()
    # helper function in between — found by testing this fix against the
    # actual file rather than a synthetic snippet.
    _msm_marker_found() {
        awk -v want="$1" '
            { t = $0; gsub(/[-# \t]/, "", t); if (t == want) f = 1 }
            END { exit (f ? 0 : 1) }
        ' "$2"
    }

    # Discover every persisted marker actually present on THIS device's own
    # prior startup.sh, instead of relying on a fixed, hand-maintained name
    # list — so a brand-new persisted-state marker a future release adds is
    # carried forward automatically, the same way WAN_REPURPOSE is here,
    # without anyone having to remember to register its name in this
    # function (and in self_heal()'s matching list) by hand.
    _MSM_NAMES=$(awk '
        { t = $0; gsub(/[-# \t]/, "", t); if (t ~ /^BEGIN_/) { sub(/^BEGIN_/, "", t); print t } }
    ' "$_MSM_OLD")

    for _MSM_NAME in $_MSM_NAMES; do
        case " $_MSM_EXCLUDE " in
            *" $_MSM_NAME "*) continue ;;
        esac

        _MSM_BEG="BEGIN_${_MSM_NAME}"
        _MSM_END="END_${_MSM_NAME}"

        # Require both anchors to be present in the freshly-shipped file
        # before touching it at all. These markers are the ONLY way this
        # function addresses a section; if a hand-edit to www2/sh/startup.sh
        # changed the anchor text badly enough that even the normalized
        # match above can't find it, we cannot safely locate that section,
        # let alone edit it. Guessing here is exactly how a live "wlan0-vxd"
        # WAN-repurpose setting could silently turn into whatever the
        # tarball's committed content happened to be: a match that finds no
        # anchor says nothing and just leaves the shipped content in place.
        if ! _msm_marker_found "$_MSM_BEG" "$_MSM_NEW" || ! _msm_marker_found "$_MSM_END" "$_MSM_NEW"; then
            log "  ERROR: $_MSM_NAME markers not found in new www2/sh/startup.sh — leaving this device's $_MSM_NAME setting UNVERIFIED, section left as shipped"
            notify "OTA: could not confirm your $_MSM_NAME setting after the update (startup.sh template changed shape) — please check Admin > System and re-apply if needed"
            continue
        fi

        _MSM_CONTENT="/tmp/ota_marker_${_MSM_NAME}.$$"
        awk -v beg="$_MSM_BEG" -v end="$_MSM_END" '
            function norm(s,   t) { t = s; gsub(/[-# \t]/, "", t); return t }
            { m = norm($0) }
            m==beg { insec=1; next }
            m==end { insec=0; next }
            insec  { print }
        ' "$_MSM_OLD" > "$_MSM_CONTENT"

        # $_MSM_CONTENT now holds this device's OWN prior state for this marker
        # — possibly empty, e.g. WAN-repurpose was never enabled here. Splice it
        # into the freshly-shipped file EITHER WAY, replacing whatever the release
        # tarball's own www2/sh/startup.sh happened to carry in that section. These
        # three markers are pure per-device runtime state; the committed template's
        # own marker content must never leak onto a device that never set it — if
        # the repo's copy is ever hand-edited (or generated from someone's own test
        # unit) with something non-empty checked in, a device with nothing persisted
        # must end up blank here, not silently inherit it. (Skipping the splice when
        # $_MSM_CONTENT was empty is exactly what let a committed
        # "eth0.3.0" WAN-repurpose line leak onto every device that had never
        # touched the feature.)
        _MSM_TMP="/tmp/ota_startup_sh.$$"
        awk -v beg="$_MSM_BEG" -v end="$_MSM_END" -v contentfile="$_MSM_CONTENT" '
            function norm(s,   t) { t = s; gsub(/[-# \t]/, "", t); return t }
            {
                m = norm($0)
                if (m == beg) {
                    print; insec = 1
                    while ((getline line < contentfile) > 0) print line
                    close(contentfile)
                    next
                }
                if (m == end) { insec = 0; print; next }
                if (insec) next
                print
            }
        ' "$_MSM_NEW" > "$_MSM_TMP" && mv "$_MSM_TMP" "$_MSM_NEW"
        if [ -s "$_MSM_CONTENT" ]; then
            log "  carried forward $_MSM_NAME from previous www2/sh/startup.sh"
        else
            log "  cleared $_MSM_NAME (not configured on this device) — ignored shipped template value"
        fi
        rm -f "$_MSM_CONTENT"
    done
    chmod 755 "$_MSM_NEW" 2>/dev/null
}

# restore a specific set of components from their .ota_old backups
_do_rollback_set() {
    for c in $1; do
        if [ -e "$ROOT/$c$BAK_SUFFIX" ]; then
            rm -rf "$ROOT/$c"
            mv "$ROOT/$c$BAK_SUFFIX" "$ROOT/$c"
            log "  restored $c"
        fi
    done
}

# manual rollback entrypoint: restore whatever .ota_old backups still exist
do_rollback() {
    : > "$LOG"; set_status "restarting"; log "manual rollback requested"
    _any=""
    for c in $COMPONENTS; do
        if [ -e "$ROOT/$c$BAK_SUFFIX" ]; then
            rm -rf "$ROOT/$c"; mv "$ROOT/$c$BAK_SUFFIX" "$ROOT/$c"
            _any="$_any $c"; log "  restored $c"
        fi
    done
    if [ -z "$_any" ]; then set_status "failed"; log "no backup to roll back to"; return 1; fi
    [ -f "$ROOT/VERSION.ota_old" ] && mv "$ROOT/VERSION.ota_old" "$VERSION_FILE"
    restart_services
    set_status "success"; log "rollback complete — now on $(now_ver)"
    return 0
}

# ---- restart the portal httpd, admin httpd and hotspot watchdog ----
restart_services() {
    # admin UI (www2) — binds 0.0.0.0:8080
    for pid in $($BB ps w 2>/dev/null | grep "httpd" | grep -v grep | grep -F "/lmepisowifi/www2" | awk '{print $1}'); do
        kill "$pid" 2>/dev/null
    done
    ( setsid $BB httpd -h "$ROOT/www2" -p 8080 >/dev/null 2>&1 & ) 2>/dev/null || \
        ( $BB httpd -h "$ROOT/www2" -p 8080 >/dev/null 2>&1 & )

    # portal + hotspot watchdog + firewall: lmehspt.sh tears down and rebuilds.
    ( setsid sh "$ROOT/lmehspt.sh" --force >/tmp/ota_lmehspt.log 2>&1 & ) 2>/dev/null || \
        ( sh "$ROOT/lmehspt.sh" --force >/tmp/ota_lmehspt.log 2>&1 & )
    sleep 4
}

# ---- health check: admin UI answers and portal httpd is up ----
health_ok() {
    _tries=0
    while [ "$_tries" -lt 10 ]; do
        if wget -q -T 3 -O /dev/null "http://127.0.0.1:8080/login.html" 2>/dev/null; then
            # also confirm a portal httpd process exists (best-effort)
            if $BB ps w 2>/dev/null | grep "httpd" | grep -v grep | grep -qF "/lmepisowifi/hotspot"; then
                return 0
            fi
            return 0
        fi
        sleep 2; _tries=$((_tries+1))
    done
    return 1
}

# ---- scheduled check (cron) ----
do_cron() {
    # Always run self-heal first, even when no update is available.
    # This is what rescues state (WAN-repurpose/images/etc.) stranded
    # in .ota_old backups by the pre-fix ota.sh run that delivered
    # this very script — see self_heal() for the full explanation.
    self_heal

    _json=$(do_check)

    if echo "$_json" | grep -q '"update_available":true'; then
        _lat=$(printf '%s' "$_json" | sed -n 's/.*"latest":"\([^"]*\)".*/\1/p')
        if [ "$OTA_AUTO" = "1" ]; then
            log "cron: auto-updating to $_lat"
            do_apply "$_lat"
            # sync_nodemcu is already called inside do_apply on success; skip here.
        else
            # Notify only ONCE per new version so the 6-hour check doesn't spam.
            _seen_file="$ROOT/hotspot_data/.ota_notified"
            _seen=$(cat "$_seen_file" 2>/dev/null | tr -d ' \t\r\n')
            if [ "$_seen" != "$_lat" ]; then
                log "cron: update $_lat available (auto off) — notifying"
                notify "OTA: version $_lat is available. Open Admin > System > Software Update to install."
                printf '%s' "$_lat" > "$_seen_file" 2>/dev/null
            else
                log "cron: update $_lat available (already notified)"
            fi
            # Portal update is pending manual install; skip NodeMCU push here.
            # The hotspot/firmware/coin_nodemcu.bin on disk is still the old bundle,
            # and the manifest's nodemcu_version refers to the not-yet-applied release.
            # sync_nodemcu() will run after the user hits Apply.
        fi
    else
        log "cron: portal up to date"
        # Even when no portal update is available, the NodeMCU may have missed its
        # firmware push because it was offline (or mid-coin-session) when the last
        # do_apply() called sync_nodemcu(). Re-check every cron tick so a late-coming
        # device catches up without waiting for the next full portal release.
        #
        # do_check() already fetched the manifest into $DL/manifest.txt, so mval()
        # works here at no extra cost. If the fetch failed, mval returns empty and
        # we skip gracefully.
        if [ "$OTA_NODEMCU" = "1" ]; then
            _cron_nver=$(mval nodemcu_version)
            if [ -n "$_cron_nver" ]; then
                log "cron: checking nodemcu firmware (manifest expects $_cron_nver)"
                sync_nodemcu
            else
                log "cron: no nodemcu_version in manifest — skipping nodemcu check"
            fi
        fi
    fi

    # Auto-update installed modules when MOD_AUTO_UPDATE is enabled (default: on).
    # Runs on every cron tick regardless of whether a portal update was applied, so
    # modules stay current even in between portal releases.
    [ -x "$ROOT/module_ctl.sh" ] && "$ROOT/module_ctl.sh" auto_update >> "$LOG" 2>&1
}

# ---- auto-update toggle (persists OTA_AUTO in ota.env) ----
do_get_auto() { [ "$OTA_AUTO" = "1" ] && echo 1 || echo 0; }

do_set_auto() {
    case "$1" in 1) _v=1 ;; *) _v=0 ;; esac
    if [ -f "$ENV_FILE" ] && grep -q '^OTA_AUTO=' "$ENV_FILE"; then
        _tmp=$(mktemp /tmp/ota.env.XXXXXX)
        sed "s/^OTA_AUTO=.*/OTA_AUTO=\"$_v\"/" "$ENV_FILE" > "$_tmp" && mv "$_tmp" "$ENV_FILE"
    else
        printf 'OTA_AUTO="%s"\n' "$_v" >> "$ENV_FILE"
    fi
    echo "$_v"
}

# ---- changelog (raw CHANGELOG.md from the repo) ----
do_changelog() {
    [ -n "$OTA_CHANGELOG_URL" ] || { echo "No changelog configured."; return 0; }
    mkdir -p "$DL"
    if fetch "$OTA_CHANGELOG_URL" "$DL/CHANGELOG.md" && [ -s "$DL/CHANGELOG.md" ]; then
        cat "$DL/CHANGELOG.md"
    else
        echo "Could not fetch changelog."
    fi
}

# ---- coin-slot NodeMCU firmware push -----------------------------------------
# Version-GATED self-flash of the ESP8266 coin controller(s). Called at the end
# of a successful do_apply (and available standalone as `ota.sh nodemcu`).
#
# Why this never reflashes on a portal-only update: we compare each device's
# running FW_VERSION (GET /version) against the release manifest's
# nodemcu_version. A release that only touched www2/hotspot does NOT bump
# nodemcu_version, so running == release and that unit is skipped WITHOUT
# flashing.
#
# The image ships inside the release at hotspot/firmware/coin_nodemcu.bin, so
# after the hotspot swap it is already live and served by the captive httpd
# (busybox httpd -h /lmepisowifi/hotspot -p $PORTAL_PORT) at /firmware/
# coin_nodemcu.bin — the exact host:port every NodeMCU already reaches. Each
# device pulls it itself; we only hand it a signed authorisation.
#
# Auth mirrors wlanbasic.cgi's nm_push() / the firmware's /setwifi flow:
#   GET /version                          → gate
#   GET /nonce                            → single-use nonce
#   GET /update?md5=<hex>&token=<t>        t = md5(psk:nonce:md5:update)
#
# Multi-unit: pushes to every configured, ENABLED NodeMCU — the primary (#1,
# NODEMCU_IP/PORT/COIN_PSK in globals.env) plus any units listed in
# NODEMCU_EXTRA_FILE (ID|TITLE|IP|MAC|PORT|PSK|ENABLED). A unit with an empty
# IP/PSK is just that one unit's config being unset (e.g. the primary was
# deleted, or never configured on a hotspot-only box) — it is skipped
# INDIVIDUALLY rather than aborting the whole sync, so a box with no primary
# but a working #2 unit (or vice versa) still gets serviced.
_nodemcu_push_one() {
    _ph_label="$1"; _ph_ip="$2"; _ph_port="$3"; _ph_psk="$4"; _ph_nver="$5"; _ph_nmd5="$6"
    _ph_base="http://${_ph_ip}:${_ph_port:-8080}"

    # ---- GATE: Try to reach the device with retries (Network might still be settling) ----
    log "nodemcu $_ph_label: checking version at $_ph_base/version"
    _ph_vresp=""
    _ph_attempt=1
    while [ $_ph_attempt -le 3 ]; do
        _ph_vresp=$(wget -q -T 5 -O - "$_ph_base/version" 2>/dev/null)
        [ -n "$_ph_vresp" ] && break
        log "nodemcu $_ph_label: no reply (attempt $_ph_attempt/3), waiting..."
        sleep 10
        _ph_attempt=$((_ph_attempt + 1))
    done

    _ph_running=$(printf '%s' "$_ph_vresp" | sed -n 's/.*"fw":"\([^"]*\)".*/\1/p')

    if [ -z "$_ph_running" ]; then
        if [ -n "$_ph_vresp" ]; then
            log "nodemcu $_ph_label: device replied but version format is invalid: $_ph_vresp"
        else
            log "nodemcu $_ph_label: device at $_ph_ip is unreachable after 3 attempts"
        fi
        return 0
    fi

    if [ "$_ph_running" = "$_ph_nver" ]; then
        log "nodemcu $_ph_label: already on $_ph_running — no flash needed"
        return 0
    fi
    log "nodemcu $_ph_label: running $_ph_running, release ships $_ph_nver — pushing update"

    # ---- signed handshake: nonce → update ----------------------------------
    _ph_nresp=$(wget -q -T 5 -O - "$_ph_base/nonce" 2>/dev/null)
    _ph_nonce=$(printf '%s' "$_ph_nresp" | grep -o '"nonce":"[^"]*"' | awk -F'"' '{print $4}' | head -n1)
    if [ -z "$_ph_nonce" ]; then
        log "nodemcu $_ph_label: no nonce from device — aborting push"; return 1
    fi
    _ph_tok=$(printf '%s' "${_ph_psk}:${_ph_nonce}:${_ph_nmd5}:update" | md5sum | awk '{print $1}')
    _ph_uresp=$(wget -q -T 20 -O - "$_ph_base/update?md5=${_ph_nmd5}&token=${_ph_tok}" 2>/dev/null)
    if printf '%s' "$_ph_uresp" | grep -q '"error":"busy"'; then
        log "nodemcu $_ph_label: coin session active — will retry on next cron/apply"
        return 0
    fi
    if ! printf '%s' "$_ph_uresp" | grep -q '"ok":true'; then
        log "nodemcu $_ph_label: update not accepted (resp=$_ph_uresp)"; return 1
    fi
    log "nodemcu $_ph_label: flash accepted, device downloading; verifying…"

    # ---- verify: device should come back reporting the new version --------
    _ph_i=0
    while [ "$_ph_i" -lt 15 ]; do
        sleep 4
        _ph_rv=$(wget -q -T 4 -O - "$_ph_base/version" 2>/dev/null | sed -n 's/.*"fw":"\([^"]*\)".*/\1/p')
        if [ "$_ph_rv" = "$_ph_nver" ]; then
            log "nodemcu $_ph_label: confirmed running $_ph_nver"
            notify "OTA: coin slot firmware ($_ph_label) updated to $_ph_nver"
            return 0
        fi
        _ph_i=$((_ph_i + 1))
    done
    log "nodemcu $_ph_label: could not confirm $_ph_nver after flash (last=$_ph_rv)"
    return 1
}

sync_nodemcu() {
    [ "$OTA_NODEMCU" = "1" ] || { log "nodemcu: push disabled (OTA_NODEMCU=0)"; return 0; }

    _nver=$(mval nodemcu_version)
    _nmd5=$(mval nodemcu_md5)
    if [ -z "$_nver" ] || [ -z "$_nmd5" ]; then
        log "nodemcu: manifest has no nodemcu_version/nodemcu_md5 — nothing to push"
        return 0
    fi

    # Coin-slot connection details + PSK live in globals.env (user settings).
    NODEMCU_IP=""; NODEMCU_PORT="8080"; COIN_PSK=""; NODEMCU_1_ENABLED="1"
    NODEMCU_EXTRA_FILE="${NODEMCU_EXTRA_FILE:-/lmepisowifi/hotspot_data/nodemcus_extra.txt}"
    [ -f "$ROOT/globals.env" ] && . "$ROOT/globals.env"

    _any=0    # did we find at least one node worth checking (primary or extra)?
    _fail=0   # did any individual push explicitly fail?

    # Primary (#1). Its IP/PSK being empty just means #1 isn't configured
    # (deleted, or never set up on a box that only has extra units) — that's
    # not grounds to skip the extras below.
    if [ -n "$NODEMCU_IP" ] && [ -n "$COIN_PSK" ] && [ "${NODEMCU_1_ENABLED:-1}" = "1" ]; then
        _any=1
        _nodemcu_push_one "#1 (primary)" "$NODEMCU_IP" "${NODEMCU_PORT:-8080}" "$COIN_PSK" "$_nver" "$_nmd5" || _fail=1
    fi

    # Extras (#2+).
    if [ -f "$NODEMCU_EXTRA_FILE" ]; then
        while IFS='|' read -r _nid _ntitle _nip _nmac _nport _npsk _nen; do
            case "$_nid" in ''|*[!0-9]*) continue ;;
            esac
            [ "${_nen:-1}" = "1" ] || continue
            [ -n "$_nip" ] && [ -n "$_npsk" ] || continue
            _any=1
            _nodemcu_push_one "#${_nid} (${_ntitle:-unit $_nid})" "$_nip" "${_nport:-8080}" "$_npsk" "$_nver" "$_nmd5" || _fail=1
        done < "$NODEMCU_EXTRA_FILE"
    fi

    if [ "$_any" = "0" ]; then
        log "nodemcu: NODEMCU_IP/COIN_PSK not set in globals.env and no extra units configured — skipping"
        return 0
    fi

    return $_fail
}

# ---- dispatch ----
case "$1" in
    check)    do_check ;;
    apply)    do_apply "$2" ;;
    rollback) do_rollback ;;
    cron)     do_cron ;;
    # Internal only: do_apply() relaunches a freshly-swapped ota.sh under this
    # verb for an immediate self-heal pass once the apply that installed it has
    # fully exited. Deliberately left out of the usage line below — it's
    # plumbing, not a command an operator needs — but harmless to run by hand:
    # it just waits out any in-progress lock, then does the same thing `cron` does.
    _postapply_cron) _wait_for_unlock; do_cron ;;
    changelog) do_changelog ;;
    get_auto) do_get_auto ;;
    set_auto) do_set_auto "$2" ;;
    nodemcu)  mkdir -p "$DL"; fetch "$OTA_MANIFEST_URL" "$DL/manifest.txt" && sync_nodemcu ;;
    status)   cat "$STATUS_FILE" 2>/dev/null || echo "idle" ;;
    log)      cat "$LOG" 2>/dev/null ;;
    *) echo "usage: $0 {check|apply [version]|rollback|cron|changelog|get_auto|set_auto 0|1|nodemcu|status|log}" ; exit 2 ;;
esac
