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

# dhcp_control.sh — rebuild /var/udhcpd/udhcpd.conf from MIB and restart
# the DHCP server (/bin/udhcpd — the Realtek custom binary, NOT BusyBox).
#
# Field mapping fully verified this session: 17/17 MIB IDs read by
# libmib.so's setupDhcpd() cross-checked via `mib getname <id>` against
# the live /var/udhcpd/udhcpd.conf content.
#
# NOT wired in (present in setupDhcpd's reads but not reflected in the
# live conf on this unit, and role unconfirmed — leave alone unless you
# specifically need them):
#   DNS_MODE, SPC_ENABLED, SPC_IPTYPE

DHCPD_BIN="/bin/udhcpd"
DHCPD_CONF="/var/udhcpd/udhcpd.conf"
DHCPD_LEASES="/var/udhcpd/udhcpd.leases"
DHCPD_PID="/var/run/udhcpd.pid"

DBG_LOG="/tmp/dhcp_control_debug.log"
dbg() {
    printf '[%s] dhcp_control.sh: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
        >> "$DBG_LOG" 2>/dev/null
}

mib_get() { mib get "$1" 2>/dev/null | busybox cut -d= -f2- | busybox tr -d '\r\n' | busybox sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

read_pid() {
    [ -f "$1" ] || return 1
    p=$(cat "$1" 2>/dev/null)
    case "$p" in [0-9]*) printf '%s' "$p"; return 0 ;; esac
    return 1
}
pid_alive() { kill -0 "$1" 2>/dev/null; }

setup_dhcpd() {
    LAN_IP=$(mib_get LAN_IP_ADDR)
    POOL_START=$(mib_get LAN_DHCP_POOL_START)
    POOL_END=$(mib_get LAN_DHCP_POOL_END)
    MASK=$(mib_get DHCP_SUBNET_MASK)
    GATEWAY=$(mib_get LAN_DHCP_GATEWAY)
    LEASE=$(mib_get LAN_DHCP_LEASE)
    DOMAIN=$(mib_get LAN_DHCP_DOMAIN)
    SERIAL=$(mib_get HW_SERIAL_NO)
    TFTP=$(mib_get TFTP_SERVER_ADDR)
    TZSTR=$(mib_get POSIX_TZ_STRING)

    [ -z "$LEASE" ]  && LEASE="86400"
    [ -z "$MASK" ]   && MASK="255.255.255.0"
    [ -z "$DOMAIN" ] && DOMAIN="bbrouter"
    [ -z "$TFTP" ]   && TFTP="tftp://0.0.0.0"

    if [ -z "$LAN_IP" ] || [ -z "$POOL_START" ] || [ -z "$POOL_END" ] || [ -z "$GATEWAY" ]; then
        dbg "ERROR setup_dhcpd: missing required field(s) — LAN_IP=$LAN_IP POOL_START=$POOL_START POOL_END=$POOL_END GATEWAY=$GATEWAY"
        return 1
    fi

    DNS_OPT=$(mib_get LAN_DHCP_DNS_OPT)
    DNS_LINES=""
    if [ "$DNS_OPT" = "1" ]; then
        for k in DHCPS_DNS1 DHCPS_DNS2 DHCPS_DNS3; do
            v=$(mib_get "$k")
            [ -n "$v" ] && [ "$v" != "0.0.0.0" ] && DNS_LINES="${DNS_LINES}opt dns $v
"
        done
    else
        DNS_LINES="opt dns $LAN_IP
"
    fi
    [ -z "$DNS_LINES" ] && DNS_LINES="opt dns $LAN_IP
"

    NTP_ID=$(mib_get NTP_SERVER_ID)
    case "$NTP_ID" in ''|*[!0-9]*) NTP_ID=0 ;; esac
    NTP_HOST=$(mib_get "NTP_SERVER_HOST$((NTP_ID + 1))")
    [ -z "$NTP_HOST" ] && NTP_HOST=$(mib_get NTP_SERVER_HOST1)

    dbg "setup_dhcpd: lan_ip=$LAN_IP pool=$POOL_START-$POOL_END mask=$MASK gw=$GATEWAY lease=$LEASE dns_opt=$DNS_OPT ntp=$NTP_HOST"

    mkdir -p /var/udhcpd
    cat > "$DHCPD_CONF" <<EOF
poolname default
interface br0
server $LAN_IP
start $POOL_START
end $POOL_END
opt subnet $MASK
opt router $GATEWAY
${DNS_LINES}opt lease $LEASE
opt domain $DOMAIN
opt venspec 3561 4 00E04C 5 $SERIAL 6 IGD
opt ntpsrv $NTP_HOST
opt tftp $TFTP
opt tzstring $TZSTR
poolend end
EOF

    [ -f "$DHCPD_LEASES" ] || touch "$DHCPD_LEASES"
    dbg "setup_dhcpd: wrote $DHCPD_CONF"
    return 0
}

stop_dhcpd() {
    pid=$(read_pid "$DHCPD_PID")
    if [ -n "$pid" ] && pid_alive "$pid"; then
        dbg "stop_dhcpd: killing pid $pid"
        kill -15 "$pid" 2>/dev/null
        i=0
        while [ $i -lt 5 ]; do
            pid_alive "$pid" || break
            sleep 1; i=$((i + 1))
        done
        pid_alive "$pid" && { dbg "stop_dhcpd: pid $pid didn't exit, SIGKILL"; kill -9 "$pid" 2>/dev/null; }
    else
        busybox killall "$(basename "$DHCPD_BIN")" 2>/dev/null
    fi
    rm -f "$DHCPD_PID"
}

start_dhcpd() {
    [ -f "$DHCPD_CONF" ] || setup_dhcpd || return 1
    "$DHCPD_BIN" -S "$DHCPD_CONF" >/dev/null 2>&1 &
    i=0
    while [ $i -lt 6 ]; do
        sleep 1
        read_pid "$DHCPD_PID" >/dev/null 2>&1 && { dbg "start_dhcpd: up, pid $(read_pid "$DHCPD_PID")"; return 0; }
        i=$((i + 1))
    done
    dbg "start_dhcpd: ERROR — no pidfile after 6s, did it start?"
    return 1
}

restart_dhcpd() {
    stop_dhcpd
    setup_dhcpd || return 1
    start_dhcpd
}

case "$1" in
    setup)   setup_dhcpd ;;
    stop)    stop_dhcpd ;;
    start)   start_dhcpd ;;
    restart) restart_dhcpd ;;
    *)
        echo "Usage: $0 {setup|start|stop|restart}" >&2
        exit 1
        ;;
esac
