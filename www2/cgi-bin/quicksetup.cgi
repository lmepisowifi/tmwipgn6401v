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

# quicksetup.cgi — backend of the "Quick Setup" wizard (www2/js/quicksetup.js)
#
# GET  ?action=context   what the wizard needs to pre-fill itself: current LAN /
#                        DHCP / per-band WiFi values, coin-slot + merged-SSID
#                        locks, repurposed VXDs, saved static gateway/DNS
# POST ?action=apply     the finished wizard (urlencoded). EVERYTHING is
#                        validated here first; only then is a job file written
#                        and sh/quicksetup.sh started detached. Nothing is
#                        changed by a request that fails validation.
# GET  ?action=status    progress of the running / last job
# POST ?action=reboot    sync + reboot (used when a live apply wasn't possible)
#
# The wizard never writes anything while the user is clicking through it: the
# answers live in the browser until the final "Apply".
#
# Field names in the POST body (see the validation below for the rules):
#   mode=router|ap|extender
#   up_type=pon|rj45  up_pon=auto|1|2|3  up_port=0..3          (router / ap)
#   wan_action=keep|replace  wan_type=dhcp|pppoe|static|bridge
#   wan_user wan_pass wan_ip wan_mask wan_gw wan_dns1 wan_dns2
#   wan_vlan=0|1 wan_vid wan_vprio  wan_bind=<itfGroup bitmask>  (ap)
#   lan_mode=static|client  lan_ip lan_mask lan_gw lan_dns1 lan_dns2
#   dhcp_on dhcp_start dhcp_end dhcp_lease dhcp_dns_opt dhcp_dns1 dhcp_dns2 (router)
#   w24_on w24_ssid w24_sec w24_pass   w5_on w5_ssid w5_sec w5_pass
#   up_band=24|5 up_ssid up_enc up_uc up_u2c up_pass            (extender)

SESSION_TIMEOUT=600
BB=busybox
JOB=/tmp/quicksetup.job
STATE=/tmp/quicksetup.state
NOTES=/tmp/quicksetup.notes
LOCKD=/tmp/quicksetup.lock
RUNNER=/lmepisowifi/www2/sh/quicksetup.sh
MERGE_FILE=/lmepisowifi/www2/data/merged_ssid.json
NM_IFACES=/lmepisowifi/www2/data/nodemcu_ifaces.txt
STATIC_ENV=/lmepisowifi/www2/data/br0_static.env
REPURPOSE=/tmp/repurpose_active
RP_LIB=/lmepisowifi/www2/sh/repurpose_lib.sh
STALE_AFTER=900

# ── Auth ──────────────────────────────────────────────────────────────────────
BROWSER_SESSION=$(echo "$HTTP_COOKIE" \
    | $BB sed -n 's/.*session=\([^;]*\).*/\1/p' \
    | $BB tr -d '\r\n')
BROWSER_SESSION=$(printf '%s' "$BROWSER_SESSION" \
    | $BB tr -cd 'a-fA-F0-9')
SESSION_FILE="/tmp/sessions/$BROWSER_SESSION"

if [ -z "$BROWSER_SESSION" ] || [ ! -f "$SESSION_FILE" ]; then
    printf "Status: 302 Found\r\nLocation: /login.html\r\n\r\n"
    exit 0
fi

LAST=$(cat "$SESSION_FILE" 2>/dev/null | $BB tr -d '\r\n')
NOW=$(date +%s)
[ -z "$LAST" ] && LAST=$NOW
if [ $((NOW - LAST)) -gt $SESSION_TIMEOUT ]; then
    rm -f "$SESSION_FILE"
    printf "Status: 302 Found\r\nLocation: /login.html\r\n\r\n"
    exit 0
fi
_STMP=$(mktemp /tmp/sessions/.tmp.XXXXXX)
echo "$NOW" > "$_STMP"
$BB mv "$_STMP" "$SESSION_FILE"

# ── Helpers ───────────────────────────────────────────────────────────────────
json_esc() { printf '%s' "$1" | $BB sed 's/\\/\\\\/g; s/"/\\"/g' | $BB tr -d '\r\n'; }

err_json() {
    printf 'Status: 400 Bad Request\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    printf '{"ok":false,"error":"%s","detail":"%s"}' "$1" "$(json_esc "$2")"
    exit 0
}
ok_json() {
    printf 'Status: 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n%s' "$1"
    exit 0
}

mf() { # MIB value, trimmed ("" if unreadable)
    mib get "$1" 2>/dev/null | $BB grep '=' | $BB head -n 1 | $BB cut -d'=' -f2- \
        | $BB tr -d '\r\n' | $BB sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}
num() { case "$1" in ''|*[!0-9]*) printf '%s' "${2:-0}" ;; *) printf '%s' "$1" ;; esac; }

is_uint() { # value min max
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -gt 9 ] && return 1
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}
is_ipv4() {
    [ -n "$1" ] || return 1
    printf '%s' "$1" | $BB awk -F. '
        { ok = (NF == 4)
          for (i = 1; i <= NF && ok; i++) if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i + 0 > 255) ok = 0
          exit ok ? 0 : 1 }'
}
is_mask() {
    is_ipv4 "$1" || return 1
    [ "$1" = "0.0.0.0" ] && return 1
    printf '%s' "$1" | $BB awk -F. '
        { ok = 1; seen = 0
          for (i = 1; i <= 4; i++) {
              o = $i + 0
              if (o != 0 && o != 128 && o != 192 && o != 224 && o != 240 && o != 248 && o != 252 && o != 254 && o != 255) ok = 0
              if (seen && o != 0) ok = 0
              if (o != 255) seen = 1
          }
          exit ok ? 0 : 1 }'
}
bytes() { printf '%s' "$1" | LC_ALL=C $BB wc -c | $BB tr -d ' '; }

# ── merged SSID / coin-slot locks ────────────────────────────────────────────
merge_get() { # KEY DEFAULT
    if [ ! -f "$MERGE_FILE" ]; then printf '%s' "$2"; return; fi
    _mv=$($BB sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\\(-\\{0,1\\}[0-9]\\{1,\\}\\).*/\\1/p" \
            "$MERGE_FILE" 2>/dev/null | $BB head -n1 | $BB tr -d '\r\n')
    [ -z "$_mv" ] && _mv="$2"
    printf '%s' "$_mv"
}

# A coin-slot NodeMCU rides on a band's MAIN access point (iface 0) when its
# sync binding is on. Only wlanbasic.cgi pushes new credentials to the NodeMCU,
# so Quick Setup leaves such a band completely alone.
nm_bound() { # band 24|5
    [ -f "$NM_IFACES" ] || { echo 0; return; }
    $BB awk -F'|' -v b="$1" '$2 == "1" && $3 == b && $4 == "0" { f = 1 } END { print f ? 1 : 0 }' "$NM_IFACES"
}

compute_locks() {
    B24=$(nm_bound 24); B5=$(nm_bound 5)
    L24=$B24; L5=$B5
    ME=$(merge_get enabled 0)
    M24=$(merge_get iface24 -1); M5=$(merge_get iface5 -1)
    MERGE_MAIN=0
    [ "$ME" = "1" ] && [ "$M24" = "0" ] && [ "$M5" = "0" ] && MERGE_MAIN=1
    # merged main APs mirror each other, so a bound one locks both
    if [ "$MERGE_MAIN" = "1" ] && { [ "$B24" = "1" ] || [ "$B5" = "1" ]; }; then L24=1; L5=1; fi
}

# Interfaces repurposed as a WAN (DHCP Client page). Read through the same
# helper wan-repurpose.cgi uses, so a legacy registry that an older build left
# with fused names is understood the same way; plain file as the fallback.
repurposed_list() {
    {
        if [ -r "$RP_LIB" ]; then
            ( . "$RP_LIB"; rp_registry_list ) 2>/dev/null
        else
            $BB cat "$REPURPOSE" 2>/dev/null
        fi
    } | $BB grep -E '^[a-z0-9._-]+$'
}

repurposed_json() {
    _s=""; _o="["
    for _i in $(repurposed_list); do
        _o="$_o$_s\"$_i\""; _s=","
    done
    printf '%s]' "$_o"
}

job_busy() {
    [ -d "$LOCKD" ] || return 1
    _m=$(date +%s)
    _t=$($BB cat "$LOCKD/ts" 2>/dev/null | $BB tr -d '\r\n ')
    case "$_t" in ''|*[!0-9]*) _t=$_m ;; esac
    if [ $((_m - _t)) -gt "$STALE_AFTER" ]; then rm -rf "$LOCKD" 2>/dev/null; return 1; fi
    return 0
}

QS="$QUERY_STRING"

# ================================================================
# GET ?action=context
# ================================================================
if echo "$QS" | $BB grep -q "action=context"; then
    compute_locks

    band_json() { # band
        case "$1" in 5) _T=WLAN_MBSSIB_TBL ;; *) _T=WLAN1_MBSSIB_TBL ;; esac
        _ss=$(mf "$_T.0.ssid"); _dis=$(num "$(mf "$_T.0.wlanDisabled")" 1)
        _md=$(num "$(mf "$_T.0.wlanMode")" 0);  _en=$(num "$(mf "$_T.0.encrypt")" 0)
        _pk=$(mf "$_T.0.wpaPSK");               _vd=$(num "$(mf "$_T.5.wlanDisabled")" 1)
        printf '{"ssid":"%s","disabled":%s,"mode":%s,"encrypt":%s,"psk":"%s","vxd_disabled":%s}' \
            "$(json_esc "$_ss")" "$_dis" "$_md" "$_en" "$(json_esc "$_pk")" "$_vd"
    }
    tf() { [ "$1" = "1" ] && printf 'true' || printf 'false'; }

    DMODE=$(num "$(mf DHCP_MODE)" 2)
    case "$DMODE" in 0|1|2|3) ;; *) DMODE=2 ;; esac
    ENVGW=$($BB awk 'index($0,"GW=")==1{print substr($0,4);exit}' "$STATIC_ENV" 2>/dev/null | $BB tr -d '\r\n ')
    ENVD1=$($BB awk 'index($0,"DNS1=")==1{print substr($0,6);exit}' "$STATIC_ENV" 2>/dev/null | $BB tr -d '\r\n ')
    ENVD2=$($BB awk 'index($0,"DNS2=")==1{print substr($0,6);exit}' "$STATIC_ENV" 2>/dev/null | $BB tr -d '\r\n ')
    if [ -x /lmepisowifi/www2/tool/wanapply ] || [ -f /lmepisowifi/www2/tool/wanapply ]; then HP=true; else HP=false; fi
    if job_busy; then BUSY=true; else BUSY=false; fi

    printf 'Status: 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    printf '{"ok":true,"client_ip":"%s","busy":%s,"live_wan":%s,' "$(json_esc "$REMOTE_ADDR")" "$BUSY" "$HP"
    printf '"lan":{"ip":"%s","mask":"%s","dhcp_mode":%s,"pool_start":"%s","pool_end":"%s","lease":%s,"dns_opt":%s,"dns1":"%s","dns2":"%s"},' \
        "$(json_esc "$(mf LAN_IP_ADDR)")" "$(json_esc "$(mf LAN_SUBNET)")" "$DMODE" \
        "$(json_esc "$(mf LAN_DHCP_POOL_START)")" "$(json_esc "$(mf LAN_DHCP_POOL_END)")" \
        "$(num "$(mf LAN_DHCP_LEASE)" 86400)" "$(num "$(mf LAN_DHCP_DNS_OPT)" 0)" \
        "$(json_esc "$(mf DHCPS_DNS1)")" "$(json_esc "$(mf DHCPS_DNS2)")"
    printf '"static":{"gw":"%s","dns1":"%s","dns2":"%s"},' "$(json_esc "$ENVGW")" "$(json_esc "$ENVD1")" "$(json_esc "$ENVD2")"
    printf '"merge":{"enabled":%s,"main_pair":%s},' "$(tf "$ME")" "$(tf "$MERGE_MAIN")"
    printf '"locked":{"24":%s,"5":%s},' "$(tf "$L24")" "$(tf "$L5")"
    printf '"repurposed":%s,' "$(repurposed_json)"
    printf '"wlan":{"24":%s,"5":%s}}' "$(band_json 24)" "$(band_json 5)"
    exit 0
fi

# ================================================================
# GET ?action=status
# ================================================================
if echo "$QS" | $BB grep -q "action=status"; then
    sv() { $BB awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$STATE" 2>/dev/null | $BB tr -d '\r\n'; }
    if [ -f "$STATE" ]; then
        PH=$(sv phase); ST=$(num "$(sv step)" 0); TT=$(num "$(sv total)" 0)
        RB=$(num "$(sv reboot)" 0); RN=$(num "$(sv reboot_needed)" 0)
        MS=$(sv msg); NI=$(sv new_ip)
    elif job_busy; then
        PH=running; ST=0; TT=0; RB=0; RN=0; MS="Starting"; NI=""
    else
        PH=idle; ST=0; TT=0; RB=0; RN=0; MS=""; NI=""
    fi
    _n=""; _s=""
    if [ -f "$NOTES" ]; then
        while IFS= read -r _l; do
            [ -n "$_l" ] || continue
            _n="$_n$_s\"$(json_esc "$_l")\""; _s=","
        done < "$NOTES"
    fi
    printf 'Status: 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    printf '{"ok":true,"phase":"%s","step":%s,"total":%s,"msg":"%s","rebooting":%s,"reboot_needed":%s,"new_ip":"%s","notes":[%s]}' \
        "$(json_esc "$PH")" "$ST" "$TT" "$(json_esc "$MS")" \
        "$([ "$RB" = 1 ] && echo true || echo false)" "$([ "$RN" = 1 ] && echo true || echo false)" \
        "$(json_esc "$NI")" "$_n"
    exit 0
fi

# ================================================================
# POST ?action=reboot
# ================================================================
if echo "$QS" | $BB grep -q "action=reboot"; then
    printf 'Status: 200 OK\r\nContent-Type: application/json\r\n\r\n{"ok":true,"rebooting":true}'
    ( sleep 1; sync; reboot ) >/dev/null 2>&1 </dev/null &
    exit 0
fi

# ================================================================
# POST ?action=apply
# ================================================================
if ! echo "$QS" | $BB grep -q "action=apply"; then
    printf 'Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nUnknown action'
    exit 0
fi
[ "$REQUEST_METHOD" = "POST" ] || err_json "bad_method" "use POST"

case "${CONTENT_LENGTH:-0}" in *[!0-9]*|"") CONTENT_LENGTH=0 ;; esac
[ "$CONTENT_LENGTH" -gt 8192 ] && err_json "too_large" "request body too large"
[ "$CONTENT_LENGTH" -eq 0 ] && err_json "no_data" "empty request"
read -n "$CONTENT_LENGTH" POST_DATA

job_busy && err_json "busy" "A quick setup is already being applied — wait for it to finish."
[ -f /tmp/wanprofile.applying ] && err_json "busy" "A WAN change is still being applied — wait a few seconds and try again."

# Decode the body once into key=value lines. A decoded value holding a control
# character (newline, NUL, ...) is refused outright rather than risk it
# forging another key.
DEC=$(mktemp /tmp/quicksetup.dec.XXXXXX)
trap 'rm -f "$DEC"' EXIT
printf '%s' "$POST_DATA" | $BB tr '&' '\n' | $BB awk '
    BEGIN { for (i = 0; i < 256; i++) { hx[sprintf("%02x", i)] = sprintf("%c", i); hx[sprintf("%02X", i)] = sprintf("%c", i) } }
    {
        i = index($0, "="); if (i == 0) next
        k = substr($0, 1, i - 1); v = substr($0, i + 1)
        gsub(/\+/, " ", v)
        n = split(v, a, "%"); out = a[1]; bad = 0
        for (j = 2; j <= n; j++) {
            h = substr(a[j], 1, 2)
            if (length(a[j]) >= 2 && (h in hx)) { if (h == "00") bad = 1; out = out hx[h] substr(a[j], 3) }
            else out = out "%" a[j]
        }
        for (c = 1; c < 32; c++) if (index(out, sprintf("%c", c))) bad = 1
        if (index(out, sprintf("%c", 127))) bad = 1
        if (bad) print "__bad__=" k; else print k "=" out
    }' > "$DEC"
$BB grep -q '^__bad__=' "$DEC" && err_json "bad_chars" "a field contains a control character"
chmod 600 "$DEC" 2>/dev/null

fg() { $BB awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$DEC"; }

# netchk IP MASK [PS PE GW OIP OMASK] — "ok" or the reason (all arithmetic in awk:
# 32-bit shell arithmetic isn't safe for addresses on this MIPS busybox)
netchk() {
    $BB awk -v ip="$1" -v mask="$2" -v ps="$3" -v pe="$4" -v gw="$5" -v oip="$6" -v omask="$7" '
    function n(s,  a, k) {
        if (split(s, a, ".") != 4) return -1
        for (k = 1; k <= 4; k++) if (a[k] !~ /^[0-9]+$/ || a[k] + 0 > 255) return -1
        return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4]
    }
    function bad(m) { print m; exit }
    BEGIN {
        x = n(ip); m = n(mask)
        if (x < 0 || m < 0) bad("Invalid address or subnet mask.")
        size = 4294967296 - m
        p = 1; while (p < size) p *= 2
        if (p != size || size < 4 || size > 16777216) bad("The subnet mask must be between 255.0.0.0 and 255.255.255.252.")
        net = x - (x % size); bc = net + size - 1
        a1 = int(x / 16777216)
        if (a1 == 0 || a1 == 127 || a1 >= 224) bad("That address cannot be used for a LAN. Use a private range such as 192.168.x.x or 10.x.x.x.")
        if (x == net || x == bc) bad("That address is the network or broadcast address of its subnet.")
        if (ps != "") {
            s = n(ps); e = n(pe)
            if (s < 0 || e < 0) bad("Invalid DHCP range.")
            if (s <= net || e >= bc) bad("The DHCP range must be inside the LAN subnet.")
            if (s > e) bad("The DHCP range start must come before its end.")
            if (x >= s && x <= e) bad("The DHCP range cannot include the router'"'"'s own address.")
        }
        if (gw != "") {
            g = n(gw)
            if (g < 0) bad("Invalid gateway address.")
            if (g <= net || g >= bc) bad("The gateway must be inside the same subnet as the LAN address.")
            if (g == x) bad("The gateway cannot be this device'"'"'s own address.")
        }
        if (oip != "") {
            o = n(oip); om = n(omask)
            if (o >= 0 && om >= 0) {
                os = 4294967296 - om
                if (os > 0) {
                    on = o - (o % os); ob = on + os - 1
                    if (!(ob < net || on > bc)) bad("The WAN address range overlaps the LAN subnet. Pick a different LAN address.")
                }
            }
        }
        print "ok"
    }'
}

MODE=$(fg mode)
case "$MODE" in router|ap|extender) ;; *) err_json "bad_mode" "choose a setup mode" ;; esac
compute_locks

# ── WAN upstream + connection (router / ap) ───────────────────────────────────
WAN_STATIC_IP=""; WAN_STATIC_MASK=""
if [ "$MODE" != "extender" ]; then
    case "$(fg up_type)" in
        pon)
            case "$(fg up_pon)" in auto|1|2|3) ;; *) err_json "bad_upstream" "choose a fiber mode (auto-detect, GPON, EPON or Fiber Ethernet)" ;; esac ;;
        rj45)
            is_uint "$(fg up_port)" 0 3 || err_json "bad_upstream" "choose which LAN port is the WAN uplink" ;;
        *) err_json "bad_upstream" "choose where the internet comes from (fiber or an RJ45 port)" ;;
    esac

    WA=$(fg wan_action)
    case "$WA" in
        keep)
            _t=$(mib get ATM_VC_TBL 2>/dev/null | $BB tr -d '\r' | $BB grep -c '^ATM_VC_TBL\.[0-9][0-9]*:')
            case "$_t" in ''|*[!0-9]*) _t=0 ;; esac
            _ok=0; _i=0
            while [ "$_i" -lt "$_t" ]; do
                _cm=$(mf "ATM_VC_TBL.$_i.ChannelMode"); _en=$(mf "ATM_VC_TBL.$_i.ChannelStatus")
                if [ "$_en" != "0" ]; then
                    if [ "$MODE" = "ap" ] && [ "$_cm" = "0" ]; then _ok=1; fi
                    if [ "$MODE" = "router" ] && { [ "$_cm" = "1" ] || [ "$_cm" = "2" ]; }; then _ok=1; fi
                fi
                _i=$((_i + 1))
            done
            [ "$_ok" = "1" ] || err_json "no_wan" "there is no suitable WAN profile to keep — set up a new one"
            ;;
        replace)
            WT=$(fg wan_type)
            if [ "$MODE" = "ap" ]; then
                [ "$WT" = "bridge" ] || err_json "bad_wan" "access point mode uses a bridge WAN"
            else
                case "$WT" in dhcp|pppoe|static) ;; *) err_json "bad_wan" "choose DHCP, PPPoE or Static IP for the WAN" ;; esac
            fi
            if [ "$(fg wan_vlan)" = "1" ]; then
                is_uint "$(fg wan_vid)" 1 4094 || err_json "bad_vlan" "VLAN ID must be 1-4094"
                is_uint "$(fg wan_vprio)" 0 7  || err_json "bad_vlan" "VLAN priority must be 0-7"
            fi
            if [ "$WT" = "pppoe" ]; then
                _u=$(fg wan_user)
                [ -n "$_u" ] || err_json "bad_pppoe" "enter the PPPoE username from your ISP"
                [ "$(bytes "$_u")" -le 63 ] || err_json "bad_pppoe" "the PPPoE username is too long (63 characters max)"
                [ "$(bytes "$(fg wan_pass)")" -le 63 ] || err_json "bad_pppoe" "the PPPoE password is too long (63 characters max)"
            fi
            if [ "$WT" = "static" ]; then
                is_ipv4 "$(fg wan_ip)"   || err_json "bad_wan_ip" "enter a valid WAN IP address"
                is_mask "$(fg wan_mask)" || err_json "bad_wan_ip" "enter a valid WAN subnet mask"
                is_ipv4 "$(fg wan_gw)"   || err_json "bad_wan_ip" "enter a valid WAN gateway"
                for _k in wan_dns1 wan_dns2; do
                    _v=$(fg "$_k"); [ -z "$_v" ] || is_ipv4 "$_v" || err_json "bad_wan_ip" "invalid WAN DNS server"
                done
                WAN_STATIC_IP=$(fg wan_ip); WAN_STATIC_MASK=$(fg wan_mask)
            fi
            if [ "$MODE" = "ap" ]; then
                is_uint "$(fg wan_bind)" 0 16383 || err_json "bad_bind" "invalid interface selection"
            fi
            ;;
        *) err_json "bad_wan" "choose whether to keep or replace the WAN profile" ;;
    esac
fi

# ── WiFi (every mode) ─────────────────────────────────────────────────────────
for B in 24 5; do
    eval "_L=\$L$B"
    [ "$_L" = "1" ] && continue
    ON=$(fg "w${B}_on")
    case "$ON" in 0|1) ;; *) err_json "bad_wifi" "invalid WiFi on/off value" ;; esac
    [ "$ON" = "1" ] || continue
    LABEL="2.4 GHz"; [ "$B" = "5" ] && LABEL="5 GHz"
    S=$(fg "w${B}_ssid")
    _n=$(bytes "$S")
    { [ "$_n" -ge 1 ] && [ "$_n" -le 32 ]; } || err_json "bad_ssid" "the $LABEL WiFi name must be 1-32 characters"
    SEC=$(fg "w${B}_sec")
    case "$SEC" in open) ;; wpa2|wpa2wpa3|wpa3)
        _n=$(bytes "$(fg "w${B}_pass")")
        { [ "$_n" -ge 8 ] && [ "$_n" -le 63 ]; } || err_json "bad_wifi_pass" "the $LABEL WiFi password must be 8-63 characters" ;;
        *) err_json "bad_wifi" "choose a security type for the $LABEL WiFi" ;;
    esac
done
# merged SSID (main APs paired): both bands must carry identical credentials
if [ "$MERGE_MAIN" = "1" ] && [ "$L24" != "1" ] && [ "$(fg w24_on)" = "1" ] && [ "$(fg w5_on)" = "1" ]; then
    if [ "$(fg w24_ssid)" != "$(fg w5_ssid)" ] || [ "$(fg w24_sec)" != "$(fg w5_sec)" ] || [ "$(fg w24_pass)" != "$(fg w5_pass)" ]; then
        err_json "merge_mismatch" "the merged SSID feature is on, so both bands need the same name, security and password"
    fi
fi

# ── extender uplink ───────────────────────────────────────────────────────────
if [ "$MODE" = "extender" ]; then
    UBAND=$(fg up_band)
    case "$UBAND" in 24|5) ;; *) err_json "bad_uplink" "choose which band connects to the upstream WiFi" ;; esac
    if [ "$UBAND" = "5" ]; then VXD=wlan0-vxd; else VXD=wlan1-vxd; fi
    repurposed_list | $BB grep -qx "$VXD" && \
        err_json "vxd_in_use" "$VXD is currently used as a WAN (DHCP Client page) — pick the other band or turn that off first"
    eval "_L=\$L$UBAND"
    if [ "$_L" != "1" ] && [ "$(fg "w${UBAND}_on")" != "1" ]; then
        err_json "uplink_band_off" "the band used to connect upstream needs its own WiFi turned on"
    fi
    US=$(fg up_ssid); _n=$(bytes "$US")
    { [ "$_n" -ge 1 ] && [ "$_n" -le 32 ]; } || err_json "bad_uplink" "enter the name of the WiFi network to connect to"
    UE=$(fg up_enc)
    case "$UE" in 0|2|4|6|16|20) ;; *) err_json "bad_uplink" "unsupported upstream security type (WEP networks can be joined from Site Survey)" ;; esac
    is_uint "$(fg up_uc)" 0 3  || err_json "bad_uplink" "invalid cipher"
    is_uint "$(fg up_u2c)" 0 3 || err_json "bad_uplink" "invalid cipher"
    if [ "$UE" != "0" ]; then
        _n=$(bytes "$(fg up_pass)")
        { [ "$_n" -ge 8 ] && [ "$_n" -le 63 ]; } || err_json "bad_uplink_pass" "the upstream WiFi password must be 8-63 characters"
    fi
fi

# ── LAN ───────────────────────────────────────────────────────────────────────
LIP=$(fg lan_ip); LMASK=$(fg lan_mask)
if [ "$MODE" = "router" ]; then
    is_ipv4 "$LIP"   || err_json "bad_lan" "enter a valid LAN IP address"
    is_mask "$LMASK" || err_json "bad_lan" "enter a valid subnet mask"
    PS=""; PE=""
    case "$(fg dhcp_on)" in
        1)
            PS=$(fg dhcp_start); PE=$(fg dhcp_end)
            is_ipv4 "$PS" && is_ipv4 "$PE" || err_json "bad_dhcp" "enter a valid DHCP start and end address"
            is_uint "$(fg dhcp_lease)" 60 31536000 || err_json "bad_dhcp" "the lease time must be between 60 seconds and 1 year"
            case "$(fg dhcp_dns_opt)" in
                0) ;;
                1)
                    is_ipv4 "$(fg dhcp_dns1)" || err_json "bad_dhcp" "enter at least one valid DNS server"
                    _v=$(fg dhcp_dns2); [ -z "$_v" ] || is_ipv4 "$_v" || err_json "bad_dhcp" "invalid second DNS server"
                    ;;
                *) err_json "bad_dhcp" "invalid DNS option" ;;
            esac
            ;;
        0) ;;
        *) err_json "bad_dhcp" "choose whether the DHCP server is on" ;;
    esac
    R=$(netchk "$LIP" "$LMASK" "$PS" "$PE" "" "$WAN_STATIC_IP" "$WAN_STATIC_MASK")
    [ "$R" = "ok" ] || err_json "bad_lan" "$R"
else
    case "$(fg lan_mode)" in
        client) ;;
        static)
            is_ipv4 "$LIP"   || err_json "bad_lan" "enter a valid LAN IP address"
            is_mask "$LMASK" || err_json "bad_lan" "enter a valid subnet mask"
            _g=$(fg lan_gw)
            [ -z "$_g" ] || is_ipv4 "$_g" || err_json "bad_lan" "invalid gateway address"
            for _k in lan_dns1 lan_dns2; do
                _v=$(fg "$_k"); [ -z "$_v" ] || is_ipv4 "$_v" || err_json "bad_lan" "invalid DNS server address"
            done
            R=$(netchk "$LIP" "$LMASK" "" "" "$_g" "" "")
            [ "$R" = "ok" ] || err_json "bad_lan" "$R"
            ;;
        *) err_json "bad_lan" "choose a static address or DHCP client for the LAN" ;;
    esac
fi

# ── everything is valid: write the job and start it ──────────────────────────
{
    cat "$DEC"
    printf 'lock24=%s\nlock5=%s\nclient_ip=%s\n' "$L24" "$L5" "$REMOTE_ADDR"
} > "$JOB.tmp"
chmod 600 "$JOB.tmp" 2>/dev/null
$BB mv "$JOB.tmp" "$JOB"

rm -f "$STATE" "$NOTES"
( sh "$RUNNER" run ) </dev/null >/dev/null 2>&1 &

if [ "$MODE" = "router" ] || [ "$(fg lan_mode)" = "static" ]; then NEWIP="$LIP"; else NEWIP=""; fi
ok_json "{\"ok\":true,\"mode\":\"$MODE\",\"new_ip\":\"$(json_esc "$NEWIP")\"}"
