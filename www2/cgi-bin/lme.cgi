#!/bin/sh

SESSION_TIMEOUT=600

# 1. Extract session ID from cookie
BROWSER_SESSION=$(echo "$HTTP_COOKIE" | busybox sed -n 's/.*session=\([^;]*\).*/\1/p' | busybox tr -d '\r\n')
# Sanitize: session IDs are sha256 hex. Strip anything else to block
# path traversal (e.g. Cookie: session=../../config/foo) into rm/mv/cat.
BROWSER_SESSION=$(printf '%s' "$BROWSER_SESSION" | busybox tr -cd 'a-fA-F0-9')
SESSION_FILE="/tmp/sessions/$BROWSER_SESSION"

# 2. Security gate — validate session and timestamp
if [ -z "$BROWSER_SESSION" ] || [ ! -f "$SESSION_FILE" ]; then
    printf "Status: 302 Found\r\n"
    printf "Location: /login.html\r\n\r\n"
    exit 0
fi

LAST=$(cat "$SESSION_FILE" 2>/dev/null | busybox tr -d '\r\n')
NOW=$(date +%s)

# Guard: empty file means a concurrent request is mid-write — treat as still valid
# rather than logging the user out (same logic as check_auth.cgi).
if [ -z "$LAST" ]; then
    LAST=$NOW
fi

if [ $((NOW - LAST)) -gt $SESSION_TIMEOUT ]; then
    rm -f "$SESSION_FILE"
    printf "Status: 302 Found\r\n"
    printf "Location: /login.html\r\n\r\n"
    exit 0
fi

# 3. Refresh session timestamp — atomic write (mktemp + mv = single rename() syscall)
#    so concurrent requests never see an empty/truncated file.
_SESS_TMP=$(mktemp /tmp/sessions/.tmp.XXXXXX)
echo "$NOW" > "$_SESS_TMP"
busybox mv "$_SESS_TMP" "$SESSION_FILE"

# ---- LAN helper ----
LAN_SH=/lmepisowifi/www2/sh/lan.sh

# ---- LAN revert state files ----
LAN_REVERT_PENDING=/tmp/lan_revert_pending
LAN_REVERT_PORT=/tmp/lan_revert_port
LAN_REVERT_POWER=/tmp/lan_revert_power
LAN_REVERT_SPEED=/tmp/lan_revert_speed
LAN_REVERT_START=/tmp/lan_revert_start
LAN_REVERT_TIMEOUT=90

# ---- startup.sh speed persistence ----
STARTUP_SH=/lmepisowifi/www2/sh/startup.sh

# ---- shared data directory (layout, etc.) ----
DATA_DIR=/lmepisowifi/www2/data
LAYOUT_FILE="$DATA_DIR/dashboard_layout.json"

# update_startup_speed <port> <speed_abilities>
#   port           : 1-4 (user-facing, matches lan.sh convention)
#   speed_abilities: space-separated ability tokens already in canonical order
#                    (e.g. "100f", "10h 10f 100h 100f 1000f"), OR empty to
#                    remove the entry for that port (used when reverting to auto).
#
# Interface mapping: LAN1 = port 1 = eth0.2 = diag index 0
#                    LAN2 = port 2 = eth0.3 = diag index 1
#                    LAN3 = port 3 = eth0.4 = diag index 2
#                    LAN4 = port 4 = eth0.5 = diag index 3
#
# Each managed entry in startup.sh is a single line of the form:
#   ( wait_for_iface <iface> && diag port set auto-nego port <idx> ability <speeds> ) &
# The function rewrites the BEGIN_LAN_SPEEDS … END_LAN_SPEEDS section in-place.
update_startup_speed() {
    _UPD_PORT="$1"
    _UPD_SPEED="$2"

    [ ! -f "$STARTUP_SH" ] && return

    case "$_UPD_PORT" in
        1) _UPD_IFACE="eth0.2"; _UPD_IDX="0" ;;
        2) _UPD_IFACE="eth0.3"; _UPD_IDX="1" ;;
        3) _UPD_IFACE="eth0.4"; _UPD_IDX="2" ;;
        4) _UPD_IFACE="eth0.5"; _UPD_IDX="3" ;;
    esac

    _UPD_REMOVE=0
    [ -z "$_UPD_SPEED" ] && _UPD_REMOVE=1

    _UPD_TMP="/tmp/startup_sh_$$.tmp"

    busybox awk \
        -v iface="$_UPD_IFACE" \
        -v idx="$_UPD_IDX" \
        -v speed="$_UPD_SPEED" \
        -v remove_only="$_UPD_REMOVE" \
        'BEGIN { in_sec=0 }
         /^# --- BEGIN_LAN_SPEEDS ---/ { print; in_sec=1; next }
         /^# --- END_LAN_SPEEDS ---/ {
             if (!remove_only && speed != "") {
                 print "( wait_for_iface " iface " && diag port set auto-nego port " idx " ability " speed " ) &"
             }
             in_sec=0; print; next
         }
         in_sec && index($0, "wait_for_iface " iface) > 0 { next }
         { print }' \
        "$STARTUP_SH" > "$_UPD_TMP" \
    && busybox mv "$_UPD_TMP" "$STARTUP_SH" \
    && busybox chmod 755 "$STARTUP_SH"
}

# ---- WLAN revert state files ----
REVERT_PENDING=/tmp/ssid_revert_pending
REVERT_ROLLBACK=/tmp/ssid_rollback
REVERT_ROLLBACK_CH=/tmp/channel_rollback
REVERT_ROLLBACK_BAND=/tmp/wlanband_rollback
REVERT_ROLLBACK_DIS=/tmp/disabled_rollback
REVERT_ROLLBACK_CW=/tmp/channelwidth_rollback
REVERT_ROLLBACK_CB=/tmp/controlband_rollback
REVERT_ROLLBACK_TP=/tmp/txpower_rollback
REVERT_START=/tmp/ssid_revert_start
REVERT_TIMEOUT=90

# ---- MAC filter revert state files ----
MAC_REVERT_PENDING=/tmp/macfilter_revert_pending
MAC_REVERT_MODE=/tmp/macfilter_revert_mode
MAC_REVERT_START=/tmp/macfilter_revert_start
MAC_REVERT_TIMEOUT=90

# ---- DHCP server revert state files ----
DHCP_REVERT_PENDING=/tmp/dhcp_revert_pending
DHCP_REVERT_MODE=/tmp/dhcp_revert_mode
DHCP_REVERT_START=/tmp/dhcp_revert_start
DHCP_REVERT_TIMEOUT=90

# ---- WLAN helper functions ----
get_ssid() {
    mib get WLAN1_MBSSIB_TBL.0.ssid \
        | busybox grep "=" \
        | busybox cut -d'=' -f2- \
        | busybox tr -d '\r\n'
}

get_channel() {
    mib get WLAN1_CHANNEL \
        | busybox grep "=" \
        | busybox cut -d'=' -f2- \
        | busybox tr -d '\r\n'
}

get_channelwidth() {
    mib get WLAN1_CHANNELWIDTH \
        | busybox grep "=" \
        | busybox cut -d'=' -f2- \
        | busybox tr -d '\r\n'
}

get_disabled() {
    mib get WLAN1_MBSSIB_TBL.0.wlanDisabled \
        | busybox grep "=" \
        | busybox cut -d'=' -f2- \
        | busybox tr -d '\r\n'
}

get_wlanband() {
    mib get WLAN1_MBSSIB_TBL.0.wlanBand \
        | busybox grep "=" \
        | busybox cut -d'=' -f2- \
        | busybox tr -d '\r\n'
}

get_controlband() {
    mib get WLAN1_CONTROLBAND \
        | busybox grep "=" \
        | busybox cut -d'=' -f2- \
        | busybox tr -d '\r\n'
}

get_txpower() {
    mib get WLAN1_RFPOWER_SCALE \
        | busybox grep "=" \
        | busybox cut -d'=' -f2- \
        | busybox tr -d '\r\n'
}

get_channel_list() {
    IFACE="${1:-wlan1}"
    AVAIL=$(busybox grep 'AVAIL_CH' /proc/${IFACE}/mib_dfs 2>/dev/null \
        | busybox sed 's/.*AVAIL_CH:[[:space:]]*//' \
        | busybox tr '\n' ' ' \
        | busybox tr -s ' ' \
        | busybox sed 's/^ *//;s/ *$//' \
        | busybox sed 's/ /,/g')
    if [ -z "$AVAIL" ]; then
        case "$IFACE" in
            wlan0) printf '36,40,44,48,52,56,60,64,100,104,108,112,116,120,124,128,132,136,140,144,149,153,157,161,165' ;;
            *)     printf '1,2,3,4,5,6,7,8,9,10,11' ;;
        esac
    else
        printf '%s' "$AVAIL"
    fi
}

# ---- MAC filter helper functions ----

# Returns current mode (0/1/2) for WLAN1
get_mac_mode() {
    mib get WLAN1_MACAC_ENABLED \
        | busybox grep "=" \
        | busybox cut -d'=' -f2- \
        | busybox tr -d '\r\n'
}

# Emits a JSON array of {index, mac} objects from WLAN1_AC_TBL
# MAC is formatted as uppercase colon-separated XX:XX:XX:XX:XX:XX
get_mac_entries_json() {
    RAW=$(mib get WLAN1_AC_TBL 2>/dev/null)
    # Each record looks like:
    #   WLAN1_AC_TBL.N:
    #   wlanIdx = 1
    #   MacAddr = aabbccddeeff
    printf '['
    FIRST=1
    IDX=""
    MAC_RAW=""
    WLAN_IDX=""
    echo "$RAW" | while IFS= read -r LINE; do
        # New record header
        HEADER=$(echo "$LINE" | busybox grep -E '^WLAN1_AC_TBL\.[0-9]+:')
        if [ -n "$HEADER" ]; then
            # Flush previous record if it belonged to wlan1 (wlanIdx=1)
            if [ -n "$IDX" ] && [ "$WLAN_IDX" = "1" ] && [ -n "$MAC_RAW" ]; then
                FORMATTED=$(echo "$MAC_RAW" | busybox tr 'a-z' 'A-Z' | busybox sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/')
                if [ "$FIRST" = "1" ]; then
                    FIRST=0
                else
                    printf ','
                fi
                printf '{"index":%s,"mac":"%s"}' "$IDX" "$FORMATTED"
            fi
            IDX=$(echo "$HEADER" | busybox sed 's/WLAN1_AC_TBL\.\([0-9]*\):.*/\1/')
            MAC_RAW=""
            WLAN_IDX=""
            continue
        fi
        VAL=$(echo "$LINE" | busybox sed 's/^[[:space:]]*//')
        W=$(echo "$VAL" | busybox sed -n 's/wlanIdx[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p')
        [ -n "$W" ] && WLAN_IDX="$W"
        M=$(echo "$VAL" | busybox sed -n 's/MacAddr[[:space:]]*=[[:space:]]*\([0-9a-fA-F]*\).*/\1/p')
        [ -n "$M" ] && MAC_RAW="$M"
    done
    # Flush last record
    # (The subshell from 'while … | while' means variables don't persist — handled below)
    printf ']'
}

# ==========================================
# GET MODE
# ==========================================
if [ "$REQUEST_METHOD" = "GET" ]; then

    # --- action=confirm: client acknowledged, cancel the WLAN revert ---
    if echo "$QUERY_STRING" | busybox grep -q "action=confirm"; then
        rm -f "$REVERT_PENDING" "$REVERT_ROLLBACK" "$REVERT_ROLLBACK_CH" "$REVERT_ROLLBACK_BAND" "$REVERT_ROLLBACK_DIS" "$REVERT_ROLLBACK_CW" "$REVERT_ROLLBACK_CB" "$REVERT_ROLLBACK_TP" "$REVERT_START"
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "confirmed"
        exit 0
    fi

    # --- action=status: return WLAN status as JSON ---
    if echo "$QUERY_STRING" | busybox grep -q "action=status"; then
        CURRENT_SSID=$(get_ssid)
        CURRENT_CHANNEL=$(get_channel)
        CURRENT_DISABLED=$(get_disabled)
        CURRENT_BAND=$(get_wlanband)
        CURRENT_CW=$(get_channelwidth)
        CURRENT_CB=$(get_controlband)
        CURRENT_TP=$(get_txpower)
        [ -z "$CURRENT_TP" ] && CURRENT_TP=0
        CHANNEL_LIST=$(get_channel_list)
        ESCAPED=$(printf '%s' "$CURRENT_SSID" \
            | busybox sed 's/\\/\\\\/g; s/"/\\"/g')
        if [ -f "$REVERT_PENDING" ] && [ -f "$REVERT_START" ]; then
            START=$(cat "$REVERT_START")
            NOW2=$(date +%s)
            ELAPSED=$((NOW2 - START))
            REMAINING=$((REVERT_TIMEOUT - ELAPSED))
            [ "$REMAINING" -lt 0 ] && REMAINING=0
            printf "Status: 200 OK\r\n"
            printf "Content-Type: application/json\r\n\r\n"
            printf '{"ssid":"%s","channel":%s,"channels":[%s],"disabled":%s,"wlanband":%s,"channelwidth":%s,"controlband":%s,"txpower":%s,"pending":true,"remaining":%d}' \
                "$ESCAPED" "$CURRENT_CHANNEL" "$CHANNEL_LIST" "$CURRENT_DISABLED" "$CURRENT_BAND" "$CURRENT_CW" "$CURRENT_CB" "$CURRENT_TP" "$REMAINING"
        else
            printf "Status: 200 OK\r\n"
            printf "Content-Type: application/json\r\n\r\n"
            printf '{"ssid":"%s","channel":%s,"channels":[%s],"disabled":%s,"wlanband":%s,"channelwidth":%s,"controlband":%s,"txpower":%s,"pending":false,"remaining":0}' \
                "$ESCAPED" "$CURRENT_CHANNEL" "$CHANNEL_LIST" "$CURRENT_DISABLED" "$CURRENT_BAND" "$CURRENT_CW" "$CURRENT_CB" "$CURRENT_TP"
        fi
        exit 0
    fi

    # --- action=lan_confirm: client acknowledged, cancel the LAN revert ---
    if echo "$QUERY_STRING" | busybox grep -q "action=lan_confirm"; then
        rm -f "$LAN_REVERT_PENDING" "$LAN_REVERT_PORT" "$LAN_REVERT_POWER" "$LAN_REVERT_SPEED" "$LAN_REVERT_START"
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "confirmed"
        exit 0
    fi

    # --- action=lan_status: return LAN port status as JSON ---
    if echo "$QUERY_STRING" | busybox grep -q "action=lan_status"; then
        RAW=$(sh "$LAN_SH" status 2>&1)

        P1_PWR=$(echo "$RAW" | busybox sed -n 's/.*PORT1_PWR="\([^"]*\)".*/\1/p')
        P1_SPD=$(echo "$RAW" | busybox sed -n 's/.*PORT1_SPEED="\([^"]*\)".*/\1/p')
        P2_PWR=$(echo "$RAW" | busybox sed -n 's/.*PORT2_PWR="\([^"]*\)".*/\1/p')
        P2_SPD=$(echo "$RAW" | busybox sed -n 's/.*PORT2_SPEED="\([^"]*\)".*/\1/p')
        P3_PWR=$(echo "$RAW" | busybox sed -n 's/.*PORT3_PWR="\([^"]*\)".*/\1/p')
        P3_SPD=$(echo "$RAW" | busybox sed -n 's/.*PORT3_SPEED="\([^"]*\)".*/\1/p')
        P4_PWR=$(echo "$RAW" | busybox sed -n 's/.*PORT4_PWR="\([^"]*\)".*/\1/p')
        P4_SPD=$(echo "$RAW" | busybox sed -n 's/.*PORT4_SPEED="\([^"]*\)".*/\1/p')

        if ! echo "$RAW" | busybox grep -q 'STATUS="SUCCESS"'; then
            printf "Status: 500 Internal Server Error\r\n"
            printf "Content-Type: application/json\r\n\r\n"
            ERR=$(echo "$RAW" | busybox sed -n 's/.*ERROR="\([^"]*\)".*/\1/p')
            [ -z "$ERR" ] && ERR="lan.sh returned unexpected output"
            printf '{"error":"%s"}' "$ERR"
            exit 0
        fi

        LAN_PENDING=false
        LAN_REMAINING=0
        if [ -f "$LAN_REVERT_PENDING" ] && [ -f "$LAN_REVERT_START" ]; then
            LAN_START=$(cat "$LAN_REVERT_START")
            LAN_NOW=$(date +%s)
            LAN_ELAPSED=$((LAN_NOW - LAN_START))
            LAN_REMAINING=$((LAN_REVERT_TIMEOUT - LAN_ELAPSED))
            [ "$LAN_REMAINING" -lt 0 ] && LAN_REMAINING=0
            LAN_PENDING=true
        fi

        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"port1_pwr":"%s","port1_speed":"%s","port2_pwr":"%s","port2_speed":"%s","port3_pwr":"%s","port3_speed":"%s","port4_pwr":"%s","port4_speed":"%s","pending":%s,"remaining":%d}' \
            "$P1_PWR" "$P1_SPD" "$P2_PWR" "$P2_SPD" "$P3_PWR" "$P3_SPD" "$P4_PWR" "$P4_SPD" "$LAN_PENDING" "$LAN_REMAINING"
        exit 0
    fi


    # --- action=system_status: return HW serial, MAC, PON mode and auto flag ---
    if echo "$QUERY_STRING" | busybox grep -q "action=system_status"; then
        HW_SERIAL=$(mib get HW_SERIAL_NO 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2- \
            | busybox tr -d '\r\n')
        MAC_RAW=$(mib get ELAN_MAC_ADDR 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2 \
            | busybox tr -d '\r\n')
        PON_MODE=$(mib get PON_MODE 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2 \
            | busybox tr -d '\r\n')
        PON_AUTO=$(mib get PON_MODE_AUTO_CHECK_ENABLE 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2 \
            | busybox tr -d '\r\n')
        MAC=$(echo "$MAC_RAW" \
            | busybox sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/' \
            | busybox tr 'a-z' 'A-Z')
        [ -z "$PON_MODE" ] && PON_MODE=1
        [ -z "$PON_AUTO" ] && PON_AUTO=1
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"hw_serial_no":"%s","mac":"%s","pon_mode":%s,"pon_auto":%s}' \
            "$HW_SERIAL" "$MAC" "$PON_MODE" "$PON_AUTO"
        exit 0
    fi

    # --- action=account_status: return current admin (superuser) username ---
    if echo "$QUERY_STRING" | busybox grep -q "action=account_status"; then
        SUSER=$(mib get SUSER_NAME 2>/dev/null \
            | busybox grep "SUSER_NAME=" \
            | busybox cut -d'=' -f2- \
            | busybox tr -d '\r\n')
        ESC_SUSER=$(printf '%s' "$SUSER" | busybox sed 's/\\/\\\\/g; s/"/\\"/g')
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"suser_name":"%s"}' "$ESC_SUSER"
        exit 0
    fi

    # --- action=lan_ip_status: return current LAN IP and subnet mask ---
    if echo "$QUERY_STRING" | busybox grep -q "action=lan_ip_status"; then
        LAN_IP=$(mib get LAN_IP_ADDR 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2- \
            | busybox tr -d '\r\n')
        LAN_SN=$(mib get LAN_SUBNET 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2- \
            | busybox tr -d '\r\n')
        [ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"
        [ -z "$LAN_SN" ] && LAN_SN="255.255.255.0"
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"ip":"%s","subnet":"%s"}' "$LAN_IP" "$LAN_SN"
        exit 0
    fi

    # --- action=dhcp_status: return current DHCP server settings as JSON ---
    if echo "$QUERY_STRING" | busybox grep -q "action=dhcp_status"; then
        DHCP_MODE_VAL=$(mib get DHCP_MODE 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- | busybox tr -d '\r\n')
        DHCP_POOL_START=$(mib get LAN_DHCP_POOL_START 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- | busybox tr -d '\r\n')
        DHCP_POOL_END=$(mib get LAN_DHCP_POOL_END 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- | busybox tr -d '\r\n')
        DHCP_MASK=$(mib get DHCP_SUBNET_MASK 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- | busybox tr -d '\r\n')
        DHCP_GW=$(mib get LAN_DHCP_GATEWAY 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- | busybox tr -d '\r\n')
        DHCP_LEASE=$(mib get LAN_DHCP_LEASE 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- | busybox tr -d '\r\n')
        DHCP_DOMAIN=$(mib get LAN_DHCP_DOMAIN 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- | busybox tr -d '\r\n')
        DHCP_DNS_OPT=$(mib get LAN_DHCP_DNS_OPT 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- | busybox tr -d '\r\n')
        DHCP_DNS1=$(mib get DHCPS_DNS1 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- | busybox tr -d '\r\n')
        DHCP_DNS2=$(mib get DHCPS_DNS2 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- | busybox tr -d '\r\n')
        DHCP_DNS3=$(mib get DHCPS_DNS3 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- | busybox tr -d '\r\n')

        DHCP_ENABLED=false
        [ -n "$DHCP_MODE_VAL" ] && [ "$DHCP_MODE_VAL" != "0" ] && DHCP_ENABLED=true

        [ -z "$DHCP_LEASE" ]  && DHCP_LEASE="86400"
        [ -z "$DHCP_MASK" ]   && DHCP_MASK="255.255.255.0"
        [ -z "$DHCP_DOMAIN" ] && DHCP_DOMAIN="bbrouter"

        ESC_DOMAIN=$(printf '%s' "$DHCP_DOMAIN" | busybox sed 's/\\/\\\\/g; s/"/\\"/g')

        # Surface any pending dhcp_enable revert the same way lan_status/status do,
        # so the UI can reflect it if/when it's wired up to show a countdown.
        DHCP_PENDING=false
        DHCP_REMAINING=0
        if [ -f "$DHCP_REVERT_PENDING" ] && [ -f "$DHCP_REVERT_START" ]; then
            D_START=$(cat "$DHCP_REVERT_START")
            D_NOW=$(date +%s)
            D_ELAPSED=$((D_NOW - D_START))
            DHCP_REMAINING=$((DHCP_REVERT_TIMEOUT - D_ELAPSED))
            [ "$DHCP_REMAINING" -lt 0 ] && DHCP_REMAINING=0
            DHCP_PENDING=true
        fi

        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"enabled":%s,"pool_start":"%s","pool_end":"%s","mask":"%s","gateway":"%s","lease":%s,"domain":"%s","dns_opt":%s,"dns1":"%s","dns2":"%s","dns3":"%s","pending":%s,"remaining":%d}' \
            "$DHCP_ENABLED" "$DHCP_POOL_START" "$DHCP_POOL_END" "$DHCP_MASK" "$DHCP_GW" \
            "$DHCP_LEASE" "$ESC_DOMAIN" "${DHCP_DNS_OPT:-0}" "$DHCP_DNS1" "$DHCP_DNS2" "$DHCP_DNS3" \
            "$DHCP_PENDING" "$DHCP_REMAINING"
        exit 0
    fi

    # --- action=dhcp_confirm: client acknowledged, cancel the DHCP enable/disable revert ---
    if echo "$QUERY_STRING" | busybox grep -q "action=dhcp_confirm"; then
        rm -f "$DHCP_REVERT_PENDING" "$DHCP_REVERT_MODE" "$DHCP_REVERT_START"
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "confirmed"
        exit 0
    fi

    # --- action=gpon_status: return GPON SN, LOID, LOID password, PLOAM password ---
    if echo "$QUERY_STRING" | busybox grep -q "action=gpon_status"; then
        G_SN=$(mib get GPON_SN 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2- \
            | busybox tr -d '\r\n')
        G_LOID=$(mib get LOID 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2- \
            | busybox tr -d '\r\n')
        G_LOID_PW=$(mib get LOID_PASSWD 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2- \
            | busybox tr -d '\r\n')
        G_PLOAM=$(mib get GPON_PLOAM_PASSWD 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2- \
            | busybox tr -d '\r\n')
        G_PON_MODE=$(mib get PON_MODE 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2 \
            | busybox tr -d '\r\n')
        G_PON_AUTO=$(mib get PON_MODE_AUTO_CHECK_ENABLE 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2 \
            | busybox tr -d '\r\n')
        [ -z "$G_PON_MODE" ] && G_PON_MODE=1
        [ -z "$G_PON_AUTO" ] && G_PON_AUTO=1
        ESC_SN=$(printf '%s' "$G_SN"     | busybox sed 's/\\/\\\\/g; s/"/\\"/g')
        ESC_LOID=$(printf '%s' "$G_LOID" | busybox sed 's/\\/\\\\/g; s/"/\\"/g')
        ESC_LPWD=$(printf '%s' "$G_LOID_PW" | busybox sed 's/\\/\\\\/g; s/"/\\"/g')
        ESC_PLOAM=$(printf '%s' "$G_PLOAM"  | busybox sed 's/\\/\\\\/g; s/"/\\"/g')
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"gpon_sn":"%s","loid":"%s","loid_passwd":"%s","ploam_passwd":"%s","pon_mode":%s,"pon_auto":%s}' \
            "$ESC_SN" "$ESC_LOID" "$ESC_LPWD" "$ESC_PLOAM" "$G_PON_MODE" "$G_PON_AUTO"
        exit 0
    fi

    # --- action=static: static system info (hostname, firmware, kernel, GPON, MAC, HW S/N) ---
    if echo "$QUERY_STRING" | busybox grep -q "action=static"; then
        SW_ACTIVE=$(nv getenv sw_active 2>/dev/null \
            | busybox cut -d'=' -f2 \
            | busybox tr -d '\r\n')
        SW_VERSION=$(nv getenv "sw_version${SW_ACTIVE}" 2>/dev/null \
            | busybox cut -d'=' -f2 \
            | busybox tr -d '\r\n')
        KERNEL=$(busybox uname -r 2>/dev/null | busybox tr -d '\r\n')
        ARCH=$(busybox uname -m 2>/dev/null   | busybox tr -d '\r\n')
        HOSTNAME=$(busybox hostname 2>/dev/null | busybox tr -d '\r\n')
        GPON_SN=$(mib get GPON_SN 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2 \
            | busybox tr -d '\r\n')
        MAC_RAW=$(mib get ELAN_MAC_ADDR 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2 \
            | busybox tr -d '\r\n')
        MAC=$(echo "$MAC_RAW" \
            | busybox sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/' \
            | busybox tr 'a-z' 'A-Z')
        HW_SN=$(mib get HW_SERIAL_NO 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2- \
            | busybox tr -d '\r\n')
        ESC_HW_SN=$(printf '%s' "$HW_SN" | busybox sed 's/\\/\\\\/g; s/"/\\"/g')
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"hostname":"%s","sw_version":"%s","kernel":"%s","arch":"%s","gpon_sn":"%s","mac":"%s","hw_serial_no":"%s"}' \
            "$HOSTNAME" "$SW_VERSION" "$KERNEL" "$ARCH" "$GPON_SN" "$MAC" "$ESC_HW_SN"
        exit 0
    fi

    # --- action=dynamic: live system stats (date, uptime, load, RAM) ---
    if echo "$QUERY_STRING" | busybox grep -q "action=dynamic"; then
        DATE_STR=$(busybox date 2>/dev/null | busybox tr -d '\r\n')
        UPTIME_RAW=$(busybox uptime 2>/dev/null)
        UPTIME_STR=$(echo "$UPTIME_RAW" \
            | busybox sed 's/.*up \([^,]*\).*/\1/' \
            | busybox sed 's/^ *//;s/ *$//')
        LOAD_STR=$(echo "$UPTIME_RAW" \
            | busybox sed 's/.*load average: //' \
            | busybox tr -d '\r\n')
        LOAD1=$(echo  "$LOAD_STR" | busybox cut -d',' -f1 | busybox sed 's/ //g')
        LOAD5=$(echo  "$LOAD_STR" | busybox cut -d',' -f2 | busybox sed 's/ //g')
        LOAD15=$(echo "$LOAD_STR" | busybox cut -d',' -f3 | busybox sed 's/ //g')
        FREE_OUT=$(busybox free 2>/dev/null)
        MEM_TOTAL_KB=$(echo "$FREE_OUT" | busybox awk '/^Mem:/{print $2}')
        MEM_USED_KB=$(echo "$FREE_OUT" | busybox awk '/^Mem:/{print $2 - $7}')
        [ -z "$MEM_TOTAL_KB" ] && MEM_TOTAL_KB=1
        [ -z "$MEM_USED_KB"  ] && MEM_USED_KB=0
        MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
        MEM_USED_MB=$((MEM_USED_KB  / 1024))
        MEM_PCT=$((MEM_USED_KB * 100 / MEM_TOTAL_KB))
        CT_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null \
            | busybox tr -d '\r\n')
        CT_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null \
            | busybox tr -d '\r\n')
        [ -z "$CT_COUNT" ] && CT_COUNT=0
        [ -z "$CT_MAX"   ] && CT_MAX=1
        CT_PCT=$((CT_COUNT * 100 / CT_MAX))
        # --- CPU usage % (sample /proc/stat twice over a short interval) ---
        CPU_PCT=0
        read -r _c U1 N1 S1 I1 W1 IR1 SI1 ST1 _rest1 < /proc/stat 2>/dev/null
        busybox sleep 1 2>/dev/null || sleep 1
        read -r _c U2 N2 S2 I2 W2 IR2 SI2 ST2 _rest2 < /proc/stat 2>/dev/null
        for v in U1 N1 S1 I1 W1 IR1 SI1 ST1 U2 N2 S2 I2 W2 IR2 SI2 ST2; do
            eval "[ -z \"\$$v\" ] && $v=0"
        done
        BUSY1=$((U1 + N1 + S1 + IR1 + SI1 + ST1))
        BUSY2=$((U2 + N2 + S2 + IR2 + SI2 + ST2))
        TOTAL1=$((BUSY1 + I1 + W1))
        TOTAL2=$((BUSY2 + I2 + W2))
        DTOTAL=$((TOTAL2 - TOTAL1))
        DBUSY=$((BUSY2 - BUSY1))
        [ "$DTOTAL" -gt 0 ] && CPU_PCT=$((DBUSY * 100 / DTOTAL))
        [ "$CPU_PCT" -lt 0 ]   && CPU_PCT=0
        [ "$CPU_PCT" -gt 100 ] && CPU_PCT=100
        # --- Storage usage for the /lmepisowifi mount ---
        DISK_LINE=$(busybox df -k /lmepisowifi 2>/dev/null | busybox awk 'NR==2{print $2" "$3" "$4}')
        DISK_TOTAL_KB=$(echo "$DISK_LINE" | busybox cut -d' ' -f1)
        DISK_USED_KB=$(echo  "$DISK_LINE" | busybox cut -d' ' -f2)
        DISK_AVAIL_KB=$(echo "$DISK_LINE" | busybox cut -d' ' -f3)
        [ -z "$DISK_TOTAL_KB" ] && DISK_TOTAL_KB=1
        [ -z "$DISK_USED_KB"  ] && DISK_USED_KB=0
        [ -z "$DISK_AVAIL_KB" ] && DISK_AVAIL_KB=0
        DISK_TOTAL_MB=$((DISK_TOTAL_KB / 1024))
        DISK_USED_MB=$((DISK_USED_KB / 1024))
        DISK_AVAIL_MB=$((DISK_AVAIL_KB / 1024))
        DISK_PCT=$((DISK_USED_KB * 100 / DISK_TOTAL_KB))
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"date":"%s","uptime":"%s","load1":"%s","load5":"%s","load15":"%s","cpu_pct":%d,"mem_used_mb":%d,"mem_total_mb":%d,"mem_pct":%d,"disk_used_mb":%d,"disk_avail_mb":%d,"disk_total_mb":%d,"disk_pct":%d,"ct_count":%d,"ct_max":%d,"ct_pct":%d}' \
            "$DATE_STR" "$UPTIME_STR" "$LOAD1" "$LOAD5" "$LOAD15" "$CPU_PCT" \
            "$MEM_USED_MB" "$MEM_TOTAL_MB" "$MEM_PCT" \
            "$DISK_USED_MB" "$DISK_AVAIL_MB" "$DISK_TOTAL_MB" "$DISK_PCT" \
            "$CT_COUNT" "$CT_MAX" "$CT_PCT"
        exit 0
    fi

    # --- action=macfilter_status: return mode + entry list as JSON ---
    if echo "$QUERY_STRING" | busybox grep -q "action=macfilter_status"; then
        CURRENT_MODE=$(get_mac_mode)
        [ -z "$CURRENT_MODE" ] && CURRENT_MODE=0

        # Parse WLAN1_AC_TBL into a JSON array.
        # Because busybox sh pipelines run in subshells, we accumulate output
        # into a temp file to avoid the variable-scope trap.
        TMP_ENTRIES=/tmp/mac_entries_$$.json
        printf '[' > "$TMP_ENTRIES"
        FIRST_ENTRY=1

        mib get WLAN1_AC_TBL 2>/dev/null | while IFS= read -r LINE; do
            HEADER=$(echo "$LINE" | busybox grep -oE '^WLAN1_AC_TBL\.[0-9]+:')
            if [ -n "$HEADER" ]; then
                # Write a sentinel so the next iteration can detect a new record
                printf '\037%s' "$(echo "$HEADER" | busybox tr -d ':')" >> "$TMP_ENTRIES"
            fi
            W=$(echo "$LINE" | busybox sed -n 's/.*wlanIdx[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p')
            [ -n "$W" ] && printf '\036WIDX=%s' "$W" >> "$TMP_ENTRIES"
            M=$(echo "$LINE" | busybox sed -n 's/.*MacAddr[[:space:]]*=[[:space:]]*\([0-9a-fA-F]*\).*/\1/p')
            [ -n "$M" ] && printf '\036MAC=%s' "$M" >> "$TMP_ENTRIES"
        done

        # Now post-process the temp file with awk to produce clean JSON
        JSON_ENTRIES=$(
            busybox awk '
            BEGIN { RS="\037"; FS="\036"; first=1 }
            NR==1 { next }   # skip the leading [ before first sentinel
            {
                idx=""; widx=""; mac=""
                for (i=1;i<=NF;i++) {
                    if ($i ~ /^WLAN1_AC_TBL\./) {
                        idx = substr($i, index($i,".")+1)
                    } else if ($i ~ /^WIDX=/) {
                        widx = substr($i, 6)
                    } else if ($i ~ /^MAC=/) {
                        mac = substr($i, 5)
                    }
                }
                # Only include entries belonging to wlan1 (wlanIdx=1)
                # and skip all-zero placeholder MACs
                if (widx == "1" && mac != "" && mac != "000000000000") {
                    # Format MAC as XX:XX:XX:XX:XX:XX uppercase
                    m = toupper(mac)
                    formatted = substr(m,1,2)":"substr(m,3,2)":"substr(m,5,2)":"substr(m,7,2)":"substr(m,9,2)":"substr(m,11,2)
                    if (!first) printf ","
                    printf "{\"index\":%s,\"mac\":\"%s\"}", idx, formatted
                    first=0
                }
            }
            ' "$TMP_ENTRIES"
        )
        rm -f "$TMP_ENTRIES"

        MAC_PENDING=false
        MAC_REMAINING=0
        if [ -f "$MAC_REVERT_PENDING" ] && [ -f "$MAC_REVERT_START" ]; then
            MAC_START=$(cat "$MAC_REVERT_START")
            MAC_NOW=$(date +%s)
            MAC_ELAPSED=$((MAC_NOW - MAC_START))
            MAC_REMAINING=$((MAC_REVERT_TIMEOUT - MAC_ELAPSED))
            [ "$MAC_REMAINING" -lt 0 ] && MAC_REMAINING=0
            MAC_PENDING=true
        fi

        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"mode":%s,"entries":[%s],"pending":%s,"remaining":%d}' \
            "$CURRENT_MODE" "$JSON_ENTRIES" "$MAC_PENDING" "$MAC_REMAINING"
        exit 0
    fi

    # --- action=macfilter_confirm: cancel the mode revert ---
    if echo "$QUERY_STRING" | busybox grep -q "action=macfilter_confirm"; then
        rm -f "$MAC_REVERT_PENDING" "$MAC_REVERT_MODE" "$MAC_REVERT_START"
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "confirmed"
        exit 0
    fi

    # --- action=sitesurvey_load: read existing /proc SS_Result, no scan trigger ---
    if echo "$QUERY_STRING" | busybox grep -q "action=sitesurvey_load"; then
        IFACE=$(echo "$QUERY_STRING" | busybox sed -n 's/.*iface=\([^&]*\).*/\1/p' | busybox tr -d '\r\n')
        case "$IFACE" in
            wlan0|wlan1) ;;
            *) IFACE="wlan1" ;;
        esac
        # If a scan is already in progress, wait for it (up to 20s) before reading
        TRIES=0
        while [ $TRIES -lt 20 ]; do
            RAW=$(cat "/proc/${IFACE}/SS_Result" 2>/dev/null)
            if ! printf '%s\n' "$RAW" | busybox grep -q "^waitting"; then
                break
            fi
            busybox sleep 1
            TRIES=$((TRIES + 1))
        done
        RESULT=$(printf '%s\n' "$RAW" | busybox awk -v iface="$IFACE" '
BEGIN {
    in_ap = 0; ap_str = ""; ch_str = ""
    hwaddr = ""; ap_ch = 0; ssid = ""; rssi = 0; enc = ""; net = ""; bw = ""
}
function clean(s) {
    gsub(/[\r\n]+$/, "", s); gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s)
    return s
}
function escape_json(s) {
    gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
    return s
}
function flush_ap() {
    if (hwaddr == "") return
    if (ap_str != "") ap_str = ap_str ","
    ap_str = ap_str sprintf("{\"mac\":\"%s\",\"channel\":%d,\"ssid\":\"%s\",\"rssi\":%d,\"encryption\":\"%s\",\"network\":\"%s\",\"bandwidth\":\"%s\"}",
        clean(hwaddr), ap_ch, escape_json(clean(ssid)), rssi,
        escape_json(clean(enc)), escape_json(clean(net)), escape_json(clean(bw)))
    hwaddr = ""; ap_ch = 0; ssid = ""; rssi = 0; enc = ""; net = ""; bw = ""
}
/^[ \t]*={4,}/ {
    flush_ap(); in_ap = 1; next
}
/channel utilization/ {
    flush_ap(); in_ap = 0; next
}
in_ap && /^[ \t]*HwAddr:/     { sub(/^[ \t]*HwAddr:[ \t]*/,     ""); hwaddr = $0 }
in_ap && /^[ \t]*Channel:/    { sub(/^[ \t]*Channel:[ \t]*/,    ""); ap_ch  = $0 + 0 }
in_ap && /^[ \t]*SSID:/       { sub(/^[ \t]*SSID:[ \t]*/,       ""); ssid   = $0 }
in_ap && /^[ \t]*RSSI:/       { sub(/^[ \t]*RSSI:[ \t]*/,       ""); rssi   = $0 + 0 }
in_ap && /^[ \t]*Encryption:/ { sub(/^[ \t]*Encryption:[ \t]*/, ""); enc    = $0 }
in_ap && /^[ \t]*Network:/    { sub(/^[ \t]*Network:[ \t]*/,    ""); net    = $0 }
in_ap && /^[ \t]*Bandwidth:/  { sub(/^[ \t]*Bandwidth:[ \t]*/,  ""); bw     = $0 }
!in_ap && /Channel:[ \t]*[0-9]+/ && /ch_load/ {
    gsub(/[ \t]+/, "", $0)
    split($0, arr, ",")
    c=0; l=0; f=0; i=0; n=0
    for (idx in arr) {
        split(arr[idx], kv, ":")
        if (kv[1] == "Channel")        c = kv[2] + 0
        if (kv[1] == "ch_load")        l = kv[2] + 0
        if (kv[1] == "free_time")      f = kv[2] + 0
        if (kv[1] == "interence_time") i = kv[2] + 0
        if (kv[1] == "noise_level")    n = kv[2] + 0
    }
    if (c > 0) {
        if (ch_str != "") ch_str = ch_str ","
        ch_str = ch_str sprintf("{\"ch\":%d,\"load\":%d,\"free\":%d,\"inter\":%d,\"noise\":%d}", c, l, f, i, n)
    }
}
END {
    flush_ap()
    printf "{\"iface\":\"%s\",\"aps\":[%s],\"channels\":[%s]}", iface, ap_str, ch_str
}
')
        if [ -z "$RESULT" ]; then
            RESULT="{\"iface\":\"$IFACE\",\"aps\":[],\"channels\":[]}"
        fi
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '%s' "$RESULT"
        exit 0
    fi

    # --- action=sitesurvey_scan: trigger querysitesurvey, poll until ready, parse ---
    if echo "$QUERY_STRING" | busybox grep -q "action=sitesurvey_scan"; then
        IFACE=$(echo "$QUERY_STRING" | busybox sed -n 's/.*iface=\([^&]*\).*/\1/p' | busybox tr -d '\r\n')
        case "$IFACE" in
            wlan0|wlan1) ;;
            *) IFACE="wlan1" ;;
        esac
        iwpriv "$IFACE" at_ss /dev/null 2>&1
        # Poll until the kernel removes the "waitting" sentinel (scan complete)
        # or until 20s timeout, whichever comes first
        TRIES=0
        while [ $TRIES -lt 20 ]; do
            RAW=$(cat "/proc/${IFACE}/SS_Result" 2>/dev/null)
            if ! printf '%s\n' "$RAW" | busybox grep -q "^waitting"; then
                break
            fi
            busybox sleep 1
            TRIES=$((TRIES + 1))
        done
        RESULT=$(printf '%s\n' "$RAW" | busybox awk -v iface="$IFACE" '
BEGIN {
    in_ap = 0; ap_str = ""; ch_str = ""
    hwaddr = ""; ap_ch = 0; ssid = ""; rssi = 0; enc = ""; net = ""; bw = ""
}
function clean(s) {
    gsub(/[\r\n]+$/, "", s); gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s)
    return s
}
function escape_json(s) {
    gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
    return s
}
function flush_ap() {
    if (hwaddr == "") return
    if (ap_str != "") ap_str = ap_str ","
    ap_str = ap_str sprintf("{\"mac\":\"%s\",\"channel\":%d,\"ssid\":\"%s\",\"rssi\":%d,\"encryption\":\"%s\",\"network\":\"%s\",\"bandwidth\":\"%s\"}",
        clean(hwaddr), ap_ch, escape_json(clean(ssid)), rssi,
        escape_json(clean(enc)), escape_json(clean(net)), escape_json(clean(bw)))
    hwaddr = ""; ap_ch = 0; ssid = ""; rssi = 0; enc = ""; net = ""; bw = ""
}
/^[ \t]*={4,}/ {
    flush_ap(); in_ap = 1; next
}
/channel utilization/ {
    flush_ap(); in_ap = 0; next
}
in_ap && /^[ \t]*HwAddr:/     { sub(/^[ \t]*HwAddr:[ \t]*/,     ""); hwaddr = $0 }
in_ap && /^[ \t]*Channel:/    { sub(/^[ \t]*Channel:[ \t]*/,    ""); ap_ch  = $0 + 0 }
in_ap && /^[ \t]*SSID:/       { sub(/^[ \t]*SSID:[ \t]*/,       ""); ssid   = $0 }
in_ap && /^[ \t]*RSSI:/       { sub(/^[ \t]*RSSI:[ \t]*/,       ""); rssi   = $0 + 0 }
in_ap && /^[ \t]*Encryption:/ { sub(/^[ \t]*Encryption:[ \t]*/, ""); enc    = $0 }
in_ap && /^[ \t]*Network:/    { sub(/^[ \t]*Network:[ \t]*/,    ""); net    = $0 }
in_ap && /^[ \t]*Bandwidth:/  { sub(/^[ \t]*Bandwidth:[ \t]*/,  ""); bw     = $0 }
!in_ap && /Channel:[ \t]*[0-9]+/ && /ch_load/ {
    gsub(/[ \t]+/, "", $0)
    split($0, arr, ",")
    c=0; l=0; f=0; i=0; n=0
    for (idx in arr) {
        split(arr[idx], kv, ":")
        if (kv[1] == "Channel")        c = kv[2] + 0
        if (kv[1] == "ch_load")        l = kv[2] + 0
        if (kv[1] == "free_time")      f = kv[2] + 0
        if (kv[1] == "interence_time") i = kv[2] + 0
        if (kv[1] == "noise_level")    n = kv[2] + 0
    }
    if (c > 0) {
        if (ch_str != "") ch_str = ch_str ","
        ch_str = ch_str sprintf("{\"ch\":%d,\"load\":%d,\"free\":%d,\"inter\":%d,\"noise\":%d}", c, l, f, i, n)
    }
}
END {
    flush_ap()
    printf "{\"iface\":\"%s\",\"aps\":[%s],\"channels\":[%s]}", iface, ap_str, ch_str
}
')
        if [ -z "$RESULT" ]; then
            RESULT="{\"iface\":\"$IFACE\",\"aps\":[],\"channels\":[]}"
        fi
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '%s' "$RESULT"
        exit 0
    fi

    # --- action=pon_transceiver: return PON transceiver diagnostics as JSON ---
    if echo "$QUERY_STRING" | busybox grep -q "action=pon_transceiver"; then
        BIAS=$(diag pon get transceiver bias-current 2>/dev/null \
            | busybox grep "Bias Current:" \
            | busybox sed 's/.*Bias Current:[[:space:]]*//' \
            | busybox tr -d '\r\n')
        RX=$(diag pon get transceiver rx-power 2>/dev/null \
            | busybox grep "Rx Power:" \
            | busybox sed 's/.*Rx Power:[[:space:]]*//' \
            | busybox sed 's/[[:space:]]*$//' \
            | busybox tr -d '\r\n')
        TX=$(diag pon get transceiver tx-power 2>/dev/null \
            | busybox grep "Tx Power:" \
            | busybox sed 's/.*Tx Power:[[:space:]]*//' \
            | busybox sed 's/[[:space:]]*$//' \
            | busybox tr -d '\r\n')
        TEMP=$(diag pon get transceiver temperature 2>/dev/null \
            | busybox grep "Temperature:" \
            | busybox sed 's/.*Temperature:[[:space:]]*//' \
            | busybox tr -d '\r\n')
        VOLT=$(diag pon get transceiver voltage 2>/dev/null \
            | busybox grep "Voltage:" \
            | busybox sed 's/.*Voltage:[[:space:]]*//' \
            | busybox tr -d '\r\n')
        [ -z "$BIAS" ] && BIAS="-"
        [ -z "$RX"   ] && RX="-"
        [ -z "$TX"   ] && TX="-"
        [ -z "$TEMP" ] && TEMP="-"
        [ -z "$VOLT" ] && VOLT="-"
        ESC_BIAS=$(printf '%s' "$BIAS" | busybox sed 's/\\/\\\\/g; s/"/\\"/g')
        ESC_RX=$(printf '%s' "$RX"    | busybox sed 's/\\/\\\\/g; s/"/\\"/g')
        ESC_TX=$(printf '%s' "$TX"    | busybox sed 's/\\/\\\\/g; s/"/\\"/g')
        ESC_TEMP=$(printf '%s' "$TEMP"| busybox sed 's/\\/\\\\/g; s/"/\\"/g')
        ESC_VOLT=$(printf '%s' "$VOLT"| busybox sed 's/\\/\\\\/g; s/"/\\"/g')
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"bias_current":"%s","rx_power":"%s","tx_power":"%s","temperature":"%s","voltage":"%s"}' \
            "$ESC_BIAS" "$ESC_RX" "$ESC_TX" "$ESC_TEMP" "$ESC_VOLT"
        exit 0
    fi

    # --- action=lan_link_status: physical link state from diag port get status ---
    # Returns speed/duplex/status for all 4 LAN ports as reported by the switch.
    # Port 0 = LAN 1 (eth0.2), Port 1 = LAN 2 (eth0.3),
    # Port 2 = LAN 3 (eth0.4), Port 3 = LAN 4 (eth0.5).
    if echo "$QUERY_STRING" | busybox grep -q "action=lan_link_status"; then
        RAW0=$(diag port get status port 0 2>/dev/null)
        RAW1=$(diag port get status port 1 2>/dev/null)
        RAW2=$(diag port get status port 2 2>/dev/null)
        RAW3=$(diag port get status port 3 2>/dev/null)

        # Each diag call returns a block like:
        #   Port Status Speed    Duplex TX_FC RX_FC
        #   ---- ------ -----    ------ ----- -----
        #   0    Down   10M      Half   En    En
        # The data line begins with the port index digit.
        P0_STATUS=$(echo "$RAW0" | busybox awk '/^[[:space:]]*0[[:space:]]/{print $2; exit}' | busybox tr -d '\r\n')
        P0_SPEED=$( echo "$RAW0" | busybox awk '/^[[:space:]]*0[[:space:]]/{print $3; exit}' | busybox tr -d '\r\n')
        P0_DUPLEX=$(echo "$RAW0" | busybox awk '/^[[:space:]]*0[[:space:]]/{print $4; exit}' | busybox tr -d '\r\n')

        P1_STATUS=$(echo "$RAW1" | busybox awk '/^[[:space:]]*1[[:space:]]/{print $2; exit}' | busybox tr -d '\r\n')
        P1_SPEED=$( echo "$RAW1" | busybox awk '/^[[:space:]]*1[[:space:]]/{print $3; exit}' | busybox tr -d '\r\n')
        P1_DUPLEX=$(echo "$RAW1" | busybox awk '/^[[:space:]]*1[[:space:]]/{print $4; exit}' | busybox tr -d '\r\n')

        P2_STATUS=$(echo "$RAW2" | busybox awk '/^[[:space:]]*2[[:space:]]/{print $2; exit}' | busybox tr -d '\r\n')
        P2_SPEED=$( echo "$RAW2" | busybox awk '/^[[:space:]]*2[[:space:]]/{print $3; exit}' | busybox tr -d '\r\n')
        P2_DUPLEX=$(echo "$RAW2" | busybox awk '/^[[:space:]]*2[[:space:]]/{print $4; exit}' | busybox tr -d '\r\n')

        P3_STATUS=$(echo "$RAW3" | busybox awk '/^[[:space:]]*3[[:space:]]/{print $2; exit}' | busybox tr -d '\r\n')
        P3_SPEED=$( echo "$RAW3" | busybox awk '/^[[:space:]]*3[[:space:]]/{print $3; exit}' | busybox tr -d '\r\n')
        P3_DUPLEX=$(echo "$RAW3" | busybox awk '/^[[:space:]]*3[[:space:]]/{print $4; exit}' | busybox tr -d '\r\n')

        [ -z "$P0_STATUS" ] && P0_STATUS="Unknown"
        [ -z "$P0_SPEED"  ] && P0_SPEED="-"
        [ -z "$P0_DUPLEX" ] && P0_DUPLEX="-"
        [ -z "$P1_STATUS" ] && P1_STATUS="Unknown"
        [ -z "$P1_SPEED"  ] && P1_SPEED="-"
        [ -z "$P1_DUPLEX" ] && P1_DUPLEX="-"
        [ -z "$P2_STATUS" ] && P2_STATUS="Unknown"
        [ -z "$P2_SPEED"  ] && P2_SPEED="-"
        [ -z "$P2_DUPLEX" ] && P2_DUPLEX="-"
        [ -z "$P3_STATUS" ] && P3_STATUS="Unknown"
        [ -z "$P3_SPEED"  ] && P3_SPEED="-"
        [ -z "$P3_DUPLEX" ] && P3_DUPLEX="-"

        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"port0":{"status":"%s","speed":"%s","duplex":"%s"},"port1":{"status":"%s","speed":"%s","duplex":"%s"},"port2":{"status":"%s","speed":"%s","duplex":"%s"},"port3":{"status":"%s","speed":"%s","duplex":"%s"}}' \
            "$P0_STATUS" "$P0_SPEED" "$P0_DUPLEX" \
            "$P1_STATUS" "$P1_SPEED" "$P1_DUPLEX" \
            "$P2_STATUS" "$P2_SPEED" "$P2_DUPLEX" \
            "$P3_STATUS" "$P3_SPEED" "$P3_DUPLEX"
        exit 0
    fi

    # --- action=reboot_sched_get: return current auto-reboot schedule as JSON ---
    if echo "$QUERY_STRING" | busybox grep -q "action=reboot_sched_get"; then
        SCHED_FILE=/lmepisowifi/reboot_sched.conf
        if [ ! -f "$SCHED_FILE" ]; then
            printf "Status: 200 OK\r\n"
            printf "Content-Type: application/json\r\n\r\n"
            printf '{"mode":"none"}'
            exit 0
        fi
        R_MODE=$(grep '^mode='        "$SCHED_FILE" | cut -d'=' -f2- | busybox tr -d '\r\n')
        R_UPSECS=$(grep '^uptime_secs=' "$SCHED_FILE" | cut -d'=' -f2- | busybox tr -d '\r\n')
        R_TOD=$(grep '^tod_time='    "$SCHED_FILE" | cut -d'=' -f2- | busybox tr -d '\r\n')
        R_DAYS=$(grep '^days='        "$SCHED_FILE" | cut -d'=' -f2- | busybox tr -d '\r\n')
        [ -z "$R_MODE" ] && R_MODE="none"
        [ -z "$R_UPSECS" ] && R_UPSECS=0

        # Build days JSON array
        DAYS_JSON="["
        FIRST_D=1
        IFS=','
        for D in $R_DAYS; do
            [ -z "$D" ] && continue
            case "$D" in
                0|1|2|3|4|5|6) ;;
                *) continue ;;
            esac
            [ "$FIRST_D" = "1" ] && FIRST_D=0 || DAYS_JSON="${DAYS_JSON},"
            DAYS_JSON="${DAYS_JSON}${D}"
        done
        unset IFS
        DAYS_JSON="${DAYS_JSON}]"

        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"mode":"%s","uptime_secs":%s,"tod_time":"%s","days":%s}' \
            "$R_MODE" "$R_UPSECS" "$R_TOD" "$DAYS_JSON"
        exit 0
    fi

    # --- action=wan_profile_status: return nas* interface status as JSON array ---
    # Implements the same logic as the wan profile status shell script:
    #   find all nas* interfaces via ip -o link show, then for each:
    #   status from ip addr state field, IP/CIDR from inet line,
    #   subnet mask converted from CIDR, RX/TX bytes from ip -s link.
    if echo "$QUERY_STRING" | busybox grep -q "action=wan_profile_status"; then
        WAN_IFACES=$(ip -o link show 2>/dev/null \
            | busybox awk -F': ' '$2 ~ /^nas/ {print $2}')
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        if [ -z "$WAN_IFACES" ]; then
            printf '[]'
            exit 0
        fi
        printf '['
        WAN_FIRST=1
        for WAN_IFACE in $WAN_IFACES; do
            [ "$WAN_IFACE" = "nas0" ] && continue
            WAN_IP_DATA=$(ip addr show dev "$WAN_IFACE" 2>/dev/null)
            WAN_STATS=$(ip -s link show dev "$WAN_IFACE" 2>/dev/null)

            # 1. Status: extract "state UP/DOWN/..." from first line of ip addr output
            WAN_STATUS=$(printf '%s\n' "$WAN_IP_DATA" \
                | busybox awk -F'state ' '/state / {split($2, a, " "); print tolower(a[1]); exit}')
            [ -z "$WAN_STATUS" ] && WAN_STATUS="down"

            # 2. Extract IP and CIDR prefix from "inet x.x.x.x/N" line
            WAN_INET=$(printf '%s\n' "$WAN_IP_DATA" \
                | busybox awk '/inet / {print $2; exit}')
            WAN_IP=$( printf '%s' "$WAN_INET" | busybox cut -d'/' -f1)
            WAN_CIDR=$(printf '%s' "$WAN_INET" | busybox cut -d'/' -f2)
            [ -z "$WAN_IP" ] && WAN_IP="N/A"

            # 3. Convert CIDR prefix to dotted-decimal subnet mask
            WAN_MASK="N/A"
            if [ -n "$WAN_CIDR" ]; then
                WAN_MASK=$(busybox awk -v cidr="$WAN_CIDR" 'BEGIN {
                    split("0 128 192 224 240 248 252 254 255", bits, " ");
                    mask="";
                    for (i=0; i<4; i++) {
                        if (cidr >= 8) { mask = mask "255"; cidr -= 8; }
                        else if (cidr > 0) { mask = mask bits[cidr + 1]; cidr = 0; }
                        else { mask = mask "0"; }
                        if (i < 3) mask = mask ".";
                    }
                    print mask;
                }')
                [ -z "$WAN_MASK" ] && WAN_MASK="N/A"
            fi

            # 4. Extract raw RX and TX bytes from ip -s link output
            #    Format: header line "RX: bytes packets ...", then data line with counts
            WAN_RX_B=$(printf '%s\n' "$WAN_STATS" \
                | busybox awk '/RX:/ {getline; print $1; exit}')
            WAN_TX_B=$(printf '%s\n' "$WAN_STATS" \
                | busybox awk '/TX:/ {getline; print $1; exit}')

            # 5. Convert bytes to MiB with 2 decimal places
            WAN_RX_MB=$(busybox awk -v b="${WAN_RX_B:-0}" 'BEGIN {printf "%.2f", b/1048576}')
            WAN_TX_MB=$(busybox awk -v b="${WAN_TX_B:-0}" 'BEGIN {printf "%.2f", b/1048576}')

            # JSON-escape all string fields
            ESC_IFACE=$( printf '%s' "$WAN_IFACE"  | busybox sed 's/\\/\\\\/g; s/"/\\"/g')
            ESC_STATUS=$(printf '%s' "$WAN_STATUS" | busybox sed 's/\\/\\\\/g; s/"/\\"/g')
            ESC_IP=$(    printf '%s' "$WAN_IP"     | busybox sed 's/\\/\\\\/g; s/"/\\"/g')
            ESC_MASK=$(  printf '%s' "$WAN_MASK"   | busybox sed 's/\\/\\\\/g; s/"/\\"/g')

            [ "$WAN_FIRST" = "1" ] && WAN_FIRST=0 || printf ','
            printf '{"ifname":"%s","status":"%s","ipaddr":"%s","subnetmask":"%s","rx_mb":"%s","tx_mb":"%s"}' \
                "$ESC_IFACE" "$ESC_STATUS" "$ESC_IP" "$ESC_MASK" "$WAN_RX_MB" "$WAN_TX_MB"
        done
        printf ']'
        exit 0
    fi

    # --- action=get_layout: return stored dashboard card layout as JSON ---
    if echo "$QUERY_STRING" | busybox grep -q "action=get_layout"; then
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        if [ -f "$LAYOUT_FILE" ]; then
            cat "$LAYOUT_FILE"
        else
            printf 'null'
        fi
        exit 0
    fi

    # --- Default GET: return current SSID as plain text ---
    CURRENT_SSID=$(get_ssid)
    printf "Status: 200 OK\r\n"
    printf "Content-Type: text/plain\r\n\r\n"
    printf "%s" "$CURRENT_SSID"
    exit 0
fi

# ==========================================
# POST MODE
# ==========================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    # Clamp body size: reject non-numeric and cap to 64KB to stop a
    # malicious Content-Length from forcing a huge/slow byte-by-byte read (DoS).
    __CL="${CONTENT_LENGTH:-0}"; case "$__CL" in *[!0-9]*|"") __CL=0 ;; esac
    [ "$__CL" -gt 65536 ] && __CL=65536
    POST_DATA=$(busybox dd bs=1 count="$__CL" 2>/dev/null)

    # --- action=save_layout: persist dashboard card layout to data dir ---
    if echo "$QUERY_STRING" | busybox grep -q "action=save_layout"; then
        # Body must be a JSON array (client sends raw JSON, not form-encoded)
        _LY=$(printf '%s' "$POST_DATA" | busybox tr -d '\r\n ')
        _LY_FIRST=$(printf '%s' "$_LY" | busybox cut -c1)
        _LY_LAST=$(printf '%s' "$_LY"  | busybox awk '{print substr($0,length($0),1)}')
        if [ "$_LY_FIRST" != "[" ] || [ "$_LY_LAST" != "]" ]; then
            printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
            printf "Invalid layout"
            exit 0
        fi
        mkdir -p "$DATA_DIR"
        _LY_TMP="${LAYOUT_FILE}.tmp.$$"
        printf '%s' "$_LY" > "$_LY_TMP"
        busybox mv "$_LY_TMP" "$LAYOUT_FILE"
        printf "Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # --- action=system_settings: apply HW S/N, MAC, PON mode ---
    if echo "$QUERY_STRING" | busybox grep -q "action=system_settings"; then
        FORM_HW_SERIAL=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^hw_serial=' | busybox cut -d'=' -f2-)
        FORM_HW_SERIAL=$(busybox httpd -d "$FORM_HW_SERIAL" \
            | busybox tr -d '\r\n' \
            | busybox tr 'a-z' 'A-Z')
        FORM_MAC=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*mac=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n' \
            | busybox tr 'A-Z' 'a-z')
        FORM_PON_MODE=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*pon_mode=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        FORM_PON_AUTO=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*pon_auto=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')

        # Validate HW Serial: 4-32 uppercase alphanumeric chars (hyphens allowed)
        HW_SN_LEN=$(echo -n "$FORM_HW_SERIAL" | busybox wc -c | busybox tr -d ' ')
        if [ -n "$FORM_HW_SERIAL" ]; then
            if [ "$HW_SN_LEN" -lt 4 ] || [ "$HW_SN_LEN" -gt 32 ]; then
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid hardware serial: must be 4-32 characters"
                exit 0
            fi
            if ! echo "$FORM_HW_SERIAL" | busybox grep -qE '^[A-Z0-9][A-Z0-9-]{2,30}[A-Z0-9]$'; then
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid hardware serial: alphanumeric and hyphens only"
                exit 0
            fi
        fi

        # Validate MAC: exactly 12 hex chars (no colons, sent pre-stripped by JS)
        MAC_LEN=$(echo -n "$FORM_MAC" | busybox wc -c | busybox tr -d ' ')
        if [ "$MAC_LEN" != "12" ] || ! echo "$FORM_MAC" | busybox grep -qE '^[0-9a-f]{12}$'; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid MAC address"
            exit 0
        fi
        if [ "$FORM_MAC" = "000000000000" ] || [ "$FORM_MAC" = "ffffffffffff" ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid MAC address"
            exit 0
        fi

        # Validate PON mode: 1, 2, or 3
        case "$FORM_PON_MODE" in
            1|2|3) ;;
            *) FORM_PON_MODE=1 ;;
        esac

        # Validate PON auto: 0 or 1
        case "$FORM_PON_AUTO" in
            0|1) ;;
            *) FORM_PON_AUTO=1 ;;
        esac

        # Read current PON settings BEFORE applying so we can detect changes
        CUR_PON_AUTO=$(mib get PON_MODE_AUTO_CHECK_ENABLE 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2 \
            | busybox tr -d '\r\n')
        CUR_PON_MODE=$(mib get PON_MODE 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2 \
            | busybox tr -d '\r\n')
        [ -z "$CUR_PON_AUTO" ] && CUR_PON_AUTO=1
        [ -z "$CUR_PON_MODE" ] && CUR_PON_MODE=1

        [ -n "$FORM_HW_SERIAL" ] && mib set HW_SERIAL_NO "$FORM_HW_SERIAL"
        mib set ELAN_MAC_ADDR "$FORM_MAC"
        mib set PON_MODE_AUTO_CHECK_ENABLE "$FORM_PON_AUTO"
        if [ "$FORM_PON_AUTO" = "0" ]; then
            mib set PON_MODE "$FORM_PON_MODE"
        fi
        mib commit

        # Determine whether a reboot is needed (PON mode or auto-detect changed)
        PON_CHANGED=0
        if [ "$FORM_PON_AUTO" != "$CUR_PON_AUTO" ]; then
            PON_CHANGED=1
        elif [ "$FORM_PON_AUTO" = "0" ] && [ "$FORM_PON_MODE" != "$CUR_PON_MODE" ]; then
            PON_CHANGED=1
        fi

        if [ "$PON_CHANGED" = "1" ]; then
            printf "Status: 200 OK\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "REBOOT"
            ( sleep 3; sync; reboot ) &
            exit 0
        fi

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # --- action=account_settings: change admin (superuser) name / password ---
    if echo "$QUERY_STRING" | busybox grep -q "action=account_settings"; then
        # Require the current password to authorise the change
        FORM_CURPASS=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^cur_passwd=' | busybox cut -d'=' -f2-)
        FORM_CURPASS=$(busybox httpd -d "$FORM_CURPASS" | busybox tr -d '\r\n')

        FORM_SUSER=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^suser_name=' | busybox cut -d'=' -f2-)
        FORM_SUSER=$(busybox httpd -d "$FORM_SUSER" | busybox tr -d '\r\n')

        FORM_SPASS=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^suser_passwd=' | busybox cut -d'=' -f2-)
        FORM_SPASS=$(busybox httpd -d "$FORM_SPASS" | busybox tr -d '\r\n')

        # Verify current password matches what is stored
        REAL_PASS=$(mib get SUSER_PASSWORD 2>/dev/null \
            | busybox grep "SUSER_PASSWORD=" \
            | busybox cut -d'=' -f2- \
            | busybox tr -d '\r\n')
        if [ "$FORM_CURPASS" != "$REAL_PASS" ]; then
            printf "Status: 403 Forbidden\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Current password is incorrect"
            exit 0
        fi

        # Validate new username: 1-32 chars, letters/digits/._- only
        SUSER_LEN=$(echo -n "$FORM_SUSER" | busybox wc -c | busybox tr -d ' ')
        if [ -z "$FORM_SUSER" ] || [ "$SUSER_LEN" -gt 32 ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid username: must be 1-32 characters"
            exit 0
        fi
        if ! echo "$FORM_SUSER" | busybox grep -qE '^[A-Za-z0-9._-]+$'; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid username: letters, digits, dot, underscore, hyphen only"
            exit 0
        fi

        # Validate new password: 4-32 chars, no spaces (only if a new one is given)
        if [ -n "$FORM_SPASS" ]; then
            SPASS_LEN=$(echo -n "$FORM_SPASS" | busybox wc -c | busybox tr -d ' ')
            if [ "$SPASS_LEN" -lt 4 ] || [ "$SPASS_LEN" -gt 32 ]; then
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid password: must be 4-32 characters"
                exit 0
            fi
            case "$FORM_SPASS" in
                *" "*)
                    printf "Status: 400 Bad Request\r\n"
                    printf "Content-Type: text/plain\r\n\r\n"
                    printf "Invalid password: spaces not allowed"
                    exit 0
                    ;;
            esac
        fi

        # Apply changes
        mib set SUSER_NAME "$FORM_SUSER"
        [ -n "$FORM_SPASS" ] && mib set SUSER_PASSWORD "$FORM_SPASS"
        mib commit

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # --- action=lan_ip_save: apply LAN IP address and subnet mask ---
    if echo "$QUERY_STRING" | busybox grep -q "action=lan_ip_save"; then
        FORM_IP=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^ip=' | busybox cut -d'=' -f2-)
        FORM_IP=$(busybox httpd -d "$FORM_IP" | busybox tr -d '\r\n')
        FORM_SN=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^subnet=' | busybox cut -d'=' -f2-)
        FORM_SN=$(busybox httpd -d "$FORM_SN" | busybox tr -d '\r\n')

        # Validate: four dot-separated octets 0-255
        VALID_IP=$(echo "$FORM_IP" | busybox awk -F. '
            NF==4 { ok=1; for(i=1;i<=4;i++) if($i!~/^[0-9]+$/||$i+0>255) ok=0; print ok; exit }
            { print 0 }')
        if [ "$VALID_IP" != "1" ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid IP address"
            exit 0
        fi
        VALID_SN=$(echo "$FORM_SN" | busybox awk -F. '
            NF==4 { ok=1; for(i=1;i<=4;i++) if($i!~/^[0-9]+$/||$i+0>255) ok=0; print ok; exit }
            { print 0 }')
        if [ "$VALID_SN" != "1" ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid subnet mask"
            exit 0
        fi

        CUR_IP=$(mib get LAN_IP_ADDR 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- \
            | busybox tr -d '\r\n')
        CUR_SN=$(mib get LAN_SUBNET 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- \
            | busybox tr -d '\r\n')

        if [ "$FORM_IP" != "$CUR_IP" ] || [ "$FORM_SN" != "$CUR_SN" ]; then
            /bin/ifconfig br0 "$FORM_IP" netmask "$FORM_SN" mtu 1500
        fi
        mib set LAN_IP_ADDR "$FORM_IP"
        mib set LAN_SUBNET "$FORM_SN"
        mib commit

        # LAN IP just changed -- udhcpd.conf's "server" line is now stale, rebuild + restart it.
        sh /lmepisowifi/www2/sh/dhcp_control.sh restart

        # Return new IP so the client can redirect if it changed
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"ip":"%s"}' "$FORM_IP"
        exit 0
    fi

    # --- action=dhcp_save: apply DHCP server pool/lease/DNS settings ---
    if echo "$QUERY_STRING" | busybox grep -q "action=dhcp_save"; then
        FORM_POOL_START=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^pool_start=' | busybox cut -d'=' -f2-)
        FORM_POOL_START=$(busybox httpd -d "$FORM_POOL_START" | busybox tr -d '\r\n')
        FORM_POOL_END=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^pool_end=' | busybox cut -d'=' -f2-)
        FORM_POOL_END=$(busybox httpd -d "$FORM_POOL_END" | busybox tr -d '\r\n')
        FORM_MASK=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^mask=' | busybox cut -d'=' -f2-)
        FORM_MASK=$(busybox httpd -d "$FORM_MASK" | busybox tr -d '\r\n')
        FORM_GATEWAY=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^gateway=' | busybox cut -d'=' -f2-)
        FORM_GATEWAY=$(busybox httpd -d "$FORM_GATEWAY" | busybox tr -d '\r\n')
        FORM_LEASE=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^lease=' | busybox cut -d'=' -f2-)
        FORM_LEASE=$(busybox httpd -d "$FORM_LEASE" | busybox tr -d '\r\n')
        FORM_DOMAIN=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^domain=' | busybox cut -d'=' -f2-)
        FORM_DOMAIN=$(busybox httpd -d "$FORM_DOMAIN" | busybox tr -d '\r\n')
        FORM_DNS_OPT=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^dns_opt=' | busybox cut -d'=' -f2-)
        FORM_DNS_OPT=$(busybox httpd -d "$FORM_DNS_OPT" | busybox tr -d '\r\n')
        FORM_DNS1=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^dns1=' | busybox cut -d'=' -f2-)
        FORM_DNS1=$(busybox httpd -d "$FORM_DNS1" | busybox tr -d '\r\n')
        FORM_DNS2=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^dns2=' | busybox cut -d'=' -f2-)
        FORM_DNS2=$(busybox httpd -d "$FORM_DNS2" | busybox tr -d '\r\n')
        FORM_DNS3=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^dns3=' | busybox cut -d'=' -f2-)
        FORM_DNS3=$(busybox httpd -d "$FORM_DNS3" | busybox tr -d '\r\n')

        # Validate pool start/end, mask, gateway: four dot-separated octets 0-255
        # (same validator as lan_ip_save, reused rather than rewritten)
        VALID_START=$(echo "$FORM_POOL_START" | busybox awk -F. '
            NF==4 { ok=1; for(i=1;i<=4;i++) if($i!~/^[0-9]+$/||$i+0>255) ok=0; print ok; exit }
            { print 0 }')
        if [ "$VALID_START" != "1" ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid pool start address"
            exit 0
        fi
        VALID_END=$(echo "$FORM_POOL_END" | busybox awk -F. '
            NF==4 { ok=1; for(i=1;i<=4;i++) if($i!~/^[0-9]+$/||$i+0>255) ok=0; print ok; exit }
            { print 0 }')
        if [ "$VALID_END" != "1" ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid pool end address"
            exit 0
        fi
        VALID_MASK=$(echo "$FORM_MASK" | busybox awk -F. '
            NF==4 { ok=1; for(i=1;i<=4;i++) if($i!~/^[0-9]+$/||$i+0>255) ok=0; print ok; exit }
            { print 0 }')
        if [ "$VALID_MASK" != "1" ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid subnet mask"
            exit 0
        fi
        VALID_GW=$(echo "$FORM_GATEWAY" | busybox awk -F. '
            NF==4 { ok=1; for(i=1;i<=4;i++) if($i!~/^[0-9]+$/||$i+0>255) ok=0; print ok; exit }
            { print 0 }')
        if [ "$VALID_GW" != "1" ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid gateway address"
            exit 0
        fi

        # Lease: positive integer
        case "$FORM_LEASE" in
            ''|*[!0-9]*)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid lease time"
                exit 0
                ;;
        esac
        if [ "$FORM_LEASE" -le 0 ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Lease time must be positive"
            exit 0
        fi

        # Domain: non-empty
        if [ -z "$FORM_DOMAIN" ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Domain must not be empty"
            exit 0
        fi

        # DNS opt: 0/1 only
        case "$FORM_DNS_OPT" in
            0|1) ;;
            *) FORM_DNS_OPT=0 ;;
        esac

        # DNS servers are optional (dhcp_control.sh falls back to this router's
        # IP when dns_opt=0 or all three are blank) -- validate only if set.
        for _DNS_VAL in "$FORM_DNS1" "$FORM_DNS2" "$FORM_DNS3"; do
            if [ -n "$_DNS_VAL" ]; then
                _DNS_OK=$(echo "$_DNS_VAL" | busybox awk -F. '
                    NF==4 { ok=1; for(i=1;i<=4;i++) if($i!~/^[0-9]+$/||$i+0>255) ok=0; print ok; exit }
                    { print 0 }')
                if [ "$_DNS_OK" != "1" ]; then
                    printf "Status: 400 Bad Request\r\n"
                    printf "Content-Type: text/plain\r\n\r\n"
                    printf "Invalid DNS server address"
                    exit 0
                fi
            fi
        done

        mib set LAN_DHCP_POOL_START "$FORM_POOL_START"
        mib set LAN_DHCP_POOL_END "$FORM_POOL_END"
        mib set DHCP_SUBNET_MASK "$FORM_MASK"
        mib set LAN_DHCP_GATEWAY "$FORM_GATEWAY"
        mib set LAN_DHCP_LEASE "$FORM_LEASE"
        mib set LAN_DHCP_DOMAIN "$FORM_DOMAIN"
        mib set LAN_DHCP_DNS_OPT "$FORM_DNS_OPT"
        mib set DHCPS_DNS1 "$FORM_DNS1"
        mib set DHCPS_DNS2 "$FORM_DNS2"
        mib set DHCPS_DNS3 "$FORM_DNS3"
        mib commit

        sh /lmepisowifi/www2/sh/dhcp_control.sh restart

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # --- action=dhcp_enable: enable/disable DHCP server, mirrors macfilter_mode's revert-timer shape ---
    if echo "$QUERY_STRING" | busybox grep -q "action=dhcp_enable"; then
        FORM_MODE=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*mode=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        case "$FORM_MODE" in
            0|1) ;;
            *)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid mode value"
                exit 0
                ;;
        esac

        OLD_MODE=$(mib get DHCP_MODE 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- | busybox tr -d '\r\n')
        [ -z "$OLD_MODE" ] && OLD_MODE=0

        # Save rollback state
        rm -f "$DHCP_REVERT_PENDING" "$DHCP_REVERT_MODE" "$DHCP_REVERT_START"
        echo "$OLD_MODE" > "$DHCP_REVERT_MODE"
        touch "$DHCP_REVERT_PENDING"
        date +%s > "$DHCP_REVERT_START"

        if [ "$FORM_MODE" = "0" ]; then
            mib set DHCP_MODE 0
            mib set LAN_DHCP 0
            mib commit
            sh /lmepisowifi/www2/sh/dhcp_control.sh stop
        else
            mib set DHCP_MODE 2
            mib set LAN_DHCP 1
            mib commit
            sh /lmepisowifi/www2/sh/dhcp_control.sh restart
        fi

        # Background revert timer (same shape as macfilter_mode's)
        (
            sleep $DHCP_REVERT_TIMEOUT
            if [ -f "$DHCP_REVERT_PENDING" ]; then
                RB_MODE=$(cat "$DHCP_REVERT_MODE")
                mib set DHCP_MODE "$RB_MODE"
                if [ "$RB_MODE" = "0" ]; then
                    mib set LAN_DHCP 0
                    mib commit
                    sh /lmepisowifi/www2/sh/dhcp_control.sh stop
                else
                    mib set LAN_DHCP 1
                    mib commit
                    sh /lmepisowifi/www2/sh/dhcp_control.sh restart
                fi
                rm -f "$DHCP_REVERT_PENDING" "$DHCP_REVERT_MODE" "$DHCP_REVERT_START"
            fi
        ) &

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # --- action=gpon_settings: apply GPON SN, LOID, LOID password, PLOAM password ---
    if echo "$QUERY_STRING" | busybox grep -q "action=gpon_settings"; then
        FORM_SN=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^gpon_sn=' | busybox cut -d'=' -f2-)
        FORM_SN=$(busybox httpd -d "$FORM_SN" | busybox tr -d '\r\n' \
            | busybox tr 'a-z' 'A-Z')
        FORM_LOID=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^loid=' | busybox cut -d'=' -f2-)
        FORM_LOID=$(busybox httpd -d "$FORM_LOID" | busybox tr -d '\r\n')
        FORM_LOID_PW=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^loid_passwd=' | busybox cut -d'=' -f2-)
        FORM_LOID_PW=$(busybox httpd -d "$FORM_LOID_PW" | busybox tr -d '\r\n')
        FORM_PLOAM=$(echo "$POST_DATA" | busybox sed 's/&/\n/g' \
            | busybox grep '^ploam_passwd=' | busybox cut -d'=' -f2-)
        FORM_PLOAM=$(busybox httpd -d "$FORM_PLOAM" | busybox tr -d '\r\n')

        # Validate GPON SN: exactly 12 chars, first 4 letters, last 8 hex
        SN_LEN=$(echo -n "$FORM_SN" | busybox wc -c | busybox tr -d ' ')
        SN_VENDOR=$(echo "$FORM_SN" | busybox cut -c1-4)
        SN_HEX=$(echo "$FORM_SN" | busybox cut -c5-12)
        if [ "$SN_LEN" != "12" ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid GPON SN: must be 12 characters"
            exit 0
        fi
        if ! echo "$SN_VENDOR" | busybox grep -qiE '^[A-Za-z]{4}$'; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid GPON SN: first 4 chars must be letters"
            exit 0
        fi
        if ! echo "$SN_HEX" | busybox grep -qiE '^[0-9A-Fa-f]{8}$'; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid GPON SN: last 8 chars must be hex digits"
            exit 0
        fi

        # Get current SN to detect change
        CUR_GPON_SN=$(mib get GPON_SN 2>/dev/null \
            | busybox grep "=" | busybox cut -d'=' -f2- \
            | busybox tr -d '\r\n')

        SN_CHANGED=0
        [ "$FORM_SN" != "$CUR_GPON_SN" ] && SN_CHANGED=1

        # Apply all MIB settings synchronously before responding
        [ "$SN_CHANGED" = "1" ] && mib set GPON_SN "$FORM_SN"
        mib set LOID "$FORM_LOID"
        mib set LOID_PASSWD "$FORM_LOID_PW"
        mib set GPON_PLOAM_PASSWD "$FORM_PLOAM"
        mib commit

        # Check igmpd state now (before forking) so the subshell inherits the flag
        if busybox pidof igmpd >/dev/null; then
            NEED_IGMP_RESTART=1
        else
            NEED_IGMP_RESTART=0
        fi

        # Respond immediately — before omci_app restart can disrupt the connection
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"

        # Restart omci_app (and optionally igmpd) in the background so the
        # HTTP response is already delivered before any network disruption occurs
        (
            # If SN changed, cycle the GPON link layer first
            if [ "$SN_CHANGED" = "1" ]; then
                diag gpon deactivate
                diag gpon set serialnumber "$FORM_SN"
                sleep 1
                gpon activate init-state o1
            fi

            # Stop igmpd if it was running
            if [ "$NEED_IGMP_RESTART" = "1" ]; then
                busybox killall igmpd 2>/dev/null
                sleep 1
                busybox killall -9 igmpd 2>/dev/null
            fi

            # Restart omci_app
            busybox killall omci_app 2>/dev/null
            sleep 1
            /etc/runomci.sh 2>/dev/null

            # Restart igmpd if it was originally running and runomci.sh didn't revive it
            if [ "$NEED_IGMP_RESTART" = "1" ]; then
                sleep 2
                if ! busybox pidof igmpd >/dev/null; then
                    /etc/runigmp.sh 2>/dev/null
                fi
            fi
        ) &

        exit 0
    fi


    # --- action=macfilter_mode: set WLAN1_MACAC_ENABLED with revert ---
    if echo "$QUERY_STRING" | busybox grep -q "action=macfilter_mode"; then
        FORM_MODE=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*mode=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        case "$FORM_MODE" in
            0|1|2) ;;
            *)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid mode value"
                exit 0
                ;;
        esac

        OLD_MODE=$(get_mac_mode)
        [ -z "$OLD_MODE" ] && OLD_MODE=0

        # Save rollback state
        rm -f "$MAC_REVERT_PENDING" "$MAC_REVERT_MODE" "$MAC_REVERT_START"
        echo "$OLD_MODE" > "$MAC_REVERT_MODE"
        touch "$MAC_REVERT_PENDING"
        date +%s > "$MAC_REVERT_START"

        mib set WLAN1_MACAC_ENABLED "$FORM_MODE"
        mib commit
        wlan_apply restart

        # Background revert timer
        (
            sleep $MAC_REVERT_TIMEOUT
            if [ -f "$MAC_REVERT_PENDING" ]; then
                RB_MODE=$(cat "$MAC_REVERT_MODE")
                mib set WLAN1_MACAC_ENABLED "$RB_MODE"
                mib commit
                wlan_apply restart
                rm -f "$MAC_REVERT_PENDING" "$MAC_REVERT_MODE" "$MAC_REVERT_START"
            fi
        ) &

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # --- action=macfilter_add: add a new MAC to WLAN1_AC_TBL ---
    if echo "$QUERY_STRING" | busybox grep -q "action=macfilter_add"; then
        FORM_MAC=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*mac=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n' \
            | busybox tr 'A-Z' 'a-z')

        # Validate: exactly 12 hex chars (wire format, no colons)
        case "$FORM_MAC" in
            ''|*[!0-9a-f]*)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid MAC address"
                exit 0
                ;;
        esac
        if [ ${#FORM_MAC} -ne 12 ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid MAC address length"
            exit 0
        fi

        # Reject all-zero MAC
        if [ "$FORM_MAC" = "000000000000" ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid MAC address"
            exit 0
        fi

        # Duplicate check: scan existing wlanIdx=1 entries
        EXISTING=$(mib get WLAN1_AC_TBL 2>/dev/null)
        if echo "$EXISTING" | busybox grep -iq "MacAddr[[:space:]]*=[[:space:]]*$FORM_MAC"; then
            printf "Status: 409 Conflict\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "MAC already exists"
            exit 0
        fi

        # Add new record: mib add returns new NUM, new index = NUM-1
        ADD_OUT=$(mib add WLAN1_AC_TBL 2>&1)
        NEW_NUM=$(echo "$ADD_OUT" | busybox sed -n 's/.*NUM=\([0-9]*\).*/\1/p' | busybox tr -d '\r\n')
        if [ -z "$NEW_NUM" ]; then
            printf "Status: 500 Internal Server Error\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Failed to allocate table entry"
            exit 0
        fi
        NEW_IDX=$((NEW_NUM - 1))

        mib set "WLAN1_AC_TBL.${NEW_IDX}.wlanIdx" 1
        mib set "WLAN1_AC_TBL.${NEW_IDX}.MacAddr" "$FORM_MAC"
        mib commit
        wlan_apply restart

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # --- action=macfilter_del: delete a MAC entry by table index ---
    if echo "$QUERY_STRING" | busybox grep -q "action=macfilter_del"; then
        FORM_IDX=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*index=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')

        # Validate: non-negative integer
        case "$FORM_IDX" in
            ''|*[!0-9]*)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid index"
                exit 0
                ;;
        esac

        # Verify the entry exists and belongs to wlan1
        ENTRY=$(mib get "WLAN1_AC_TBL.${FORM_IDX}" 2>/dev/null)
        if [ -z "$ENTRY" ]; then
            printf "Status: 404 Not Found\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Entry not found"
            exit 0
        fi
        ENTRY_WIDX=$(echo "$ENTRY" | busybox sed -n 's/.*wlanIdx[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' | busybox tr -d '\r\n')
        if [ "$ENTRY_WIDX" != "1" ]; then
            printf "Status: 403 Forbidden\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Entry does not belong to WLAN1"
            exit 0
        fi

        mib del "WLAN1_AC_TBL.${FORM_IDX}"
        mib commit
        wlan_apply restart

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi


    # --- LAN port set: detected by presence of 'port=' in POST data ---
    if echo "$POST_DATA" | busybox grep -q "port="; then
        PORT=$(echo "$POST_DATA" | busybox sed -n 's/.*port=\([^&]*\).*/\1/p' | busybox tr -d '\r\n')
        POWER=$(echo "$POST_DATA" | busybox sed -n 's/.*power=\([^&]*\).*/\1/p' | busybox tr -d '\r\n')
        SPEED_RAW=$(echo "$POST_DATA" | busybox sed -n 's/.*speed=\([^&]*\).*/\1/p' | busybox tr -d '\r\n')
        SPEED_RAW=$(echo "$SPEED_RAW" | busybox sed 's/+/ /g')
        SPEED=$(busybox httpd -d "$SPEED_RAW" | busybox tr -d '\r\n')

        # Validate port
        case "$PORT" in
            1|2|3|4) ;;
            *)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid port: '%s'" "$PORT"
                exit 0
                ;;
        esac

        # Validate power
        case "$POWER" in
            enable|disable|"") ;;
            *)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid power value: '%s'" "$POWER"
                exit 0
                ;;
        esac

        # Read current port state for rollback
        STATUS_RAW=$(sh "$LAN_SH" status 2>&1)
        OLD_PWR_VAL=$(echo "$STATUS_RAW" | busybox sed -n "s/.*PORT${PORT}_PWR=\"\([^\"]*\)\".*/\1/p")
        OLD_SPD=$(echo "$STATUS_RAW" | busybox sed -n "s/.*PORT${PORT}_SPEED=\"\([^\"]*\)\".*/\1/p")
        case "$OLD_PWR_VAL" in
            enabled)  OLD_POWER=enable  ;;
            disabled) OLD_POWER=disable ;;
            *)        OLD_POWER=""      ;;
        esac

        # Build argument list for lan.sh
        ARGS="$PORT"
        case "$POWER" in
            enable)  ARGS="$ARGS --enable"  ;;
            disable) ARGS="$ARGS --disable" ;;
        esac
        if [ -n "$SPEED" ]; then
            ARGS="$ARGS --speed $SPEED"
        fi

        OUT=$(sh "$LAN_SH" $ARGS 2>&1)

        if echo "$OUT" | busybox grep -q 'STATUS="SUCCESS"'; then
            # Save rollback state and start background revert timer
            rm -f "$LAN_REVERT_PENDING" "$LAN_REVERT_PORT" "$LAN_REVERT_POWER" "$LAN_REVERT_SPEED" "$LAN_REVERT_START"
            echo "$PORT"      > "$LAN_REVERT_PORT"
            echo "$OLD_POWER" > "$LAN_REVERT_POWER"
            echo "$OLD_SPD"   > "$LAN_REVERT_SPEED"
            touch "$LAN_REVERT_PENDING"
            date +%s > "$LAN_REVERT_START"

            # Persist the new speed to startup.sh so it survives reboots.
            # Expand the user-supplied SPEED into canonical ordered abilities
            # (same ordering lan.sh uses: 10h 10f 100h 100f 1000f).
            # "auto" means all speeds enabled = the default after reboot, so
            # remove any existing entry for this port rather than adding one.
            if [ -n "$SPEED" ]; then
                if echo "$SPEED" | busybox grep -qi "auto"; then
                    PERSIST_SPEED=""
                else
                    _SPDC=$(busybox echo "$SPEED" | busybox tr '[:upper:]' '[:lower:]')
                    PERSIST_SPEED=""
                    for _SP in 10h 10f 100h 100f 1000f; do
                        case " $_SPDC " in
                            *" $_SP "*) PERSIST_SPEED="$PERSIST_SPEED $_SP" ;;
                        esac
                    done
                    PERSIST_SPEED="${PERSIST_SPEED# }"
                fi
                update_startup_speed "$PORT" "$PERSIST_SPEED"
            fi

            (
                sleep $LAN_REVERT_TIMEOUT
                if [ -f "$LAN_REVERT_PENDING" ]; then
                    RB_PORT=$(cat "$LAN_REVERT_PORT")
                    RB_PWR=$(cat "$LAN_REVERT_POWER")
                    RB_SPD=$(cat "$LAN_REVERT_SPEED")
                    RB_ARGS="$RB_PORT"
                    case "$RB_PWR" in
                        enable)  RB_ARGS="$RB_ARGS --enable"  ;;
                        disable) RB_ARGS="$RB_ARGS --disable" ;;
                    esac
                    [ -n "$RB_SPD" ] && RB_ARGS="$RB_ARGS --speed $RB_SPD"
                    sh "$LAN_SH" $RB_ARGS 2>&1
                    rm -f "$LAN_REVERT_PENDING" "$LAN_REVERT_PORT" "$LAN_REVERT_POWER" "$LAN_REVERT_SPEED" "$LAN_REVERT_START"
                    # Also revert startup.sh back to the pre-change speed so
                    # the next reboot does not re-apply the discarded setting.
                    if echo "$RB_SPD" | busybox grep -qi "auto" || [ -z "$RB_SPD" ]; then
                        RB_PERSIST=""
                    else
                        _RBDC=$(busybox echo "$RB_SPD" | busybox tr '[:upper:]' '[:lower:]')
                        RB_PERSIST=""
                        for _RBSP in 10h 10f 100h 100f 1000f; do
                            case " $_RBDC " in
                                *" $_RBSP "*) RB_PERSIST="$RB_PERSIST $_RBSP" ;;
                            esac
                        done
                        RB_PERSIST="${RB_PERSIST# }"
                    fi
                    update_startup_speed "$RB_PORT" "$RB_PERSIST"
                fi
            ) &

            printf "Status: 200 OK\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "OK"
        else
            ERR=$(echo "$OUT" | busybox sed -n 's/.*ERROR="\([^"]*\)".*/\1/p')
            [ -z "$ERR" ] && ERR="$OUT"
            printf "Status: 500 Internal Server Error\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "%s" "$ERR"
        fi
        exit 0
    fi

    # --- action=reboot: immediate device reboot ---
    if echo "$QUERY_STRING" | busybox grep -q "action=reboot"; then
        FORM_CONFIRM=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*confirm=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        if [ "$FORM_CONFIRM" != "1" ]; then
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Missing confirmation"
            exit 0
        fi
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        ( sleep 1; sync; reboot ) &
        exit 0
    fi

    # --- action=reboot_sched_set: write schedule config and (re)start background daemon ---
    # No crond required.  reboot_sched.sh runs as a persistent background process
    # started by startup.sh.  lme.cgi kills the old instance and starts a new one
    # so config changes take effect immediately without a reboot.
    if echo "$QUERY_STRING" | busybox grep -q "action=reboot_sched_set"; then
        SCHED_FILE=/lmepisowifi/reboot_sched.conf
        SCHED_DAEMON=/lmepisowifi/www2/sh/reboot_sched.sh
        SCHED_PID=/tmp/reboot_sched.pid

        FORM_MODE=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*mode=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        case "$FORM_MODE" in
            none|uptime|time) ;;
            *)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid mode"
                exit 0
                ;;
        esac

        # ── Helper: kill the running daemon instance (if any) ────────────────
        _kill_sched_daemon() {
            if [ -f "$SCHED_PID" ]; then
                OLD_PID=$(cat "$SCHED_PID" | busybox tr -d '\r\n')
                if [ -n "$OLD_PID" ]; then
                    kill "$OLD_PID" 2>/dev/null
                    busybox sleep 1
                    kill -0 "$OLD_PID" 2>/dev/null && kill -9 "$OLD_PID" 2>/dev/null
                fi
                rm -f "$SCHED_PID"
            fi
            busybox pkill -f "$SCHED_DAEMON" 2>/dev/null || true
            rm -f /tmp/reboot_sched_fired
        }

        # ── Helper: update startup.sh BEGIN_REBOOT_SCHED section ────────────
        _update_startup_sched() {
            _UPD_ENABLE="$1"
            [ ! -f "$STARTUP_SH" ] && return
            _UPD_TMP="/tmp/startup_sched_$$.tmp"
            busybox awk \
                -v enable="$_UPD_ENABLE" \
                -v daemon="$SCHED_DAEMON" \
                'BEGIN { in_sec=0 }
                 /^# --- BEGIN_REBOOT_SCHED ---/ { print; in_sec=1; next }
                 /^# --- END_REBOOT_SCHED ---/   {
                     if (enable == "1") { print daemon " &" }
                     in_sec=0; print; next
                 }
                 in_sec { next }
                 { print }' \
                "$STARTUP_SH" > "$_UPD_TMP" \
            && busybox mv "$_UPD_TMP" "$STARTUP_SH" \
            && busybox chmod 755 "$STARTUP_SH"
        }

        # ── mode=none ─────────────────────────────────────────────────────────
        if [ "$FORM_MODE" = "none" ]; then
            _kill_sched_daemon
            rm -f "$SCHED_FILE"
            _update_startup_sched 0
            printf "Status: 200 OK\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "OK"
            exit 0
        fi

        # ── mode=uptime ───────────────────────────────────────────────────────
        if [ "$FORM_MODE" = "uptime" ]; then
            FORM_UPSECS=$(echo "$POST_DATA" \
                | busybox sed -n 's/.*uptime_secs=\([^&]*\).*/\1/p' \
                | busybox tr -d '\r\n')
            case "$FORM_UPSECS" in
                ''|*[!0-9]*)
                    printf "Status: 400 Bad Request\r\n"
                    printf "Content-Type: text/plain\r\n\r\n"
                    printf "Invalid uptime_secs"
                    exit 0
                    ;;
            esac
            if [ "$FORM_UPSECS" -lt 60 ]; then
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "uptime_secs must be >= 60"
                exit 0
            fi

            _kill_sched_daemon
            printf 'mode=uptime\nuptime_secs=%s\n' "$FORM_UPSECS" > "$SCHED_FILE"
            _update_startup_sched 1
            ( "$SCHED_DAEMON" ) &

            printf "Status: 200 OK\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "OK"
            exit 0
        fi

        # ── mode=time ─────────────────────────────────────────────────────────
        if [ "$FORM_MODE" = "time" ]; then
            FORM_TOD=$(echo "$POST_DATA" \
                | busybox sed -n 's/.*tod_time=\([^&]*\).*/\1/p' \
                | busybox tr -d '\r\n')
            FORM_TOD=$(busybox httpd -d "$FORM_TOD" | busybox tr -d '\r\n')
            FORM_DAYS=$(echo "$POST_DATA" \
                | busybox sed -n 's/.*days=\([^&]*\).*/\1/p' \
                | busybox tr -d '\r\n')
            FORM_DAYS=$(busybox httpd -d "$FORM_DAYS" | busybox tr -d '\r\n')

            TOD_HOUR=$(echo "$FORM_TOD" | busybox cut -d':' -f1)
            TOD_MIN=$(echo  "$FORM_TOD" | busybox cut -d':' -f2)
            case "$TOD_HOUR" in ''|*[!0-9]*) TOD_HOUR=4 ;; esac
            case "$TOD_MIN"  in ''|*[!0-9]*) TOD_MIN=0  ;; esac
            [ "$TOD_HOUR" -gt 23 ] && TOD_HOUR=23
            [ "$TOD_MIN"  -gt 59 ] && TOD_MIN=59

            SAFE_DAYS=""
            IFS=','
            for D in $FORM_DAYS; do
                case "$D" in
                    0|1|2|3|4|5|6)
                        [ -z "$SAFE_DAYS" ] && SAFE_DAYS="$D" \
                            || SAFE_DAYS="${SAFE_DAYS},${D}"
                        ;;
                esac
            done
            unset IFS

            _kill_sched_daemon
            printf 'mode=time\ntod_time=%d:%02d\ndays=%s\n' \
                "$TOD_HOUR" "$TOD_MIN" "$SAFE_DAYS" > "$SCHED_FILE"
            _update_startup_sched 1
            ( "$SCHED_DAEMON" ) &

            printf "Status: 200 OK\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "OK"
            exit 0
        fi
    fi

    # --- Main WLAN save ---
    FORM_SSID=$(echo "$POST_DATA" \
        | busybox sed -n 's/.*ssid=\([^&]*\).*/\1/p')
    FORM_SSID=$(busybox httpd -d "$FORM_SSID" \
        | busybox tr -d '\r\n')

    FORM_CHANNEL=$(echo "$POST_DATA" \
        | busybox sed -n 's/.*channel=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')
    case "$FORM_CHANNEL" in
        ''|*[!0-9]*) FORM_CHANNEL="" ;;
    esac

    FORM_BAND=$(echo "$POST_DATA" \
        | busybox sed -n 's/.*wlanband=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')
    case "$FORM_BAND" in
        ''|*[!0-9]*) FORM_BAND="" ;;
    esac

    FORM_DISABLED=$(echo "$POST_DATA" \
        | busybox sed -n 's/.*disabled=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')
    case "$FORM_DISABLED" in
        0|1) ;;
        *) FORM_DISABLED="" ;;
    esac

    FORM_CW=$(echo "$POST_DATA" \
        | busybox sed -n 's/.*channelwidth=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')
    case "$FORM_CW" in
        0|1) ;;
        *) FORM_CW="" ;;
    esac

    FORM_CB=$(echo "$POST_DATA" \
        | busybox sed -n 's/.*controlband=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')
    case "$FORM_CB" in
        0|1) ;;
        *) FORM_CB="" ;;
    esac

    FORM_TXPOWER=$(echo "$POST_DATA" \
        | busybox sed -n 's/.*txpower=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')
    case "$FORM_TXPOWER" in
        0|1|2|3|4) ;;
        *) FORM_TXPOWER="" ;;
    esac

    if [ -n "$FORM_SSID" ]; then
        rm -f "$REVERT_PENDING" "$REVERT_ROLLBACK" "$REVERT_ROLLBACK_CH" "$REVERT_ROLLBACK_BAND" "$REVERT_ROLLBACK_DIS" "$REVERT_ROLLBACK_CW" "$REVERT_ROLLBACK_CB" "$REVERT_ROLLBACK_TP" "$REVERT_START"

        # Read current disabled state BEFORE applying changes so we know
        # whether the disabled flag is actually transitioning.
        CURRENT_DIS=$(get_disabled)

        mib set WLAN1_MBSSIB_TBL.0.ssid "$FORM_SSID"
        [ -n "$FORM_BAND" ]     && mib set WLAN1_MBSSIB_TBL.0.wlanBand "$FORM_BAND"
        [ -n "$FORM_DISABLED" ] && mib set WLAN1_MBSSIB_TBL.0.wlanDisabled "$FORM_DISABLED"
        [ -n "$FORM_CHANNEL" ]  && mib set WLAN1_CHANNEL "$FORM_CHANNEL"
        [ -n "$FORM_CW" ]       && mib set WLAN1_CHANNELWIDTH "$FORM_CW"
        [ -n "$FORM_CB" ]       && mib set WLAN1_CONTROLBAND "$FORM_CB"
        [ -n "$FORM_TXPOWER" ]  && mib set WLAN1_RFPOWER_SCALE "$FORM_TXPOWER"

        mib commit

        # Skip revert only when WLAN was already off and is staying off.
        # Any transition (enabled->disabled or disabled->enabled) needs the
        # full revert flow -- especially enabled->disabled which can lock the user out.
        if [ "$FORM_DISABLED" = "1" ] && [ "$CURRENT_DIS" = "1" ]; then
            printf "Status: 200 OK\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "OK"
            exit 0
        fi

        # WLAN state is changing, or WLAN is on -- save rollback, arm revert timer, restart
        get_ssid         > "$REVERT_ROLLBACK"
        get_channel      > "$REVERT_ROLLBACK_CH"
        get_wlanband     > "$REVERT_ROLLBACK_BAND"
        get_disabled     > "$REVERT_ROLLBACK_DIS"
        get_channelwidth > "$REVERT_ROLLBACK_CW"
        get_controlband  > "$REVERT_ROLLBACK_CB"
        get_txpower      > "$REVERT_ROLLBACK_TP"

        touch "$REVERT_PENDING"
        date +%s > "$REVERT_START"

        (
            sleep $REVERT_TIMEOUT
            if [ -f "$REVERT_PENDING" ]; then
                ORIG_DIS=$(cat "$REVERT_ROLLBACK_DIS")
                mib set WLAN1_MBSSIB_TBL.0.ssid "$(cat $REVERT_ROLLBACK)"
                mib set WLAN1_MBSSIB_TBL.0.wlanBand "$(cat $REVERT_ROLLBACK_BAND)"
                mib set WLAN1_MBSSIB_TBL.0.wlanDisabled "$ORIG_DIS"
                mib set WLAN1_CHANNEL "$(cat $REVERT_ROLLBACK_CH)"
                mib set WLAN1_CHANNELWIDTH "$(cat $REVERT_ROLLBACK_CW)"
                mib set WLAN1_CONTROLBAND "$(cat $REVERT_ROLLBACK_CB)"
                mib set WLAN1_RFPOWER_SCALE "$(cat $REVERT_ROLLBACK_TP)"
                mib commit
                wlan_apply restart
                rm -f "$REVERT_PENDING" "$REVERT_ROLLBACK" "$REVERT_ROLLBACK_CH" "$REVERT_ROLLBACK_BAND" "$REVERT_ROLLBACK_DIS" "$REVERT_ROLLBACK_CW" "$REVERT_ROLLBACK_CB" "$REVERT_ROLLBACK_TP" "$REVERT_START"
            fi
        ) &

        wlan_apply restart

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi
fi

# Fallback
printf "Status: 302 Found\r\n"
printf "Location: /wlan24.html\r\n\r\n"

