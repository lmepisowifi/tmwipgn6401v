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

# Serves the stylesheet of the portal theme the operator picked in
# www2 > Hotspot > Portal > Theme — no auth required (it is just the CSS the
# portal page itself loads, like portal_css.sh).
#
# A theme is a folder hotspot/themes/<id>/ holding theme.info (name, blurb,
# swatch colours) and, for anything other than the stock look, theme.css.
# See THEMES.md in the repository root for how to write one.
#
# The selection lives in hotspot_data/portal_theme (one line: the theme id),
# NOT in portal.env: hotspot.cgi rewrites portal.env from scratch on every
# branding save / logo upload, which would silently reset the theme. It is in
# hotspot_data/ rather than hotspot/ for the same reason as the custom CSS:
# hotspot/ is re-laid by every OTA / module reinstall, hotspot_data/ is not,
# while the theme folders themselves ship with (and are refreshed by) the OTA.
#
# This script must NEVER fail loudly: whatever goes wrong it emits a valid
# (possibly empty) text/css response, so the worst case is the stock look.
#
#   (no query)   -> the saved theme
#   ?id=<id>     -> that theme instead (admin preview, or a test on your phone:
#                   open the portal as /?theme=<id>)
#
# The id is whitelisted to [a-z0-9_-] and must exist as a folder with a
# theme.css, so it can never reach outside hotspot/themes/.
BB="busybox"
HDATA="/lmepisowifi/hotspot_data"
TDIR="/lmepisowifi/hotspot/themes"
SEL="$HDATA/portal_theme"

ID=$(printf '&%s' "$QUERY_STRING" | $BB sed -n 's/.*&id=\([^&]*\).*/\1/p' | $BB tr -cd 'a-z0-9_-' | $BB cut -c1-32)
if [ -z "$ID" ] && [ -f "$SEL" ]; then
    ID=$($BB head -n1 "$SEL" 2>/dev/null | $BB tr -cd 'a-z0-9_-' | $BB cut -c1-32)
fi

CSS="$TDIR/$ID/theme.css"
if [ -z "$ID" ] || [ "$ID" = "default" ] || [ ! -f "$CSS" ]; then
    printf 'Content-Type: text/css; charset=utf-8\r\nCache-Control: no-cache, no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n'
    exit 0
fi

# Never cached, and deliberately no ETag / Last-Modified: the saved theme is
# served from ONE url whatever theme it is, so a validator (e.g. the file's
# mtime, which two theme files can share) could let the browser keep the
# previous theme's CSS after the operator switches. A theme is ~15 KB, small
# next to the portal page itself, which is not cached either.
printf 'Content-Type: text/css; charset=utf-8\r\nCache-Control: no-cache, no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n'
$BB cat "$CSS" 2>/dev/null
exit 0
