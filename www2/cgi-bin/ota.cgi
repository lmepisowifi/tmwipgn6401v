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

# ota.cgi — admin-UI front end for /lmepisowifi/ota.sh
# Auth model matches lme.cgi / check_auth.cgi (session cookie -> /tmp/sessions/<hex>).

OTA="/lmepisowifi/ota.sh"
STATUS_FILE="/tmp/ota_status"
LOG="/tmp/ota.log"
VERSION_FILE="/lmepisowifi/VERSION"
SESSION_TIMEOUT=600

# ---- auth gate -------------------------------------------------------------
BROWSER_SESSION=$(echo "$HTTP_COOKIE" | busybox sed -n 's/.*session=\([^;]*\).*/\1/p' | busybox tr -d '\r\n')
BROWSER_SESSION=$(printf '%s' "$BROWSER_SESSION" | busybox tr -cd 'a-fA-F0-9')
SESSION_FILE="/tmp/sessions/$BROWSER_SESSION"
_deny() { printf "Status: 401 Unauthorized\r\nContent-Type: text/plain\r\n\r\nunauthorized"; exit 0; }
[ -z "$BROWSER_SESSION" ] && _deny
[ -f "$SESSION_FILE" ] || _deny
LAST=$(cat "$SESSION_FILE" 2>/dev/null | busybox tr -d '\r\n'); NOW=$(date +%s)
[ -z "$LAST" ] && LAST=$NOW
[ $((NOW - LAST)) -gt $SESSION_TIMEOUT ] && { rm -f "$SESSION_FILE"; _deny; }
# refresh session (atomic)
_T=$(mktemp /tmp/sessions/.tmp.XXXXXX); echo "$NOW" > "$_T"; busybox mv "$_T" "$SESSION_FILE"

json_hdr() { printf "Content-Type: application/json\r\n\r\n"; }
text_hdr() { printf "Content-Type: text/plain\r\n\r\n"; }
json_esc() { printf '%s' "$1" | busybox sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ---- POST body (for apply/rollback) ----
POST=""
if [ "$REQUEST_METHOD" = "POST" ]; then
    [ -n "$CONTENT_LENGTH" ] && POST=$(head -c "$CONTENT_LENGTH")
fi
qs_has() { echo "$QUERY_STRING" | busybox grep -q "$1"; }

# ---- dispatch --------------------------------------------------------------
if [ "$REQUEST_METHOD" = "GET" ]; then

    if qs_has "action=check"; then
        json_hdr
        sh "$OTA" check 2>/dev/null
        exit 0
    fi

    if qs_has "action=status"; then
        _st=$(cat "$STATUS_FILE" 2>/dev/null); [ -z "$_st" ] && _st="idle"
        _ver=$(busybox tr -d ' \t\r\n' < "$VERSION_FILE" 2>/dev/null)
        json_hdr
        printf '{"status":"%s","version":"%s"}\n' "$(json_esc "$_st")" "$(json_esc "$_ver")"
        exit 0
    fi

    if qs_has "action=config"; then
        _auto=$(sh "$OTA" get_auto 2>/dev/null); [ -z "$_auto" ] && _auto="0"
        json_hdr
        printf '{"auto":"%s"}\n' "$(json_esc "$_auto")"
        exit 0
    fi

    if qs_has "action=changelog"; then
        text_hdr
        sh "$OTA" changelog 2>/dev/null
        exit 0
    fi

    if qs_has "action=log"; then
        text_hdr
        tail -c 8000 "$LOG" 2>/dev/null
        exit 0
    fi

    json_hdr; printf '{"error":"unknown action"}\n'; exit 0
fi

if [ "$REQUEST_METHOD" = "POST" ]; then

    if echo "$QUERY_STRING $POST" | busybox grep -q "action=apply"; then
        # optional explicit version: version=1.2.3
        VER=$(echo "$POST" | busybox sed -n 's/.*version=\([0-9.][0-9.]*\).*/\1/p')
        printf 'started' > "$STATUS_FILE"
        # detach so it survives the www2 httpd restart that apply performs
        ( setsid sh "$OTA" apply "$VER" >/tmp/ota.log 2>&1 & ) 2>/dev/null || \
            ( sh "$OTA" apply "$VER" >/tmp/ota.log 2>&1 & )
        text_hdr; printf 'OK'; exit 0
    fi

    if echo "$QUERY_STRING $POST" | busybox grep -q "action=rollback"; then
        ( setsid sh "$OTA" rollback >/tmp/ota.log 2>&1 & ) 2>/dev/null || \
            ( sh "$OTA" rollback >/tmp/ota.log 2>&1 & )
        text_hdr; printf 'OK'; exit 0
    fi

    if echo "$QUERY_STRING $POST" | busybox grep -q "action=setauto"; then
        AUTO=$(echo "$POST" | busybox sed -n 's/.*auto=\([01]\).*/\1/p'); [ -z "$AUTO" ] && AUTO=0
        _v=$(sh "$OTA" set_auto "$AUTO" 2>/dev/null)
        json_hdr; printf '{"auto":"%s"}\n' "$_v"; exit 0
    fi

    text_hdr; printf 'unknown action'; exit 0
fi

text_hdr; printf 'method not allowed'
