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


BB="busybox"
SESSION_FILE="/tmp/active_sessions.txt"
USERS_FILE="/lmepisowifi/hotspot_data/users.txt"
COIN_BANK_FILE="/lmepisowifi/hotspot_data/coin_bank.txt"
HOTSPOT_BR="br1"

# Live-updatable toggles (MAC_RANDOMIZATION_FIX among them) written by
# lmehspt.sh / hotspot.cgi — same cache coin.sh/coin_result.sh already use.
[ -f /tmp/coin_config.env ] && . /tmp/coin_config.env
# MAC-randomization session-continuity fix (cookie-based device fingerprint)
[ -f /lmepisowifi/hotspot/macfix.sh ] && . /lmepisowifi/hotspot/macfix.sh

_unlock() { rm -f /tmp/hotspot_session.lock/pid 2>/dev/null; rmdir /tmp/hotspot_session.lock 2>/dev/null; }
_lock() {
    local i=0
    while ! mkdir /tmp/hotspot_session.lock 2>/dev/null; do
        # Only steal the lock once its holder is provably dead (see
        # lmehspt.sh's _lock for the full explanation) - a flat 5s wait was
        # force-breaking a live holder's lock under normal polling load and
        # letting two writers stomp the same USERS_FILE.tmp at once.
        if [ "$((i % 10))" -eq 0 ] && [ "$i" -gt 0 ]; then
            if [ "$i" -ge 300 ]; then
                $BB rm -f /tmp/hotspot_session.lock/pid 2>/dev/null
                rmdir /tmp/hotspot_session.lock 2>/dev/null
            else
                _HPID=$($BB cat /tmp/hotspot_session.lock/pid 2>/dev/null)
                if [ -z "$_HPID" ] || ! kill -0 "$_HPID" 2>/dev/null; then
                    $BB rm -f /tmp/hotspot_session.lock/pid 2>/dev/null
                    rmdir /tmp/hotspot_session.lock 2>/dev/null
                fi
            fi
        fi
        $BB sleep 0.1 2>/dev/null || sleep 0.1
        i=$((i + 1))
    done
    $BB echo $$ > /tmp/hotspot_session.lock/pid 2>/dev/null
    trap _unlock EXIT INT TERM
}

CLIENT_IP="$REMOTE_ADDR"
CLIENT_MAC=$(
    $BB cat /proc/net/arp \
    | $BB grep "^$CLIENT_IP " \
    | $BB awk '{print $4}' \
    | $BB head -1
)
# Verify/refresh this browser's fingerprint cookie and, if it was last seen
# on a different MAC (a randomized-MAC reconnect), migrate its live
# session/firewall rule onto the current one before the lookups below run.
mf_reconcile

$BB echo "Content-type: application/json"
$BB echo "Cache-Control: no-store"
[ -n "$MF_COOKIE_HEADER" ] && $BB echo "$MF_COOKIE_HEADER"
$BB echo ""

if [ -z "$CLIENT_MAC" ] || [ "$CLIENT_MAC" = "00:00:00:00:00:00" ]; then
    $BB echo '{"logged_in":false,"error":"no_mac"}'
    exit 0
fi

# Pesos banked from a below-minimum-tier coin top-up (see coin_result.sh's
# COIN_BANK_FILE) that haven't converted to time yet — already reconciled
# onto this MAC by mf_reconcile() above if it changed since the balance was
# banked. Surfaced only when nonzero so the portal's "Available coins"
# banner stays hidden for everyone else.
AVAIL_COINS=0
[ -f "$COIN_BANK_FILE" ] && AVAIL_COINS=$($BB awk -v m="$CLIENT_MAC" '$1==m{print $2; exit}' "$COIN_BANK_FILE")
case "$AVAIL_COINS" in ''|*[!0-9]*) AVAIL_COINS=0 ;; esac
AVAIL_JSON=""
[ "$AVAIL_COINS" -gt 0 ] && AVAIL_JSON=",\"available_coins\":$AVAIL_COINS"

# -- CONNECTION DETECTION (Run for everyone regardless of session) --
WLAN_IFACE=""
WLAN_BAND=""
WLAN_RSSI=""
WLAN_SNR=""
MAC_NC=$($BB echo "$CLIENT_MAC" | $BB tr -d ':' | $BB tr 'A-Z' 'a-z')

for ifpath in /sys/class/net/wlan*; do
    [ -e "$ifpath" ] || continue
    iface=$(basename "$ifpath")
    link=$(readlink -f "/sys/class/net/$iface/brport/bridge" 2>/dev/null)
    [ -n "$link" ] && [ "$(basename "$link")" = "$HOTSPOT_BR" ] || continue
    [ -r "/proc/$iface/sta_info" ] || continue

    sta=$($BB awk -v want="$MAC_NC" '
        function flush() { if (ismatch) { print rssi; print snr; found=1 } }
        /^ *[0-9]+: *stat_info/ { flush(); if (found) exit; ismatch=0; rssi=""; snr=""; next }
        /hwaddr:/ { if (index($0, want) > 0) ismatch=1 }
        /rssi:/   { rssi=$2 }
        /snr:/    { snr=$2 }
        END { flush() }
    ' "/proc/$iface/sta_info")

    if [ -n "$sta" ]; then
        WLAN_IFACE="$iface"
        WLAN_RSSI=$($BB echo "$sta" | $BB head -1)
        WLAN_SNR=$($BB echo "$sta" | $BB tail -1)
        case "$iface" in wlan1*) WLAN_BAND="2.4GHz" ;; wlan0*) WLAN_BAND="5GHz" ;; esac
        break
    fi
done

if [ -n "$WLAN_IFACE" ]; then
    CONN_JSON="\"connection\":\"WLAN\",\"wlan_iface\":\"$WLAN_IFACE\",\"band\":\"$WLAN_BAND\",\"rssi\":${WLAN_RSSI:-0},\"snr\":${WLAN_SNR:-0}"
else
    CONN_JSON="\"connection\":\"LAN\""
fi
# -----------------------------------------------------------------

_lock
SESSION=$($BB grep "^$CLIENT_MAC " "$SESSION_FILE" 2>/dev/null | $BB head -1)

if [ -n "$SESSION" ]; then
    EXPIRY=$($BB echo "$SESSION" | $BB awk '{print $2}')
    TOTAL=$($BB echo "$SESSION" | $BB awk '{print $3}')
    NOW=$($BB awk '{print int($1)}' /proc/uptime)
    REMAINING=$(( EXPIRY - NOW ))

    if [ "$REMAINING" -gt 0 ]; then
        # Handle cases where coin_result.sh hasn't appended the total yet
        [ -z "$TOTAL" ] && TOTAL=$REMAINING
        USED=$(( TOTAL - REMAINING ))
        [ "$USED" -lt 0 ] && USED=0

        $BB echo "{\"logged_in\":true,\"mac\":\"$CLIENT_MAC\",\"ip\":\"$CLIENT_IP\",\"remaining\":$REMAINING,\"total\":$TOTAL,\"used\":$USED,${CONN_JSON}${AVAIL_JSON}}"
        _unlock
        exit 0
    fi
fi

# Find paused entry in the unified users.txt master file
PAUSED=$($BB grep "^$CLIENT_MAC paused " "$USERS_FILE" 2>/dev/null | $BB head -1)
if [ -n "$PAUSED" ]; then
    # Format: MAC STATUS REMAINING TOTAL FMT
    REMAINING=$($BB echo "$PAUSED" | $BB awk '{print $3}')
    TOTAL=$($BB echo "$PAUSED" | $BB awk '{print $4}')
    [ -z "$TOTAL" ] && TOTAL=$REMAINING
    # AUTO_RESUME_ENABLED comes from coin_config.env (sourced above). When
    # on, index.html fires the same resume=1 request the "Resume Time"
    # button sends, on this same status poll — no tap needed. login.sh
    # still does the actual resume, so this flag never bypasses its
    # locking/atomic-write path, just who clicks the button.
    AR_BOOL="false"; [ "${AUTO_RESUME_ENABLED:-0}" = "1" ] && AR_BOOL="true"
    $BB echo "{\"logged_in\":false,\"mac\":\"$CLIENT_MAC\",\"ip\":\"$CLIENT_IP\",\"has_paused\":true,\"remaining\":$REMAINING,\"total\":$TOTAL,\"auto_resume\":$AR_BOOL,${CONN_JSON}${AVAIL_JSON}}"
else
    $BB echo "{\"logged_in\":false,\"mac\":\"$CLIENT_MAC\",\"ip\":\"$CLIENT_IP\",${CONN_JSON}${AVAIL_JSON}}"
fi
_unlock
