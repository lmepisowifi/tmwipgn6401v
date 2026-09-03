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

# /lmepisowifi/hotspot/macfix.sh — MAC-randomization session-continuity fix
# ============================================================================
# Recent iOS/Android builds hand out a freshly randomized MAC address on
# every WiFi reconnect (not just once per network). Every session, firewall
# rule and balance in this project is keyed by MAC (see SESSION_FILE /
# USERS_FILE usage in login.sh, logout.sh, status.sh) — so a customer who's
# mid-session and simply locks their phone, walks out of range for a moment,
# or has their radio bounce comes back looking like a brand-new,
# unauthenticated device, even though their paid time is still sitting there
# under their OLD MAC.
#
# The fix issues each BROWSER (not each MAC) a long-lived, server-signed
# cookie the first time it's seen. Every hotspot CGI request that sources
# this file calls mf_reconcile() once CLIENT_MAC is known: it verifies the
# cookie's signature (never trusts a value just because it was sent — see
# _mf_verify_cookie), looks up which MAC that same browser last presented,
# and — if that differs from the MAC it's presenting right now — moves the
# live SESSION_FILE / USERS_FILE row, any banked below-minimum-tier coin
# balance (MACFIX_BANK_FILE — see coin_result.sh), and firewall rule over
# to the new MAC *before* the caller does its own MAC-keyed lookup. If the
# new MAC already has its own separate live row (e.g. it was paid for on
# its own before this browser's cookie tied the two MACs together), the
# two rows' remaining time (or banked pesos) are combined into one instead
# of being left as two shadowing/duplicate rows under the same MAC — see
# _mf_reconcile_row. Every existing MAC-keyed code path downstream
# (resume, stacking, pause, status polling, coin banking) keeps working
# completely unmodified.
#
# Cookie is set purely via the HTTP Set-Cookie response header — no
# document.cookie / localStorage JS involved on the frontend at all, so it
# behaves the same across every browser/webview a customer might land in
# (the in-app WebView that auto-opens the portal, then later Safari/Chrome/
# whatever they switch to — each still gets recognized once it presents the
# same cookie back), including the locked-down CNA-style sandboxes that
# have previously thrown SecurityErrors on localStorage in this project.
#
# Toggle: MAC_RANDOMIZATION_FIX ("1"/"0", default "1" — see defaults.env,
# www2 > Hotspot).
#
# Sourced (not executed) by login.sh / logout.sh / status.sh / coin.sh.
# Requires the sourcing script to already define: BB, CLIENT_MAC, _lock,
# _unlock — all already present at the top of each. SESSION_FILE and
# USERS_FILE are optional: a caller that doesn't define them (coin.sh has
# no need for either) simply skips reconciliation for those two files —
# the coin-bank balance (MACFIX_BANK_FILE, always defined below) still
# gets migrated regardless.
# ============================================================================

MACFIX_SECRET_FILE="/lmepisowifi/hotspot_data/.macfix_secret"
MACFIX_MAP_FILE="/lmepisowifi/hotspot_data/device_fp.txt"
# Same physical file as coin_result.sh's COIN_BANK_FILE — duplicated as a
# literal constant here rather than sourced, matching how this project
# already repeats e.g. USERS_FILE's path across lmehspt.sh/coin_result.sh/
# status.sh instead of centralizing it.
MACFIX_BANK_FILE="/lmepisowifi/hotspot_data/coin_bank.txt"
MACFIX_COOKIE_NAME="lme_fp"
MACFIX_COOKIE_MAXAGE=31536000   # 1 year — a slow "remember this browser", not a login session

_mf_now() { $BB awk '{print int($1)}' /proc/uptime 2>/dev/null || date +%s; }

# Loads the private signing key, generating it once on first use. Lives on
# the non-volatile data partition (same as users.txt/income.env) so it
# survives reboots — regenerating it would invalidate every customer's
# cookie in one shot. Never shipped/OTA'd and never written to globals.env,
# matching the "no secrets in globals.env" rule at the top of defaults.env.
_mf_secret() {
    if [ ! -s "$MACFIX_SECRET_FILE" ]; then
        $BB mkdir -p /lmepisowifi/hotspot_data 2>/dev/null
        printf '%s %d %d %s\n' \
            "$(cat /proc/uptime 2>/dev/null)" "$$" "$RANDOM" "$(date +%s 2>/dev/null)" \
            | sha256sum | awk '{print $1}' > "${MACFIX_SECRET_FILE}.tmp" 2>/dev/null
        $BB mv "${MACFIX_SECRET_FILE}.tmp" "$MACFIX_SECRET_FILE" 2>/dev/null
    fi
    cat "$MACFIX_SECRET_FILE" 2>/dev/null
}

# Keyed hash of $1 using the private secret above — same "PSK:payload →
# digest" idiom coin.sh/coin_result.sh already use for NodeMCU reply
# signatures, just sha256 instead of md5 since this token lives for a year.
_mf_sign() { printf '%s:%s' "$(_mf_secret)" "$1" | sha256sum | awk '{print $1}'; }

# Verifies $HTTP_COOKIE's fingerprint cookie, if any. Sets MF_FP_ID and
# returns 0 on a signature match; returns 1 (MF_FP_ID cleared) for anything
# else — no cookie, malformed cookie, or a value that doesn't verify. A
# customer editing the cookie in devtools just looks like a first-ever
# visit; they can't pick their own ID or anyone else's without the secret.
_mf_verify_cookie() {
    local raw sig
    raw=$($BB echo "$HTTP_COOKIE" | $BB sed -n "s/.*${MACFIX_COOKIE_NAME}=\([^;]*\).*/\1/p" | $BB tr -d '\r\n')
    # fp_id/sig are always plain sha256 hex plus one separating dot — strip
    # anything else so a hostile cookie value can never reach grep/file
    # paths below with unexpected characters.
    raw=$(printf '%s' "$raw" | $BB tr -cd 'a-f0-9.')
    MF_FP_ID=""
    case "$raw" in
        *.*) ;;
        *) return 1 ;;
    esac
    MF_FP_ID="${raw%%.*}"
    sig="${raw#*.}"
    [ -n "$MF_FP_ID" ] && [ -n "$sig" ] || { MF_FP_ID=""; return 1; }
    [ "$(_mf_sign "$MF_FP_ID")" = "$sig" ] || { MF_FP_ID=""; return 1; }
    return 0
}

# Self-contained "Xd Xh Xm" formatter for USERS_FILE's trailing display
# field. Duplicated here rather than relying on the sourcing script's own
# _fmt_secs, because status.sh - one of macfix.sh's three sourcing
# scripts - never defines one (it only ever reads USERS_FILE, never
# writes it), so it can't be assumed present.
_mf_fmt_secs() {
    local s="${1:-0}" d h m
    s="${s#-}"
    case "$s" in ""|*[!0-9]*) s=0 ;; esac
    d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
    if [ "$d" -gt 0 ]; then printf '%dd %dh %dm' "$d" "$h" "$m"
    elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
    else printf '%dm' "$m"; fi
}

# Renames $2 (old MAC)'s row in a MAC-keyed flat file ($1) onto $3 (new
# MAC) - or, if $3 already has a row of its own there too, COMBINES
# whatever time is actually left on each side into one merged row under
# $3, instead of the old behaviour of just appending a second row and
# leaving both to shadow/duplicate each other. $4 selects the row layout:
# "session" for SESSION_FILE's "MAC EXPIRY TOTAL", or "users" for
# USERS_FILE's "MAC STATUS REMAINING TOTAL FMT...".
#
# For "users" rows, a merge only ever happens when BOTH sides say
# "active" - a row that's merely "paused" is left exactly where it is
# (old MAC, untouched) rather than risk silently reactivating a session
# the customer hasn't asked to resume, or double-counting a balance
# against a mismatched state. That paused time isn't lost - it's just
# left recoverable under its old MAC instead of guessed at here.
#
# Same exclude-then-recommit safety idiom as _users_file_stage_excl
# elsewhere in this project (refuses to commit over a transient read
# error rather than risking a wipe). Returns 1 with the file untouched if
# there's no old-MAC row to reconcile, or if a collision exists that this
# function has deliberately chosen not to merge.
_mf_reconcile_row() {
    local file="$1" old="$2" new="$3" kind="$4"
    local old_row new_row rc=0 existed=0 now

    [ -e "$file" ] && existed=1
    old_row=$($BB grep "^${old} " "$file" 2>/dev/null | $BB head -1)
    [ -n "$old_row" ] || return 1
    new_row=$($BB grep "^${new} " "$file" 2>/dev/null | $BB head -1)

    if [ -n "$new_row" ] && [ "$kind" = "users" ]; then
        case "$old_row" in *" active "*) ;; *) return 1 ;; esac
        case "$new_row" in *" active "*) ;; *) return 1 ;; esac
    fi

    # Exclude both MACs' rows in two read-checked passes (rather than one
    # combined pattern) so a transient flash read glitch on the on-disk
    # file is still caught the same way _users_file_stage_excl catches it
    # - never silently committing a truncated/empty result over the live
    # file.
    $BB grep -v "^${old} " "$file" > "${file}.tmp" 2>/dev/null || rc=$?
    if [ "$existed" -eq 1 ] && [ "$rc" -gt 1 ]; then
        rm -f "${file}.tmp" 2>/dev/null
        return 1
    fi
    if [ -n "$new_row" ]; then
        rc=0
        $BB grep -v "^${new} " "${file}.tmp" > "${file}.tmp2" 2>/dev/null || rc=$?
        if [ "$rc" -gt 1 ]; then
            rm -f "${file}.tmp" "${file}.tmp2" 2>/dev/null
            return 1
        fi
        $BB mv "${file}.tmp2" "${file}.tmp"
    fi

    if [ -z "$new_row" ]; then
        # No collision - plain rename, every other field untouched.
        printf '%s\n' "${new}${old_row#"$old"}" >> "${file}.tmp"
    else
        case "$kind" in
            session)
                # "MAC EXPIRY TOTAL" - remaining is derived from EXPIRY.
                local o_exp o_tot n_exp n_tot o_rem n_rem
                now=$(_mf_now)
                o_exp=$($BB echo "$old_row" | $BB awk '{print $2}')
                o_tot=$($BB echo "$old_row" | $BB awk '{print $3}')
                n_exp=$($BB echo "$new_row" | $BB awk '{print $2}')
                n_tot=$($BB echo "$new_row" | $BB awk '{print $3}')
                o_rem=$(( o_exp - now )); [ "$o_rem" -lt 0 ] && o_rem=0
                n_rem=$(( n_exp - now )); [ "$n_rem" -lt 0 ] && n_rem=0
                [ -n "$o_tot" ] || o_tot=$o_rem
                [ -n "$n_tot" ] || n_tot=$n_rem
                printf '%s %d %d\n' "$new" "$(( now + o_rem + n_rem ))" "$(( o_tot + n_tot ))" >> "${file}.tmp"
                ;;
            users)
                # "MAC STATUS REMAINING TOTAL FMT..." - REMAINING is
                # already a remaining-seconds count, no EXPIRY math needed.
                local o_rem o_tot n_rem n_tot m_rem m_tot
                o_rem=$($BB echo "$old_row" | $BB awk '{print $3}')
                o_tot=$($BB echo "$old_row" | $BB awk '{print $4}')
                n_rem=$($BB echo "$new_row" | $BB awk '{print $3}')
                n_tot=$($BB echo "$new_row" | $BB awk '{print $4}')
                [ -n "$o_rem" ] || o_rem=0; [ "$o_rem" -lt 0 ] && o_rem=0
                [ -n "$n_rem" ] || n_rem=0; [ "$n_rem" -lt 0 ] && n_rem=0
                [ -n "$o_tot" ] || o_tot=$o_rem
                [ -n "$n_tot" ] || n_tot=$n_rem
                m_rem=$(( o_rem + n_rem ))
                m_tot=$(( o_tot + n_tot ))
                printf '%s active %d %d %s\n' "$new" "$m_rem" "$m_tot" "$(_mf_fmt_secs "$m_rem")" >> "${file}.tmp"
                ;;
            bank)
                # "MAC AMOUNT" - plain pesos, no time math needed. Always
                # summed on collision (unlike "users", there's no
                # active/paused state to worry about mismatching here).
                local o_amt n_amt
                o_amt=$($BB echo "$old_row" | $BB awk '{print $2}')
                n_amt=$($BB echo "$new_row" | $BB awk '{print $2}')
                [ -n "$o_amt" ] || o_amt=0
                [ -n "$n_amt" ] || n_amt=0
                printf '%s %d\n' "$new" "$(( o_amt + n_amt ))" >> "${file}.tmp"
                ;;
        esac
    fi

    $BB mv "${file}.tmp" "$file"
    return 0
}

# The entry point. Call once CLIENT_MAC is known and BEFORE the caller's own
# SESSION_FILE/USERS_FILE lookups. Always sets MF_COOKIE_HEADER (possibly to
# "") — the caller should print it, when non-empty, as part of its one
# header block (see login.sh/status.sh/logout.sh for the exact spot).
mf_reconcile() {
    MF_COOKIE_HEADER=""
    [ "${MAC_RANDOMIZATION_FIX:-1}" = "1" ] || return 0
    [ -n "$CLIENT_MAC" ] && [ "$CLIENT_MAC" != "00:00:00:00:00:00" ] || return 0

    if ! _mf_verify_cookie; then
        # First time we've seen this browser (or its old cookie didn't
        # verify) — mint a fresh identity. Same uptime+MAC+PID+RANDOM
        # entropy mix coin.sh uses for its SID generation.
        MF_FP_ID=$(printf '%s %s %s %d %d\n' \
            "$(cat /proc/uptime 2>/dev/null)" "$CLIENT_MAC" "$(date +%s 2>/dev/null)" "$$" "$RANDOM" \
            | sha256sum | awk '{print $1}')
    fi

    _lock
    PREV_MAC=$($BB grep "^${MF_FP_ID} " "$MACFIX_MAP_FILE" 2>/dev/null | $BB tail -1 | $BB awk '{print $2}')

    if [ -n "$PREV_MAC" ] && [ "$PREV_MAC" != "$CLIENT_MAC" ]; then
        # Same browser, different MAC than last time - exactly what a
        # reconnect-time MAC rotation looks like. CLIENT_MAC may already
        # have its own live row here too (e.g. it was paid for separately
        # before this browser's cookie tied the two MACs together) -
        # _mf_reconcile_row tells the two cases apart: no collision, just
        # rename PREV_MAC's row onto CLIENT_MAC; collision, combine the
        # remaining time from both into a single row under CLIENT_MAC. So
        # the caller's own "grep ^$CLIENT_MAC" below always finds exactly
        # one row, in both cases.
        if _mf_reconcile_row "$SESSION_FILE" "$PREV_MAC" "$CLIENT_MAC" session; then
            iptables -t nat -D HOTSPOT -m mac --mac-source "$PREV_MAC" -j RETURN 2>/dev/null
            iptables -t filter -D HOTSPOT_FWD -m mac --mac-source "$PREV_MAC" -j ACCEPT 2>/dev/null
            # Also drop any rule CLIENT_MAC already had of its own, so a
            # collision merge can never leave two RETURN/ACCEPT rules
            # stacked for the same MAC - a no-op in the plain-rename case,
            # where CLIENT_MAC never had one to begin with.
            iptables -t nat -D HOTSPOT -m mac --mac-source "$CLIENT_MAC" -j RETURN 2>/dev/null
            iptables -t filter -D HOTSPOT_FWD -m mac --mac-source "$CLIENT_MAC" -j ACCEPT 2>/dev/null
            iptables -t nat -I HOTSPOT 1 -m mac --mac-source "$CLIENT_MAC" -j RETURN 2>/dev/null
            iptables -t filter -I HOTSPOT_FWD 1 -m mac --mac-source "$CLIENT_MAC" -j ACCEPT 2>/dev/null
        fi
        _mf_reconcile_row "$USERS_FILE" "$PREV_MAC" "$CLIENT_MAC" users
        # Below-minimum-tier coin balance follows the browser too, same as
        # the session/users rows above — MACFIX_BANK_FILE is a fixed
        # constant (not caller-supplied), so this runs for every caller
        # regardless of whether SESSION_FILE/USERS_FILE were defined.
        _mf_reconcile_row "$MACFIX_BANK_FILE" "$PREV_MAC" "$CLIENT_MAC" bank
    fi

    # Keep the mapping current regardless: a first-ever sighting of this
    # fingerprint, or just a repeat visit on an unchanged MAC, both need
    # today's MAC/timestamp recorded so the next visit has something to
    # compare against.
    $BB grep -v "^${MF_FP_ID} " "$MACFIX_MAP_FILE" > "${MACFIX_MAP_FILE}.tmp" 2>/dev/null
    printf '%s %s %s\n' "$MF_FP_ID" "$CLIENT_MAC" "$(_mf_now)" >> "${MACFIX_MAP_FILE}.tmp"
    $BB mv "${MACFIX_MAP_FILE}.tmp" "$MACFIX_MAP_FILE"
    _unlock

    MF_COOKIE_HEADER="Set-Cookie: ${MACFIX_COOKIE_NAME}=${MF_FP_ID}.$(_mf_sign "$MF_FP_ID"); Path=/; Max-Age=${MACFIX_COOKIE_MAXAGE}; HttpOnly; SameSite=Lax"
}
