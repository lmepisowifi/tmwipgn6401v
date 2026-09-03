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


SESSION_TIMEOUT=600

# ---------------------------------------------------------------
# Auth gate — same pattern as hotspot.cgi / modules.cgi
# ---------------------------------------------------------------
BROWSER_SESSION=$(echo "$HTTP_COOKIE" | busybox sed -n 's/.*session=\([^;]*\).*/\1/p' | busybox tr -d '\r\n')
BROWSER_SESSION=$(echo "$BROWSER_SESSION" | busybox tr -cd 'a-fA-F0-9')
SESSION_FILE="/tmp/sessions/$BROWSER_SESSION"
if [ -z "$BROWSER_SESSION" ] || [ ! -f "$SESSION_FILE" ]; then
    printf "Status: 302 Found\r\n"; printf "Location: /login.html\r\n\r\n"; exit 0
fi
LAST=$(cat "$SESSION_FILE" 2>/dev/null | busybox tr -d '\r\n')
NOW=$(date +%s); [ -z "$LAST" ] && LAST=$NOW
if [ $((NOW - LAST)) -gt $SESSION_TIMEOUT ]; then
    rm -f "$SESSION_FILE"; printf "Status: 302 Found\r\n"; printf "Location: /login.html\r\n\r\n"; exit 0
fi
_SESS_TMP=$(mktemp /tmp/sessions/.tmp.XXXXXX); echo "$NOW" > "$_SESS_TMP"; busybox mv "$_SESS_TMP" "$SESSION_FILE"

case "${CONTENT_LENGTH:-0}" in *[!0-9]*|"") CONTENT_LENGTH=0 ;; esac
[ "$CONTENT_LENGTH" -gt 4096 ] && CONTENT_LENGTH=4096

BB="busybox"
CTL="/lmepisowifi/tailscale/tailscale_ctl.sh"
ok_json()  { printf "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n%s" "$1"; exit 0; }
err_json() { printf "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n{\"ok\":false,\"error\":\"%s\"}" "$1"; exit 0; }

[ -x "$CTL" ] || $BB chmod +x "$CTL" 2>/dev/null
[ -x "$CTL" ] || err_json "module_not_installed"

QS="$QUERY_STRING"
ACT=$(echo "$QS" | $BB grep -o 'action=[^&]*' | $BB sed 's/action=//')

field() { printf '%s' "$1" | $BB tr '&' '\n' | $BB grep "^$2=" | $BB sed "s/^$2=//" | head -1; }
urldec() { $BB sed 's/+/ /g; s/%2[fF]/\//g; s/%2[cC]/,/g; s/%2[eE]/./g'; }

case "$ACT" in
    status)
        OUT=$("$CTL" status 2>/dev/null)
        [ -n "$OUT" ] && ok_json "$OUT" || err_json "status_failed"
        ;;
    set_config)
        read -n "$CONTENT_LENGTH" BODY
        # routes: comma-separated CIDRs — keep only digits . / ,
        ROUTES=$(field "$BODY" routes | urldec | $BB tr -cd '0-9./,')
        SSH=$(field "$BODY" ssh | $BB tr -cd '01' | cut -c1)
        [ "$SSH" = "1" ] || SSH=0
        EXIT_NODE=$(field "$BODY" exit_node | $BB tr -cd '01' | cut -c1)
        [ "$EXIT_NODE" = "1" ] || EXIT_NODE=0
        ACCEPT_ROUTES=$(field "$BODY" accept_routes | $BB tr -cd '01' | cut -c1)
        [ "$ACCEPT_ROUTES" = "1" ] || ACCEPT_ROUTES=0
        ACCEPT_DNS=$(field "$BODY" accept_dns | $BB tr -cd '01' | cut -c1)
        [ "$ACCEPT_DNS" = "1" ] || ACCEPT_DNS=0
        # hostname: DNS label chars only, lowercased, capped at 63 (max label length)
        HOST_NAME=$(field "$BODY" hostname | urldec | $BB tr 'A-Z' 'a-z' | $BB tr -cd 'a-z0-9-' | cut -c1-63)
        # tags: comma-separated "tag:name" entries per Tailscale ACL syntax
        TAGS=$(field "$BODY" tags | urldec | $BB tr 'A-Z' 'a-z' | $BB tr -cd 'a-z0-9:,-')
        OUT=$("$CTL" set-config "$ROUTES" "$SSH" "$EXIT_NODE" "$ACCEPT_ROUTES" "$ACCEPT_DNS" "$HOST_NAME" "$TAGS" 2>/dev/null)
        [ -n "$OUT" ] && ok_json "$OUT" || err_json "set_config_failed"
        ;;
    set_enabled)
        read -n "$CONTENT_LENGTH" BODY
        EN=$(field "$BODY" enabled | $BB tr -cd '01' | cut -c1); [ "$EN" = "1" ] || EN=0
        OUT=$("$CTL" set-enabled "$EN" 2>/dev/null)
        [ -n "$OUT" ] && ok_json "$OUT" || err_json "set_enabled_failed"
        ;;
    logout)
        OUT=$("$CTL" logout 2>/dev/null)
        [ -n "$OUT" ] && ok_json "$OUT" || err_json "logout_failed"
        ;;
    refresh)
        OUT=$("$CTL" up 2>/dev/null)
        [ -n "$OUT" ] && ok_json "$OUT" || err_json "refresh_failed"
        ;;
    *)
        err_json "unknown_action"
        ;;
esac
