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

# ---- Auth ----
BROWSER_SESSION=$(echo "$HTTP_COOKIE" | busybox sed -n 's/.*session=\([^;]*\).*/\1/p' | busybox tr -d '\r\n')
# Sanitize: session IDs are sha256 hex. Strip anything else to block
# path traversal (e.g. Cookie: session=../../config/foo) into rm/mv/cat.
BROWSER_SESSION=$(printf '%s' "$BROWSER_SESSION" | busybox tr -cd 'a-fA-F0-9')
SESSION_FILE="/tmp/sessions/$BROWSER_SESSION"

if [ -z "$BROWSER_SESSION" ] || [ ! -f "$SESSION_FILE" ]; then
    printf "Status: 302 Found\r\n"
    printf "Location: /login.html\r\n\r\n"
    exit 0
fi

LAST=$(cat "$SESSION_FILE" 2>/dev/null | busybox tr -d '\r\n')
NOW=$(date +%s)
if [ $((NOW - LAST)) -gt $SESSION_TIMEOUT ]; then
    rm -f "$SESSION_FILE"
    printf "Status: 302 Found\r\n"
    printf "Location: /login.html\r\n\r\n"
    exit 0
fi
echo "$NOW" > "$SESSION_FILE"

# ==========================================
# Parse /proc/<iface>/sta_info -> JSON object list
# Emits a comma-separated list of {...} (no surrounding [ ]).
# ==========================================
parse_sta() {
    IFACE="$1"
    FILE="/proc/${IFACE}/sta_info"
    [ -f "$FILE" ] || return
    busybox cat "$FILE" 2>/dev/null | busybox awk -v iface="$IFACE" '
    function clean(s)   { gsub(/\r/,"",s); gsub(/^[ \t]+/,"",s); gsub(/[ \t]+$/,"",s); return s }
    function ejson(s)   { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s }
    function valof(line){ sub(/^[^:]*:[ \t]*/,"",line); return clean(line) }
    # sta_info reports link_time as "X hr Y min Z sec" (any subset of the
    # three units, e.g. "46 sec" or "36 min 46 sec"), not a raw seconds count.
    # Coercing that string straight to a number (old behavior: linktime+0)
    # only picks up the leading digits before the first unit, so "2 hr 36 min
    # 46 sec" became 2 -> displayed as "2s" instead of ~2h37m. Parse each
    # "<number> <unit>" pair and sum to total seconds instead.
    function parse_linktime(s,    n, arr, i, tot, unit, val) {
        tot = 0
        n = split(s, arr, /[ \t]+/)
        for (i = 1; i <= n; i++) {
            if (arr[i] ~ /^[0-9]+$/) {
                val = arr[i] + 0
                unit = (i < n) ? arr[i+1] : ""
                if      (unit ~ /^[Dd]/) tot += val * 86400
                else if (unit ~ /^[Hh]/) tot += val * 3600
                else if (unit ~ /^[Mm]/) tot += val * 60
                else if (unit ~ /^[Ss]/) tot += val
                else if (unit == "")     tot += val
            }
        }
        return tot
    }
    function flush() {
        if (mac == "") return
        # keep hex digits only, then format AA:BB:CC:DD:EE:FF
        hx = mac; gsub(/[^0-9a-fA-F]/, "", hx)
        if (length(hx) == 12) {
            fm = toupper(substr(hx,1,2)) ":" toupper(substr(hx,3,2)) ":" \
                 toupper(substr(hx,5,2)) ":" toupper(substr(hx,7,2)) ":" \
                 toupper(substr(hx,9,2)) ":" toupper(substr(hx,11,2))
            macraw = tolower(hx)
        } else {
            fm = clean(mac); macraw = tolower(hx)
        }
        bf = "false"
        if (bfee == "Y" || bfee == "y" || bfer == "Y" || bfer == "y" || (txbf != "" && txbf != "0")) bf = "true"
        if (out != "") out = out ","
        out = out sprintf("{\"iface\":\"%s\",\"mac\":\"%s\",\"macraw\":\"%s\",\"aid\":%d,\"rssi\":%d,\"sq\":%d,\"snr\":%d,\"txrate\":\"%s\",\"rxrate\":\"%s\",\"bw\":\"%s\",\"mode\":\"%s\",\"linktime\":%d,\"txbytes\":%.0f,\"rxbytes\":%.0f,\"bf\":%s}", \
            iface, ejson(fm), macraw, aid, rssi, sq, snr, ejson(txrate), ejson(rxrate), ejson(bw), ejson(mode), linktime, txbytes, rxbytes, bf)
        mac=""; aid=0; rssi=0; sq=0; snr=0; txrate=""; rxrate=""; bw=""; mode=""; linktime=0; txbytes=0; rxbytes=0; bfee=""; bfer=""; txbf=""
    }
    BEGIN { out=""; mac=""; aid=0; rssi=0; sq=0; snr=0; txrate=""; rxrate=""; bw=""; mode=""; linktime=0; txbytes=0; rxbytes=0; bfee=""; bfer=""; txbf="" }
    /^[ \t]*[0-9]+:[ \t]*stat/        { flush(); next }
    /^[ \t]*hwaddr:/                  { mac=valof($0); next }
    /^[ \t]*aid:/                     { aid=valof($0)+0; next }
    /^[ \t]*rssi:/                    { rssi=valof($0)+0; next }
    /^[ \t]*sq:/                      { sq=valof($0)+0; next }
    /^[ \t]*snr:/                     { snr=valof($0)+0; next }
    /^[ \t]*current_tx_rate:/         { txrate=valof($0); next }
    /^[ \t]*current_rx_rate:/         { rxrate=valof($0); next }
    /^[ \t]*current_tx_BW:/           { bw=valof($0); next }
    /^[ \t]*wireless mode:/           { mode=valof($0); next }
    /^[ \t]*link_time:/               { linktime=parse_linktime(valof($0)); next }
    /^[ \t]*tx_bytes:/                { txbytes=valof($0)+0; next }
    /^[ \t]*rx_bytes:/                { rxbytes=valof($0)+0; next }
    /^[ \t]*ht beamformee:/           { bfee=valof($0); next }
    /^[ \t]*ht beamformer:/           { bfer=valof($0); next }
    /^[ \t]*inTXBFEntry:/             { txbf=valof($0); next }
    END { flush(); printf "%s", out }
    '
}

# ==========================================
# GET  -> action=status : list all stations on wlan0 + wlan1
# ==========================================
if [ "$REQUEST_METHOD" = "GET" ]; then

    if echo "$QUERY_STRING" | busybox grep -q "action=status"; then
        S0=$(parse_sta wlan0)
        S1=$(parse_sta wlan1)
        if [ -n "$S0" ] && [ -n "$S1" ]; then
            ALL="$S0,$S1"
        elif [ -n "$S0" ]; then
            ALL="$S0"
        else
            ALL="$S1"
        fi
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"stations":[%s]}' "$ALL"
        exit 0
    fi

    printf "Status: 200 OK\r\n"
    printf "Content-Type: text/plain\r\n\r\n"
    printf "wlansta"
    exit 0
fi

# ==========================================
# POST -> action=disconnect : iwpriv <iface> del_sta <mac>
# ==========================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    # Clamp body size to stop a malicious Content-Length forcing a huge read.
    __CL="${CONTENT_LENGTH:-0}"; case "$__CL" in *[!0-9]*|"") __CL=0 ;; esac
    [ "$__CL" -gt 65536 ] && __CL=65536
    POST_DATA=$(busybox dd bs=1 count="$__CL" 2>/dev/null)
    ACTION=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*action=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')

    if [ "$ACTION" = "disconnect" ]; then
        IFACE=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*iface=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        case "$IFACE" in
            wlan0|wlan1) ;;
            *)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid interface"
                exit 0
                ;;
        esac

        MACRAW=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*mac=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        # Normalize: lowercase, keep only hex digits -> aabbccddeeff
        MAC=$(echo "$MACRAW" | busybox tr 'A-Z' 'a-z' | busybox sed 's/[^0-9a-f]//g')

        if [ ${#MAC} -ne 12 ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid MAC"
            exit 0
        fi

        iwpriv "$IFACE" del_sta "$MAC" > /dev/null 2>&1

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi
fi

printf "Status: 302 Found\r\n"
printf "Location: /wlansta.html\r\n\r\n"
