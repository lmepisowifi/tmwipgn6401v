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

# wan-profile.cgi — WAN profile editor (vendor ATM_VC_TBL)
#
# Shell-CGI counterpart of the vendor boa page multi_wan_generic.asp
# (form handler: formEth() in fmwan.c, record layout: MIB_CE_ATM_VC_T).
#
# GET  ?action=list    → every ATM_VC_TBL record + live interface state (JSON)
# POST ?action=save    → edit ONE existing profile, body: idx=<n>&<fields>
# POST ?action=reboot  → sync + reboot (needed to apply a saved profile)
#
# Member names below are the `mib get ATM_VC_TBL.<n>` descriptor names from
# the SDK (mibtbl.c), NOT the C struct names: ChannelMode (cmode),
# ChannelAddrType (ipDhcp), ChannelStatus (enable), LocalIPAddr, RemoteIPAddr,
# SubnetMask, DNSV4IPAddr1/2, pppUser, pppPasswd, MTU, DefaultGW, ...
# Optional members (enableIpQos / enableIGMP / enableMLD / IpProtocol / mVid
# / WanName) only exist when the firmware was built with that option, so
# every write is skipped for a member the live dump doesn't contain.
#
# Scope (deliberate): edit in place only. The vendor add/delete path also
# runs rtk_layer2bridging_update_wan_interface_mib_table(), the CWMP
# instance-number bookkeeping, restartWAN()/deleteConnection() — all inside
# boa, none reachable from a shell. Changing PPPoE <-> non-PPPoE is refused
# for the same reason: it changes ifIndex, which port-forwarding, routes and
# the bridging table reference. Bridge <-> IPoE keeps ifIndex and is allowed.
#
# Live apply: `mib set` + `mib commit` only persist the record. The vendor page
# then runs deleteConnection()/restartWAN() inside boa; both are exported by
# libmib.so, and sh/wanapply (source: src/wanapply/) calls them from its own
# process the way the stock `cli` does. Order matches boa's modify path:
#     wanapply stop  <idx>   old record -> tear down nas0_N / ppp / dhcp / NAT
#     mib set ... ; mib commit
#     wanapply start <idx>   new record -> recreate, then /bin/firewall.sh
# `start` runs detached; the page polls ?action=list ("applying") until done.
# restartWAN() flushes the whole netfilter state (iptables -F, ebtables -F, nat
# built-in chains), so reassert_rules() puts back the rules this project owns.
# If sh/wanapply is missing or `wanapply check` fails, the old behaviour is
# kept: the record is saved and takes effect after a reboot.
# A rolling copy of /config/config.xml is kept at
# /config/config.xml.wanprofile.bak before each save; it can be restored from
# System > MIB Configuration.

SESSION_TIMEOUT=600
BB=busybox
CHAIN=ATM_VC_TBL
NETSYS=/sys/class/net
CFG=/config/config.xml
LOCK=/tmp/wanprofile.lock
WANAPPLY=/lmepisowifi/www2/sh/wanapply
APPLYING=/tmp/wanprofile.applying      # exists (holding an epoch) while a live apply runs
APPLY_LOG=/tmp/wanprofile_apply.log
APPLY_MAXAGE=240                       # a stale marker older than this is ignored
TAB=$(printf '\t')

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

# Atomic session refresh
_STMP=$(mktemp /tmp/sessions/.tmp.XXXXXX)
echo "$NOW" > "$_STMP"
$BB mv "$_STMP" "$SESSION_FILE"

# ── Helpers ───────────────────────────────────────────────────────────────────
json_esc() { printf '%s' "$1" | $BB sed 's/\\/\\\\/g; s/"/\\"/g' | $BB tr -d '\r\n'; }

err_json() {
    printf 'Status: 400 Bad Request\r\nContent-Type: application/json\r\n\r\n'
    printf '{"ok":false,"error":"%s","detail":"%s"}' "$1" "$(json_esc "$2")"
    exit 0
}
ok_json() {
    printf 'Status: 200 OK\r\nContent-Type: application/json\r\n\r\n%s' "$1"
    exit 0
}

urldecode() {
    $BB awk '
    BEGIN {
        for (i = 0; i <= 255; i++) hx[sprintf("%02x", i)] = sprintf("%c", i)
        for (i = 0; i <= 255; i++) hx[sprintf("%02X", i)] = sprintf("%c", i)
    }
    {
        s = $0
        gsub(/\+/, " ", s)
        n = split(s, a, "%")
        out = a[1]
        for (i = 2; i <= n; i++) {
            h = substr(a[i], 1, 2)
            if (length(a[i]) >= 2 && (h in hx)) {
                out = out hx[h] substr(a[i], 3)
            } else {
                out = out "%" a[i]
            }
        }
        print out
    }'
}

QS="$QUERY_STRING"

# ── Live apply helpers ────────────────────────────────────────────────────────
# apply_running — true while a detached `wanapply start` job is still in flight
apply_running() {
    [ -f "$APPLYING" ] || return 1
    _at=$(cat "$APPLYING" 2>/dev/null | $BB tr -d '\r\n')
    case "$_at" in ''|*[!0-9]*) rm -f "$APPLYING"; return 1 ;; esac
    if [ $(( $(date +%s) - _at )) -gt "$APPLY_MAXAGE" ]; then rm -f "$APPLYING"; return 1; fi
    return 0
}

# helper_ready — wanapply is present and can reach libmib + configd
helper_ready() {
    [ -f "$WANAPPLY" ] || return 1
    [ -x "$WANAPPLY" ] || chmod +x "$WANAPPLY" 2>/dev/null
    [ -x "$WANAPPLY" ] || return 1
    "$WANAPPLY" check >/dev/null 2>&1
}

# reassert_rules — restartWAN() flushes iptables/ebtables/nat; put back what the
# rest of lmepisowifi owns. Every call below is the same one boot or a watchdog
# already makes, and all are re-entrant. Best effort: failures are only logged.
reassert_rules() {
    echo "[reassert] $(date +%T)"
    iptables -D INPUT ! -i br0 -p tcp --dport 80 -j DROP 2>/dev/null
    iptables -I INPUT ! -i br0 -p tcp --dport 80 -j DROP 2>/dev/null
    [ -f /lmepisowifi/www2/sh/ipacl.sh ] && sh /lmepisowifi/www2/sh/ipacl.sh apply_all
    [ -f /lmepisowifi/www2/sh/domainblk.sh ] && ( . /lmepisowifi/www2/sh/domainblk.sh --lib; apply_all )
    if [ -f /tmp/hotspot_watchdog.pid ] && [ -f /lmepisowifi/lmehspt.sh ]; then
        ( LMEHSPT_LIB_ONLY=1; . /lmepisowifi/lmehspt.sh --lib
          setup_firewall; restore_fw_sessions; setup_whitelist )
    fi
}

# start_detached <idx> — run `wanapply start` + reassert_rules() in the background
# and return at once (restartWAN() takes several seconds; httpd would otherwise
# hold the request open). stdout/stderr must be closed or httpd waits for EOF.
start_detached() {
    date +%s > "$APPLYING"
    (
        echo "=== start idx=$1 $(date +%T)"
        "$WANAPPLY" start "$1"
        echo "=== wanapply start exit=$?"
        reassert_rules
        rm -f "$APPLYING"
        echo "=== done $(date +%T)"
    ) </dev/null >>"$APPLY_LOG" 2>&1 &
}

# ── MIB access ────────────────────────────────────────────────────────────────
# `mib get ATM_VC_TBL` prints every record as
#   ATM_VC_TBL.<n>:
#   member            = value
# It is read once per request into $ALL and sliced per record below.
ALL=$(mib get "$CHAIN" 2>/dev/null | $BB tr -d '\r')

chain_total() {
    printf '%s\n' "$ALL" | $BB grep -c '^ATM_VC_TBL\.[0-9][0-9]*:'
}

# chain_dump <idx> — the record's "member = value" lines
chain_dump() {
    printf '%s\n' "$ALL" | $BB awk -v want="$CHAIN.$1:" '
        $1 == want { on = 1; next }
        /^ATM_VC_TBL\.[0-9]+:/ { on = 0 }
        on { print }'
}

# fld <dump> <member> — value of one member (empty if absent or empty)
fld() {
    printf '%s\n' "$1" | $BB awk -v k="$2" '
        { i = index($0, "="); if (i == 0) next
          n = substr($0, 1, i - 1); gsub(/[ \t]+$/, "", n)
          if (n == k) { v = substr($0, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); print v; exit } }'
}

# has <dump> <member> — true if the member exists in this firmware's record
has() {
    printf '%s\n' "$1" | $BB awk -v k="$2" '
        BEGIN { f = 1 }
        { i = index($0, "="); if (i == 0) next
          n = substr($0, 1, i - 1); gsub(/[ \t]+$/, "", n)
          if (n == k) { f = 0; exit } }
        END { exit f }'
}

# ── Live interface state ──────────────────────────────────────────────────────
# ifIndex layout: (media << 16) | (ppp << 8) | vc ; media 1 = ETH, ppp 0xff = none
ifname_for() {
    _ix=$1
    _media=$(( (_ix >> 16) & 255 ))
    _ppp=$(( (_ix >> 8) & 255 ))
    _vc=$(( _ix & 255 ))
    [ "$_media" -ne 1 ] && return
    if [ "$_ppp" -ne 255 ]; then printf 'ppp%s' "$_ppp"; else printf 'nas0_%s' "$_vc"; fi
}

# profile_json <idx> — one JSON object
profile_json() {
    _pi=$1
    _dump=$(chain_dump "$_pi")
    _body=$(printf '%s\n' "$_dump" | $BB awk '
    BEGIN {
        n = split("ifIndex:ifindex:n ChannelStatus:enable:n ChannelMode:cmode:n ChannelAddrType:addrtype:n vlan:vlan:n vid:vid:n vprio:vprio:n mVid:mvid:n applicationtype:app:n NAPT:napt:n enableIpQos:qos:n enableIGMP:igmp:n enableMLD:mld:n MTU:mtu:n DefaultGW:dgw:n IpProtocol:ipproto:n pppUser:pppuser:s pppAuth:pppauth:n pppACName:pppac:s pppServiceName:pppsvc:s pppConnectType:pppctype:n pppIdleTime:pppidle:n LocalIPAddr:ip:s RemoteIPAddr:gw:s SubnetMask:mask:s DNSMode:dnsmode:n DNSV4IPAddr1:dns1:s DNSV4IPAddr2:dns2:s itfGroup:itfgroup:n MacAddr:mac:s WanName:name:s", t, " ")
        for (k = 1; k <= n; k++) { split(t[k], p, ":"); mj[p[1]] = p[2]; mt[p[1]] = p[3] }
    }
    {
        i = index($0, "="); if (i == 0) next
        nm = substr($0, 1, i - 1); gsub(/[ \t]+$/, "", nm)
        v = substr($0, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
        seen[nm] = 1
        if (nm == "pppPasswd") { passset = (v != ""); next }
        if (!(nm in mj)) next
        if (mt[nm] == "n") {
            if (v !~ /^-?[0-9]+$/) v = 0
            out = out sprintf("\"%s\":%s,", mj[nm], v)
        } else {
            gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v)
            out = out sprintf("\"%s\":\"%s\",", mj[nm], v)
        }
    }
    END {
        printf "%s\"pppass_set\":%s,", out, passset ? "true" : "false"
        printf "\"has_qos\":%s,\"has_igmp\":%s,\"has_mld\":%s,\"has_ipproto\":%s,\"has_mvid\":%s,\"has_name\":%s,",
            ("enableIpQos" in seen) ? "true" : "false", ("enableIGMP" in seen) ? "true" : "false",
            ("enableMLD" in seen) ? "true" : "false", ("IpProtocol" in seen) ? "true" : "false",
            ("mVid" in seen) ? "true" : "false", ("WanName" in seen) ? "true" : "false"
    }')

    _ix=$(fld "$_dump" ifIndex)
    case "$_ix" in ''|*[!0-9]*) _ix=0 ;; esac
    _ifn=$(ifname_for "$_ix")
    _en=$(fld "$_dump" ChannelStatus)
    _cm=$(fld "$_dump" ChannelMode)

    _st="missing"; _lip=""; _br=""
    if [ -n "$_ifn" ]; then
        _lk=$(printf '%s\n' "$LINKS" | $BB awk -v n="$_ifn" '$1 == n { print $2; exit }')
        if [ -n "$_lk" ]; then
            _st="down"
            _lip=$(printf '%s\n' "$ADDRS" | $BB awk -v n="$_ifn" '$1 == n { print $2; exit }')
            if printf '%s' "$_lk" | $BB grep -q 'LOWER_UP'; then
                if [ "$_cm" = "0" ] || [ -n "$_lip" ]; then _st="up"; else _st="connecting"; fi
            fi
            [ -e "$NETSYS/$_ifn/master" ] && \
                _br=$(readlink "$NETSYS/$_ifn/master" 2>/dev/null | $BB sed 's|.*/||')
        fi
    fi
    [ "$_en" = "0" ] && _st="disabled"

    printf '{"index":%s,%s"ifname":"%s","status":"%s","live_ip":"%s","bridge":"%s"}' \
        "$_pi" "$_body" "$(json_esc "$_ifn")" "$_st" "$(json_esc "$_lip")" "$(json_esc "$_br")"
}

# ================================================================
# GET ?action=list
# ================================================================
if echo "$QS" | $BB grep -q "action=list"; then
    TOTAL=$(chain_total)
    case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac
    # "<ifname> <FLAGS>" and "<ifname> <first IPv4>" from plain `ip` output
    LINKS=$(ip link show 2>/dev/null | $BB awk '/^[0-9]+: / { n = $2; sub(/[:@].*$/, "", n); f = $3; gsub(/[<>]/, "", f); print n, f }')
    ADDRS=$(ip -4 addr show 2>/dev/null | $BB awk '/^[0-9]+: / { n = $2; sub(/[:@].*$/, "", n) }
        $1 == "inet" { split($2, a, "/"); if (!(n in s)) { s[n] = 1; print n, a[1] } }')
    printf 'Status: 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    if apply_running; then _ap=true; else _ap=false; fi
    if [ -x "$WANAPPLY" ]; then _hp=true; else _hp=false; fi
    printf '{"ok":true,"total":%s,"applying":%s,"live_apply":%s,"profiles":[' "$TOTAL" "$_ap" "$_hp"
    _i=0; _sep=""
    while [ "$_i" -lt "$TOTAL" ]; do
        printf '%s' "$_sep"; profile_json "$_i"; _sep=","
        _i=$((_i + 1))
    done
    printf ']}'
    exit 0
fi

# ================================================================
# POST ?action=reboot
# ================================================================
if echo "$QS" | $BB grep -q "action=reboot"; then
    printf 'Status: 200 OK\r\nContent-Type: application/json\r\n\r\n{"ok":true,"rebooting":true}'
    ( sleep 1; sync; reboot ) >/dev/null 2>&1 &
    exit 0
fi

# ================================================================
# POST ?action=save
# ================================================================
if ! echo "$QS" | $BB grep -q "action=save"; then
    printf 'Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nUnknown action'
    exit 0
fi

case "${CONTENT_LENGTH:-0}" in *[!0-9]*|"") CONTENT_LENGTH=0 ;; esac
[ "$CONTENT_LENGTH" -gt 8192 ] && err_json "too_large" "request body too large"
[ "$CONTENT_LENGTH" -eq 0 ] && err_json "no_data" "empty request"
read -n "$CONTENT_LENGTH" POST_DATA

fget() {
    printf '%s' "$POST_DATA" \
        | $BB tr '&' '\n' \
        | $BB grep "^$1=" \
        | $BB sed 's/^[^=]*=//' \
        | urldecode \
        | head -1 \
        | $BB tr -d '\r'
}

apply_running && err_json "busy" "the previous change is still being applied — wait a few seconds"

# One save at a time — mib set/commit is not re-entrant across CGIs.
mkdir "$LOCK" 2>/dev/null || err_json "busy" "another WAN change is in progress"
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# ── validators ────────────────────────────────────────────────────────────────
is_uint() { # value min max
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -gt 9 ] && return 1
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}
is_ipv4() {
    [ -n "$1" ] || return 1      # awk never runs its main block on empty input
    printf '%s' "$1" | $BB awk -F. '
        { ok = (NF == 4)
          for (i = 1; i <= NF && ok; i++) if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i + 0 > 255) ok = 0
          exit ok ? 0 : 1 }'
}
is_mask() {
    # Comparisons only: this BusyBox awk is built without math support (no ^, %, int()).
    # Valid mask = octets from {255,254,252,248,240,224,192,128,0}; once an octet is
    # below 255, every later octet must be 0.
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
printable() { # value maxlen
    [ "${#1}" -le "$2" ] || return 1
    [ -z "$(printf '%s' "$1" | $BB tr -d '\040-\176')" ]
}

IDX=$(fget idx | $BB tr -cd '0-9')
TOTAL=$(chain_total)
case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac
[ -z "$IDX" ] && err_json "bad_idx" "no profile selected"
[ "$IDX" -ge "$TOTAL" ] && err_json "bad_idx" "profile $IDX does not exist"

DUMP=$(chain_dump "$IDX")
[ -z "$DUMP" ] && err_json "read_failed" "could not read profile $IDX"

CUR_CMODE=$(fld "$DUMP" ChannelMode)
CUR_IFINDEX=$(fld "$DUMP" ifIndex)
CUR_APP=$(fld "$DUMP" applicationtype)
case "$CUR_CMODE" in 0|1|2|3|4|5|6|8) ;; *) err_json "bad_state" "unreadable ChannelMode" ;; esac
case "$CUR_IFINDEX" in ''|*[!0-9]*) err_json "bad_state" "unreadable ifIndex" ;; esac
case "$CUR_APP" in ''|*[!0-9]*) CUR_APP=0 ;; esac

NEW_CMODE=$(fget cmode)
[ -z "$NEW_CMODE" ] && NEW_CMODE=$CUR_CMODE
case "$NEW_CMODE" in 0|1|2) ;; *)
    [ "$NEW_CMODE" = "$CUR_CMODE" ] || err_json "bad_cmode" "unsupported connection type" ;;
esac
if [ "$NEW_CMODE" != "$CUR_CMODE" ]; then
    case "$CUR_CMODE$NEW_CMODE" in
        01|10) ;;
        *) err_json "type_change" "Changing to or from PPPoE changes the interface index. Add a new profile in the vendor page, or edit the MIB XML, instead." ;;
    esac
fi

PAIRS=$(mktemp /tmp/wanprofile_pairs.XXXXXX)
trap 'rm -f "$PAIRS"; rmdir "$LOCK" 2>/dev/null' EXIT

# addp <member> <value> — queue a write, only if this firmware has the member
addp() {
    has "$DUMP" "$1" || return 0
    [ "$(fld "$DUMP" "$1")" = "$2" ] && return 0
    printf '%s%s%s\n' "$1" "$TAB" "$2" >> "$PAIRS"
}

# ── name / admin status ───────────────────────────────────────────────────────
V=$(fget name)
if [ -n "$V" ]; then
    printable "$V" 29 || err_json "bad_name" "name must be printable ASCII, up to 29 characters"
    case "$V" in *[!A-Za-z0-9_.-]*) err_json "bad_name" "name may only use letters, digits, _ . -" ;; esac
    addp WanName "$V"
fi

V=$(fget enable)
if [ -n "$V" ]; then
    is_uint "$V" 0 1 || err_json "bad_enable" "admin status must be 0 or 1"
    addp ChannelStatus "$V"
fi

# ── connection type ───────────────────────────────────────────────────────────
[ "$NEW_CMODE" != "$CUR_CMODE" ] && addp ChannelMode "$NEW_CMODE"

# ── VLAN ──────────────────────────────────────────────────────────────────────
V=$(fget vlan)
if [ -n "$V" ]; then
    is_uint "$V" 0 1 || err_json "bad_vlan" "VLAN switch must be 0 or 1"
    addp vlan "$V"
    if [ "$V" = "1" ]; then
        VID=$(fget vid)
        is_uint "$VID" 1 4095 || err_json "bad_vid" "VLAN ID must be 1-4095"
        addp vid "$VID"
        VP=$(fget vprio); [ -z "$VP" ] && VP=0
        is_uint "$VP" 0 7 || err_json "bad_vprio" "802.1p must be 0-7"
        addp vprio "$VP"
    fi
fi
V=$(fget mvid)
if [ -n "$V" ]; then
    { [ "$V" = "0" ] || is_uint "$V" 1 4095; } || err_json "bad_mvid" "multicast VLAN must be 0 or 1-4095"
    addp mVid "$V"
fi

# ── service type (keep any bits the page doesn't expose) ─────────────────────
V=$(fget app)
if [ -n "$V" ]; then
    is_uint "$V" 1 15 || err_json "bad_app" "pick at least one service type"
    addp applicationtype $(( (CUR_APP & ~15) | V ))
fi

# ── NAPT / QoS / IGMP / MLD ──────────────────────────────────────────────────
for _pair in napt:NAPT qos:enableIpQos igmp:enableIGMP mld:enableMLD; do
    _k=${_pair%%:*}; _m=${_pair##*:}
    V=$(fget "$_k")
    [ -z "$V" ] && continue
    is_uint "$V" 0 1 || err_json "bad_$_k" "$_k must be 0 or 1"
    [ "$_k" = "napt" ] && [ "$NEW_CMODE" = "0" ] && V=0
    addp "$_m" "$V"
done

# ── MTU / default route / IP protocol ────────────────────────────────────────
V=$(fget mtu)
if [ -n "$V" ]; then
    if [ "$NEW_CMODE" = "2" ]; then _max=1492; else _max=1500; fi
    is_uint "$V" 68 "$_max" || err_json "bad_mtu" "MTU must be 68-$_max for this connection type"
    addp MTU "$V"
fi

V=$(fget dgw)
if [ -n "$V" ]; then
    is_uint "$V" 0 1 || err_json "bad_dgw" "default route must be 0 or 1"
    [ "$NEW_CMODE" = "0" ] && V=0
    if [ "$V" = "1" ]; then
        _j=0
        while [ "$_j" -lt "$TOTAL" ]; do
            if [ "$_j" -ne "$IDX" ]; then
                _od=$(chain_dump "$_j")
                if [ "$(fld "$_od" DefaultGW)" = "1" ] && [ "$(fld "$_od" ChannelStatus)" = "1" ] \
                   && [ "$(fld "$_od" ChannelMode)" != "0" ]; then
                    _on=$(fld "$_od" WanName); [ -z "$_on" ] && _on="profile $_j"
                    err_json "dgw_conflict" "$_on already carries the default route — turn it off there first"
                fi
            fi
            _j=$((_j + 1))
        done
    fi
    addp DefaultGW "$V"
fi

V=$(fget ipproto)
if [ -n "$V" ]; then
    is_uint "$V" 1 3 || err_json "bad_ipproto" "IP protocol must be 1, 2 or 3"
    addp IpProtocol "$V"
fi

# ── PPPoE ─────────────────────────────────────────────────────────────────────
if [ "$NEW_CMODE" = "2" ]; then
    U=$(fget pppuser)
    [ -z "$U" ] && err_json "bad_pppuser" "PPP user name cannot be empty"
    printable "$U" 63 || err_json "bad_pppuser" "PPP user name must be printable ASCII, up to 63 characters"
    case "$U" in *" "*) err_json "bad_pppuser" "PPP user name cannot contain spaces" ;; esac
    addp pppUser "$U"

    P=$(fget ppppass)
    # Blank or all-stars means "unchanged" (same convention as the vendor page).
    if [ -n "$P" ] && [ -n "$(printf '%s' "$P" | $BB tr -d '*')" ]; then
        printable "$P" 29 || err_json "bad_ppppass" "PPP password must be printable ASCII, up to 29 characters"
        case "$P" in *" "*) err_json "bad_ppppass" "PPP password cannot contain spaces" ;; esac
        addp pppPasswd "$P"
    elif [ -z "$(fld "$DUMP" pppPasswd)" ] && [ -z "$P" ]; then
        err_json "bad_ppppass" "PPP password cannot be empty"
    fi

    V=$(fget pppauth); [ -n "$V" ] && { is_uint "$V" 0 2 || err_json "bad_pppauth" "auth must be 0-2"; addp pppAuth "$V"; }
    V=$(fget pppac);   printable "$V" 29 || err_json "bad_pppac" "AC name up to 29 printable characters"; addp pppACName "$V"
    V=$(fget pppsvc);  printable "$V" 29 || err_json "bad_pppsvc" "service name up to 29 printable characters"; addp pppServiceName "$V"
    CT=$(fget pppctype)
    if [ -n "$CT" ]; then
        is_uint "$CT" 0 2 || err_json "bad_pppctype" "connect type must be 0-2"
        addp pppConnectType "$CT"
        if [ "$CT" = "1" ]; then
            V=$(fget pppidle)
            is_uint "$V" 1 65535 || err_json "bad_pppidle" "idle time must be 1-65535 for connect-on-demand"
            addp pppIdleTime "$V"
        fi
    fi
fi

# ── IPoE addressing / DNS ─────────────────────────────────────────────────────
if [ "$NEW_CMODE" = "1" ]; then
    AT=$(fget addrtype)
    if [ -n "$AT" ]; then
        is_uint "$AT" 0 1 || err_json "bad_addrtype" "address type must be 0 (static) or 1 (DHCP)"
        addp ChannelAddrType "$AT"
    else
        AT=$(fld "$DUMP" ChannelAddrType)
    fi
    if [ "$AT" = "0" ]; then
        A=$(fget ip);   is_ipv4 "$A" && [ "$A" != "0.0.0.0" ] || err_json "bad_ip" "enter a valid IPv4 address"
        M=$(fget mask); is_mask "$M" || err_json "bad_mask" "enter a valid subnet mask"
        G=$(fget gw); [ -z "$G" ] && G=0.0.0.0
        is_ipv4 "$G" || err_json "bad_gw" "enter a valid gateway"
        addp LocalIPAddr "$A"; addp SubnetMask "$M"; addp RemoteIPAddr "$G"
    fi
fi
if [ "$NEW_CMODE" = "1" ] || [ "$NEW_CMODE" = "2" ]; then
    DM=$(fget dnsmode)
    if [ -n "$DM" ]; then
        is_uint "$DM" 0 1 || err_json "bad_dnsmode" "DNS mode must be 0 or 1"
        addp DNSMode "$DM"
        if [ "$DM" = "0" ]; then   # 0 = manual DNS, 1 = automatic
            D1=$(fget dns1); is_ipv4 "$D1" || err_json "bad_dns1" "enter a valid primary DNS"
            addp DNSV4IPAddr1 "$D1"
            D2=$(fget dns2); [ -z "$D2" ] && D2=0.0.0.0
            is_ipv4 "$D2" || err_json "bad_dns2" "enter a valid secondary DNS"
            addp DNSV4IPAddr2 "$D2"
        fi
    fi
fi

[ -s "$PAIRS" ] || ok_json "{\"ok\":true,\"idx\":$IDX,\"changed\":0,\"backup\":false,\"applied\":\"none\",\"applying\":false,\"reboot_required\":false}"

# ── backup, apply, commit ─────────────────────────────────────────────────────
BACKUP=false
if [ -f "$CFG" ]; then
    _av=$($BB df -k /config 2>/dev/null | $BB awk 'NR==2 {print $4+0}')
    _sz=$($BB wc -c < "$CFG" 2>/dev/null | $BB tr -d ' ')
    if [ $(( ${_av:-0} * 1024 - ${_sz:-0} )) -gt 1048576 ]; then
        cp "$CFG" "$CFG.wanprofile.bak" 2>/dev/null && BACKUP=true
    fi
fi

UNDO=$(mktemp /tmp/wanprofile_undo.XXXXXX)
trap 'rm -f "$PAIRS" "$UNDO"; rmdir "$LOCK" 2>/dev/null' EXIT

# ── tear the live connection down with the OLD record (boa does the same) ─────
LIVE=0; STOPPED=0
if helper_ready; then
    LIVE=1
    echo "=== stop idx=$IDX $(date +%T)" >> "$APPLY_LOG"
    "$WANAPPLY" stop "$IDX" --expect-ifindex "$CUR_IFINDEX" >> "$APPLY_LOG" 2>&1
    _rc=$?
    case "$_rc" in
        0) STOPPED=1 ;;
        2|3|4|5|6|75) err_json "stop_failed" "could not stop the live connection (wanapply exit $_rc, see $APPLY_LOG); nothing was changed" ;;
        *) STOPPED=1   # crashed part-way: connection state unknown, so restore below
           start_detached "$IDX"
           err_json "stop_failed" "wanapply stop died (exit $_rc); the connection is being restored — nothing was saved" ;;
    esac
fi

FAILED=""
while IFS="$TAB" read -r M NV; do
    [ -z "$M" ] && continue
    OV=$(fld "$DUMP" "$M")
    OUT=$(mib set "$CHAIN.$IDX.$M" "$NV" 2>&1)
    if [ $? -ne 0 ] || printf '%s' "$OUT" | $BB grep -qi "fail\|out of range"; then
        FAILED="$M"
        break
    fi
    printf '%s%s%s\n' "$M" "$TAB" "$OV" >> "$UNDO"
done < "$PAIRS"

if [ -n "$FAILED" ]; then
    # Put back whatever was already written so a later commit from another
    # page can't persist a half-applied profile.
    while IFS="$TAB" read -r M OV; do
        [ -z "$M" ] && continue
        mib set "$CHAIN.$IDX.$M" "$OV" >/dev/null 2>&1
    done < "$UNDO"
    [ "$STOPPED" = "1" ] && start_detached "$IDX"   # bring the old profile back up
    err_json "set_failed" "the device rejected $FAILED; nothing was saved"
fi

if ! mib commit >/dev/null 2>&1; then
    [ "$STOPPED" = "1" ] && start_detached "$IDX"
    err_json "commit_failed" "mib commit failed; the change is not persisted"
fi
sync

if [ "$STOPPED" = "1" ]; then
    start_detached "$IDX"
    ok_json "{\"ok\":true,\"idx\":$IDX,\"changed\":$(wc -l < "$PAIRS" | $BB tr -d ' '),\"backup\":$BACKUP,\"applied\":\"live\",\"applying\":true,\"reboot_required\":false}"
fi

ok_json "{\"ok\":true,\"idx\":$IDX,\"changed\":$(wc -l < "$PAIRS" | $BB tr -d ' '),\"backup\":$BACKUP,\"applied\":\"reboot\",\"applying\":false,\"reboot_required\":true}"
