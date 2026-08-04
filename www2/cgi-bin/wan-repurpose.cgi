#!/bin/sh
# wan-repurpose.cgi — Repurpose LAN / WiFi interface as DHCP WAN
#
# GET  ?action=iface_list  → enumerate eligible interfaces (JSON)
# GET  ?action=status      → quick watchdog/IP poll (JSON)
# POST ?action=apply       → start repurpose watchdog daemon
# POST ?action=revert      → revert interface back to br0
#
# WLAN eligibility (wlanbasic.cgi conventions):
#   5GHz  wlan0 → WLAN_MBSSIB_TBL.0.{wlanDisabled,wlanMode}
#   2.4GHz wlan1 → WLAN1_MBSSIB_TBL.0.{wlanDisabled,wlanMode}
#   wlanDisabled=0 (enabled) AND wlanMode=1 (client) required.
#
# LAN eligibility:
#   eth0.2.0 (LAN1 / port 0) — only if PORT1_PWR=enabled from lan.sh
#   eth0.3.0 (LAN2 / port 1) — only if PORT2_PWR=enabled from lan.sh
#   eth0.4.0 (LAN3 / port 2) — only if PORT3_PWR=enabled from lan.sh
#   eth0.5.0 (LAN4 / port 3) — only if PORT4_PWR=enabled from lan.sh

SESSION_TIMEOUT=600

# ── Auth ──────────────────────────────────────────────────────────────────────
BROWSER_SESSION=$(echo "$HTTP_COOKIE" \
    | busybox sed -n 's/.*session=\([^;]*\).*/\1/p' \
    | busybox tr -d '\r\n')
BROWSER_SESSION=$(printf '%s' "$BROWSER_SESSION" \
    | busybox tr -cd 'a-fA-F0-9')
SESSION_FILE="/tmp/sessions/$BROWSER_SESSION"

if [ -z "$BROWSER_SESSION" ] || [ ! -f "$SESSION_FILE" ]; then
    printf "Status: 302 Found\r\nLocation: /login.html\r\n\r\n"
    exit 0
fi

LAST=$(cat "$SESSION_FILE" 2>/dev/null | busybox tr -d '\r\n')
NOW=$(date +%s)
[ -z "$LAST" ] && LAST=$NOW
if [ $((NOW - LAST)) -gt $SESSION_TIMEOUT ]; then
    rm -f "$SESSION_FILE"
    printf "Status: 302 Found\r\nLocation: /login.html\r\n\r\n"
    exit 0
fi

# Atomic session refresh
_STMP=$(mktemp /tmp/sessions/.tmp.XXXXXX)
echo "$NOW" > "$_STMP"
busybox mv "$_STMP" "$SESSION_FILE"

# ── Constants ─────────────────────────────────────────────────────────────────
REPURPOSE_SH="/lmepisowifi/www2/sh/repurposeaswan.sh"
REVERT_SH="/lmepisowifi/www2/sh/revertwan.sh"
LAN_SH="/lmepisowifi/www2/sh/lan.sh"
STATE_FILE="/tmp/repurpose_active"
STARTUP_SH="/lmepisowifi/www2/sh/startup.sh"

# ── update_startup_repurpose <iface|""> ───────────────────────────────────────
# Rewrites the BEGIN_WAN_REPURPOSE … END_WAN_REPURPOSE section of startup.sh.
# Pass the interface name to persist it, or "" to clear the section (revert).
# Uses the same atomic awk+mv pattern as update_startup_speed in lme.cgi.
update_startup_repurpose() {
    _USR_IFACE="$1"
    [ ! -f "$STARTUP_SH" ] && return

    _USR_TMP="/tmp/startup_sh_repurpose_$$.tmp"

    busybox awk \
        -v iface="$_USR_IFACE" \
        -v repurpose_sh="$REPURPOSE_SH" \
        'BEGIN { in_sec=0 }
         /^# --- BEGIN_WAN_REPURPOSE ---/ { print; in_sec=1; next }
         /^# --- END_WAN_REPURPOSE ---/ {
             if (iface != "") {
                 # No wait_for_iface gate here: repurposeaswan.sh already waits
                 # for the interface to appear in sysfs and for monitord (vendor
                 # hardware bring-up signal) internally, with a longer timeout
                 # and its own logging. Gating on wait_for_iface (60s, ifconfig-
                 # based) too was a second, stricter, unlogged point of failure —
                 # if it timed out first on a slow boot, the && short-circuited
                 # and repurposeaswan.sh never launched at all for that boot,
                 # silently leaving the admin UI showing "select interface".
                 print "( sh " repurpose_sh " " iface " ) &"
             }
             in_sec=0; print; next
         }
         in_sec { next }
         { print }' \
        "$STARTUP_SH" > "$_USR_TMP" \
    && busybox mv "$_USR_TMP" "$STARTUP_SH" \
    && busybox chmod 755 "$STARTUP_SH"
}

# ── Helpers ───────────────────────────────────────────────────────────────────
json_esc() { printf '%s' "$1" | busybox sed 's/\\/\\\\/g; s/"/\\"/g'; }

mib_field() {
    mib get "$1" 2>/dev/null \
        | busybox grep "=" \
        | busybox cut -d'=' -f2- \
        | busybox tr -d '\r\n'
}

get_active() {
    [ -f "$STATE_FILE" ] \
        && busybox tr -d '\r\n' < "$STATE_FILE" 2>/dev/null \
        || printf ''
}

watchdog_alive() {
    _PF="/tmp/repurpose_${1}.pid"
    [ -f "$_PF" ] || return 1
    _P=$(busybox tr -d '\r\n' < "$_PF" 2>/dev/null)
    [ -n "$_P" ] && kill -0 "$_P" 2>/dev/null
}

udhcpc_alive() {
    _PF="/var/run/udhcpc.${1}.pid"
    if [ -f "$_PF" ]; then
        _P=$(busybox tr -d '\r\n' < "$_PF" 2>/dev/null)
        [ -n "$_P" ] && kill -0 "$_P" 2>/dev/null && return 0
    fi
    busybox ps 2>/dev/null | busybox grep "udhcpc" \
        | busybox grep -q "$1"
}

get_iface_ip() {
    ip addr show dev "$1" 2>/dev/null \
        | busybox awk '/inet / {print $2; exit}' \
        | busybox cut -d'/' -f1 \
        | busybox tr -d '\r\n'
}

get_iface_gw() {
    ip route 2>/dev/null \
        | busybox awk -v IF="$1" \
            '/^default/ && $5==IF {print $3; exit}' \
        | busybox tr -d '\r\n'
}

iface_in_br0() {
    _M=$(ip link show "$1" 2>/dev/null \
        | busybox sed -n 's/.* master \([^ ]*\) .*/\1/p' \
        | busybox tr -d '\r\n')
    [ "$_M" = "br0" ]
}

# True if the interface is enslaved to br1
iface_has_master() {
    ip link show "$1" 2>/dev/null \
        | busybox grep -q " master br1"
}

iface_is_up() {
    ip link show "$1" 2>/dev/null \
        | busybox grep -q ",UP,"
}

# ── WLAN MIB prefix for each radio (wlanbasic.cgi convention) ─────────────────
# wlan0 / wlan0-vxd (5GHz)   → WLAN_MBSSIB_TBL   (no "0" in prefix)
# wlan1 / wlan1-vxd (2.4GHz) → WLAN1_MBSSIB_TBL
# VXD sub-interfaces share the parent radio's MIB table; their entry is at idx 5.
wlan_tbl_pfx() {
    case "$1" in
        wlan0|wlan0-vxd) printf 'WLAN_MBSSIB_TBL'  ;;
        wlan1|wlan1-vxd) printf 'WLAN1_MBSSIB_TBL' ;;
        *)                 printf ''                  ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════════════
# GET
# ════════════════════════════════════════════════════════════════════════════════
if [ "$REQUEST_METHOD" = "GET" ]; then

    ACTION=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*action=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')

    # ── action=status: quick poll for active WAN state ────────────────────────
    if [ "$ACTION" = "status" ]; then
        ACTIVE=$(get_active)

        WD=false; DC=false; IN_BR0=false; UP=false
        IFACE_IP=""; IFACE_GW=""

        if [ -n "$ACTIVE" ]; then
            watchdog_alive "$ACTIVE" && WD=true
            udhcpc_alive   "$ACTIVE" && DC=true
            iface_in_br0   "$ACTIVE" && IN_BR0=true
            iface_is_up    "$ACTIVE" && UP=true
            IFACE_IP=$(get_iface_ip "$ACTIVE")
            IFACE_GW=$(get_iface_gw "$ACTIVE")
        fi

        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"active_iface":"%s","ip":"%s","gateway":"%s","watchdog_running":%s,"udhcpc_running":%s,"in_br0":%s,"iface_up":%s}' \
            "$(json_esc "$ACTIVE")" "$(json_esc "$IFACE_IP")" \
            "$(json_esc "$IFACE_GW")" "$WD" "$DC" "$IN_BR0" "$UP"
        exit 0
    fi

    # ── action=iface_list: discover eligible LAN + WLAN interfaces ────────────
    if [ "$ACTION" = "iface_list" ]; then
        ACTIVE=$(get_active)

        # Get LAN port power state once (costly, so run only once)
        LAN_RAW=$(sh "$LAN_SH" status 2>&1)
        LAN_OK=0
        echo "$LAN_RAW" | busybox grep -q 'STATUS="SUCCESS"' && LAN_OK=1

        # Fetch diag port link status for all 4 LAN ports (for display)
        P0_RAW=$(diag port get status port 0 2>/dev/null)
        P1_RAW=$(diag port get status port 1 2>/dev/null)
        P2_RAW=$(diag port get status port 2 2>/dev/null)
        P3_RAW=$(diag port get status port 3 2>/dev/null)

        JSON="["
        FIRST=1

        # ── LAN interfaces ────────────────────────────────────────────────────
        for LAN_IFACE in eth0.2.0 eth0.3.0 eth0.4.0 eth0.5.0; do
            case "$LAN_IFACE" in
                eth0.2.0) PORT=1; DIAG_IDX=0; DIAG_RAW="$P0_RAW" ;;
                eth0.3.0) PORT=2; DIAG_IDX=1; DIAG_RAW="$P1_RAW" ;;
                eth0.4.0) PORT=3; DIAG_IDX=2; DIAG_RAW="$P2_RAW" ;;
                eth0.5.0) PORT=4; DIAG_IDX=3; DIAG_RAW="$P3_RAW" ;;
            esac

            # Check port power via lan.sh (skip if disabled)
            if [ "$LAN_OK" = "1" ]; then
                PORT_PWR=$(echo "$LAN_RAW" \
                    | busybox sed -n "s/.*PORT${PORT}_PWR=\"\([^\"]*\)\".*/\1/p")
                [ "$PORT_PWR" = "enabled" ] || continue
            else
                # lan.sh unavailable; fall back to kernel interface existence
                ip link show "$LAN_IFACE" >/dev/null 2>&1 || continue
            fi

            # Double-check interface actually exists in the kernel
            ip link show "$LAN_IFACE" >/dev/null 2>&1 || continue

            # Skip if currently enslaved to any bridge.
            # A port in br0/br1 is actively serving hotspot clients; pulling it
            # out as WAN mid-traffic causes routing conflicts.
            # Exception: the currently-active repurposed interface was already
            # removed from its bridge by repurposeaswan.sh (nomaster), so
            # iface_has_master returns false for it and it passes through.
            if [ "$LAN_IFACE" != "$ACTIVE" ]; then
                iface_has_master "$LAN_IFACE" && continue
            fi

            # Link status + speed from diag (may be empty on first boot)
            LNK=$(echo "$DIAG_RAW" \
                | busybox awk -v di="$DIAG_IDX" '$1==di {print $2; exit}' \
                | busybox tr -d '\r\n')
            SPD=$(echo "$DIAG_RAW" \
                | busybox awk -v di="$DIAG_IDX" '$1==di {print $3; exit}' \
                | busybox tr -d '\r\n')
            [ -z "$LNK" ] && LNK="Unknown"
            [ -z "$SPD" ] && SPD="-"

            # IP + GW only if this iface is the active WAN
            IFACE_IP=""; IFACE_GW=""
            if [ "$ACTIVE" = "$LAN_IFACE" ]; then
                IFACE_IP=$(get_iface_ip "$LAN_IFACE")
                IFACE_GW=$(get_iface_gw "$LAN_IFACE")
            fi

            [ "$FIRST" = "1" ] && FIRST=0 || JSON="${JSON},"
            JSON="${JSON}{\"iface\":\"$(json_esc "$LAN_IFACE")\""
            JSON="${JSON},\"type\":\"lan\""
            JSON="${JSON},\"label\":\"LAN ${PORT} (${LAN_IFACE})\""
            JSON="${JSON},\"port\":${PORT}"
            JSON="${JSON},\"link_status\":\"$(json_esc "$LNK")\""
            JSON="${JSON},\"link_speed\":\"$(json_esc "$SPD")\""
            JSON="${JSON},\"ip\":\"$(json_esc "$IFACE_IP")\""
            JSON="${JSON},\"gateway\":\"$(json_esc "$IFACE_GW")\"}"
        done

        # ── WLAN interfaces ───────────────────────────────────────────────────
        for WLAN_IF in wlan0 wlan1; do
            case "$WLAN_IF" in
                wlan0) BAND_LABEL="5GHz" ;;
                wlan1) BAND_LABEL="2.4GHz" ;;
            esac

            # Interface must exist in the kernel
            ip link show "$WLAN_IF" >/dev/null 2>&1 || continue

            # Get MIB table prefix for this radio (wlanbasic.cgi convention)
            TBL=$(wlan_tbl_pfx "$WLAN_IF")
            [ -z "$TBL" ] && continue

            # ── Enabled check (same MIB key wlanbasic.cgi reads) ─────────────
            DIS=$(mib_field "${TBL}.0.wlanDisabled")
            # wlanDisabled=1 means OFF; anything else (0 or empty) means ON.
            [ "${DIS:-0}" = "1" ] && continue

            # ── Client mode check (wlanMode=1 means infrastructure client) ────
            WMODE=$(mib_field "${TBL}.0.wlanMode")
            [ "${WMODE:-0}" = "1" ] || continue

            # Configured target SSID (filled in when client mode is set up)
            SSID=$(mib_field "${TBL}.0.ssid")

            # IP + GW only if active
            IFACE_IP=""; IFACE_GW=""
            if [ "$ACTIVE" = "$WLAN_IF" ]; then
                IFACE_IP=$(get_iface_ip "$WLAN_IF")
                IFACE_GW=$(get_iface_gw "$WLAN_IF")
            fi

            [ "$FIRST" = "1" ] && FIRST=0 || JSON="${JSON},"
            JSON="${JSON}{\"iface\":\"$(json_esc "$WLAN_IF")\""
            JSON="${JSON},\"type\":\"wlan\""
            JSON="${JSON},\"label\":\"WiFi ${BAND_LABEL} (${WLAN_IF})\""
            JSON="${JSON},\"band\":\"$(json_esc "$BAND_LABEL")\""
            JSON="${JSON},\"assoc_ssid\":\"$(json_esc "$SSID")\""
            JSON="${JSON},\"ip\":\"$(json_esc "$IFACE_IP")\""
            JSON="${JSON},\"gateway\":\"$(json_esc "$IFACE_GW")\"}"
        done

        # ── WLAN VXD sub-interfaces ───────────────────────────────────────────
        # VXD (Virtual eXtended Device) lives at MIB index 5 in the same table.
        # It is the dedicated client/repeater interface — no separate wlanMode
        # check needed; if it exists and is enabled it is inherently client-mode.
        for VXD_IF in wlan0-vxd wlan1-vxd; do
            case "$VXD_IF" in
                wlan0-vxd) BAND_LABEL="5GHz" ;;
                wlan1-vxd) BAND_LABEL="2.4GHz" ;;
            esac

            # Interface must be present in the kernel
            ip link show "$VXD_IF" >/dev/null 2>&1 || continue

            TBL=$(wlan_tbl_pfx "$VXD_IF")
            [ -z "$TBL" ] && continue

            # VXD is MIB index 5 (wlanbasic.cgi: TY="vxd" when I=5)
            VXD_DIS=$(mib_field "${TBL}.5.wlanDisabled")
            [ "${VXD_DIS:-0}" = "1" ] && continue

            # SSID stored in slot 5
            SSID=$(mib_field "${TBL}.5.ssid")

            IFACE_IP=""; IFACE_GW=""
            if [ "$ACTIVE" = "$VXD_IF" ]; then
                IFACE_IP=$(get_iface_ip "$VXD_IF")
                IFACE_GW=$(get_iface_gw "$VXD_IF")
            fi

            [ "$FIRST" = "1" ] && FIRST=0 || JSON="${JSON},"
            JSON="${JSON}{\"iface\":\"$(json_esc "$VXD_IF")\""
            JSON="${JSON},\"type\":\"wlan\""
            JSON="${JSON},\"label\":\"WiFi ${BAND_LABEL} VXD (${VXD_IF})\""
            JSON="${JSON},\"band\":\"$(json_esc "$BAND_LABEL")\""
            JSON="${JSON},\"assoc_ssid\":\"$(json_esc "$SSID")\""
            JSON="${JSON},\"ip\":\"$(json_esc "$IFACE_IP")\""
            JSON="${JSON},\"gateway\":\"$(json_esc "$IFACE_GW")\"}"
        done

        JSON="${JSON}]"

        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"interfaces":%s,"active_iface":"%s"}' \
            "$JSON" "$(json_esc "$ACTIVE")"
        exit 0
    fi

    # Unknown GET action
    printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
    printf "Unknown action"
    exit 0
fi

# ════════════════════════════════════════════════════════════════════════════════
# POST
# ════════════════════════════════════════════════════════════════════════════════
if [ "$REQUEST_METHOD" = "POST" ]; then

    __CL="${CONTENT_LENGTH:-0}"
    case "$__CL" in *[!0-9]*|"") __CL=0 ;; esac
    [ "$__CL" -gt 65536 ] && __CL=65536
    POST_DATA=$(busybox dd bs=1 count="$__CL" 2>/dev/null)

    ACTION=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*action=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')

    # ── action=apply: start repurpose watchdog for chosen interface ───────────
    if [ "$ACTION" = "apply" ]; then
        FORM_IFACE=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*iface=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        FORM_IFACE=$(busybox httpd -d "$FORM_IFACE" \
            | busybox tr -d '\r\n')

        # Whitelist: only the eight supported interfaces
        case "$FORM_IFACE" in
            eth0.2.0|eth0.3.0|eth0.4.0|eth0.5.0|wlan0|wlan1|wlan0-vxd|wlan1-vxd) ;;
            *)
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid interface"
                exit 0
                ;;
        esac

        # Interface must exist
        if ! ip link show "$FORM_IFACE" >/dev/null 2>&1; then
            printf "Status: 404 Not Found\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Interface not found: %s" "$FORM_IFACE"
            exit 0
        fi

        # If a different interface is currently active, revert it first
        CURRENTLY=$(get_active)
        if [ -n "$CURRENTLY" ] && [ "$CURRENTLY" != "$FORM_IFACE" ]; then
            sh "$REVERT_SH" "$CURRENTLY" >/dev/null 2>&1
            busybox sleep 1
        fi

        # Persist to startup.sh so the repurpose survives a reboot
        update_startup_repurpose "$FORM_IFACE"

        # Respond immediately (so the browser doesn't time out while udhcpc negotiates)
        printf "Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n"
        printf "OK"

        # Launch watchdog daemon in background, fully detached from the CGI's
        # stdout/stderr.  BusyBox httpd waits for EOF on the pipe before it
        # flushes the HTTP response to the browser; keeping the pipe open in the
        # daemon process (which runs an infinite watchdog loop) would stall the
        # fetch() call indefinitely.  Redirecting to /dev/null closes the
        # inherited fd so httpd gets EOF the moment the CGI script exits.
        sh "$REPURPOSE_SH" "$FORM_IFACE" >/dev/null 2>&1 &

        exit 0
    fi

    # ── action=revert: restore interface to br0 ───────────────────────────────
    if [ "$ACTION" = "revert" ]; then
        FORM_IFACE=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*iface=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        FORM_IFACE=$(busybox httpd -d "$FORM_IFACE" \
            | busybox tr -d '\r\n')

        # If iface not specified or not in whitelist, fall back to active
        case "$FORM_IFACE" in
            eth0.2.0|eth0.3.0|eth0.4.0|eth0.5.0|wlan0|wlan1|wlan0-vxd|wlan1-vxd) ;;
            *) FORM_IFACE=$(get_active) ;;
        esac

        if [ -z "$FORM_IFACE" ]; then
            printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
            printf "No active interface to revert"
            exit 0
        fi

        sh "$REVERT_SH" "$FORM_IFACE" >/dev/null 2>&1

        # Clear the startup.sh entry so it doesn't run again on reboot
        update_startup_repurpose ""

        printf "Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi
fi

# Fallback
printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
printf "Bad request"
