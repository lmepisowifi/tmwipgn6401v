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

# ---- Band key selection ----
band_keys() {
    if [ "$1" = "24" ]; then
        MODE_KEY="WLAN1_MACAC_ENABLED"
        TABLE_KEY="WLAN1_AC_TBL"
        WLAN_IDX="1"
    else
        MODE_KEY="WLAN_MACAC_ENABLED"
        TABLE_KEY="WLAN_AC_TBL"
        WLAN_IDX="0"
    fi
}

# ---- Get wlanDisabled flag (0=up, 1=off) for a band ----
get_wlan_disabled() {
    if [ "$1" = "24" ]; then
        DIS_KEY="WLAN1_MBSSIB_TBL.0.wlanDisabled"
    else
        DIS_KEY="WLAN_MBSSIB_TBL.0.wlanDisabled"
    fi
    mib get "$DIS_KEY" 2>/dev/null \
        | busybox grep "=" \
        | busybox cut -d'=' -f2- \
        | busybox tr -d '\r\n'
}

# ---- Get filter mode integer (0/1/2) for a band ----
get_mode() {
    band_keys "$1"
    mib get "$MODE_KEY" 2>/dev/null \
        | busybox grep "=" \
        | busybox awk -F= '{gsub(/ /,"",$2); print $2}' \
        | busybox tr -d '\r\n'
}

# ---- Emit MAC list as a JSON array ----
get_mac_json() {
    TABLE=$1
    mib get "$TABLE" 2>/dev/null | busybox awk -v tbl="$TABLE" '
    BEGIN { out = ""; sep = "" }
    {
        if (index($0, tbl ".") == 1 && substr($0, length($0), 1) == ":") {
            s = substr($0, length(tbl) + 2)
            sub(/:.*/, "", s)
            idx = s
        }
        if ($0 ~ /MacAddr[ \t]*=[ \t]*[0-9a-fA-F]/) {
            mac = $NF
            gsub(/\r/, "", mac)
            fmt = toupper(substr(mac,1,2))  ":" toupper(substr(mac,3,2))  ":" \
                  toupper(substr(mac,5,2))  ":" toupper(substr(mac,7,2))  ":" \
                  toupper(substr(mac,9,2))  ":" toupper(substr(mac,11,2))
            out = out sep "{\"idx\":" idx ",\"mac\":\"" fmt "\"}"
            sep = ","
        }
    }
    END { print "[" out "]" }
    '
}

# ---- Normalize MAC: lowercase, strip everything except hex digits ----
# FIXED: old code used `tr -d ':- \r\n'` where the ':- ' was interpreted as the
# character range from ' ' (32) to ':' (58) by busybox tr, deleting digits 0-9.
# Now we use sed to keep only [0-9a-f] after lowercasing.
normalize_mac() {
    echo "$1" | busybox tr 'A-Z' 'a-z' | busybox tr -d '\r\n' | busybox sed 's/[^0-9a-f]//g'
}

# ==========================================
# GET
# ==========================================
if [ "$REQUEST_METHOD" = "GET" ]; then

    if echo "$QUERY_STRING" | busybox grep -q "action=status"; then
        MODE24=$(get_mode "24")
        MODE5=$(get_mode "5")
        [ -z "$MODE24" ] && MODE24=0
        [ -z "$MODE5"  ] && MODE5=0
        MACS24=$(get_mac_json "WLAN1_AC_TBL")
        MACS5=$(get_mac_json "WLAN_AC_TBL")
        DIS24=$(get_wlan_disabled "24")
        [ -z "$DIS24" ] && DIS24=0
        DIS5=$(get_wlan_disabled "5")
        [ -z "$DIS5" ] && DIS5=0
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"band24":{"mode":%s,"macs":%s,"disabled":%s},"band5":{"mode":%s,"macs":%s,"disabled":%s}}' \
            "$MODE24" "$MACS24" "$DIS24" "$MODE5" "$MACS5" "$DIS5"
        exit 0
    fi

    # ---- action=clientcheck ----
    if echo "$QUERY_STRING" | busybox grep -q "action=clientcheck"; then
    # Extract the IP and strip IPv6 mapping junk
RAW_IP=$(echo "$REMOTE_ADDR" | busybox tr -d '\r\n')
# This sed command removes [::ffff: and any closing ]
CLIENT_IP=$(echo "$RAW_IP" | busybox sed 's/.*[: \[]//; s/\]//g')
        CLIENT_MAC_FOUND="false"
        CLIENT_MAC_FMT=""

        # 1. Collect MACs into a clean, newline-separated list
        # We remove 'tr -d \r\n' to keep them as individual lines
        STA_MACS=$(cat /proc/wlan*/sta_info 2>/dev/null \
            | busybox grep 'hwaddr' \
            | busybox awk '{print toupper($NF)}' \
            | busybox tr -d ':')

        if [ -n "$STA_MACS" ]; then
            # 2. Get ARP MAC from /proc/net/arp
            ARP_MAC=$(busybox awk -v ip="$CLIENT_IP" \
                'NR>1 && $1==ip {print $4; exit}' /proc/net/arp 2>/dev/null \
                | busybox tr -d '\r\n')

            # Fallback to arp command
            if [ -z "$ARP_MAC" ]; then
                ARP_MAC=$(arp 2>/dev/null \
                    | busybox awk -v ip="$CLIENT_IP" '$1==ip{print $3;exit}' \
                    | busybox tr -d '\r\n')
            fi

            if [ -n "$ARP_MAC" ] && [ "$ARP_MAC" != "00:00:00:00:00:00" ]; then
                # 3. Normalize for comparison
                ARP_NORM=$(echo "$ARP_MAC" | busybox tr 'a-f' 'A-F' | busybox tr -dc '0-9A-F')
                
                # 4. Use -qFx for an exact line-by-line match
                # -F: literal string, -x: whole line match
                if [ ${#ARP_NORM} -eq 12 ] && echo "$STA_MACS" | busybox grep -qFx "$ARP_NORM"; then
                    CLIENT_MAC_FOUND="true"
                    # Format as AA:BB:CC:DD:EE:FF for the JSON response
                    CLIENT_MAC_FMT=$(echo "$ARP_NORM" | busybox awk '{
                        print substr($0,1,2) ":" substr($0,3,2) ":" substr($0,5,2) ":" \
                              substr($0,7,2) ":" substr($0,9,2) ":" substr($0,11,2)
                    }')
                fi
            fi
        fi
        echo "MAC: $CLIENT_MAC_FMT IP: $CLIENT_IP" > /tmp/debug.txt
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"mac":"%s","ip":"%s","found":%s}' \
            "$CLIENT_MAC_FMT" "$CLIENT_IP" "$CLIENT_MAC_FOUND"
        exit 0
    fi


    printf "Status: 200 OK\r\n"
    printf "Content-Type: text/plain\r\n\r\n"
    printf "wlanmac"
    exit 0
fi

# ==========================================
# POST
# ==========================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    # Clamp body size: reject non-numeric and cap to 64KB to stop a
    # malicious Content-Length from forcing a huge/slow byte-by-byte read (DoS).
    __CL="${CONTENT_LENGTH:-0}"; case "$__CL" in *[!0-9]*|"") __CL=0 ;; esac
    [ "$__CL" -gt 65536 ] && __CL=65536
    POST_DATA=$(busybox dd bs=1 count="$__CL" 2>/dev/null)
    ACTION=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*action=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')

    # action=setmode
    if [ "$ACTION" = "setmode" ]; then
        BAND=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*band=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        MODE=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*mode=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')

        case "$BAND" in
            24|5) ;;
            *)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid band"
                exit 0
                ;;
        esac

        case "$MODE" in
            0|1|2) ;;
            *)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid mode"
                exit 0
                ;;
        esac

        band_keys "$BAND"
        mib set "$MODE_KEY" "$MODE"
        mib commit

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"

        WLAN_DIS=$(get_wlan_disabled "$BAND")
        if [ "${WLAN_DIS:-0}" = "0" ]; then
            ( wlan_apply restart ) &
        fi
        exit 0
    fi

    # action=addmac
    if [ "$ACTION" = "addmac" ]; then
        BAND=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*band=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        MAC_IN_RAW=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*mac=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        MAC_IN=$(busybox httpd -d "$MAC_IN_RAW" | busybox tr -d '\r\n')

        case "$BAND" in
            24|5) ;;
            *)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid band"
                exit 0
                ;;
        esac

        MAC_NORM=$(normalize_mac "$MAC_IN")
        VALID=$(echo "$MAC_NORM" | busybox awk '/^[0-9a-f]{12}$/{print "1"}')
        if [ "$VALID" != "1" ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid MAC address (expected 12 hex digits, e.g. AA:BB:CC:DD:EE:FF)"
            exit 0
        fi

        band_keys "$BAND"

        if mib get "$TABLE_KEY" 2>/dev/null \
                | busybox grep -i "MacAddr" \
                | busybox grep -qi "$MAC_NORM"; then
            printf "Status: 409 Conflict\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "MAC address already in list"
            exit 0
        fi

        ADD_OUT=$(mib add "$TABLE_KEY" 2>/dev/null)
        NEW_NUM=$(echo "$ADD_OUT" \
            | busybox grep "NUM=" \
            | busybox awk -F= '{print $2}' \
            | busybox tr -d ' \r\n')
        NEW_IDX=$((NEW_NUM - 1))

        mib set "${TABLE_KEY}.${NEW_IDX}.wlanIdx" "$WLAN_IDX"
        mib set "${TABLE_KEY}.${NEW_IDX}.MacAddr" "$MAC_NORM"
        mib commit

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"

        CUR_MODE=$(get_mode "$BAND")
        if [ "${CUR_MODE:-0}" != "0" ]; then
            WLAN_DIS=$(get_wlan_disabled "$BAND")
            if [ "${WLAN_DIS:-0}" = "0" ]; then
                ( wlan_apply restart ) &
            fi
        fi
        exit 0
    fi

    # action=delmac
    if [ "$ACTION" = "delmac" ]; then
        BAND=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*band=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        DEL_IDX=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*idx=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')

        case "$BAND" in
            24|5) ;;
            *)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid band"
                exit 0
                ;;
        esac

        case "$DEL_IDX" in
            ''|*[!0-9]*)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid index"
                exit 0
                ;;
        esac

        band_keys "$BAND"
        mib del "${TABLE_KEY}.${DEL_IDX}"
        mib commit

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"

        CUR_MODE=$(get_mode "$BAND")
        if [ "${CUR_MODE:-0}" != "0" ]; then
            WLAN_DIS=$(get_wlan_disabled "$BAND")
            if [ "${WLAN_DIS:-0}" = "0" ]; then
                ( wlan_apply restart ) &
            fi
        fi
        exit 0
    fi

fi

printf "Status: 302 Found\r\n"
printf "Location: /wlanmac.html\r\n\r\n"
