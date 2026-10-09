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

# ensure_dns.sh — make sure a host resolves before something tries to download from it.
#
#   ensure_dns.sh [host]      host defaults to github.com
#   exit 0   the host resolves (it already did, or it does after the fix below)
#   exit 1   it still does not resolve (no internet, or the resolver was not the problem)
#
# Why this exists: the public-resolver fallback (1.1.1.1 / 8.8.8.8 in /etc/resolv.conf)
# used to live only in lmehspt.sh's DNS watchdog, i.e. inside the hotspot module.
# The vendor's /etc/resolv.conf is rebuilt on every boot and its resolver is not
# always able to resolve, so with the hotspot module uninstalled nothing re-added
# the fallback after a reboot and module_ctl.sh / ota.sh could not download
# anything — including the hotspot module itself.
#
# Same rules as that watchdog: resolv.conf is touched ONLY when the host really
# does not resolve, never again once 1.1.1.1 is already listed, and the original
# is kept as resolv.conf.bak. Existing entries stay as fallbacks behind the
# public resolvers.
#
# Test hooks: ENSURE_DNS_RESOLV, ENSURE_DNS_BB, ENSURE_DNS_NSLOOKUP, ENSURE_DNS_LOG.

RESOLV="${ENSURE_DNS_RESOLV:-/etc/resolv.conf}"
BB="${ENSURE_DNS_BB:-busybox}"
NSL="${ENSURE_DNS_NSLOOKUP:-$BB nslookup}"
LOG="${ENSURE_DNS_LOG:-/tmp/ensure_dns.log}"
HOST="${1:-github.com}"

say() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

case "$HOST" in ""|*[!A-Za-z0-9.-]*) exit 1 ;; esac

# Some busybox builds exit 0 even when the lookup failed, so the output is
# checked as well as the exit status.
resolves() {
    _o=$($NSL "$1" 2>&1); _rc=$?
    [ "$_rc" -eq 0 ] || return 1
    printf '%s\n' "$_o" | $BB grep -qiE "can't resolve|can't find|NXDOMAIN|SERVFAIL|REFUSED|timed out|no servers could be reached" && return 1
    return 0
}

resolves "$HOST" && exit 0

if $BB grep -qE '^nameserver[[:space:]]+1\.1\.1\.1([[:space:]]|$)' "$RESOLV" 2>/dev/null; then
    say "$HOST does not resolve, but public resolvers are already configured; leaving $RESOLV alone"
    exit 1
fi

[ -f "$RESOLV.bak" ] || cp "$RESOLV" "$RESOLV.bak" 2>/dev/null
_tmp="/tmp/ensure_dns.$$"
{
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n'
    [ -f "$RESOLV" ] && $BB grep -vE '^nameserver[[:space:]]+(1\.1\.1\.1|8\.8\.8\.8)[[:space:]]*$' "$RESOLV"
} > "$_tmp" 2>/dev/null
# cat > (not mv): keeps working if resolv.conf is a symlink or a bind mount.
if ! cat "$_tmp" 2>/dev/null > "$RESOLV"; then
    rm -f "$_tmp"; say "could not write $RESOLV"; exit 1
fi
rm -f "$_tmp"
say "$HOST did not resolve; added 1.1.1.1 / 8.8.8.8 to $RESOLV (original kept in $RESOLV.bak)"

resolves "$HOST" && exit 0
say "$HOST still does not resolve after adding public resolvers"
exit 1
