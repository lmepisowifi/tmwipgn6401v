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

# tr069_ctl.sh — control the vendor TR-069 (CWMP) client, /bin/cwmpClient
# Installed at: /lmepisowifi/www2/sh/tr069_ctl.sh
# Called by:    tr069.cgi (TR-069 page)
#
# Usage:
#   tr069_ctl.sh pid              print the running cwmpClient pid (nothing if stopped)
#   tr069_ctl.sh apply [0|1]      stop cwmpClient, then start it again if the
#                                 AUTORUN flag is set in the (already committed)
#                                 MIB. Pass 1 as the 2nd arg when the Connection
#                                 Request port changed so its firewall mark rule
#                                 is rebuilt too.
#
# This mirrors what the vendor firmware's own web UI does after saving the
# TR-069 page (boa form_src_generic/fmtr069.c formTR069Config, utility.c
# off_tr069() / startCWMP() / restart_cwmp_acl()):
#   - off_tr069(): SIGTERM the pid in /var/run/cwmp.pid (cwmpClient's SIGTERM
#     handler removes the pid file and exits)
#   - wait a few seconds ("restart is too fast, then the new cwmp process will
#     receive the signal SIGTERM")
#   - startCWMP(): run /bin/cwmpClient only if CWMP_FLAG & CWMP_FLAG_AUTORUN
#
# Meant to be run detached by the CGI (setsid ... &) so it survives the CGI
# exiting; it never prints anything the caller needs to read.

BB="busybox"
PIDFILE="/var/run/cwmp.pid"
CWMP_BIN="/bin/cwmpClient"
CWMP_FLAG_AUTORUN=32      # mib.h CWMP_FLAG_AUTORUN 0x20
RMACC_MARK="0x1000"       # utility.c RMACC_MARK
CWMP_ACL_CHAIN="cwmp_aclblock"  # utility.c FW_CWMP_ACL (mangle table)
LANIF="br0"

mib_get() {
    mib get "$1" 2>/dev/null | $BB sed -n "s/^$1=//p" | $BB head -n 1 | $BB tr -d '\r'
}

# Echo the pid of the running cwmpClient, or nothing. Trust the pid file
# only if that process still exists; fall back to pidof for a stale file.
running_pid() {
    _p=$($BB cat "$PIDFILE" 2>/dev/null | $BB tr -cd '0-9')
    if [ -z "$_p" ] || [ ! -d "/proc/$_p" ]; then
        _p=$($BB pidof cwmpClient 2>/dev/null | $BB cut -d' ' -f1)
    fi
    [ -n "$_p" ] && printf '%s' "$_p"
    return 0
}

stop_client() {
    _p=$(running_pid)
    [ -z "$_p" ] && return 0
    kill -15 "$_p" 2>/dev/null
    _i=0
    while [ "$_i" -lt 10 ] && [ -d "/proc/$_p" ]; do
        sleep 1
        _i=$((_i + 1))
    done
    # Still alive after ~10 s: it ignored SIGTERM, don't leave two clients.
    [ -d "/proc/$_p" ] && kill -9 "$_p" 2>/dev/null
    $BB rm -f "$PIDFILE"
    return 0
}

start_client() {
    [ -x "$CWMP_BIN" ] || return 1
    [ -n "$(running_pid)" ] && return 0
    ( "$CWMP_BIN" >/dev/null 2>&1 </dev/null & )
    return 0
}

# Rebuild the WAN-side mark rule for the Connection Request port. This is
# exactly vendor restart_cwmp_acl() for the "CWMP ACL disabled" case: flush
# mangle/cwmp_aclblock, then mark non-br0 TCP traffic to the port so
# filter/inacc lets it through. When the CWMP ACL is enabled the chain also
# carries per-source rules built from CWMP_ACL_IP_TBL, which this script does
# not reproduce — leave it alone (it is rebuilt at next boot).
refresh_fw() {
    [ "$(mib_get CWMP_ACL_ENABLE)" = "0" ] || return 0
    _port=$(mib_get CWMP_CONREQ_PORT)
    case "$_port" in ''|0|*[!0-9]*) _port=7547 ;; esac
    iptables -t mangle -F "$CWMP_ACL_CHAIN" 2>/dev/null || return 0
    iptables -t mangle -A "$CWMP_ACL_CHAIN" ! -i "$LANIF" -p tcp --dport "$_port" \
        -j MARK --set-mark "$RMACC_MARK" 2>/dev/null
    return 0
}

case "$1" in
    pid)
        running_pid
        ;;
    apply)
        stop_client
        [ "$2" = "1" ] && refresh_fw
        _flag=$(mib_get CWMP_FLAG)
        case "$_flag" in ''|*[!0-9]*) _flag=0 ;; esac
        if [ $(( _flag & CWMP_FLAG_AUTORUN )) -ne 0 ]; then
            sleep 1
            start_client
        fi
        ;;
    *)
        echo "Usage: $0 pid | apply [0|1]" >&2
        exit 1
        ;;
esac
exit 0
