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

# 404 handler + captive-portal redirector (dynamic IP, host-agnostic).
BB="busybox"
[ -f /tmp/coin_config.env ] && . /tmp/coin_config.env

# 1. patched httpd exports the local socket addr the client actually hit
_srv_ip="$SERVER_ADDR"
_srv_port="$SERVER_PORT"

# 2. fallback: ask the kernel which local IP faces this client
if [ -z "$_srv_ip" ] && [ -n "$REMOTE_ADDR" ]; then
    _srv_ip=$(ip -4 route get "$REMOTE_ADDR" 2>/dev/null \
        | $BB awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
fi

# 3. config override, then the baked-in portal IP
[ -z "$_srv_ip" ] && _srv_ip="${PORTAL_IP:-10.0.0.1}"

# 4. HARD guarantee: never allow an empty host (empty host => redirect loop)
_srv_ip="${_srv_ip:-10.0.0.1}"
_srv_port="${_srv_port:-${PORTAL_PORT:-80}}"

case "${REQUEST_URI%%\?*}" in
    /admin|/admin/|/admin/*)
        _loc="http://${_srv_ip}:8080/"
        ;;
    *)
        _cb="$($BB date +%s)"
        _loc="http://${_srv_ip}:${_srv_port}/index.html?v=${_cb}"
        ;;
esac

echo "Status: 302 Found"
echo "Location: ${_loc}"
echo "Content-Type: text/html"
echo "Cache-Control: no-cache, no-store"
echo "Pragma: no-cache"
echo "Connection: close"
echo ""
echo "<!DOCTYPE html><html><head>"
echo "<meta http-equiv=\"refresh\" content=\"0;url=${_loc}\">"
echo "</head><body>"
echo "Redirecting to <a href=\"${_loc}\">${_loc}</a>..."
echo "</body></html>"
