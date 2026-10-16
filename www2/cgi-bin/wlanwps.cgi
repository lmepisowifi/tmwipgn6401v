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


SESSION_TIMEOUT=600

# ---- Auth ----
BROWSER_SESSION=$(echo "$HTTP_COOKIE" | busybox sed -n 's/.*session=\([^;]*\).*/\1/p' | busybox tr -d '\r\n')
# Sanitize: session IDs are sha256 hex. Strip anything else to block
# path traversal (e.g. Cookie: session=../../config/foo) into rm/mv/cat.
BROWSER_SESSION=$(printf '%s' "$BROWSER_SESSION" | busybox tr -cd 'a-fA-F0-9')
SESSION_FILE="/tmp/sessions/$BROWSER_SESSION"

if [ -z "$BROWSER_SESSION" ] || [ ! -f "$SESSION_FILE" ]; then
    printf "Status: 302 Found\r\n"
    printf "Location: /login.html\r\n\r\n"
    exit 0
fi

LAST=$(cat "$SESSION_FILE" 2>/dev/null | busybox tr -d '\r\n')
NOW=$(date +%s)
if [ $((NOW - LAST)) -gt $SESSION_TIMEOUT ]; then
    rm -f "$SESSION_FILE"
    printf "Status: 302 Found\r\n"
    printf "Location: /login.html\r\n\r\n"
    exit 0
fi
echo "$NOW" > "$SESSION_FILE"

# wlanwps.cgi — WLAN > WPS page backend
#
# Band 24 -> WLAN1_MBSSIB_TBL / wlan1 (2.4 GHz)    Band 5 -> WLAN_MBSSIB_TBL / wlan0 (5 GHz)
#
# How the vendor drives WPS (user/boa formWsc() + subr_wlan.c restartWPS()):
#   per-radio switch  WLAN[1]_MBSSIB_TBL.0.wsc_disabled   (0 = WPS on)
#   push-button       echo 1 > /var/wps_start_interfaceN ; wscd -sig_pbc wlanN
#   router PIN        wscd -sig_start wlanN               (client types OUR pin)
#   client PIN        iwpriv wlanN set_mib pin=<pin> + the same wps_start_interfaceN
#   lockdown reset    wscd -sig_unlock wlanN
#   router PIN value  global MIB WSC_PIN (4 digits, or 8 with a valid checksum)
# wscd is only started by the vendor for an SSID that passes check_wps_enc():
# not WEP / WPA-only / WPA2-TKIP-only / hidden / 802.1X.  We surface exactly
# those cases as "blockers" instead of letting a button silently do nothing.

# ── Debug logging ─────────────────────────────────────────────────────────────
DBG_LOG="/tmp/wlanwps_debug.log"
dbg() {
    # /tmp is RAM on this device - keep the log from growing without bound
    if [ -f "$DBG_LOG" ] && [ "$(busybox wc -c < "$DBG_LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
        : > "$DBG_LOG"
    fi
    printf '[%s] wlanwps.cgi: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$DBG_LOG" 2>/dev/null
}

WSCD=/bin/wscd
WPS_WALKTIME=120     # seconds a PBC/PIN session stays open (vendor: "within 2 minutes")
WLANAPPLY=/lmepisowifi/www2/tool/wlanapply
WL_HELPER_OK=""

# ── Band selection ────────────────────────────────────────────────────────────
band_keys() {
    case "$1" in
        5)
            TBL="WLAN_MBSSIB_TBL"
            WIF="wlan0"
            WIDX=0
            FLAT_DIS_KEY="WSC_DISABLE"
            ;;
        *)
            TBL="WLAN1_MBSSIB_TBL"
            WIF="wlan1"
            WIDX=1
            FLAT_DIS_KEY="WLAN1_WSC_DISABLE"
            ;;
    esac
}

# ── Helpers ───────────────────────────────────────────────────────────────────
# Trimmed on purpose: the pgn6401v `mib` tool right-pads field names, so the
# value would otherwise come back with leading whitespace.
mib_field() {
    mib get "$1" 2>/dev/null \
        | busybox grep "=" \
        | busybox cut -d'=' -f2- \
        | busybox tr -d '\r\n' \
        | busybox sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

json_esc() {
    printf '%s' "$1" | busybox sed 's/\\/\\\\/g; s/"/\\"/g'
}

reply() {
    printf 'Status: %s\r\n' "$1"
    printf 'Content-Type: text/plain\r\n\r\n'
    printf '%s' "$2"
}

# POST field helpers - anchored on "&name=" so "ssid" can never match inside
# "bssid" (same reasoning as wlanbasic.cgi).
pd_str() {
    RAW=$(echo "&$POST_DATA" \
        | busybox sed -n "s/.*&${1}=\\([^&]*\\).*/\\1/p" \
        | busybox tr -d '\r\n')
    busybox httpd -d "$RAW" 2>/dev/null | busybox tr -d '\r\n'
}

pd_int() {
    V=$(echo "&$POST_DATA" \
        | busybox sed -n "s/.*&${1}=\\([^&]*\\).*/\\1/p" \
        | busybox tr -d '\r\n')
    case "$V" in ''|*[!0-9]*) V="${2:-0}" ;; esac
    printf '%s' "$V"
}

# ── wscd presence / state ─────────────────────────────────────────────────────
wscd_bin_ok() {
    [ -x "$WSCD" ] && return 0
    _wb=$(command -v wscd 2>/dev/null)
    if [ -n "$_wb" ] && [ -x "$_wb" ]; then
        WSCD="$_wb"
        return 0
    fi
    return 1
}

# wscd_running IFACE -> 0 if a live wscd serves IFACE.  The vendor can run one
# daemon per interface (wscd-wlan0.pid) or a single dual-band one
# (wscd-wlan0-wlan1.pid), so accept either.
wscd_running() {
    for _pf in "/var/run/wscd-$1.pid" /var/run/wscd-wlan0-wlan1.pid; do
        [ -f "$_pf" ] || continue
        _p=$(busybox tr -d '\r\n ' < "$_pf" 2>/dev/null)
        case "$_p" in ''|*[!0-9]*) continue ;; esac
        [ -d "/proc/$_p" ] && return 0
    done
    return 1
}

# ── Open-session tracking (wscd has no "is a session open?" query) ───────────
# We remember when WE opened a PBC/PIN window; it closes after WPS_WALKTIME.
session_file() { printf '/tmp/wlanwps_session_%s' "$1"; }

session_start() {   # $1 = iface, $2 = kind (pbc | pin | cpin)
    printf '%s %s\n' "$(date +%s)" "$2" > "$(session_file "$1")" 2>/dev/null
}

session_left() {    # $1 = iface -> seconds left, 0 when none
    _sf=$(session_file "$1")
    [ -f "$_sf" ] || { printf '0'; return; }
    _st=$(busybox awk '{print $1; exit}' "$_sf" 2>/dev/null)
    case "$_st" in ''|*[!0-9]*) rm -f "$_sf"; printf '0'; return ;; esac
    _left=$((WPS_WALKTIME - ($(date +%s) - _st)))
    # <=0: expired.  >WALKTIME: the clock stepped backwards (NTP) - drop it.
    if [ "$_left" -le 0 ] || [ "$_left" -gt "$WPS_WALKTIME" ]; then
        rm -f "$_sf"
        printf '0'
        return
    fi
    printf '%s' "$_left"
}

session_kind() {    # $1 = iface
    busybox awk '{print $2; exit}' "$(session_file "$1")" 2>/dev/null | busybox tr -d '\r\n'
}

# ── PIN validation / checksum (mirrors CheckPINCode_s() in the vendor boa) ───
# 4 digits: accepted as-is.  8 digits: 3,1,3,1,3,1,3,1 weighted sum % 10 == 0.
pin_valid() {
    case "$1" in
        [0-9][0-9][0-9][0-9]) return 0 ;;
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
            printf '%s' "$1" | busybox awk '{
                s = 0
                for (i = 1; i <= 8; i++) s += ((i % 2) ? 3 : 1) * (substr($0, i, 1) + 0)
                exit (s % 10) ? 1 : 0
            }'
            return $?
            ;;
    esac
    return 1
}

# ── Why WPS can't run on a band ───────────────────────────────────────────────
# Sets BL_JSON / BL_N / BL_FIRST (blockers: WPS cannot work) and WR_JSON / WR_N
# (warnings: it will run, but probably not how you want).  Mirrors the vendor's
# check_wps_enc() + restartWPS() skip conditions.
add_bl() {
    _bj=$(json_esc "$1")
    if [ -z "$BL_JSON" ]; then BL_JSON="\"$_bj\""; else BL_JSON="$BL_JSON,\"$_bj\""; fi
    [ -z "$BL_FIRST" ] && BL_FIRST="$1"
    BL_N=$((BL_N + 1))
}
add_wr() {
    _wj=$(json_esc "$1")
    if [ -z "$WR_JSON" ]; then WR_JSON="\"$_wj\""; else WR_JSON="$WR_JSON,\"$_wj\""; fi
    WR_N=$((WR_N + 1))
}

wps_checks() {
    band_keys "$1"
    BL_JSON=""; BL_N=0; BL_FIRST=""; WR_JSON=""; WR_N=0

    C_DIS=$(mib_field "${TBL}.0.wlanDisabled");        [ -z "$C_DIS" ]  && C_DIS=0
    C_MODE=$(mib_field "${TBL}.0.wlanMode");           [ -z "$C_MODE" ] && C_MODE=0
    C_ENC=$(mib_field "${TBL}.0.encrypt");             [ -z "$C_ENC" ]  && C_ENC=0
    case "$C_ENC" in *[!0-9]*) C_ENC=0 ;; esac
    C_1X=$(mib_field "${TBL}.0.enable1X");             [ -z "$C_1X" ]   && C_1X=0
    C_WAUTH=$(mib_field "${TBL}.0.wpaAuth");           [ -z "$C_WAUTH" ] && C_WAUTH=2
    C_UC=$(mib_field "${TBL}.0.unicastCipher");        [ -z "$C_UC" ]   && C_UC=2
    C_UC2=$(mib_field "${TBL}.0.wpa2UnicastCipher");   [ -z "$C_UC2" ]  && C_UC2=2
    C_HID=$(mib_field "${TBL}.0.hidessid");            [ -z "$C_HID" ]  && C_HID=0

    # WSC_VERSION 0 = WPS 1.0 build: the vendor only skips enterprise auth there.
    _ver=$(mib_field "WSC_VERSION")
    if [ "$_ver" = "0" ]; then STRICT=0; else STRICT=1; fi

    [ "$C_DIS" = "1" ] && add_bl "The radio is turned off"

    if [ "$C_1X" = "1" ] || { [ "$C_ENC" -ge 2 ] 2>/dev/null && [ "$C_WAUTH" = "1" ]; }; then
        add_bl "802.1X / WPA-Enterprise (RADIUS) is enabled - WPS cannot be used with it"
    fi

    if [ "$STRICT" = "1" ]; then
        [ "$C_HID" = "1" ] && add_bl "The SSID is hidden - WPS needs a broadcast SSID"
        case "$C_ENC" in
            1) add_bl "WEP security does not support WPS" ;;
            2) add_bl "WPA-only security does not support WPS (use WPA2 with AES)" ;;
            4) [ "$C_UC2" = "1" ] && add_bl "WPA2 with TKIP-only cipher does not support WPS (use AES)" ;;
            6) if [ "$C_UC" = "1" ] && [ "$C_UC2" = "1" ]; then
                   add_bl "WPA/WPA2 mixed with TKIP-only ciphers does not support WPS (use AES)"
               fi ;;
        esac
    fi

    [ "$C_MODE" != "0" ] && add_wr "The main interface is in client mode - WPS acts as a client, not an access point"
    case "$C_ENC" in
        0)     add_wr "This network is open (no password) - WPS adds nothing here" ;;
        16|20) add_wr "WPA3 networks may not support WPS on this firmware - WPA2-PSK (AES) is the reliable choice" ;;
    esac
}

# ── Apply: restart only the affected radio, never both ───────────────────────
# Why a per-band restart is enough to (re)start WPS: stopwlan() SIGKILLs wscd,
# and startWLan() always ends with startWLanOneTimeDaemon() -> start_WPS(), which
# relaunches wscd for every band whose wsc_disabled is 0 (skipping live ones).
# Same order as wlanbasic.cgi: wlanapply (one radio) first, the stock
# `wlan_apply restart` only if the helper is missing or fails.
wl_helper_ok() {
    if [ -z "$WL_HELPER_OK" ]; then
        WL_HELPER_OK=1
        if [ -f "$WLANAPPLY" ]; then
            [ -x "$WLANAPPLY" ] || chmod +x "$WLANAPPLY" 2>/dev/null
            if [ -x "$WLANAPPLY" ] && "$WLANAPPLY" check >/dev/null 2>&1; then
                WL_HELPER_OK=0
            fi
        fi
    fi
    return "$WL_HELPER_OK"
}

wl_restart_band() {   # $1 = 5 | 24
    if [ "$1" = "5" ]; then _wl_bn=5g; else _wl_bn=2g; fi
    if wl_helper_ok; then
        "$WLANAPPLY" restart "$_wl_bn" all >> "$DBG_LOG" 2>&1
        _wl_rc=$?
        if [ "$_wl_rc" = "0" ]; then
            dbg "wlanapply restart $_wl_bn all ok"
            return 0
        fi
        dbg "wlanapply restart $_wl_bn all failed (rc=$_wl_rc), falling back to wlan_apply restart"
    else
        dbg "wlanapply unavailable, falling back to wlan_apply restart"
    fi
    wlan_apply restart
}

# apply_bands_bg BAND... -> restart each band after the HTTP reply has gone out
apply_bands_bg() {
    [ $# -gt 0 ] || return 0
    # stopwlan() SIGKILLs every wscd, so any window we opened is gone
    rm -f /tmp/wlanwps_session_* 2>/dev/null
    (
        if wl_helper_ok; then
            for _ab in "$@"; do
                wl_restart_band "$_ab"
            done
        else
            # stock restart already covers every band - once is enough
            dbg "wlanapply unavailable, single wlan_apply restart for: $*"
            wlan_apply restart
        fi
    ) >/dev/null 2>&1 </dev/null &
}

# Reply + exit helper for the trigger actions: the band must be able to run WPS.
require_ready() {   # $1 = band
    band_keys "$1"
    if ! wscd_bin_ok; then
        reply "501 Not Implemented" "This firmware has no WPS daemon (wscd)"
        exit 0
    fi
    _rd=$(mib_field "${TBL}.0.wsc_disabled")
    if [ -z "$_rd" ]; then
        reply "501 Not Implemented" "This firmware does not expose WPS settings for this band"
        exit 0
    fi
    if [ "$_rd" != "0" ]; then
        reply "409 Conflict" "WPS is turned off on this band - enable it first"
        exit 0
    fi
    wps_checks "$1"
    if [ "$BL_N" -gt 0 ]; then
        reply "409 Conflict" "WPS cannot run on this band: $BL_FIRST"
        exit 0
    fi
    if ! wscd_running "$WIF"; then
        reply "409 Conflict" "The WPS daemon is not running for $WIF - toggle WPS off and on again, or restart WiFi"
        exit 0
    fi
}

valid_band() {
    case "$1" in 24|5) return 0 ;; esac
    return 1
}

# ── status JSON for one band ──────────────────────────────────────────────────
emit_band() {
    _eb="$1"
    band_keys "$_eb"
    _wd=$(mib_field "${TBL}.0.wsc_disabled")
    if [ -z "$_wd" ]; then
        printf '{"band":"%s","iface":"%s","present":false}' "$_eb" "$WIF"
        return
    fi
    _wc=$(mib_field "${TBL}.0.wsc_configured"); [ -z "$_wc" ] && _wc=0
    _ssid=$(mib_field "${TBL}.0.ssid")
    wps_checks "$_eb"

    if [ "$_wd" = "0" ]; then _en=true; else _en=false; fi
    if [ "$_wc" = "1" ]; then _cf=true; else _cf=false; fi
    if [ "$C_DIS" = "1" ]; then _radio=false; else _radio=true; fi
    if wscd_running "$WIF"; then _run=true; else _run=false; fi
    _left=0
    if [ "$_run" = "true" ]; then _left=$(session_left "$WIF"); else rm -f "$(session_file "$WIF")"; fi
    _kind=""
    [ "$_left" -gt 0 ] && _kind=$(session_kind "$WIF")

    printf '{"band":"%s","iface":"%s","present":true,"enabled":%s,"configured":%s,"radioOn":%s,' \
        "$_eb" "$WIF" "$_en" "$_cf" "$_radio"
    printf '"ssid":"%s","encrypt":%s,"running":%s,"left":%s,"kind":"%s",' \
        "$(json_esc "$_ssid")" "$C_ENC" "$_run" "$_left" "$(json_esc "$_kind")"
    printf '"blockers":[%s],"warnings":[%s]}' "$BL_JSON" "$WR_JSON"
}

emit_live_band() {
    band_keys "$1"
    if wscd_running "$WIF"; then _run=true; else _run=false; fi
    _left=0
    if [ "$_run" = "true" ]; then _left=$(session_left "$WIF"); else rm -f "$(session_file "$WIF")"; fi
    _kind=""
    [ "$_left" -gt 0 ] && _kind=$(session_kind "$WIF")
    printf '{"band":"%s","running":%s,"left":%s,"kind":"%s"}' "$1" "$_run" "$_left" "$(json_esc "$_kind")"
}

# ==========================================
# GET
# ==========================================
if [ "$REQUEST_METHOD" = "GET" ]; then

    # ---- action=status : everything the page needs (reads the MIB) ----
    if echo "$QUERY_STRING" | busybox grep -q "action=status"; then
        if wscd_bin_ok; then _bin=true; else _bin=false; fi
        _pin=$(mib_field "WSC_PIN")
        case "$_pin" in *[!0-9]*) _pin="" ;; esac
        if [ -n "$_pin" ] && pin_valid "$_pin"; then _pv=true; else _pv=false; fi
        _vv=$(mib_field "WSC_VERSION")
        if [ "$_vv" = "0" ]; then _wps2=false; else _wps2=true; fi

        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n"
        printf "Cache-Control: no-store\r\n\r\n"
        printf '{"wscdBin":%s,"wps2":%s,"pin":"%s","pinValid":%s,"walkTime":%s,"bands":[' \
            "$_bin" "$_wps2" "$_pin" "$_pv" "$WPS_WALKTIME"
        emit_band 24
        printf ','
        emit_band 5
        printf ']}'
        exit 0
    fi

    # ---- action=live : cheap poll (no MIB reads) - daemon + open-session state ----
    if echo "$QUERY_STRING" | busybox grep -q "action=live"; then
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n"
        printf "Cache-Control: no-store\r\n\r\n"
        printf '['
        emit_live_band 24
        printf ','
        emit_live_band 5
        printf ']'
        exit 0
    fi

    printf "Status: 200 OK\r\n"
    printf "Content-Type: text/plain\r\n\r\n"
    printf "wlanwps"
    exit 0
fi

# ==========================================
# POST
# ==========================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    # Clamp body size (non-numeric -> 0, cap 4KB): these forms are tiny, and an
    # attacker-chosen Content-Length must not force a long byte-by-byte read.
    __CL="${CONTENT_LENGTH:-0}"; case "$__CL" in *[!0-9]*|"") __CL=0 ;; esac
    [ "$__CL" -gt 4096 ] && __CL=4096
    POST_DATA=$(busybox dd bs=1 count="$__CL" 2>/dev/null)
    ACTION=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*action=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')

    # ---- action=set_enabled : band=24|5 & enabled=0|1 ----
    if [ "$ACTION" = "set_enabled" ]; then
        BAND=$(pd_str band)
        valid_band "$BAND" || { reply "400 Bad Request" "Invalid band"; exit 0; }
        EN=$(pd_int enabled 0)
        case "$EN" in 0|1) ;; *) reply "400 Bad Request" "Invalid value"; exit 0 ;; esac

        band_keys "$BAND"
        CUR=$(mib_field "${TBL}.0.wsc_disabled")
        if [ -z "$CUR" ]; then
            reply "501 Not Implemented" "This firmware does not expose WPS settings for this band"
            exit 0
        fi

        # Turning WPS ON for a config the vendor refuses to run would just
        # leave a switch that says "on" and does nothing - say why instead.
        if [ "$EN" = "1" ]; then
            wps_checks "$BAND"
            if [ "$BL_N" -gt 0 ]; then
                reply "409 Conflict" "Cannot enable WPS: $BL_FIRST"
                exit 0
            fi
        fi

        NEWDIS=$((1 - EN))
        dbg "set_enabled band=$BAND enabled=$EN ($TBL.0.wsc_disabled $CUR -> $NEWDIS)"
        mib set "${TBL}.0.wsc_disabled" "$NEWDIS" >/dev/null 2>&1
        # The vendor mirrors this into the flat WSC_DISABLE key (update_wps_mib());
        # best effort - builds without the flat key just print an error.
        mib set "$FLAT_DIS_KEY" "$NEWDIS" >/dev/null 2>&1
        mib commit >/dev/null 2>&1

        CHK=$(mib_field "${TBL}.0.wsc_disabled")
        if [ "$CHK" != "$NEWDIS" ]; then
            dbg "set_enabled: read-back mismatch (wanted $NEWDIS, got '$CHK')"
            reply "500 Internal Server Error" "The WPS setting could not be changed"
            exit 0
        fi

        reply "200 OK" "OK"

        # Only a running radio needs a restart (this is what starts/stops wscd).
        DIS=$(mib_field "${TBL}.0.wlanDisabled")
        if [ "${DIS:-0}" = "0" ] && [ "$CUR" != "$NEWDIS" ]; then
            apply_bands_bg "$BAND"
        fi
        exit 0
    fi

    # ---- action=pbc : band=24|5  (push-button: open a 2-minute window) ----
    if [ "$ACTION" = "pbc" ]; then
        BAND=$(pd_str band)
        valid_band "$BAND" || { reply "400 Bad Request" "Invalid band"; exit 0; }
        require_ready "$BAND"
        dbg "pbc band=$BAND iface=$WIF"
        echo 1 > "/var/wps_start_interface${WIDX}" 2>/dev/null
        "$WSCD" -sig_pbc "$WIF" >> "$DBG_LOG" 2>&1
        session_start "$WIF" pbc
        reply "200 OK" "OK"
        exit 0
    fi

    # ---- action=pin_router : band=24|5  (client enters OUR pin) ----
    if [ "$ACTION" = "pin_router" ]; then
        BAND=$(pd_str band)
        valid_band "$BAND" || { reply "400 Bad Request" "Invalid band"; exit 0; }
        require_ready "$BAND"
        dbg "pin_router band=$BAND iface=$WIF"
        "$WSCD" -sig_start "$WIF" >> "$DBG_LOG" 2>&1
        session_start "$WIF" pin
        reply "200 OK" "OK"
        exit 0
    fi

    # ---- action=pin_client : band=24|5 & pin=<client's pin> ----
    if [ "$ACTION" = "pin_client" ]; then
        BAND=$(pd_str band)
        valid_band "$BAND" || { reply "400 Bad Request" "Invalid band"; exit 0; }
        CPIN=$(pd_str pin | busybox tr -d ' -')
        if ! pin_valid "$CPIN"; then
            reply "400 Bad Request" "Invalid PIN - use 4 digits, or an 8-digit PIN with a valid checksum"
            exit 0
        fi
        require_ready "$BAND"
        dbg "pin_client band=$BAND iface=$WIF"        # (the PIN itself is not logged)
        echo 1 > "/var/wps_start_interface${WIDX}" 2>/dev/null
        iwpriv "$WIF" set_mib "pin=$CPIN" >/dev/null 2>&1
        session_start "$WIF" cpin
        reply "200 OK" "OK"
        exit 0
    fi

    # ---- action=unlock : band=24|5  (clear the PIN brute-force lockdown) ----
    if [ "$ACTION" = "unlock" ]; then
        BAND=$(pd_str band)
        valid_band "$BAND" || { reply "400 Bad Request" "Invalid band"; exit 0; }
        require_ready "$BAND"
        dbg "unlock band=$BAND iface=$WIF"
        "$WSCD" -sig_unlock "$WIF" >> "$DBG_LOG" 2>&1
        reply "200 OK" "OK"
        exit 0
    fi

    # ---- action=set_pin : pin=<router pin> ----
    if [ "$ACTION" = "set_pin" ]; then
        NPIN=$(pd_str pin | busybox tr -d ' -')
        if ! pin_valid "$NPIN"; then
            reply "400 Bad Request" "Invalid PIN - use 4 digits, or an 8-digit PIN with a valid checksum"
            exit 0
        fi
        OLDPIN=$(mib_field "WSC_PIN")
        if [ -z "$OLDPIN" ]; then
            reply "501 Not Implemented" "This firmware does not expose a WPS PIN"
            exit 0
        fi
        dbg "set_pin (value not logged)"
        mib set "WSC_PIN" "$NPIN" >/dev/null 2>&1
        mib commit >/dev/null 2>&1
        if [ "$(mib_field "WSC_PIN")" != "$NPIN" ]; then
            dbg "set_pin: read-back mismatch"
            reply "500 Internal Server Error" "The PIN could not be saved"
            exit 0
        fi
        reply "200 OK" "OK"

        # wscd reads the PIN at start-up, so bands that are running WPS get a
        # one-radio restart (the vendor does a full restart here).
        TORESTART=""
        for _b in 24 5; do
            band_keys "$_b"
            _d=$(mib_field "${TBL}.0.wsc_disabled")
            _r=$(mib_field "${TBL}.0.wlanDisabled")
            if [ "$_d" = "0" ] && [ "${_r:-0}" = "0" ]; then
                TORESTART="$TORESTART $_b"
            fi
        done
        # shellcheck disable=SC2086
        apply_bands_bg $TORESTART
        exit 0
    fi

    reply "400 Bad Request" "Unknown action"
    exit 0
fi

printf "Status: 302 Found\r\n"
printf "Location: /wlanwps.html\r\n\r\n"
