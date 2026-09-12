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

# wlanbasic.cgi — WiFi Basic Settings
# Manages 6 interfaces per radio: main AP (idx 0), VAPs (idx 1-4), VXD/repeater (idx 5)
# Band 24 → WLAN1_* / wlan1    Band 5 → WLAN_* / wlan0

SESSION_TIMEOUT=600

# ── Debug logging ──────────────────────────────────────────────────────────────
DBG_LOG="/tmp/wlanbasic_debug.log"
dbg() {
    printf '[%s] wlanbasic.cgi: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
        >> "$DBG_LOG" 2>/dev/null
}

# ── Auth ──────────────────────────────────────────────────────────────────────
BROWSER_SESSION=$(echo "$HTTP_COOKIE" \
    | busybox sed -n 's/.*session=\([^;]*\).*/\1/p' \
    | busybox tr -d '\r\n')
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

REVERT_TIMEOUT=90

# ── Band-specific key setup ───────────────────────────────────────────────────
band_keys() {
    case "$1" in
        5)
            TBL_PFX="WLAN_MBSSIB_TBL"
            CH_KEY="CHANNEL"
            CW_KEY="WLAN_CHANNELWIDTH"
            CB_KEY="WLAN_CONTROLBAND"
            TP_KEY="WLAN_RFPOWER_SCALE"
            AC_KEY="AUTO_CHANNEL"
            WLAN_IF="wlan0"
            VXD_IF="wlan0-vxd"
            RV_PFX="/tmp/wbasic5"
            SEC_PFX="/tmp/wsec5"
            REPEATER_EN_KEY="REPEATER_ENABLED1"
            REPEATER_SSID_KEY="REPEATER_SSID1"
            ;;
        *)
            TBL_PFX="WLAN1_MBSSIB_TBL"
            CH_KEY="WLAN1_CHANNEL"
            CW_KEY="WLAN1_CHANNELWIDTH"
            CB_KEY="WLAN1_CONTROLBAND"
            TP_KEY="WLAN1_RFPOWER_SCALE"
            AC_KEY="WLAN1_AUTO_CHANNEL"
            WLAN_IF="wlan1"
            VXD_IF="wlan1-vxd"
            RV_PFX="/tmp/wbasic24"
            SEC_PFX="/tmp/wsec24"
            REPEATER_EN_KEY="REPEATER_ENABLED2"
            REPEATER_SSID_KEY="REPEATER_SSID2"
            ;;
    esac
}

# ── Helpers ───────────────────────────────────────────────────────────────────
mib_field() {
    mib get "$1" 2>/dev/null \
        | busybox grep "=" \
        | busybox cut -d'=' -f2- \
        | busybox tr -d '\r\n' \
        | busybox sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

json_esc() {
    printf '%s' "$1" \
        | busybox sed 's/\\/\\\\/g; s/"/\\"/g'
}

get_ch_list() {
    AVAIL=$(busybox grep 'AVAIL_CH' /proc/${1}/mib_dfs 2>/dev/null \
        | busybox sed 's/.*AVAIL_CH:[[:space:]]*//' \
        | busybox tr '\n' ' ' | busybox tr -s ' ' \
        | busybox sed 's/^ *//;s/ *$//' \
        | busybox sed 's/ /,/g')
    if [ -z "$AVAIL" ]; then
        case "$1" in
            wlan0) printf '36,40,44,48,52,56,60,64,100,104,108,112,116,120,124,128,132,136,140,144,149,153,157,161,165' ;;
            *)     printf '1,2,3,4,5,6,7,8,9,10,11' ;;
        esac
    else
        printf '%s' "$AVAIL"
    fi
}

# ── VXD (idx 5) live connection + auth status ────────────────────────────────
# proc_field FILE LABEL  → value after "LABEL:" on the matching line, trimmed
proc_field() {
    [ -f "$1" ] || return
    busybox grep -m1 "^[[:space:]]*$2:" "$1" 2>/dev/null \
        | busybox sed "s/^[[:space:]]*$2:[[:space:]]*//" \
        | busybox tr -d '\r\n'
}

# auth_text CODE  → human-readable 4-way handshake status
auth_text() {
    case "$1" in
        0)  printf 'OK' ;;
        14) printf 'Wrong password (MIC failure)' ;;
        15) printf 'Handshake timeout (no reply from AP)' ;;
        '') printf 'Unknown' ;;
        *)  printf 'Failed (reason %s)' "$1" ;;
    esac
}

# emit_vxd_status_json VXD_IF TBL_PFX  → JSON connection/auth snapshot
emit_vxd_status_json() {
    _vif="$1"; _pfx="$2"
    _bssdesc="/proc/${_vif}/mib_bssdesc"
    _authf="/proc/${_vif}/mib_auth"

    _lock=$(mib_field "${_pfx}.5.prefer_bssid")
    [ -z "$_lock" ] && _lock="000000000000"

    _bssid=$(proc_field "$_bssdesc" "bssid")
    [ -z "$_bssid" ] && _bssid="000000000000"
    if [ "$_bssid" = "000000000000" ]; then
        _connected=false
    else
        _connected=true
    fi

    _ssid=$(proc_field "$_bssdesc" "ssid")
    _chan=$(proc_field "$_bssdesc" "channel");  [ -z "$_chan" ] && _chan=0
    _rssi=$(proc_field "$_bssdesc" "rssi");     [ -z "$_rssi" ] && _rssi=0
    _sq=$(proc_field   "$_bssdesc" "sq");       [ -z "$_sq"   ] && _sq=0

    _authst=$(proc_field "$_authf" "4-way status")
    _authfin=$(proc_field "$_authf" "4-way finished"); [ -z "$_authfin" ] && _authfin=0
    _authtxt=$(auth_text "$_authst")
    [ -z "$_authst" ] && _authst=-1

    printf '{"vxdIf":"%s","lockedBssid":"%s","connected":%s,"bssid":"%s","ssid":"%s","channel":%s,"rssi":%s,"sq":%s,"authStatus":%s,"authFinished":%s,"authText":"%s"}' \
        "$(json_esc "$_vif")" "$_lock" "$_connected" "$_bssid" "$(json_esc "$_ssid")" \
        "$_chan" "$_rssi" "$_sq" "$_authst" "$_authfin" "$(json_esc "$_authtxt")"
}

# POST field helpers ─────────────────────────────────────────────────────────
# Both helpers anchor on "&name=" (with a synthetic leading "&" prepended so
# the very first field matches too) rather than a bare "name=" substring
# search. Without that anchor, a field whose name is a substring of another
# field's name later in the same body — e.g. "ssid" inside "bssid" — makes
# the greedy sed pattern latch onto the LAST "ssid=" it finds, which is the
# one buried inside "bssid=", silently returning the bssid value (or empty)
# instead of the real ssid. This bit action=sta_connect for real: "Connect
# Manually" posts both ssid and bssid in the same body, so pd_str ssid was
# reading bssid's value the whole time — reported as SSID being rejected as
# empty even when typed in, and would have silently mis-set the SSID to the
# BSSID's hex string on any request where a BSSID pin was also filled in.
pd_str() {
    # URL-decode a string field from POST_DATA; $1 = field name
    RAW=$(echo "&$POST_DATA" \
        | busybox sed -n "s/.*&${1}=\\([^&]*\\).*/\\1/p" \
        | busybox tr -d '\r\n')
    busybox httpd -d "$RAW" 2>/dev/null \
        | busybox tr -d '\r\n'
}

pd_int() {
    # Extract an integer field; $1 = field name, $2 = default value
    V=$(echo "&$POST_DATA" \
        | busybox sed -n "s/.*&${1}=\\([^&]*\\).*/\\1/p" \
        | busybox tr -d '\r\n')
    case "$V" in ''|*[!0-9]*) V="${2:-0}" ;; esac
    printf '%s' "$V"
}

# ── Merged SSID (band-steering) helpers ──────────────────────────────
# Config persisted as flat-integer JSON: {"enabled":0,"iface24":0,"iface5":0}
MERGE_FILE="/lmepisowifi/www2/data/merged_ssid.json"

# tbl_pfx_for BAND  → prints the MBSSIB table prefix for that band
tbl_pfx_for() {
    case "$1" in 5) printf 'WLAN_MBSSIB_TBL' ;; *) printf 'WLAN1_MBSSIB_TBL' ;; esac
}

# merge_get KEY DEFAULT  → read an integer value from MERGE_FILE
merge_get() {
    if [ ! -f "$MERGE_FILE" ]; then printf '%s' "$2"; return; fi
    _mv=$(busybox sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\\(-\\{0,1\\}[0-9]\\{1,\\}\\).*/\\1/p" \
            "$MERGE_FILE" 2>/dev/null | busybox head -n1 | busybox tr -d '\r\n')
    [ -z "$_mv" ] && _mv="$2"
    printf '%s' "$_mv"
}

# resolve_partner BAND IDX
# If merge is enabled and (BAND,IDX) is one of the paired interfaces, sets:
#   PART_BAND PART_IDX PART_PFX PART_DIS   (otherwise all left empty)
resolve_partner() {
    PART_BAND=""; PART_IDX=""; PART_PFX=""; PART_DIS=""
    [ "$(merge_get enabled 0)" = "1" ] || return 0
    _i24=$(merge_get iface24 -1)
    _i5=$(merge_get iface5 -1)
    if [ "$1" = "24" ] && [ "$2" = "$_i24" ]; then
        PART_BAND=5;  PART_IDX="$_i5"
    elif [ "$1" = "5" ] && [ "$2" = "$_i5" ]; then
        PART_BAND=24; PART_IDX="$_i24"
    else
        return 0
    fi
    PART_PFX=$(tbl_pfx_for "$PART_BAND")
    PART_DIS=$(mib_field "${PART_PFX}.${PART_IDX}.wlanDisabled"); [ -z "$PART_DIS" ] && PART_DIS=1
}

# emit_ifaces_json TBL_PFX  → JSON array of {idx,type,ssid,disabled} for idx 0-5
emit_ifaces_json() {
    _pfx="$1"; _out="["; _sep=""; _j=0
    while [ "$_j" -le 5 ]; do
        _ss=$(mib_field "${_pfx}.${_j}.ssid")
        _di=$(mib_field "${_pfx}.${_j}.wlanDisabled"); [ -z "$_di" ] && _di=1
        if   [ "$_j" = "0" ]; then _ty="ap"
        elif [ "$_j" = "5" ]; then _ty="vxd"
        else                        _ty="vap"
        fi
        _se=$(json_esc "$_ss")
        _out="${_out}${_sep}{\"idx\":${_j},\"type\":\"${_ty}\",\"ssid\":\"${_se}\",\"disabled\":${_di}}"
        _sep=","
        _j=$((_j + 1))
    done
    printf '%s]' "$_out"
}

# ── Coin-slot NodeMCU Wi-Fi sync (multi-unit) ────────────────────────
# Every ESP8266 coin controller rides on one of our WLAN SSIDs as a station.
# If we rename/re-key that SSID without warning it, it is stranded offline.
# So before retuning an interface we hand every NodeMCU bound to it the new
# credentials over the still-live old link and wait for each one's ACK (see
# /setwifi in the firmware). Multiple units can share one interface (e.g.
# unit 1 and unit 2 both on wlan1) or ride different ones (e.g. unit 1 on
# wlan1, unit 2 on wlan1-vap0) — each unit's binding is its own row here.
#
# Registry: unit #1's connection details (IP/MAC/PORT/PSK/title/enabled)
# live in /tmp/coin_config.env, written by lmehspt.sh. Units #2+ live in
# NODEMCU_EXTRA_FILE (ID|TITLE|IP|MAC|PORT|PSK|ENABLED), maintained by
# hotspot.cgi's nodemcu_add/edit/del — read directly here, same as coin.sh
# does, so there's nothing that can go stale.
#
# Per-unit interface binding (which band+iface *this* unit rides, and
# whether sync is turned on for it) is separate from the registry above and
# lives in NODEMCU_IFACES_FILE, one row per unit: ID|ENABLED|BAND|IFACE.
# A unit with no row here just has sync off (default) for it.
NODEMCU_IFACES_FILE="/lmepisowifi/www2/data/nodemcu_ifaces.txt"
# Pre-multi-unit format (single implicit "unit #1" binding). Read once below
# to migrate an already-configured box's binding forward; never written to
# again after that.
NODEMCU_BIND_FILE_LEGACY="/lmepisowifi/www2/data/nodemcu_iface.json"
[ -f /tmp/coin_config.env ] && . /tmp/coin_config.env 2>/dev/null
NODEMCU_EXTRA_FILE="${NODEMCU_EXTRA_FILE:-/lmepisowifi/hotspot_data/nodemcus_extra.txt}"

# nm_migrate_legacy_bind  → one-time upgrade of the old single-NodeMCU
# binding into unit #1's row in NODEMCU_IFACES_FILE, so a box that already
# picked an interface via the old "Coin Slot (NodeMCU)" card keeps that
# setting. No-op once NODEMCU_IFACES_FILE exists (never re-migrates).
#
# REPAIR CASE: ota.sh's PRESERVE list didn't cover nodemcu_iface.json until
# the fix that added this comment, so every box that already made the
# single-switch -> multi-unit jump had it wiped by that OTA's wholesale www2
# swap before this function ever got to read it -- migration silently no-op'd
# and unit #1 came up with sync OFF regardless of what the admin had it set
# to. That on/off bit is gone for good (no on-box copy of it survived the
# swap), so it can't be recovered -- it can only be repaired. Per explicit
# instruction, every already-affected box is assumed to have had it ON, so
# if a NodeMCU is clearly configured (NODEMCU_IP set) but neither file
# exists, seed unit #1 as enabled=1 instead of leaving it unmigrated forever.
# NOTE: this can't distinguish that box from a brand-new multi-unit-only
# install that registered a NodeMCU but never touched the sync toggle -- such
# a box would also get defaulted to ON here. Not a concern for an existing
# fleet that's already past that point; worth revisiting before any public
# release where fresh installs are the common case.
nm_migrate_legacy_bind() {
    [ -f "$NODEMCU_IFACES_FILE" ] && return
    if [ -f "$NODEMCU_BIND_FILE_LEGACY" ]; then
        _le=$(busybox sed -n 's/.*"enabled"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9]\{1,\}\).*/\1/p' \
                "$NODEMCU_BIND_FILE_LEGACY" 2>/dev/null | busybox head -n1)
        _lb=$(busybox sed -n 's/.*"band"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9]\{1,\}\).*/\1/p' \
                "$NODEMCU_BIND_FILE_LEGACY" 2>/dev/null | busybox head -n1)
        _li=$(busybox sed -n 's/.*"iface"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9]\{1,\}\).*/\1/p' \
                "$NODEMCU_BIND_FILE_LEGACY" 2>/dev/null | busybox head -n1)
        [ -z "$_le" ] && _le=0; [ -z "$_lb" ] && _lb=24; [ -z "$_li" ] && _li=0
        dbg "nm_migrate_legacy_bind: migrated legacy binding -> unit #1 enabled=$_le band=$_lb iface=$_li"
    elif [ -n "${NODEMCU_IP:-}" ]; then
        _le=1; _lb=24; _li=0
        dbg "nm_migrate_legacy_bind: legacy bind file already lost (pre-fix OTA) -- repairing unit #1 to enabled=$_le band=$_lb iface=$_li"
    else
        return
    fi
    mkdir -p /lmepisowifi/www2/data
    printf '1|%s|%s|%s\n' "$_le" "$_lb" "$_li" > "$NODEMCU_IFACES_FILE"
}
nm_migrate_legacy_bind

# nm_unit_ids  → every configured NodeMCU unit id, space-separated: #1
# first (only if it has ever been set up), then every row in the extras file.
nm_unit_ids() {
    _uids=""
    [ -n "${NODEMCU_IP:-}" ] || [ -n "${NODEMCU_MAC:-}" ] && _uids="1"
    if [ -f "$NODEMCU_EXTRA_FILE" ]; then
        _uids="$_uids $(busybox awk -F'|' '$1 ~ /^[0-9]+$/ {printf "%s ", $1}' "$NODEMCU_EXTRA_FILE" 2>/dev/null)"
    fi
    printf '%s' "$_uids"
}

# nm_unit_conn ID  → sets NMC_IP/NMC_PORT/NMC_PSK/NMC_TITLE/NMC_REG_EN from
# the unit's registry entry (coin_config.env for #1, NODEMCU_EXTRA_FILE for
# #2+). NMC_REG_EN is the unit's own overall enabled state (separate from
# the sync-specific toggle in NODEMCU_IFACES_FILE).
nm_unit_conn() {
    if [ "$1" = "1" ]; then
        NMC_IP="${NODEMCU_IP:-}"; NMC_PORT="${NODEMCU_PORT:-8080}"; NMC_PSK="${COIN_PSK:-}"
        NMC_TITLE="${NODEMCU_1_TITLE:-Coin Slot}"; NMC_REG_EN="${NODEMCU_1_ENABLED:-1}"
        return
    fi
    NMC_IP=""; NMC_PORT="8080"; NMC_PSK=""; NMC_TITLE=""; NMC_REG_EN="0"
    [ -f "$NODEMCU_EXTRA_FILE" ] || return
    _row=$(busybox awk -F'|' -v id="$1" '$1==id{print;exit}' "$NODEMCU_EXTRA_FILE" 2>/dev/null)
    [ -z "$_row" ] && return
    NMC_TITLE=$(printf '%s' "$_row" | busybox awk -F'|' '{print $2}')
    NMC_IP=$(printf '%s' "$_row"    | busybox awk -F'|' '{print $3}')
    NMC_PORT=$(printf '%s' "$_row"  | busybox awk -F'|' '{print $5}')
    NMC_PSK=$(printf '%s' "$_row"   | busybox awk -F'|' '{print $6}')
    NMC_REG_EN=$(printf '%s' "$_row" | busybox awk -F'|' '{print $7}')
    [ -z "$NMC_PORT" ] && NMC_PORT=8080
    [ -z "$NMC_REG_EN" ] && NMC_REG_EN=1
}

# nm_unit_bind ID  → sets NMB_EN/NMB_BAND/NMB_IFACE, this unit's WiFi-sync
# interface binding. NMB_EN=0 (no row, or explicitly off) means "don't sync
# this unit on any interface".
nm_unit_bind() {
    NMB_EN=0; NMB_BAND=24; NMB_IFACE=0
    [ -f "$NODEMCU_IFACES_FILE" ] || return
    _row=$(busybox awk -F'|' -v id="$1" '$1==id{print;exit}' "$NODEMCU_IFACES_FILE" 2>/dev/null)
    [ -z "$_row" ] && return
    NMB_EN=$(printf '%s' "$_row"    | busybox awk -F'|' '{print $2}')
    NMB_BAND=$(printf '%s' "$_row"  | busybox awk -F'|' '{print $3}')
    NMB_IFACE=$(printf '%s' "$_row" | busybox awk -F'|' '{print $4}')
    [ -z "$NMB_EN" ] && NMB_EN=0
    [ -z "$NMB_BAND" ] && NMB_BAND=24
    [ -z "$NMB_IFACE" ] && NMB_IFACE=0
}

# nm_unit_active_here ID BAND IDX  → 0(true) if unit ID's sync is enabled,
# it's bound to BAND/IDX, and it currently has an IP to talk to
nm_unit_active_here() {
    nm_unit_bind "$1"
    [ "$NMB_EN" = "1" ] || return 1
    [ "$NMB_BAND" = "$2" ] && [ "$NMB_IFACE" = "$3" ] || return 1
    nm_unit_conn "$1"
    [ -n "$NMC_IP" ]
}

# urlenc STR  → percent-encode a query value (ASCII; NodeMCU .arg() decodes it)
urlenc() {
    _us="$1"; _uo=""; _ui=0; _ulen=${#_us}
    while [ "$_ui" -lt "$_ulen" ]; do
        _uc=$(printf '%s' "$_us" | busybox cut -c$((_ui + 1)))
        case "$_uc" in
            [a-zA-Z0-9.~_-]) _uo="${_uo}${_uc}" ;;
            *)               _uo="${_uo}$(printf '%%%02X' "'$_uc")" ;;
        esac
        _ui=$((_ui + 1))
    done
    printf '%s' "$_uo"
}

# ascii_to_hex STR  → lowercase 2-digit-hex-per-character MIB encoding
# (WEP ASCII key convention, e.g. "wep12" -> 7765703132). Used when
# wepKeyType=0 (ASCII key format) so the raw passphrase is stored the
# same way the vendor GUI/MIB expects, mirroring urlenc's char-by-char
# ordinal trick above.
ascii_to_hex() {
    _as="$1"; _ao=""; _ai=0; _alen=${#_as}
    while [ "$_ai" -lt "$_alen" ]; do
        _ac=$(printf '%s' "$_as" | busybox cut -c$((_ai + 1)))
        _ao="${_ao}$(printf '%02x' "'$_ac")"
        _ai=$((_ai + 1))
    done
    printf '%s' "$_ao"
}

# nm_push_unit ID NEW_SSID NEW_PASS  → 0 on that unit's NodeMCU ACK, 1 on
# any failure. Two-step signed handshake (matches the firmware's /reset
# flow), using unit ID's own IP/port/PSK from nm_unit_conn:
#   1. GET /nonce                              → fresh single-use nonce
#   2. GET /setwifi?ssid&pass&token            → token=md5(PSK:nonce:ssid:pass:setwifi)
nm_push_unit() {
    _pid="$1"; _ps="$2"; _pp="$3"
    nm_unit_conn "$_pid"
    _base="http://${NMC_IP}:${NMC_PORT}"
    # NOTE: use GNU wget (the applet busybox on this ONT does NOT ship), exactly
    # like coin.sh. `busybox wget` here failed instantly with an empty response
    # (applet-not-found -> stderr, swallowed by 2>/dev/null), which surfaced as
    # the misleading "NodeMCU did not acknowledge" abort even though it was online.
    _nresp=$(wget -q -T 5 -O - "${_base}/nonce" 2>/dev/null)
    _nonce=$(printf '%s' "$_nresp" | busybox grep -o '"nonce":"[^"]*"' \
                | busybox awk -F'"' '{print $4}' | busybox head -n1)
    if [ -z "$_nonce" ]; then
        dbg "nm_push_unit #$_pid: no nonce from NodeMCU at $_base (resp=$_nresp)"
        return 1
    fi
    _tok=$(printf '%s' "${NMC_PSK}:${_nonce}:${_ps}:${_pp}:setwifi" \
                | busybox md5sum | busybox awk '{print $1}')
    _q="ssid=$(urlenc "$_ps")&pass=$(urlenc "$_pp")&token=${_tok}"
    _resp=$(wget -q -T 8 -O - "${_base}/setwifi?${_q}" 2>/dev/null)
    if printf '%s' "$_resp" | busybox grep -q '"ok":true'; then
        dbg "nm_push_unit #$_pid: NodeMCU ACK (ssid=$_ps)"
        return 0
    fi
    dbg "nm_push_unit #$_pid: NodeMCU did NOT ACK (resp=$_resp)"
    return 1
}

# nm_effective_pass TBL_PFX IDX  → the Wi-Fi password the station needs
# (empty for an open network, else the interface's WPA-PSK)
# NOTE: encrypt=1 is WEP, which has no wpaPSK — this returns empty for it,
# same as open. The coin-slot NodeMCU is not currently handed a WEP key at
# all (nm_push_unit only ever carries a WPA passphrase), so a coin-slot SSID
# switched to WEP will look "open" to the sync logic and the NodeMCU will
# fail to associate. Not fixed here — flagging so it isn't mistaken for
# working WEP support on the coin-slot path.
nm_effective_pass() {
    _ee=$(mib_field "${1}.${2}.encrypt"); [ -z "$_ee" ] && _ee=0
    case "$_ee" in 0|1) printf '' ;; *) mib_field "${1}.${2}.wpaPSK" ;; esac
}

# nm_sync_iface BAND IDX NEW_SSID NEW_PASS
#   → 0 if no unit is bound here (nothing to do) OR every unit bound here ACKed
#   → 1 if at least one unit bound here failed to acknowledge (caller must abort)
# Sets NM_FAILED_UNITS to a space-separated list of ids that failed, for the
# error message. Every unit bound to this (band, idx) — there can be more
# than one — is notified independently with its own IP/PSK.
nm_sync_iface() {
    _sb="$1"; _si="$2"; _sssid="$3"; _spass="$4"
    NM_FAILED_UNITS=""
    _sfail=0
    for _suid in $(nm_unit_ids); do
        if nm_unit_active_here "$_suid" "$_sb" "$_si"; then
            dbg "nm_sync_iface: band=$_sb idx=$_si -> notifying NodeMCU #$_suid (ssid=$_sssid)"
            nm_push_unit "$_suid" "$_sssid" "$_spass" || { _sfail=1; NM_FAILED_UNITS="$NM_FAILED_UNITS $_suid"; }
        fi
    done
    [ "$_sfail" = "0" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# GET
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$REQUEST_METHOD" = "GET" ]; then

    BAND=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*band=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')
    case "$BAND" in 5) ;; *) BAND=24 ;; esac
    band_keys "$BAND"

    # ── action=confirm: cancel the revert timer ──────────────────────────────
    if echo "$QUERY_STRING" | busybox grep -q "action=confirm"; then
        rm -f "${RV_PFX}_"*
        rm -f "${SEC_PFX}_"*
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "confirmed"
        exit 0
    fi

    # ── action=merge_status: merged-SSID config + both bands' interfaces ──
    if echo "$QUERY_STRING" | busybox grep -q "action=merge_status"; then
        ME=$(merge_get  enabled 0)
        MI24=$(merge_get iface24 0)
        MI5=$(merge_get  iface5  0)
        IF24=$(emit_ifaces_json WLAN1_MBSSIB_TBL)
        IF5=$(emit_ifaces_json  WLAN_MBSSIB_TBL)
        dbg "GET merge_status: enabled=$ME iface24=$MI24 iface5=$MI5"
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"enabled":%s,"iface24":%s,"iface5":%s,"ifaces24":%s,"ifaces5":%s}' \
            "$ME" "$MI24" "$MI5" "$IF24" "$IF5"
        exit 0
    fi

    # ── action=nodemcu_status: every configured NodeMCU unit's Wi-Fi-sync
    #    binding (one entry per unit — multiple units can be listed) ──────
    if echo "$QUERY_STRING" | busybox grep -q "action=nodemcu_status"; then
        _out="["; _sep=""
        for _uid in $(nm_unit_ids); do
            nm_unit_conn "$_uid"
            nm_unit_bind "$_uid"
            _out="${_out}${_sep}{\"id\":${_uid},\"title\":\"$(json_esc "$NMC_TITLE")\",\"regEnabled\":${NMC_REG_EN:-0},\"enabled\":${NMB_EN},\"band\":${NMB_BAND},\"iface\":${NMB_IFACE},\"nodemcuIp\":\"$(json_esc "$NMC_IP")\"}"
            _sep=","
        done
        _out="${_out}]"
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"coinEnabled":%s,"units":%s}' "${COIN_ENABLED:-0}" "$_out"
        exit 0
    fi

    # ── action=vxd_status: VXD (idx 5) BSSID lock + live connection/auth ──
    if echo "$QUERY_STRING" | busybox grep -q "action=vxd_status"; then
        dbg "GET vxd_status: band=$BAND vxd_if=$VXD_IF"
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        emit_vxd_status_json "$VXD_IF" "$TBL_PFX"
        exit 0
    fi

    # ── action=vxd_status: VXD (idx 5) BSSID lock + live connection/auth ──
    if echo "$QUERY_STRING" | busybox grep -q "action=vxd_status"; then
        dbg "GET vxd_status: band=$BAND vxd_if=$VXD_IF"
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        emit_vxd_status_json "$VXD_IF" "$TBL_PFX"
        exit 0
    fi

    # ── action=vxd_status: VXD (idx 5) BSSID lock + live connection/auth ──
    if echo "$QUERY_STRING" | busybox grep -q "action=vxd_status"; then
        dbg "GET vxd_status: band=$BAND vxd_if=$VXD_IF"
        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        emit_vxd_status_json "$VXD_IF" "$TBL_PFX"
        exit 0
    fi

    # ── action=status: return full per-band JSON ─────────────────────────────
    if echo "$QUERY_STRING" | busybox grep -q "action=status"; then

        dbg "GET status start: band=$BAND wlan_if=$WLAN_IF tbl=$TBL_PFX"

        CH=$(mib_field "$CH_KEY")
        if [ -z "$CH" ]; then
            CH=6
            dbg "WARN: $CH_KEY empty, defaulting to $CH"
        fi

        CW=$(mib_field "$CW_KEY")
        if [ -z "$CW" ]; then
            CW=0
            dbg "WARN: $CW_KEY empty, defaulting to $CW"
        fi

        CB=$(mib_field "$CB_KEY")
        if [ -z "$CB" ]; then
            CB=0
            dbg "WARN: $CB_KEY empty, defaulting to $CB"
        fi

        TP=$(mib_field "$TP_KEY")
        if [ -z "$TP" ]; then
            TP=0
            dbg "WARN: $TP_KEY empty, defaulting to $TP"
        fi

        AC=$(mib_field "$AC_KEY")
        if [ -z "$AC" ]; then
            AC=0
            dbg "WARN: $AC_KEY empty, defaulting to $AC"
        fi

        CHLIST=$(get_ch_list "$WLAN_IF")
        if [ -z "$CHLIST" ]; then
            dbg "ERROR: get_ch_list returned empty for $WLAN_IF — channel list unavailable"
            CHLIST="1,6,11"
        else
            dbg "channel list for $WLAN_IF: $CHLIST"
        fi

        # Build ifaces JSON array (idx 0-5)
        IFACES_J="["
        ISEP=""
        I=0
        while [ "$I" -le 5 ]; do
            SSID=$(mib_field "${TBL_PFX}.${I}.ssid")
            DIS=$(mib_field  "${TBL_PFX}.${I}.wlanDisabled"); [ -z "$DIS"   ] && DIS=1
            WMOD=$(mib_field "${TBL_PFX}.${I}.wlanMode");    [ -z "$WMOD"  ] && WMOD=0
            WBD=$(mib_field  "${TBL_PFX}.${I}.wlanBand");    [ -z "$WBD"   ] && WBD=0
            ENC=$(mib_field  "${TBL_PFX}.${I}.encrypt");     [ -z "$ENC"   ] && ENC=0
            UC=$(mib_field   "${TBL_PFX}.${I}.unicastCipher");     [ -z "$UC"  ] && UC=0
            U2C=$(mib_field  "${TBL_PFX}.${I}.wpa2UnicastCipher"); [ -z "$U2C" ] && U2C=2
            PSK=$(mib_field  "${TBL_PFX}.${I}.wpaPSK")
            WEP=$(mib_field  "${TBL_PFX}.${I}.wep");          [ -z "$WEP"   ] && WEP=1
            WKT=$(mib_field  "${TBL_PFX}.${I}.wepKeyType");   [ -z "$WKT"   ] && WKT=0
            WDK=$(mib_field  "${TBL_PFX}.${I}.wepDefaultKey"); [ -z "$WDK"  ] && WDK=0
            AUTHTYPE=$(mib_field "${TBL_PFX}.${I}.authType"); [ -z "$AUTHTYPE" ] && AUTHTYPE=0

            # wep = key length (1=64-bit, 2=128-bit) selects which slot table
            # to read from; wepKeyType is key *format* (ASCII/Hex) and has no
            # bearing on which slot the key lives in.
            if [ "$WEP" = "2" ]; then
                WEPKEY=$(mib_field "${TBL_PFX}.${I}.wep128Key$((WDK + 1))")
            else
                WEPKEY=$(mib_field "${TBL_PFX}.${I}.wep64Key$((WDK + 1))")
            fi

            if [ -z "$SSID" ] && [ "$I" = "0" ]; then
                dbg "WARN: ${TBL_PFX}.0.ssid is empty (main AP has no SSID set)"
            fi

            SE=$(json_esc "$SSID")
            PE=$(json_esc "$PSK")
            if   [ "$I" = "0" ]; then TY="ap"
            elif [ "$I" = "5" ]; then TY="vxd"
            else                       TY="vap"
            fi
            IFACES_J="${IFACES_J}${ISEP}{\"idx\":${I},\"type\":\"${TY}\",\"ssid\":\"${SE}\",\"disabled\":${DIS},\"wlanMode\":${WMOD},\"wlanBand\":${WBD},\"encrypt\":${ENC},\"unicastCipher\":${UC},\"wpa2UnicastCipher\":${U2C},\"psk\":\"${PE}\",\"wep\":${WEP},\"wepKeyType\":${WKT},\"wepDefaultKey\":${WDK},\"wepKey\":\"${WEPKEY}\",\"authType\":${AUTHTYPE}}"
            ISEP=","
            I=$((I + 1))
        done
        IFACES_J="${IFACES_J}]"

        # Pending revert state
        PENDING=false
        REMAINING=0
        
        # 1. Check main AP basic settings revert timer
        if [ -f "${RV_PFX}_pending" ] && [ -f "${RV_PFX}_start" ]; then
            RVS=$(cat "${RV_PFX}_start" 2>/dev/null)
            if [ -n "$RVS" ]; then
                REMAINING=$(( REVERT_TIMEOUT - ($(date +%s) - RVS) ))
                [ "$REMAINING" -lt 0 ] && REMAINING=0
                PENDING=true
            fi
        fi

        # 2. Check security revert timers using exact file paths (fixes BusyBox wildcard bugs)
        i=0
        while [ "$i" -le 5 ]; do
            if [ -f "${SEC_PFX}_${i}_pending" ] && [ -f "${SEC_PFX}_${i}_start" ]; then
                PENDING=true
                RVS=$(cat "${SEC_PFX}_${i}_start" 2>/dev/null)
                if [ -n "$RVS" ]; then
                    REM=$(( REVERT_TIMEOUT - ($(date +%s) - RVS) ))
                    [ "$REM" -lt 0 ] && REM=0
                    [ "$REM" -gt "$REMAINING" ] && REMAINING=$REM
                fi
            fi
            i=$((i + 1))
        done

        dbg "GET status OK: band=$BAND ch=$CH cw=$CW pending=$PENDING"

        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"band":"%s","channel":%s,"autoChannel":%s,"channels":[%s],"channelwidth":%s,"controlband":%s,"txpower":%s,"ifaces":%s,"pending":%s,"remaining":%d}' \
            "$BAND" "$CH" "$AC" "$CHLIST" "$CW" "$CB" "$TP" "$IFACES_J" "$PENDING" "$REMAINING"
        exit 0
    fi

    printf "Status: 200 OK\r\n"
    printf "Content-Type: text/plain\r\n\r\n"
    printf "wlanbasic"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# POST
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$REQUEST_METHOD" = "POST" ]; then

    # Clamp body size: reject non-numeric and cap to 64KB to stop a
    # malicious Content-Length from forcing a huge/slow byte-by-byte read (DoS).
    __CL="${CONTENT_LENGTH:-0}"; case "$__CL" in *[!0-9]*|"") __CL=0 ;; esac
    [ "$__CL" -gt 65536 ] && __CL=65536
    POST_DATA=$(busybox dd bs=1 count="$__CL" 2>/dev/null)
    ACTION=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*action=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')
    BAND=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*band=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')
    case "$BAND" in 5) ;; *) BAND=24 ;; esac
    band_keys "$BAND"

    dbg "POST action=$ACTION band=$BAND"

    # ── action=save_merge: enable/disable merged SSID + choose the pair ──
    # Body: enabled=0|1  iface24=0-5  iface5=0-5
    # When enabling, the 2.4 GHz interface is the master: its SSID +
    # security/encryption are copied onto the chosen 5 GHz interface so the
    # two networks start out identical. From then on save_ap / save_iface /
    # save_security mirror any change across the pair automatically.
    if [ "$ACTION" = "save_merge" ]; then
        M_EN=$(pd_int  enabled 0)
        M_I24=$(pd_int iface24 0)
        M_I5=$(pd_int  iface5  0)
        case "$M_EN"  in 0|1)         ;; *) M_EN=0  ;; esac
        case "$M_I24" in 0|1|2|3|4|5) ;; *) M_I24=0 ;; esac
        case "$M_I5"  in 0|1|2|3|4|5) ;; *) M_I5=0  ;; esac

        if [ "$M_EN" = "1" ]; then
            # Both selected interfaces must currently be enabled
            D24=$(mib_field "WLAN1_MBSSIB_TBL.${M_I24}.wlanDisabled"); [ -z "$D24" ] && D24=1
            D5=$(mib_field  "WLAN_MBSSIB_TBL.${M_I5}.wlanDisabled");   [ -z "$D5"  ] && D5=1
            if [ "$D24" != "0" ] || [ "$D5" != "0" ]; then
                dbg "WARN save_merge: selected ifaces not both enabled (d24=$D24 d5=$D5)"
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Both the selected 2.4 GHz and 5 GHz interfaces must be enabled"
                exit 0
            fi
        fi

        if [ "$M_EN" = "1" ]; then
            # Compute the credentials the 5 GHz partner will inherit from 2.4
            S_SSID=$(mib_field "WLAN1_MBSSIB_TBL.${M_I24}.ssid")
            S_ENC=$(mib_field  "WLAN1_MBSSIB_TBL.${M_I24}.encrypt");            [ -z "$S_ENC" ] && S_ENC=0
            S_UC=$(mib_field   "WLAN1_MBSSIB_TBL.${M_I24}.unicastCipher");      [ -z "$S_UC" ]  && S_UC=0
            S_U2C=$(mib_field  "WLAN1_MBSSIB_TBL.${M_I24}.wpa2UnicastCipher");  [ -z "$S_U2C" ] && S_U2C=2
            S_PSK=$(mib_field  "WLAN1_MBSSIB_TBL.${M_I24}.wpaPSK")
            S_PMF=$(mib_field  "WLAN1_MBSSIB_TBL.${M_I24}.dotIEEE80211W");      [ -z "$S_PMF" ] && S_PMF=0

            # Coin-slot NodeMCU: enabling overwrites the 5 GHz interface's
            # name + security. If the NodeMCU rides on it, hand over the new
            # credentials and wait for ACK before persisting/applying. Abort
            # the whole merge if it doesn't answer.
            if [ "$S_ENC" = "0" ]; then NM_MPASS=""; else NM_MPASS="$S_PSK"; fi
            C5_SSID=$(mib_field "WLAN_MBSSIB_TBL.${M_I5}.ssid")
            C5_PASS=$(nm_effective_pass "WLAN_MBSSIB_TBL" "$M_I5")
            if [ "$S_SSID" != "$C5_SSID" ] || [ "$NM_MPASS" != "$C5_PASS" ]; then
                if ! nm_sync_iface 5 "$M_I5" "$S_SSID" "$NM_MPASS"; then
                    dbg "save_merge: NodeMCU did not ACK — aborting merge enable"
                    printf "Status: 502 Bad Gateway\r\n"
                    printf "Content-Type: text/plain\r\n\r\n"
                    printf "Coin-slot NodeMCU did not acknowledge the new WiFi credentials. Merge aborted so the coin slot is not stranded. Make sure the NodeMCU is online and try again."
                    exit 0
                fi
            fi
        fi

        # Persist merge config atomically
        mkdir -p /lmepisowifi/www2/data
        MF_TMP="${MERGE_FILE}.tmp.$$"
        printf '{"enabled":%s,"iface24":%s,"iface5":%s}\n' "$M_EN" "$M_I24" "$M_I5" > "$MF_TMP"
        busybox mv "$MF_TMP" "$MERGE_FILE"
        dbg "save_merge: saved enabled=$M_EN iface24=$M_I24 iface5=$M_I5"

        if [ "$M_EN" = "1" ]; then
            # Copy 2.4 GHz (master) SSID + security onto the 5 GHz partner
            mib set "WLAN_MBSSIB_TBL.${M_I5}.ssid"    "$S_SSID"
            mib set "WLAN_MBSSIB_TBL.${M_I5}.encrypt" "$S_ENC"
            if [ "$S_ENC" != "0" ]; then
                mib set "WLAN_MBSSIB_TBL.${M_I5}.wpaAuth"           2
                mib set "WLAN_MBSSIB_TBL.${M_I5}.enable1X"          0
                mib set "WLAN_MBSSIB_TBL.${M_I5}.unicastCipher"     "$S_UC"
                mib set "WLAN_MBSSIB_TBL.${M_I5}.wpa2UnicastCipher" "$S_U2C"
                mib set "WLAN_MBSSIB_TBL.${M_I5}.wpaPSK"            "$S_PSK"
                mib set "WLAN_MBSSIB_TBL.${M_I5}.wscPsk"            "$S_PSK"
                mib set "WLAN_MBSSIB_TBL.${M_I5}.dotIEEE80211W"     "$S_PMF"
            fi
            mib commit
            dbg "save_merge: mirrored 2.4 idx $M_I24 -> 5 idx $M_I5 (ssid=$S_SSID enc=$S_ENC)"
            wlan_apply restart
        fi

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # ── action=save_nodemcu_bind: which band+iface a given NodeMCU unit
    #    rides (id selects the unit; #1 is primary, #2+ are extras) ──────
    if [ "$ACTION" = "save_nodemcu_bind" ]; then
        NB_ID=$(pd_int    id      0)
        NB_EN=$(pd_int    enabled 0)
        NB_BAND=$(pd_int  band  24)
        NB_IFACE=$(pd_int iface 0)
        case "$NB_EN"    in 0|1)         ;; *) NB_EN=0     ;; esac
        case "$NB_BAND"  in 5)           ;; *) NB_BAND=24  ;; esac
        case "$NB_IFACE" in 0|1|2|3|4|5) ;; *) NB_IFACE=0  ;; esac
        if [ "$NB_ID" -lt 1 ] 2>/dev/null; then
            dbg "WARN save_nodemcu_bind: invalid/missing unit id"
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Invalid NodeMCU unit id"
            exit 0
        fi
        mkdir -p /lmepisowifi/www2/data
        touch "$NODEMCU_IFACES_FILE"
        NB_TMP="${NODEMCU_IFACES_FILE}.tmp.$$"
        busybox grep -v "^${NB_ID}|" "$NODEMCU_IFACES_FILE" > "$NB_TMP" 2>/dev/null
        printf '%s|%s|%s|%s\n' "$NB_ID" "$NB_EN" "$NB_BAND" "$NB_IFACE" >> "$NB_TMP"
        busybox mv "$NB_TMP" "$NODEMCU_IFACES_FILE"
        dbg "save_nodemcu_bind: id=$NB_ID enabled=$NB_EN band=$NB_BAND iface=$NB_IFACE"
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # ── action=save_ap: save main AP settings (idx 0) ───────────────────────
    if [ "$ACTION" = "save_ap" ]; then
        FORM_SSID=$(pd_str ssid)
        FORM_DIS=$(pd_int  disabled    0)
        FORM_MODE=$(pd_int wlanMode    0)
        FORM_WBD=$(pd_int  wlanBand    0)
        FORM_CH=$(pd_int   channel      0)
        FORM_AUTO_CH=$(pd_int autoChannel 0)
        FORM_CW=$(pd_int   channelwidth 0)
        FORM_CB=$(pd_int   controlband  0)
        FORM_TP=$(pd_int   txpower      0)

        # Validate numeric ranges
        case "$FORM_DIS"     in 0|1)       ;; *) FORM_DIS=0     ;; esac
        case "$FORM_MODE"    in 0|1)       ;; *) FORM_MODE=0    ;; esac
        case "$FORM_AUTO_CH" in 0|1)       ;; *) FORM_AUTO_CH=0 ;; esac
        case "$FORM_CW"      in 0|1|2|3)   ;; *) FORM_CW=0      ;; esac
        case "$FORM_CB"      in 0|1)       ;; *) FORM_CB=0      ;; esac
        case "$FORM_TP"      in 0|1|2|3|4) ;; *) FORM_TP=0      ;; esac

        if [ -z "$FORM_SSID" ]; then
            dbg "WARN save_ap: SSID is empty"
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "SSID is required"
            exit 0
        fi

        CUR_DIS=$(mib_field "${TBL_PFX}.0.wlanDisabled")

        # Capture rollback values BEFORE applying changes
        RV_SSID=$(mib_field  "${TBL_PFX}.0.ssid")
        RV_DIS="$CUR_DIS"
        RV_MODE=$(mib_field  "${TBL_PFX}.0.wlanMode")
        RV_WBD=$(mib_field   "${TBL_PFX}.0.wlanBand")
        RV_CH=$(mib_field    "$CH_KEY")
        RV_AC=$(mib_field    "$AC_KEY")
        RV_CW=$(mib_field    "$CW_KEY")
        RV_CB=$(mib_field    "$CB_KEY")
        RV_TP=$(mib_field    "$TP_KEY")

# Detect a "live-updatable-only" change: every field except SSID/
        # channel/autoChannel is identical to the current value. In that
        # case we can skip the full wlan_apply restart (which drops all
        # client associations) and poke the driver directly via iwpriv
        # instead.
        CORE_FIELDS_UNCHANGED=0
        if [ "$FORM_DIS" = "$RV_DIS" ] \
            && [ "$FORM_MODE" = "$RV_MODE" ] \
            && [ "$FORM_CW" = "$RV_CW" ] \
            && [ "$FORM_CB" = "$RV_CB" ] \
            && [ "$FORM_TP" = "$RV_TP" ]; then
            CORE_FIELDS_UNCHANGED=1
        fi

        # wlanBand doubles as the 802.11 mode/standard selector (numeric
        # target codes for b/g/n/ac/etc). 0 means "leave as-is" per the
        # mib-set guard below, so it's only a real change when non-zero
        # and different from the stored value.
        WBD_CHANGED=0
        if [ "$FORM_WBD" != "0" ] && [ "$FORM_WBD" != "$RV_WBD" ]; then
            WBD_CHANGED=1
        fi

        ONLY_CHANNEL_CHANGED=0
        ONLY_SSID_CHANGED=0
        CHANNEL_AND_SSID_CHANGED=0
        ONLY_AUTO_CHANGED=0
        AUTO_AND_SSID_CHANGED=0
        ONLY_WBD_CHANGED=0
        WBD_AND_SSID_CHANGED=0
        if [ "$CORE_FIELDS_UNCHANGED" = "1" ] && [ "$WBD_CHANGED" = "0" ]; then
            if [ "$FORM_AUTO_CH" = "1" ] && [ "$RV_AC" != "1" ]; then
                # Switching manual -> auto channel
                if [ "$FORM_SSID" = "$RV_SSID" ]; then
                    ONLY_AUTO_CHANGED=1
                else
                    AUTO_AND_SSID_CHANGED=1
                fi
            elif [ "$FORM_AUTO_CH" = "0" ] && [ "$RV_AC" = "0" ]; then
                # Manual channel both before and after
                if [ "$FORM_CH" != "$RV_CH" ] && [ "$FORM_SSID" != "$RV_SSID" ]; then
                    CHANNEL_AND_SSID_CHANGED=1
                elif [ "$FORM_CH" != "$RV_CH" ] && [ "$FORM_SSID" = "$RV_SSID" ]; then
                    ONLY_CHANNEL_CHANGED=1
                elif [ "$FORM_CH" = "$RV_CH" ] && [ "$FORM_SSID" != "$RV_SSID" ]; then
                    ONLY_SSID_CHANGED=1
                fi
            elif [ "$FORM_AUTO_CH" = "$RV_AC" ] && [ "$FORM_SSID" != "$RV_SSID" ]; then
                # Auto-channel state unchanged (still on or still off-with-
                # same-channel-irrelevant-here), only SSID differs
                ONLY_SSID_CHANGED=1
            fi
        elif [ "$CORE_FIELDS_UNCHANGED" = "1" ] && [ "$WBD_CHANGED" = "1" ] \
            && [ "$FORM_AUTO_CH" = "$RV_AC" ] && [ "$FORM_CH" = "$RV_CH" ]; then
            # 802.11 mode changed; channel/auto-channel state untouched.
            # If channel changed at the same time, fall through to a full
            # wlan_apply restart instead — that combo isn't fast-pathed.
            if [ "$FORM_SSID" = "$RV_SSID" ]; then
                ONLY_WBD_CHANGED=1
            else
                WBD_AND_SSID_CHANGED=1
            fi
        fi
        # ── Coin-slot NodeMCU: if the SSID of the interface the coin
        #    acceptor rides on is changing, hand it the new credentials and
        #    wait for its ACK *before* we retune the radio. If it does not
        #    acknowledge, abort now (nothing written yet) so we never strand
        #    the coin slot on a vanished SSID.
        if [ "$FORM_SSID" != "$RV_SSID" ]; then
            NM_PASS=$(nm_effective_pass "$TBL_PFX" 0)
            NM_FAIL=0
            nm_sync_iface "$BAND" 0 "$FORM_SSID" "$NM_PASS" || NM_FAIL=1
            # Cover the merged partner too — the mirror will rename it as well
            resolve_partner "$BAND" 0
            if [ -n "$PART_PFX" ]; then
                NM_PPASS=$(nm_effective_pass "$PART_PFX" "$PART_IDX")
                nm_sync_iface "$PART_BAND" "$PART_IDX" "$FORM_SSID" "$NM_PPASS" || NM_FAIL=1
            fi
            if [ "$NM_FAIL" = "1" ]; then
                dbg "save_ap: NodeMCU did not ACK — aborting SSID change"
                printf "Status: 502 Bad Gateway\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Coin-slot NodeMCU did not acknowledge the new WiFi credentials. SSID change aborted so the coin slot is not stranded. Make sure the NodeMCU is online and try again."
                exit 0
            fi
        fi

        # Apply new settings
        mib set "${TBL_PFX}.0.ssid"         "$FORM_SSID"
        mib set "${TBL_PFX}.0.wlanDisabled" "$FORM_DIS"
        mib set "${TBL_PFX}.0.wlanMode"     "$FORM_MODE"
        [ "$FORM_WBD" != "0" ] && mib set "${TBL_PFX}.0.wlanBand" "$FORM_WBD"
        mib set "$AC_KEY" "$FORM_AUTO_CH"
        # Store channel as 0 (auto) when auto-channel is enabled, otherwise
        # write the manually selected channel
        if [ "$FORM_AUTO_CH" = "1" ]; then
            mib set "$CH_KEY" 0
        elif [ "$FORM_CH" != "0" ]; then
            mib set "$CH_KEY" "$FORM_CH"
        fi
        mib set "$CW_KEY" "$FORM_CW"
        mib set "$CB_KEY" "$FORM_CB"
        mib set "$TP_KEY" "$FORM_TP"
        mib commit

        # ── Merged SSID: mirror the SSID onto the paired interface on the
        #    other band (band-specific settings like channel/mode are NOT
        #    mirrored). Forces a full wlan_apply restart so both radios
        #    reload with the new name.
        FORCE_RESTART=0
        RV_P_SSID=""; RV_P_PFX=""; RV_P_IDX=""
        resolve_partner "$BAND" 0
        if [ -n "$PART_PFX" ]; then
            RV_P_SSID=$(mib_field "${PART_PFX}.${PART_IDX}.ssid")
            RV_P_PFX="$PART_PFX"; RV_P_IDX="$PART_IDX"
            mib set "${PART_PFX}.${PART_IDX}.ssid" "$FORM_SSID"
            mib commit
            [ "$FORM_DIS" = "0" ] || [ "$PART_DIS" = "0" ] && FORCE_RESTART=1
            dbg "save_ap: merged mirror ssid -> band $PART_BAND idx $PART_IDX (force_restart=$FORCE_RESTART)"
        fi

        dbg "save_ap: applied ssid=$FORM_SSID dis=$FORM_DIS ch=$FORM_CH autoCh=$FORM_AUTO_CH cw=$FORM_CW"

        # Skip wlan_apply if WLAN was off and stays off (unless a merged
        # partner on the other band is live and needs the mirrored change)
        if [ "$FORM_DIS" = "1" ] && [ "${CUR_DIS:-1}" = "1" ] && [ "$FORCE_RESTART" != "1" ]; then
            dbg "save_ap: both disabled, skipping wlan_apply"
            printf "Status: 200 OK\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "OK"
            exit 0
        fi

        # Write revert files
        printf '%s' "$RV_SSID"  > "${RV_PFX}_ssid"
        printf '%s' "$RV_DIS"   > "${RV_PFX}_dis"
        printf '%s' "$RV_MODE"  > "${RV_PFX}_mode"
        printf '%s' "$RV_WBD"   > "${RV_PFX}_wband"
        printf '%s' "$RV_CH"    > "${RV_PFX}_ch"
        printf '%s' "$RV_AC"    > "${RV_PFX}_ac"
        printf '%s' "$RV_CW"    > "${RV_PFX}_cw"
        printf '%s' "$RV_CB"    > "${RV_PFX}_cb"
        printf '%s' "$RV_TP"    > "${RV_PFX}_tp"
        # Merged partner rollback (only present when a mirror happened)
        if [ -n "$RV_P_PFX" ]; then
            printf '%s' "$RV_P_SSID" > "${RV_PFX}_p_ssid"
            printf '%s' "$RV_P_PFX"  > "${RV_PFX}_p_pfx"
            printf '%s' "$RV_P_IDX"  > "${RV_PFX}_p_idx"
        fi
        touch "${RV_PFX}_pending"
        date +%s > "${RV_PFX}_start"

        # Background revert timer
        (
            sleep "$REVERT_TIMEOUT"
            if [ -f "${RV_PFX}_pending" ]; then
                dbg "save_ap: revert timeout reached, rolling back"
                _RB_SSID=$(cat "${RV_PFX}_ssid")
                # ── Coin-slot NodeMCU(s): the forward path already handed
                #    every unit bound here $FORM_SSID and they may have
                #    reassociated. Hand each of them (this interface, and
                #    the merged partner we mirrored onto) the pre-change
                #    credentials back *before* we revert the radio, so none
                #    are left associated to an SSID that's about to stop
                #    existing. Best-effort: an unreachable unit must not
                #    block the safety rollback.
                _RB_PASS=$(nm_effective_pass "$TBL_PFX" 0)
                nm_sync_iface "$BAND" 0 "$_RB_SSID" "$_RB_PASS" \
                    || dbg "save_ap: revert - NodeMCU(s)${NM_FAILED_UNITS} did not ACK rollback SSID (continuing anyway)"
                mib set "${TBL_PFX}.0.ssid"         "$_RB_SSID"
                mib set "${TBL_PFX}.0.wlanDisabled" "$(cat ${RV_PFX}_dis)"
                mib set "${TBL_PFX}.0.wlanMode"     "$(cat ${RV_PFX}_mode)"
                mib set "${TBL_PFX}.0.wlanBand"     "$(cat ${RV_PFX}_wband)"
                mib set "$CH_KEY"                    "$(cat ${RV_PFX}_ch)"
                mib set "$AC_KEY"                    "$(cat ${RV_PFX}_ac)"
                mib set "$CW_KEY"                    "$(cat ${RV_PFX}_cw)"
                mib set "$CB_KEY"                    "$(cat ${RV_PFX}_cb)"
                mib set "$TP_KEY"                    "$(cat ${RV_PFX}_tp)"
                # Roll back the mirrored SSID on the merged partner too
                if [ -f "${RV_PFX}_p_pfx" ]; then
                    _RB_P_PFX=$(cat "${RV_PFX}_p_pfx"); _RB_P_IDX=$(cat "${RV_PFX}_p_idx")
                    _RB_P_SSID=$(cat "${RV_PFX}_p_ssid")
                    _RB_P_BAND=$([ "$_RB_P_PFX" = "WLAN_MBSSIB_TBL" ] && echo 5 || echo 24)
                    _RB_P_PASS=$(nm_effective_pass "$_RB_P_PFX" "$_RB_P_IDX")
                    nm_sync_iface "$_RB_P_BAND" "$_RB_P_IDX" "$_RB_P_SSID" "$_RB_P_PASS" \
                        || dbg "save_ap: revert - NodeMCU(s)${NM_FAILED_UNITS} (partner iface) did not ACK rollback SSID (continuing anyway)"
                    mib set "${_RB_P_PFX}.${_RB_P_IDX}.ssid" "$_RB_P_SSID"
                fi
                mib commit
                wlan_apply restart
                rm -f "${RV_PFX}_"*
            fi
        ) &

        if [ "$FORCE_RESTART" = "1" ]; then
            # Merged SSID mirror touched the other radio — the targeted
            # iwpriv fast-paths only poke a single interface, so fall back
            # to a full wlan_apply restart to reload both bands.
            dbg "save_ap: merged mirror -> full wlan_apply restart"
            wlan_apply restart
        elif [ "$AUTO_AND_SSID_CHANGED" = "1" ]; then
            dbg "save_ap: auto-channel enabled + SSID change ($RV_SSID -> $FORM_SSID), using iwpriv set_mib instead of wlan_apply restart"
            iwpriv "$WLAN_IF" set_mib "channel=0"
            iwpriv "$WLAN_IF" autoch
            iwpriv "$WLAN_IF" set_mib "ssid=$FORM_SSID"
        elif [ "$ONLY_AUTO_CHANGED" = "1" ]; then
            dbg "save_ap: auto-channel enabled, using iwpriv set_mib instead of wlan_apply restart"
            iwpriv "$WLAN_IF" set_mib "channel=0"
            iwpriv "$WLAN_IF" autoch
        elif [ "$CHANNEL_AND_SSID_CHANGED" = "1" ]; then
            dbg "save_ap: channel+SSID change ($RV_CH -> $FORM_CH, $RV_SSID -> $FORM_SSID), using iwpriv set_mib + if bounce instead of wlan_apply restart"
            iwpriv "$WLAN_IF" set_mib "channel=$FORM_CH"
            ifconfig "$WLAN_IF" down
            ifconfig "$WLAN_IF" up
            iwpriv "$WLAN_IF" set_mib "ssid=$FORM_SSID"
        elif [ "$ONLY_CHANNEL_CHANGED" = "1" ]; then
            dbg "save_ap: channel-only change ($RV_CH -> $FORM_CH), using iwpriv set_mib + if bounce instead of wlan_apply restart"
            iwpriv "$WLAN_IF" set_mib "channel=$FORM_CH"
            ifconfig "$WLAN_IF" down
            ifconfig "$WLAN_IF" up
        elif [ "$WBD_AND_SSID_CHANGED" = "1" ]; then
            dbg "save_ap: 802.11 mode+SSID change ($RV_WBD -> $FORM_WBD, $RV_SSID -> $FORM_SSID), using iwpriv set_mib instead of wlan_apply restart"
            if [ "$WLAN_IF" = "wlan0" ]; then WBD_MAX=76; else WBD_MAX=11; fi
            WBD_DENY=$((WBD_MAX - FORM_WBD))
            iwpriv "$WLAN_IF" set_mib "band=$FORM_WBD"
            iwpriv "$WLAN_IF" set_mib "deny_legacy=$WBD_DENY"
            iwpriv "$WLAN_IF" set_mib "ssid=$FORM_SSID"
        elif [ "$ONLY_WBD_CHANGED" = "1" ]; then
            dbg "save_ap: 802.11 mode-only change ($RV_WBD -> $FORM_WBD), using iwpriv set_mib instead of wlan_apply restart"
            if [ "$WLAN_IF" = "wlan0" ]; then WBD_MAX=76; else WBD_MAX=11; fi
            WBD_DENY=$((WBD_MAX - FORM_WBD))
            iwpriv "$WLAN_IF" set_mib "band=$FORM_WBD"
            iwpriv "$WLAN_IF" set_mib "deny_legacy=$WBD_DENY"
        elif [ "$ONLY_SSID_CHANGED" = "1" ]; then
            dbg "save_ap: SSID-only change ($RV_SSID -> $FORM_SSID), using iwpriv set_mib instead of wlan_apply restart"
            iwpriv "$WLAN_IF" set_mib "ssid=$FORM_SSID"
        else
            dbg "save_ap: launching wlan_apply restart"
            wlan_apply restart
            if [ "$IDX" = "5" ]; then
                dbg "save_iface idx=5: also restarting multi-ap agent service"
                sysconf multi_ap_agent_restart
            fi
        fi
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # ── action=save_iface: save VAP (idx 1-4) or VXD (idx 5) ────────────────
    if [ "$ACTION" = "save_iface" ]; then
        IDX=$(echo "$QUERY_STRING" \
            | busybox sed -n 's/.*idx=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        case "$IDX" in
            1|2|3|4|5) ;;
            *)
                dbg "WARN save_iface: invalid index '$IDX'"
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid interface index"
                exit 0
                ;;
        esac

        FORM_SSID=$(pd_str ssid)
        FORM_DIS=$(pd_int  disabled 1)

        case "$FORM_DIS" in 0|1) ;; *) FORM_DIS=1 ;; esac

        # Safety: force disabled when main AP is in client/WDS mode
        MAIN_MODE=$(mib_field "${TBL_PFX}.0.wlanMode")
        if [ "${MAIN_MODE:-0}" = "1" ] && [ "$FORM_DIS" = "0" ]; then
            FORM_DIS=1
            dbg "save_iface idx=$IDX: forced disabled (main AP in client mode)"
        fi

        CUR_DIS=$(mib_field "${TBL_PFX}.${IDX}.wlanDisabled")
        CUR_SSID=$(mib_field "${TBL_PFX}.${IDX}.ssid")

        # ── Coin-slot NodeMCU: notify before renaming the SSID it rides on
        if [ -n "$FORM_SSID" ] && [ "$FORM_SSID" != "$CUR_SSID" ]; then
            NM_PASS=$(nm_effective_pass "$TBL_PFX" "$IDX")
            NM_FAIL=0
            nm_sync_iface "$BAND" "$IDX" "$FORM_SSID" "$NM_PASS" || NM_FAIL=1
            resolve_partner "$BAND" "$IDX"
            if [ -n "$PART_PFX" ]; then
                NM_PPASS=$(nm_effective_pass "$PART_PFX" "$PART_IDX")
                nm_sync_iface "$PART_BAND" "$PART_IDX" "$FORM_SSID" "$NM_PPASS" || NM_FAIL=1
            fi
            if [ "$NM_FAIL" = "1" ]; then
                dbg "save_iface idx=$IDX: NodeMCU did not ACK — aborting SSID change"
                printf "Status: 502 Bad Gateway\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Coin-slot NodeMCU did not acknowledge the new WiFi credentials. SSID change aborted so the coin slot is not stranded. Make sure the NodeMCU is online and try again."
                exit 0
            fi
        fi

        [ -n "$FORM_SSID" ] && mib set "${TBL_PFX}.${IDX}.ssid"         "$FORM_SSID"
        mib set "${TBL_PFX}.${IDX}.wlanDisabled" "$FORM_DIS"
        mib commit

        # ── Repeater MIB sync (VXD/idx=5 only): REPEATER_ENABLED1/SSID1 is
        #    the 5GHz repeater, REPEATER_ENABLED2/SSID2 is 2.4GHz. Enabled is
        #    the inverse of wlanDisabled; SSID mirrors only when changed.
        if [ "$IDX" = "5" ]; then
            REPEATER_EN=$((1 - FORM_DIS))
            mib set "$REPEATER_EN_KEY" "$REPEATER_EN"
            [ -n "$FORM_SSID" ] && mib set "$REPEATER_SSID_KEY" "$FORM_SSID"
            mib commit
            dbg "save_iface idx=5: set $REPEATER_EN_KEY=$REPEATER_EN ssid=${FORM_SSID:-(unchanged)} ($REPEATER_SSID_KEY)"
        fi

        # ── Merged SSID: mirror SSID + enable state onto the paired
        #    interface on the other band.
        FORCE_RESTART=0
        resolve_partner "$BAND" "$IDX"
        if [ -n "$PART_PFX" ]; then
            [ -n "$FORM_SSID" ] && mib set "${PART_PFX}.${PART_IDX}.ssid" "$FORM_SSID"
            mib set "${PART_PFX}.${PART_IDX}.wlanDisabled" "$FORM_DIS"
            mib commit
            [ "$FORM_DIS" = "0" ] || [ "$PART_DIS" = "0" ] && FORCE_RESTART=1
            dbg "save_iface idx=$IDX: merged mirror -> band $PART_BAND idx $PART_IDX dis=$FORM_DIS (force_restart=$FORCE_RESTART)"
        fi

        dbg "save_iface idx=$IDX: applied dis=$FORM_DIS ssid=${FORM_SSID:-(unchanged)}"

        # Skip wlan_apply if interface was off and stays off (unless a merged
        # partner on the other band is live and needs the mirrored change)
        if [ "$FORM_DIS" = "1" ] && [ "${CUR_DIS:-1}" = "1" ] && [ "$FORCE_RESTART" != "1" ]; then
            dbg "save_iface idx=$IDX: both disabled, skipping wlan_apply"
            printf "Status: 200 OK\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "OK"
            exit 0
        fi

        dbg "save_iface idx=$IDX: launching wlan_apply restart"
        wlan_apply restart
        if [ "$IDX" = "5" ]; then
            dbg "save_iface idx=5: also restarting multi-ap agent service"
            sysconf multi_ap_agent_restart
        fi
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # ── action=save_bssid_lock: pin/unpin VXD (idx 5) to one specific AP ──
    # Body: bssid=<12 hex chars>  (empty or all-zero clears the lock)
    # Writes dot11DesiredBssid (bssid2join) via WLAN_MBSSIB_TBL.5.prefer_bssid.
    # NOTE: the driver's own join-candidate loop has a compile-time carve-out
    # (SMART_REPEATER_MODE / SSFROM_REPEATER_VXD) that skips this BSSID check
    # entirely for scans it tags as VXD-repeater-originated, so treat this as
    # a preference the firmware is *supposed* to honor, not a hard guarantee —
    # verify empirically if a same-SSID neighbor AP exists nearby.
    if [ "$ACTION" = "save_bssid_lock" ]; then
        RAW_BSSID=$(pd_str bssid)
        BSSID=$(printf '%s' "$RAW_BSSID" | busybox tr 'A-Z' 'a-z' | busybox sed 's/[^0-9a-f]//g')

        if [ -z "$BSSID" ]; then
            BSSID="000000000000"
        elif [ ${#BSSID} -ne 12 ]; then
            dbg "WARN save_bssid_lock: invalid bssid '$RAW_BSSID' (len ${#BSSID})"
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "BSSID must be 12 hex characters (or empty to unlock)"
            exit 0
        fi

        mib set "${TBL_PFX}.5.prefer_bssid" "$BSSID"
        mib commit
        dbg "save_bssid_lock: band=$BAND ${TBL_PFX}.5.prefer_bssid=$BSSID"

        wlan_apply restart
        dbg "save_bssid_lock: also restarting multi-ap agent service"
        sysconf multi_ap_agent_restart

        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # ── action=save_security: save security settings for any interface ───────
    if [ "$ACTION" = "save_security" ]; then
        IDX=$(echo "$QUERY_STRING" \
            | busybox sed -n 's/.*idx=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        case "$IDX" in
            0|1|2|3|4|5) ;;
            *)
                dbg "WARN save_security: invalid index '$IDX'"
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Invalid interface index"
                exit 0
                ;;
        esac

        FORM_ENC=$(pd_int  encrypt           0)
        FORM_UC=$(pd_int   unicastCipher     0)
        FORM_U2C=$(pd_int  wpa2UnicastCipher 2)
        FORM_PSK=$(pd_str  psk)
        # WEP fields — mapping per vendor MIB spec:
        #   encrypt=1        WEP State (this IS the WEP toggle, not a forced-0 value)
        #   wep=1|2          Key Length: 1=64-bit, 2=128-bit
        #   wepKeyType=0|1   Key Format: 0=ASCII, 1=Hex
        #   wepDefaultKey    0-indexed default key slot (0=Key1 ... 3=Key4)
        #   authType=0|1|2   Authentication: 0=Open System, 1=Shared Key, 2=Auto
        FORM_WEP=$(pd_int  wep               1)
        FORM_WKT=$(pd_int  wepKeyType        0)
        FORM_WDK=$(pd_int  wepKeyIdx         0)
        FORM_AUTHTYPE=$(pd_int authType      0)
        FORM_WKEY_RAW=$(pd_str wepKey)

        # Validate
        case "$FORM_ENC" in 0|1|2|4|6|16|20) ;; *) FORM_ENC=0 ;; esac
        case "$FORM_UC"  in 0|1|2|3)         ;; *) FORM_UC=0  ;; esac
        case "$FORM_U2C" in 0|1|2|3)         ;; *) FORM_U2C=2 ;; esac
        case "$FORM_WEP" in 1|2)             ;; *) FORM_WEP=1 ;; esac
        case "$FORM_WKT" in 0|1)             ;; *) FORM_WKT=0 ;; esac
        case "$FORM_WDK" in 0|1|2|3)         ;; *) FORM_WDK=0 ;; esac
        case "$FORM_AUTHTYPE" in 0|1|2)      ;; *) FORM_AUTHTYPE=0 ;; esac

        # WPA3 (enc 16 or 20): WPA cipher must be disabled, WPA2/WPA3 cipher must be AES
        case "$FORM_ENC" in
            16|20) FORM_UC=0; FORM_U2C=2 ;;
        esac

        # WEP (encrypt=1): key length comes from `wep` (1=64-bit/2=128-bit),
        # key format from `wepKeyType` (0=ASCII/1=Hex). ASCII input must be
        # the exact byte length for the chosen key size (5 or 13 chars) and
        # gets hex-encoded (2 hex digits per ASCII byte) before storage; Hex
        # input is parsed directly (lowercased, non-hex chars stripped) and
        # must already be the exact hex-digit length (10 or 26).
        if [ "$FORM_ENC" = "1" ]; then
            if [ "$FORM_WEP" = "2" ]; then ASCII_LEN=13; HEX_LEN=26; else ASCII_LEN=5; HEX_LEN=10; fi

            if [ "$FORM_WKT" = "1" ]; then
                FORM_WKEY=$(printf '%s' "$FORM_WKEY_RAW" | busybox tr 'A-Z' 'a-z' | busybox sed 's/[^0-9a-f]//g')
                if [ ${#FORM_WKEY} -ne "$HEX_LEN" ]; then
                    dbg "WARN save_security idx=$IDX: WEP hex key length ${#FORM_WKEY} != $HEX_LEN (wep=$FORM_WEP)"
                    printf "Status: 400 Bad Request\r\n"
                    printf "Content-Type: text/plain\r\n\r\n"
                    if [ "$FORM_WEP" = "2" ]; then
                        printf "128-bit WEP hex key must be 26 hex characters (13 bytes)"
                    else
                        printf "64-bit WEP hex key must be 10 hex characters (5 bytes)"
                    fi
                    exit 0
                fi
            else
                if [ ${#FORM_WKEY_RAW} -ne "$ASCII_LEN" ]; then
                    dbg "WARN save_security idx=$IDX: WEP ascii key length ${#FORM_WKEY_RAW} != $ASCII_LEN (wep=$FORM_WEP)"
                    printf "Status: 400 Bad Request\r\n"
                    printf "Content-Type: text/plain\r\n\r\n"
                    if [ "$FORM_WEP" = "2" ]; then
                        printf "128-bit WEP ASCII key must be 13 characters"
                    else
                        printf "64-bit WEP ASCII key must be 5 characters"
                    fi
                    exit 0
                fi
                FORM_WKEY=$(ascii_to_hex "$FORM_WKEY_RAW")
            fi
        fi

        # PSK required for all non-open, non-WEP modes
        if [ "$FORM_ENC" != "0" ] && [ "$FORM_ENC" != "1" ]; then
            PSK_LEN=$(printf '%s' "$FORM_PSK" \
                | busybox wc -c | busybox tr -d ' ')
            if [ "$PSK_LEN" -lt 8 ] || [ "$PSK_LEN" -gt 63 ]; then
                dbg "WARN save_security idx=$IDX: PSK length $PSK_LEN invalid (8-63 required)"
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Password must be 8-63 characters"
                exit 0
            fi
        fi

        CUR_DIS=$(mib_field "${TBL_PFX}.${IDX}.wlanDisabled")
        SP="${SEC_PFX}_${IDX}"  # per-interface security rollback prefix

        # Capture rollback values
        SV_ENC=$(mib_field "${TBL_PFX}.${IDX}.encrypt")
        SV_UC=$(mib_field  "${TBL_PFX}.${IDX}.unicastCipher")
        SV_U2C=$(mib_field "${TBL_PFX}.${IDX}.wpa2UnicastCipher")
        SV_PSK=$(mib_field "${TBL_PFX}.${IDX}.wpaPSK")
        SV_PMF=$(mib_field "${TBL_PFX}.${IDX}.dotIEEE80211W")
        SV_WEP=$(mib_field "${TBL_PFX}.${IDX}.wep");           [ -z "$SV_WEP" ] && SV_WEP=1
        SV_WKT=$(mib_field "${TBL_PFX}.${IDX}.wepKeyType");    [ -z "$SV_WKT" ] && SV_WKT=0
        SV_WDK=$(mib_field "${TBL_PFX}.${IDX}.wepDefaultKey"); [ -z "$SV_WDK" ] && SV_WDK=0
        SV_AUTHTYPE=$(mib_field "${TBL_PFX}.${IDX}.authType"); [ -z "$SV_AUTHTYPE" ] && SV_AUTHTYPE=0
        # Only the exact slot this save is about to (possibly) overwrite needs
        # a snapshot — other WEP key slots are never touched by this action.
        # Slot is chosen by key LENGTH (wep), not key format (wepKeyType).
        if [ "$FORM_WEP" = "2" ]; then SV_WKEY_FIELD="wep128Key$((FORM_WDK + 1))"
        else                           SV_WKEY_FIELD="wep64Key$((FORM_WDK + 1))"
        fi
        SV_WKEY_VAL=$(mib_field "${TBL_PFX}.${IDX}.${SV_WKEY_FIELD}")

        # ── Coin-slot NodeMCU: if the passphrase/encryption of the SSID it
        #    rides on is changing, push the new credentials and wait for ACK
        #    *before* applying (nothing written yet, so we can abort cleanly).
        if [ "${SV_ENC:-0}" = "0" ]; then NM_OLD_PASS=""; else NM_OLD_PASS="$SV_PSK"; fi
        if [ "$FORM_ENC" = "0" ];       then NM_NEW_PASS=""; else NM_NEW_PASS="$FORM_PSK"; fi
        if [ "$NM_NEW_PASS" != "$NM_OLD_PASS" ]; then
            NM_CUR_SSID=$(mib_field "${TBL_PFX}.${IDX}.ssid")
            NM_FAIL=0
            nm_sync_iface "$BAND" "$IDX" "$NM_CUR_SSID" "$NM_NEW_PASS" || NM_FAIL=1
            resolve_partner "$BAND" "$IDX"
            if [ -n "$PART_PFX" ]; then
                NM_PP_SSID=$(mib_field "${PART_PFX}.${PART_IDX}.ssid")
                nm_sync_iface "$PART_BAND" "$PART_IDX" "$NM_PP_SSID" "$NM_NEW_PASS" || NM_FAIL=1
            fi
            if [ "$NM_FAIL" = "1" ]; then
                dbg "save_security idx=$IDX: NodeMCU did not ACK — aborting"
                printf "Status: 502 Bad Gateway\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Coin-slot NodeMCU did not acknowledge the new WiFi password. Security change aborted so the coin slot is not stranded. Make sure the NodeMCU is online and try again."
                exit 0
            fi
        fi

        # Apply security settings
        mib set "${TBL_PFX}.${IDX}.encrypt" "$FORM_ENC"
        if [ "$FORM_ENC" = "1" ]; then
            # WEP
            mib set "${TBL_PFX}.${IDX}.wep"           "$FORM_WEP"
            mib set "${TBL_PFX}.${IDX}.wepKeyType"    "$FORM_WKT"
            mib set "${TBL_PFX}.${IDX}.wepDefaultKey" "$FORM_WDK"
            mib set "${TBL_PFX}.${IDX}.authType"      "$FORM_AUTHTYPE"
            if [ "$FORM_WEP" = "2" ]; then
                mib set "${TBL_PFX}.${IDX}.wep128Key$((FORM_WDK + 1))" "$FORM_WKEY"
            else
                mib set "${TBL_PFX}.${IDX}.wep64Key$((FORM_WDK + 1))" "$FORM_WKEY"
            fi
        elif [ "$FORM_ENC" != "0" ]; then
            # WPA family
            mib set "${TBL_PFX}.${IDX}.wpaAuth"          2
            mib set "${TBL_PFX}.${IDX}.enable1X"         0
            mib set "${TBL_PFX}.${IDX}.unicastCipher"    "$FORM_UC"
            mib set "${TBL_PFX}.${IDX}.wpa2UnicastCipher" "$FORM_U2C"
            mib set "${TBL_PFX}.${IDX}.wpaPSK"           "$FORM_PSK"
            mib set "${TBL_PFX}.${IDX}.wscPsk"           "$FORM_PSK"
            # WPA3 and WPA3-Transition require PMF (dotIEEE80211W=1)
            case "$FORM_ENC" in
                16|20) mib set "${TBL_PFX}.${IDX}.dotIEEE80211W" 1 ;;
                *)     mib set "${TBL_PFX}.${IDX}.dotIEEE80211W" 0 ;;
            esac
        fi
        mib commit

        # ── Merged SSID: mirror the security/encryption settings onto the
        #    paired interface on the other band. Capture the partner's
        #    previous values first so the revert timer can restore them.
        FORCE_RESTART=0
        SVP_ENC=""; SVP_UC=""; SVP_U2C=""; SVP_PSK=""; SVP_PMF=""; SVP_PFX=""; SVP_IDX=""
        SVP_WEP=""; SVP_WKT=""; SVP_WDK=""; SVP_WKEY_FIELD=""; SVP_WKEY_VAL=""
        resolve_partner "$BAND" "$IDX"
        if [ -n "$PART_PFX" ]; then
            SVP_ENC=$(mib_field "${PART_PFX}.${PART_IDX}.encrypt")
            SVP_UC=$(mib_field  "${PART_PFX}.${PART_IDX}.unicastCipher")
            SVP_U2C=$(mib_field "${PART_PFX}.${PART_IDX}.wpa2UnicastCipher")
            SVP_PSK=$(mib_field "${PART_PFX}.${PART_IDX}.wpaPSK")
            SVP_PMF=$(mib_field "${PART_PFX}.${PART_IDX}.dotIEEE80211W")
            SVP_WEP=$(mib_field "${PART_PFX}.${PART_IDX}.wep");           [ -z "$SVP_WEP" ] && SVP_WEP=1
            SVP_WKT=$(mib_field "${PART_PFX}.${PART_IDX}.wepKeyType");    [ -z "$SVP_WKT" ] && SVP_WKT=0
            SVP_WDK=$(mib_field "${PART_PFX}.${PART_IDX}.wepDefaultKey"); [ -z "$SVP_WDK" ] && SVP_WDK=0
            SVP_AUTHTYPE=$(mib_field "${PART_PFX}.${PART_IDX}.authType"); [ -z "$SVP_AUTHTYPE" ] && SVP_AUTHTYPE=0
            if [ "$FORM_WEP" = "2" ]; then SVP_WKEY_FIELD="wep128Key$((FORM_WDK + 1))"
            else                           SVP_WKEY_FIELD="wep64Key$((FORM_WDK + 1))"
            fi
            SVP_WKEY_VAL=$(mib_field "${PART_PFX}.${PART_IDX}.${SVP_WKEY_FIELD}")
            SVP_PFX="$PART_PFX"; SVP_IDX="$PART_IDX"

            mib set "${PART_PFX}.${PART_IDX}.encrypt" "$FORM_ENC"
            if [ "$FORM_ENC" = "1" ]; then
                mib set "${PART_PFX}.${PART_IDX}.wep"           "$FORM_WEP"
                mib set "${PART_PFX}.${PART_IDX}.wepKeyType"    "$FORM_WKT"
                mib set "${PART_PFX}.${PART_IDX}.wepDefaultKey" "$FORM_WDK"
                mib set "${PART_PFX}.${PART_IDX}.authType"      "$FORM_AUTHTYPE"
                if [ "$FORM_WEP" = "2" ]; then
                    mib set "${PART_PFX}.${PART_IDX}.wep128Key$((FORM_WDK + 1))" "$FORM_WKEY"
                else
                    mib set "${PART_PFX}.${PART_IDX}.wep64Key$((FORM_WDK + 1))" "$FORM_WKEY"
                fi
            elif [ "$FORM_ENC" != "0" ]; then
                mib set "${PART_PFX}.${PART_IDX}.wpaAuth"           2
                mib set "${PART_PFX}.${PART_IDX}.enable1X"          0
                mib set "${PART_PFX}.${PART_IDX}.unicastCipher"     "$FORM_UC"
                mib set "${PART_PFX}.${PART_IDX}.wpa2UnicastCipher" "$FORM_U2C"
                mib set "${PART_PFX}.${PART_IDX}.wpaPSK"            "$FORM_PSK"
                mib set "${PART_PFX}.${PART_IDX}.wscPsk"            "$FORM_PSK"
                case "$FORM_ENC" in
                    16|20) mib set "${PART_PFX}.${PART_IDX}.dotIEEE80211W" 1 ;;
                    *)     mib set "${PART_PFX}.${PART_IDX}.dotIEEE80211W" 0 ;;
                esac
            fi
            mib commit
            [ "$PART_DIS" = "0" ] && FORCE_RESTART=1
            dbg "save_security idx=$IDX: merged mirror -> band $PART_BAND idx $PART_IDX (force_restart=$FORCE_RESTART)"
        fi

        dbg "save_security idx=$IDX: applied enc=$FORM_ENC uc=$FORM_UC u2c=$FORM_U2C wep=$FORM_WEP wkt=$FORM_WKT authType=$FORM_AUTHTYPE cur_dis=$CUR_DIS"

        # If interface is disabled no restart needed (unless a merged partner
        # on the other band is live and needs the mirrored change)
        if [ "${CUR_DIS:-1}" = "1" ] && [ "$FORCE_RESTART" != "1" ]; then
            dbg "save_security idx=$IDX: interface disabled, skipping wlan_apply"
            printf "Status: 200 OK\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "OK"
            exit 0
        fi

        # Write per-interface rollback files
        printf '%s' "$SV_ENC" > "${SP}_enc"
        printf '%s' "$SV_UC"  > "${SP}_uc"
        printf '%s' "$SV_U2C" > "${SP}_u2c"
        printf '%s' "$SV_PSK" > "${SP}_psk"
        printf '%s' "$SV_PMF" > "${SP}_pmf"
        printf '%s' "$SV_WEP" > "${SP}_wep"
        printf '%s' "$SV_WKT" > "${SP}_wkt"
        printf '%s' "$SV_WDK" > "${SP}_wdk"
        printf '%s' "$SV_AUTHTYPE" > "${SP}_authtype"
        printf '%s' "$SV_WKEY_FIELD" > "${SP}_wkey_field"
        printf '%s' "$SV_WKEY_VAL"   > "${SP}_wkey_val"
        # Merged partner security rollback (only present when a mirror happened)
        if [ -n "$SVP_PFX" ]; then
            printf '%s' "$SVP_ENC" > "${SP}_p_enc"
            printf '%s' "$SVP_UC"  > "${SP}_p_uc"
            printf '%s' "$SVP_U2C" > "${SP}_p_u2c"
            printf '%s' "$SVP_PSK" > "${SP}_p_psk"
            printf '%s' "$SVP_PMF" > "${SP}_p_pmf"
            printf '%s' "$SVP_PFX" > "${SP}_p_pfx"
            printf '%s' "$SVP_IDX" > "${SP}_p_idx"
            printf '%s' "$SVP_WEP" > "${SP}_p_wep"
            printf '%s' "$SVP_WKT" > "${SP}_p_wkt"
            printf '%s' "$SVP_WDK" > "${SP}_p_wdk"
            printf '%s' "$SVP_AUTHTYPE" > "${SP}_p_authtype"
            printf '%s' "$SVP_WKEY_FIELD" > "${SP}_p_wkey_field"
            printf '%s' "$SVP_WKEY_VAL"   > "${SP}_p_wkey_val"
        fi
        touch "${SP}_pending"
        date +%s > "${SP}_start"

        # Background revert timer
        (
            sleep "$REVERT_TIMEOUT"
            if [ -f "${SP}_pending" ]; then
                dbg "save_security idx=$IDX: revert timeout reached, rolling back"
                # ── Coin-slot NodeMCU(s): may have been handed the new
                #    passphrase on the forward path. Hand every unit bound
                #    here the pre-change passphrase back *before* the radio
                #    reverts, so none are left holding credentials the AP no
                #    longer accepts. Best-effort: an unreachable unit must
                #    not block the safety rollback. Reconstruct what
                #    nm_effective_pass would have returned for the rollback
                #    state directly from the saved fields rather than
                #    mib_field, since the mib hasn't been reverted yet.
                _RB_ENC=$(cat "${SP}_enc")
                case "$_RB_ENC" in 0|1) _RB_PASS="" ;; *) _RB_PASS=$(cat "${SP}_psk") ;; esac
                _RB_SSID=$(mib_field "${TBL_PFX}.${IDX}.ssid")
                nm_sync_iface "$BAND" "$IDX" "$_RB_SSID" "$_RB_PASS" \
                    || dbg "save_security idx=$IDX: revert - NodeMCU(s)${NM_FAILED_UNITS} did not ACK rollback credentials (continuing anyway)"
                mib set "${TBL_PFX}.${IDX}.encrypt"          "$(cat ${SP}_enc)"
                mib set "${TBL_PFX}.${IDX}.unicastCipher"    "$(cat ${SP}_uc)"
                mib set "${TBL_PFX}.${IDX}.wpa2UnicastCipher" "$(cat ${SP}_u2c)"
                mib set "${TBL_PFX}.${IDX}.wpaPSK"           "$(cat ${SP}_psk)"
                mib set "${TBL_PFX}.${IDX}.wscPsk"           "$(cat ${SP}_psk)"
                mib set "${TBL_PFX}.${IDX}.dotIEEE80211W"    "$(cat ${SP}_pmf)"
                mib set "${TBL_PFX}.${IDX}.wep"              "$(cat ${SP}_wep)"
                mib set "${TBL_PFX}.${IDX}.wepKeyType"       "$(cat ${SP}_wkt)"
                mib set "${TBL_PFX}.${IDX}.wepDefaultKey"    "$(cat ${SP}_wdk)"
                mib set "${TBL_PFX}.${IDX}.authType"         "$(cat ${SP}_authtype)"
                mib set "${TBL_PFX}.${IDX}.$(cat ${SP}_wkey_field)" "$(cat ${SP}_wkey_val)"
                # Roll back the mirrored security on the merged partner too
                if [ -f "${SP}_p_pfx" ]; then
                    _pp=$(cat ${SP}_p_pfx); _pi=$(cat ${SP}_p_idx)
                    _p_band=$([ "$_pp" = "WLAN_MBSSIB_TBL" ] && echo 5 || echo 24)
                    _RB_P_ENC=$(cat "${SP}_p_enc")
                    case "$_RB_P_ENC" in 0|1) _RB_P_PASS="" ;; *) _RB_P_PASS=$(cat "${SP}_p_psk") ;; esac
                    _RB_P_SSID=$(mib_field "${_pp}.${_pi}.ssid")
                    nm_sync_iface "$_p_band" "$_pi" "$_RB_P_SSID" "$_RB_P_PASS" \
                        || dbg "save_security idx=$IDX: revert - NodeMCU(s)${NM_FAILED_UNITS} (partner iface) did not ACK rollback credentials (continuing anyway)"
                    mib set "${_pp}.${_pi}.encrypt"          "$(cat ${SP}_p_enc)"
                    mib set "${_pp}.${_pi}.unicastCipher"    "$(cat ${SP}_p_uc)"
                    mib set "${_pp}.${_pi}.wpa2UnicastCipher" "$(cat ${SP}_p_u2c)"
                    mib set "${_pp}.${_pi}.wpaPSK"           "$(cat ${SP}_p_psk)"
                    mib set "${_pp}.${_pi}.wscPsk"           "$(cat ${SP}_p_psk)"
                    mib set "${_pp}.${_pi}.dotIEEE80211W"    "$(cat ${SP}_p_pmf)"
                    mib set "${_pp}.${_pi}.wep"              "$(cat ${SP}_p_wep)"
                    mib set "${_pp}.${_pi}.wepKeyType"       "$(cat ${SP}_p_wkt)"
                    mib set "${_pp}.${_pi}.wepDefaultKey"    "$(cat ${SP}_p_wdk)"
                    mib set "${_pp}.${_pi}.authType"         "$(cat ${SP}_p_authtype)"
                    mib set "${_pp}.${_pi}.$(cat ${SP}_p_wkey_field)" "$(cat ${SP}_p_wkey_val)"
                fi
                mib commit
                wlan_apply restart
                rm -f "${SP}_"*
            fi
        ) &

        dbg "save_security idx=$IDX: launching wlan_apply restart"
        wlan_apply restart
        if [ "$IDX" = "5" ]; then
            dbg "save_iface idx=5: also restarting multi-ap agent service"
            sysconf multi_ap_agent_restart
        fi
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

    # ── action=sta_connect: point client / VXD interface at a network ────────
    # Used by both the Site Survey "Connect" button (scanned AP) and "Connect
    # Manually" (hand-typed SSID/security, no scan result required). Writes
    # the target network's SSID + security onto the band's client-capable
    # interface, optionally pins prefer_bssid (see save_bssid_lock), then
    # applies.
    if [ "$ACTION" = "sta_connect" ]; then
        FORM_SSID=$(pd_str ssid)
        FORM_ENC=$(pd_int  encrypt           0)
        FORM_UC=$(pd_int   unicastCipher     0)
        FORM_U2C=$(pd_int  wpa2UnicastCipher 2)
        FORM_PSK=$(pd_str  psk)
        FORM_BSSID_RAW=$(pd_str bssid)
        FORM_BSSID=$(printf '%s' "$FORM_BSSID_RAW" | busybox tr 'A-Z' 'a-z' | busybox sed 's/[^0-9a-f]//g')
        FORM_WEP=$(pd_int  wep               1)
        FORM_WKT=$(pd_int  wepKeyType        0)
        FORM_WDK=$(pd_int  wepKeyIdx         0)
        FORM_AUTHTYPE=$(pd_int authType      0)
        FORM_WKEY_RAW=$(pd_str wepKey)

        # Validate encryption + cipher codes (same set as save_security)
        case "$FORM_ENC" in 0|1|2|4|6|16|20) ;; *) FORM_ENC=0 ;; esac
        case "$FORM_UC"  in 0|1|2|3)         ;; *) FORM_UC=0  ;; esac
        case "$FORM_U2C" in 0|1|2|3)         ;; *) FORM_U2C=2 ;; esac
        case "$FORM_WEP" in 1|2)             ;; *) FORM_WEP=1 ;; esac
        case "$FORM_WKT" in 0|1)             ;; *) FORM_WKT=0 ;; esac
        case "$FORM_WDK" in 0|1|2|3)         ;; *) FORM_WDK=0 ;; esac
        case "$FORM_AUTHTYPE" in 0|1|2)      ;; *) FORM_AUTHTYPE=0 ;; esac
        # WPA3 (16/20) forces AES-only cipher + PMF
        case "$FORM_ENC" in 16|20) FORM_UC=0; FORM_U2C=2 ;; esac

        if [ -z "$FORM_SSID" ]; then
            dbg "WARN sta_connect: SSID empty"
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "Target SSID is required"
            exit 0
        fi

        # Optional BSSID pin: empty clears any existing lock, else must be a
        # full 12 hex-char MAC (same rule as action=save_bssid_lock)
        if [ -z "$FORM_BSSID" ]; then
            FORM_BSSID="000000000000"
        elif [ ${#FORM_BSSID} -ne 12 ]; then
            dbg "WARN sta_connect: invalid bssid '$FORM_BSSID_RAW' (len ${#FORM_BSSID})"
            printf "Status: 400 Bad Request\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "BSSID must be 12 hex characters (or empty)"
            exit 0
        fi

        # WEP (encrypt=1): see save_security for full field provenance. Key
        # length from `wep`, key format from `wepKeyType`; ASCII input is
        # hex-encoded before storage, Hex input is parsed directly.
        if [ "$FORM_ENC" = "1" ]; then
            if [ "$FORM_WEP" = "2" ]; then ASCII_LEN=13; HEX_LEN=26; else ASCII_LEN=5; HEX_LEN=10; fi

            if [ "$FORM_WKT" = "1" ]; then
                FORM_WKEY=$(printf '%s' "$FORM_WKEY_RAW" | busybox tr 'A-Z' 'a-z' | busybox sed 's/[^0-9a-f]//g')
                if [ ${#FORM_WKEY} -ne "$HEX_LEN" ]; then
                    dbg "WARN sta_connect: WEP hex key length ${#FORM_WKEY} != $HEX_LEN (wep=$FORM_WEP)"
                    printf "Status: 400 Bad Request\r\n"
                    printf "Content-Type: text/plain\r\n\r\n"
                    if [ "$FORM_WEP" = "2" ]; then
                        printf "128-bit WEP hex key must be 26 hex characters (13 bytes)"
                    else
                        printf "64-bit WEP hex key must be 10 hex characters (5 bytes)"
                    fi
                    exit 0
                fi
            else
                if [ ${#FORM_WKEY_RAW} -ne "$ASCII_LEN" ]; then
                    dbg "WARN sta_connect: WEP ascii key length ${#FORM_WKEY_RAW} != $ASCII_LEN (wep=$FORM_WEP)"
                    printf "Status: 400 Bad Request\r\n"
                    printf "Content-Type: text/plain\r\n\r\n"
                    if [ "$FORM_WEP" = "2" ]; then
                        printf "128-bit WEP ASCII key must be 13 characters"
                    else
                        printf "64-bit WEP ASCII key must be 5 characters"
                    fi
                    exit 0
                fi
                FORM_WKEY=$(ascii_to_hex "$FORM_WKEY_RAW")
            fi
        fi

        # Secured (non-open, non-WEP) networks require a valid 8-63 char PSK
        if [ "$FORM_ENC" != "0" ] && [ "$FORM_ENC" != "1" ]; then
            PSK_LEN=$(printf '%s' "$FORM_PSK" | busybox wc -c | busybox tr -d ' ')
            if [ "$PSK_LEN" -lt 8 ] || [ "$PSK_LEN" -gt 63 ]; then
                dbg "WARN sta_connect: PSK length $PSK_LEN invalid (8-63 required)"
                printf "Status: 400 Bad Request\r\n"
                printf "Content-Type: text/plain\r\n\r\n"
                printf "Password must be 8-63 characters"
                exit 0
            fi
        fi

        # Pick the client-capable interface for this band:
        #   VXD (idx 5) when enabled, else the main AP (idx 0) if it is in
        #   client mode (wlanMode=1). VXD wins because it is the dedicated
        #   repeater/client interface.
        VXD_DIS=$(mib_field "${TBL_PFX}.5.wlanDisabled")
        AP_MODE=$(mib_field "${TBL_PFX}.0.wlanMode")
        AP_DIS=$(mib_field  "${TBL_PFX}.0.wlanDisabled")
        if [ "${VXD_DIS:-1}" != "1" ]; then
            IDX=5
        elif [ "${AP_MODE:-0}" = "1" ] && [ "${AP_DIS:-1}" != "1" ]; then
            IDX=0
        else
            dbg "sta_connect: no client-mode interface available on band $BAND"
            printf "Status: 409 Conflict\r\n"
            printf "Content-Type: text/plain\r\n\r\n"
            printf "No client or VXD interface is enabled on this band"
            exit 0
        fi

        dbg "sta_connect: band=$BAND idx=$IDX ssid=$FORM_SSID enc=$FORM_ENC wep=$FORM_WEP wkt=$FORM_WKT authType=$FORM_AUTHTYPE bssid=$FORM_BSSID"

        # Point the interface at the target network
        mib set "${TBL_PFX}.${IDX}.ssid"          "$FORM_SSID"
        mib set "${TBL_PFX}.${IDX}.encrypt"       "$FORM_ENC"
        mib set "${TBL_PFX}.${IDX}.prefer_bssid"  "$FORM_BSSID"
        if [ "$FORM_ENC" = "1" ]; then
            mib set "${TBL_PFX}.${IDX}.wep"           "$FORM_WEP"
            mib set "${TBL_PFX}.${IDX}.wepKeyType"    "$FORM_WKT"
            mib set "${TBL_PFX}.${IDX}.wepDefaultKey" "$FORM_WDK"
            mib set "${TBL_PFX}.${IDX}.authType"      "$FORM_AUTHTYPE"
            if [ "$FORM_WEP" = "2" ]; then
                mib set "${TBL_PFX}.${IDX}.wep128Key$((FORM_WDK + 1))" "$FORM_WKEY"
            else
                mib set "${TBL_PFX}.${IDX}.wep64Key$((FORM_WDK + 1))" "$FORM_WKEY"
            fi
            mib set "${TBL_PFX}.${IDX}.wpaPSK" ""
            mib set "${TBL_PFX}.${IDX}.wscPsk" ""
            mib set "${TBL_PFX}.${IDX}.dotIEEE80211W" 0
        elif [ "$FORM_ENC" != "0" ]; then
            mib set "${TBL_PFX}.${IDX}.wpaAuth"           2
            mib set "${TBL_PFX}.${IDX}.enable1X"          0
            mib set "${TBL_PFX}.${IDX}.unicastCipher"     "$FORM_UC"
            mib set "${TBL_PFX}.${IDX}.wpa2UnicastCipher" "$FORM_U2C"
            mib set "${TBL_PFX}.${IDX}.wpaPSK"            "$FORM_PSK"
            mib set "${TBL_PFX}.${IDX}.wscPsk"            "$FORM_PSK"
            case "$FORM_ENC" in
                16|20) mib set "${TBL_PFX}.${IDX}.dotIEEE80211W" 1 ;;
                *)     mib set "${TBL_PFX}.${IDX}.dotIEEE80211W" 0 ;;
            esac
        else
            mib set "${TBL_PFX}.${IDX}.wpaPSK" ""
            mib set "${TBL_PFX}.${IDX}.wscPsk" ""
            mib set "${TBL_PFX}.${IDX}.dotIEEE80211W" 0
        fi
        mib commit

        dbg "sta_connect: launching wlan_apply restart"
        wlan_apply restart
        if [ "$IDX" = "5" ]; then
            dbg "sta_connect idx=5: also restarting multi-ap agent service"
            sysconf multi_ap_agent_restart
        fi
        printf "Status: 200 OK\r\n"
        printf "Content-Type: text/plain\r\n\r\n"
        printf "OK"
        exit 0
    fi

fi

printf "Status: 302 Found\r\n"
printf "Location: /wlanbasic.html\r\n\r\n"