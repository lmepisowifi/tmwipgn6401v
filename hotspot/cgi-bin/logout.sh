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


BB="busybox"
SESSION_FILE="/tmp/active_sessions.txt"
USERS_FILE="/lmepisowifi/hotspot_data/users.txt"
# See lmehspt.sh's AUTO_PAUSED_FILE comment — this file's own pause below is
# always MANUAL (the customer tapped Pause), so it's cleared, never set.
AUTO_PAUSED_FILE="/lmepisowifi/hotspot_data/auto_paused.txt"

# Notification templates (for the "session paused" alert). Sourcing is
# harmless if the file is missing — tpl_render just won't be defined and
# the guarded call below is skipped.
[ -f /lmepisowifi/hotspot/notify_templates.sh ] && . /lmepisowifi/hotspot/notify_templates.sh
# Live-updatable toggles (MAC_RANDOMIZATION_FIX among them) written by
# lmehspt.sh / hotspot.cgi — same cache coin.sh/coin_result.sh already use.
[ -f /tmp/coin_config.env ] && . /tmp/coin_config.env
# MAC-randomization session-continuity fix (cookie-based device fingerprint)
[ -f /lmepisowifi/hotspot/macfix.sh ] && . /lmepisowifi/hotspot/macfix.sh
# WiFi Rates expiry/validity bucket tracking - see ratevalidity.sh.
[ -f /lmepisowifi/hotspot/ratevalidity.sh ] && . /lmepisowifi/hotspot/ratevalidity.sh

_unlock() { rm -f /tmp/hotspot_session.lock/pid 2>/dev/null; rmdir /tmp/hotspot_session.lock 2>/dev/null; }
_lock() {
    local i=0
    while ! mkdir /tmp/hotspot_session.lock 2>/dev/null; do
        # Only steal the lock once its holder is provably dead (see
        # lmehspt.sh's _lock for the full explanation) - a flat 5s wait was
        # force-breaking a live holder's lock under normal polling load and
        # letting two writers stomp the same USERS_FILE.tmp at once.
        if [ "$((i % 10))" -eq 0 ] && [ "$i" -gt 0 ]; then
            if [ "$i" -ge 300 ]; then
                $BB rm -f /tmp/hotspot_session.lock/pid 2>/dev/null
                rmdir /tmp/hotspot_session.lock 2>/dev/null
            else
                _HPID=$($BB cat /tmp/hotspot_session.lock/pid 2>/dev/null)
                if [ -z "$_HPID" ] || ! kill -0 "$_HPID" 2>/dev/null; then
                    $BB rm -f /tmp/hotspot_session.lock/pid 2>/dev/null
                    rmdir /tmp/hotspot_session.lock 2>/dev/null
                fi
            fi
        fi
        $BB sleep 0.1 2>/dev/null || sleep 0.1
        i=$((i + 1))
    done
    $BB echo $$ > /tmp/hotspot_session.lock/pid 2>/dev/null
    trap _unlock EXIT INT TERM
}
_fmt_secs() {
    # Guard against blank or empty variables
    local s="${1:-0}"
    
    # Strip negative signs if present
    s="${s#-}"
    
    # Force to 0 if containing non-numeric characters
    case "$s" in
        ""|*[!0-9]*) s=0 ;;
    esac

    local d=$(( s / 86400 )) 
    local h=$(( (s % 86400) / 3600 )) 
    local m=$(( (s % 3600) / 60 )) 
    
    if [ "$d" -gt 0 ]; then printf '%dd %dh %dm' "$d" "$h" "$m"
    elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
    else printf '%dm' "$m"; fi
}

# Stages "${USERS_FILE}.tmp" with every line except the one starting "$1 ",
# WITHOUT committing it - the caller appends the paused-replacement line
# directly into that same tmp file, then calls _users_file_commit once, so
# the exclusion and the new line land in a single atomic mv instead of two
# separate writes to the live file. Refuses (returns 1, tmp file removed)
# if grep couldn't actually read USERS_FILE in the first place. `grep -v`
# exit status: 0 = some lines kept, 1 = every line was a genuine match
# (also what a truly-empty file returns - normal when the last user is
# being removed), 2+ = read/access error. Without this check, a single
# transient flash read glitch produces an empty tmp file that then gets
# committed over USERS_FILE unconditionally, wiping every user's balance
# in one request - no concurrency needed at all. Call this INSIDE _lock.
_users_file_stage_excl() {
    local mac="$1" existed=0 rc=0
    [ -e "$USERS_FILE" ] && existed=1
    $BB grep -v "^${mac} " "$USERS_FILE" > "${USERS_FILE}.tmp" 2>/dev/null || rc=$?
    if [ "$existed" -eq 1 ] && [ "$rc" -gt 1 ]; then
        rm -f "${USERS_FILE}.tmp" 2>/dev/null
        logger -t lmehspt "users.txt: refused overwrite after read error (rc=$rc) - kept existing file" 2>/dev/null
        return 1
    fi
    return 0
}
# Commits a staged "${USERS_FILE}.tmp" via a single atomic mv, so the
# empty-expected marker is evaluated exactly once against the file's true
# final content for this operation - never against a transient
# mid-operation state that a separate later append could change out from
# under it.
_users_file_commit() {
    $BB mv "${USERS_FILE}.tmp" "$USERS_FILE"
    # Same reasoning as macfix.sh's MACFIX_MAP_FILE/MACFIX_LOG_FILE: this
    # file links a real customer MAC to a balance/status, so it shouldn't
    # be left world-readable by whatever the process umask happens to be.
    # mv doesn't inherit the destination's old mode - it carries over
    # whatever mode the just-written .tmp file had - so this has to be
    # re-applied after every commit, not just once at creation.
    $BB chmod 600 "$USERS_FILE" 2>/dev/null
    # Rename is atomic/crash-consistent on ubifs, but that only guarantees
    # you never see a half-written file - it says nothing about whether
    # this specific write has actually reached the NAND yet vs. still
    # sitting dirty in the page cache. Force it out now so a power-cut
    # moments after a pause/logout can't silently roll this request back
    # (and, combined with the unconditional stage+commit above, can't
    # leave a stale "active" line behind either).
    sync
    if [ -s "$USERS_FILE" ]; then rm -f /tmp/hotspot_users_empty_expected 2>/dev/null; else : > /tmp/hotspot_users_empty_expected 2>/dev/null; fi
}

CLIENT_IP="$REMOTE_ADDR"
CLIENT_MAC=$(
    $BB cat /proc/net/arp \
    | $BB grep "^$CLIENT_IP " \
    | $BB awk '{print $4}' \
    | $BB head -1
)
# Verify/refresh this browser's fingerprint cookie and, if it was last seen
# on a different MAC, migrate its live session/firewall rule onto the
# current one first — so a manual Pause tap finds the right session even
# if the phone's MAC rotated moments before this request.
mf_reconcile

$BB echo "Content-type: application/json"
$BB echo "Cache-Control: no-store"
[ -n "$MF_COOKIE_HEADER" ] && $BB echo "$MF_COOKIE_HEADER"
$BB echo ""

if [ -z "$CLIENT_MAC" ] || [ "$CLIENT_MAC" = "00:00:00:00:00:00" ]; then
    $BB echo '{"ok":false,"error":"no_mac"}'
    exit 0
fi

_lock
NOW=$($BB awk '{print int($1)}' /proc/uptime)
SESSION=$($BB grep "^$CLIENT_MAC " "$SESSION_FILE" 2>/dev/null | $BB head -1)

if [ -z "$SESSION" ]; then
    $BB echo '{"ok":false,"error":"no_session"}'
    exit 0
fi

EXPIRY=$($BB echo "$SESSION" | $BB awk '{print $2}')
TOTAL=$($BB echo "$SESSION" | $BB awk '{print $3}')
REMAINING=$(( EXPIRY - NOW ))
[ -z "$TOTAL" ] && TOTAL=$REMAINING

$BB grep -v "^$CLIENT_MAC " "$SESSION_FILE" > "${SESSION_FILE}.tmp"
$BB mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
$BB chmod 600 "$SESSION_FILE" 2>/dev/null

# Freeze this MAC's expiring (rate-validity) bucket, if it has one, into
# its own paused-mode row so its deadline keeps ticking while offline
# instead of being lost or left stale in "live" (uptime-boundary) form —
# see ratevalidity.sh. No-op for a purely no-expiry balance.
rv_freeze "$CLIENT_MAC" "$NOW" "$REMAINING"

# Save paused user to flash master database. Stage+commit is now
# UNCONDITIONAL (matches hotspot.cgi's admin "kick" handler) - only the
# appended "paused" line is conditional on REMAINING>0.
#
# Why: a manual pause/logout request can race the session's own natural
# expiry, landing here with REMAINING<=0. SESSION_FILE is cleared for this
# MAC unconditionally above regardless of REMAINING, but USERS_FILE used to
# be skipped entirely whenever REMAINING<=0 - leaving whatever "active ..."
# line was last written there (from the original grant or the last 5-minute
# sync) stranded in place. Because the MAC is now gone from SESSION_FILE,
# the ~1s expiry watchdog never encounters it again to clean it up either
# (it only walks entries still in SESSION_FILE) - so that stale line
# survived indefinitely, until the next periodic sync_to_persistent_db()
# run reinterpreted the orphaned "active" status as "paused" and copied its
# old remaining/total across unchanged, handing the user back whatever
# time had been recorded at that last write even though the session had
# already fully run out. Excluding the MAC's line unconditionally here
# (and only re-adding it when there's real time to preserve) removes the
# entry outright instead of leaving it behind.
PAUSED_OK=0
if _users_file_stage_excl "$CLIENT_MAC"; then
    if [ "$REMAINING" -gt 0 ]; then
        $BB echo "$CLIENT_MAC paused $REMAINING $TOTAL $(_fmt_secs "$REMAINING")" >> "${USERS_FILE}.tmp"
        PAUSED_OK=1
    fi
    _users_file_commit
fi
# This pause is always MANUAL (the customer tapped Pause) — drop any stale
# "system auto-paused this MAC" marker so AUTO_RESUME_ENABLED can't
# silently resume it (see lmehspt.sh's AUTO_PAUSED_FILE comment).
[ -f "$AUTO_PAUSED_FILE" ] && { $BB grep -vx "$CLIENT_MAC" "$AUTO_PAUSED_FILE" > /tmp/logout_ap.tmp 2>/dev/null; $BB mv /tmp/logout_ap.tmp "$AUTO_PAUSED_FILE"; }

iptables -t nat -D HOTSPOT -m mac --mac-source "$CLIENT_MAC" -j RETURN 2>/dev/null
iptables -t filter -D HOTSPOT_FWD -m mac --mac-source "$CLIENT_MAC" -j ACCEPT 2>/dev/null

_unlock

# Fire the "session paused" alert — this path is a MANUAL pause (the user
# tapped Pause on the portal). Fire-and-forget; the session_paused event
# key lets the admin mute it from the www2 UI. Skipped if nothing was
# actually paused (no remaining time) or if templates aren't available.
if [ "$PAUSED_OK" = "1" ] && command -v tpl_render >/dev/null 2>&1; then
    _P_ACTIVE=$($BB grep -c '.' "$SESSION_FILE" 2>/dev/null)
    [ -n "$_P_ACTIVE" ] || _P_ACTIVE=0
    _P_MSG=$(tpl_render "$TPL_SESSION_PAUSED" \
        reason "Manually" \
        remainingtime "$(_fmt_secs "$REMAINING")" \
        totaltime "$(_fmt_secs "$TOTAL")" \
        mac "$CLIENT_MAC" \
        activeusrcount "${_P_ACTIVE:-0}")
    ( /lmepisowifi/hotspot/notify.sh "$_P_MSG" "" session_paused "$CLIENT_MAC" >/dev/null 2>&1 </dev/null & )
fi

$BB echo "{\"ok\":true,\"mac\":\"$CLIENT_MAC\"}"
