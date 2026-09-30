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

# Proxy CGI — serves audio files from /lmepisowifi/hotspot/audio/ for the www2 admin panel.
# Auth is checked so only logged-in admins can access portal audio files.

SESSION_TIMEOUT=600
BROWSER_SESSION=$(echo "$HTTP_COOKIE" | busybox sed -n 's/.*session=\([^;]*\).*/\1/p' | busybox tr -d '\r\n')
BROWSER_SESSION=$(echo "$BROWSER_SESSION" | busybox tr -cd 'a-fA-F0-9')
SESSION_FILE="/tmp/sessions/$BROWSER_SESSION"

if [ -z "$BROWSER_SESSION" ] || [ ! -f "$SESSION_FILE" ]; then
    printf "Status: 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nForbidden"
    exit 0
fi

# SESSION_TIMEOUT was declared above but never enforced here, so a session
# cookie kept working on this endpoint long after it had expired everywhere
# else (expired session files are only swept at the next login). Same
# expiry rule as hotspot.cgi/check_auth.cgi; an empty file is a concurrent
# write in progress, not an expired session.
_LAST=$(cat "$SESSION_FILE" 2>/dev/null | busybox tr -d '\r\n')
_NOW=$(date +%s)
case "$_LAST" in "") _LAST=$_NOW ;; *[!0-9]*) _LAST=0 ;; esac
if [ $((_NOW - _LAST)) -gt $SESSION_TIMEOUT ]; then
    rm -f "$SESSION_FILE"
    printf "Status: 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nForbidden"
    exit 0
fi

# Sanitize: only alphanumeric, dot, underscore, hyphen — no path traversal
FILE=$(echo "$QUERY_STRING" | busybox sed -n 's/.*file=\([^&]*\).*/\1/p' | busybox tr -cd 'a-zA-Z0-9._-')
[ -z "$FILE" ] && { printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nBad Request"; exit 0; }

FULL_PATH="/lmepisowifi/hotspot/audio/$FILE"
[ -f "$FULL_PATH" ] || { printf "Status: 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot Found"; exit 0; }

case "$FILE" in
    *.mp3)  CT="audio/mpeg"  ;;
    *.ogg)  CT="audio/ogg"   ;;
    *.wav)  CT="audio/wav"   ;;
    *) printf "Status: 415 Unsupported Media Type\r\nContent-Type: text/plain\r\n\r\nUnsupported type"; exit 0 ;;
esac

SIZE=$(busybox wc -c < "$FULL_PATH" 2>/dev/null || echo 0)
printf "Status: 200 OK\r\nContent-Type: %s\r\nContent-Length: %s\r\nCache-Control: no-cache\r\nAccept-Ranges: bytes\r\n\r\n" "$CT" "$SIZE"
cat "$FULL_PATH"
