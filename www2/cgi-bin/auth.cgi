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


. /lmepisowifi/www2/sh/auth_lockout.sh --lib

# 0. Global lockout gate — checked first, before even reading the POST body.
#    Blocks EVERYONE (not just whichever client tripped it) until the
#    lockout expires, regardless of what credentials this request carries.
_LOCK_RES=$(lockout_status)
case "$_LOCK_RES" in
    locked*)
        _LOCK_SECS=$(printf '%s' "$_LOCK_RES" | busybox cut -d' ' -f2)
        printf "Status: 302 Found\r\n"
        printf "Location: /login.html?locked=1&secs=%s\r\n\r\n" "$_LOCK_SECS"
        exit 0
        ;;
esac

# A bare GET (no submitted credentials) isn't a login attempt — don't let it
# consume a slot in the failure counter, or anyone could grief-lock the
# admin by just repeatedly loading this URL.
if [ "$REQUEST_METHOD" != "POST" ]; then
    printf "Status: 302 Found\r\n"
    printf "Location: /login.html\r\n\r\n"
    exit 0
fi

# 1. Read POST data
# Clamp body size: reject non-numeric and cap to 64KB to stop a
# malicious Content-Length from forcing a huge/slow byte-by-byte read (DoS).
__CL="${CONTENT_LENGTH:-0}"; case "$__CL" in *[!0-9]*|"") __CL=0 ;; esac
[ "$__CL" -gt 65536 ] && __CL=65536
POST_DATA=$(busybox dd bs=1 count="$__CL" 2>/dev/null)

# 2. Extract and decode submitted credentials
FORM_USER=$(echo "$POST_DATA" | busybox sed -n 's/.*username=\([^&]*\).*/\1/p')
FORM_PASS=$(echo "$POST_DATA" | busybox sed -n 's/.*password=\([^&]*\).*/\1/p')
FORM_USER=$(busybox httpd -d "$FORM_USER" | busybox tr -d '\r\n')
FORM_PASS=$(busybox httpd -d "$FORM_PASS" | busybox tr -d '\r\n')

# 3. Get real credentials from MIB
REAL_USER=$(mib get SUSER_NAME | grep "^SUSER_NAME[[:space:]]*=" | busybox cut -d'=' -f2- | busybox tr -d '\r\n' | busybox sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
REAL_PASS=$(mib get SUSER_PASSWORD | grep "^SUSER_PASSWORD[[:space:]]*=" | busybox cut -d'=' -f2- | busybox tr -d '\r\n' | busybox sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# 4. Validate credentials
if [ -n "$FORM_USER" ] && [ "$FORM_USER" = "$REAL_USER" ] && [ "$FORM_PASS" = "$REAL_PASS" ]; then

    # Correct password — clear the global failure/lockout cycle immediately,
    # server-side, right here. This (not a client-side reload of login.html,
    # which never happens on success) is what keeps the next wrong password
    # from anyone starting from a stale count.
    lockout_reset

    # Generate unique session ID
    SESSION_ID=$(printf "%s%s%s" "$(date)" "$RANDOM" "$FORM_USER" | busybox sha256sum | busybox cut -d' ' -f1)

    # Ensure session directory exists and write timestamp for this session
    mkdir -p /tmp/sessions
    date +%s > "/tmp/sessions/$SESSION_ID"

    # Sweep expired sessions (older than 600s) to keep /tmp clean
    NOW=$(date +%s)
    for f in /tmp/sessions/*; do
        [ -f "$f" ] || continue
        LAST=$(cat "$f" 2>/dev/null | busybox tr -d '\r\n')
        [ -z "$LAST" ] && rm -f "$f" && continue
        [ $((NOW - LAST)) -gt 600 ] && rm -f "$f"
    done

    printf "Status: 302 Found\r\n"
    printf "Set-Cookie: session=%s; Path=/; HttpOnly; SameSite=Strict\r\n" "$SESSION_ID"
    printf "Location: /index.html\r\n\r\n"
else
    _FAIL_RES=$(lockout_register_failure)
    case "$_FAIL_RES" in
        locked*)
            _FAIL_SECS=$(printf '%s' "$_FAIL_RES" | busybox cut -d' ' -f2)
            printf "Status: 302 Found\r\n"
            printf "Location: /login.html?locked=1&secs=%s\r\n\r\n" "$_FAIL_SECS"
            ;;
        ok*)
            _REMAINING=$(printf '%s' "$_FAIL_RES" | busybox cut -d' ' -f2)
            printf "Status: 302 Found\r\n"
            printf "Location: /login.html?error=1&remaining=%s\r\n\r\n" "$_REMAINING"
            ;;
    esac
fi