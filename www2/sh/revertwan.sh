#!/bin/sh
# revertwan.sh — Revert a repurposed WAN interface back to the br0 bridge
# Usage: revertwan.sh <interface>

if [ -z "$1" ]; then
    echo "Usage: $0 <interface>" >&2
    exit 1
fi

TARGET_IFACE="$1"
STATE_FILE="/tmp/repurpose_active"
DEFROUTE_FILE="/tmp/repurpose_defroute_${TARGET_IFACE}"
GW_FILE="/tmp/repurpose_gw_${TARGET_IFACE}"
PID_FILE="/tmp/repurpose_${TARGET_IFACE}.pid"
SCRIPT_PATH="/tmp/udhcpc_${TARGET_IFACE}.script"
UDHCPC_PID="/var/run/udhcpc.${TARGET_IFACE}.pid"
LOG="/tmp/repurpose_${TARGET_IFACE}.log"

printf '[%s] revertwan: reverting %s\n' "$(busybox date)" "$TARGET_IFACE"

# ── 1. Stop watchdog daemon ────────────────────────────────────────────────────
if [ -f "$PID_FILE" ]; then
    WD_PID=$(busybox tr -d '\r\n' < "$PID_FILE" 2>/dev/null)
    if [ -n "$WD_PID" ]; then
        kill "$WD_PID" 2>/dev/null
        busybox sleep 1
        kill -9 "$WD_PID" 2>/dev/null
        printf 'Stopped watchdog (pid %s)\n' "$WD_PID"
    fi
    rm -f "$PID_FILE"
fi

# ── 2. Stop the udhcpc instance ───────────────────────────────────────────────
if [ -f "$UDHCPC_PID" ]; then
    UPID=$(busybox tr -d '\r\n' < "$UDHCPC_PID" 2>/dev/null)
    [ -n "$UPID" ] && kill "$UPID" 2>/dev/null
    rm -f "$UDHCPC_PID"
fi
# Belt-and-suspenders: kill any stray udhcpc referencing this interface
busybox pkill -f "udhcpc.*${TARGET_IFACE}" 2>/dev/null || true

# ── 2b. Stop the event-driven re-enslavement watcher (ip monitor link) ────────
# This is a separate background process from the watchdog itself (started
# with its own `&` in repurposeaswan.sh), so killing WD_PID above does not
# reap it — it must be stopped explicitly or it's left running as an orphan.
MONITOR_PID_FILE="/tmp/repurpose_${TARGET_IFACE}.monitor.pid"
if [ -f "$MONITOR_PID_FILE" ]; then
    MPID=$(busybox tr -d '\r\n' < "$MONITOR_PID_FILE" 2>/dev/null)
    [ -n "$MPID" ] && kill "$MPID" 2>/dev/null
    rm -f "$MONITOR_PID_FILE"
fi

# ── 3. Remove iptables NAT masquerade rule ────────────────────────────────────
iptables -t nat -D POSTROUTING -o "$TARGET_IFACE" -j MASQUERADE 2>/dev/null
printf 'Removed NAT MASQUERADE for %s\n' "$TARGET_IFACE"

# ── 3a. Remove DHCP anti-leak rules ───────────────────────────────────────────
if ebtables --version >/dev/null 2>&1 || busybox ebtables --version >/dev/null 2>&1; then
    ebtables -D FORWARD -o "$TARGET_IFACE" -p ipv4 --ip-proto udp --ip-sport 67 -j DROP 2>/dev/null
    ebtables -D FORWARD -i "$TARGET_IFACE" -p ipv4 --ip-proto udp --ip-dport 67 -j DROP 2>/dev/null
    ebtables -D INPUT -i "$TARGET_IFACE" -p ipv4 --ip-proto udp --ip-dport 67 -j DROP 2>/dev/null
fi
iptables -t filter -D FORWARD -m physdev --physdev-out "$TARGET_IFACE" -p udp --sport 67 -j DROP 2>/dev/null
iptables -t filter -D FORWARD -m physdev --physdev-in "$TARGET_IFACE" -p udp --dport 67 -j DROP 2>/dev/null
iptables -t filter -D INPUT -i "$TARGET_IFACE" -p udp --dport 67 -j DROP 2>/dev/null
printf 'Removed DHCP anti-leak rules for %s\n' "$TARGET_IFACE"

# ── 3b. Remove LAN isolation rules ────────────────────────────────────────
iptables -t filter -D FORWARD -i "$TARGET_IFACE" -o br0 -j DROP 2>/dev/null
iptables -t filter -D INPUT -i "$TARGET_IFACE" -p tcp --dport 8080 -j ACCEPT 2>/dev/null
_RPW_MARK="/tmp/repurpose_subnet_${TARGET_IFACE}.mark"
_RPW_OLD_SUBNET=$(busybox cat "$_RPW_MARK" 2>/dev/null)
if [ -n "$_RPW_OLD_SUBNET" ]; then
    _RPW_HOTSPOT_BR=$(grep -m1 '^HOTSPOT_BR=' /tmp/coin_config.env 2>/dev/null \
        | sed 's/^HOTSPOT_BR="//;s/"$//')
    _RPW_HOTSPOT_BR="${_RPW_HOTSPOT_BR:-br1}"
    iptables -t filter -D FORWARD -i "$_RPW_HOTSPOT_BR" -d "$_RPW_OLD_SUBNET" -j DROP 2>/dev/null
fi
rm -f "$_RPW_MARK"
printf 'Removed LAN isolation rules for %s\n' "$TARGET_IFACE"

# ── 4. Flush IP addresses + take link down before re-bridging ─────────────────
ip addr flush dev "$TARGET_IFACE" 2>/dev/null
ip link set "$TARGET_IFACE" down 2>/dev/null

# ── 5. Rebind to br0 ──────────────────────────────────────────────────────────
ip link set "$TARGET_IFACE" master br0 2>/dev/null

# ── 6. Bring back up as a bridge member ───────────────────────────────────────
ip link set "$TARGET_IFACE" up 2>/dev/null

# ── 7. Clear this interface's state + temp files ──────────────────────────────
# Remove only TARGET_IFACE's own line from the shared registry — other
# concurrently repurposed interfaces (each with their own line) are left
# running and untouched.
if [ -f "$STATE_FILE" ]; then
    _RW_TMP="/tmp/repurpose_active.revert.$$.tmp"
    busybox grep -vx "$TARGET_IFACE" "$STATE_FILE" > "$_RW_TMP" 2>/dev/null
    busybox mv "$_RW_TMP" "$STATE_FILE"
    [ -s "$STATE_FILE" ] || rm -f "$STATE_FILE"
fi
rm -f "$SCRIPT_PATH"
rm -f "$LOG"
rm -f "$DEFROUTE_FILE"
rm -f "$GW_FILE"

printf '[%s] %s restored to br0\n' "$(busybox date)" "$TARGET_IFACE"
