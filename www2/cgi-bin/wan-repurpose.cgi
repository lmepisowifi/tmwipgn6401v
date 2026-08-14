#!/bin/sh
# wan-repurpose.cgi — DHCP Client interfaces (repurpose LAN / WiFi as WAN)
#
# GET  ?action=iface_list  → enumerate eligible + configured interfaces (JSON)
# GET  ?action=status      → quick watchdog/IP poll for every configured
#                             interface (JSON array)
# POST ?action=apply       → add/re-apply an interface as a DHCP client,
#                             body: iface=<iface>&default_route=1|0
# POST ?action=revert      → remove a configured interface, body: iface=<iface>
# POST ?action=set_default → flip the default-route switch on an already
#                             -configured interface, body:
#                             iface=<iface>&default_route=1|0
#
# Multiple interfaces can be configured as DHCP clients at once — each runs
# its own repurposeaswan.sh watchdog (namespaced entirely by interface name).
# At most one of them is ever flagged default_route=1 at a time (enforced
# here, since only one interface can meaningfully hold the kernel default
# route) — see /tmp/repurpose_defroute_<iface>.
#
# The set of configured interfaces + their default-route flags is
# persisted in the BEGIN_WAN_REPURPOSE…END_WAN_REPURPOSE block of
# startup.sh, one line per interface:
#   ( sh /lmepisowifi/www2/sh/repurposeaswan.sh <iface> <default_route> ) &
# Older, pre-multi-interface entries in that block
# (`( sh .../repurposeaswan.sh <iface> ) &`, no third field) are left
# untouched until the user next touches that interface from this page —
# repurposeaswan.sh treats an omitted default_route argument as "1", which
# matches exactly what those older single-interface entries always did.
#
# WLAN eligibility (wlanbasic.cgi conventions):
#   5GHz  wlan0 → WLAN_MBSSIB_TBL.0.{wlanDisabled,wlanMode}
#   2.4GHz wlan1 → WLAN1_MBSSIB_TBL.0.{wlanDisabled,wlanMode}
#   wlanDisabled=0 (enabled) AND wlanMode=1 (client) required.
#
# LAN eligibility:
#   eth0.2.0 (LAN1 / port 0) — only if PORT1_PWR=enabled from lan.sh
#   eth0.3.0 (LAN2 / port 1) — only if PORT2_PWR=enabled from lan.sh

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

# ── update_startup_repurpose_all ──────────────────────────────────────────────
# Rewrites the whole BEGIN_WAN_REPURPOSE … END_WAN_REPURPOSE section of
# startup.sh from the CURRENT live registry (STATE_FILE + each interface's
# own /tmp/repurpose_defroute_<iface> flag) — one launch line per configured
# interface, so every currently-configured DHCP-client interface (not just
# the one just touched) survives a reboot. Uses the same
# getline-from-contentfile awk idiom ota.sh's self-heal already uses for
# splicing a marker section, for consistency.
update_startup_repurpose_all() {
    [ ! -f "$STARTUP_SH" ] && return

    _USR_CONTENT="/tmp/startup_sh_repurpose_content_$$.tmp"
    : > "$_USR_CONTENT"
    if [ -f "$STATE_FILE" ]; then
        while IFS= read -r _usr_if; do
            [ -z "$_usr_if" ] && continue
            _usr_flag=$(busybox cat "/tmp/repurpose_defroute_${_usr_if}" 2>/dev/null | busybox tr -d '\r\n')
            _usr_flag="${_usr_flag:-1}"
            printf '( sh %s %s %s ) &\n' "$REPURPOSE_SH" "$_usr_if" "$_usr_flag" >> "$_USR_CONTENT"
        done < "$STATE_FILE"
    fi

    _USR_TMP="/tmp/startup_sh_repurpose_$$.tmp"
    busybox awk \
        -v contentfile="$_USR_CONTENT" \
        'BEGIN { in_sec=0 }
         /^# --- BEGIN_WAN_REPURPOSE ---/ {
             print; in_sec=1
             while ((getline line < contentfile) > 0) print line
             close(contentfile)
             next
         }
         /^# --- END_WAN_REPURPOSE ---/ { in_sec=0; print; next }
         in_sec { next }
         { print }' \
        "$STARTUP_SH" > "$_USR_TMP" \
    && busybox mv "$_USR_TMP" "$STARTUP_SH" \
    && busybox chmod 755 "$STARTUP_SH"
    rm -f "$_USR_CONTENT"
}

# ── Helpers ───────────────────────────────────────────────────────────────────
json_esc() { printf '%s' "$1" | busybox sed 's/\\/\\\\/g; s/"/\\"/g'; }

mib_field() {
    mib get "$1" 2>/dev/null \
        | busybox grep "=" \
        | busybox cut -d'=' -f2- \
        | busybox tr -d '\r\n'
}

# True if $1 is currently a configured (applied) DHCP-client interface —
# i.e. it has its own line in the shared state registry.
iface_configured() {
    [ -f "$STATE_FILE" ] && busybox grep -qx "$1" "$STATE_FILE" 2>/dev/null
}

# Space this interface's configured-interface list, one per line.
configured_ifaces() {
    [ -f "$STATE_FILE" ] && busybox grep -v '^[[:space:]]*$' "$STATE_FILE" 2>/dev/null
}

# This interface's default-route flag ("1" or "0"). Missing flag file = "1"
# (matches pre-multi-interface behaviour for older single-entry configs).
get_defroute() {
    _gd=$(busybox cat "/tmp/repurpose_defroute_${1}" 2>/dev/null | busybox tr -d '\r\n')
    printf '%s' "${_gd:-1}"
}

# Clear the default-route flag (and live route/masquerade) from every
# CONFIGURED interface except $1. Only one interface should ever carry the
# real kernel default route.
_clear_other_defaults() {
    _KEEP="$1"
    [ -f "$STATE_FILE" ] || return
    while IFS= read -r _oi; do
        [ -z "$_oi" ] && continue
        [ "$_oi" = "$_KEEP" ] && continue
        [ "$(get_defroute "$_oi")" = "1" ] || continue
        printf '0' > "/tmp/repurpose_defroute_${_oi}"
        _ocd=$(ip route show default 2>/dev/null | head -1)
        case "$_ocd" in *"dev $_oi"*) ip route del default dev "$_oi" 2>/dev/null ;; esac
        iptables -t nat -D POSTROUTING -o "$_oi" -j MASQUERADE 2>/dev/null
        rm -f "/tmp/repurpose_gw_${_oi}"
    done < "$STATE_FILE"
}

# Immediately point the kernel default route + NAT masquerade at $1, using
# whatever gateway is already known for it (live route table, else its
# saved gw file). No-op (besides setting the flag) if no gateway is known
# yet — the udhcpc handler will finish the job itself once DHCP completes,
# since it re-reads this same flag file on every bound/renew.
_apply_default_now() {
    _TGT="$1"
    printf '1' > "/tmp/repurpose_defroute_${_TGT}"
    _TGW=$(get_iface_gw "$_TGT")
    [ -z "$_TGW" ] && _TGW=$(busybox cat "/tmp/repurpose_gw_${_TGT}" 2>/dev/null | busybox tr -d '\r\n')
    if [ -n "$_TGW" ]; then
        while ip route del default 2>/dev/null; do :; done
        ip route add default via "$_TGW" dev "$_TGT" 2>/dev/null
        printf '%s' "$_TGW" > "/tmp/repurpose_gw_${_TGT}"
        iptables -t nat -D POSTROUTING -o "$_TGT" -j MASQUERADE 2>/dev/null
        iptables -t nat -A POSTROUTING -o "$_TGT" -j MASQUERADE 2>/dev/null
    fi
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

    # ── action=status: quick poll for every configured interface ──────────────
    if [ "$ACTION" = "status" ]; then
        JSON="["
        FIRST=1
        for ACTIVE in $(configured_ifaces); do
            WD=false; DC=false; IN_BR0=false; UP=false
            IFACE_IP=""; IFACE_GW=""

            watchdog_alive "$ACTIVE" && WD=true
            udhcpc_alive   "$ACTIVE" && DC=true
            iface_in_br0   "$ACTIVE" && IN_BR0=true
            iface_is_up    "$ACTIVE" && UP=true
            IFACE_IP=$(get_iface_ip "$ACTIVE")
            IFACE_GW=$(get_iface_gw "$ACTIVE")
            DEFROUTE=$(get_defroute "$ACTIVE")
            [ "$DEFROUTE" = "1" ] && DEFROUTE=true || DEFROUTE=false

            [ "$FIRST" = "1" ] && FIRST=0 || JSON="${JSON},"
            JSON="${JSON}{\"iface\":\"$(json_esc "$ACTIVE")\""
            JSON="${JSON},\"ip\":\"$(json_esc "$IFACE_IP")\""
            JSON="${JSON},\"gateway\":\"$(json_esc "$IFACE_GW")\""
            JSON="${JSON},\"default_route\":${DEFROUTE}"
            JSON="${JSON},\"watchdog_running\":${WD}"
            JSON="${JSON},\"udhcpc_running\":${DC}"
            JSON="${JSON},\"in_br0\":${IN_BR0}"
            JSON="${JSON},\"iface_up\":${UP}}"
        done
        JSON="${JSON}]"

        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"interfaces":%s}' "$JSON"
        exit 0
    fi

    # ── action=iface_list: discover eligible LAN + WLAN interfaces ────────────
    if [ "$ACTION" = "iface_list" ]; then

        # Get LAN port power state once (costly, so run only once)
        LAN_RAW=$(sh "$LAN_SH" status 2>&1)
        LAN_OK=0
        echo "$LAN_RAW" | busybox grep -q 'STATUS="SUCCESS"' && LAN_OK=1

        # Fetch diag port link status for both LAN ports (for display)
        P0_RAW=$(diag port get status port 0 2>/dev/null)
        P1_RAW=$(diag port get status port 1 2>/dev/null)

        JSON="["
        FIRST=1

        # ── LAN interfaces ────────────────────────────────────────────────────
        for LAN_IFACE in eth0.2.0 eth0.3.0; do
            case "$LAN_IFACE" in
                eth0.2.0) PORT=1; DIAG_IDX=0; DIAG_RAW="$P0_RAW" ;;
                eth0.3.0) PORT=2; DIAG_IDX=1; DIAG_RAW="$P1_RAW" ;;
            esac

            CONFIGURED=0
            iface_configured "$LAN_IFACE" && CONFIGURED=1

            # Check port power via lan.sh (skip if disabled) — unless already
            # configured, in which case always show it (a configured
            # interface may have had its port power toggled off since).
            if [ "$CONFIGURED" != "1" ]; then
                if [ "$LAN_OK" = "1" ]; then
                    PORT_PWR=$(echo "$LAN_RAW" \
                        | busybox sed -n "s/.*PORT${PORT}_PWR=\"\([^\"]*\)\".*/\1/p")
                    [ "$PORT_PWR" = "enabled" ] || continue
                else
                    # lan.sh unavailable; fall back to kernel interface existence
                    ip link show "$LAN_IFACE" >/dev/null 2>&1 || continue
                fi
            fi

            # Double-check interface actually exists in the kernel
            ip link show "$LAN_IFACE" >/dev/null 2>&1 || continue

            # Skip if currently enslaved to any bridge.
            # A port in br0/br1 is actively serving hotspot clients; pulling it
            # out as WAN mid-traffic causes routing conflicts.
            # Exception: an already-configured interface was already removed
            # from its bridge by repurposeaswan.sh (nomaster), so
            # iface_has_master returns false for it and it passes through.
            if [ "$CONFIGURED" != "1" ]; then
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

            # IP + GW + default-route flag only if this iface is configured
            IFACE_IP=""; IFACE_GW=""; DEFROUTE="false"
            WD="false"; DC="false"; IN_BR0="false"; UP="false"
            if [ "$CONFIGURED" = "1" ]; then
                IFACE_IP=$(get_iface_ip "$LAN_IFACE")
                IFACE_GW=$(get_iface_gw "$LAN_IFACE")
                [ "$(get_defroute "$LAN_IFACE")" = "1" ] && DEFROUTE="true"
                watchdog_alive "$LAN_IFACE" && WD="true"
                udhcpc_alive   "$LAN_IFACE" && DC="true"
                iface_in_br0   "$LAN_IFACE" && IN_BR0="true"
                iface_is_up    "$LAN_IFACE" && UP="true"
            fi

            [ "$FIRST" = "1" ] && FIRST=0 || JSON="${JSON},"
            JSON="${JSON}{\"iface\":\"$(json_esc "$LAN_IFACE")\""
            JSON="${JSON},\"type\":\"lan\""
            JSON="${JSON},\"label\":\"LAN ${PORT} (${LAN_IFACE})\""
            JSON="${JSON},\"port\":${PORT}"
            JSON="${JSON},\"link_status\":\"$(json_esc "$LNK")\""
            JSON="${JSON},\"link_speed\":\"$(json_esc "$SPD")\""
            JSON="${JSON},\"configured\":$([ "$CONFIGURED" = "1" ] && echo true || echo false)"
            JSON="${JSON},\"default_route\":${DEFROUTE}"
            JSON="${JSON},\"watchdog_running\":${WD}"
            JSON="${JSON},\"udhcpc_running\":${DC}"
            JSON="${JSON},\"in_br0\":${IN_BR0}"
            JSON="${JSON},\"iface_up\":${UP}"
            JSON="${JSON},\"ip\":\"$(json_esc "$IFACE_IP")\""
            JSON="${JSON},\"gateway\":\"$(json_esc "$IFACE_GW")\"}"
        done

        # ── WLAN interfaces ───────────────────────────────────────────────────
        for WLAN_IF in wlan0 wlan1; do
            case "$WLAN_IF" in
                wlan0) BAND_LABEL="5GHz" ;;
                wlan1) BAND_LABEL="2.4GHz" ;;
            esac

            CONFIGURED=0
            iface_configured "$WLAN_IF" && CONFIGURED=1

            # Interface must exist in the kernel
            ip link show "$WLAN_IF" >/dev/null 2>&1 || continue

            # Get MIB table prefix for this radio (wlanbasic.cgi convention)
            TBL=$(wlan_tbl_pfx "$WLAN_IF")
            [ -z "$TBL" ] && continue

            # ── Enabled check (same MIB key wlanbasic.cgi reads) ─────────────
            DIS=$(mib_field "${TBL}.0.wlanDisabled")
            # wlanDisabled=1 means OFF; anything else (0 or empty) means ON.
            if [ "$CONFIGURED" != "1" ]; then
                [ "${DIS:-0}" = "1" ] && continue
            fi

            # ── Client mode check (wlanMode=1 means infrastructure client) ────
            WMODE=$(mib_field "${TBL}.0.wlanMode")
            if [ "$CONFIGURED" != "1" ]; then
                [ "${WMODE:-0}" = "1" ] || continue
            fi

            # Configured target SSID (filled in when client mode is set up)
            SSID=$(mib_field "${TBL}.0.ssid")

            IFACE_IP=""; IFACE_GW=""; DEFROUTE="false"
            WD="false"; DC="false"; IN_BR0="false"; UP="false"
            if [ "$CONFIGURED" = "1" ]; then
                IFACE_IP=$(get_iface_ip "$WLAN_IF")
                IFACE_GW=$(get_iface_gw "$WLAN_IF")
                [ "$(get_defroute "$WLAN_IF")" = "1" ] && DEFROUTE="true"
                watchdog_alive "$WLAN_IF" && WD="true"
                udhcpc_alive   "$WLAN_IF" && DC="true"
                iface_in_br0   "$WLAN_IF" && IN_BR0="true"
                iface_is_up    "$WLAN_IF" && UP="true"
            fi

            [ "$FIRST" = "1" ] && FIRST=0 || JSON="${JSON},"
            JSON="${JSON}{\"iface\":\"$(json_esc "$WLAN_IF")\""
            JSON="${JSON},\"type\":\"wlan\""
            JSON="${JSON},\"label\":\"WiFi ${BAND_LABEL} (${WLAN_IF})\""
            JSON="${JSON},\"band\":\"$(json_esc "$BAND_LABEL")\""
            JSON="${JSON},\"assoc_ssid\":\"$(json_esc "$SSID")\""
            JSON="${JSON},\"configured\":$([ "$CONFIGURED" = "1" ] && echo true || echo false)"
            JSON="${JSON},\"default_route\":${DEFROUTE}"
            JSON="${JSON},\"watchdog_running\":${WD}"
            JSON="${JSON},\"udhcpc_running\":${DC}"
            JSON="${JSON},\"in_br0\":${IN_BR0}"
            JSON="${JSON},\"iface_up\":${UP}"
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

            CONFIGURED=0
            iface_configured "$VXD_IF" && CONFIGURED=1

            # Interface must be present in the kernel
            ip link show "$VXD_IF" >/dev/null 2>&1 || continue

            TBL=$(wlan_tbl_pfx "$VXD_IF")
            [ -z "$TBL" ] && continue

            # VXD is MIB index 5 (wlanbasic.cgi: TY="vxd" when I=5)
            VXD_DIS=$(mib_field "${TBL}.5.wlanDisabled")
            if [ "$CONFIGURED" != "1" ]; then
                [ "${VXD_DIS:-0}" = "1" ] && continue
            fi

            # SSID stored in slot 5
            SSID=$(mib_field "${TBL}.5.ssid")

            IFACE_IP=""; IFACE_GW=""; DEFROUTE="false"
            WD="false"; DC="false"; IN_BR0="false"; UP="false"
            if [ "$CONFIGURED" = "1" ]; then
                IFACE_IP=$(get_iface_ip "$VXD_IF")
                IFACE_GW=$(get_iface_gw "$VXD_IF")
                [ "$(get_defroute "$VXD_IF")" = "1" ] && DEFROUTE="true"
                watchdog_alive "$VXD_IF" && WD="true"
                udhcpc_alive   "$VXD_IF" && DC="true"
                iface_in_br0   "$VXD_IF" && IN_BR0="true"
                iface_is_up    "$VXD_IF" && UP="true"
            fi

            [ "$FIRST" = "1" ] && FIRST=0 || JSON="${JSON},"
            JSON="${JSON}{\"iface\":\"$(json_esc "$VXD_IF")\""
            JSON="${JSON},\"type\":\"wlan\""
            JSON="${JSON},\"label\":\"WiFi ${BAND_LABEL} VXD (${VXD_IF})\""
            JSON="${JSON},\"band\":\"$(json_esc "$BAND_LABEL")\""
            JSON="${JSON},\"assoc_ssid\":\"$(json_esc "$SSID")\""
            JSON="${JSON},\"configured\":$([ "$CONFIGURED" = "1" ] && echo true || echo false)"
            JSON="${JSON},\"default_route\":${DEFROUTE}"
            JSON="${JSON},\"watchdog_running\":${WD}"
            JSON="${JSON},\"udhcpc_running\":${DC}"
            JSON="${JSON},\"in_br0\":${IN_BR0}"
            JSON="${JSON},\"iface_up\":${UP}"
            JSON="${JSON},\"ip\":\"$(json_esc "$IFACE_IP")\""
            JSON="${JSON},\"gateway\":\"$(json_esc "$IFACE_GW")\"}"
        done

        JSON="${JSON}]"

        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"interfaces":%s}' "$JSON"
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

    # ── action=apply: add (or re-apply) an interface as a DHCP client ─────────
    if [ "$ACTION" = "apply" ]; then
        FORM_IFACE=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*iface=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        FORM_IFACE=$(busybox httpd -d "$FORM_IFACE" \
            | busybox tr -d '\r\n')

        FORM_DEFROUTE=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*default_route=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        case "$FORM_DEFROUTE" in 1) FORM_DEFROUTE=1 ;; *) FORM_DEFROUTE=0 ;; esac

        # Whitelist: only the six supported interfaces
        case "$FORM_IFACE" in
            eth0.2.0|eth0.3.0|wlan0|wlan1|wlan0-vxd|wlan1-vxd) ;;
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

        # If this SAME interface is already configured, cleanly stop its
        # existing daemon first (this is a re-apply / restart), so we never
        # end up with two watchdogs running for one interface. Other
        # configured interfaces are left running — repurposing one
        # interface no longer reverts every other one.
        if iface_configured "$FORM_IFACE"; then
            sh "$REVERT_SH" "$FORM_IFACE" >/dev/null 2>&1
            busybox sleep 1
        fi

        # Register in the shared state registry + default-route flag
        # synchronously (before backgrounding the daemon below) so the
        # table/startup.sh reflect this immediately rather than racing the
        # daemon's own startup.
        busybox grep -qx "$FORM_IFACE" "$STATE_FILE" 2>/dev/null \
            || printf '%s\n' "$FORM_IFACE" >> "$STATE_FILE"
        printf '%s' "$FORM_DEFROUTE" > "/tmp/repurpose_defroute_${FORM_IFACE}"

        # Only one interface may hold the real default route.
        [ "$FORM_DEFROUTE" = "1" ] && _clear_other_defaults "$FORM_IFACE"

        # Persist every currently-configured interface (this one included)
        # to startup.sh so it survives a reboot.
        update_startup_repurpose_all

        # Respond immediately (so the browser doesn't time out while udhcpc negotiates)
        printf "Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n"
        printf "OK"

        # Launch watchdog daemon in background, fully detached from the CGI's
        # stdout/stderr.  BusyBox httpd waits for EOF on the pipe before it
        # flushes the HTTP response to the browser; keeping the pipe open in the
        # daemon process (which runs an infinite watchdog loop) would stall the
        # fetch() call indefinitely.  Redirecting to /dev/null closes the
        # inherited fd so httpd gets EOF the moment the CGI script exits.
        sh "$REPURPOSE_SH" "$FORM_IFACE" "$FORM_DEFROUTE" >/dev/null 2>&1 &

        exit 0
    fi

    # ── action=revert: remove a configured interface, restore it to br0 ───────
    if [ "$ACTION" = "revert" ]; then
        FORM_IFACE=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*iface=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        FORM_IFACE=$(busybox httpd -d "$FORM_IFACE" \
            | busybox tr -d '\r\n')

        case "$FORM_IFACE" in
            eth0.2.0|eth0.3.0|wlan0|wlan1|wlan0-vxd|wlan1-vxd) ;;
            *)
                printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
                printf "Invalid interface"
                exit 0
                ;;
        esac

        if ! iface_configured "$FORM_IFACE"; then
            printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
            printf "Interface is not configured"
            exit 0
        fi

        sh "$REVERT_SH" "$FORM_IFACE" >/dev/null 2>&1
        # Belt-and-suspenders — revertwan.sh already does this, but the CGI
        # doesn't wait for it to finish, so clear these here too.
        rm -f "/tmp/repurpose_defroute_${FORM_IFACE}" "/tmp/repurpose_gw_${FORM_IFACE}"
        if [ -f "$STATE_FILE" ]; then
            _REV_TMP="/tmp/repurpose_active.cgi.$$.tmp"
            busybox grep -vx "$FORM_IFACE" "$STATE_FILE" > "$_REV_TMP" 2>/dev/null
            busybox mv "$_REV_TMP" "$STATE_FILE"
            [ -s "$STATE_FILE" ] || rm -f "$STATE_FILE"
        fi

        # Update startup.sh so it isn't relaunched on next reboot.
        update_startup_repurpose_all

        printf "Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # ── action=set_default: flip the default-route switch for a configured
    #    interface without restarting its watchdog daemon ──────────────────────
    if [ "$ACTION" = "set_default" ]; then
        FORM_IFACE=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*iface=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        FORM_IFACE=$(busybox httpd -d "$FORM_IFACE" \
            | busybox tr -d '\r\n')

        FORM_VAL=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*default_route=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        case "$FORM_VAL" in 1) FORM_VAL=1 ;; *) FORM_VAL=0 ;; esac

        case "$FORM_IFACE" in
            eth0.2.0|eth0.3.0|wlan0|wlan1|wlan0-vxd|wlan1-vxd) ;;
            *)
                printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
                printf "Invalid interface"
                exit 0
                ;;
        esac

        if ! iface_configured "$FORM_IFACE"; then
            printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
            printf "Interface is not configured"
            exit 0
        fi

        if [ "$FORM_VAL" = "1" ]; then
            _clear_other_defaults "$FORM_IFACE"
            _apply_default_now "$FORM_IFACE"
        else
            printf '0' > "/tmp/repurpose_defroute_${FORM_IFACE}"
            _cd=$(ip route show default 2>/dev/null | head -1)
            case "$_cd" in *"dev $FORM_IFACE"*) ip route del default dev "$FORM_IFACE" 2>/dev/null ;; esac
            iptables -t nat -D POSTROUTING -o "$FORM_IFACE" -j MASQUERADE 2>/dev/null
            rm -f "/tmp/repurpose_gw_${FORM_IFACE}"
        fi

        update_startup_repurpose_all

        printf "Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi
fi

# Fallback
printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
printf "Bad request"
