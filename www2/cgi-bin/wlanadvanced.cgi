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

# ---- Auth gate (mirrors lme.cgi) ----
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

# ---- Debug logging ----
DBG_LOG="/tmp/wlanadvanced_debug.log"
dbg() {
    printf '[%s] wlanadvanced.cgi: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
        >> "$DBG_LOG" 2>/dev/null
}

# ---- Band-specific key/table setup ----
# 5GHz   → WLAN_MBSSIB_TBL  / wlan0   (no "1" in prefix — matches the
#          convention already used in wlanbasic.cgi / wan-repurpose.cgi)
# 2.4GHz → WLAN1_MBSSIB_TBL / wlan1
# WLAN_SHORTGI / WLAN1_SHORTGI are true radio-wide MIB keys (no per-interface
# variant), so Short Guard Interval only ever appears on the idx=0 (Main AP)
# card/form — same precedent as channel/txpower in wlanbasic.cgi's save_ap.
band_keys() {
    case "$1" in
        5)
            TBL_PFX="WLAN_MBSSIB_TBL"
            SGI_KEY="WLAN_SHORTGI"
            WLAN_IF="wlan0"
            RV_PFX="/tmp/advwlan_rb_5"
            ;;
        *)
            TBL_PFX="WLAN1_MBSSIB_TBL"
            SGI_KEY="WLAN1_SHORTGI"
            WLAN_IF="wlan1"
            RV_PFX="/tmp/advwlan_rb_24"
            ;;
    esac
}

# ---- Actual netdev name for a given VAP index, for iwpriv targeting ----
# idx 0 → wlan0/wlan1 (Main AP), idx 5 → wlan{0,1}-vxd (repeater/client),
# idx 1-4 → wlan{0,1}-vapN (N = idx-1). Mirrors vifName() in wlanadvanced.html
# and the naming already used by hotspot.cgi / wan-repurpose.cgi.
vif_name() {
    case "$1" in
        0) printf '%s' "$WLAN_IF" ;;
        5) printf '%s-vxd' "$WLAN_IF" ;;
        *) printf '%s-vap%s' "$WLAN_IF" "$(($1 - 1))" ;;
    esac
}

ADV_TIMEOUT=90

# ---- MIB helpers ----
# Note: mib get reads from the live (running) radio state, not the committed
# config database. After mib set+commit but before wlan_apply restart, mib get
# still returns the OLD live values — this is what makes the rollback pattern work.
mib_get() {
    mib get "$1" \
        | busybox grep "=" \
        | busybox cut -d'=' -f2- \
        | busybox tr -d '\r\n' \
        | busybox sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ---- Unified SSID (merge) state ----
# Band steering only makes sense when the two radios advertise one SSID, which
# is exactly what the Unified SSID feature on wlanbasic does. That state lives
# in the same flat-integer JSON wlanbasic.cgi writes; read it here (read-only)
# so the advanced page can gate the band-steering control on it.
MERGE_FILE="/lmepisowifi/www2/data/merged_ssid.json"
merge_get() {
    if [ ! -f "$MERGE_FILE" ]; then printf '%s' "$2"; return; fi
    _mv=$(busybox sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\\(-\\{0,1\\}[0-9]\\{1,\\}\\).*/\\1/p" \
            "$MERGE_FILE" 2>/dev/null | busybox head -n1 | busybox tr -d '\r\n')
    [ -z "$_mv" ] && _mv="$2"
    printf '%s' "$_mv"
}
# unified_enabled → prints 1 when Unified SSID is on, else 0
unified_enabled() { [ "$(merge_get enabled 0)" = "1" ] && printf '1' || printf '0'; }


# POST field helper: extract an integer field; $1 = field name, $2 = default
# Anchored on "&name=" (synthetic leading "&" so the first field matches too)
# so a field name that's a substring of another field's name later in the
# body can't be mismatched — see wlanbasic.cgi's pd_str for the sta_connect
# ssid/bssid bug this pattern caused there.
pd_int() {
    V=$(echo "&$POST_DATA" \
        | busybox sed -n "s/.*&${1}=\\([^&]*\\).*/\\1/p" \
        | busybox tr -d '\r\n')
    case "$V" in ''|*[!0-9]*) V="${2:-0}" ;; esac
    printf '%s' "$V"
}

# pd_has NAME -> success when the POST body carries that field at all.
pd_has() { echo "&$POST_DATA" | busybox grep -q "&${1}="; }

# pd_sint NAME -> signed decimal integer (e.g. -70) in canonical form, or
# nothing when the field is missing/non-numeric. pd_int can't do this: it only
# accepts digits, and dBm values are negative.
pd_sint() {
    _ps=$(echo "&$POST_DATA" \
        | busybox sed -n "s/.*&${1}=\\([^&]*\\).*/\\1/p" \
        | busybox tr -d '\r\n')
    _ps_sign=""
    case "$_ps" in -*) _ps_sign="-"; _ps="${_ps#-}" ;; esac
    case "$_ps" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#_ps}" -le 4 ] || return 1
    _ps=$(printf '%s' "$_ps" | busybox sed 's/^0*//')   # no leading zeros: $(( )) would read them as octal
    [ -z "$_ps" ] && { printf '0'; return 0; }
    printf '%s%s' "$_ps_sign" "$_ps"
}

# ── Live apply: iwpriv first, then a single-radio / single-SSID restart ──────
# `mib set` + `mib commit` only persist a change. To make it take effect without
# `wlan_apply restart` (which stops and starts BOTH radios and every SSID):
#   1. iwpriv <if> set_mib key=value on the running driver - no restart at all.
#      set_mib is a raw write into the driver's per-interface mib struct, so it
#      is only used for what the driver re-reads at runtime (SSID, beamforming,
#      mc2u, short GI) or when the interface is re-opened (channel, width,
#      sideband - see wl_bounce).
#   2. wlanapply (src/wlanapply) - the vendor config_WLAN(ACT_RESTART_xG, idx):
#      restarts ONE radio, or ONE SSID, for everything iwpriv can't take
#      (radio on/off, AP/client mode, TX power, Auto width, security, PMF ...).
#   3. the stock `wlan_apply restart`, only if that helper is missing or fails.
WLANAPPLY=/lmepisowifi/www2/tool/wlanapply
WL_HELPER_OK=""

# wl_set IF KEY VALUE -> iwpriv IF set_mib KEY=VALUE (skipped if IF is absent)
wl_set() {
    if [ ! -d "${WL_NETSYS:-/sys/class/net}/$1" ]; then
        dbg "wl_set: $1 not present, skipped $2=$3"
        return 1
    fi
    iwpriv "$1" set_mib "$2=$3" >/dev/null 2>&1
    _wl_rc=$?
    dbg "wl_set: iwpriv $1 set_mib $2=$3 -> rc=$_wl_rc"
    return $_wl_rc
}

# wl_helper_ok -> 0 when wlanapply is usable (same preflight as wan-profile.cgi)
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

# wl_restart_scoped BAND IDX -> restart one radio (IDX 0 = whole band: the VAPs
# hang off the root, so a root/radio change restarts that band's SSIDs, as the
# vendor does) or a single SSID (IDX 1-4 = vap0-3, 5 = vxd). BAND: 5 | 24.
wl_restart_scoped() {
    if [ "$1" = "5" ]; then _wl_bn=5g; else _wl_bn=2g; fi
    _wl_ix="$2"; [ "$_wl_ix" = "0" ] && _wl_ix=all
    if wl_helper_ok; then
        "$WLANAPPLY" restart "$_wl_bn" "$_wl_ix" >> "$DBG_LOG" 2>&1
        _wl_rc=$?
        if [ "$_wl_rc" = "0" ]; then
            dbg "wl_restart_scoped: wlanapply restart $_wl_bn $_wl_ix ok"
            return 0
        fi
        dbg "wl_restart_scoped: wlanapply restart $_wl_bn $_wl_ix failed (rc=$_wl_rc), falling back to wlan_apply restart"
    else
        dbg "wl_restart_scoped: wlanapply unavailable, falling back to wlan_apply restart"
    fi
    wlan_apply restart
}

# wl_restart_bands "5 24" -> whole-band restart of each listed radio (5 = wlan0,
# 24 = wlan1), one wlanapply call per radio. For the global settings that cannot
# be applied live and have no narrower scope than a radio (band steering,
# regulatory domain). If the helper is missing or any call fails, ONE stock
# `wlan_apply restart` (everything) is run instead, so a half-applied state is
# never left behind.
wl_restart_bands() {
    if wl_helper_ok; then
        _rb_ok=1
        for _rb_band in $1; do
            if [ "$_rb_band" = "5" ]; then _rb_bn=5g; else _rb_bn=2g; fi
            "$WLANAPPLY" restart "$_rb_bn" all >> "$DBG_LOG" 2>&1
            _rb_rc=$?
            if [ "$_rb_rc" != "0" ]; then
                dbg "wl_restart_bands: wlanapply restart $_rb_bn all failed (rc=$_rb_rc), falling back to wlan_apply restart"
                _rb_ok=0
                break
            fi
            dbg "wl_restart_bands: wlanapply restart $_rb_bn all ok"
        done
        [ "$_rb_ok" = "1" ] && return 0
    else
        dbg "wl_restart_bands: wlanapply unavailable, falling back to wlan_apply restart"
    fi
    wlan_apply restart
}

# wl_set_sgi VALUE -> short GI (20/40/80 MHz) on this radio's root AND on every
# VAP/VXD netdev. The driver gives each VAP its own pmib (dot11nConfigEntry is
# per interface), and the vendor setupWLan() pushes shortGI20M/40M/80M to the
# root and to each VAP/VXD in turn - so poking the root alone would leave VAP/VXD
# clients, and 80 MHz links on 5 GHz, on the old value until the next restart.
# Interfaces that don't exist are skipped by wl_set.
wl_set_sgi() {
    for _sg_if in "$WLAN_IF" "$WLAN_IF-vap0" "$WLAN_IF-vap1" "$WLAN_IF-vap2" "$WLAN_IF-vap3" "$WLAN_IF-vxd"; do
        wl_set "$_sg_if" shortGI20M "$1"
        wl_set "$_sg_if" shortGI40M "$1"
        wl_set "$_sg_if" shortGI80M "$1"
    done
}

# ---- Band-steering RSSI thresholds -------------------------------------------
# The same two knobs the vendor (Boa) "Band Steering" page exposes, stored the
# same way:
#   MIB_STACTRL_PARAM_1 -> driver stactrl_param_1: RSSI threshold on the
#       PREFERRED band. A client there whose signal is at or below it is steered
#       to the other band (Boa: "5GHz to 2.4GHz WiFi RSSI").
#   MIB_STACTRL_PARAM_6 -> driver stactrl_param_6: RSSI threshold on the
#       NON-preferred band. A client there whose signal is above it is steered
#       back to the preferred band (Boa: "2.4GHz to 5GHz WiFi RSSI").
# Each is one BYTE stored as dBm + 100 (-75 dBm is stored as 25); this API and
# the page speak plain dBm, as Boa's page does. Unlike WIFI_STA_CONTROL, the
# `mib` CLI names carry the literal "MIB_" prefix (that is how the vendor mib
# table spells them). Vendor defaults: 25 (-75 dBm) and 40 (-60 dBm).
# The vendor applies a change with `iwpriv <if> set_mib stactrl_param_N=raw` on
# BOTH radios and again at every boot, and the driver re-reads the value on each
# steering decision, so a threshold-only change needs no WiFi restart.
BS_RSSI_P_KEY="MIB_STACTRL_PARAM_1"; BS_RSSI_P_DEF=25
BS_RSSI_O_KEY="MIB_STACTRL_PARAM_6"; BS_RSSI_O_DEF=40
# Lowest dBm accepted (Boa allows -100..0). The driver evaluates
# (threshold - tolerance) in unsigned arithmetic and the tolerance is 5, so a
# stored value under 5 would wrap around to a huge number and make the radio
# treat every client as too weak. -95 dBm is already below any usable link.
BS_RSSI_MIN_DBM=-95

# bs_rssi_read KEY DEFAULT -> raw 0-100 byte; prints DEFAULT and returns 1 when
# the key can't be read (e.g. a firmware build without band steering).
bs_rssi_read() {
    _bs_v=$(mib_get "$1")
    case "$_bs_v" in ''|*[!0-9]*) printf '%s' "$2"; return 1 ;; esac
    if [ "${#_bs_v}" -gt 3 ] || [ "$_bs_v" -gt 100 ]; then
        printf '%s' "$2"; return 1
    fi
    printf '%s' "$_bs_v"
}

# bs_rssi_apply RAW_PREFER RAW_OTHER -> push both thresholds into the running
# driver on both radios (what Boa's formWlbandsteering does with iwpriv).
bs_rssi_apply() {
    for _bs_if in wlan0 wlan1; do
        wl_set "$_bs_if" stactrl_param_1 "$1"
        wl_set "$_bs_if" stactrl_param_6 "$2"
    done
}

# Per-interface getters (idx 0-5). MIMO/TXBF/MC2U/rate-limits/PMF/SHA-256/
# rate-adaptive/fixed-rate are assumed to exist per MBSSIB_TBL entry, the same
# way dotIEEE80211W (PMF) is already confirmed per-idx in wlansecurity —
# verify with `mib get` on a VAP/VXD idx if any of these don't take effect.
get_mimo()      { mib_get "${TBL_PFX}.$1.txbf_mu"; }
get_txbf()      { mib_get "${TBL_PFX}.$1.txbf"; }
get_mc2u()      { mib_get "${TBL_PFX}.$1.mc2u_disable"; }
get_txr()       { mib_get "${TBL_PFX}.$1.tx_restrict"; }
get_rxr()       { mib_get "${TBL_PFX}.$1.rx_restrict"; }
get_pmf()       { mib_get "${TBL_PFX}.$1.dotIEEE80211W"; }
get_sha256()    { mib_get "${TBL_PFX}.$1.sha256"; }
get_disabled()  { mib_get "${TBL_PFX}.$1.wlanDisabled"; }
get_rateadapt() { mib_get "${TBL_PFX}.$1.rateAdaptiveEnabled"; }
get_fixedrate() { mib_get "${TBL_PFX}.$1.fixedTxRate"; }
get_sgi()       { mib_get "$SGI_KEY"; }   # radio-wide, no idx

# ---- 5GHz 11ac fixed-rate encoding ----
# fixedTxRate = 2147483648 + (NSS-1)*10 + MCS, for NSS 1-2 and MCS 0-9:
#   2147483648-2147483657 = NSS1 MCS0-9   2147483658-2147483667 = NSS2 MCS0-9
# No mapping has been supplied for 2.4GHz (11n) yet, so fixed-rate is only
# ever accepted when band=5; 2.4GHz always stays on rate-adaptive (auto).
FIXEDRATE_BASE=2147483648
is_valid_fixedrate_5g() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge "$FIXEDRATE_BASE" ] && [ "$1" -le $((FIXEDRATE_BASE + 19)) ]
}

# ==========================================================
# GET
# ==========================================================
if [ "$REQUEST_METHOD" = "GET" ]; then

    BAND=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*band=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')
    case "$BAND" in 5) ;; *) BAND=24 ;; esac
    band_keys "$BAND"

    # --- action=adv_confirm: client confirmed, cancel every revert timer for this band ---
    if echo "$QUERY_STRING" | busybox grep -q "action=adv_confirm"; then
        rm -f "${RV_PFX}_"*
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "confirmed"
        exit 0
    fi

    # --- action=adv_status: return band-wide + per-interface settings as JSON ---
    if echo "$QUERY_STRING" | busybox grep -q "action=adv_status"; then
        SGI=$(get_sgi); [ -z "$SGI" ] && SGI=0

        # Band steering is a GLOBAL key (WIFI_STA_CONTROL), shared by both
        # radios (not per-band / per-idx). 0=disabled, 1=enabled 5GHz preferred,
        # 3=enabled 2.4GHz preferred. Returned on every band so the (global)
        # card shows the same value regardless of which band is selected.
        BSTEER=$(mib_get "WIFI_STA_CONTROL"); case "$BSTEER" in 0|1|3) ;; *) BSTEER=0 ;; esac

        # Wireless regulatory domain: vendor HW settings, GLOBAL like band
        # steering. HW_WLAN0_* belongs to wlan0 (5GHz) and HW_WLAN1_* to wlan1
        # (2.4GHz) - see band_keys(). 0 means the entry could not be read.
        REG5=$(mib_get "HW_WLAN0_REG_DOMAIN");  case "$REG5"  in ''|*[!0-9]*) REG5=0  ;; esac
        REG24=$(mib_get "HW_WLAN1_REG_DOMAIN"); case "$REG24" in ''|*[!0-9]*) REG24=0 ;; esac

        # Whether Unified SSID is enabled — the page uses this to allow/lock the
        # band-steering control (steering is only offered when it's on).
        UNIFIED=$(unified_enabled)

        # Band-steering RSSI thresholds (stored dBm+100, reported as dBm). When
        # a key can't be read, report the vendor defaults and rssi_supported=0
        # so the page can lock the fields instead of showing made-up numbers.
        RSSI_OK=1
        _rp=$(bs_rssi_read "$BS_RSSI_P_KEY" "$BS_RSSI_P_DEF") || RSSI_OK=0
        _ro=$(bs_rssi_read "$BS_RSSI_O_KEY" "$BS_RSSI_O_DEF") || RSSI_OK=0
        RSSI_P=$((_rp - 100)); RSSI_O=$((_ro - 100))

        # Build ifaces JSON array (idx 0-5), aggregating the max remaining
        # revert time across every interface that has a pending timer.
        IFACES_J="["
        ISEP=""
        PENDING=false
        REMAINING=0
        I=0
        while [ "$I" -le 5 ]; do
            DIS=$(get_disabled "$I");  [ -z "$DIS"  ] && DIS=1
            MIMO=$(get_mimo "$I");     [ -z "$MIMO" ] && MIMO=0
            TXBF=$(get_txbf "$I");     [ -z "$TXBF" ] && TXBF=0
            MC2U=$(get_mc2u "$I");     [ -z "$MC2U" ] && MC2U=1
            TXR=$(get_txr "$I");       [ -z "$TXR"  ] && TXR=0
            RXR=$(get_rxr "$I");       [ -z "$RXR"  ] && RXR=0
            PMF=$(get_pmf "$I");       [ -z "$PMF"  ] && PMF=0
            SHA=$(get_sha256 "$I");    [ -z "$SHA"  ] && SHA=0
            RA=$(get_rateadapt "$I");  [ -z "$RA"   ] && RA=1
            FR=$(get_fixedrate "$I");  [ -z "$FR"   ] && FR=0

            if   [ "$I" = "0" ]; then TY="ap"
            elif [ "$I" = "5" ]; then TY="vxd"
            else                       TY="vap"
            fi

            if [ -f "${RV_PFX}_${I}_pending" ] && [ -f "${RV_PFX}_${I}_start" ]; then
                PENDING=true
                RVS=$(cat "${RV_PFX}_${I}_start" 2>/dev/null)
                if [ -n "$RVS" ]; then
                    REM=$(( ADV_TIMEOUT - ($(date +%s) - RVS) ))
                    [ "$REM" -lt 0 ] && REM=0
                    [ "$REM" -gt "$REMAINING" ] && REMAINING=$REM
                fi
            fi

            IFACES_J="${IFACES_J}${ISEP}{\"idx\":${I},\"type\":\"${TY}\",\"disabled\":${DIS},\"mimo\":${MIMO},\"txbf\":${TXBF},\"mc2u_disable\":${MC2U},\"tx_restrict\":${TXR},\"rx_restrict\":${RXR},\"pmf\":${PMF},\"sha256\":${SHA},\"rate_adaptive\":${RA},\"fixed_rate\":${FR}}"
            ISEP=","
            I=$((I + 1))
        done
        IFACES_J="${IFACES_J}]"

        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"band":"%s","wlan_if":"%s","shortgi":%s,"band_steering":%s,"regdomain_5":%s,"regdomain_24":%s,"unified_ssid":%s,"rssi_supported":%d,"rssi_prefer":%d,"rssi_nonprefer":%d,"ifaces":%s,"pending":%s,"remaining":%d}' \
            "$BAND" "$WLAN_IF" "$SGI" "$BSTEER" "$REG5" "$REG24" "$UNIFIED" "$RSSI_OK" "$RSSI_P" "$RSSI_O" "$IFACES_J" "$PENDING" "$REMAINING"
        exit 0
    fi

    # Default GET — redirect to the page
    printf "Status: 302 Found\r\n"
    printf "Location: /wlanadvanced.html\r\n\r\n"
    exit 0
fi

# ==========================================================
# POST
# ==========================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    BAND=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*band=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')
    case "$BAND" in 5) ;; *) BAND=24 ;; esac
    band_keys "$BAND"

    # --- action=save_regdomain: global wireless regulatory domain ------------
    # Vendor HW settings HW_WLAN0_REG_DOMAIN (5GHz, wlan0) and
    # HW_WLAN1_REG_DOMAIN (2.4GHz, wlan1). The vendor config_WLAN() passes the
    # value to the driver as `iwpriv <if> set_mib regdomain=N` every time WLAN
    # (re)starts, so this does what the vendor web UI does (mib set + commit
    # into the hardware-settings area) and then restarts the radio(s). The
    # driver builds its channel list and TX power limits when an interface
    # opens, so this cannot be applied live - but only a radio whose domain
    # actually changes is restarted (one wlanapply call per radio), and
    # re-applying the current domain restarts nothing. Both entries are written
    # together so the radios can never end up on different domains - this build
    # does not remap the HW entry per radio. The accepted range (1-15) mirrors
    # the vendor dropdown. A valid value cannot lock the admin out, so no
    # per-interface revert timer is needed.
    if echo "$QUERY_STRING" | busybox grep -q "action=save_regdomain"; then
        __CL="${CONTENT_LENGTH:-0}"; case "$__CL" in *[!0-9]*|"") __CL=0 ;; esac
        [ "$__CL" -gt 65536 ] && __CL=65536
        POST_DATA=$(busybox dd bs=1 count="$__CL" 2>/dev/null)

        FORM_REGDOM=$(pd_int regdomain 0)
        if [ "$FORM_REGDOM" -lt 1 ] || [ "$FORM_REGDOM" -gt 15 ]; then
            dbg "save_regdomain: rejected out-of-range value '$FORM_REGDOM'"
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid regulatory domain"
            exit 0
        fi

        # HW_WLAN0 = 5 GHz (wlan0), HW_WLAN1 = 2.4 GHz (wlan1). Read what each
        # radio is on BEFORE writing (mib get reports the running value - see
        # mib_get). An unreadable value counts as "changed", so it restarts.
        CUR_REG5=$(mib_get "HW_WLAN0_REG_DOMAIN")
        CUR_REG24=$(mib_get "HW_WLAN1_REG_DOMAIN")
        RESTART_BANDS=""
        [ "$CUR_REG5"  != "$FORM_REGDOM" ] && RESTART_BANDS="5"
        [ "$CUR_REG24" != "$FORM_REGDOM" ] && RESTART_BANDS="$RESTART_BANDS 24"

        mib set "HW_WLAN0_REG_DOMAIN" "$FORM_REGDOM"
        mib set "HW_WLAN1_REG_DOMAIN" "$FORM_REGDOM"
        mib commit
        dbg "save_regdomain: applied HW_WLAN0_REG_DOMAIN=HW_WLAN1_REG_DOMAIN=$FORM_REGDOM (was 5GHz='$CUR_REG5' 2.4GHz='$CUR_REG24')"

        if [ -z "$RESTART_BANDS" ]; then
            dbg "save_regdomain: both radios already on $FORM_REGDOM, nothing to restart"
            printf "Status: 200 OK\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "NOCHANGE"
            exit 0
        fi
        wl_restart_bands "$RESTART_BANDS"

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # --- action=save_bandsteer: global band steering (WIFI_STA_CONTROL) -------
    # This is a single radio-wide key (no band / no idx). The MODE cannot be
    # applied live: the driver pairs the two radios in stactrl_init() when an
    # interface opens (the sibling must already be open, enabled and unpaired)
    # and a plain `iwpriv set_mib stactrl_*` has no hook that re-runs it. So a
    # mode change restarts both radios - one wlanapply call per radio; whichever
    # comes up second completes the pairing, the same end state as the stock
    # both-radio restart - but only when the value actually changes. The RSSI
    # thresholds saved with it (MIB_STACTRL_PARAM_1/_6) ARE applied live and only
    # restart WiFi together with a mode change. The page uses its loading overlay
    # + poll-until-back around a mode change. A valid enum (0/1/3) cannot lock
    # the admin out, so no per-interface revert timer is needed here.
    if echo "$QUERY_STRING" | busybox grep -q "action=save_bandsteer"; then
        __CL="${CONTENT_LENGTH:-0}"; case "$__CL" in *[!0-9]*|"") __CL=0 ;; esac
        [ "$__CL" -gt 65536 ] && __CL=65536
        POST_DATA=$(busybox dd bs=1 count="$__CL" 2>/dev/null)

        FORM_BSTEER=$(pd_int band_steering 0)
        case "$FORM_BSTEER" in 0|1|3) ;; *) FORM_BSTEER=0 ;; esac

        # Guard: band steering may only be ENABLED (1/3) when Unified SSID is
        # on. Without one shared SSID across both radios there is nothing to
        # steer clients between, and the per-radio prefer-band values would be
        # meaningless. Disabling (0) is always allowed. The UI already locks the
        # control, but enforce it here too so a direct POST can't turn it on.
        if [ "$FORM_BSTEER" != "0" ] && [ "$(unified_enabled)" != "1" ]; then
            dbg "save_bandsteer: rejected enable=$FORM_BSTEER — Unified SSID is off"
            printf "Status: 409 Conflict\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Band steering requires Unified SSID. Enable Unified SSID on the WiFi (Basic) page first."
            exit 0
        fi

        # Optional RSSI thresholds, in dBm like Boa's page (see the Band-steering
        # RSSI section above). rssi_prefer / rssi_nonprefer arrive together; when
        # neither is present (an older cached copy of the page) the stored
        # thresholds are left alone. Everything is validated BEFORE anything is
        # written, so a bad value can never leave a half-applied change.
        RSSI_SET=0
        if pd_has rssi_prefer || pd_has rssi_nonprefer; then
            FORM_RSSI_P=$(pd_sint rssi_prefer)
            FORM_RSSI_O=$(pd_sint rssi_nonprefer)
            if [ -z "$FORM_RSSI_P" ] || [ -z "$FORM_RSSI_O" ] \
               || [ "$FORM_RSSI_P" -lt "$BS_RSSI_MIN_DBM" ] || [ "$FORM_RSSI_P" -gt 0 ] \
               || [ "$FORM_RSSI_O" -lt "$BS_RSSI_MIN_DBM" ] || [ "$FORM_RSSI_O" -gt 0 ]; then
                dbg "save_bandsteer: rejected RSSI prefer='$FORM_RSSI_P' nonprefer='$FORM_RSSI_O'"
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid RSSI. Enter a value from %s to 0 dBm for both thresholds." "$BS_RSSI_MIN_DBM"
                exit 0
            fi
            RAW_P=$((FORM_RSSI_P + 100))
            RAW_O=$((FORM_RSSI_O + 100))
            RSSI_SET=1
        fi

        # Raw compare with the running value (mib get - see mib_get), read
        # BEFORE writing: re-saving the current setting restarts nothing.
        CUR_BSTEER_RAW=$(mib_get "WIFI_STA_CONTROL")
        NEED_RESTART=1
        [ "$CUR_BSTEER_RAW" = "$FORM_BSTEER" ] && NEED_RESTART=0

        mib set "WIFI_STA_CONTROL" "$FORM_BSTEER"
        if [ "$RSSI_SET" = "1" ]; then
            mib set "$BS_RSSI_P_KEY" "$RAW_P"
            mib set "$BS_RSSI_O_KEY" "$RAW_O"
        fi
        mib commit
        dbg "save_bandsteer: applied WIFI_STA_CONTROL=$FORM_BSTEER (was '$CUR_BSTEER_RAW') rssi_set=$RSSI_SET${RAW_P:+ raw_prefer=$RAW_P raw_nonprefer=$RAW_O} restart=$NEED_RESTART"

        # Push the thresholds into the running driver now (both radios)...
        [ "$RSSI_SET" = "1" ] && bs_rssi_apply "$RAW_P" "$RAW_O"

        if [ "$NEED_RESTART" = "0" ]; then
            # Mode unchanged. With thresholds the live push above is the whole
            # apply; with none there was nothing to do at all.
            printf "Status: 200 OK\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            if [ "$RSSI_SET" = "1" ]; then printf "OK"; else printf "NOCHANGE"; fi
            exit 0
        fi

        # Restarting each radio re-runs stactrl_init(), which reads
        # stactrl_prefer_band from pmib and derives the correct asymmetric
        # runtime state (stactrl_prefer=1 on the preferred radio, 0 on the
        # non-preferred). libmib.so sets these MIBs correctly on start, so the
        # restart alone is sufficient for the mode. The thresholds are pushed
        # again afterwards in case the restart re-initialised the driver's mib
        # (idempotent when it didn't).
        wl_restart_bands "5 24"
        [ "$RSSI_SET" = "1" ] && bs_rssi_apply "$RAW_P" "$RAW_O"

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    IDX=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*idx=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')
    case "$IDX" in
        0|1|2|3|4|5) ;;
        *)
            dbg "WARN save_adv: invalid index '$IDX'"
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid interface index"
            exit 0
            ;;
    esac

    # Clamp body size: reject non-numeric and cap to 64KB to stop a
    # malicious Content-Length from forcing a huge/slow byte-by-byte read (DoS).
    __CL="${CONTENT_LENGTH:-0}"; case "$__CL" in *[!0-9]*|"") __CL=0 ;; esac
    [ "$__CL" -gt 65536 ] && __CL=65536
    POST_DATA=$(busybox dd bs=1 count="$__CL" 2>/dev/null)

    FORM_MIMO=$(pd_int mimo          0)
    FORM_TXBF=$(pd_int txbf          0)
    FORM_MC2U=$(pd_int mc2u_disable  1)
    FORM_TXR=$(pd_int  tx_restrict   0)
    FORM_RXR=$(pd_int  rx_restrict   0)
    FORM_PMF=$(pd_int  pmf           0)
    FORM_SHA=$(pd_int  sha256        0)
    FORM_RATEADAPT=$(pd_int rate_adaptive 1)
    FORM_FIXEDRATE=$(pd_int fixed_rate    0)
    FORM_LIVE=$(pd_int live               0)
    case "$FORM_LIVE" in 1) ;; *) FORM_LIVE=0 ;; esac

    # Validate binary flags / enums
    case "$FORM_MIMO" in 0|1)   ;; *) FORM_MIMO=0 ;; esac
    case "$FORM_TXBF" in 0|1)   ;; *) FORM_TXBF=0 ;; esac
    case "$FORM_MC2U" in 0|1)   ;; *) FORM_MC2U=1 ;; esac
    case "$FORM_PMF"  in 0|1|2) ;; *) FORM_PMF=0  ;; esac
    case "$FORM_SHA"  in 0|1)   ;; *) FORM_SHA=0  ;; esac
    case "$FORM_RATEADAPT" in 0|1) ;; *) FORM_RATEADAPT=1 ;; esac

    # TX Beamforming MIMO (txbf_mu) requires the base TX Beamforming (txbf)
    # to be enabled first — force MIMO off if TX Beamforming is being disabled
    [ "$FORM_TXBF" = "0" ] && FORM_MIMO=0

    # Fixed TX rate: only 5GHz has a validated 11ac MCS mapping right now.
    # Reject fixed mode (and any unrecognized fixedTxRate value) on any other
    # band rather than risk writing an unverified value — fall back to auto.
    if [ "$FORM_RATEADAPT" = "0" ]; then
        if [ "$BAND" = "5" ] && is_valid_fixedrate_5g "$FORM_FIXEDRATE"; then
            : # keep fixed mode with the validated value
        else
            dbg "save_adv idx=$IDX band=$BAND: rejected fixed_rate='$FORM_FIXEDRATE', forcing rate-adaptive=1"
            FORM_RATEADAPT=1
            FORM_FIXEDRATE=0
        fi
    else
        FORM_FIXEDRATE=0
    fi

    # Short Guard Interval is a radio-wide key with no per-idx variant, so it
    # only ever comes from — and is only ever applied via — the idx=0 (Main
    # AP) form.
    if [ "$IDX" = "0" ]; then
        FORM_SGI=$(pd_int shortgi 0)
        case "$FORM_SGI" in 0|1) ;; *) FORM_SGI=0 ;; esac
    fi

    CUR_DIS=$(get_disabled "$IDX")
    [ -z "$CUR_DIS" ] && CUR_DIS=1

    RP="${RV_PFX}_${IDX}"  # per-interface revert prefix

    # Clear any stale revert state for this interface only — leave other
    # interfaces' pending timers untouched.
    rm -f "${RP}_"*

    # Apply TX Beamforming / TX Beamforming MIMO in dependency order:
    #   Disable: set txbf_mu=0 (dependent first), then txbf=0 (base last)
    #   Enable:  set txbf=1 (base first), then txbf_mu=N (MIMO needs txbf on)
    if [ "$FORM_TXBF" = "0" ]; then
        mib set "${TBL_PFX}.${IDX}.txbf_mu" 0
        mib set "${TBL_PFX}.${IDX}.txbf"    0
    else
        mib set "${TBL_PFX}.${IDX}.txbf"     "$FORM_TXBF"
        mib set "${TBL_PFX}.${IDX}.txbf_mu"  "$FORM_MIMO"
    fi

    mib set "${TBL_PFX}.${IDX}.mc2u_disable"  "$FORM_MC2U"
    mib set "${TBL_PFX}.${IDX}.tx_restrict"   "$FORM_TXR"
    mib set "${TBL_PFX}.${IDX}.rx_restrict"   "$FORM_RXR"
    mib set "${TBL_PFX}.${IDX}.dotIEEE80211W" "$FORM_PMF"
    mib set "${TBL_PFX}.${IDX}.sha256"        "$FORM_SHA"
    mib set "${TBL_PFX}.${IDX}.rateAdaptiveEnabled" "$FORM_RATEADAPT"
    [ "$FORM_RATEADAPT" = "0" ] && mib set "${TBL_PFX}.${IDX}.fixedTxRate" "$FORM_FIXEDRATE"
    [ "$IDX" = "0" ] && mib set "$SGI_KEY" "$FORM_SGI"
    mib commit

    dbg "save_adv idx=$IDX band=$BAND: applied mimo=$FORM_MIMO txbf=$FORM_TXBF mc2u=$FORM_MC2U pmf=$FORM_PMF cur_dis=$CUR_DIS"

    # Skip restart and revert if this interface is already disabled — no radio change needed
    if [ "$CUR_DIS" = "1" ]; then
        dbg "save_adv idx=$IDX: interface disabled, skipping wlan_apply"
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # Interface is enabled — capture OLD live values (mib get reads the
    # running radio state, which hasn't been updated by wlan_apply yet)
    OLD_MIMO=$(get_mimo      "$IDX")
    OLD_TXBF=$(get_txbf      "$IDX")
    OLD_MC2U=$(get_mc2u      "$IDX")
    OLD_TXR=$(get_txr        "$IDX")
    OLD_RXR=$(get_rxr        "$IDX")
    OLD_PMF=$(get_pmf        "$IDX")
    OLD_SHA=$(get_sha256     "$IDX")
    OLD_RATEADAPT=$(get_rateadapt "$IDX")
    OLD_FIXEDRATE=$(get_fixedrate "$IDX")
    [ "$IDX" = "0" ] && OLD_SGI=$(get_sgi)

    # TX Beamforming (txbf/txbfer/txbfee) and TX Beamforming MIMO (txbf_mu)
    # can be poked live via iwpriv without dropping any client associations.
    # Every other field on this form still needs a full wlan_apply restart,
    # so only take the iwpriv fast path when nothing else changed.
    OTHER_FIELDS_UNCHANGED=1
    [ "$FORM_LIVE" != "1" ] && [ "$FORM_MC2U" != "$OLD_MC2U" ] && OTHER_FIELDS_UNCHANGED=0
    [ "$FORM_TXR"       != "$OLD_TXR" ]       && OTHER_FIELDS_UNCHANGED=0
    [ "$FORM_RXR"       != "$OLD_RXR" ]       && OTHER_FIELDS_UNCHANGED=0
    [ "$FORM_PMF"       != "$OLD_PMF" ]       && OTHER_FIELDS_UNCHANGED=0
    [ "$FORM_SHA"       != "$OLD_SHA" ]       && OTHER_FIELDS_UNCHANGED=0
    [ "$FORM_RATEADAPT" != "$OLD_RATEADAPT" ] && OTHER_FIELDS_UNCHANGED=0
    [ "$FORM_RATEADAPT" = "0" ] && [ "$FORM_FIXEDRATE" != "$OLD_FIXEDRATE" ] && OTHER_FIELDS_UNCHANGED=0
    [ "$FORM_LIVE" != "1" ] && [ "$IDX" = "0" ] && [ "$FORM_SGI" != "$OLD_SGI" ] && OTHER_FIELDS_UNCHANGED=0

    if [ "$OTHER_FIELDS_UNCHANGED" = "1" ]; then
        IWPRIV_IF=$(vif_name "$IDX")
        dbg "save_adv idx=$IDX: TX Beamforming-only change (txbf=$FORM_TXBF txbf_mu=$FORM_MIMO) on $IWPRIV_IF, using iwpriv set_mib instead of wlan_apply restart"
        iwpriv "$IWPRIV_IF" set_mib "txbf=$FORM_TXBF"
        iwpriv "$IWPRIV_IF" set_mib "txbfer=$FORM_TXBF"
        iwpriv "$IWPRIV_IF" set_mib "txbfee=$FORM_TXBF"
        iwpriv "$IWPRIV_IF" set_mib "txbf_mu=$FORM_MIMO"
        if [ "$FORM_LIVE" = "1" ]; then
            # mc2u_disable is read per packet; short GI is radio-wide and is
            # picked up by clients as they (re)associate (see wl_set_sgi).
            [ "$FORM_MC2U" != "$OLD_MC2U" ] && wl_set "$IWPRIV_IF" mc2u_disable "$FORM_MC2U"
            if [ "$IDX" = "0" ] && [ "$FORM_SGI" != "$OLD_SGI" ]; then
                wl_set_sgi "$FORM_SGI"
            fi
        fi
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # Some other field changed too — fall back to the full wlan_apply
    # restart path with revert-timer safety, same as before.
    printf '%s' "$OLD_MIMO"      > "${RP}_mimo"
    printf '%s' "$OLD_TXBF"      > "${RP}_txbf"
    printf '%s' "$OLD_MC2U"      > "${RP}_mc2u"
    printf '%s' "$OLD_TXR"       > "${RP}_txr"
    printf '%s' "$OLD_RXR"       > "${RP}_rxr"
    printf '%s' "$OLD_PMF"       > "${RP}_pmf"
    printf '%s' "$OLD_SHA"       > "${RP}_sha256"
    printf '%s' "$OLD_RATEADAPT" > "${RP}_rateadapt"
    printf '%s' "$OLD_FIXEDRATE" > "${RP}_fixedrate"
    [ "$IDX" = "0" ] && printf '%s' "$OLD_SGI" > "${RP}_sgi"
    touch "${RP}_pending"
    date +%s > "${RP}_start"

    # Background revert timer
    (
        sleep $ADV_TIMEOUT
        if [ -f "${RP}_pending" ]; then
            dbg "save_adv idx=$IDX: revert timeout reached, rolling back"
            RB_MIMO=$(cat "${RP}_mimo")
            RB_TXBF=$(cat "${RP}_txbf")
            RB_MC2U=$(cat "${RP}_mc2u")
            RB_TXR=$(cat "${RP}_txr")
            RB_RXR=$(cat "${RP}_rxr")
            RB_PMF=$(cat "${RP}_pmf")
            RB_SHA=$(cat "${RP}_sha256")
            RB_RATEADAPT=$(cat "${RP}_rateadapt")
            RB_FIXEDRATE=$(cat "${RP}_fixedrate")

            if [ "$RB_TXBF" = "0" ]; then
                mib set "${TBL_PFX}.${IDX}.txbf_mu" 0
                mib set "${TBL_PFX}.${IDX}.txbf"    0
            else
                mib set "${TBL_PFX}.${IDX}.txbf"     "$RB_TXBF"
                mib set "${TBL_PFX}.${IDX}.txbf_mu"  "$RB_MIMO"
            fi
            mib set "${TBL_PFX}.${IDX}.mc2u_disable"  "$RB_MC2U"
            mib set "${TBL_PFX}.${IDX}.tx_restrict"   "$RB_TXR"
            mib set "${TBL_PFX}.${IDX}.rx_restrict"   "$RB_RXR"
            mib set "${TBL_PFX}.${IDX}.dotIEEE80211W" "$RB_PMF"
            mib set "${TBL_PFX}.${IDX}.sha256"        "$RB_SHA"
            mib set "${TBL_PFX}.${IDX}.rateAdaptiveEnabled" "${RB_RATEADAPT:-1}"
            if [ "${RB_RATEADAPT:-1}" = "0" ]; then
                mib set "${TBL_PFX}.${IDX}.fixedTxRate" "${RB_FIXEDRATE:-0}"
            fi
            if [ "$IDX" = "0" ] && [ -f "${RP}_sgi" ]; then
                mib set "$SGI_KEY" "$(cat "${RP}_sgi")"
            fi
            mib commit
            if [ "$FORM_LIVE" = "1" ]; then
                wl_restart_scoped "$BAND" "$IDX"
            else
                wlan_apply restart
            fi
            if [ "$IDX" = "5" ]; then
                dbg "save_adv idx=5 revert: also restarting multi-ap agent service"
                sysconf multi_ap_agent_restart
            fi
            rm -f "${RP}_"*
        fi
    ) &

    if [ "$FORM_LIVE" = "1" ]; then
        dbg "save_adv idx=$IDX: live apply - restarting only band $BAND idx $IDX via wlanapply"
        wl_restart_scoped "$BAND" "$IDX"
    else
        dbg "save_adv idx=$IDX: launching wlan_apply restart"
        wlan_apply restart
    fi
    if [ "$IDX" = "5" ]; then
        dbg "save_adv idx=5: also restarting multi-ap agent service"
        sysconf multi_ap_agent_restart
    fi

    printf "Status: 200 OK\r\n"
    printf "Content-Type: text/plain\r\n\r\n"
    printf "OK"
    exit 0
fi

# Fallback
printf "Status: 302 Found\r\n"
printf "Location: /wlanadvanced.html\r\n\r\n"
