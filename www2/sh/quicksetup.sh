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

# quicksetup.sh — detached worker behind the "Quick Setup" wizard
#
#   quicksetup.sh run      read /tmp/quicksetup.job and apply it
#
# cgi-bin/quicksetup.cgi validates the wizard's answers, writes them to the job
# file (one decoded key=value per line) and starts this script in the
# background. It has to be a separate, detached process: changing the LAN IP or
# restarting WiFi drops the very connection the browser used to ask for it, so
# nothing may depend on the HTTP request staying open.
#
# Order of work (nothing is touched until the preflight has passed):
#   1. preflight   every MIB key we are about to write must exist
#   2. backup      /config/config.xml -> config.xml.quicksetup.bak
#   3. settings    upstream (PON mode / RJ45 port), WiFi per band (extender: the
#                  uplink VXD), LAN + DHCP — plain `mib set`s, nothing destructive
#   4. WAN         (router / AP) replace ALL WAN profiles — last on purpose, so
#                  a rejected write in step 3 stops the job with the WAN intact
#   5. commit, then bring it live: WAN -> WiFi -> LAN. Changing the PON mode or
#      the RJ45 WAN port always ends in a reboot instead of a live apply.
#
# Progress goes to /tmp/quicksetup.state (read by `quicksetup.cgi?action=status`),
# human-readable warnings to /tmp/quicksetup.notes, details to /tmp/quicksetup.log.
# Passwords are never written to the log.
#
# Test hooks: QS_JOB, QS_STATE, QS_NOTES, QS_LOG, QS_LOCK, QS_CFG, QS_BB,
# QS_WANAPPLY, QS_WLANAPPLY, QS_DHCP_CONTROL, QS_BR0STATIC, QS_STATIC_ENV.

JOB="${QS_JOB:-/tmp/quicksetup.job}"
STATE="${QS_STATE:-/tmp/quicksetup.state}"
NOTES="${QS_NOTES:-/tmp/quicksetup.notes}"
LOG="${QS_LOG:-/tmp/quicksetup.log}"
LOCKD="${QS_LOCK:-/tmp/quicksetup.lock}"
CFG="${QS_CFG:-/config/config.xml}"
BAK="$CFG.quicksetup.bak"
BB="${QS_BB:-busybox}"
WANAPPLY="${QS_WANAPPLY:-/lmepisowifi/www2/tool/wanapply}"
WLANAPPLY="${QS_WLANAPPLY:-/lmepisowifi/www2/tool/wlanapply}"
DHCP_CONTROL="${QS_DHCP_CONTROL:-/lmepisowifi/www2/sh/dhcp_control.sh}"
BR0STATIC="${QS_BR0STATIC:-/lmepisowifi/www2/sh/br0static.sh}"
STATIC_ENV="${QS_STATIC_ENV:-/lmepisowifi/www2/data/br0_static.env}"
WAN_LOCK=/tmp/wanprofile.lock
WAN_APPLYING=/tmp/wanprofile.applying
WAN_LOG=/tmp/wanprofile_apply.log

CHAIN=ATM_VC_TBL
MEDIA_ETH=1
DUMMY_PPP=255
WAN_MAC_BASE=1

STEP=0; TOTAL=5; MSG=""; NEW_IP=""
REBOOTING=0; REBOOT_NEEDED=0
HAVE_WAN_LOCK=0
TOUCHED=""            # bands (24 / 5) whose main AP was written
WL_FALLBACK=0
WAN_REPLACED=0

# ── plumbing ──────────────────────────────────────────────────────────────────
log() { printf '[%s] %s\n' "$(date +%T)" "$*" >> "$LOG" 2>/dev/null; }

# jg KEY — value from the job file (first match; may contain '=')
jg() {
    $BB awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$JOB"
}

write_state() { # phase
    {
        printf 'phase=%s\n' "$1"
        printf 'step=%s\n' "$STEP"
        printf 'total=%s\n' "$TOTAL"
        printf 'msg=%s\n' "$MSG"
        printf 'reboot=%s\n' "$REBOOTING"
        printf 'reboot_needed=%s\n' "$REBOOT_NEEDED"
        printf 'new_ip=%s\n' "$NEW_IP"
    } > "$STATE.tmp" 2>/dev/null && mv "$STATE.tmp" "$STATE"
}

progress() {
    STEP=$((STEP + 1)); MSG="$1"
    log "step $STEP/$TOTAL: $1"
    write_state running
}

note() { printf '%s\n' "$1" >> "$NOTES"; log "note: $1"; }

cleanup() {
    [ "$HAVE_WAN_LOCK" = "1" ] && rmdir "$WAN_LOCK" 2>/dev/null
    rm -f "$WAN_APPLYING" 2>/dev/null
    rm -f "$JOB" 2>/dev/null          # holds the WiFi / PPPoE passwords: don't leave it in /tmp
    rm -rf "$LOCKD" 2>/dev/null
}

fail() {
    MSG="$1"
    log "FAILED: $1"
    write_state failed
    cleanup
    exit 1
}

trim() { $BB sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# mget KEY — current MIB value (empty if unreadable)
mget() {
    mib get "$1" 2>/dev/null | $BB grep '=' | $BB head -n 1 | $BB cut -d'=' -f2- | $BB tr -d '\r\n' | trim
}

need_key() {
    mib get "$1" 2>/dev/null | $BB grep -q '=' || \
        fail "This firmware does not expose '$1', so nothing was changed."
}

# mset KEY VALUE — never logs the value (it may be a password)
mset() {
    _o=$(mib set "$1" "$2" 2>&1); _rc=$?
    if [ "$_rc" -ne 0 ] || printf '%s' "$_o" | $BB grep -qi 'fail\|out of range'; then
        log "mib set $1 FAILED (rc=$_rc)"
        return 1
    fi
    log "mib set $1 ok"
    return 0
}
mset_or_fail() {
    mset "$1" "$2" || fail "The device rejected '$1'. Setup stopped; a backup of the previous configuration is at $BAK."
}

dhcp_set_mode_mibs() { # same contract as lme.cgi's helper of the same name
    mset_or_fail DHCP_MODE "$1"
    if [ "$1" = "2" ]; then mset_or_fail LAN_DHCP 1; else mset_or_fail LAN_DHCP 0; fi
}

band_vars() { # band -> T REP_EN REP_SSID BN
    case "$1" in
        5) T=WLAN_MBSSIB_TBL;  REP_EN=REPEATER_ENABLED1; REP_SSID=REPEATER_SSID1; BN=5g ;;
        *) T=WLAN1_MBSSIB_TBL; REP_EN=REPEATER_ENABLED2; REP_SSID=REPEATER_SSID2; BN=2g ;;
    esac
}

enc_for_sec() { # open|wpa2|wpa2wpa3|wpa3 -> MIB encrypt code
    case "$1" in
        open) echo 0 ;; wpa2) echo 4 ;; wpa2wpa3) echo 20 ;; wpa3) echo 16 ;; *) echo 4 ;;
    esac
}

# ── helpers shared with wan-profile.cgi (kept in step with it) ───────────────
helper_ready() {
    [ -f "$WANAPPLY" ] || return 1
    [ -x "$WANAPPLY" ] || chmod +x "$WANAPPLY" 2>/dev/null
    [ -x "$WANAPPLY" ] || return 1
    "$WANAPPLY" check >/dev/null 2>&1
}

# restartWAN() flushes iptables/ebtables/nat; put back what the rest of
# lmepisowifi owns (same calls as wan-profile.cgi's reassert_rules)
reassert_rules() {
    log "reassert rules"
    iptables -D INPUT ! -i br0 -p tcp --dport 80 -j DROP 2>/dev/null
    iptables -I INPUT ! -i br0 -p tcp --dport 80 -j DROP 2>/dev/null
    [ -f /lmepisowifi/www2/sh/ipacl.sh ] && sh /lmepisowifi/www2/sh/ipacl.sh apply_all
    [ -f /lmepisowifi/www2/sh/domainblk.sh ] && ( . /lmepisowifi/www2/sh/domainblk.sh --lib; apply_all )
    if [ -f /tmp/hotspot_watchdog.pid ] && [ -f /lmepisowifi/lmehspt.sh ]; then
        ( LMEHSPT_LIB_ONLY=1; . /lmepisowifi/lmehspt.sh --lib
          setup_firewall; restore_fw_sessions; setup_whitelist )
    fi
}

next_wan_mac() { # vc -> 12 hex digits (no colons)
    _vc=$1; _hex=
    for _key in ELAN_MAC_ADDR HW_NIC0_ADDR HW_ELAN_MAC_ADDR; do
        _cand=$(mib get "$_key" 2>/dev/null | $BB head -1 | $BB sed 's/^[^=]*=[[:space:]]*//' | $BB tr -d ' \t\r\n:-' | $BB tr 'a-f' 'A-F')
        if [ "${#_cand}" -eq 12 ]; then _hex=$_cand; break; fi
    done
    if [ "${#_hex}" -ne 12 ]; then
        _cand=$(cat /sys/class/net/br0/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null || true)
        _cand=$(printf '%s' "$_cand" | $BB tr -d ' \t\r\n:-' | $BB tr 'a-f' 'A-F')
        [ "${#_cand}" -eq 12 ] && _hex=$_cand
    fi
    if [ "${#_hex}" -ne 12 ]; then printf '000000000000'; return; fi
    _hi=$(printf '%s' "$_hex" | $BB cut -c1-6)
    _lo=$(printf '%s' "$_hex" | $BB cut -c7-12)
    _n=$(printf '%d' "0x$_lo" 2>/dev/null) || _n=0
    _n=$((_n + WAN_MAC_BASE + _vc))
    printf '%s%06X' "$_hi" $((_n & 0xffffff))
}

atm_total() {
    _t=$(mib get "$CHAIN" 2>/dev/null | $BB tr -d '\r' | $BB grep -c '^ATM_VC_TBL\.[0-9][0-9]*:')
    case "$_t" in ''|*[!0-9]*) _t=0 ;; esac
    printf '%s' "$_t"
}

wl_helper_ok() {
    [ -f "$WLANAPPLY" ] || return 1
    [ -x "$WLANAPPLY" ] || chmod +x "$WLANAPPLY" 2>/dev/null
    [ -x "$WLANAPPLY" ] && "$WLANAPPLY" check >/dev/null 2>&1
}

# wl_restart BAND IDX — IDX: all | 5 (vxd). Falls back to one stock restart at the end.
wl_restart() {
    band_vars "$1"
    if wl_helper_ok && "$WLANAPPLY" restart "$BN" "$2" >> "$LOG" 2>&1; then
        log "wlanapply restart $BN $2 ok"
    else
        log "wlanapply restart $BN $2 unavailable/failed -> will use wlan_apply restart"
        WL_FALLBACK=1
    fi
}

# ── 1. preflight ──────────────────────────────────────────────────────────────
preflight() {
    for _k in LAN_IP_ADDR LAN_SUBNET DHCP_MODE LAN_DHCP; do need_key "$_k"; done
    if [ "$MODE" = "router" ]; then
        for _k in LAN_DHCP_POOL_START LAN_DHCP_POOL_END DHCP_SUBNET_MASK LAN_DHCP_GATEWAY \
                  LAN_DHCP_LEASE LAN_DHCP_DNS_OPT DHCPS_DNS1 DHCPS_DNS2; do need_key "$_k"; done
    fi
    if [ "$MODE" != "extender" ]; then
        for _k in PON_MODE WAN_PHY_PORT AUTO_PON_MODE; do need_key "$_k"; done
    fi
    for _b in 24 5; do
        band_vars "$_b"
        if [ "$(jg lock$_b)" = "1" ]; then continue; fi
        for _f in ssid wlanDisabled wlanMode encrypt wpaPSK dotIEEE80211W; do need_key "$T.0.$_f"; done
    done
    if [ "$MODE" = "extender" ]; then
        band_vars "$UB"
        for _f in ssid wlanDisabled encrypt wpaPSK dotIEEE80211W; do need_key "$T.5.$_f"; done
        need_key "$REP_EN"; need_key "$REP_SSID"
        # The uplink's own radio has to be an access point that is (or will be) on.
        if [ "$(jg lock$UB)" = "1" ]; then
            [ "$(mget "$T.0.wlanDisabled")" = "0" ] || \
                fail "The WiFi on that band is off and is managed elsewhere (coin slot), so it can't be used as the uplink."
            [ "$(mget "$T.0.wlanMode")" != "1" ] || \
                fail "The WiFi on that band is in client mode already; choose the other band."
        fi
    fi
}

# ── 2. backup ─────────────────────────────────────────────────────────────────
backup_cfg() {
    [ -f "$CFG" ] || { note "No $CFG to back up."; return 0; }
    _av=$($BB df -k "$(dirname "$CFG")" 2>/dev/null | $BB awk 'NR==2 {print $4+0}')
    _sz=$($BB wc -c < "$CFG" 2>/dev/null | $BB tr -d ' ')
    if [ $(( ${_av:-0} * 1024 - ${_sz:-0} )) -gt 1048576 ] && cp "$CFG" "$BAK" 2>/dev/null; then
        log "backup -> $BAK"
    else
        note "Not enough free space to keep a backup of the previous configuration."
    fi
}

# ── 3. WAN ────────────────────────────────────────────────────────────────────
# Works out the PON-mode / RJ45-port MIB values exactly the way lme.cgi's
# system_settings does, writes the ones that differ, and sets AUTO_REBOOT.
apply_upstream() {
    CUR_AUTO=$(mget AUTO_PON_MODE); [ -z "$CUR_AUTO" ] && CUR_AUTO=1
    CUR_PMODE=$(mget PON_MODE);                  [ -z "$CUR_PMODE" ] && CUR_PMODE=1
    CUR_PORT=$(mget WAN_PHY_PORT);               [ -z "$CUR_PORT" ] && CUR_PORT=5
    UP_TYPE=$(jg up_type)
    if [ "$UP_TYPE" = "rj45" ]; then
        NEW_AUTO=0; NEW_PMODE=0; NEW_PORT=$(jg up_port)
    else
        UP_PON=$(jg up_pon)
        if [ "$UP_PON" = "auto" ]; then
            NEW_AUTO=1
            if [ "$CUR_PMODE" = "0" ]; then NEW_PMODE=1; NEW_PORT=5; else NEW_PMODE=$CUR_PMODE; NEW_PORT=$CUR_PORT; fi
        else
            NEW_AUTO=0; NEW_PMODE=$UP_PON; NEW_PORT=5
        fi
    fi
    UP_CHANGED=0
    if [ "$NEW_AUTO" != "$CUR_AUTO" ]; then
        mset_or_fail AUTO_PON_MODE "$NEW_AUTO"
        # Only turning auto-detect ON needs a reboot. Turning it OFF alone leaves
        # the live mode/port untouched (a real mode/port change is caught below).
        [ "$NEW_AUTO" = "1" ] && UP_CHANGED=1
    fi
    if [ "$NEW_PMODE" != "$CUR_PMODE" ]; then mset_or_fail PON_MODE "$NEW_PMODE"; UP_CHANGED=1; fi
    if [ "$NEW_PORT" != "$CUR_PORT" ]; then mset_or_fail WAN_PHY_PORT "$NEW_PORT"; UP_CHANGED=1; fi
    # the LAN port that became the WAN uplink can't also be bound to a bridge WAN
    WAN_PORT_BIT=0
    [ "$NEW_PMODE" = "0" ] && WAN_PORT_BIT=$((1 << NEW_PORT))
    if [ "$UP_CHANGED" = "1" ]; then
        AUTO_REBOOT=1
        log "upstream changed: auto $CUR_AUTO->$NEW_AUTO mode $CUR_PMODE->$NEW_PMODE port $CUR_PORT->$NEW_PORT (reboot)"
    fi
}

acquire_wan_lock() {
    _w=0
    while ! mkdir "$WAN_LOCK" 2>/dev/null; do
        _w=$((_w + 1))
        [ "$_w" -gt 20 ] && fail "Another WAN change is in progress. Try again in a moment."
        $BB sleep 1
    done
    HAVE_WAN_LOCK=1
}

wan_delete_all() {
    _total=$(atm_total)
    _i=$((_total - 1))
    while [ "$_i" -ge 0 ]; do
        _ix=$(mget "$CHAIN.$_i.ifIndex")
        if [ "$AUTO_REBOOT" != "1" ] && [ "$WAN_HELPER" = "1" ] && [ -n "$_ix" ]; then
            "$WANAPPLY" stop "$_i" --expect-ifindex "$_ix" >> "$WAN_LOG" 2>&1 || true
        fi
        mib del "$CHAIN.$_i" >> "$LOG" 2>&1 || \
            fail "Could not remove WAN profile $_i. Setup stopped; the previous configuration is backed up at $BAK."
        _i=$((_i - 1))
    done
    mib commit >> "$LOG" 2>&1 || fail "Could not save after removing the old WAN profiles."
    log "removed $_total WAN profile(s)"
}

wan_set() { # key value — roll the half-made record back on failure
    mset "$CHAIN.$NEW_IDX.$1" "$2" && return 0
    mib del "$CHAIN.$NEW_IDX" >/dev/null 2>&1
    mib commit >/dev/null 2>&1
    fail "The device rejected WAN setting '$1'. The old WAN profiles were already removed; restore $BAK from System > MIB Configuration if needed."
}

wan_create() {
    WT=$(jg wan_type)
    case "$WT" in
        pppoe)  CM=2; PPP=0 ;;
        bridge) CM=0; PPP=$DUMMY_PPP ;;
        *)      CM=1; PPP=$DUMMY_PPP ;;
    esac
    VC=0   # the table was just emptied
    IFINDEX=$(( (MEDIA_ETH << 16) | (PPP << 8) | VC ))
    MAC=$(next_wan_mac "$VC")
    case "$MAC" in ''|000000000000|900000000000)
        fail "Could not derive a WAN MAC address from ELAN_MAC_ADDR." ;; esac

    ADD_OUT=$(mib add "$CHAIN" 2>/dev/null)
    NEW_NUM=$(printf '%s' "$ADD_OUT" | $BB grep 'NUM=' | $BB awk -F= '{print $2}' | $BB tr -d ' \r\n')
    case "$NEW_NUM" in ''|*[!0-9]*) fail "Could not add a WAN profile (mib add failed)." ;; esac
    NEW_IDX=$((NEW_NUM - 1))

    if [ "$CM" = "2" ]; then MTU=1492; else MTU=1500; fi
    if [ "$CM" = "0" ]; then NAPT=0; DGW=0; BTYPE=0; else NAPT=1; DGW=1; BTYPE=2; fi
    VLAN=$(jg wan_vlan); [ "$VLAN" = "1" ] || VLAN=0
    ITFG=0
    if [ "$MODE" = "ap" ]; then
        ITFG=$(jg wan_bind); case "$ITFG" in ''|*[!0-9]*) ITFG=0 ;; esac
        ITFG=$(( ITFG & 16383 & ~WAN_PORT_BIT ))
    fi

    wan_set ifIndex       "$IFINDEX"
    wan_set MacAddr       "$MAC"
    wan_set ChannelMode   "$CM"
    wan_set ChannelStatus 1
    wan_set NAPT          "$NAPT"
    wan_set MTU           "$MTU"
    wan_set DefaultGW     "$DGW"
    wan_set vlan          "$VLAN"
    if [ "$VLAN" = "1" ]; then
        wan_set vid   "$(jg wan_vid)"
        wan_set vprio "$(jg wan_vprio)"
    fi
    wan_set applicationtype 2        # INTERNET
    wan_set WanName       wan0
    wan_set itfGroup      "$ITFG"
    wan_set IpProtocol    1
    wan_set BridgeType    "$BTYPE"

    case "$WT" in
        dhcp)
            wan_set ChannelAddrType 1
            wan_set DNSMode 1
            wan_set LocalIPAddr 0.0.0.0
            wan_set RemoteIPAddr 0.0.0.0
            wan_set SubnetMask 0.0.0.0
            ;;
        static)
            wan_set ChannelAddrType 0
            wan_set LocalIPAddr  "$(jg wan_ip)"
            wan_set RemoteIPAddr "$(jg wan_gw)"
            wan_set SubnetMask   "$(jg wan_mask)"
            _d=$(jg wan_dns1); [ -n "$_d" ] && wan_set DNSV4IPAddr1 "$_d"
            _d=$(jg wan_dns2); [ -n "$_d" ] && wan_set DNSV4IPAddr2 "$_d"
            wan_set DNSMode 0
            ;;
        pppoe)
            wan_set pppUser "$(jg wan_user)"
            _p=$(jg wan_pass); [ -n "$_p" ] && wan_set pppPasswd "$_p"
            ;;
        bridge)
            wan_set ChannelAddrType 0
            wan_set DNSMode 0
            ;;
    esac

    mib commit >> "$LOG" 2>&1 || {
        mib del "$CHAIN.$NEW_IDX" >/dev/null 2>&1
        fail "Could not save the new WAN profile."
    }
    WAN_REPLACED=1
    log "created WAN profile idx=$NEW_IDX type=$WT ifindex=$IFINDEX itfGroup=$ITFG"
}

# ── 4. WiFi ───────────────────────────────────────────────────────────────────
write_ap_band() { # band
    band_vars "$1"; _p="w$1"
    if [ "$(jg lock$1)" = "1" ]; then
        note "The $( [ "$1" = 5 ] && echo '5 GHz' || echo '2.4 GHz' ) WiFi was left as it is (a coin-slot NodeMCU is synced to it)."
        return 0
    fi
    TOUCHED="$TOUCHED $1"
    if [ "$(jg ${_p}_on)" != "1" ]; then
        mset_or_fail "$T.0.wlanDisabled" 1
        return 0
    fi
    _enc=$(enc_for_sec "$(jg ${_p}_sec)")
    mset_or_fail "$T.0.wlanDisabled" 0
    # quick setup configures an access point: leave client mode, but don't
    # disturb AP+WDS or other AP flavours
    [ "$(mget "$T.0.wlanMode")" = "1" ] && mset_or_fail "$T.0.wlanMode" 0
    mset_or_fail "$T.0.ssid" "$(jg ${_p}_ssid)"
    mset_or_fail "$T.0.encrypt" "$_enc"
    if [ "$_enc" != "0" ]; then
        _pw=$(jg ${_p}_pass)
        mset_or_fail "$T.0.wpaAuth" 2
        mset_or_fail "$T.0.enable1X" 0
        mset_or_fail "$T.0.unicastCipher" 0
        mset_or_fail "$T.0.wpa2UnicastCipher" 2
        mset_or_fail "$T.0.wpaPSK" "$_pw"
        mset_or_fail "$T.0.wscPsk" "$_pw"
    fi
    case "$_enc" in 16|20) mset_or_fail "$T.0.dotIEEE80211W" 1 ;; *) mset_or_fail "$T.0.dotIEEE80211W" 0 ;; esac
}

# extender: point the band's repeater/VXD interface (idx 5) at the upstream network
write_vxd() {
    band_vars "$UB"
    _enc=$(jg up_enc)
    _ssid=$(jg up_ssid)
    mset_or_fail "$T.5.wlanDisabled" 0
    mset_or_fail "$REP_EN" 1
    mset_or_fail "$REP_SSID" "$_ssid"
    mset_or_fail "$T.5.ssid" "$_ssid"
    mset_or_fail "$T.5.encrypt" "$_enc"
    # a stale BSSID pin would keep it from joining; clear it where the patched SDK has the key
    _lk=$(mget "$T.5.LME_BSSID_LOCKING" | $BB tr 'A-F' 'a-f')
    case "$_lk" in ''|*[!0-9a-f]*) ;; *) [ "${#_lk}" -eq 12 ] && mset "$T.5.LME_BSSID_LOCKING" 000000000000 ;; esac
    if [ "$_enc" != "0" ]; then
        _pw=$(jg up_pass)
        mset_or_fail "$T.5.wpaAuth" 2
        mset_or_fail "$T.5.enable1X" 0
        mset_or_fail "$T.5.unicastCipher" "$(jg up_uc)"
        mset_or_fail "$T.5.wpa2UnicastCipher" "$(jg up_u2c)"
        mset_or_fail "$T.5.wpaPSK" "$_pw"
        mset_or_fail "$T.5.wscPsk" "$_pw"
    else
        mset_or_fail "$T.5.wpaPSK" ""
        mset_or_fail "$T.5.wscPsk" ""
    fi
    case "$_enc" in 16|20) mset_or_fail "$T.5.dotIEEE80211W" 1 ;; *) mset_or_fail "$T.5.dotIEEE80211W" 0 ;; esac
}

# ── 5. LAN ────────────────────────────────────────────────────────────────────
write_lan() {
    LAN_STATIC=1
    if [ "$MODE" = "router" ]; then
        mset_or_fail LAN_IP_ADDR "$(jg lan_ip)"
        mset_or_fail LAN_SUBNET  "$(jg lan_mask)"
        NEW_IP=$(jg lan_ip)
        if [ "$(jg dhcp_on)" = "1" ]; then
            dhcp_set_mode_mibs 2
            mset_or_fail LAN_DHCP_POOL_START "$(jg dhcp_start)"
            mset_or_fail LAN_DHCP_POOL_END   "$(jg dhcp_end)"
            mset_or_fail DHCP_SUBNET_MASK    "$(jg lan_mask)"
            mset_or_fail LAN_DHCP_GATEWAY    "$(jg lan_ip)"
            mset_or_fail LAN_DHCP_LEASE      "$(jg dhcp_lease)"
            if [ "$(jg dhcp_dns_opt)" = "1" ]; then
                mset_or_fail LAN_DHCP_DNS_OPT 1
                mset_or_fail DHCPS_DNS1 "$(jg dhcp_dns1)"
                mset_or_fail DHCPS_DNS2 "$(jg dhcp_dns2)"
            else
                mset_or_fail LAN_DHCP_DNS_OPT 0
            fi
        else
            dhcp_set_mode_mibs 0
        fi
        STATIC_GW=""; STATIC_DNS1=""; STATIC_DNS2=""
    elif [ "$(jg lan_mode)" = "client" ]; then
        LAN_STATIC=0
        dhcp_set_mode_mibs 3
        NEW_IP=""
    else
        mset_or_fail LAN_IP_ADDR "$(jg lan_ip)"
        mset_or_fail LAN_SUBNET  "$(jg lan_mask)"
        dhcp_set_mode_mibs 0
        NEW_IP=$(jg lan_ip)
        STATIC_GW=$(jg lan_gw); STATIC_DNS1=$(jg lan_dns1); STATIC_DNS2=$(jg lan_dns2)
    fi
}

# Persist (or forget) the static gateway/DNS that br0static.sh re-applies at boot.
write_static_env() {
    if [ "$LAN_STATIC" = "1" ] && [ "$MODE" != "router" ] && \
       { [ -n "$STATIC_GW" ] || [ -n "$STATIC_DNS1" ] || [ -n "$STATIC_DNS2" ]; }; then
        mkdir -p "$(dirname "$STATIC_ENV")" 2>/dev/null
        {
            if [ -n "$STATIC_GW" ];   then printf 'GW=%s\n'   "$STATIC_GW"; fi
            if [ -n "$STATIC_DNS1" ]; then printf 'DNS1=%s\n' "$STATIC_DNS1"; fi
            if [ -n "$STATIC_DNS2" ]; then printf 'DNS2=%s\n' "$STATIC_DNS2"; fi
        } > "$STATIC_ENV.tmp"
        if mv "$STATIC_ENV.tmp" "$STATIC_ENV"; then
            log "static gateway/DNS saved"
        else
            note "Could not save the gateway/DNS, so they won't survive a reboot."
        fi
    else
        rm -f "$STATIC_ENV"
    fi
}

# ── 6. live apply ─────────────────────────────────────────────────────────────
apply_live() {
    if [ "$WAN_REPLACED" = "1" ]; then
        MSG="Starting the new WAN connection"; write_state running
        if [ "$WAN_HELPER" = "1" ]; then
            date +%s > "$WAN_APPLYING"
            "$WANAPPLY" start 0 >> "$WAN_LOG" 2>&1
            log "wanapply start 0 rc=$?"
            reassert_rules >> "$LOG" 2>&1
            rm -f "$WAN_APPLYING"
        else
            REBOOT_NEEDED=1
            note "Live WAN apply isn't available on this firmware, so the new WAN profile starts after a reboot."
        fi
    fi

    MSG="Restarting WiFi"; write_state running
    for _b in $TOUCHED; do wl_restart "$_b" all; done
    if [ "$MODE" = "extender" ]; then
        wl_restart "$UB" 5
        sysconf multi_ap_agent_restart >> "$LOG" 2>&1
    fi
    [ "$WL_FALLBACK" = "1" ] && wlan_apply restart >> "$LOG" 2>&1

    MSG="Applying the LAN settings"; write_state running
    if [ "$LAN_STATIC" = "1" ]; then
        ifconfig br0 "$NEW_IP" netmask "$(jg lan_mask)" mtu 1500 >> "$LOG" 2>&1
    fi
    sh "$DHCP_CONTROL" restart >> "$LOG" 2>&1 || note "The DHCP service reported a problem while restarting; check LAN > DHCP."
    if [ -f "$STATIC_ENV" ] && [ -f "$BR0STATIC" ]; then sh "$BR0STATIC" apply >> "$LOG" 2>&1; fi
}

# ── main ──────────────────────────────────────────────────────────────────────
run() {
    [ -f "$JOB" ] || { echo "no job file" >&2; exit 2; }
    mkdir "$LOCKD" 2>/dev/null || { echo "already running" >&2; exit 3; }
    date +%s > "$LOCKD/ts"
    trap cleanup EXIT
    : > "$NOTES"; : > "$LOG"
    rm -f "$STATE"

    MODE=$(jg mode)
    case "$MODE" in router|ap|extender) ;; *) fail "Unknown setup mode." ;; esac
    UB=$(jg up_band)
    AUTO_REBOOT=0
    WAN_HELPER=0
    TOTAL=4
    [ "$MODE" != "extender" ] && [ "$(jg wan_action)" = "replace" ] && TOTAL=5

    progress "Checking the settings"
    preflight

    progress "Backing up the current configuration"
    backup_cfg

    # Everything that is a plain `mib set` goes first. The one destructive step
    # (replacing every WAN profile) comes last, so a rejected write above stops
    # the job before the existing WAN has been touched.
    progress "Saving the settings"
    [ "$MODE" != "extender" ] && apply_upstream
    write_ap_band 24
    write_ap_band 5
    [ "$MODE" = "extender" ] && write_vxd
    write_lan

    if [ "$MODE" != "extender" ]; then
        if [ "$(jg wan_action)" = "replace" ]; then
            progress "Replacing the WAN connection"
            [ "$AUTO_REBOOT" = "1" ] || { helper_ready && WAN_HELPER=1; }
            acquire_wan_lock
            wan_delete_all     # also commits the settings written above
            wan_create
        else
            log "keeping the existing WAN profiles"
        fi
    fi
    mib commit >> "$LOG" 2>&1 || fail "Could not save the configuration (mib commit failed)."
    write_static_env
    sync

    progress "Applying"
    if [ "$AUTO_REBOOT" = "1" ]; then
        MSG="Rebooting to switch the WAN upstream"
        REBOOTING=1
        write_state done
        log "rebooting"
        ( sleep 3; sync; reboot ) >/dev/null 2>&1 </dev/null &
        trap - EXIT
        cleanup
        exit 0
    fi
    apply_live
    MSG="Done"
    write_state done
    log "done"
    exit 0
}

case "$1" in
    run) run ;;
    *)   echo "Usage: $0 run" >&2; exit 1 ;;
esac
