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

# br0static.sh — default gateway + DNS for a *static* br0 (Quick Setup)
#
#   br0static.sh apply   put the saved gateway / DNS in place now
#   br0static.sh boot    wait for the SDK startup to finish, then apply
#   br0static.sh clear   forget the saved values and drop the route we added
#
# Why this exists: when br0 is a plain static address (Quick Setup's Access
# Point / Extender modes) the vendor firmware has no MIB for "default gateway
# of the LAN bridge", so the device itself — OTA updates, NTP, the hotspot
# module's downloads — would have no route out. Quick Setup stores the values
# in $ENV_FILE and this script re-applies them after every boot.
#
# $ENV_FILE is written only by quicksetup.sh, one KEY=VALUE per line:
#     GW=192.168.1.1
#     DNS1=1.1.1.1
#     DNS2=8.8.8.8
# It is parsed, never sourced, and every value must be a plain IPv4 address.
#
# Nothing happens in br0 DHCP-client mode (DHCP_MODE=3): the lease already
# carries the router and DNS servers.
#
# Test hooks: BR0S_ENV, BR0S_RESOLV, BR0S_BB, BR0S_LOG.

ENV_FILE="${BR0S_ENV:-/lmepisowifi/www2/data/br0_static.env}"
RESOLV="${BR0S_RESOLV:-/etc/resolv.conf}"
BB="${BR0S_BB:-busybox}"
LOG="${BR0S_LOG:-/tmp/br0static.log}"
LAN_IF=br0

say() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

is_ipv4() {
    [ -n "$1" ] || return 1
    printf '%s' "$1" | $BB awk -F. '
        { ok = (NF == 4)
          for (i = 1; i <= NF && ok; i++) if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i + 0 > 255) ok = 0
          exit ok ? 0 : 1 }'
}

# env_get KEY — value of KEY from the env file (first match, trimmed)
env_get() {
    [ -f "$ENV_FILE" ] || return 0
    $BB awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); gsub(/[ \t\r]+$/, "", v); print v; exit }' "$ENV_FILE"
}

dhcp_mode() {
    mib get DHCP_MODE 2>/dev/null | $BB cut -d= -f2- | $BB tr -d '\r\n \t'
}

do_apply() {
    [ -f "$ENV_FILE" ] || { say "apply: no $ENV_FILE, nothing to do"; return 0; }
    if [ "$(dhcp_mode)" = "3" ]; then
        say "apply: br0 is a DHCP client, leaving routes and DNS to the lease"
        return 0
    fi

    GW=$(env_get GW); DNS1=$(env_get DNS1); DNS2=$(env_get DNS2)

    if [ -n "$GW" ]; then
        if is_ipv4 "$GW"; then
            if ip route replace default via "$GW" dev "$LAN_IF" 2>>"$LOG"; then
                say "apply: default route via $GW dev $LAN_IF"
            else
                say "apply: could not set default route via $GW"
            fi
        else
            say "apply: ignoring invalid GW '$GW'"
        fi
    fi

    # DNS: our servers go first, whatever is already in resolv.conf stays as a
    # fallback behind them. cat > (not mv) keeps a symlinked/bind-mounted
    # resolv.conf working, same as ensure_dns.sh.
    _new=""
    for _d in "$DNS1" "$DNS2"; do
        [ -n "$_d" ] || continue
        if is_ipv4 "$_d"; then _new="$_new $_d"; else say "apply: ignoring invalid DNS '$_d'"; fi
    done
    [ -n "$_new" ] || return 0

    _tmp="/tmp/br0static.$$"
    {
        for _d in $_new; do printf 'nameserver %s\n' "$_d"; done
        if [ -f "$RESOLV" ]; then
            $BB awk -v skip="$_new" '
                BEGIN { n = split(skip, s, " "); for (i = 1; i <= n; i++) drop[s[i]] = 1 }
                $1 == "nameserver" && ($2 in drop) { next }
                { print }' "$RESOLV"
        fi
    } > "$_tmp" 2>/dev/null
    if cat "$_tmp" > "$RESOLV" 2>/dev/null; then
        say "apply: resolv.conf now starts with:$_new"
    else
        say "apply: could not write $RESOLV"
    fi
    rm -f "$_tmp"
}

# The SDK's own `startup` rewrites routes and resolv.conf while it runs; wait
# for it to finish (bounded) so what we set is not immediately overwritten.
do_boot() {
    [ -f "$ENV_FILE" ] || exit 0
    _i=0
    while [ "$_i" -lt 180 ]; do
        $BB ps w 2>/dev/null | $BB grep -v grep | $BB grep -qE '(^|[ /])startup( |$)' || break
        $BB sleep 2
        _i=$((_i + 1))
    done
    $BB sleep 5
    do_apply
}

do_clear() {
    _gw=$(env_get GW)
    rm -f "$ENV_FILE"
    if [ -n "$_gw" ] && is_ipv4 "$_gw"; then
        ip route del default via "$_gw" dev "$LAN_IF" 2>/dev/null
    fi
    say "clear: removed $ENV_FILE"
}

case "$1" in
    apply) do_apply ;;
    boot)  do_boot ;;
    clear) do_clear ;;
    *)
        echo "Usage: $0 {apply|boot|clear}" >&2
        exit 1
        ;;
esac
exit 0
