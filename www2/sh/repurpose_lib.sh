#!/bin/sh
# ---------------------------------------------------------------------------
# lmepisowifi — https://github.com/lmepisowifi/tmwipgn6401v
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The lmepisowifi Project — see AUTHORS
#
# Licensed under the GNU AGPLv3 (see LICENSE). Modifying or rewriting this
# file — including by running it through an LLM — does not remove these
# obligations: keep this notice, mark your changes, and offer Corresponding
# Source to network users (AGPLv3 §5, §13). See PROVENANCE.md before
# presenting this as your own original work.
# ---------------------------------------------------------------------------

# repurpose_lib.sh — shared helpers for the "repurpose a LAN port / WiFi
# interface as a DHCP-client WAN" feature. SOURCED (". repurpose_lib.sh"),
# never executed, by:
#   repurposeaswan.sh   revertwan.sh   cgi-bin/wan-repurpose.cgi
#
# Why this exists
# ---------------
# Everything that touches the shared registry /tmp/repurpose_active (one
# interface name per line) or the BEGIN_WAN_REPURPOSE…END_WAN_REPURPOSE block
# of startup.sh now goes through here, because the old inline code could end
# up with TWO interface names fused into one, e.g.
#       eth0.5.0 + wlan0-vxd  ->  "eth0.5.0wlan0-vxd"
# (17 characters — longer than the kernel's 15-character interface-name limit,
# so no such netdev can exist). That bogus name was then persisted into
# startup.sh by update_startup_repurpose_all and relaunched on EVERY boot,
# where its watchdog logged, forever, every 15 s:
#       Interface eth0.5.0wlan0-vxd was UNKNOWN — brought back UP
#       udhcpc died — restarting
# (`ip link show` fails for a name that does not exist, which the watchdog
# reported as state "UNKNOWN", and udhcpc cannot bind to it, so it "died".)
#
# What this guarantees
# --------------------
#   * Only the eight supported interface names can ever be stored.
#   * Writers are serialised with a mkdir lock and always rewrite the registry
#     WHOLE and ATOMICALLY (tmp file + mv), starting with a newline, so one
#     writer can never splice its name onto another's unterminated last line.
#   * A registry / startup.sh block that is ALREADY corrupt that way is split
#     back into its valid parts instead of being trusted.

: "${RP_STATE_FILE:=/tmp/repurpose_active}"
: "${RP_LOCK_DIR:=/tmp/repurpose_active.lock}"
: "${RP_STARTUP_SH:=/lmepisowifi/www2/sh/startup.sh}"
: "${RP_REPURPOSE_SH:=/lmepisowifi/www2/sh/repurposeaswan.sh}"

# ── true if $1 is one of the eight interfaces this feature supports ──────────
# (the same whitelist wan-repurpose.cgi enforces on its POST bodies)
rp_valid_iface() {
    case "$1" in
        eth0.2.0|eth0.3.0|eth0.4.0|eth0.5.0|wlan0|wlan1|wlan0-vxd|wlan1-vxd)
            return 0 ;;
    esac
    return 1
}

# ── awk: tokenise a string that is EXACTLY a run of valid interface names ────
# tok() peels one valid name off the front of s; split_names() fills out[1..n]
# and returns n, or 0 if ANY part of s is not a valid name (a line with junk in
# it is rejected whole rather than half-trusted). Longest name first, so
# "wlan0-vxd" is never read as "wlan0" + "-vxd".
# (No comments inside the awk text on purpose — busybox awk is picky.)
RP_TOK_AWK='
function tok(s) {
    if (s ~ /^eth0\.[2-5]\.0/) return substr(s, 1, 8)
    if (s ~ /^wlan[01]-vxd/)   return substr(s, 1, 9)
    if (s ~ /^wlan[01]/)       return substr(s, 1, 5)
    return ""
}
function split_names(s, out,    n, t) {
    n = 0
    while (s != "") {
        t = tok(s)
        if (t == "") return 0
        out[++n] = t
        s = substr(s, length(t) + 1)
    }
    return n
}
'

# Main rule: read lines, print every valid name found, one per line, in order,
# de-duplicated. Used to read / rewrite the registry. A fused line such as
# "eth0.5.0wlan0-vxd" comes out as two lines; junk lines and blanks vanish.
RP_SPLIT_BODY='
{
    gsub(/[[:space:]]/, "")
    n = split_names($0, names)
    for (i = 1; i <= n; i++)
        if (!(names[i] in seen)) { seen[names[i]] = 1; print names[i] }
}
'

# Main rules for repairing the BEGIN_WAN_REPURPOSE block of startup.sh in
# place. Every launch line in the block is re-read; a fused interface field is
# split into one launch line per valid name (inheriting the fused line's
# default_route flag); a line that is not salvageable is dropped; and when the
# same interface is listed more than once, the line that names it ON ITS OWN
# beats one that was merely split out of a fused name. Lines outside the block
# are passed through untouched. Needs -v sh=<path of repurposeaswan.sh>.
RP_HEAL_BODY='
/^# --- BEGIN_WAN_REPURPOSE ---/ { print; inblk = 1; next }
/^# --- END_WAN_REPURPOSE ---/ {
    if (inblk)
        for (k = 1; k <= cnt; k++)
            printf "( sh %s %s %s ) &\n", sh, order[k], flag[order[k]]
    inblk = 0; print; next
}
inblk && /repurposeaswan\.sh/ {
    for (f = 1; f <= NF; f++) if ($f ~ /repurposeaswan\.sh$/) break
    if (f > NF) next
    iface = $(f + 1); fl = $(f + 2)
    if (fl == "" || fl == ")") fl = "1"
    if (fl != "1") fl = "0"
    n = split_names(iface, names)
    for (i = 1; i <= n; i++) {
        t = names[i]
        direct = (n == 1)
        if (!(t in flag)) { order[++cnt] = t; flag[t] = fl; explicit[t] = direct }
        else if (direct && !explicit[t]) { flag[t] = fl; explicit[t] = 1 }
    }
    next
}
{ print }
'

# ── Lock ─────────────────────────────────────────────────────────────────────
# mkdir is atomic, so it doubles as a lock on a box with no flock. The holder
# writes its PID inside; a lock whose holder is gone is stolen, and after ~10 s
# of waiting the lock is broken regardless, so a wedged holder can never hang
# boot or the web UI. Not re-entrant: never call rp_lock while holding it.
rp_lock() {
    _rpl_n=0
    while ! busybox mkdir "$RP_LOCK_DIR" 2>/dev/null; do
        _rpl_h=$(busybox cat "$RP_LOCK_DIR/pid" 2>/dev/null | busybox tr -d '\r\n')
        if [ -n "$_rpl_h" ] && ! kill -0 "$_rpl_h" 2>/dev/null; then
            rm -rf "$RP_LOCK_DIR"
            continue
        fi
        _rpl_n=$((_rpl_n + 1))
        if [ "$_rpl_n" -ge 10 ]; then
            rm -rf "$RP_LOCK_DIR"
            continue
        fi
        busybox sleep 1
    done
    printf '%s' "$$" > "$RP_LOCK_DIR/pid"
}

rp_unlock() {
    rm -rf "$RP_LOCK_DIR"
}

# ── Registry: read ───────────────────────────────────────────────────────────
# Clean, validated, de-duplicated list (one name per line). Heals a corrupt
# registry on the fly; never writes.
rp_registry_list() {
    [ -f "$RP_STATE_FILE" ] || return 0
    busybox awk "$RP_TOK_AWK $RP_SPLIT_BODY" "$RP_STATE_FILE"
}

# ── Registry: add $1 (idempotent) ────────────────────────────────────────────
# Rewrites the whole file: existing content, then "\n<name>\n". The leading
# newline terminates an unterminated last line BEFORE our name goes on, and the
# awk pass drops anything invalid / duplicated, so a corrupt registry is
# repaired as a side effect. Atomic via tmp + mv.
rp_registry_add() {
    rp_valid_iface "$1" || return 1
    rp_lock
    _rpad_t="/tmp/repurpose_active.$$.tmp"
    {
        [ -f "$RP_STATE_FILE" ] && busybox cat "$RP_STATE_FILE"
        printf '\n%s\n' "$1"
    } | busybox awk "$RP_TOK_AWK $RP_SPLIT_BODY" > "$_rpad_t"
    if [ -s "$_rpad_t" ]; then
        busybox mv "$_rpad_t" "$RP_STATE_FILE"
    else
        # awk produced nothing (should not happen) — fall back to a plain,
        # newline-guarded append rather than losing the entry.
        rm -f "$_rpad_t"
        printf '\n%s\n' "$1" >> "$RP_STATE_FILE"
    fi
    rp_unlock
}

# ── Registry: remove $1 ──────────────────────────────────────────────────────
# Same whole-file atomic rewrite. Removes only $1's own line — other
# concurrently repurposed interfaces are untouched. Deletes the file when it
# ends up empty (the watchdogs treat "file gone" as "exit").
rp_registry_remove() {
    [ -f "$RP_STATE_FILE" ] || return 0
    rp_lock
    _rprm_t="/tmp/repurpose_active.$$.tmp"
    busybox awk "$RP_TOK_AWK $RP_SPLIT_BODY" "$RP_STATE_FILE" \
        | busybox grep -vx "$1" > "$_rprm_t"
    busybox mv "$_rprm_t" "$RP_STATE_FILE"
    [ -s "$RP_STATE_FILE" ] || rm -f "$RP_STATE_FILE"
    rp_unlock
}

# ── startup.sh: replace the BEGIN_WAN_REPURPOSE block body with file $1 ──────
# (the awk idiom wan-repurpose.cgi already used). Not locked — callers lock.
# startup.sh runs at every boot, so it is only replaced if what came out still
# has the block's END marker; an awk crash / truncated write leaves it alone.
rp_startup_write_block() {
    [ -f "$RP_STARTUP_SH" ] || return 0
    _rpw_t="/tmp/startup_sh_repurpose_$$.tmp"
    busybox awk -v contentfile="$1" '
        /^# --- BEGIN_WAN_REPURPOSE ---/ {
            print; inblk = 1
            while ((getline line < contentfile) > 0) print line
            close(contentfile)
            next
        }
        /^# --- END_WAN_REPURPOSE ---/ { inblk = 0; print; next }
        inblk { next }
        { print }' "$RP_STARTUP_SH" > "$_rpw_t"
    if [ -s "$_rpw_t" ] && busybox grep -q '^# --- END_WAN_REPURPOSE ---' "$_rpw_t"; then
        busybox mv "$_rpw_t" "$RP_STARTUP_SH" && busybox chmod 755 "$RP_STARTUP_SH"
    fi
    rm -f "$_rpw_t"
}

# ── startup.sh: regenerate the block from the live registry ──────────────────
# One launch line per CONFIGURED interface (its own default-route flag from
# /tmp/repurpose_defroute_<iface>; missing = 1), so every configured interface
# survives a reboot, not just the one just touched.
rp_startup_regen() {
    [ -f "$RP_STARTUP_SH" ] || return 0
    _rps_c="/tmp/startup_sh_repurpose_content_$$.tmp"
    : > "$_rps_c"
    for _rps_if in $(rp_registry_list); do
        _rps_f=$(busybox cat "/tmp/repurpose_defroute_${_rps_if}" 2>/dev/null | busybox tr -d '\r\n')
        printf '( sh %s %s %s ) &\n' "$RP_REPURPOSE_SH" "$_rps_if" "${_rps_f:-1}" >> "$_rps_c"
    done
    rp_lock
    rp_startup_write_block "$_rps_c"
    rp_unlock
    rm -f "$_rps_c"
}

# ── startup.sh: repair a corrupt block IN PLACE (see RP_HEAL_BODY) ───────────
# Works from the block's own lines, NOT the registry — at boot the registry is
# still being filled in by the watchdogs that startup.sh has just launched, so
# regenerating from it would drop the ones that have not registered yet.
rp_startup_heal() {
    [ -f "$RP_STARTUP_SH" ] || return 0
    _rph_t="/tmp/startup_sh_repurpose_heal_$$.tmp"
    rp_lock
    busybox awk -v sh="$RP_REPURPOSE_SH" "$RP_TOK_AWK $RP_HEAL_BODY" \
        "$RP_STARTUP_SH" > "$_rph_t"
    if [ -s "$_rph_t" ] && busybox grep -q '^# --- END_WAN_REPURPOSE ---' "$_rph_t"; then
        busybox mv "$_rph_t" "$RP_STARTUP_SH" && busybox chmod 755 "$RP_STARTUP_SH"
    fi
    rm -f "$_rph_t"
    rp_unlock
}

# ── true if startup.sh has a launch line naming exactly interface $1 ─────────
rp_has_own_launch_line() {
    [ -f "$RP_STARTUP_SH" ] || return 1
    busybox grep -Eq '^[[:space:]]*\([[:space:]]*sh[[:space:]]+[^[:space:]]*repurposeaswan\.sh[[:space:]]+'"$1"'([[:space:]]|$)' \
        "$RP_STARTUP_SH" 2>/dev/null
}

# ── true if a repurposeaswan.sh watchdog for $1 is already running ───────────
rp_watchdog_alive() {
    _rpa_f="/tmp/repurpose_${1}.pid"
    [ -f "$_rpa_f" ] || return 1
    _rpa_p=$(busybox tr -d '\r\n' < "$_rpa_f" 2>/dev/null)
    [ -n "$_rpa_p" ] && kill -0 "$_rpa_p" 2>/dev/null
}

# ── Called by repurposeaswan.sh when it is launched with a name that is not a
# supported interface (typically a fused one persisted in startup.sh by an
# earlier build). Args: <bad name> <its default_route flag> <path of
# repurposeaswan.sh to relaunch>.
#   1. logs it to /tmp/repurpose_invalid.log (next to the other
#      /tmp/repurpose_* logs) — it does NOT start a watchdog for the bad name;
#   2. relaunches each valid interface hiding inside it — except ones that
#      startup.sh launches on their own line (those start themselves, with
#      their own flag) or that already have a watchdog;
#   3. rewrites the startup.sh block so the bad line is gone next boot.
rp_recover_invalid_iface() {
    _rpr_bad="$1"; _rpr_flag="$2"; _rpr_self="$3"
    _rpr_log="/tmp/repurpose_invalid.log"
    printf '[%s] repurposeaswan: refusing invalid interface name "%s" (not one of the supported interfaces)\n' \
        "$(busybox date)" "$_rpr_bad" >> "$_rpr_log"
    for _rpr_i in $(printf '%s\n' "$_rpr_bad" | busybox awk "$RP_TOK_AWK $RP_SPLIT_BODY"); do
        if rp_has_own_launch_line "$_rpr_i" || rp_watchdog_alive "$_rpr_i"; then
            continue
        fi
        printf '[%s] repurposeaswan: recovered "%s" from "%s" — launching it with default_route=%s\n' \
            "$(busybox date)" "$_rpr_i" "$_rpr_bad" "$_rpr_flag" >> "$_rpr_log"
        ( sh "$_rpr_self" "$_rpr_i" "$_rpr_flag" >/dev/null 2>&1 ) &
    done
    rp_startup_heal
    printf '[%s] repurposeaswan: startup.sh WAN-repurpose block repaired\n' \
        "$(busybox date)" >> "$_rpr_log"
}
