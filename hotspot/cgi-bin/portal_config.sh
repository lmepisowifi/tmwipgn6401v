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

# Portal branding config endpoint — no auth required
# Returns title/brand/logo/promos JSON for captive portal dynamic branding.
BB="busybox"
HDATA="/lmepisowifi/hotspot_data"
PCFG="$HDATA/portal.env"
PORTAL_TITLE="lmepisowifi"
PORTAL_BRAND="beta"
PORTAL_LOGO="/img/favicon.ico"
PORTAL_FOOTER="Your device is identified by MAC address. Vouchers are single-use."
[ -f "$PCFG" ] && . "$PCFG" 2>/dev/null

esc_j() { printf '%s' "$1" | $BB sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Cache-buster: append ?v=<mtime> to a URL so browsers refetch whenever the
# underlying file is replaced (filename stays the same on re-upload, so the
# mtime is what actually changes). $1 = filesystem path, $2 = URL to stamp.
bust() {
    _mt=$($BB stat -c %Y "$1" 2>/dev/null)
    [ -z "$_mt" ] && _mt=0
    printf '%s?v=%s' "$2" "$_mt"
}

# Auto-detect promo images promo1.* through promo5.*
PROMOS_JSON=""
for _n in 1 2 3 4 5; do
    for _e in jpg jpeg png gif webp; do
        _pf="/lmepisowifi/hotspot/img/promo${_n}.${_e}"
        if [ -f "$_pf" ]; then
            PROMOS_JSON="${PROMOS_JSON},\"$(bust "$_pf" "/img/promo${_n}.${_e}")\""
            break
        fi
    done
done

# Cache-bust the logo too (it can be replaced via the UI while keeping its name)
if [ -f "/lmepisowifi/hotspot${PORTAL_LOGO}" ]; then
    PORTAL_LOGO="$(bust "/lmepisowifi/hotspot${PORTAL_LOGO}" "$PORTAL_LOGO")"
fi

# Auto-detect audio files
BG_MUSIC=""
COIN_SOUND=""
INSERT_BG_MUSIC=""

for _e in mp3 ogg wav; do
    if [ -f "/lmepisowifi/hotspot/audio/bg_music.${_e}" ]; then
        BG_MUSIC="$(bust "/lmepisowifi/hotspot/audio/bg_music.${_e}" "/audio/bg_music.${_e}")"
        break
    fi
done

for _e in mp3 ogg wav; do
    if [ -f "/lmepisowifi/hotspot/audio/coin_sound.${_e}" ]; then
        COIN_SOUND="$(bust "/lmepisowifi/hotspot/audio/coin_sound.${_e}" "/audio/coin_sound.${_e}")"
        break
    fi
done

# NEW: Auto-detect insert coin background music
for _e in mp3 ogg wav; do
    if [ -f "/lmepisowifi/hotspot/audio/insert_bg_music.${_e}" ]; then
        INSERT_BG_MUSIC="$(bust "/lmepisowifi/hotspot/audio/insert_bg_music.${_e}" "/audio/insert_bg_music.${_e}")"
        break
    fi
done

printf "Content-Type: application/json\r\nCache-Control: no-cache, no-store\r\n\r\n"
printf '{"title":"%s","brand":"%s","logo":"%s","promos":[%s],"bg_music":"%s","coin_sound":"%s","insert_bg_music":"%s","footer":"%s"}\n' \
    "$(esc_j "$PORTAL_TITLE")" \
    "$(esc_j "$PORTAL_BRAND")" \
    "$(esc_j "$PORTAL_LOGO")" \
    "${PROMOS_JSON#,}" \
    "$(esc_j "$BG_MUSIC")" \
    "$(esc_j "$COIN_SOUND")" \
    "$(esc_j "$INSERT_BG_MUSIC")" \
    "$(esc_j "$PORTAL_FOOTER")"
