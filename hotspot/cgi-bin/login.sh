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
VOUCHER_FILE="/lmepisowifi/hotspot_data/vouchers.txt"
# See lmehspt.sh's AUTO_PAUSED_FILE comment — cleared below once a paused
# session becomes active again (resume, or a voucher stacked onto one),
# since whatever it recorded no longer describes anything currently paused.
AUTO_PAUSED_FILE="/lmepisowifi/hotspot_data/auto_paused.txt"

# Customizable Telegram/Discord message templates
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
    local s="${1:-0}"
    s="${s#-}"
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
# WITHOUT committing it - the caller appends its replacement line (resume/
# stack/grant) directly into that same tmp file, then calls
# _users_file_commit once, so the exclusion and the new line land in a
# single atomic mv instead of two separate writes to the live file. Refuses
# (returns 1, tmp file removed) if grep couldn't actually read USERS_FILE in
# the first place. `grep -v` exit status: 0 = some lines kept, 1 = every
# line was a genuine match (also what a truly-empty file returns - normal
# when the last user is being removed), 2+ = read/access error. Without this
# check, a single transient flash read glitch produces an empty tmp file
# that then gets committed over USERS_FILE unconditionally, wiping every
# user's balance in one request - no concurrency needed at all. Call this
# INSIDE _lock.
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
    # moments after a resume/voucher/coin-stack grant can't silently roll
    # this request back.
    sync
    if [ -s "$USERS_FILE" ]; then rm -f /tmp/hotspot_users_empty_expected 2>/dev/null; else : > /tmp/hotspot_users_empty_expected 2>/dev/null; fi
}

# Same guard as _users_file_stage_excl above, but for VOUCHER_FILE. A
# voucher redemption calls this to burn the code the customer just used -
# without the existed/rc check, a transient flash read glitch on
# VOUCHER_FILE would produce an empty tmp file that then gets moved over
# VOUCHER_FILE unconditionally, deleting every unredeemed voucher in one
# request. Returns 1 (VOUCHER_FILE left untouched) on a genuine read error;
# caller must not treat the redemption as successful in that case.
_voucher_file_replace_excl() {
    local code="$1" existed=0 rc=0
    [ -e "$VOUCHER_FILE" ] && existed=1
    $BB grep -v "^${code} " "$VOUCHER_FILE" > "${VOUCHER_FILE}.tmp" 2>/dev/null || rc=$?
    if [ "$existed" -eq 0 ] || [ "$rc" -le 1 ]; then
        $BB mv "${VOUCHER_FILE}.tmp" "$VOUCHER_FILE"
        # Same as USERS_FILE above - mv carries over the .tmp file's mode,
        # not the old VOUCHER_FILE's, so this has to be re-applied on
        # every commit.
        $BB chmod 600 "$VOUCHER_FILE" 2>/dev/null
        # Force the burned code out to flash now - without this, a
        # power-cut between this redemption and the users.txt grant
        # further down could roll vouchers.txt back to "unredeemed"
        # while the code has already been shown to the customer as used.
        sync
        return 0
    fi
    rm -f "${VOUCHER_FILE}.tmp" 2>/dev/null
    logger -t lmehspt "vouchers.txt: refused overwrite after read error (rc=$rc) - kept existing file" 2>/dev/null
    return 1
}

# 1. Parse uptime instantly using zero-fork built-ins (Sets global $NOW)
if [ -f /proc/uptime ]; then
    read -r UP_RAW < /proc/uptime
    NOW=${UP_RAW%%.*}
else
    NOW=$(date +%s)
fi

# 1b. Resolve the client's MAC now — ahead of the rate-limiter/DOS checks
# below, which never look at it — purely so a device-fingerprint cookie can
# be verified/refreshed as part of this response's one-and-only header
# block. Same /proc/net/arp lookup this script always did, just done once,
# here, instead of a second time further down (see step 5, where it used to
# live — CLIENT_MAC is used as-is from here on).
CLIENT_IP="$REMOTE_ADDR"
CLIENT_MAC=$(
    $BB cat /proc/net/arp \
    | $BB grep "^$CLIENT_IP " \
    | $BB awk '{print $4}' \
    | $BB head -1
)
mf_reconcile

# 2. Output HTTP Headers EXACTLY ONCE
echo "Content-type: application/json"
echo "Cache-Control: no-store"
[ -n "$MF_COOKIE_HEADER" ] && echo "$MF_COOKIE_HEADER"
echo ""

# 3. Zero-Fork Rate Limiter Interceptor
if [ -n "$REMOTE_ADDR" ]; then
    RATE_FILE="/tmp/hs_rate_${REMOTE_ADDR}"
    if [ -f "$RATE_FILE" ]; then
        read -r LAST_ATTEMPT < "$RATE_FILE"
        if [ -n "$LAST_ATTEMPT" ] && [ "$NOW" -le "$LAST_ATTEMPT" ]; then
            # Headers are already printed; just output JSON and quit instantly
            echo '{"ok":false,"error":"cooldown"}'
            exit 0
        fi
    fi
    echo "$NOW" > "$RATE_FILE"
fi

# 4. DOS Protection: Reject overly large payloads early.
CLEN=$($BB echo "$CONTENT_LENGTH" | $BB tr -dc '0-9')
if [ -z "$CLEN" ] || [ "$CLEN" -gt 256 ]; then
    echo '{"ok":false,"error":"invalid"}'
    exit 0
fi

read -n "$CLEN" POST_DATA

# 5. Extract inputs securely
VOUCHER=$(
    $BB echo "$POST_DATA" \
    | $BB tr '&' '\n' \
    | $BB grep '^voucher=' \
    | $BB cut -d '=' -f 2- \
    | $BB sed 's/+/ /g; s/%20/ /g' \
    | $BB tr -dc 'a-zA-Z0-9\-_' \
    | $BB tr 'a-z' 'A-Z'
)

RESUME=$(
    $BB echo "$POST_DATA" \
    | $BB tr '&' '\n' \
    | $BB grep '^resume=' \
    | $BB cut -d '=' -f 2- \
    | $BB tr -dc '0-9'
)

if [ -z "$CLIENT_MAC" ] || [ "$CLIENT_MAC" = "00:00:00:00:00:00" ]; then
    echo '{"ok":false,"error":"no_mac"}'
    exit 0
fi

# --- Proceed with Core Logic ---
_lock
EXISTING=$($BB grep "^$CLIENT_MAC " "$SESSION_FILE" 2>/dev/null | $BB head -1)
PAUSED=$($BB grep "^$CLIENT_MAC paused " "$USERS_FILE" 2>/dev/null | $BB head -1)

DURATION=0
TOTAL=0

# Handle Resumes First
if [ -n "$RESUME" ] && [ "$RESUME" = "1" ]; then
    if [ -n "$PAUSED" ]; then
        DURATION=$($BB echo "$PAUSED" | $BB awk '{print $3}')
        TOTAL=$($BB echo "$PAUSED" | $BB awk '{print $4}')
        [ -z "$TOTAL" ] && TOTAL=$DURATION

        # Resolve this MAC's expiring (rate-validity) bucket now, before
        # granting anything back: a chunk of DURATION may belong to a rate
        # whose validity window already elapsed (or that was rebooted
        # through) while the session sat paused, in which case it's
        # forfeited rather than resumed — see ratevalidity.sh. No-op
        # (RV_FORFEITED stays 0) for a balance with no expiring bucket at
        # all.
        rv_apply_resume "$CLIENT_MAC" "$NOW"
        if [ "${RV_FORFEITED:-0}" -gt 0 ]; then
            DURATION=$(( DURATION - RV_FORFEITED ))
            TOTAL=$(( TOTAL - RV_FORFEITED ))
            [ "$DURATION" -lt 0 ] && DURATION=0
            [ "$TOTAL" -lt 0 ] && TOTAL=0
        fi
    elif [ -n "$EXISTING" ]; then
        # Stale "Resume Time" click landing after the session was already
        # activated some other way — most commonly: the user inserted coins
        # while the paused-state Resume button was still visible, and
        # coin_result.sh already merged the paused balance into a fresh
        # active session by the time this request arrives. Nothing is
        # actually being paused→resumed here, so acknowledge with the live
        # numbers but skip the rewrite below and the "Session Resumed"
        # Telegram/Discord notification, since no session was ever paused.
        OLD_EXPIRY=$($BB echo "$EXISTING" | $BB awk '{print $2}')
        OLD_TOTAL=$($BB echo "$EXISTING" | $BB awk '{print $3}')
        ALREADY_REMAINING=$(( OLD_EXPIRY - NOW ))
        if [ "$ALREADY_REMAINING" -gt 0 ]; then
            [ -z "$OLD_TOTAL" ] && OLD_TOTAL=$ALREADY_REMAINING
            echo "{\"ok\":true,\"stacked\":false,\"remaining\":$ALREADY_REMAINING,\"total\":$OLD_TOTAL,\"duration\":0,\"mac\":\"$CLIENT_MAC\"}"
            exit 0
        fi
    fi
    
    if [ "$DURATION" -le 0 ]; then
        # A forfeiture above may have just emptied out what used to be a
        # genuine paused balance — drop the now-stale row from USERS_FILE
        # too, so status.sh / the admin session list / a repeat resume
        # attempt all see the truth (nothing left) instead of the
        # pre-forfeiture REMAIN/TOTAL that rate-validity no longer backs.
        if [ -n "$PAUSED" ] && _users_file_stage_excl "$CLIENT_MAC"; then
            _users_file_commit
        fi
        echo '{"ok":false,"error":"no_paused_session"}'
        exit 0
    fi
    NEW_EXPIRY=$(( NOW + DURATION ))
    NEW_TOTAL=$TOTAL
else
    # Master switch: voucher input entirely disabled by the admin. Checked
    # before anything else in this branch (strikes, internet gate, code
    # lookup) so a disabled device doesn't accumulate strikes or burn a
    # code lookup for a feature it can't use. Resuming an already-paused
    # session (the branch above) is untouched by this toggle, same as
    # COIN_ENABLED never blocks resuming an already-paid coin session.
    if [ "${VOUCHER_ENABLED:-1}" = "0" ]; then
        echo '{"ok":false,"error":"voucher_disabled"}'
        exit 0
    fi

    # Verify regular voucher inputs
    if [ -z "$VOUCHER" ]; then
        echo '{"ok":false,"error":"no_voucher"}'
        exit 0
    fi

    # --- Wrong-voucher anti-troll strike system (mirrors coin.sh's) ---
    # Tracks repeated incorrect voucher submissions per-device in
    # /tmp/voucher_strikes.txt ("MAC STRIKES LAST_STRIKE_UPTIME") and, once
    # VOUCHER_STRIKE_ENABLED is on, temporarily blocks further attempts from
    # that device after VOUCHER_STRIKE_THRESHOLD wrong codes in a row, for
    # VOUCHER_COOLDOWN seconds — same shape as coin.sh's /tmp/coin_strikes.txt
    # anti-griefing suspension. Off by default (opt-in) so existing installs
    # keep today's unlimited-attempts behavior until the admin turns it on.
    touch /tmp/voucher_strikes.txt
    if [ "${VOUCHER_STRIKE_ENABLED:-0}" = "1" ]; then
        VSTRIKE_DATA=$($BB grep "^$CLIENT_MAC " /tmp/voucher_strikes.txt 2>/dev/null)
        if [ -n "$VSTRIKE_DATA" ]; then
            VSTRIKES=$(printf '%s' "$VSTRIKE_DATA" | $BB awk '{print $2}')
            VLAST_STRIKE=$(printf '%s' "$VSTRIKE_DATA" | $BB awk '{print $3}')
            _VST=${VOUCHER_STRIKE_THRESHOLD:-3}
            _VCD=${VOUCHER_COOLDOWN:-60}
            if [ "${VSTRIKES:-0}" -ge "$_VST" ]; then
                _VSINCE=$(( NOW - VLAST_STRIKE ))
                if [ "$_VSINCE" -lt "$_VCD" ]; then
                    _VWAIT_MINS=$(( (_VCD - _VSINCE + 59) / 60 ))
                    echo "{\"ok\":false,\"error\":\"voucher_suspended\",\"wait_minutes\":${_VWAIT_MINS},\"cooldown_remaining\":$(( _VCD - _VSINCE ))}"
                    exit 0
                else
                    # Cooldown elapsed — clear the slate for this device.
                    $BB grep -v "^$CLIENT_MAC " /tmp/voucher_strikes.txt > /tmp/vs.tmp 2>/dev/null
                    $BB mv /tmp/vs.tmp /tmp/voucher_strikes.txt
                    $BB chmod 600 /tmp/voucher_strikes.txt 2>/dev/null
                fi
            fi
        fi
    fi

    # Refuse to convert (burn) a voucher code while the router has no
    # internet, if the operator has opted into that. Only gates a fresh
    # voucher redemption — resuming an already-paused session (the branch
    # above) never touches VOUCHER_FILE, so it's unaffected.
    if [ "${VOUCHER_REQUIRE_INTERNET:-0}" = "1" ] && [ ! -f "${INTERNET_UP_FILE:-/tmp/internet_up}" ]; then
        echo '{"ok":false,"error":"no_internet"}'
        exit 0
    fi

    VOUCHER_LINE=$(
        $BB grep -v "^#" "$VOUCHER_FILE" 2>/dev/null \
        | $BB grep "^$VOUCHER " \
        | $BB head -1
    )

    if [ -z "$VOUCHER_LINE" ]; then
        if [ "${VOUCHER_STRIKE_ENABLED:-0}" = "1" ]; then
            VSTRIKES=$($BB grep "^$CLIENT_MAC " /tmp/voucher_strikes.txt 2>/dev/null | $BB awk '{print $2}')
            VSTRIKES=$(( ${VSTRIKES:-0} + 1 ))
            $BB grep -v "^$CLIENT_MAC " /tmp/voucher_strikes.txt > /tmp/vs.tmp 2>/dev/null
            printf '%s %s %s\n' "$CLIENT_MAC" "$VSTRIKES" "$NOW" >> /tmp/vs.tmp
            $BB mv /tmp/vs.tmp /tmp/voucher_strikes.txt
            $BB chmod 600 /tmp/voucher_strikes.txt 2>/dev/null

            # Notify once when suspension is first triggered (strikes exactly == threshold)
            _VST=${VOUCHER_STRIKE_THRESHOLD:-3}
            if [ "$VSTRIKES" -eq "$_VST" ]; then
                _VCD=${VOUCHER_COOLDOWN:-60}
                _VCD_MINS=$(( _VCD / 60 ))
                _VSUSP_MSG=$(tpl_render "$TPL_VOUCHER_ANTI_TROLL" \
                    mac "$CLIENT_MAC" strikes "$VSTRIKES" strikemax "$_VST" cooldownmins "$_VCD_MINS")
                ( /lmepisowifi/hotspot/notify.sh "$_VSUSP_MSG" "" voucher_anti_troll >/dev/null 2>&1 </dev/null & )
            fi
        fi
        echo '{"ok":false,"error":"invalid"}'
        exit 0
    fi

    # Valid code entered — a legitimate customer, not a troll. Clear any
    # wrong-voucher strikes this device had accumulated.
    $BB grep -v "^$CLIENT_MAC " /tmp/voucher_strikes.txt > /tmp/vs.tmp 2>/dev/null
    $BB mv /tmp/vs.tmp /tmp/voucher_strikes.txt
    $BB chmod 600 /tmp/voucher_strikes.txt 2>/dev/null

    DURATION=$($BB echo "$VOUCHER_LINE" | $BB awk '{print $2}')
    VALID_UNTIL=$($BB echo "$VOUCHER_LINE" | $BB awk '{print $3}')
    # Remember the voucher's own duration before any stacking mutates DURATION
    VOUCHER_TIME=$DURATION

    if [ -n "$VALID_UNTIL" ] && [ "$VALID_UNTIL" != "" ]; then
        NOW_EPOCH=$(date +%s 2>/dev/null)
        if [ -n "$NOW_EPOCH" ] && [ "$NOW_EPOCH" -gt "$VALID_UNTIL" ]; then
            echo '{"ok":false,"error":"expired"}'
            exit 0
        fi
    fi

    if ! _voucher_file_replace_excl "$VOUCHER"; then
        # VOUCHER_FILE couldn't be safely read/rewritten (transient flash
        # glitch) - fail closed. Granting time here without actually
        # burning the code would let the same voucher be redeemed
        # repeatedly until the file happens to read cleanly.
        echo '{"ok":false,"error":"try_again"}'
        exit 0
    fi
fi

STACKED=false
NEED_FW_RULES=true

if [ -z "$RESUME" ]; then
    if [ -n "$EXISTING" ]; then
        OLD_EXPIRY=$($BB echo "$EXISTING" | $BB awk '{print $2}')
        OLD_TOTAL=$($BB echo "$EXISTING" | $BB awk '{print $3}')
        [ -z "$OLD_TOTAL" ] && OLD_TOTAL=$(( OLD_EXPIRY - NOW ))

        if [ "$OLD_EXPIRY" -gt "$NOW" ]; then
            NEW_EXPIRY=$(( OLD_EXPIRY + DURATION ))
            NEW_TOTAL=$(( OLD_TOTAL + DURATION ))
            STACKED=true
            NEED_FW_RULES=false
        else
            NEW_EXPIRY=$(( NOW + DURATION ))
            NEW_TOTAL=$DURATION
        fi
    else
        VOUCHER_DURATION=$DURATION
        if [ -n "$PAUSED" ]; then
            PAUSED_DURATION=$($BB echo "$PAUSED" | $BB awk '{print $3}')
            PAUSED_TOTAL=$($BB echo "$PAUSED" | $BB awk '{print $4}')
            [ -z "$PAUSED_TOTAL" ] && PAUSED_TOTAL=$PAUSED_DURATION

            # Same rate-validity resolution as the explicit Resume branch
            # above: a voucher redemption landing on a paused balance is
            # just as much a paused→active transition, so any expired or
            # rebooted-through expiring-bucket chunk forfeits here too
            # instead of being silently carried forward forever.
            rv_apply_resume "$CLIENT_MAC" "$NOW"
            if [ "${RV_FORFEITED:-0}" -gt 0 ]; then
                PAUSED_DURATION=$(( PAUSED_DURATION - RV_FORFEITED ))
                PAUSED_TOTAL=$(( PAUSED_TOTAL - RV_FORFEITED ))
                [ "$PAUSED_DURATION" -lt 0 ] && PAUSED_DURATION=0
                [ "$PAUSED_TOTAL" -lt 0 ] && PAUSED_TOTAL=0
            fi

            DURATION=$(( VOUCHER_DURATION + PAUSED_DURATION ))
            NEW_TOTAL=$(( PAUSED_TOTAL + VOUCHER_DURATION ))
            STACKED=true
        else
            NEW_TOTAL=$VOUCHER_DURATION
        fi
        NEW_EXPIRY=$(( NOW + DURATION ))
    fi
fi

$BB grep -v "^$CLIENT_MAC " "$SESSION_FILE" > "${SESSION_FILE}.tmp" 2>/dev/null
$BB mv "${SESSION_FILE}.tmp" "$SESSION_FILE"

# Format: MAC EXPIRY TOTAL
$BB echo "$CLIENT_MAC $NEW_EXPIRY $NEW_TOTAL" >> "$SESSION_FILE"
$BB chmod 600 "$SESSION_FILE" 2>/dev/null

# Immediately write state to persistent Flash database as 'active'
REMAINING_SECS=$(( NEW_EXPIRY - NOW ))
if _users_file_stage_excl "$CLIENT_MAC"; then
    $BB echo "$CLIENT_MAC active $REMAINING_SECS $NEW_TOTAL $(_fmt_secs "$REMAINING_SECS")" >> "${USERS_FILE}.tmp"
    _users_file_commit
fi
# No longer paused (resumed, or a voucher just stacked onto a paused
# balance) — drop the auto-pause marker so a later manual pause doesn't
# inherit a stale "system paused this" flag from before.
[ -f "$AUTO_PAUSED_FILE" ] && { $BB grep -vx "$CLIENT_MAC" "$AUTO_PAUSED_FILE" > /tmp/login_ap.tmp 2>/dev/null; $BB mv /tmp/login_ap.tmp "$AUTO_PAUSED_FILE"; }

if [ "$NEED_FW_RULES" = "true" ]; then
    iptables -t nat -I HOTSPOT 1 -m mac --mac-source "$CLIENT_MAC" -j RETURN 2>/dev/null
    iptables -t filter -I HOTSPOT_FWD 1 -m mac --mac-source "$CLIENT_MAC" -j ACCEPT 2>/dev/null
fi

REMAINING=$(( NEW_EXPIRY - NOW ))
echo "{\"ok\":true,\"stacked\":$STACKED,\"remaining\":$REMAINING,\"total\":$NEW_TOTAL,\"duration\":$DURATION,\"mac\":\"$CLIENT_MAC\"}"

# --- Notifications (resume / voucher conversion) ---------------------------
# Reached only on success (all failure paths exit earlier). Fire-and-forget.
_fmt_dur() {
    $BB awk -v s="$1" 'BEGIN{
        s=int(s); if(s<0)s=0
        d=int(s/86400); s=s%86400
        h=int(s/3600);  s=s%3600
        m=int(s/60)
        out=""
        if(d>0){ out=out d"d " }
        if(h>0||d>0){ out=out h"h " }
        out=out m"m"
        printf "%s", out
    }'
}
if [ "$RESUME" = "1" ]; then
    _ACTIVE=$($BB grep -c '.' "$SESSION_FILE" 2>/dev/null)
    [ -n "$_ACTIVE" ] || _ACTIVE=0
    N_MSG=$(tpl_render "$TPL_SESSION_RESUMED" \
        remainingtime "$(_fmt_dur ${REMAINING:-0})" totaltime "$(_fmt_dur ${NEW_TOTAL:-0})" \
        mac "$CLIENT_MAC" activeusrcount "${_ACTIVE:-0}")
    ( /lmepisowifi/hotspot/notify.sh "$N_MSG" "" session_resumed "$CLIENT_MAC" >/dev/null 2>&1 </dev/null & )
elif [ -n "$VOUCHER" ]; then
    N_MSG=$(tpl_render "$TPL_VOUCHER_REDEEMED" \
        voucher "$VOUCHER" addedtime "$(_fmt_dur ${VOUCHER_TIME:-0})" \
        totaltime "$(_fmt_dur ${NEW_TOTAL:-0})" remainingtime "$(_fmt_dur ${REMAINING:-0})" mac "$CLIENT_MAC")
    ( /lmepisowifi/hotspot/notify.sh "$N_MSG" "" voucher_redeemed >/dev/null 2>&1 </dev/null & )
fi
# ---------------------------------------------------------------------------
