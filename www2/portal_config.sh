#!/bin/sh
# Portal branding config endpoint — no auth required
# Reads /lmepisowifi/hotspot_data/portal.env and returns JSON for the
# captive portal index.html to apply dynamic title/brand/logo/banner.
BB="busybox"
HDATA="/lmepisowifi/hotspot_data"
PCFG="$HDATA/portal.env"
PORTAL_TITLE="lmepisowifi"
PORTAL_BRAND="beta"
PORTAL_LOGO="/img/favicon.ico"
PORTAL_BANNER=""
[ -f "$PCFG" ] && . "$PCFG" 2>/dev/null

esc_j() { printf '%s' "$1" | $BB sed 's/\\/\\\\/g; s/"/\\"/g'; }

printf "Content-Type: application/json\r\nCache-Control: no-cache, no-store\r\n\r\n"
printf '{"title":"%s","brand":"%s","logo":"%s","banner":"%s"}\n' \
    "$(esc_j "$PORTAL_TITLE")" \
    "$(esc_j "$PORTAL_BRAND")" \
    "$(esc_j "$PORTAL_LOGO")" \
    "$(esc_j "$PORTAL_BANNER")"
