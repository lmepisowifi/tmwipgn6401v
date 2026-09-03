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

# mibconfig.cgi — MIB configuration backup/restore
#
# GET  ?action=list                              -> {ok,files:{current,hs,default}} size+mtime for each
# GET  ?action=download&file=current|hs|default   -> streams the raw XML file for download
# POST ?action=upload  body: target=current|hs & data=<base64 xml>
#       -> writes the file, syncs, then reboots the device so the config
#          engine re-parses it at boot. default (config_custom_default.xml)
#          is download-only from this page — never an upload target.

SESSION_TIMEOUT=600
BB=busybox

# ── Auth ──────────────────────────────────────────────────────────────────────
BROWSER_SESSION=$(echo "$HTTP_COOKIE" \
    | $BB sed -n 's/.*session=\([^;]*\).*/\1/p' \
    | $BB tr -d '\r\n')
BROWSER_SESSION=$(printf '%s' "$BROWSER_SESSION" \
    | $BB tr -cd 'a-fA-F0-9')
SESSION_FILE="/tmp/sessions/$BROWSER_SESSION"

if [ -z "$BROWSER_SESSION" ] || [ ! -f "$SESSION_FILE" ]; then
    printf "Status: 302 Found\r\nLocation: /login.html\r\n\r\n"
    exit 0
fi

LAST=$(cat "$SESSION_FILE" 2>/dev/null | $BB tr -d '\r\n')
NOW=$(date +%s)
[ -z "$LAST" ] && LAST=$NOW
if [ $((NOW - LAST)) -gt $SESSION_TIMEOUT ]; then
    rm -f "$SESSION_FILE"
    printf "Status: 302 Found\r\nLocation: /login.html\r\n\r\n"
    exit 0
fi

_STMP=$(mktemp /tmp/sessions/.tmp.XXXXXX)
echo "$NOW" > "$_STMP"
$BB mv "$_STMP" "$SESSION_FILE"

# ── Helpers ───────────────────────────────────────────────────────────────────
err_json() { printf "Status: 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"ok\":false,\"error\":\"%s\"}" "$1"; exit 0; }
ok_json()  { printf "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n%s" "$1"; exit 0; }

urldecode() {
    $BB awk '
    BEGIN {
        for (i = 0; i <= 255; i++) hx[sprintf("%02x", i)] = sprintf("%c", i)
        for (i = 0; i <= 255; i++) hx[sprintf("%02X", i)] = sprintf("%c", i)
    }
    {
        s = $0
        gsub(/\+/, " ", s)
        n = split(s, a, "%")
        out = a[1]
        for (i = 2; i <= n; i++) {
            h = substr(a[i], 1, 2)
            if (length(a[i]) >= 2 && (h in hx)) {
                out = out hx[h] substr(a[i], 3)
            } else {
                out = out "%" a[i]
            }
        }
        print out
    }'
}

# file key -> real on-device path. current/hs live on the flash-backed
# config partition; default is the read-only-from-here factory reference
# copy (download only — path_for is still used for it, but the upload
# action never accepts "default" as a target, enforced below).
path_for() {
    case "$1" in
        current) printf '/config/config.xml' ;;
        hs)      printf '/config/config_hs.xml' ;;
        default) printf '/config/config_custom_default.xml' ;;
        *)       printf '' ;;
    esac
}

QS="$QUERY_STRING"

# Clamp body size for the base64 upload: generous headroom for a config
# dump, well short of anything that would strain the device.
case "${CONTENT_LENGTH:-0}" in *[!0-9]*|"") CONTENT_LENGTH=0 ;; esac
[ "$CONTENT_LENGTH" -gt 20971520 ] && CONTENT_LENGTH=20971520

# ================================================================
# GET ?action=list
# ================================================================
if echo "$QS" | $BB grep -q "action=list"; then
    OUT="{"; SEP=""
    for KEY in current hs default; do
        P=$(path_for "$KEY")
        if [ -f "$P" ]; then
            SZ=$($BB stat -c '%s' "$P" 2>/dev/null); [ -z "$SZ" ] && SZ=0
            MT=$($BB stat -c '%Y' "$P" 2>/dev/null); [ -z "$MT" ] && MT=0
            OUT="${OUT}${SEP}\"$KEY\":{\"exists\":true,\"size\":$SZ,\"mtime\":$MT}"
        else
            OUT="${OUT}${SEP}\"$KEY\":{\"exists\":false}"
        fi
        SEP=","
    done
    OUT="${OUT}}"
    ok_json "{\"ok\":true,\"files\":$OUT}"
fi

# ================================================================
# GET ?action=download&file=current|hs|default
# ================================================================
if echo "$QS" | $BB grep -q "action=download"; then
    FILEKEY=$(echo "$QS" | $BB sed -n 's/.*file=\([^&]*\).*/\1/p' | $BB tr -cd 'a-z')
    TARGET_PATH=$(path_for "$FILEKEY")

    if [ -z "$TARGET_PATH" ]; then
        printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nInvalid file key"
        exit 0
    fi
    if [ ! -f "$TARGET_PATH" ]; then
        printf "Status: 404 Not Found\r\nContent-Type: text/plain\r\n\r\nConfig file not found on this device"
        exit 0
    fi

    FNAME=$($BB basename "$TARGET_PATH")
    printf "Status: 200 OK\r\n"
    printf "Content-Type: application/xml; charset=utf-8\r\n"
    printf "Content-Disposition: attachment; filename=\"%s\"\r\n" "$FNAME"
    printf "\r\n"
    $BB cat "$TARGET_PATH"
    exit 0
fi

# ================================================================
# POST ?action=upload   body: target=current|hs & data=<base64 xml>
# Overwrites the target config file, syncs it to flash, then reboots so
# the config engine re-parses it — same "confirm=1"-free sync+reboot
# idiom action=reboot in lme.cgi already uses.
# ================================================================
if echo "$QS" | $BB grep -q "action=upload"; then
    read -n "$CONTENT_LENGTH" POST_DATA

    fget() {
        printf '%s' "$POST_DATA" \
            | $BB tr '&' '\n' \
            | $BB grep "^$1=" \
            | $BB sed 's/^[^=]*=//' \
            | urldecode \
            | head -1
    }

    TARGET=$(fget target | $BB tr -cd 'a-z')
    case "$TARGET" in current|hs) ;; *) err_json "bad_target" ;; esac

    # Base64 only ever percent-encodes +, /, = — decode those with sed
    # instead of running the whole payload through the character-by-
    # character urldecode awk loop.
    B64=$(printf '%s' "$POST_DATA" \
        | $BB tr '&' '\n' \
        | $BB grep "^data=" \
        | $BB sed 's/^data=//; s/%2B/+/g; s/%2F/\//g; s/%3D/=/g; s/%2b/+/g; s/%2f/\//g; s/%3d/=/g')
    [ -z "$B64" ] && err_json "no_data"

    TARGET_PATH=$(path_for "$TARGET")
    TMP="${TARGET_PATH}.upload.tmp"

    if ! printf '%s' "$B64" | $BB base64 -d > "$TMP" 2>/dev/null; then
        printf '%s' "$B64" | openssl enc -d -base64 -A > "$TMP" 2>/dev/null \
            || { rm -f "$TMP"; err_json "decode_failed"; }
    fi

    # Sanity gate: this device's MIB config dump always wraps in a
    # Config_Information_File_* root element. Reject anything else before
    # it gets anywhere near overwriting a file the bootloader parses -
    # a malformed config here can strand the device on next boot.
    if ! $BB head -c 4096 "$TMP" | $BB grep -q "Config_Information_File"; then
        rm -f "$TMP"
        err_json "not_a_mib_config"
    fi

    # Disk-space guard, same floor style as the portal image/audio uploads.
    _av_kb=$($BB df -k /config 2>/dev/null | $BB awk 'NR==2 {print $4+0}')
    _av_bytes=$(( ${_av_kb:-0} * 1024 ))
    _upload_size=$($BB wc -c < "$TMP" 2>/dev/null | $BB tr -d ' ')
    if [ $(( _av_bytes - ${_upload_size:-0} )) -lt 5242880 ]; then
        rm -f "$TMP"
        err_json "insufficient_space"
    fi

    # Best-effort rolling backup of whatever is being replaced.
    [ -f "$TARGET_PATH" ] && cp "$TARGET_PATH" "${TARGET_PATH}.bak" 2>/dev/null

    $BB mv "$TMP" "$TARGET_PATH"
    sync

    # Response must go out before the background job fires - ok_json()
    # exits immediately, which would skip the reboot trigger if it ran first.
    printf "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n{\"ok\":true,\"target\":\"$TARGET\",\"rebooting\":true}"
    ( sleep 1; sync; reboot ) &
    exit 0
fi

printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nUnknown action"
