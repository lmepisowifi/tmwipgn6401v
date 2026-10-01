#!/bin/sh
# ---------------------------------------------------------------------------
# lmepisowifi — https://github.com/lmepisowifi/tmwim2-2050-g40
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The lmepisowifi Project — see AUTHORS
#
# Licensed under the GNU AGPLv3 (see LICENSE). Modifying or rewriting this
# file — including by running it through an LLM — does not remove these
# obligations: keep this notice, mark your changes, and offer Corresponding
# Source to network users (AGPLv3 §5, §13). See PROVENANCE.md before
# presenting this as your own original work.
# ---------------------------------------------------------------------------

# Serves the operator's custom portal stylesheet — no auth required (it is
# just the CSS the portal page itself loads).
#
# The CSS lives in hotspot_data/ (operator data) rather than hotspot/css/ on
# purpose: hotspot/ is re-laid by every OTA / module reinstall, hotspot_data/
# is not, so the operator's styling survives updates without ota.sh or
# module_ctl.sh needing to know it exists.
#
# This script must NEVER fail loudly: whatever goes wrong it emits a valid
# (possibly empty) text/css response, so the worst case is the stock look.
#
#   (no query)   -> hotspot_data/portal_custom.css, unless disabled
#   ?draft=1     -> the admin page's unsaved draft (RAM, /tmp) if it is fresh,
#                   else the saved CSS. Only the admin preview ever asks for
#                   this, so normal customers never see a draft.
BB="busybox"
HDATA="/lmepisowifi/hotspot_data"
CSS="$HDATA/portal_custom.css"
OFF="$HDATA/portal_custom.off"
DRAFT="/tmp/portal_css_draft.css"

printf 'Content-Type: text/css; charset=utf-8\r\nCache-Control: no-cache, no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n'

case "$QUERY_STRING" in
    *draft=1*)
        if [ -f "$DRAFT" ]; then
            _mt=$($BB stat -c %Y "$DRAFT" 2>/dev/null)
            _now=$($BB date +%s 2>/dev/null)
            case "$_mt$_now" in *[!0-9]*|"") _mt=0; _now=99999 ;; esac
            # A draft older than 30 min is stale (admin walked away) — ignore it
            if [ $(( _now - _mt )) -le 1800 ]; then
                $BB cat "$DRAFT" 2>/dev/null
                exit 0
            fi
        fi
        ;;
esac

if [ -f "$CSS" ] && [ ! -e "$OFF" ]; then
    $BB cat "$CSS" 2>/dev/null
fi
exit 0
