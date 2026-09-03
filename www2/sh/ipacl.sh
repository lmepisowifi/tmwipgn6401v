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

# ipacl.sh — ACC_TBL per-service access-level enforcement
# Installed at: /lmepisowifi/www2/sh/ipacl.sh
#
# Controls WAN / LAN(br0) reachability of router management services
# (telnet, ftp, tftp, web, https, ssh, snmp) at four levels, matching the
# vendor ACC_TBL mib semantics observed via `mib get ACC_TBL`:
#   0 = blocked for all
#   1 = WAN only (br0 excluded)
#   2 = br0 (LAN) access only
#   3 = WAN + LAN access
#
# Reverse-engineered from live iptables-save captures while toggling
# ACC_TBL.0.telnet through all four values. Two independent, idempotent
# rules implement it per service/port:
#
#   Rule A (mangle/PREROUTING) marks WAN(non-br0)-sourced packets to the
#     service port with 0x1000 so filter/inacc's mark-based ACCEPT lets
#     them reach INPUT. Present only for levels 1 and 3 (WAN allowed).
#
#   Rule B (filter/inacc) explicitly DROPs br0(LAN)-sourced packets to the
#     service port. Present only for levels 0 and 1 (LAN blocked). Its
#     absence lets LAN traffic fall through to the router's existing
#     "-i br+ ... ACCEPT" catch-all further down INPUT, which is why LAN
#     access is "on by default" without any rule of its own.
#
# NOTE: only single-port TCP/UDP services are handled here. `icmp` is
# protocol-matched rather than port-matched, and `samba` spans four ports
# (137/138 udp, 139/445 tcp) — both are intentionally left out of this
# generic mechanism rather than special-cased half-correctly.
#
# SSH is a special case among the services above: telnet/ftp/tftp/web/https/
# snmp are handled by daemons that are always running (boa, busybox httpd,
# etc.), so blocking their port is the entire story. SSH's daemon (dropbear)
# is only started on demand — apply_acc_rule starts/stops it to match the
# requested level, so "Blocked (all)" actually stops the process instead of
# just firewalling an idle listener. See dropbear_start/dropbear_stop below.
#
# --lib mode: `. ipacl.sh --lib` sources just the functions below (used by
# ipacl.cgi) without running the apply_all CLI dispatch at the bottom.
# Same convention as lmehspt.sh --lib.

BB="busybox"
[ "$1" = "--lib" ] && IPACL_LIB_ONLY=1

# ── Dropbear (SSH daemon) control ────────────────────────────────────────────
# Binary location: currently under /lmepisowifi (writable, OTA-updatable).
# If the binary is ever relocated to /bin (see chat notes), only these two
# paths need to change — nothing else in this file references them directly.
DROPBEAR_BIN="/bin/dropbear"
DROPBEARKEY_BIN="/bin/dropbearkey"
DROPBEAR_KEYDIR="/config/dropbear"
DROPBEAR_RSA_KEY="$DROPBEAR_KEYDIR/dropbear_rsa_host_key"
DROPBEAR_ED25519_KEY="$DROPBEAR_KEYDIR/dropbear_ed25519_host_key"

dropbear_running() {
    $BB pidof dropbear >/dev/null 2>&1
}

# dropbear_start [port] — idempotent: safe to call whether or not dropbear
# is already running. NOTE: if dropbear is already running, this does NOT
# rebind it to a different port (that's what dropbear_restart is for) —
# stock behavior here matches the original "start if not up" semantics.
dropbear_start() {
    _DB_PORT="${1:-22}"
    dropbear_running && return 0
    [ -x "$DROPBEAR_BIN" ] || return 1

    mkdir -p "$DROPBEAR_KEYDIR"
    [ -f "$DROPBEAR_RSA_KEY" ]     || "$DROPBEARKEY_BIN" -t rsa     -f "$DROPBEAR_RSA_KEY"     >/dev/null 2>&1
    [ -f "$DROPBEAR_ED25519_KEY" ] || "$DROPBEARKEY_BIN" -t ed25519 -f "$DROPBEAR_ED25519_KEY" >/dev/null 2>&1

    "$DROPBEAR_BIN" -r "$DROPBEAR_RSA_KEY" -r "$DROPBEAR_ED25519_KEY" -p "$_DB_PORT"
}

# Idempotent: safe to call whether or not dropbear is already stopped.
dropbear_stop() {
    dropbear_running || return 0
    $BB killall dropbear 2>/dev/null
}

# dropbear_restart [port] — unconditionally stop+start bound to the given
# port. Unlike dropbear_start (which is a no-op if already running),
# this is how a live port change actually takes effect, since the stock
# firmware never had per-mib SSH port support to begin with — dropbear's
# listening port was whatever was hardcoded (or defaulted to 22) at
# invocation time, with no path from ACC_TBL to the running process.
dropbear_restart() {
    _DB_PORT="${1:-22}"
    dropbear_stop
    dropbear_start "$_DB_PORT"
}

# service -> "proto default_port"
svc_defaults() {
    case "$1" in
        telnet) echo "tcp 23"  ;;
        ftp)    echo "tcp 21"  ;;
        tftp)   echo "udp 69"  ;;
        web)    echo "tcp 80"  ;;
        https)  echo "tcp 443" ;;
        ssh)    echo "tcp 22"  ;;
        snmp)   echo "udp 161" ;;
        *)      echo ""        ;;
    esac
}

mib_field() {
    mib get "$1" 2>/dev/null | $BB grep "=" | $BB cut -d'=' -f2- | $BB tr -d ' \r\n'
}

# Resolve "proto port" for a service: prefer the mib's <service>_port field
# when it's a nonzero number, else fall back to svc_defaults.
svc_proto_port() {
    _IPACL_SVC="$1"
    _IPACL_DEF=$(svc_defaults "$_IPACL_SVC")
    [ -z "$_IPACL_DEF" ] && return 1
    _IPACL_PROTO=${_IPACL_DEF%% *}
    _IPACL_PORT=${_IPACL_DEF#* }
    _IPACL_MIBPORT=$(mib_field "ACC_TBL.0.${_IPACL_SVC}_port")
    case "$_IPACL_MIBPORT" in
        ''|0) ;;
        *[!0-9]*) ;;
        *) _IPACL_PORT="$_IPACL_MIBPORT" ;;
    esac
    echo "$_IPACL_PROTO $_IPACL_PORT"
}

# Idempotently delete every instance of a rule (iptables -D removes one
# match per call; loop until none remain so re-runs never leave dupes).
_ipacl_del_all() {
    while iptables "$@" 2>/dev/null; do :; done
}

# apply_acc_rule <service> <level 0-3>
# Tears down both rule types for the service's port, then re-adds
# whichever combination matches the requested level.
apply_acc_rule() {
    _IPACL_SVC="$1"
    _IPACL_LVL="$2"

    _IPACL_PP=$(svc_proto_port "$_IPACL_SVC") || return 1
    _IPACL_PROTO=${_IPACL_PP%% *}
    _IPACL_PORT=${_IPACL_PP#* }

    _ipacl_del_all -t mangle -D PREROUTING ! -i br0 -p "$_IPACL_PROTO" -m "$_IPACL_PROTO" \
        --dport "$_IPACL_PORT" -j MARK --set-xmark 0x1000/0xffffffff
    _ipacl_del_all -t filter -D inacc -i br0 -p "$_IPACL_PROTO" -m "$_IPACL_PROTO" \
        --dport "$_IPACL_PORT" -j DROP

    case "$_IPACL_LVL" in
        1|3)
            iptables -t mangle -A PREROUTING ! -i br0 -p "$_IPACL_PROTO" -m "$_IPACL_PROTO" \
                --dport "$_IPACL_PORT" -j MARK --set-xmark 0x1000/0xffffffff 2>/dev/null
            ;;
    esac
    case "$_IPACL_LVL" in
        0|1)
            iptables -t filter -A inacc -i br0 -p "$_IPACL_PROTO" -m "$_IPACL_PROTO" \
                --dport "$_IPACL_PORT" -j DROP 2>/dev/null
            ;;
    esac

    # SSH: tie the daemon's running state to the requested level. Level 0
    # (blocked for all) stops dropbear outright; any other level means SSH
    # is reachable from at least one side, so the daemon must be up — and
    # is unconditionally restarted bound to $_IPACL_PORT (the current
    # ACC_TBL.0.ssh_port value, resolved above by svc_proto_port) so that
    # a port change is picked up immediately instead of only at next boot.
    if [ "$_IPACL_SVC" = "ssh" ]; then
        case "$_IPACL_LVL" in
            0) dropbear_stop ;;
            *) dropbear_restart "$_IPACL_PORT" ;;
        esac
    fi

    return 0
}

# apply_all — reapply iptables state (and, for ssh, the dropbear process
# state) for every supported service from the currently persisted mib
# ACC_TBL values. iptables rules are volatile (lost on reboot); the mib
# values are not — this is the boot-time bridge between the two. An unset
# mib value defaults to 0 (blocked), matching ipacl.cgi's list display, so
# a fresh device with no ACC_TBL.0.ssh value yet boots with dropbear
# stopped rather than silently running unmanaged. Called from
# www2/sh/startup.sh at boot (rc35).
apply_all() {
    for _IPACL_S in telnet ftp tftp web https ssh snmp; do
        _IPACL_V=$(mib_field "ACC_TBL.0.${_IPACL_S}")
        case "$_IPACL_V" in
            0|1|2|3) ;;
            *) _IPACL_V=0 ;;
        esac
        apply_acc_rule "$_IPACL_S" "$_IPACL_V"
    done
}

# ── CLI dispatch (skipped when sourced with --lib) ────────────────────────
if [ -z "$IPACL_LIB_ONLY" ]; then
    case "$1" in
        apply_all) apply_all ;;
    esac
fi
