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

# bootpart.cgi — admin-UI front end for /lmepisowifi/www2/sh/fwboot.sh
# (bootpart.html = boot-slot manager / downloader, fwupload.html = tar upload).
# Auth model matches ota.cgi / lme.cgi (session cookie -> /tmp/sessions/<hex>).
#
#   GET  ?action=status | log | dump&slot=0|1&part=kernel|rootfs
#   POST ?action=setdefault&slot=N | bootonce&slot=N&keep=0|1 | cancel | reboot
#   POST ?action=upload      body = the raw .tar (Content-Length required)
#   POST ?action=fetch       body = url=<urlencoded https URL>
#   POST ?action=flash&slot=N | discard

FW="/lmepisowifi/www2/sh/fwboot.sh"
WORK="${FWBOOT_WORK:-/tmp/fwboot}"
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

json_hdr() { printf "Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n"; }
text_hdr() { printf "Content-Type: text/plain\r\nCache-Control: no-store\r\n\r\n"; }
jerr()     { json_hdr; printf '{"ok":false,"error":"%s"}\n' "$1"; exit 0; }

# Query values that are used as selectors are reduced to [a-z0-9]; the helper
# script validates them again, so nothing from the request reaches a shell
# unquoted.
qparam() {
    printf '%s' "$QUERY_STRING" | busybox tr '&' '\n' | busybox sed -n "s/^$1=//p" | busybox head -n 1 | busybox tr -cd 'a-z0-9'
}
ACTION=$(qparam action)
SLOT=$(qparam slot)
PART=$(qparam part)
KEEP=$(qparam keep)

is_busy() { sh "$FW" status 2>/dev/null | busybox grep -q '"busy":true'; }

# ---- GET -------------------------------------------------------------------
if [ "$REQUEST_METHOD" = "GET" ]; then
    case "$ACTION" in
        status) json_hdr; sh "$FW" status; exit 0 ;;
        log)    text_hdr; sh "$FW" log; exit 0 ;;
        dump)
            DEV=$(sh "$FW" devpath "$SLOT" "$PART" 2>/dev/null)
            [ -n "$DEV" ] && [ -r "$DEV" ] || jerr "no such partition"
            printf 'Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename="slot%s-%s.bin"\r\nCache-Control: no-store\r\n\r\n' "$SLOT" "$PART"
            exec cat "$DEV"
            ;;
    esac
    jerr "unknown action"
fi

# ---- POST ------------------------------------------------------------------
if [ "$REQUEST_METHOD" = "POST" ]; then
    mkdir -p "$WORK"
    case "$ACTION" in
        setdefault) json_hdr; sh "$FW" setdefault "$SLOT"; exit 0 ;;
        bootonce)   json_hdr; sh "$FW" bootonce "$SLOT" "$KEEP"; exit 0 ;;
        cancel)     json_hdr; sh "$FW" cancel; exit 0 ;;
        discard)    json_hdr; sh "$FW" discard; exit 0 ;;
        reboot)     json_hdr; sh "$FW" reboot; exit 0 ;;

        upload)
            # Raw body -> file. Content-Length is mandatory so a truncated
            # transfer is detected instead of being flashed.
            case "$CONTENT_LENGTH" in ""|*[!0-9]*) jerr "missing Content-Length" ;; esac
            [ "$CONTENT_LENGTH" -gt 0 ] || jerr "empty upload"
            [ "$CONTENT_LENGTH" -le 67108864 ] || jerr "file is larger than 64 MiB"
            is_busy && jerr "another firmware operation is running"
            AVAIL=$(df -k "$WORK" 2>/dev/null | busybox tail -n 1 | busybox awk '{print $(NF-2)}')
            NEED=$(( CONTENT_LENGTH / 1024 + 4096 ))
            case "$AVAIL" in ""|*[!0-9]*) ;; *)
                [ "$AVAIL" -ge "$NEED" ] || jerr "not enough free memory to stage the file (need ${NEED} KB, have ${AVAIL} KB)" ;;
            esac
            rm -f "$WORK/upload.tar" "$WORK/meta"
            printf 'verifying' > "$WORK/state"; printf 'Receiving upload' > "$WORK/msg"
            busybox head -c "$CONTENT_LENGTH" > "$WORK/upload.tar.part" 2>/dev/null
            GOT=$(busybox wc -c < "$WORK/upload.tar.part" 2>/dev/null | busybox tr -d ' ')
            if [ "$GOT" != "$CONTENT_LENGTH" ]; then
                rm -f "$WORK/upload.tar.part"; printf 'error' > "$WORK/state"; printf 'Upload was cut short' > "$WORK/msg"
                jerr "upload was cut short ($GOT of $CONTENT_LENGTH bytes)"
            fi
            busybox mv "$WORK/upload.tar.part" "$WORK/upload.tar"
            json_hdr
            sh "$FW" check
            exit 0
            ;;

        fetch)
            POST=""; [ -n "$CONTENT_LENGTH" ] && POST=$(busybox head -c "$CONTENT_LENGTH")
            RAW=$(printf '%s' "$POST" | busybox sed -n 's/^.*url=\([^&]*\).*$/\1/p')
            URL=$(busybox httpd -d "$RAW" | busybox tr -d '\r\n')
            [ -n "$URL" ] || jerr "missing url"
            is_busy && jerr "another firmware operation is running"
            printf 'downloading' > "$WORK/state"; printf 'Starting download' > "$WORK/msg"
            # detach: the download outlives this request
            ( setsid sh "$FW" fetch "$URL" >/dev/null 2>&1 & ) 2>/dev/null || \
                ( sh "$FW" fetch "$URL" >/dev/null 2>&1 & )
            json_hdr; printf '{"ok":true}\n'; exit 0
            ;;

        flash)
            case "$SLOT" in 0|1) ;; *) jerr "slot must be 0 or 1" ;; esac
            is_busy && jerr "another firmware operation is running"
            printf 'flashing' > "$WORK/state"; printf 'Starting' > "$WORK/msg"
            ( setsid sh "$FW" flash "$SLOT" >/dev/null 2>&1 & ) 2>/dev/null || \
                ( sh "$FW" flash "$SLOT" >/dev/null 2>&1 & )
            json_hdr; printf '{"ok":true}\n'; exit 0
            ;;
    esac
    jerr "unknown action"
fi

printf "Status: 405 Method Not Allowed\r\nContent-Type: text/plain\r\n\r\nmethod not allowed"
