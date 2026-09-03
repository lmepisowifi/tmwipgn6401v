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

# wan_status.sh
#
# Reads all WAN profiles from ATM_VC_TBL (MIB ID 3004) and correlates
# them with live interface state from ifconfig / /proc.
#
# Works on RTL9607C ONT firmware (BusyBox sh, minimal tools).
#
# Output example:
#   [0] nas0_0  PPPoE  VPI=0 VCI=35  VLAN=--  UP  MAC=00:1A:69:DC:31:A0
#       ppp0_nas0_0  UP  IP=203.0.113.5  TX=1.2MiB  RX=4.5MiB
#   [1] nas0_1  Bridge VPI=0 VCI=36  VLAN=100  DOWN  MAC=(none)
#
# Usage:
#   wan_status.sh [-j]   # -j = JSON output

set -e

JSON=0
[ "$1" = "-j" ] && JSON=1

# -----------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------

# Get ifconfig output for a specific interface (empty string if not found)
ifcfg() {
    ifconfig "$1" 2>/dev/null || true
}

# Extract a field from ifconfig output
# Usage: ifcfg_field "<ifconfig_block>" "HWaddr"
ifcfg_field() {
    echo "$1" | grep -o "${2}[[:space:]]*[^[:space:]]*" | awk '{print $NF}' | head -1
}

# Check if interface exists in ifconfig -a
iface_exists() {
    ifconfig -a 2>/dev/null | grep -q "^${1}[[:space:]]"
}

# Check if interface is UP (has RUNNING flag or nonzero counters)
iface_up() {
    local info
    info=$(ifcfg "$1")
    # RUNNING flag is the reliable indicator
    echo "$info" | grep -q "RUNNING"
}

# Get IP address assigned to interface
iface_ip() {
    ifcfg "$1" | grep -o 'inet addr:[0-9.]*' | busybox cut -d: -f2
}

# Get MAC address
iface_mac() {
    ifcfg "$1" | grep -o 'HWaddr [0-9A-Fa-f:]*' | awk '{print $2}'
}

# Get RX/TX bytes
iface_rx_bytes() {
    ifcfg "$1" | grep -o 'RX bytes:[0-9]*' | busybox cut -d: -f2
}
iface_tx_bytes() {
    ifcfg "$1" | grep -o 'TX bytes:[0-9]*' | busybox cut -d: -f2
}

# Format bytes into human-readable
human_bytes() {
    local b="$1"
    [ -z "$b" ] || [ "$b" = "0" ] && { echo "0 B"; return; }
    if   [ "$b" -ge 1073741824 ]; then printf "%.1f GiB" "$(echo "$b" | awk '{printf "%.1f",$1/1073741824}')";
    elif [ "$b" -ge 1048576 ];    then printf "%.1f MiB" "$(echo "$b" | awk '{printf "%.1f",$1/1048576}')";
    elif [ "$b" -ge 1024 ];       then printf "%.1f KiB" "$(echo "$b" | awk '{printf "%.1f",$1/1024}')";
    else printf "%d B" "$b";
    fi
}

# Decode connection mode number to label
conn_mode_str() {
    case "$1" in
        0) echo "Bridge" ;;
        1) echo "IPoE"   ;;
        2) echo "PPPoE"  ;;
        3) echo "PPPoA"  ;;
        4) echo "Static" ;;
        *) echo "Mode$1" ;;
    esac
}

# Read a MIB chain field via flash get (field-name style)
# Returns empty string on failure
flash_get_chain() {
    # flash get <FIELD> <chain_index>
    flash get "$1" "$2" 2>/dev/null | awk '{print $NF}' || true
}

# Read total ATM_VC_TBL entries
get_total() {
    local n
    # Try flash get first
    n=$(flash get ATM_VC_TBL_NUM 2>/dev/null | awk '{print $NF}') && \
        [ -n "$n" ] && [ "$n" -ge 0 ] 2>/dev/null && echo "$n" && return
    # Fallback: count nas0_N interfaces (nas0_0, nas0_1, ...)
    n=$(ifconfig -a 2>/dev/null | grep -c '^nas0_[0-9]') || n=0
    echo "${n:-0}"
}

# -----------------------------------------------------------------------
# Find all PPPoE session interfaces for a given nas0_N
# spppd names them ppp<N>_nas0_<M> or just pppN
# -----------------------------------------------------------------------
find_ppp_iface() {
    local nas="$1"   # e.g. nas0_0
    local idx        # e.g. 0
    idx=$(echo "$nas" | sed 's/nas0_//')

    # Try pppN_nas0_M format first (confirmed in boa .rodata: "ppp%d_nas0_%d")
    local candidate="ppp${idx}_${nas}"
    iface_exists "$candidate" && echo "$candidate" && return

    # Try plain pppN
    candidate="ppp${idx}"
    iface_exists "$candidate" && echo "$candidate" && return

    # Scan /proc/net/dev for anything referencing nas via /var/ppp/
    # spppd writes a pid file /var/run/spppd.pid and conf /var/ppp/pppoe.conf
    # Last resort: check ppp0..ppp15
    local i=0
    while [ $i -lt 16 ]; do
        candidate="ppp${i}"
        if iface_exists "$candidate"; then
            # Verify it's associated with this nas by checking /var/ppp/ifup_<nas>
            if [ -f "/var/ppp/ifup_${nas}" ] || [ -f "/var/ppp/ifupv6_${nas}" ]; then
                echo "$candidate"
                return
            fi
        fi
        i=$((i + 1))
    done
}

# -----------------------------------------------------------------------
# Find VLAN child of nas0_N (nas0_N.VID)
# -----------------------------------------------------------------------
find_vlan_iface() {
    local nas="$1"
    # Look in ifconfig -a for nas0_N.<anything>
    ifconfig -a 2>/dev/null | grep "^${nas}\." | awk -F'[[:space:]]' '{print $1}' | head -1
}

# -----------------------------------------------------------------------
# Get spppctl status for a PPPoE session
# spppctl pppstatus <idx> — confirmed in libmib strings
# -----------------------------------------------------------------------
sppp_status() {
    local idx="$1"
    /bin/spppctl pppstatus "$idx" 2>/dev/null || true
}

# -----------------------------------------------------------------------
# JSON helpers
# -----------------------------------------------------------------------
json_str()  { printf '"%s"' "$1"; }
json_null() { printf 'null'; }
json_bool() { [ "$1" -eq 1 ] && printf 'true' || printf 'false'; }

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
TOTAL=$(get_total)

if [ "$JSON" -eq 0 ]; then
    printf "=%.0s" $(seq 1 60); echo
    printf " WAN Profile Status — RTL9607C  (%d profile(s))\n" "$TOTAL"
    printf "=%.0s" $(seq 1 60); echo
fi

[ "$TOTAL" -eq 0 ] && echo "No WAN profiles found." && exit 0

[ "$JSON" -eq 1 ] && printf '[\n'

i=0
first_json=1
while [ $i -lt "$TOTAL" ]; do

    # ------------------------------------------------------------------
    # Read MIB fields for profile $i
    # ------------------------------------------------------------------
    # Try flash get (field names mirror the ATM_VC_TBL struct fields)
    CONN_MODE=$(flash_get_chain ATM_VC_TBL_CONN_MODE   "$i")
    VPI=$(flash_get_chain       ATM_VC_TBL_VPI          "$i")
    VCI=$(flash_get_chain       ATM_VC_TBL_VCI          "$i")
    VID=$(flash_get_chain       ATM_VC_TBL_VID          "$i")
    VPRIO=$(flash_get_chain     ATM_VC_TBL_VPRIO        "$i")
    MTU=$(flash_get_chain       ATM_VC_TBL_MTU          "$i")
    NAPT=$(flash_get_chain      ATM_VC_TBL_NAPT         "$i")
    IGMP=$(flash_get_chain      ATM_VC_TBL_IGMP         "$i")
    DROUTE=$(flash_get_chain    ATM_VC_TBL_DROUTE       "$i")
    ADMIN_EN=$(flash_get_chain  ATM_VC_TBL_ADMIN_EN     "$i")
    PPP_USER=$(flash_get_chain  ATM_VC_TBL_PPP_USER     "$i")
    ITF_GROUP=$(flash_get_chain ATM_VC_TBL_ITF_GROUP    "$i")

    # Defaults if flash get not available
    [ -z "$CONN_MODE" ] && CONN_MODE="?"
    [ -z "$VPI" ]       && VPI="?"
    [ -z "$VCI" ]       && VCI="?"
    [ -z "$VID" ]       && VID="0"
    [ -z "$MTU" ]       && MTU="1500"
    [ -z "$NAPT" ]      && NAPT="?"
    [ -z "$ADMIN_EN" ]  && ADMIN_EN="?"

    MODE_STR=$(conn_mode_str "$CONN_MODE")
    IFNAME="nas0_${i}"

    # ------------------------------------------------------------------
    # Read live interface state
    # ------------------------------------------------------------------
    IF_EXISTS=0
    IF_UP=0
    IF_MAC=""
    IF_IP=""
    IF_RX=0
    IF_TX=0
    VLAN_IF=""
    PPP_IF=""
    PPP_IP=""
    PPP_RX=0
    PPP_TX=0
    PPP_STATUS=""

    if iface_exists "$IFNAME"; then
        IF_EXISTS=1
        iface_up "$IFNAME" && IF_UP=1
        IF_MAC=$(iface_mac "$IFNAME")
        IF_IP=$(iface_ip "$IFNAME")
        IF_RX=$(iface_rx_bytes "$IFNAME")
        IF_TX=$(iface_tx_bytes "$IFNAME")

        # VLAN child
        VLAN_IF=$(find_vlan_iface "$IFNAME")

        # PPPoE session interface
        if [ "$CONN_MODE" = "2" ] || [ "$CONN_MODE" = "3" ]; then
            PPP_IF=$(find_ppp_iface "$IFNAME")
            if [ -n "$PPP_IF" ]; then
                PPP_IP=$(iface_ip "$PPP_IF")
                PPP_RX=$(iface_rx_bytes "$PPP_IF")
                PPP_TX=$(iface_tx_bytes "$PPP_IF")
                PPP_STATUS=$(sppp_status "$i")
            fi
        fi
    fi

    # ------------------------------------------------------------------
    # Determine effective "up" status
    # For PPPoE: up = PPP session interface exists and has an IP
    # For IPoE/Static: up = nas0_N is RUNNING and has an IP
    # For Bridge: up = nas0_N is RUNNING (no IP expected)
    # ------------------------------------------------------------------
    STATUS="DOWN"
    case "$CONN_MODE" in
        2|3)
            [ -n "$PPP_IF" ] && [ -n "$PPP_IP" ] && STATUS="UP"
            [ -n "$PPP_IF" ] && [ -z "$PPP_IP" ] && STATUS="CONNECTING"
            ;;
        0)
            [ "$IF_UP" -eq 1 ] && STATUS="UP"
            ;;
        1|4)
            [ "$IF_UP" -eq 1 ] && [ -n "$IF_IP" ] && STATUS="UP"
            [ "$IF_UP" -eq 1 ] && [ -z "$IF_IP" ] && STATUS="CONNECTING"
            ;;
        *)
            [ "$IF_UP" -eq 1 ] && STATUS="UP"
            ;;
    esac
    [ "$IF_EXISTS" -eq 0 ] && STATUS="MISSING"
    [ "$ADMIN_EN" = "0" ]  && STATUS="DISABLED"

    # VLAN label
    VID_LABEL="--"
    [ "$VID" != "0" ] && [ -n "$VID" ] && VID_LABEL="$VID"

    # ------------------------------------------------------------------
    # Output
    # ------------------------------------------------------------------
    if [ "$JSON" -eq 1 ]; then
        [ "$first_json" -eq 0 ] && printf ',\n'
        first_json=0
        printf '  {\n'
        printf '    "index":      %d,\n'             "$i"
        printf '    "ifname":     %s,\n'             "$(json_str "$IFNAME")"
        printf '    "status":     %s,\n'             "$(json_str "$STATUS")"
        printf '    "mode":       %s,\n'             "$(json_str "$MODE_STR")"
        printf '    "mode_num":   %s,\n'             "$CONN_MODE"
        printf '    "vpi":        %s,\n'             "$VPI"
        printf '    "vci":        %s,\n'             "$VCI"
        printf '    "vlan_id":    %s,\n'             "$VID"
        printf '    "vlan_prio":  %s,\n'             "${VPRIO:-0}"
        printf '    "mtu":        %s,\n'             "$MTU"
        printf '    "napt":       %s,\n'             "$(json_bool "${NAPT:-0}")"
        printf '    "igmp":       %s,\n'             "$(json_bool "${IGMP:-0}")"
        printf '    "droute":     %s,\n'             "$(json_bool "${DROUTE:-0}")"
        printf '    "admin_en":   %s,\n'             "$(json_bool "${ADMIN_EN:-0}")"
        printf '    "mac":        %s,\n'             "$([ -n "$IF_MAC" ] && json_str "$IF_MAC" || json_null)"
        printf '    "ip":         %s,\n'             "$([ -n "$IF_IP"  ] && json_str "$IF_IP"  || json_null)"
        printf '    "rx_bytes":   %s,\n'             "${IF_RX:-0}"
        printf '    "tx_bytes":   %s,\n'             "${IF_TX:-0}"
        printf '    "vlan_iface": %s,\n'             "$([ -n "$VLAN_IF" ] && json_str "$VLAN_IF" || json_null)"
        printf '    "ppp_iface":  %s,\n'             "$([ -n "$PPP_IF"  ] && json_str "$PPP_IF"  || json_null)"
        printf '    "ppp_ip":     %s,\n'             "$([ -n "$PPP_IP"  ] && json_str "$PPP_IP"  || json_null)"
        printf '    "ppp_rx":     %s,\n'             "${PPP_RX:-0}"
        printf '    "ppp_tx":     %s,\n'             "${PPP_TX:-0}"
        printf '    "ppp_user":   %s\n'              "$([ -n "$PPP_USER" ] && json_str "$PPP_USER" || json_null)"
        printf '  }'
    else
        # Human-readable
        # Status colour codes (works on most BusyBox terminals)
        case "$STATUS" in
            UP)         SC="\033[1;32m" ;;   # bold green
            DOWN)       SC="\033[1;31m" ;;   # bold red
            CONNECTING) SC="\033[1;33m" ;;   # bold yellow
            DISABLED)   SC="\033[0;90m" ;;   # dark grey
            MISSING)    SC="\033[0;31m" ;;   # red
            *)          SC="\033[0m"    ;;
        esac
        NC="\033[0m"

        printf "\n[%d] %-12s  %-7s  VPI=%-3s VCI=%-5s  VLAN=%-5s  " \
            "$i" "$IFNAME" "$MODE_STR" "$VPI" "$VCI" "$VID_LABEL"
        printf "${SC}%-11s${NC}  MAC=%s\n" "$STATUS" "${IF_MAC:-(none)}"

        # MIB config line
        printf "    MTU=%-4s  NAPT=%-1s  IGMP=%-1s  DROUTE=%-1s  ADMIN=%-1s  itfGroup=0x%04x\n" \
            "$MTU" "${NAPT:-?}" "${IGMP:-?}" "${DROUTE:-?}" "${ADMIN_EN:-?}" "${ITF_GROUP:-0}"

        # Live interface line
        if [ "$IF_EXISTS" -eq 1 ]; then
            RX_H=$(human_bytes "$IF_RX")
            TX_H=$(human_bytes "$IF_TX")
            printf "    %s: IP=%-15s  RX=%-10s  TX=%s\n" \
                "$IFNAME" "${IF_IP:-(none)}" "$RX_H" "$TX_H"
        fi

        # VLAN sub-interface line
        if [ -n "$VLAN_IF" ]; then
            VLAN_MAC=$(iface_mac "$VLAN_IF")
            VLAN_IP=$(iface_ip "$VLAN_IF")
            VLAN_UP=$(iface_up "$VLAN_IF" && echo "UP" || echo "DOWN")
            printf "    %s: IP=%-15s  %s  MAC=%s\n" \
                "$VLAN_IF" "${VLAN_IP:-(none)}" "$VLAN_UP" "${VLAN_MAC:-(none)}"
        fi

        # PPPoE session line
        if [ -n "$PPP_IF" ]; then
            PPP_RX_H=$(human_bytes "$PPP_RX")
            PPP_TX_H=$(human_bytes "$PPP_TX")
            printf "    %s: IP=%-15s  RX=%-10s  TX=%s\n" \
                "$PPP_IF" "${PPP_IP:-(none)}" "$PPP_RX_H" "$PPP_TX_H"
            [ -n "$PPP_USER" ] && printf "    PPPoE user: %s\n" "$PPP_USER"
            [ -n "$PPP_STATUS" ] && printf "    spppctl: %s\n" "$PPP_STATUS"
        fi
    fi

    i=$((i + 1))
done

if [ "$JSON" -eq 1 ]; then
    printf '\n]\n'
else
    echo
    printf "=%.0s" $(seq 1 60); echo
fi
