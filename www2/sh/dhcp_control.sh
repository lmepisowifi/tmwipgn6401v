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
# CHANGED: `restart` now follows the MIB DHCP_MODE the same way the stock boa
# "DHCP Mode" page does (DHCP_TYPE_T in the vendor SDK):
#   0  off
#   1  relay   — /bin/udhcpd -R <DHCPS>   (COMBINE_DHCPD_DHCRELAY build: the
#                relay is the same binary as the server and shares its pidfile)
#   2  server  — /bin/udhcpd -S <conf>    (unchanged)
#   3  client  — /bin/udhcpc -i br0 ...   (br0 itself takes its address from an
#                upstream DHCP server; same pidfile/hook paths as stock boa's
#                setupDHCPClient(), so a client started at boot by boa can be
#                stopped from here and vice versa)
# `setup` / `start` / `stop` are unchanged and only ever touch the server/relay
# daemon.
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

# br0 client mode — paths match stock boa (utility.c / subr_net.c):
#   DHCPC_PID + "." + ifname, DHCPC_SCRIPT (wrapper), DHCPC_SCRIPT_NAME + "." + ifname
LAN_IF="br0"
DHCPC_BIN="/bin/udhcpc"
DHCPC_WRAPPER="/etc/scripts/udhcpc.sh"
DHCPC_PID_BR0="/var/run/udhcpc.pid.br0"
DHCPC_HOOK_BR0="/var/udhcpc/udhcpc.br0"
DHCPC_RESOLV_BR0="/var/udhcpc/resolv.conf.br0"

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

# ── Mode handling (relay / br0 client) ──────────────────────────────────────

# DHCP_MODE as the stock UI stores it. Anything unset/unknown is treated as
# "server", which is what `restart` always did before modes existed.
get_mode() {
    case "$(mib_get DHCP_MODE)" in
        0) echo 0 ;;
        1) echo 1 ;;
        3) echo 3 ;;
        *) echo 2 ;;
    esac
}

is_ipv4() {
    [ "$(printf '%s' "$1" | busybox awk -F. '
        NF==4 { ok=1; for(i=1;i<=4;i++) if($i!~/^[0-9]+$/||$i+0>255) ok=0; print ok; exit }
        { print 0 }')" = "1" ]
}

# Stock restart_dhcp() empties the lease table whenever the mode isn't "server".
clear_leases() {
    mkdir -p /var/udhcpd
    printf '\n' > "$DHCPD_LEASES" 2>/dev/null
}

# Relay: stock startDhcpRelay() runs `udhcpd -R <MIB DHCPS>`. The relay shares
# /var/run/udhcpd.pid with the server (udhcpd main() writes it before it even
# parses its arguments), so a bad invocation leaves a stale pidfile behind —
# check the process is really alive instead of trusting the pidfile.
start_relay() {
    RELAY_SRV=$(mib_get DHCPS)
    LAN_IP=$(mib_get LAN_IP_ADDR)

    if ! is_ipv4 "$RELAY_SRV" || [ "$RELAY_SRV" = "0.0.0.0" ] || [ "$RELAY_SRV" = "255.255.255.255" ]; then
        dbg "ERROR start_relay: DHCPS='$RELAY_SRV' is not a usable server address"
        return 1
    fi
    if [ "$RELAY_SRV" = "$LAN_IP" ]; then
        dbg "ERROR start_relay: relay server $RELAY_SRV is this router's own LAN IP"
        return 1
    fi

    dbg "start_relay: server=$RELAY_SRV"
    "$DHCPD_BIN" -R "$RELAY_SRV" >/dev/null 2>&1 &
    sleep 2
    pid=$(read_pid "$DHCPD_PID")
    if [ -n "$pid" ] && pid_alive "$pid"; then
        dbg "start_relay: up, pid $pid"
        return 0
    fi
    dbg "start_relay: ERROR — udhcpd -R $RELAY_SRV is not running"
    rm -f "$DHCPD_PID"
    return 1
}

# br0 client. Same shape as stock writeDhcpClientScript(): udhcpc is run with
# the vendor wrapper (/etc/scripts/udhcpc.sh), which on bound/renew executes
# /var/udhcpc/udhcpc.<ifname> — that per-interface hook is what configures
# br0. Differences from the stock hook, all deliberate:
#   * the default route is only taken if there is none, or the current one is
#     already on br0 (stock `ip ro add` fails harmlessly when one exists; a
#     replace here could steal a working WAN default route)
#   * 169.254.x.x (udhcpc -a fallback when no server answers) restores the
#     configured LAN_IP/LAN_SUBNET with its real netmask, and stops there
#   * POSIX `case` instead of bash-only ${ip:0:8}
# DNS is written exactly as stock does ("<dns>@<our ip>" into
# /var/udhcpc/resolv.conf.br0).
write_dhcpc_hook() {
    mkdir -p /var/udhcpc
    {
        printf '#!/bin/sh\n'
        printf 'ORIG_LAN_IP="%s"\nORIG_LAN_SN="%s"\n' "$(mib_get LAN_IP_ADDR)" "$(mib_get LAN_SUBNET)"
        cat <<'HOOK_EOF'
[ -n "$ORIG_LAN_SN" ] || ORIG_LAN_SN="255.255.255.0"
RESOLV_CONF="/var/udhcpc/resolv.conf.$interface"
[ "$broadcast" ] && BROADCAST="broadcast $broadcast"
[ "$subnet" ] && NETMASK="netmask $subnet"

case "$ip" in
    169.254.*)
        echo "DHCP server did not answer: recovering to configured LAN IP ($ORIG_LAN_IP)"
        ifconfig $interface 0.0.0.0
        [ -n "$ORIG_LAN_IP" ] && ifconfig $interface $ORIG_LAN_IP netmask $ORIG_LAN_SN
        exit 0
        ;;
esac

ifconfig $interface mtu 1500
[ "$ip" != "$ciaddr" ] && ifconfig $interface 0.0.0.0
ifconfig $interface $ip $BROADCAST $NETMASK -pointopoint

if [ -n "$router" ]; then
    set -- $router
    CUR_DEF_IF=$(route -n 2>/dev/null | busybox awk '$1=="0.0.0.0" && $3=="0.0.0.0" {print $NF; exit}')
    if [ -z "$CUR_DEF_IF" ] || [ "$CUR_DEF_IF" = "$interface" ]; then
        ip route replace default via "$1" dev "$interface"
    fi
fi

if [ -n "$dns" ]; then
    rm -f "$RESOLV_CONF"
    for i in $dns; do
        case "$i" in 0.0.0.0|255.255.255.255) continue ;; esac
        echo "$i@$ip" >> "$RESOLV_CONF"
    done
fi
HOOK_EOF
    } > "$DHCPC_HOOK_BR0" || return 1
    chmod 755 "$DHCPC_HOOK_BR0"
}

start_dhcpc() {
    if [ ! -x "$DHCPC_BIN" ] || [ ! -f "$DHCPC_WRAPPER" ]; then
        dbg "ERROR start_dhcpc: $DHCPC_BIN or $DHCPC_WRAPPER missing on this firmware"
        return 1
    fi
    write_dhcpc_hook || { dbg "ERROR start_dhcpc: cannot write $DHCPC_HOOK_BR0"; return 1; }

    # Stock drops the static address before asking (formDhcpd: ifconfig br0
    # 0.0.0.0) and passes the device name as DHCP option 12.
    ifconfig "$LAN_IF" 0.0.0.0 netmask 255.255.255.0 mtu 1500 2>/dev/null
    ifconfig "$LAN_IF" up 2>/dev/null

    HOSTNAME_OPT=$(mib_get DEVICE_NAME)
    dbg "start_dhcpc: br0 client, hostname='$HOSTNAME_OPT'"
    # udhcpc here never daemonises (foreground=1 in the vendor build) and writes
    # its own pidfile; -a is stock's Microsoft auto-IP fallback for the LAN side.
    if [ -n "$HOSTNAME_OPT" ]; then
        "$DHCPC_BIN" -i "$LAN_IF" -p "$DHCPC_PID_BR0" -s "$DHCPC_WRAPPER" -H "$HOSTNAME_OPT" -a >/dev/null 2>&1 &
    else
        "$DHCPC_BIN" -i "$LAN_IF" -p "$DHCPC_PID_BR0" -s "$DHCPC_WRAPPER" -a >/dev/null 2>&1 &
    fi

    i=0
    while [ $i -lt 5 ]; do
        sleep 1
        pid=$(read_pid "$DHCPC_PID_BR0")
        [ -n "$pid" ] && pid_alive "$pid" && { dbg "start_dhcpc: up, pid $pid"; return 0; }
        i=$((i + 1))
    done
    dbg "start_dhcpc: ERROR — udhcpc did not start"
    return 1
}

# Returns 0 if a br0 client was running and has been stopped, 1 otherwise.
# Only the br0 pidfile is used: other udhcpc instances (WAN / repurposed
# ports) must never be touched, so there is deliberately no killall fallback.
stop_dhcpc() {
    pid=$(read_pid "$DHCPC_PID_BR0")
    if [ -n "$pid" ] && pid_alive "$pid"; then
        dbg "stop_dhcpc: killing pid $pid"
        kill -15 "$pid" 2>/dev/null
        i=0
        while [ $i -lt 5 ]; do
            pid_alive "$pid" || break
            sleep 1; i=$((i + 1))
        done
        pid_alive "$pid" && { dbg "stop_dhcpc: pid $pid didn't exit, SIGKILL"; kill -9 "$pid" 2>/dev/null; }
        rm -f "$DHCPC_PID_BR0"
        return 0
    fi
    rm -f "$DHCPC_PID_BR0"
    return 1
}

# Leaving client mode: put br0 back on its configured static address (what
# stock restart_lanip() does) and drop what the lease left behind.
restore_lan_ip() {
    LAN_IP=$(mib_get LAN_IP_ADDR)
    LAN_SN=$(mib_get LAN_SUBNET)
    [ -z "$LAN_SN" ] && LAN_SN="255.255.255.0"
    ip route del default dev "$LAN_IF" 2>/dev/null
    rm -f "$DHCPC_RESOLV_BR0" "$DHCPC_HOOK_BR0"
    if [ -z "$LAN_IP" ]; then
        dbg "ERROR restore_lan_ip: LAN_IP_ADDR is empty, leaving br0 as is"
        return 1
    fi
    dbg "restore_lan_ip: br0 -> $LAN_IP/$LAN_SN"
    ifconfig "$LAN_IF" "$LAN_IP" netmask "$LAN_SN" mtu 1500
}

# Bring the running system in line with DHCP_MODE.
apply_mode() {
    MODE=$(get_mode)
    dbg "apply_mode: DHCP_MODE=$MODE"

    stop_dhcpd
    if stop_dhcpc && [ "$MODE" != "3" ]; then
        restore_lan_ip
    fi
    [ "$MODE" = "2" ] || clear_leases

    case "$MODE" in
        0) dbg "apply_mode: DHCP disabled"; return 0 ;;
        1) start_relay ;;
        2) setup_dhcpd || return 1; start_dhcpd ;;
        3) start_dhcpc ;;
    esac
}

case "$1" in
    setup)   setup_dhcpd ;;
    stop)    stop_dhcpd ;;
    start)   start_dhcpd ;;
    restart) apply_mode ;;
    *)
        echo "Usage: $0 {setup|start|stop|restart}" >&2
        echo "  restart applies the MIB DHCP_MODE (0 off, 1 relay, 2 server, 3 br0 client)" >&2
        exit 1
        ;;
esac
