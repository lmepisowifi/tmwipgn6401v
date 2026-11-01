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
        | busybox tr -d '\r\n' \
        | busybox sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
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

# ---- Debug logging ----
DBG_LOG="/tmp/wlanmac_debug.log"
dbg() {
    printf '[%s] wlanmac.cgi: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
        >> "$DBG_LOG" 2>/dev/null
}

# ---- Live apply --------------------------------------------------------------
# `mib set` + `mib commit` only persist a change. The vendor makes it take effect
# with `wlan_apply restart` (config_WLAN -> setupWLan -> set_wlan_acl), which stops
# and starts BOTH radios and every SSID, so every client is dropped for a few
# seconds. The Realtek driver reads the filter from the running interface at
# auth/assoc time, and set_wlan_acl() fills it with plain iwpriv calls, so the
# same can be done on a running radio (live=1 on the POST):
#
#   iwpriv <if> set_mib aclnum=0          empty the list
#   iwpriv <if> set_mib aclmode=<0|1|2>   0 off, 1 allow (whitelist), 2 deny (blacklist)
#   iwpriv <if> set_mib acladdr=<12 hex>  one call per MAC
#
# The driver gives every VAP its own mib struct, so it goes to the root netdev and
# to each VAP / the repeater (VXD) that is up - the same set the vendor's
# setupWLan() covers. The list is only consulted when a station authenticates or
# associates, so stations that are already connected and are no longer allowed
# (whitelist: not listed, blacklist: listed) are dropped with
# `iwpriv <if> del_sta <mac>` (what wlansta.cgi's "disconnect" does); everybody
# else stays connected. If any push fails, the band is restarted instead
# (wlanapply = one radio, else the stock restart of everything), so a half-applied
# filter is never left behind.
#
# The reply body tells the page what happened:
#   "OK live"     applied to the running radio, nothing to wait for
#   "OK"          nothing to apply (filter off, or the radio is disabled: it is
#                 read from the MIB the next time the radio starts)
#   "OK restart"  live apply failed, the band is being restarted in the background
WLANAPPLY=/lmepisowifi/www2/tool/wlanapply

# MACs of a band's access-control table as bare 12-digit lowercase hex, one per line
get_mac_list() {
    mib get "$1" 2>/dev/null | busybox awk '
        /MacAddr[ \t]*=[ \t]*[0-9a-fA-F]/ {
            m = $NF; gsub(/[^0-9a-fA-F]/, "", m)
            if (length(m) == 12) print tolower(m)
        }'
}

# acl_ifaces BAND [vxd] -> the band's netdevs that are up: root, VAP0-3 and, when
# asked for, the repeater. 5 GHz = wlan0, 2.4 GHz = wlan1. A down netdev is left
# alone: it gets the filter from the MIB when it is brought up.
acl_ifaces() {
    if [ "$1" = "24" ]; then _ai_root=wlan1; else _ai_root=wlan0; fi
    _ai_set="$_ai_root $_ai_root-vap0 $_ai_root-vap1 $_ai_root-vap2 $_ai_root-vap3"
    [ "$2" = "vxd" ] && _ai_set="$_ai_set $_ai_root-vxd"
    for _ai_if in $_ai_set; do
        [ -d "${WL_NETSYS:-/sys/class/net}/$_ai_if" ] || continue
        # flags is hex ("0x1003"); bit 0 is IFF_UP. Unreadable -> treat as up.
        _ai_fl=$(busybox cat "${WL_NETSYS:-/sys/class/net}/$_ai_if/flags" 2>/dev/null)
        if [ -n "$_ai_fl" ] && [ $(( _ai_fl & 1 )) -eq 0 ]; then continue; fi
        printf '%s ' "$_ai_if"
    done
}

# acl_push_live BAND MODE -> 0 when every up netdev of the band now has the filter
# (MODE 0/1/2 plus the band's MAC table as committed), 1 when anything failed.
acl_push_live() {
    _pl_band="$1"; _pl_mode="$2"
    band_keys "$_pl_band"
    if [ "$_pl_band" = "24" ]; then _pl_root=wlan1; else _pl_root=wlan0; fi
    _pl_ifs=$(acl_ifaces "$_pl_band" vxd)
    case " $_pl_ifs" in
        *" $_pl_root "*) ;;
        *) dbg "acl_push_live band=$_pl_band: $_pl_root is not up"; return 1 ;;
    esac
    _pl_list=$(get_mac_list "$TABLE_KEY")
    for _pl_if in $_pl_ifs; do
        if ! iwpriv "$_pl_if" set_mib aclnum=0 >/dev/null 2>&1; then
            dbg "acl_push_live band=$_pl_band: $_pl_if aclnum=0 failed"; return 1
        fi
        if ! iwpriv "$_pl_if" set_mib "aclmode=$_pl_mode" >/dev/null 2>&1; then
            dbg "acl_push_live band=$_pl_band: $_pl_if aclmode=$_pl_mode failed"; return 1
        fi
        if [ "$_pl_mode" != "0" ]; then
            for _pl_mac in $_pl_list; do
                if ! iwpriv "$_pl_if" set_mib "acladdr=$_pl_mac" >/dev/null 2>&1; then
                    dbg "acl_push_live band=$_pl_band: $_pl_if acladdr=$_pl_mac failed"; return 1
                fi
            done
        fi
    done
    dbg "acl_push_live band=$_pl_band mode=$_pl_mode: $(echo $_pl_list | busybox wc -w) MAC(s) pushed to $_pl_ifs"
    return 0
}

# acl_kick_band BAND MODE -> disassociate the connected stations the filter no
# longer allows. Nothing to do for MODE 0. The repeater (VXD) is the router's own
# client link, not a place stations connect to, so it is not touched.
acl_kick_band() {
    _kb_band="$1"; _kb_mode="$2"
    case "$_kb_mode" in 1|2) ;; *) return 0 ;; esac
    band_keys "$_kb_band"
    _kb_list=$(get_mac_list "$TABLE_KEY")
    for _kb_if in $(acl_ifaces "$_kb_band"); do
        [ -r "${WL_PROC:-/proc}/$_kb_if/sta_info" ] || continue
        for _kb_sta in $(busybox awk '
            /^[ \t]*hwaddr:/ {
                v = $0; sub(/^[^:]*:[ \t]*/, "", v); gsub(/[^0-9a-fA-F]/, "", v)
                if (length(v) == 12) print tolower(v)
            }' "${WL_PROC:-/proc}/$_kb_if/sta_info" 2>/dev/null); do
            if printf '%s\n' "$_kb_list" | busybox grep -qx "$_kb_sta"; then _kb_in=1; else _kb_in=0; fi
            _kb_drop=0
            [ "$_kb_mode" = "1" ] && [ "$_kb_in" = "0" ] && _kb_drop=1
            [ "$_kb_mode" = "2" ] && [ "$_kb_in" = "1" ] && _kb_drop=1
            if [ "$_kb_drop" = "1" ]; then
                iwpriv "$_kb_if" del_sta "$_kb_sta" >/dev/null 2>&1
                dbg "acl_kick_band band=$_kb_band mode=$_kb_mode: del_sta $_kb_if $_kb_sta rc=$?"
            fi
        done
    done
}

# acl_restart_band BAND -> the fallback: restart one radio with wlanapply (the
# vendor config_WLAN for that band), or everything with the stock wlan_apply if
# the helper is missing or fails (same preflight as wlanadvanced.cgi).
acl_restart_band() {
    if [ "$1" = "24" ]; then _rb_bn=2g; else _rb_bn=5g; fi
    if [ -f "$WLANAPPLY" ]; then
        [ -x "$WLANAPPLY" ] || chmod +x "$WLANAPPLY" 2>/dev/null
        if [ -x "$WLANAPPLY" ] && "$WLANAPPLY" check >/dev/null 2>&1 \
           && "$WLANAPPLY" restart "$_rb_bn" all >/dev/null 2>&1; then
            dbg "acl_restart_band: wlanapply restart $_rb_bn all ok"
            return 0
        fi
        dbg "acl_restart_band: wlanapply restart $_rb_bn all unavailable or failed, using wlan_apply restart"
    fi
    wlan_apply restart
}

# acl_reply BAND MODE LIVE NEED -> send the reply for a change that is already
# committed, and apply it. NEED=1 when the running radio has to learn about it.
#   LIVE=1  push it into the driver now (the reply says how that went); the
#           stations it no longer allows are dropped 1 s after the reply, so the
#           admin's own page still gets its answer.
#   LIVE=0  the old behaviour: reply, then a full `wlan_apply restart`.
# The background jobs get /dev/null for stdin/stdout so they can't hold the
# HTTP response open.
acl_reply() {
    _ar_band="$1"; _ar_mode="$2"; _ar_live="$3"; _ar_need="$4"
    _ar_tag=""; _ar_bg=""
    if [ "$_ar_need" = "1" ]; then
        if [ "$_ar_live" != "1" ]; then
            _ar_bg=legacy
        elif acl_push_live "$_ar_band" "$_ar_mode"; then
            _ar_tag=" live"; _ar_bg=kick
        else
            _ar_tag=" restart"; _ar_bg=restart
        fi
    fi
    printf "Status: 200 OK\r\n"
    printf "Content-Type: text/plain\r\n\r\n"
    printf "OK%s" "$_ar_tag"
    case "$_ar_bg" in
        legacy)  ( wlan_apply restart ) & ;;
        restart) ( acl_restart_band "$_ar_band" ) >/dev/null 2>&1 </dev/null & ;;
        kick)    ( sleep 1; acl_kick_band "$_ar_band" "$_ar_mode" ) >/dev/null 2>&1 </dev/null & ;;
    esac
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
    # live=1: apply to the running driver instead of restarting the radios
    LIVE=$(echo "$POST_DATA" \
        | busybox sed -n 's/.*live=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')
    [ "$LIVE" = "1" ] || LIVE=0

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

        # A disabled radio has nothing to apply to: it reads the MIB when it starts.
        NEED=0
        WLAN_DIS=$(get_wlan_disabled "$BAND")
        [ "${WLAN_DIS:-0}" = "0" ] && NEED=1
        acl_reply "$BAND" "$MODE" "$LIVE" "$NEED"
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

        # Only an active filter (and a radio that is up) has anything to apply.
        NEED=0
        CUR_MODE=$(get_mode "$BAND")
        if [ "${CUR_MODE:-0}" != "0" ]; then
            WLAN_DIS=$(get_wlan_disabled "$BAND")
            [ "${WLAN_DIS:-0}" = "0" ] && NEED=1
        fi
        acl_reply "$BAND" "${CUR_MODE:-0}" "$LIVE" "$NEED"
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

        # Only an active filter (and a radio that is up) has anything to apply.
        NEED=0
        CUR_MODE=$(get_mode "$BAND")
        if [ "${CUR_MODE:-0}" != "0" ]; then
            WLAN_DIS=$(get_wlan_disabled "$BAND")
            [ "${WLAN_DIS:-0}" = "0" ] && NEED=1
        fi
        acl_reply "$BAND" "${CUR_MODE:-0}" "$LIVE" "$NEED"
        exit 0
    fi

fi

printf "Status: 302 Found\r\n"
printf "Location: /wlanmac.html\r\n\r\n"
