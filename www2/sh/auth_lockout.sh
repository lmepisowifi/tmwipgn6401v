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

# auth_lockout.sh — Global admin-login lockout state (www2 /login.html).
# Installed at: /lmepisowifi/www2/sh/auth_lockout.sh
#
# Deliberately NOT per-IP / per-session: a single shared counter in /tmp is
# the only source of truth for "how many wrong passwords in a row, from
# anyone" and "is everyone currently locked out". Once MAX_ATTEMPTS wrong
# passwords land (from any client), every client — including the real
# admin — is refused at auth.cgi until LOCK_SECONDS elapses. Per-IP counters
# would be trivial to sidestep (new tab/browser/incognito, or a different
# device on the LAN) and don't fit a single-admin box like this one.
#
# NOTE (trade-off, read before changing MAX_ATTEMPTS/LOCK_SECONDS): because
# this is global rather than per-IP, *anyone* who can reach /cgi-bin/auth.cgi
# can force a lockout for everyone (including the legitimate admin) just by
# submitting MAX_ATTEMPTS wrong passwords, and can keep doing so indefinitely.
# That's the intentional trade-off of "not IP based" — stronger against
# brute force, weaker against a deliberate nuisance lockout. Fine for this
# device's threat model (opportunistic brute force over reliably tripping
# up the one admin for 60s at a time); revisit if that stops being true.
#
# State file format: "<fail_count> <lock_until_epoch>" — lock_until is 0
# when there's no active lockout. Lives in /tmp (tmpfs), same as
# /tmp/sessions/*, so it resets on reboot; that's fine, a reboot already
# implies a different trust boundary (physical/console access).
#
# --lib mode: `. auth_lockout.sh --lib` sources just the functions below
# (used by auth.cgi and check_lockout.cgi) without running the CLI dispatch
# at the bottom. Same convention as lmehspt.sh --lib / ipacl.sh --lib.

[ "$1" = "--lib" ] && AUTH_LOCKOUT_LIB_ONLY=1

MAX_ATTEMPTS=5          # wrong passwords (from anyone) before global lockout
LOCK_SECONDS=60         # lockout duration once tripped
LOCKOUT_FILE="/tmp/login_lockout"

# Populates FAIL_COUNT / LOCK_UNTIL from disk. Missing or corrupt state is
# treated as "no failures yet" rather than erroring out.
lockout_read() {
    FAIL_COUNT=0
    LOCK_UNTIL=0
    [ -f "$LOCKOUT_FILE" ] || return 0
    _line=$(cat "$LOCKOUT_FILE" 2>/dev/null | busybox tr -d '\r\n')
    _c=$(printf '%s' "$_line" | busybox cut -d' ' -f1)
    _u=$(printf '%s' "$_line" | busybox cut -d' ' -f2)
    case "$_c" in *[!0-9]*|"") _c=0 ;; esac
    case "$_u" in *[!0-9]*|"") _u=0 ;; esac
    FAIL_COUNT=$_c
    LOCK_UNTIL=$_u
}

# Atomic write (mktemp + mv = single rename(), no truncation window for a
# concurrent reader) — same pattern used for /tmp/sessions/* elsewhere.
lockout_write() {
    _tmp=$(mktemp /tmp/.lockout.XXXXXX 2>/dev/null) || return 1
    printf '%s %s\n' "$1" "$2" > "$_tmp"
    busybox mv "$_tmp" "$LOCKOUT_FILE"
}

# Read-only status check. Prints "locked <secs_remaining>" or
# "ok <attempts_remaining>". Also self-heals an expired lockout back to a
# clean slate right here, server-side, so nobody has to trust a client to
# report its own expiry — this is what actually closes the original bug
# (client-tracked count drifting from reality).
lockout_status() {
    lockout_read
    _now=$(date +%s)
    if [ "$LOCK_UNTIL" -gt "$_now" ]; then
        echo "locked $((LOCK_UNTIL - _now))"
        return 0
    fi
    # Only clear state here when an actual lockout (LOCK_UNTIL set) has
    # expired. Do NOT reset just because FAIL_COUNT > 0 — this function is
    # called as the pre-check gate on every auth.cgi request (including the
    # one currently failing) and by check_lockout.cgi, so resetting on a
    # bare FAIL_COUNT wiped the counter back to 0 before every increment,
    # making "remaining" stick at MAX_ATTEMPTS-1 forever and the lockout
    # unreachable.
    if [ "$LOCK_UNTIL" -gt 0 ]; then
        lockout_write 0 0
        FAIL_COUNT=0
    fi
    echo "ok $((MAX_ATTEMPTS - FAIL_COUNT))"
}

# Records one failed login (call only after confirming the credentials were
# actually wrong). Prints the same "locked N" / "ok N" shape as above.
lockout_register_failure() {
    lockout_read
    _now=$(date +%s)
    # A lockout from a previous cycle already expired — this failure starts
    # a fresh cycle rather than piling onto the stale count.
    if [ "$LOCK_UNTIL" -gt 0 ] && [ "$LOCK_UNTIL" -le "$_now" ]; then
        FAIL_COUNT=0
        LOCK_UNTIL=0
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [ "$FAIL_COUNT" -ge "$MAX_ATTEMPTS" ]; then
        LOCK_UNTIL=$((_now + LOCK_SECONDS))
        lockout_write "$FAIL_COUNT" "$LOCK_UNTIL"
        echo "locked $LOCK_SECONDS"
    else
        lockout_write "$FAIL_COUNT" 0
        echo "ok $((MAX_ATTEMPTS - FAIL_COUNT))"
    fi
}

# Successful login — clears the cycle for everyone immediately. This is the
# other half of the fix: reset happens the moment a correct password is
# accepted, server-side, instead of depending on the browser reloading
# login.html afterwards (it never does — auth.cgi redirects straight to
# /index.html on success).
lockout_reset() {
    lockout_write 0 0
}

# ── CLI dispatch (skipped when sourced with --lib) ────────────────────────
if [ -z "$AUTH_LOCKOUT_LIB_ONLY" ]; then
    case "$1" in
        status) lockout_status ;;
        reset)  lockout_reset ;;
        *) echo "usage: auth_lockout.sh {status|reset}" ;;
    esac
fi
