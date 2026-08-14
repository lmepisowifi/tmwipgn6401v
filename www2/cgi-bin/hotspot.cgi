#!/bin/sh

SESSION_TIMEOUT=600

# ---------------------------------------------------------------
# Auth gate — same pattern as lme.cgi
# ---------------------------------------------------------------
BROWSER_SESSION=$(echo "$HTTP_COOKIE" | busybox sed -n 's/.*session=\([^;]*\).*/\1/p' | busybox tr -d '\r\n')
# Sanitize: session IDs are sha256 hex. Strip anything else to block
# path traversal (e.g. Cookie: session=../../config/foo) into rm/mv/cat.
BROWSER_SESSION=$(echo "$BROWSER_SESSION" | busybox tr -cd 'a-fA-F0-9')
SESSION_FILE="/tmp/sessions/$BROWSER_SESSION"

if [ -z "$BROWSER_SESSION" ] || [ ! -f "$SESSION_FILE" ]; then
    printf "Status: 302 Found\r\n"
    printf "Location: /login.html\r\n\r\n"
    exit 0
fi

LAST=$(cat "$SESSION_FILE" 2>/dev/null | busybox tr -d '\r\n')
NOW=$(date +%s)
[ -z "$LAST" ] && LAST=$NOW

if [ $((NOW - LAST)) -gt $SESSION_TIMEOUT ]; then
    rm -f "$SESSION_FILE"
    printf "Status: 302 Found\r\n"
    printf "Location: /login.html\r\n\r\n"
    exit 0
fi

_SESS_TMP=$(mktemp /tmp/sessions/.tmp.XXXXXX)
echo "$NOW" > "$_SESS_TMP"
busybox mv "$_SESS_TMP" "$SESSION_FILE"

# Clamp body size once for every action below: reject non-numeric and cap
# to 64KB so a malicious Content-Length can't force an oversized read (DoS).
case "${CONTENT_LENGTH:-0}" in *[!0-9]*|"") CONTENT_LENGTH=0 ;; esac
# portal_upload and portal_audio_upload allow larger base64 payloads (up to ~15 MB)
_ACT_PRE=$(echo "$QUERY_STRING" | grep -o 'action=[^&]*' | sed 's/action=//')
if [ "$_ACT_PRE" = "portal_upload" ] || [ "$_ACT_PRE" = "portal_audio_upload" ]; then
    [ "$CONTENT_LENGTH" -gt 15728640 ] && CONTENT_LENGTH=15728640
elif [ "$_ACT_PRE" = "users_import" ]; then
    # A url-encoded users.txt (colons/spaces expand to %XX) needs more room
    # than the default cap for any deployment beyond a handful of users.
    [ "$CONTENT_LENGTH" -gt 1048576  ] && CONTENT_LENGTH=1048576
else
    [ "$CONTENT_LENGTH" -gt 65536   ] && CONTENT_LENGTH=65536
fi
# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------
BB="busybox"
HDATA="/lmepisowifi/hotspot_data"
SESSION_DATA="/tmp/active_sessions.txt"
USERS_FILE="$HDATA/users.txt"
WHITELIST_FILE="$HDATA/whitelist.txt"

_unlock() { rm -f /tmp/hotspot_session.lock/pid 2>/dev/null; rmdir /tmp/hotspot_session.lock 2>/dev/null; }
_lock() {
    local i=0
    while ! mkdir /tmp/hotspot_session.lock 2>/dev/null; do
        # Only steal the lock once its holder is provably dead (see
        # lmehspt.sh's _lock for the full explanation) - a flat 5s wait was
        # force-breaking a live holder's lock under normal polling load and
        # letting two writers stomp the same USERS_FILE.tmp at once. This
        # must match the protocol used by coin_result.sh/login.sh/logout.sh/
        # status.sh/lmehspt.sh exactly (including writing our own pid below)
        # or THIS script's lock is the one that ends up looking "dead" to
        # them after just ~1s and gets stolen out from under it mid-write.
        if [ "$((i % 10))" -eq 0 ] && [ "$i" -gt 0 ]; then
            if [ "$i" -ge 300 ]; then
                $BB rm -f /tmp/hotspot_session.lock/pid 2>/dev/null
                rmdir /tmp/hotspot_session.lock 2>/dev/null
            else
                _HPID=$($BB cat /tmp/hotspot_session.lock/pid 2>/dev/null)
                if [ -z "$_HPID" ] || ! kill -0 "$_HPID" 2>/dev/null; then
                    $BB rm -f /tmp/hotspot_session.lock/pid 2>/dev/null
                    rmdir /tmp/hotspot_session.lock 2>/dev/null
                fi
            fi
        fi
        $BB sleep 0.1 2>/dev/null || sleep 0.1
        i=$((i + 1))
    done
    $BB echo $$ > /tmp/hotspot_session.lock/pid 2>/dev/null
    trap _unlock EXIT INT TERM
}

# Stages "${USERS_FILE}.tmp" with every line except the one starting "$1 ",
# WITHOUT committing it - callers that need to append a replacement line
# first (kick/add_time/reset_time all do) can do so before calling
# _users_file_commit. Refuses (returns 1, tmp file removed) if grep
# couldn't actually read USERS_FILE in the first place. `grep -v` exit
# status: 0 = some lines kept, 1 = every line was a genuine match (also
# what a truly-empty file returns - normal for a fresh/just-touched file),
# 2+ = read/access error. Without this check, a single transient flash
# read glitch produces an empty tmp file that then gets committed over
# USERS_FILE unconditionally, wiping every user's balance in one request.
# Call this INSIDE _lock.
_users_file_stage_excl() {
    local mac="$1" existed=0 rc=0
    [ -e "$USERS_FILE" ] && existed=1
    $BB grep -v "^${mac} " "$USERS_FILE" > "${USERS_FILE}.tmp" 2>/dev/null || rc=$?
    if [ "$existed" -eq 1 ] && [ "$rc" -gt 1 ]; then
        rm -f "${USERS_FILE}.tmp" 2>/dev/null
        logger -t lmehspt "users.txt: refused overwrite after read error (rc=$rc) - kept existing file" 2>/dev/null
        return 1
    fi
    return 0
}
# Same guard as _users_file_stage_excl above, but for VOUCHER_FILE (admin
# voucher add/delete). Without the existed/rc check, a transient flash read
# glitch here would produce an empty tmp file that then gets moved over
# VOUCHER_FILE unconditionally, deleting every voucher in the database in
# one request. Returns 1 (VOUCHER_FILE left untouched) on a genuine read
# error; caller must not report success in that case.
_voucher_file_replace_excl() {
    local code="$1" existed=0 rc=0
    [ -e "$VOUCHER_FILE" ] && existed=1
    $BB grep -v "^${code} " "$VOUCHER_FILE" > "${VOUCHER_FILE}.tmp" 2>/dev/null || rc=$?
    if [ "$existed" -eq 0 ] || [ "$rc" -le 1 ]; then
        $BB mv "${VOUCHER_FILE}.tmp" "$VOUCHER_FILE"
        # Force this out to flash now rather than leaving it to the page
        # cache's own timing - see the matching comment in login.sh.
        sync
        return 0
    fi
    rm -f "${VOUCHER_FILE}.tmp" 2>/dev/null
    logger -t lmehspt "vouchers.txt: refused overwrite after read error (rc=$rc) - kept existing file" 2>/dev/null
    return 1
}
# Same idea again, for NODEMCU_EXTRA_FILE (additional coin acceptor units).
# Rows are ID|TITLE|IP|MAC|PORT|PSK|ENABLED, so the match key is the leading
# "ID|" rather than a space-delimited code.
_nodemcu_file_replace_excl() {
    local id="$1" existed=0 rc=0
    [ -e "$NODEMCU_EXTRA_FILE" ] && existed=1
    $BB grep -v "^${id}|" "$NODEMCU_EXTRA_FILE" > "${NODEMCU_EXTRA_FILE}.tmp" 2>/dev/null || rc=$?
    if [ "$existed" -eq 0 ] || [ "$rc" -le 1 ]; then
        $BB mv "${NODEMCU_EXTRA_FILE}.tmp" "$NODEMCU_EXTRA_FILE"
        sync
        return 0
    fi
    rm -f "${NODEMCU_EXTRA_FILE}.tmp" 2>/dev/null
    logger -t lmehspt "nodemcus_extra.txt: refused overwrite after read error (rc=$rc) - kept existing file" 2>/dev/null
    return 1
}
# True if $1 (an IP) already belongs to some OTHER configured node than $2
# (pass the id being edited, or "0" on add when there's nothing to exclude
# yet). Catches the admin accidentally pointing two units at the same
# address, which would otherwise silently break DHCP/ARP/firewall for
# whichever one loses the race.
_nodemcu_ip_in_use() {
    local ip="$1" exclude="$2" n1ip
    n1ip="${NODEMCU_IP:-$(read_lmehspt_var NODEMCU_IP)}"
    [ "$exclude" != "1" ] && [ "$ip" = "$n1ip" ] && return 0
    [ -f "$NODEMCU_EXTRA_FILE" ] || return 1
    $BB awk -F'|' -v ip="$ip" -v ex="$exclude" \
        '$1!=ex && $3==ip {f=1} END{exit !f}' "$NODEMCU_EXTRA_FILE"
}
# Same idea, but for the paused-session update sites which filter with awk
# instead of grep (need to drop only the "$mac paused ..." line, keeping
# any active line for the same mac untouched - grep -v "^$mac " would wrongly
# drop both). Plain awk exits 0 whether or not any line matched, so unlike
# grep there's no "1 = legitimately nothing matched" case to allow through -
# any nonzero exit here reliably means awk couldn't process the file.
_users_file_stage_excl_paused() {
    local mac="$1" existed=0 rc=0
    [ -e "$USERS_FILE" ] && existed=1
    $BB awk -v m="$mac" '$1==m && $2=="paused"{next}{print}' "$USERS_FILE" > "${USERS_FILE}.tmp" 2>/dev/null || rc=$?
    if [ "$existed" -eq 1 ] && [ "$rc" -ne 0 ]; then
        rm -f "${USERS_FILE}.tmp" 2>/dev/null
        logger -t lmehspt "users.txt: refused overwrite after awk read error (rc=$rc) - kept existing file" 2>/dev/null
        return 1
    fi
    return 0
}
_users_file_commit() {
    $BB mv "${USERS_FILE}.tmp" "$USERS_FILE"
    # Rename is atomic/crash-consistent on ubifs, but that only guarantees
    # you never see a half-written file - it says nothing about whether
    # this specific write has actually reached the NAND yet vs. still
    # sitting dirty in the page cache. Force it out now so a power-cut
    # moments after an admin kick/add_time/remove_time/remove_user can't
    # silently roll this request back.
    sync
    # See the matching comment on _users_file_replace_excl in lmehspt.sh:
    # this tells the runtime self-heal that an empty USERS_FILE right now
    # is expected (e.g. an admin just removed the last/only user), not a
    # sign of corruption to restore from backup.
    if [ -s "$USERS_FILE" ]; then rm -f /tmp/hotspot_users_empty_expected 2>/dev/null; else : > /tmp/hotspot_users_empty_expected 2>/dev/null; fi
}

_fmt_secs() {
    # Guard against blank or empty variables
    local s="${1:-0}"
    
    # Strip negative signs if present
    s="${s#-}"
    
    # Force to 0 if containing non-numeric characters
    case "$s" in
        ""|*[!0-9]*) s=0 ;;
    esac

    local d=$(( s / 86400 )) 
    local h=$(( (s % 86400) / 3600 )) 
    local m=$(( (s % 3600) / 60 )) 
    
    if [ "$d" -gt 0 ]; then printf '%dd %dh %dm' "$d" "$h" "$m"
    elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
    else printf '%dm' "$m"; fi
}
VOUCHER_FILE="$HDATA/vouchers.txt"
NODEMCU_EXTRA_FILE="$HDATA/nodemcus_extra.txt"
NODEMCU_ORDER_FILE="$HDATA/nodemcus_order.txt"
# Drop a node id from the saved display-order file (best effort - the order
# file is advisory; nodemcus_get and coin.sh both re-filter it against the
# live set of ids, so a stale entry can never hide or duplicate a unit).
_order_remove_id() {
    [ -f "$NODEMCU_ORDER_FILE" ] || return 0
    $BB grep -vx "$1" "$NODEMCU_ORDER_FILE" > "${NODEMCU_ORDER_FILE}.tmp" 2>/dev/null \
        && $BB mv "${NODEMCU_ORDER_FILE}.tmp" "$NODEMCU_ORDER_FILE"
    rm -f "${NODEMCU_ORDER_FILE}.tmp" 2>/dev/null
}

# ── DHCP pool / NodeMCU IP helpers ──────────────────────────────────────────
# NodeMCU static IPs occupy the addresses BELOW the DHCP dynamic pool: from one
# past the gateway up to one before the pool start. e.g. gateway .1 + DHCP
# start .5  =>  usable NodeMCU IPs .2 .3 .4  (so at most 3 units).
_valid_ipv4() {
    printf '%s' "$1" | $BB awk -F. '
        NF!=4 { exit 1 }
        { for(i=1;i<=4;i++){ if($i!~/^[0-9]+$/ || $i+0>255) exit 1 } exit 0 }'
}
_dhcp_prefix()   { printf '%s' "${PORTAL_IP:-$(read_lmehspt_var PORTAL_IP)}" | $BB sed 's/\.[^.]*$//'; }
_dhcp_gw_octet() { printf '%s' "${PORTAL_IP:-$(read_lmehspt_var PORTAL_IP)}" | $BB sed 's/.*\.//'; }
_dhcp_start_octet() {
    _v="${DHCP_START:-$(read_lmehspt_var DHCP_START)}"
    case "$_v" in ''|*[!0-9]*) _v=5 ;; esac
    printf '%s' "$_v"
}
# Usable NodeMCU slot count = start - gateway - 1  (clamped at 0).
_nodemcu_pool_size() {
    _gw=$(_dhcp_gw_octet); _st=$(_dhcp_start_octet)
    _n=$(( _st - _gw - 1 )); [ "$_n" -lt 0 ] && _n=0
    printf '%s' "$_n"
}
# Usable NodeMCU IPs, ascending, one per line.
_nodemcu_pool_ips() {
    _pfx=$(_dhcp_prefix); _gw=$(_dhcp_gw_octet); _st=$(_dhcp_start_octet)
    _o=$(( _gw + 1 ))
    while [ "$_o" -lt "$_st" ]; do printf '%s.%s\n' "$_pfx" "$_o"; _o=$(( _o + 1 )); done
}
# IPs already taken by configured NodeMCUs (primary + extras), one per line.
_nodemcu_used_ips() {
    _pip="${NODEMCU_IP:-$(read_lmehspt_var NODEMCU_IP)}"
    [ -n "$_pip" ] && printf '%s\n' "$_pip"
    [ -f "$NODEMCU_EXTRA_FILE" ] && $BB awk -F'|' '$1 ~ /^[0-9]+$/ && $3!="" {print $3}' "$NODEMCU_EXTRA_FILE"
}
# Lowest usable pool IP not in use; empty when the pool is full.
_next_free_nodemcu_ip() {
    _used=$(_nodemcu_used_ips)
    for _ip in $(_nodemcu_pool_ips); do
        printf '%s\n' "$_used" | $BB grep -qx "$_ip" || { printf '%s' "$_ip"; return 0; }
    done
}
# Count of configured NodeMCUs (primary counts only when it has an IP).
_nodemcu_count() {
    _c=0
    _pip="${NODEMCU_IP:-$(read_lmehspt_var NODEMCU_IP)}"
    [ -n "$_pip" ] && _c=1
    [ -f "$NODEMCU_EXTRA_FILE" ] && _c=$(( _c + $($BB awk -F'|' '$1 ~ /^[0-9]+$/ {n++} END{print n+0}' "$NODEMCU_EXTRA_FILE") ))
    printf '%s' "$_c"
}
# Reassign every NodeMCU a pool IP (lowest-first, primary then extras order) so
# they stay valid after the pool moves. Caller must have confirmed count <=
# pool size and set the in-memory PORTAL_IP / DHCP_START to the NEW values.
_dhcp_renormalize_ips() {
    set -- $(_nodemcu_pool_ips)
    _i=1
    _pip="${NODEMCU_IP:-$(read_lmehspt_var NODEMCU_IP)}"
    if [ -n "$_pip" ]; then
        eval "_new=\${$_i}"
        save_coin_env_var NODEMCU_IP "$_new"; set_lmehspt_var NODEMCU_IP "$_new"; set_globals_var NODEMCU_IP "$_new"
        _i=$(( _i + 1 ))
    fi
    if [ -f "$NODEMCU_EXTRA_FILE" ]; then
        : > /tmp/nm_renorm.tmp
        while IFS='|' read -r _rid _rt _rip _rm _rp _rk _re; do
            case "$_rid" in ''|*[!0-9]*) continue ;; esac
            eval "_new=\${$_i}"
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$_rid" "$_rt" "$_new" "$_rm" "$_rp" "$_rk" "$_re" >> /tmp/nm_renorm.tmp
            _i=$(( _i + 1 ))
        done < "$NODEMCU_EXTRA_FILE"
        $BB mv /tmp/nm_renorm.tmp "$NODEMCU_EXTRA_FILE"; sync
    fi
}
LMEHSPT="/lmepisowifi/lmehspt.sh"
COIN_CONFIG="/tmp/coin_config.env"
GLOBALS_ENV="/lmepisowifi/globals.env"

ok_json()  { printf "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n%s" "$1"; exit 0; }
err_json() { printf "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n{\"ok\":false,\"error\":\"%s\"}" "$1"; exit 0; }

# Read a var, preferring globals.env (persistent, PRESERVED across OTA) over
# lmehspt.sh's top-of-file hardcoded default (a COMPONENT wholesale-replaced
# by every OTA — see ota.sh's COMPONENTS list). globals.env is checked first
# and used whenever the key exists there at all, even set to "" — an empty
# value there means the admin deliberately cleared it (e.g. nodemcu_del
# blanking NODEMCU_IP/NODEMCU_MAC/COIN_PSK) and must NOT be second-guessed by
# falling back to lmehspt.sh's shipped default, or an OTA that refreshes
# lmehspt.sh would silently resurrect the deleted primary NodeMCU with
# GitHub's default IP/MAC/PSK. lmehspt.sh is only consulted when the key has
# never been written to globals.env at all (pre-first-seed, or a key with no
# default.env entry).
read_lmehspt_var() {
    if $BB grep -q "^$1=" "$GLOBALS_ENV" 2>/dev/null; then
        $BB grep -m1 "^$1=" "$GLOBALS_ENV" 2>/dev/null \
            | $BB sed 's/^[^=]*="\(.*\)"/\1/' \
            | $BB sed "s/^[^=]*='\(.*\)'/\1/" \
            | $BB sed 's/^[^=]*=\(.*\)/\1/'
        return
    fi
    $BB grep -m1 "^$1=" "$LMEHSPT" 2>/dev/null \
        | $BB sed 's/^[^=]*="\(.*\)"/\1/' \
        | $BB sed "s/^[^=]*='\(.*\)'/\1/" \
        | $BB sed 's/^[^=]*=\(.*\)/\1/'
}

# Safely rewrite a var in lmehspt.sh
set_lmehspt_var() {
    local var="$1" val="$2"
    local esc
    esc=$(printf '%s' "$val" | $BB sed 's/[\/&]/\\&/g')
    $BB sed -i "s|^${var}=.*|${var}=\"${esc}\"|" "$LMEHSPT"
}

# Write / update a key in coin_config.env (runtime hot-reload)
save_coin_env_var() {
    local var="$1" val="$2"
    touch "$COIN_CONFIG"
    $BB grep -v "^${var}=" "$COIN_CONFIG" > /tmp/coin_cfg_upd.tmp 2>/dev/null
    echo "${var}=\"${val}\"" >> /tmp/coin_cfg_upd.tmp
    $BB mv /tmp/coin_cfg_upd.tmp "$COIN_CONFIG"
}

load_coin_env() { [ -f "$COIN_CONFIG" ] && . "$COIN_CONFIG"; }

# Write / update a key in /lmepisowifi/globals.env (persistent flash store).
# Adds the key if absent; replaces it if present.  Same sed pattern as
# set_lmehspt_var so the two files stay in sync after every UI save.
set_globals_var() {
    local var="$1" val="$2"
    local esc
    esc=$(printf '%s' "$val" | $BB sed 's/[\\/&]/\\&/g')
    if $BB grep -q "^${var}=" "$GLOBALS_ENV" 2>/dev/null; then
        $BB sed -i "s|^${var}=.*|${var}=\"${esc}\"|" "$GLOBALS_ENV"
    else
        printf '%s="%s"\n' "$var" "$val" >> "$GLOBALS_ENV"
    fi
}

# Is the hotspot watchdog currently alive?
hotspot_running() {
    [ -f /tmp/hotspot_watchdog.pid ] || return 1
    local pid; pid=$(cat /tmp/hotspot_watchdog.pid)
    $BB kill -0 "$pid" 2>/dev/null
}

esc_json() { printf '%s' "$1" | $BB sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Resolve a wlan* netdev name to its WLAN(1)_MBSSIB_TBL row and report
# whether wlanbasic has it disabled. Naming per lmehspt.sh/wan-repurpose.cgi:
#   wlan0 / wlan1        → main AP   (idx 0)
#   wlan{0,1}-vap0..vap3 → VAPs      (idx 1-4)
#   wlan{0,1}-vxd        → repeater  (idx 5)
# Echoes "1" (disabled) or "0" (enabled); unknown/non-wlan names → "0".
wlan_iface_disabled() {
    case "$1" in
        wlan0)      WTBL="WLAN_MBSSIB_TBL";  WIDX=0 ;;
        wlan0-vap0) WTBL="WLAN_MBSSIB_TBL";  WIDX=1 ;;
        wlan0-vap1) WTBL="WLAN_MBSSIB_TBL";  WIDX=2 ;;
        wlan0-vap2) WTBL="WLAN_MBSSIB_TBL";  WIDX=3 ;;
        wlan0-vap3) WTBL="WLAN_MBSSIB_TBL";  WIDX=4 ;;
        wlan0-vxd)  WTBL="WLAN_MBSSIB_TBL";  WIDX=5 ;;
        wlan1)      WTBL="WLAN1_MBSSIB_TBL"; WIDX=0 ;;
        wlan1-vap0) WTBL="WLAN1_MBSSIB_TBL"; WIDX=1 ;;
        wlan1-vap1) WTBL="WLAN1_MBSSIB_TBL"; WIDX=2 ;;
        wlan1-vap2) WTBL="WLAN1_MBSSIB_TBL"; WIDX=3 ;;
        wlan1-vap3) WTBL="WLAN1_MBSSIB_TBL"; WIDX=4 ;;
        wlan1-vxd)  WTBL="WLAN1_MBSSIB_TBL"; WIDX=5 ;;
        *) printf '0'; return ;;
    esac
    WDIS=$(mib get "${WTBL}.${WIDX}.wlanDisabled" 2>/dev/null \
        | $BB grep "=" | $BB cut -d'=' -f2- | $BB tr -d '\r\n')
    [ -z "$WDIS" ] && WDIS=1
    printf '%s' "$WDIS"
}

# Reports whether a wlan* netdev is currently in client/STA mode rather than
# AP mode, per the same wlanMode convention wan-repurpose.cgi reads:
#   Main AP (wlan0/wlan1, idx 0): wlanMode=1 means infrastructure client.
#   VXD (wlan{0,1}-vxd, idx 5):   inherently the client/repeater interface —
#                                 always treated as client mode.
#   VAPs (wlan{0,1}-vap0..vap3):  AP-mode only, never client mode.
# Echoes "1" (client mode) or "0" (AP mode); unknown/non-wlan names → "0".
wlan_iface_is_client() {
    case "$1" in
        wlan0)  CTBL="WLAN_MBSSIB_TBL"  ;;
        wlan1)  CTBL="WLAN1_MBSSIB_TBL" ;;
        wlan0-vxd|wlan1-vxd) printf '1'; return ;;
        *) printf '0'; return ;;
    esac
    CMODE=$(mib get "${CTBL}.0.wlanMode" 2>/dev/null \
        | $BB grep "=" | $BB cut -d'=' -f2- | $BB tr -d '\r\n')
    [ -z "$CMODE" ] && CMODE=0
    printf '%s' "$CMODE"
}

# General-purpose application/x-www-form-urlencoded decoder.
# Decodes ANY %XX sequence (not a hardcoded subset) plus + as space.
# Verified under busybox awk: spaces encoded as %20 decode correctly;
# a bare % not followed by two hex digits passes through unchanged.
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

# ---------------------------------------------------------------
# Route on QUERY_STRING action
# ---------------------------------------------------------------
QS="$QUERY_STRING"

# ================================================================
# GET ?action=config_get
# Returns all config vars (coin_config.env takes priority over lmehspt.sh)
# ================================================================
if echo "$QS" | $BB grep -q "action=config_get"; then
    load_coin_env

    GR="${GLOBAL_RATE:-$(read_lmehspt_var GLOBAL_RATE)}"
    PUR="${PER_USER_RATE:-$(read_lmehspt_var PER_USER_RATE)}"
    PUB="${PER_USER_BURST:-$(read_lmehspt_var PER_USER_BURST)}"
    UAR="${UNAUTH_RATE:-$(read_lmehspt_var UNAUTH_RATE)}"
    IT="${INACTIVITY_TIMEOUT:-$(read_lmehspt_var INACTIVITY_TIMEOUT)}"
    AP="${AUTO_PAUSE_ENABLED:-$(read_lmehspt_var AUTO_PAUSE_ENABLED)}"
    AP_BOOL="false"; [ "${AP:-1}" = "1" ] && AP_BOOL="true"
    CE="${COIN_ENABLED:-$(read_lmehspt_var COIN_ENABLED)}"
    NIP="${NODEMCU_IP:-$(read_lmehspt_var NODEMCU_IP)}"
    NMC="${NODEMCU_MAC:-$(read_lmehspt_var NODEMCU_MAC)}"
    NPT="${NODEMCU_PORT:-$(read_lmehspt_var NODEMCU_PORT)}"
    NTL="${NODEMCU_1_TITLE:-$(read_lmehspt_var NODEMCU_1_TITLE)}"
    NEN="${NODEMCU_1_ENABLED:-$(read_lmehspt_var NODEMCU_1_ENABLED)}"
    NEN_BOOL="true"; [ "${NEN:-1}" = "0" ] && NEN_BOOL="false"
    CT="${COIN_TIMEOUT:-$(read_lmehspt_var COIN_TIMEOUT)}"
    CR="${COIN_RATES:-$(read_lmehspt_var COIN_RATES)}"
    CPSK="${COIN_PSK:-$(read_lmehspt_var COIN_PSK)}"
    CST="${COIN_STRIKE_THRESHOLD:-$(read_lmehspt_var COIN_STRIKE_THRESHOLD)}"
    CCD="${COIN_COOLDOWN:-$(read_lmehspt_var COIN_COOLDOWN)}"
    PIP="${PORTAL_IP:-$(read_lmehspt_var PORTAL_IP)}"
    PPT="${PORTAL_PORT:-$(read_lmehspt_var PORTAL_PORT)}"
    HBR="${HOTSPOT_BR:-$(read_lmehspt_var HOTSPOT_BR)}"
    HIF="${HOTSPOT_INTERFACES:-$(read_lmehspt_var HOTSPOT_INTERFACES)}"
    AT="${ANTI_TETHER:-$(read_lmehspt_var ANTI_TETHER)}"
    AT_BOOL="false"; [ "${AT:-0}" = "1" ] && AT_BOOL="true"
    LI="${LAN_ISOLATE:-$(read_lmehspt_var LAN_ISOLATE)}"
    LI_BOOL="true"; [ "${LI:-1}" = "0" ] && LI_BOOL="false"
    MRF="${MAC_RANDOMIZATION_FIX:-$(read_lmehspt_var MAC_RANDOMIZATION_FIX)}"
    MRF_BOOL="true"; [ "${MRF:-1}" = "0" ] && MRF_BOOL="false"

    HSP_RUNNING="false"; hotspot_running && HSP_RUNNING="true"
    COIN_ON="false"; [ -f /tmp/coin_enabled ] && COIN_ON="true"

    ok_json "{\"ok\":true,
\"global_rate\":\"$(esc_json "$GR")\",
\"per_user_rate\":\"$(esc_json "$PUR")\",
\"per_user_burst\":\"$(esc_json "$PUB")\",
\"unauth_rate\":\"$(esc_json "$UAR")\",
\"inactivity_timeout\":\"$(esc_json "$IT")\",
\"auto_pause_enabled\":$AP_BOOL,
\"coin_enabled\":\"$(esc_json "$CE")\",
\"coin_on\":$COIN_ON,
\"nodemcu_ip\":\"$(esc_json "$NIP")\",
\"nodemcu_mac\":\"$(esc_json "$NMC")\",
\"nodemcu_port\":\"$(esc_json "$NPT")\",
\"nodemcu_1_title\":\"$(esc_json "$NTL")\",
\"nodemcu_1_enabled\":$NEN_BOOL,
\"coin_timeout\":\"$(esc_json "$CT")\",
\"coin_rates\":\"$(esc_json "$CR")\",
\"coin_psk\":\"$(esc_json "$CPSK")\",
\"coin_strike_threshold\":\"$(esc_json "$CST")\",
\"coin_cooldown\":\"$(esc_json "$CCD")\",
\"portal_ip\":\"$(esc_json "$PIP")\",
\"portal_port\":\"$(esc_json "$PPT")\",
\"hotspot_br\":\"$(esc_json "$HBR")\",
\"hotspot_interfaces\":\"$(esc_json "$HIF")\",
\"anti_tether\":$AT_BOOL,
\"lan_isolate\":$LI_BOOL,
\"mac_randomization_fix\":$MRF_BOOL,
\"hotspot_running\":$HSP_RUNNING}"
fi

# ================================================================
# POST ?action=config_set  (form-encoded body, any subset of config keys)
# Writes to coin_config.env AND lmehspt.sh.
# Uses application/x-www-form-urlencoded — same convention as lme.cgi and
# wlanmac.cgi — instead of hand-rolled JSON regex that breaks on " or \ in PSK.
# ================================================================
if echo "$QS" | $BB grep -q "action=config_set"; then
    read -n "$CONTENT_LENGTH" POST_DATA

    # form-encoded field extractor — uses urldecode() for full %XX support
    fget() {
        printf '%s' "$POST_DATA" \
            | $BB tr '&' '\n' \
            | $BB grep "^$1=" \
            | $BB sed 's/^[^=]*=//' \
            | urldecode \
            | head -1
    }

    apply_if() {
        local key="$1" val="$2"
        [ -z "$val" ] && return
        save_coin_env_var "$key" "$val"
        set_lmehspt_var "$key" "$val"
        set_globals_var  "$key" "$val"
    }

    # Capture old NodeMCU values before overwriting so we can detect a change
    OLD_NIP=$(read_lmehspt_var NODEMCU_IP)
    OLD_NMC=$(read_lmehspt_var NODEMCU_MAC)
    OLD_NEN=$(read_lmehspt_var NODEMCU_1_ENABLED)

    apply_if "GLOBAL_RATE"         "$(fget global_rate)"
    apply_if "PER_USER_RATE"       "$(fget per_user_rate)"
    apply_if "PER_USER_BURST"      "$(fget per_user_burst)"
    apply_if "UNAUTH_RATE"         "$(fget unauth_rate)"
    apply_if "INACTIVITY_TIMEOUT"  "$(fget inactivity_timeout)"
    apply_if "AUTO_PAUSE_ENABLED"  "$(fget auto_pause_enabled)"
    apply_if "NODEMCU_IP"          "$(fget nodemcu_ip)"
    apply_if "NODEMCU_MAC"         "$(fget nodemcu_mac)"
    apply_if "NODEMCU_PORT"        "$(fget nodemcu_port)"
    apply_if "NODEMCU_1_TITLE"     "$(fget nodemcu_1_title)"
    apply_if "NODEMCU_1_ENABLED"   "$(fget nodemcu_1_enabled)"
    apply_if "COIN_TIMEOUT"        "$(fget coin_timeout)"
    apply_if "COIN_RATES"          "$(fget coin_rates)"
    apply_if "COIN_PSK"            "$(fget coin_psk)"
    apply_if "COIN_STRIKE_THRESHOLD" "$(fget coin_strike_threshold)"
    apply_if "COIN_COOLDOWN"       "$(fget coin_cooldown)"
    apply_if "PORTAL_IP"           "$(fget portal_ip)"
    apply_if "PORTAL_PORT"         "$(fget portal_port)"

    # Restart DHCP when the NodeMCU static-lease entry changed OR it was
    # enabled/disabled — start_dhcp() in lmehspt.sh bakes NODEMCU_IP/MAC (and
    # now whether the lease is emitted at all) into udhcpd.conf once; without
    # a restart the change won't take effect until the next hotspot start.
    NEW_NIP=$(read_lmehspt_var NODEMCU_IP)
    NEW_NMC=$(read_lmehspt_var NODEMCU_MAC)
    NEW_NEN=$(read_lmehspt_var NODEMCU_1_ENABLED)
    if [ "$OLD_NIP" != "$NEW_NIP" ] || [ "$OLD_NMC" != "$NEW_NMC" ] || [ "${OLD_NEN:-1}" != "${NEW_NEN:-1}" ]; then
        [ -f /tmp/hotspot_dhcp.pid ] && kill -9 "$(cat /tmp/hotspot_dhcp.pid)" 2>/dev/null
        load_coin_env
        LMEHSPT_LIB_ONLY=1
        . /lmepisowifi/lmehspt.sh --lib
        # busybox udhcpd re-issues whatever a MAC's leases-file entry already
        # says regardless of a freshly (re)written static_lease line — wipe
        # its memory so the restarted daemon has no stale record to fall
        # back on. Same fix apply_portal_ip_change already relies on for
        # subnet changes; this is the same class of staleness on a MAC swap.
        rm -f /tmp/udhcpd.leases
        start_dhcp

        # Flush the kernel's ARP/neighbor cache for the old and new NodeMCU
        # IPs. coin_result.sh's Guard 2 authenticates every coin-grant POST
        # by looking up who currently owns NODEMCU_IP in /proc/net/arp.
        # Swapping in a new NodeMCU (new MAC, same IP) leaves a STALE entry
        # pointing at the OLD device's MAC — and unlike a missing entry, a
        # stale-but-present one is never re-resolved on its own (Guard 2
        # only re-pings on a cache miss, not a mismatch), so every grant
        # from the new device gets silently rejected until the kernel
        # eventually garbage-collects the entry or the box reboots. Deleting
        # it here forces a genuine cache miss so the very next request
        # re-resolves the correct MAC immediately instead of binding on reboot.
        ip neigh del "$OLD_NIP" dev "$HOTSPOT_BR" 2>/dev/null
        $BB arp -d "$OLD_NIP" 2>/dev/null
        if [ "$NEW_NIP" != "$OLD_NIP" ]; then
            ip neigh del "$NEW_NIP" dev "$HOTSPOT_BR" 2>/dev/null
            $BB arp -d "$NEW_NIP" 2>/dev/null
        fi
        # Force the device off its current association so it re-DHCPs against
        # the just-restarted daemon right away instead of only picking up the
        # new static lease whenever its own renewal timer next fires.
        kick_sta_mac "$NEW_NMC"
        # Proactively re-resolve so the cache already reflects the new device
        # by the time it makes its first request, rather than relying solely
        # on Guard 2's own on-demand ping-and-retry.
        ping -c 1 -W 1 "$NEW_NIP" >/dev/null 2>&1
    fi
    touch /tmp/hotspot_qos_reload
    ok_json "{\"ok\":true}"
fi

# ================================================================
# POST ?action=qos_apply
# Signals the watchdog to rebuild QoS with the freshly-saved rates.
# Using a trigger file (rather than deleting qdiscs directly from the CGI)
# ensures the watchdog always uses the correct WAN_INT — which may differ
# from the default br0 when the repurpose-as-WAN feature is active.
# The watchdog detects the file on its next tick (≤ 1s) and calls
# setup_qos() + restore_qos_sessions() with the updated coin_config.env.
# ================================================================
if echo "$QS" | $BB grep -q "action=qos_apply"; then
    touch /tmp/hotspot_qos_reload
    ok_json "{\"ok\":true,\"msg\":\"QoS reload queued — rates active within 2s\"}"
fi

# ================================================================
# POST ?action=hotspot_start
# Launches lmehspt.sh in background; marks HOTSPOT_ENABLED=1
# ================================================================
if echo "$QS" | $BB grep -q "action=hotspot_start"; then
    if hotspot_running; then
        ok_json "{\"ok\":true,\"running\":true,\"msg\":\"already running\"}"
    fi
    set_lmehspt_var "HOTSPOT_ENABLED" "1"
    save_coin_env_var "HOTSPOT_ENABLED" "1"
    /lmepisowifi/lmehspt.sh >/tmp/lmehspt_start.log 2>&1 &
    # Poll for the watchdog PID file instead of a fixed sleep — wait_for_wlan_ready
    # can block 90-180s at first boot, so sleep 2 would report false "not running"
    # and risk a second concurrent start if the user clicks the button again.
    # We report "starting" when still not up after 15s so the UI toast is honest.
    _waited=0
    while [ $_waited -lt 15 ]; do
        hotspot_running && break
        $BB sleep 1
        _waited=$(( _waited + 1 ))
    done
    RUNNING="false"; hotspot_running && RUNNING="true"
    MSG="started"
    [ "$RUNNING" = "false" ] && MSG="starting — WLAN still initialising, check again in a moment"
    ok_json "{\"ok\":true,\"running\":$RUNNING,\"msg\":\"$MSG\"}"
fi

# ================================================================
# POST ?action=hotspot_stop
# Kills the watchdog, tears down iptables/tc, marks HOTSPOT_ENABLED=0
# ================================================================
if echo "$QS" | $BB grep -q "action=hotspot_stop"; then
    set_lmehspt_var "HOTSPOT_ENABLED" "0"
    save_coin_env_var "HOTSPOT_ENABLED" "0"

    # Kill watchdog
    if [ -f /tmp/hotspot_watchdog.pid ]; then
        kill -9 "$(cat /tmp/hotspot_watchdog.pid)" 2>/dev/null
        rm -f /tmp/hotspot_watchdog.pid
    fi
    # Kill DHCP server
    if [ -f /tmp/hotspot_dhcp.pid ]; then
        kill -9 "$(cat /tmp/hotspot_dhcp.pid)" 2>/dev/null
        rm -f /tmp/hotspot_dhcp.pid
    fi
    # Kill portal httpd
    load_coin_env
    PIP="${PORTAL_IP:-192.168.99.1}"
    PPT="${PORTAL_PORT:-808}"
    for pid in $($BB ps | $BB grep httpd | $BB grep -v grep | $BB grep -F "$PIP:$PPT" | $BB awk '{print $1}'); do
        kill -9 "$pid" 2>/dev/null
    done

    # Source lmehspt.sh in --lib mode to get all its functions without
    # running the main boot sequence, then call cleanup_old_hotspot() directly.
    # This tears down tc on both WAN_INT and HOTSPOT_BR, removes iptables chains
    # (HOTSPOT nat + HOTSPOT_FWD filter + mangle marks), kills DHCP, shuts down
    # the portal httpd, brings down br1, and returns enslaved interfaces to br0
    # — exactly the same logic the script itself uses, with zero drift risk.
    LMEHSPT_LIB_ONLY=1
    . /lmepisowifi/lmehspt.sh --lib
    cleanup_old_hotspot

    ok_json "{\"ok\":true,\"running\":false}"
fi

# ================================================================
# GET ?action=sessions
# ================================================================
if echo "$QS" | $BB grep -q "action=sessions"; then
    _lock
    UPTIME=$($BB awk '{print int($1)}' /proc/uptime)
    OUT="["; SEP=""
    if [ -f "$SESSION_DATA" ]; then
        while read -r mac expiry total; do
            [ -n "$mac" ] || continue
            rem=$(( expiry - UPTIME ))
            [ "$rem" -le 0 ] && continue
            [ -z "$total" ] && total=$rem
            used=$(( total - rem )); [ "$used" -lt 0 ] && used=0
            ip=""
            [ -f /tmp/hotspot_ip_map.txt ] && ip=$($BB grep "^$mac " /tmp/hotspot_ip_map.txt | $BB awk '{print $2}' | head -1)
            [ -z "$ip" ] && ip=$($BB awk -v m="$mac" '$4==m{print $1;exit}' /proc/net/arp 2>/dev/null)
            OUT="${OUT}${SEP}{\"mac\":\"$mac\",\"ip\":\"${ip:-?}\",\"remaining\":$rem,\"total\":$total,\"used\":$used,\"paused\":false}"
            SEP=","
        done < "$SESSION_DATA"
    fi
    if [ -f "$USERS_FILE" ]; then
        while read -r mac status rem total fmt; do
            [ -n "$mac" ] && [ "$status" = "paused" ] || continue
            [ -z "$total" ] && total=$rem
            used=$(( total - rem )); [ "$used" -lt 0 ] && used=0
            ip=$($BB awk -v m="$mac" '$4==m{print $1;exit}' /proc/net/arp 2>/dev/null)
            OUT="${OUT}${SEP}{\"mac\":\"$mac\",\"ip\":\"${ip:-?}\",\"remaining\":$rem,\"total\":$total,\"used\":$used,\"paused\":true}"
            SEP=","
        done < "$USERS_FILE"
    fi
    _unlock
    ok_json "${OUT}]"
fi

# ================================================================
# POST ?action=kick   body: mac=xx:xx:xx:xx:xx:xx
# ================================================================
if echo "$QS" | $BB grep -q "action=kick"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    # The browser sends mac=encodeURIComponent("aa:bb:..") so the colons arrive
    # as %3A. Decode it (urldecode) before matching, otherwise the literal
    # "aa%3abb%3a.." never matches the colon-form MAC stored in the session
    # files / ip_map and the kick silently no-ops. tr -cd also strips any stray
    # chars so the value is safe to use in grep regex and iptables --mac-source.
    MAC=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*mac=\([^&]*\).*/\1/p' | urldecode | $BB tr 'A-Z' 'a-z' | $BB tr -cd 'a-f0-9:')
    [ -z "$MAC" ] && err_json "missing_mac"

    ACTIVITY_FILE="/tmp/hotspot_activity.txt"
    UPTIME=$($BB awk '{print int($1)}' /proc/uptime)
    PAUSED="false"

    _lock
    # Kick == PAUSE: move the device out of RAM active and into the flash master database
    # as paused with its REMAINING time preserved.
    if [ -f "$SESSION_DATA" ] && $BB grep -q "^$MAC " "$SESSION_DATA"; then
        LINE=$($BB grep "^$MAC " "$SESSION_DATA" | head -1)
        K_EXP=$(printf '%s' "$LINE" | $BB awk '{print $2}')
        K_TOT=$(printf '%s' "$LINE" | $BB awk '{print $3}')
        REM=$(( K_EXP - UPTIME )); [ "$REM" -lt 0 ] && REM=0
        [ -z "$K_TOT" ] && K_TOT=$REM

        # remove from active
        $BB grep -v "^$MAC " "$SESSION_DATA" > /tmp/kick_s.tmp; $BB mv /tmp/kick_s.tmp "$SESSION_DATA"

        # add/replace in master db as paused
        mkdir -p "$HDATA"; touch "$USERS_FILE"
        if _users_file_stage_excl "$MAC"; then
            [ "$REM" -gt 0 ] && echo "$MAC paused $REM $K_TOT $(_fmt_secs "$REM")" >> "${USERS_FILE}.tmp"
            _users_file_commit
        fi
        PAUSED="true"
    fi
    _unlock

    # Cut internet access immediately (whether they were active or already paused)
    iptables -t nat    -D HOTSPOT     -m mac --mac-source "$MAC" -j RETURN 2>/dev/null
    iptables -t filter -D HOTSPOT_FWD -m mac --mac-source "$MAC" -j ACCEPT 2>/dev/null

    # Reset activity bookkeeping + ip map (their paused entry in $PAUSED_DATA stays)
    [ -f "$ACTIVITY_FILE" ] && { $BB grep -v "^$MAC " "$ACTIVITY_FILE" > /tmp/kick_a.tmp 2>/dev/null; $BB mv /tmp/kick_a.tmp "$ACTIVITY_FILE"; }
    [ -f /tmp/hotspot_ip_map.txt ] && { $BB grep -v "^$MAC " /tmp/hotspot_ip_map.txt > /tmp/kick_i.tmp; $BB mv /tmp/kick_i.tmp /tmp/hotspot_ip_map.txt; }

    # Fire the "session paused" alert — admin kick is a MANUAL pause.
    # Only when a session was actually moved to paused (REM > 0). Uses the
    # session_paused event key so it can be muted from the notifications UI.
    if [ "$PAUSED" = "true" ]; then
        . /lmepisowifi/hotspot/notify_templates.sh
        _P_ACTIVE=$($BB grep -c '.' "$SESSION_DATA" 2>/dev/null)
        [ -n "$_P_ACTIVE" ] || _P_ACTIVE=0
        _P_MSG=$(tpl_render "$TPL_SESSION_PAUSED" \
            reason "Manually" \
            remainingtime "$(_fmt_secs "$REM")" \
            totaltime "$(_fmt_secs "$K_TOT")" \
            mac "$MAC" \
            activeusrcount "${_P_ACTIVE:-0}")
        ( /lmepisowifi/hotspot/notify.sh "$_P_MSG" "" session_paused "$MAC" >/dev/null 2>&1 </dev/null & )
    fi

    ok_json "{\"ok\":true,\"mac\":\"$MAC\",\"paused\":$PAUSED}"
fi

# ================================================================
# POST ?action=add_time   body: mac=xx:xx:..&minutes=N
# Extends an active or paused session by N minutes. If the device has
# no session, a fresh active one is created and its firewall rules opened.
# ================================================================
if echo "$QS" | $BB grep -q "action=add_time"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    MAC=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*mac=\([^&]*\).*/\1/p' | urldecode | $BB tr 'A-Z' 'a-z' | $BB tr -cd 'a-f0-9:')
    MINS=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*minutes=\([^&]*\).*/\1/p' | $BB tr -cd '0-9')
    [ -z "$MAC" ]  && err_json "missing_mac"
    [ -z "$MINS" ] && err_json "missing_minutes"
    [ "$MINS" -le 0 ] 2>/dev/null && err_json "bad_minutes"
    ADD=$(( MINS * 60 ))
    UPTIME=$($BB awk '{print int($1)}' /proc/uptime)
    FOUND=0

    _lock
    # Active session -> update RAM and Flash
    if [ -f "$SESSION_DATA" ] && $BB grep -q "^$MAC " "$SESSION_DATA"; then
        $BB awk -v m="$MAC" -v add="$ADD" -v up="$UPTIME" '
            $1==m {
                xe=$2; tot=$3
                if (xe=="") xe=up
                if (tot=="") tot=xe-up
                base=(xe>up?xe:up)
                print m, base+add, tot+add
                next
            }
            { print }
        ' "$SESSION_DATA" > /tmp/at_s.tmp && $BB mv /tmp/at_s.tmp "$SESSION_DATA"
        
        # Sync Flash
        NEW_EXP=$($BB grep "^$MAC " "$SESSION_DATA" | $BB awk '{print $2}')
        NEW_TOT=$($BB grep "^$MAC " "$SESSION_DATA" | $BB awk '{print $3}')
        REM=$(( NEW_EXP - UPTIME ))
        if _users_file_stage_excl "$MAC"; then
            echo "$MAC active $REM $NEW_TOT $(_fmt_secs "$REM")" >> "${USERS_FILE}.tmp"
            _users_file_commit
        fi
        FOUND=1
        
    # Paused session in users.txt -> update Flash
    elif [ -f "$USERS_FILE" ] && $BB grep -q "^$MAC paused " "$USERS_FILE"; then
        OLD_P=$($BB grep "^$MAC paused " "$USERS_FILE" | head -1)
        P_REM=$($BB echo "$OLD_P" | $BB awk '{print $3}')
        P_TOT=$($BB echo "$OLD_P" | $BB awk '{print $4}')
        [ -z "$P_TOT" ] && P_TOT=$P_REM
        N_REM=$(( P_REM + ADD ))
        N_TOT=$(( P_TOT + ADD ))
        
        if _users_file_stage_excl_paused "$MAC"; then
            echo "$MAC paused $N_REM $N_TOT $(_fmt_secs "$N_REM")" >> "${USERS_FILE}.tmp"
            _users_file_commit
        fi
        FOUND=1
    fi

    # No existing session -> create a fresh active one
    if [ "$FOUND" -eq 0 ]; then
        mkdir -p "$HDATA"; touch "$SESSION_DATA"; touch "$USERS_FILE"
        echo "$MAC $(( UPTIME + ADD )) $ADD" >> "$SESSION_DATA"
        
        if _users_file_stage_excl "$MAC"; then
            echo "$MAC active $ADD $ADD $(_fmt_secs "$ADD")" >> "${USERS_FILE}.tmp"
            _users_file_commit
        fi
        
        iptables -t nat    -I HOTSPOT     1 -m mac --mac-source "$MAC" -j RETURN 2>/dev/null
        iptables -t filter -I HOTSPOT_FWD 1 -m mac --mac-source "$MAC" -j ACCEPT 2>/dev/null
    fi
    _unlock

    CREATED="false"; [ "$FOUND" -eq 0 ] && CREATED="true"
    ok_json "{\"ok\":true,\"mac\":\"$MAC\",\"added\":$ADD,\"created\":$CREATED}"
fi

# ================================================================
# POST ?action=create_session   body: mac=xx:xx:xx:xx:xx:xx&minutes=N
# Manual admin entry: creates a brand-new ACTIVE session for a MAC
# that has no session yet. Unlike add_time (which happily extends or
# creates), this REFUSES outright if the MAC already has an active or
# paused session - use +Time on the existing row for that instead.
# ================================================================
if echo "$QS" | $BB grep -q "action=create_session"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    MAC=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*mac=\([^&]*\).*/\1/p' | urldecode | $BB tr 'A-Z' 'a-z' | $BB tr -cd 'a-f0-9:')
    MINS=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*minutes=\([^&]*\).*/\1/p' | $BB tr -cd '0-9')
    [ -z "$MAC" ]  && err_json "missing_mac"
    [ -z "$MINS" ] && err_json "missing_minutes"
    [ "$MINS" -le 0 ] 2>/dev/null && err_json "bad_minutes"

    # Manual entry has no ARP/DHCP source to sanity-check against (every
    # other action here only ever sees MACs the router itself already
    # observed), so require a strict xx:xx:xx:xx:xx:xx shape before it's
    # allowed anywhere near iptables --mac-source or the session files.
    case "$MAC" in
        [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
        *) err_json "bad_mac" ;;
    esac

    ADD=$(( MINS * 60 ))
    UPTIME=$($BB awk '{print int($1)}' /proc/uptime)

    _lock
    # Duplicate guard: same two places add_time checks for an existing
    # session (live RAM table, then the flash-persisted paused row).
    if [ -f "$SESSION_DATA" ] && $BB grep -q "^$MAC " "$SESSION_DATA"; then
        _unlock; err_json "session_exists"
    fi
    if [ -f "$USERS_FILE" ] && $BB grep -q "^$MAC paused " "$USERS_FILE"; then
        _unlock; err_json "session_exists"
    fi

    mkdir -p "$HDATA"; touch "$SESSION_DATA"; touch "$USERS_FILE"
    echo "$MAC $(( UPTIME + ADD )) $ADD" >> "$SESSION_DATA"

    if _users_file_stage_excl "$MAC"; then
        echo "$MAC active $ADD $ADD $(_fmt_secs "$ADD")" >> "${USERS_FILE}.tmp"
        _users_file_commit
    fi

    iptables -t nat    -I HOTSPOT     1 -m mac --mac-source "$MAC" -j RETURN 2>/dev/null
    iptables -t filter -I HOTSPOT_FWD 1 -m mac --mac-source "$MAC" -j ACCEPT 2>/dev/null
    _unlock

    ok_json "{\"ok\":true,\"mac\":\"$MAC\",\"added\":$ADD}"
fi

# ================================================================
# POST ?action=remove_time   body: mac=xx:xx:..&minutes=N
# Subtracts N minutes from an active or paused session.
# Clamps to a minimum of 60 s remaining so the session is never
# wiped accidentally — use Kick if you want to end it outright.
# ================================================================
if echo "$QS" | $BB grep -q "action=remove_time"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    MAC=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*mac=\([^&]*\).*/\1/p' | urldecode | $BB tr 'A-Z' 'a-z' | $BB tr -cd 'a-f0-9:')
    MINS=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*minutes=\([^&]*\).*/\1/p' | $BB tr -cd '0-9')
    [ -z "$MAC" ]  && err_json "missing_mac"
    [ -z "$MINS" ] && err_json "missing_minutes"
    [ "$MINS" -le 0 ] 2>/dev/null && err_json "bad_minutes"
    SUB=$(( MINS * 60 ))
    MIN_REM=60   # floor: keep at least 60 s so the watchdog doesn't expire it mid-op
    UPTIME=$($BB awk '{print int($1)}' /proc/uptime)
    FOUND=0

    _lock
    # Active session — update RAM session file
    if [ -f "$SESSION_DATA" ] && $BB grep -q "^$MAC " "$SESSION_DATA"; then
        $BB awk -v m="$MAC" -v deduct="$SUB" -v up="$UPTIME" -v minr="$MIN_REM" '
            $1==m {
                xe=$2; tot=$3
                if (xe=="") xe=up; if (tot=="") tot=xe-up
                newxe = xe - deduct; newtot = tot - deduct
                if (newxe < up + minr) newxe = up + minr
                if (newtot < minr)     newtot = minr
                print m, newxe, newtot; next
            }
            { print }
        ' "$SESSION_DATA" > /tmp/rt_s.tmp && $BB mv /tmp/rt_s.tmp "$SESSION_DATA"

        NEW_EXP=$($BB grep "^$MAC " "$SESSION_DATA" | $BB awk '{print $2}')
        NEW_TOT=$($BB grep "^$MAC " "$SESSION_DATA" | $BB awk '{print $3}')
        REM=$(( NEW_EXP - UPTIME ))
        if _users_file_stage_excl "$MAC"; then
            echo "$MAC active $REM $NEW_TOT $(_fmt_secs "$REM")" >> "${USERS_FILE}.tmp"
            _users_file_commit
        fi
        FOUND=1

    # Paused session — update flash only
    elif [ -f "$USERS_FILE" ] && $BB grep -q "^$MAC paused " "$USERS_FILE"; then
        OLD_P=$($BB grep "^$MAC paused " "$USERS_FILE" | head -1)
        P_REM=$($BB echo "$OLD_P" | $BB awk '{print $3}')
        P_TOT=$($BB echo "$OLD_P" | $BB awk '{print $4}')
        [ -z "$P_TOT" ] && P_TOT=$P_REM
        N_REM=$(( P_REM - SUB )); [ "$N_REM" -lt "$MIN_REM" ] && N_REM=$MIN_REM
        N_TOT=$(( P_TOT - SUB )); [ "$N_TOT" -lt "$MIN_REM" ] && N_TOT=$MIN_REM

        if _users_file_stage_excl_paused "$MAC"; then
            echo "$MAC paused $N_REM $N_TOT $(_fmt_secs "$N_REM")" >> "${USERS_FILE}.tmp"
            _users_file_commit
        fi
        FOUND=1
    fi
    _unlock

    [ "$FOUND" -eq 0 ] && err_json "session_not_found"
    ok_json "{\"ok\":true,\"mac\":\"$MAC\",\"removed\":$SUB}"
fi

# ================================================================
# POST ?action=remove_user   body: mac=xx:xx:..
# Permanently removes a user and all their time from the active
# session table AND the persistent database. Cannot be undone.
# ================================================================
if echo "$QS" | $BB grep -q "action=remove_user"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    MAC=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*mac=\([^&]*\).*/\1/p' | urldecode | $BB tr 'A-Z' 'a-z' | $BB tr -cd 'a-f0-9:')
    [ -z "$MAC" ] && err_json "missing_mac"
    RM_ACTIVITY="/tmp/hotspot_activity.txt"

    _lock
    [ -f "$SESSION_DATA" ] && { $BB grep -v "^$MAC " "$SESSION_DATA" > /tmp/rm_s.tmp; $BB mv /tmp/rm_s.tmp "$SESSION_DATA"; }
    _users_file_stage_excl "$MAC" && _users_file_commit
    _unlock

    # Revoke internet access (no-op if already paused/removed)
    iptables -t nat    -D HOTSPOT     -m mac --mac-source "$MAC" -j RETURN 2>/dev/null
    iptables -t filter -D HOTSPOT_FWD -m mac --mac-source "$MAC" -j ACCEPT 2>/dev/null

    # Clean up auxiliary files
    [ -f "$RM_ACTIVITY" ]         && { $BB grep -v "^$MAC " "$RM_ACTIVITY"         > /tmp/rm_a.tmp 2>/dev/null; $BB mv /tmp/rm_a.tmp "$RM_ACTIVITY"; }
    [ -f /tmp/hotspot_ip_map.txt ] && { $BB grep -v "^$MAC " /tmp/hotspot_ip_map.txt > /tmp/rm_i.tmp;           $BB mv /tmp/rm_i.tmp /tmp/hotspot_ip_map.txt; }

    ok_json "{\"ok\":true,\"mac\":\"$MAC\"}"
fi

# ================================================================
# GET ?action=users_export
# Streams the raw persistent users.txt database back as plain text so
# the admin can save it as a backup or move it to another box. Same
# row format action=users_import reads back in.
# ================================================================
if echo "$QS" | $BB grep -q "action=users_export"; then
    _lock
    EXPORT_DATA=$($BB cat "$USERS_FILE" 2>/dev/null)
    _unlock
    printf "Status: 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"
    printf '%s\n' "$EXPORT_DATA"
    exit 0
fi

# ================================================================
# POST ?action=users_import   body: mode=overwrite|merge & data=<users.txt text>
# overwrite: wipes every current user (active sessions get kicked and
#            their firewall rule dropped first) and replaces the whole
#            database with the imported rows.
# merge:     keeps every current user; a MAC present in BOTH the current
#            database and the imported file is overwritten with the
#            imported file's value, everything else is left untouched.
# Every imported row lands as "paused" regardless of its original
# status - import only ever seeds a balance, it never opens a firewall
# rule on its own. A device is promoted back to active the normal way,
# through the captive portal's own login/resume flow, exactly like any
# other paused row.
# ================================================================
if echo "$QS" | $BB grep -q "action=users_import"; then
    read -n "$CONTENT_LENGTH" POST_DATA

    fget() {
        printf '%s' "$POST_DATA" \
            | $BB tr '&' '\n' \
            | $BB grep "^$1=" \
            | $BB sed 's/^[^=]*=//' \
            | urldecode \
            | head -1
    }

    MODE=$(fget mode | $BB tr -cd 'a-z')
    case "$MODE" in overwrite|merge) ;; *) err_json "bad_mode" ;; esac

    # data may be many lines - unlike fget's single-value fields this one
    # must NOT be truncated to the first line, so it's pulled out by hand.
    RAW=$(printf '%s' "$POST_DATA" | $BB tr '&' '\n' | $BB grep "^data=" | $BB sed 's/^data=//' | urldecode)
    [ -z "$RAW" ] && err_json "no_data"

    # Sanitize: keep only well-formed "mac ... remaining total ..." rows,
    # normalize the MAC to lowercase, dedup by MAC (last occurrence in the
    # uploaded file wins). Nothing past this point reads the raw upload -
    # only this filtered, validated set ever reaches users.txt.
    IMPORT_TMP=$(mktemp /tmp/users_import.XXXXXX)
    TOTAL_LINES=$(printf '%s\n' "$RAW" | $BB tr -d '\r' | $BB grep -c '[^[:space:]]')
    printf '%s\n' "$RAW" | $BB tr -d '\r' | $BB awk '
        {
            mac = tolower($1)
            if (mac !~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$/) next
            rem = $3; tot = $4
            if (rem !~ /^[0-9]+$/ || rem+0 <= 0) next
            if (tot !~ /^[0-9]+$/ || tot+0 <= 0) tot = rem
            val[mac] = mac " " rem " " tot
        }
        END { for (m in val) print val[m] }
    ' > "$IMPORT_TMP"

    IMPORTED_COUNT=$($BB grep -c '.' "$IMPORT_TMP" 2>/dev/null); [ -z "$IMPORTED_COUNT" ] && IMPORTED_COUNT=0
    if [ "$IMPORTED_COUNT" -eq 0 ]; then
        rm -f "$IMPORT_TMP"
        err_json "no_valid_rows"
    fi
    SKIPPED_COUNT=$(( TOTAL_LINES - IMPORTED_COUNT )); [ "$SKIPPED_COUNT" -lt 0 ] && SKIPPED_COUNT=0

    _lock
    mkdir -p "$HDATA"; touch "$USERS_FILE"; touch "$SESSION_DATA"

    if [ "$MODE" = "overwrite" ]; then
        # Full reset: nothing from the current database survives, so revoke
        # every currently-active MAC's firewall rule and clear RAM state
        # before the persistent file is replaced wholesale below.
        while read -r mac expiry total; do
            [ -n "$mac" ] || continue
            iptables -t nat    -D HOTSPOT     -m mac --mac-source "$mac" -j RETURN 2>/dev/null
            iptables -t filter -D HOTSPOT_FWD -m mac --mac-source "$mac" -j ACCEPT 2>/dev/null
        done < "$SESSION_DATA"
        : > "$SESSION_DATA"
        BASE_SRC="/dev/null"
    else
        # Merge: any imported MAC that's currently active gets pulled out of
        # RAM and its rule revoked first, so a live active-in-RAM record
        # never sits alongside the freshly-imported paused row for the same
        # MAC once the database is rewritten below.
        while read -r mac expiry total; do
            [ -n "$mac" ] || continue
            if $BB grep -q "^$mac " "$IMPORT_TMP"; then
                iptables -t nat    -D HOTSPOT     -m mac --mac-source "$mac" -j RETURN 2>/dev/null
                iptables -t filter -D HOTSPOT_FWD -m mac --mac-source "$mac" -j ACCEPT 2>/dev/null
            fi
        done < "$SESSION_DATA"
        $BB awk -v importf="$IMPORT_TMP" '
            BEGIN { while ((getline line < importf) > 0) { split(line, a, " "); skip[a[1]] = 1 } }
            { if (!($1 in skip)) print }
        ' "$SESSION_DATA" > /tmp/ui_s.tmp && $BB mv /tmp/ui_s.tmp "$SESSION_DATA"
        BASE_SRC="$USERS_FILE"
    fi

    # Existing rows not being overwritten (empty set in overwrite mode),
    # followed by every imported row - written in as paused with the time
    # column recomputed fresh.
    {
        if [ "$BASE_SRC" != "/dev/null" ] && [ -f "$BASE_SRC" ]; then
            $BB awk -v importf="$IMPORT_TMP" '
                BEGIN { while ((getline line < importf) > 0) { split(line, a, " "); skip[a[1]] = 1 } }
                { if (!($1 in skip)) print }
            ' "$BASE_SRC"
        fi
        while read -r mac rem tot; do
            [ -n "$mac" ] || continue
            echo "$mac paused $rem $tot $(_fmt_secs "$rem")"
        done < "$IMPORT_TMP"
    } > "${USERS_FILE}.tmp"
    _users_file_commit
    rm -f "$IMPORT_TMP"
    _unlock

    ok_json "{\"ok\":true,\"mode\":\"$MODE\",\"imported\":$IMPORTED_COUNT,\"skipped\":$SKIPPED_COUNT}"
fi

# ================================================================
# GET ?action=whitelist_get
# ================================================================
if echo "$QS" | $BB grep -q "action=whitelist_get"; then
    OUT="["; SEP=""
    if [ -f "$WHITELIST_FILE" ]; then
        while read -r entry; do
            case "$entry" in \#*|"") continue ;; esac
            OUT="${OUT}${SEP}\"$entry\""
            SEP=","
        done < "$WHITELIST_FILE"
    fi
    ok_json "{\"ok\":true,\"list\":${OUT}]}"
fi

# ================================================================
# POST ?action=whitelist_add  body: mac=aabbccddeeff
# ================================================================
if echo "$QS" | $BB grep -q "action=whitelist_add"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    MAC=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*mac=\([^&]*\).*/\1/p' | urldecode | $BB tr 'A-Z' 'a-z' | $BB tr -cd 'a-f0-9')
    [ -z "$MAC" ] && err_json "missing_mac"
    mkdir -p "$HDATA"; touch "$WHITELIST_FILE"
    $BB grep -qi "^${MAC}$" "$WHITELIST_FILE" || echo "$MAC" >> "$WHITELIST_FILE"
    RAW_MAC=$(printf '%s' "$MAC" | $BB sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/')
    iptables -t nat    -I HOTSPOT    1 -m mac --mac-source "$RAW_MAC" -j RETURN 2>/dev/null
    iptables -t filter -I HOTSPOT_FWD 1 -m mac --mac-source "$RAW_MAC" -j ACCEPT 2>/dev/null
    ok_json "{\"ok\":true,\"mac\":\"$MAC\"}"
fi

# ================================================================
# POST ?action=whitelist_del  body: mac=aabbccddeeff
# ================================================================
if echo "$QS" | $BB grep -q "action=whitelist_del"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    MAC=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*mac=\([^&]*\).*/\1/p' | urldecode | $BB tr 'A-Z' 'a-z' | $BB tr -cd 'a-f0-9')
    [ -z "$MAC" ] && err_json "missing_mac"
    if [ -f "$WHITELIST_FILE" ]; then
        WL_RC=0
        $BB grep -iv "^${MAC}$" "$WHITELIST_FILE" > /tmp/wl_del.tmp 2>/dev/null || WL_RC=$?
        if [ "$WL_RC" -gt 1 ]; then
            rm -f /tmp/wl_del.tmp 2>/dev/null
            logger -t lmehspt "whitelist.txt: refused overwrite after read error (rc=$WL_RC) - kept existing file" 2>/dev/null
            err_json "read_error"
        fi
        $BB mv /tmp/wl_del.tmp "$WHITELIST_FILE"
    fi
    RAW_MAC=$(printf '%s' "$MAC" | $BB sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/')
    iptables -t nat    -D HOTSPOT     -m mac --mac-source "$RAW_MAC" -j RETURN 2>/dev/null
    iptables -t filter -D HOTSPOT_FWD -m mac --mac-source "$RAW_MAC" -j ACCEPT 2>/dev/null
    ok_json "{\"ok\":true,\"mac\":\"$MAC\"}"
fi

# ================================================================
# GET ?action=vouchers_get
# ================================================================
if echo "$QS" | $BB grep -q "action=vouchers_get"; then
    OUT="["; SEP=""
    if [ -f "$VOUCHER_FILE" ]; then
        # Voucher format is now just: CODE DURATION (expiry removed).
        # Skip comment/blank lines and any row with a non-numeric duration
        # so the emitted JSON is always valid.
        while read -r code duration _rest; do
            case "$code"     in \#*|"") continue ;; esac
            case "$duration" in *[!0-9]*|"") continue ;; esac
            OUT="${OUT}${SEP}{\"code\":\"$code\",\"duration\":$duration}"
            SEP=","
        done < "$VOUCHER_FILE"
    fi
    ok_json "{\"ok\":true,\"vouchers\":${OUT}]}"
fi

# ================================================================
# POST ?action=voucher_add  body: code=XX&duration=3600
# ================================================================
if echo "$QS" | $BB grep -q "action=voucher_add"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    # Expiry (valid_until) removed. Sanitize CODE to alnum and DUR to digits
    # so they're safe in the grep regex / file write and never break the row.
    CODE=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*code=\([^&]*\).*/\1/p'     | urldecode | $BB tr 'a-z' 'A-Z' | $BB tr -cd 'A-Z0-9')
    DUR=$( printf '%s' "$POST_DATA" | $BB sed -n 's/.*duration=\([^&]*\).*/\1/p' | $BB tr -cd '0-9')
    [ -z "$CODE" ] && err_json "missing_code"
    [ -z "$DUR"  ] && err_json "missing_duration"
    mkdir -p "$HDATA"; touch "$VOUCHER_FILE"
    # Locked: login.sh's redemption path takes this same lock before it
    # touches VOUCHER_FILE. Without taking it here too, an admin add landing
    # mid-redemption is a lost-update race - both sides read the pre-change
    # file, so whichever mv() lands second silently reverts the other's
    # change (e.g. resurrecting a code a customer just redeemed).
    _lock
    VCH_RC=0
    $BB grep -v "^$CODE " "$VOUCHER_FILE" > /tmp/vch_add.tmp 2>/dev/null || VCH_RC=$?
    if [ "$VCH_RC" -gt 1 ]; then
        rm -f /tmp/vch_add.tmp 2>/dev/null
        logger -t lmehspt "vouchers.txt: refused overwrite after read error (rc=$VCH_RC) - kept existing file" 2>/dev/null
        err_json "read_error"
    fi
    echo "$CODE $DUR" >> /tmp/vch_add.tmp
    $BB mv /tmp/vch_add.tmp "$VOUCHER_FILE"
    sync
    _unlock
    ok_json "{\"ok\":true,\"code\":\"$CODE\"}"
fi

# ================================================================
# POST ?action=voucher_del  body: code=XX
# ================================================================
if echo "$QS" | $BB grep -q "action=voucher_del"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    CODE=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*code=\([^&]*\).*/\1/p' | urldecode | $BB tr 'a-z' 'A-Z' | $BB tr -cd 'A-Z0-9')
    [ -z "$CODE" ] && err_json "missing_code"
    # Locked: see the identical note in voucher_add above - login.sh's
    # redemption path takes this same lock, so this side needs to as well.
    _lock
    if [ -f "$VOUCHER_FILE" ] && ! _voucher_file_replace_excl "$CODE"; then
        _unlock
        err_json "read_error"
    fi
    _unlock
    ok_json "{\"ok\":true,\"code\":\"$CODE\"}"
fi

# ================================================================
# GET ?action=nodemcus_get
# Full merged registry (primary + extras) for the NodeMCUs admin page.
# ================================================================
if echo "$QS" | $BB grep -q "action=nodemcus_get"; then
    load_coin_env
    N1_TITLE="${NODEMCU_1_TITLE:-$(read_lmehspt_var NODEMCU_1_TITLE)}"
    N1_EN="${NODEMCU_1_ENABLED:-$(read_lmehspt_var NODEMCU_1_ENABLED)}"
    N1_IP="${NODEMCU_IP:-$(read_lmehspt_var NODEMCU_IP)}"
    N1_MAC="${NODEMCU_MAC:-$(read_lmehspt_var NODEMCU_MAC)}"
    N1_PORT="${NODEMCU_PORT:-$(read_lmehspt_var NODEMCU_PORT)}"
    N1_PSK="${COIN_PSK:-$(read_lmehspt_var COIN_PSK)}"
    N1_EN_BOOL="true"; [ "${N1_EN:-1}" = "0" ] && N1_EN_BOOL="false"

    # Build "id<TAB>{json}" rows for every unit, then emit them in the saved
    # display order (nodemcus_order.txt). The primary (#1) is only included
    # while it is still configured - after a primary delete its IP and MAC are
    # both cleared, and that empty state is the signal that there is no primary
    # any more (so it drops out of the table entirely).
    NM_MAP="/tmp/nm_map.$$"
    : > "$NM_MAP"
    if [ -n "$N1_IP" ] || [ -n "$N1_MAC" ]; then
        printf '1\t{"id":1,"title":"%s","ip":"%s","mac":"%s","port":"%s","psk":"%s","enabled":%s,"primary":true}\n' \
            "$(esc_json "${N1_TITLE:-Coin Slot}")" "$(esc_json "$N1_IP")" "$(esc_json "$N1_MAC")" "$(esc_json "$N1_PORT")" "$(esc_json "$N1_PSK")" "$N1_EN_BOOL" >> "$NM_MAP"
    fi

    if [ -f "$NODEMCU_EXTRA_FILE" ]; then
        while IFS='|' read -r nid ntitle nip nmac nport npsk nen; do
            case "$nid" in ''|*[!0-9]*) continue ;; esac
            EN_BOOL="true"; [ "${nen:-1}" = "0" ] && EN_BOOL="false"
            printf '%s\t{"id":%s,"title":"%s","ip":"%s","mac":"%s","port":"%s","psk":"%s","enabled":%s,"primary":false}\n' \
                "$nid" "$nid" "$(esc_json "$ntitle")" "$(esc_json "$nip")" "$(esc_json "$nmac")" "$(esc_json "$nport")" "$(esc_json "$npsk")" "$EN_BOOL" >> "$NM_MAP"
        done < "$NODEMCU_EXTRA_FILE"
    fi

    OUT=$($BB awk -F'\t' -v orderfile="$NODEMCU_ORDER_FILE" '
        BEGIN{
            n=0;
            while((getline l < orderfile) > 0){ gsub(/[^0-9]/,"",l); if(l!="") ord[n++]=l; }
            close(orderfile);
        }
        { obj[$1]=$2; nat[nn++]=$1; have[$1]=1; }
        END{
            out=""; sep="";
            for(i=0;i<n;i++){ id=ord[i]; if(have[id] && !done[id]){ out=out sep obj[id]; sep=","; done[id]=1; } }
            for(i=0;i<nn;i++){ id=nat[i]; if(!done[id]){ out=out sep obj[id]; sep=","; done[id]=1; } }
            printf "[%s]", out;
        }' "$NM_MAP")
    rm -f "$NM_MAP"
    NMAX=$(_nodemcu_pool_size)
    ok_json "{\"ok\":true,\"nodemcus\":${OUT},\"max_nodemcus\":$NMAX}"
fi

# ================================================================
# POST ?action=nodemcu_reorder  body: order=1,3,2
# Persists the display order shared by the NodeMCUs admin table and the
# captive portal's coin-slot picker (coin.sh reads the same file). Any id not
# listed here falls back to its natural position (primary first, then the
# extras file), so a partial list can never drop a unit.
# ================================================================
if echo "$QS" | $BB grep -q "action=nodemcu_reorder"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    ORD=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*order=\([^&]*\).*/\1/p' | urldecode)
    mkdir -p "$HDATA"
    printf '%s' "$ORD" | $BB tr ',' '\n' | $BB tr -cd '0-9\n' | $BB grep -v '^$' > "${NODEMCU_ORDER_FILE}.tmp" 2>/dev/null
    $BB mv "${NODEMCU_ORDER_FILE}.tmp" "$NODEMCU_ORDER_FILE" 2>/dev/null
    sync
    ok_json "{\"ok\":true}"
fi
# ================================================================
# POST ?action=nodemcu_add  body: title,ip,mac,port,psk,enabled
# Adds an additional coin acceptor unit (#2+). The primary (#1) is managed
# through action=config_set above, not here.
# ================================================================
if echo "$QS" | $BB grep -q "action=nodemcu_add"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    NTITLE=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*title=\([^&]*\).*/\1/p' | urldecode | $BB tr -d '|\r\n')
    NMACV=$(printf '%s'  "$POST_DATA" | $BB sed -n 's/.*mac=\([^&]*\).*/\1/p'   | urldecode | $BB tr 'A-F' 'a-f' | $BB tr -cd '0-9a-f')
    NPSKV=$(printf '%s'  "$POST_DATA" | $BB sed -n 's/.*psk=\([^&]*\).*/\1/p'   | urldecode | $BB tr -d '|\r\n')
    NENV=$(printf '%s'   "$POST_DATA" | $BB sed -n 's/.*enabled=\([^&]*\).*/\1/p')

    [ -z "$NTITLE" ] && NTITLE="Coin Slot"
    printf '%s' "$NMACV" | grep -qE '^[0-9a-f]{12}$' || err_json "invalid_mac"
    [ -z "$NPSKV" ]  && err_json "missing_psk"
    [ "$NENV" = "0" ] && NENV=0 || NENV=1
    NPORTV=8080   # fixed: NodeMCU firmware always listens on 8080
    load_coin_env
    # IP is auto-assigned from the pool below the DHCP start; adding is refused
    # once every usable address is taken (that cap IS the NodeMCU limit).
    NIPV=$(_next_free_nodemcu_ip)
    [ -z "$NIPV" ] && err_json "pool_full"

    mkdir -p "$HDATA"; touch "$NODEMCU_EXTRA_FILE"

    _lock
    NEXT_ID=$($BB awk -F'|' '$1 ~ /^[0-9]+$/ && $1+0>m{m=$1+0} END{print m+0}' "$NODEMCU_EXTRA_FILE" 2>/dev/null)
    [ -z "$NEXT_ID" ] && NEXT_ID=0
    [ "$NEXT_ID" -lt 1 ] && NEXT_ID=1
    NEXT_ID=$(( NEXT_ID + 1 ))

    printf '%s|%s|%s|%s|%s|%s|%s\n' "$NEXT_ID" "$NTITLE" "$NIPV" "$NMACV" "$NPORTV" "$NPSKV" "$NENV" >> "$NODEMCU_EXTRA_FILE"
    sync
    _unlock

    # Apply immediately: static DHCP lease + FORWARD isolation for the new
    # unit — same live-apply "source lmehspt.sh --lib" pattern config_set
    # already uses above for the primary node's IP/MAC changes.
    LMEHSPT_LIB_ONLY=1
    . /lmepisowifi/lmehspt.sh --lib
    [ -f /tmp/hotspot_dhcp.pid ] && kill -9 "$(cat /tmp/hotspot_dhcp.pid)" 2>/dev/null
    # This unit's MAC almost always already holds a DYNAMIC lease from before
    # it was registered here — seeing it associate with SOME address is
    # usually how its MAC got noticed in the first place. busybox udhcpd
    # keeps re-issuing whatever a MAC's existing leases-file entry says
    # regardless of the static_lease line we just added, so wipe the lease
    # DB before restarting: same fix apply_portal_ip_change relies on for
    # subnet changes.
    rm -f /tmp/udhcpd.leases
    start_dhcp
    apply_extra_nodemcu_fw
    # Force this unit to drop its current association so it re-DHCPs right
    # away instead of sitting on its old address until its own lease/renewal
    # timer happens to fire. Only this MAC is kicked — other connected
    # customers on wlan1 are untouched.
    kick_sta_mac "$NMACV"
    ping -c 1 -W 1 "$NIPV" >/dev/null 2>&1

    ok_json "{\"ok\":true,\"id\":$NEXT_ID}"
fi

# ================================================================
# POST ?action=nodemcu_edit  body: id,title,ip,mac,port,psk,enabled
# ================================================================
if echo "$QS" | $BB grep -q "action=nodemcu_edit"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    NID=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*id=\([^&]*\).*/\1/p' | $BB tr -cd '0-9')
    [ -z "$NID" ] && err_json "missing_id"

    NTITLE=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*title=\([^&]*\).*/\1/p' | urldecode | $BB tr -d '|\r\n')
    NMACV=$(printf '%s'  "$POST_DATA" | $BB sed -n 's/.*mac=\([^&]*\).*/\1/p'   | urldecode | $BB tr 'A-F' 'a-f' | $BB tr -cd '0-9a-f')
    NPSKV=$(printf '%s'  "$POST_DATA" | $BB sed -n 's/.*psk=\([^&]*\).*/\1/p'   | urldecode | $BB tr -d '|\r\n')
    NENV=$(printf '%s'   "$POST_DATA" | $BB sed -n 's/.*enabled=\([^&]*\).*/\1/p')

    printf '%s' "$NMACV" | grep -qE '^[0-9a-f]{12}$' || err_json "invalid_mac"
    [ -z "$NPSKV" ]  && err_json "missing_psk"
    [ "$NENV" = "0" ] && NENV=0 || NENV=1
    NPORTV=8080   # fixed: NodeMCU firmware always listens on 8080
    load_coin_env

    # The IP is auto-assigned (from the DHCP pool at add time) and is NOT
    # user-editable, so an edit keeps whatever IP the unit already holds.

    # ---- Primary (#1): config vars, not the extras file ----
    if [ "$NID" = "1" ]; then
        [ -z "$NTITLE" ] && NTITLE="Coin Slot"
        OLD_NIP=$(read_lmehspt_var NODEMCU_IP)
        OLD_NMC=$(read_lmehspt_var NODEMCU_MAC)
        OLD_NEN=$(read_lmehspt_var NODEMCU_1_ENABLED)

        # NODEMCU_IP is intentionally left untouched.
        for _kv in "NODEMCU_MAC=$NMACV" "NODEMCU_PORT=$NPORTV" "NODEMCU_1_TITLE=$NTITLE" "NODEMCU_1_ENABLED=$NENV" "COIN_PSK=$NPSKV"; do
            _k=${_kv%%=*}; _v=${_kv#*=}
            save_coin_env_var "$_k" "$_v"
            set_lmehspt_var  "$_k" "$_v"
            set_globals_var  "$_k" "$_v"
        done

        NEW_NMC=$(read_lmehspt_var NODEMCU_MAC)
        NEW_NEN=$(read_lmehspt_var NODEMCU_1_ENABLED)
        if [ "$OLD_NMC" != "$NEW_NMC" ] || [ "${OLD_NEN:-1}" != "${NEW_NEN:-1}" ]; then
            [ -f /tmp/hotspot_dhcp.pid ] && kill -9 "$(cat /tmp/hotspot_dhcp.pid)" 2>/dev/null
            load_coin_env
            LMEHSPT_LIB_ONLY=1
            . /lmepisowifi/lmehspt.sh --lib
            rm -f /tmp/udhcpd.leases
            start_dhcp
            ip neigh del "$OLD_NIP" dev "$HOTSPOT_BR" 2>/dev/null
            $BB arp -d "$OLD_NIP" 2>/dev/null
            kick_sta_mac "$NEW_NMC"
            ping -c 1 -W 1 "$OLD_NIP" >/dev/null 2>&1
        fi
        touch /tmp/hotspot_qos_reload
        ok_json "{\"ok\":true}"
    fi

    # ---- Additional units (#2+): rows in NODEMCU_EXTRA_FILE ----
    [ -z "$NTITLE" ] && NTITLE="Coin Slot $NID"
    [ -f "$NODEMCU_EXTRA_FILE" ] && $BB grep -q "^${NID}|" "$NODEMCU_EXTRA_FILE" || err_json "not_found"

    _lock
    OLD_ROW=$($BB grep "^${NID}|" "$NODEMCU_EXTRA_FILE" | head -1)
    OLD_IPV=$(printf '%s' "$OLD_ROW" | awk -F'|' '{print $3}')
    OLD_MACV=$(printf '%s' "$OLD_ROW" | awk -F'|' '{print $4}')
    NIPV="$OLD_IPV"   # keep the unit's existing (auto-assigned) IP

    NM_RC=0
    $BB grep -v "^${NID}|" "$NODEMCU_EXTRA_FILE" > /tmp/nm_edit.tmp 2>/dev/null || NM_RC=$?
    if [ "$NM_RC" -gt 1 ]; then
        rm -f /tmp/nm_edit.tmp 2>/dev/null
        _unlock
        err_json "read_error"
    fi
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$NID" "$NTITLE" "$NIPV" "$NMACV" "$NPORTV" "$NPSKV" "$NENV" >> /tmp/nm_edit.tmp
    $BB mv /tmp/nm_edit.tmp "$NODEMCU_EXTRA_FILE"
    sync
    _unlock

    LMEHSPT_LIB_ONLY=1
    . /lmepisowifi/lmehspt.sh --lib
    [ -f /tmp/hotspot_dhcp.pid ] && kill -9 "$(cat /tmp/hotspot_dhcp.pid)" 2>/dev/null
    rm -f /tmp/udhcpd.leases
    start_dhcp
    apply_extra_nodemcu_fw
    ip neigh del "$NIPV" dev "$HOTSPOT_BR" 2>/dev/null
    $BB arp -d "$NIPV" 2>/dev/null
    if [ "$OLD_MACV" != "$NMACV" ]; then
        kick_sta_mac "$NMACV"
    fi
    ping -c 1 -W 1 "$NIPV" >/dev/null 2>&1

    ok_json "{\"ok\":true}"
fi

# ================================================================
# GET ?action=dhcp_get  -> gateway, DHCP range, DNS, NodeMCU pool info
# ================================================================
if echo "$QS" | $BB grep -q "action=dhcp_get"; then
    load_coin_env
    D_PIP="${PORTAL_IP:-$(read_lmehspt_var PORTAL_IP)}"
    D_PFX=$(_dhcp_prefix)
    D_DS=$(_dhcp_start_octet)
    D_DE="${DHCP_END:-$(read_lmehspt_var DHCP_END)}"; case "$D_DE" in ''|*[!0-9]*) D_DE=254 ;; esac
    D_DNS="${DHCP_DNS:-$(read_lmehspt_var DHCP_DNS)}"; [ -z "$D_DNS" ] && D_DNS="1.1.1.1"
    D_MAX=$(_nodemcu_pool_size)
    D_CNT=$(_nodemcu_count)
    D_POOL=$(_nodemcu_pool_ips | $BB awk 'BEGIN{s="";sep=""}{s=s sep "\"" $0 "\"";sep=","}END{printf "[%s]", s}')
    ok_json "{\"ok\":true,\"gateway\":\"$(esc_json "$D_PIP")\",\"prefix\":\"$(esc_json "$D_PFX")\",\"dhcp_start\":\"$(esc_json "$D_PFX.$D_DS")\",\"dhcp_end\":\"$(esc_json "$D_PFX.$D_DE")\",\"dns\":\"$(esc_json "$D_DNS")\",\"nodemcu_pool\":$D_POOL,\"max_nodemcus\":$D_MAX,\"nodemcu_count\":$D_CNT}"
fi

# ================================================================
# POST ?action=dhcp_set  body: gateway, dhcp_start, dhcp_end, dns
# Writes the gateway (PORTAL_IP), the dynamic DHCP range, and DNS servers, then
# re-normalises every NodeMCU into the (possibly moved) usable pool and applies
# live. A gateway move reuses the portal-IP reload path (full rebuild); a
# range/DNS-only change uses the lighter hotspot_dhcp_reload path.
# ================================================================
if echo "$QS" | $BB grep -q "action=dhcp_set"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    dget() { printf '%s' "$POST_DATA" | $BB tr '&' '\n' | $BB grep "^$1=" | $BB sed 's/^[^=]*=//' | urldecode | head -1; }
    D_GW=$(dget gateway    | $BB tr -cd '0-9.')
    D_S=$(dget dhcp_start  | $BB tr -cd '0-9.')
    D_E=$(dget dhcp_end    | $BB tr -cd '0-9.')
    D_DNS_RAW=$(dget dns)

    _valid_ipv4 "$D_GW" || err_json "bad_gateway"
    _valid_ipv4 "$D_S"  || err_json "bad_dhcp_start"
    _valid_ipv4 "$D_E"  || err_json "bad_dhcp_end"

    NEW_PFX=$(printf '%s' "$D_GW" | $BB sed 's/\.[^.]*$//')
    GW_OCT=$(printf '%s'  "$D_GW" | $BB sed 's/.*\.//')
    S_PFX=$(printf '%s'   "$D_S"  | $BB sed 's/\.[^.]*$//'); S_OCT=$(printf '%s' "$D_S" | $BB sed 's/.*\.//')
    E_PFX=$(printf '%s'   "$D_E"  | $BB sed 's/\.[^.]*$//'); E_OCT=$(printf '%s' "$D_E" | $BB sed 's/.*\.//')

    [ "$S_PFX" = "$NEW_PFX" ] && [ "$E_PFX" = "$NEW_PFX" ] || err_json "range_wrong_subnet"
    [ "$GW_OCT" -ge 1 ] && [ "$GW_OCT" -le 254 ] || err_json "bad_gateway"
    [ "$S_OCT" -gt "$GW_OCT" ] || err_json "start_le_gateway"
    [ "$S_OCT" -le "$E_OCT" ]  || err_json "start_gt_end"
    [ "$E_OCT" -le 254 ]       || err_json "end_out_of_range"

    load_coin_env
    OLD_PIP=$(read_lmehspt_var PORTAL_IP)
    OLD_PPT=$(read_lmehspt_var PORTAL_PORT)

    NEW_POOL=$(( S_OCT - GW_OCT - 1 )); [ "$NEW_POOL" -lt 0 ] && NEW_POOL=0
    CUR_CNT=$(_nodemcu_count)
    if [ "$CUR_CNT" -gt "$NEW_POOL" ]; then
        ok_json "{\"ok\":false,\"error\":\"pool_too_small\",\"max\":$NEW_POOL,\"count\":$CUR_CNT}"
    fi

    # Normalise DNS: commas/newlines -> spaces, keep only valid IPv4 tokens.
    D_DNS=$(printf '%s' "$D_DNS_RAW" | $BB tr ',\r\n' '   ' | $BB tr -s ' ')
    _dns_ok=""
    for _d in $D_DNS; do _valid_ipv4 "$_d" && _dns_ok="${_dns_ok:+$_dns_ok }$_d"; done
    [ -z "$_dns_ok" ] && _dns_ok="1.1.1.1"
    D_DNS="$_dns_ok"

    for _kv in "DHCP_START=$S_OCT" "DHCP_END=$E_OCT" "DHCP_DNS=$D_DNS"; do
        _k=${_kv%%=*}; _v=${_kv#*=}
        save_coin_env_var "$_k" "$_v"; set_lmehspt_var "$_k" "$_v"; set_globals_var "$_k" "$_v"
    done

    GW_CHANGED=0; [ "$D_GW" != "$OLD_PIP" ] && GW_CHANGED=1
    if [ "$GW_CHANGED" = "1" ]; then
        save_coin_env_var PORTAL_IP "$D_GW"; set_lmehspt_var PORTAL_IP "$D_GW"; set_globals_var PORTAL_IP "$D_GW"
    fi

    # Update in-memory values so the pool helpers compute against the NEW
    # gateway/start when re-normalising the NodeMCU IPs.
    PORTAL_IP="$D_GW"; DHCP_START="$S_OCT"; DHCP_END="$E_OCT"
    _dhcp_renormalize_ips

    if hotspot_running; then
        if [ "$GW_CHANGED" = "1" ]; then
            printf '%s\n' "$D_GW"    > /tmp/hotspot_portal_ip_new
            printf '%s\n' "$OLD_PPT" > /tmp/hotspot_portal_port_new
            printf '%s\n' "$OLD_PIP" > /tmp/hotspot_portal_ip_old
            printf '%s\n' "$OLD_PPT" > /tmp/hotspot_portal_port_old
            touch /tmp/hotspot_portal_ip_reload
        else
            touch /tmp/hotspot_dhcp_reload
        fi
    fi
    ok_json "{\"ok\":true,\"max_nodemcus\":$NEW_POOL}"
fi
# ================================================================
# POST ?action=nodemcu_del  body: id
# ================================================================
if echo "$QS" | $BB grep -q "action=nodemcu_del"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    NID=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*id=\([^&]*\).*/\1/p' | $BB tr -cd '0-9')
    [ -z "$NID" ] && err_json "missing_id"

    # ---- Deleting the primary (#1): there is no separate row to drop, so wipe
    # its config vars. No promotion happens - the box is simply left with no
    # primary coin acceptor until one is configured again (the "allow empty"
    # behaviour chosen for this build). ----
    if [ "$NID" = "1" ]; then
        load_coin_env
        OLD_NIP=$(read_lmehspt_var NODEMCU_IP)
        for _k in NODEMCU_IP NODEMCU_MAC NODEMCU_1_TITLE COIN_PSK; do
            save_coin_env_var "$_k" ""
            set_lmehspt_var  "$_k" ""
            set_globals_var  "$_k" ""
        done
        save_coin_env_var "NODEMCU_1_ENABLED" "0"
        set_lmehspt_var  "NODEMCU_1_ENABLED" "0"
        set_globals_var  "NODEMCU_1_ENABLED" "0"

        [ -f /tmp/hotspot_dhcp.pid ] && kill -9 "$(cat /tmp/hotspot_dhcp.pid)" 2>/dev/null
        load_coin_env
        LMEHSPT_LIB_ONLY=1
        . /lmepisowifi/lmehspt.sh --lib
        rm -f /tmp/udhcpd.leases
        start_dhcp
        if [ -n "$OLD_NIP" ]; then
            ip neigh del "$OLD_NIP" dev "$HOTSPOT_BR" 2>/dev/null
            $BB arp -d "$OLD_NIP" 2>/dev/null
        fi
        touch /tmp/hotspot_qos_reload
        _order_remove_id "1"
        ok_json "{\"ok\":true,\"id\":1}"
    fi

    _lock
    if [ -f "$NODEMCU_EXTRA_FILE" ] && ! _nodemcu_file_replace_excl "$NID"; then
        _unlock
        err_json "read_error"
    fi
    _unlock

    load_coin_env
    LMEHSPT_LIB_ONLY=1
    . /lmepisowifi/lmehspt.sh --lib
    [ -f /tmp/hotspot_dhcp.pid ] && kill -9 "$(cat /tmp/hotspot_dhcp.pid)" 2>/dev/null
    rm -f /tmp/udhcpd.leases
    start_dhcp
    apply_extra_nodemcu_fw

    _order_remove_id "$NID"
    ok_json "{\"ok\":true,\"id\":$NID}"
fi
# ================================================================
# POST ?action=coin_toggle  body: enabled=1|0
# ================================================================
if echo "$QS" | $BB grep -q "action=coin_toggle"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    VAL=$($BB echo "$POST_DATA" | $BB sed -n 's/.*enabled=\([^&]*\).*/\1/p')
    if [ "$VAL" = "1" ]; then
        touch /tmp/coin_enabled
        save_coin_env_var "COIN_ENABLED" "1"
        set_lmehspt_var "COIN_ENABLED" "1"
        ok_json "{\"ok\":true,\"coin_on\":true}"
    else
        rm -f /tmp/coin_enabled
        save_coin_env_var "COIN_ENABLED" "0"
        set_lmehspt_var "COIN_ENABLED" "0"
        ok_json "{\"ok\":true,\"coin_on\":false}"
    fi
fi

# ================================================================
# POST ?action=lan_isolate_set   body: enabled=1|0
# Instantly applies or removes LAN isolation rules for both the hotspot
# bridge (br1) and the repurposed WAN interface (if currently active).
# Saves the new value to coin_config.env, lmehspt.sh, and globals.env so
# the watchdog picks it up on its next tick.
# ================================================================
if echo "$QS" | $BB grep -q "action=lan_isolate_set"; then
    read -n "${CONTENT_LENGTH:-0}" POST_DATA
    VAL=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*enabled=\([^&]*\).*/\1/p')
    load_coin_env
    HBR="${HOTSPOT_BR:-$(read_lmehspt_var HOTSPOT_BR)}"
    HBR="${HBR:-br1}"
    _W2P="8080"
    # Resolve repurposed WAN interface(s) — /tmp/repurpose_active is a
    # shared registry, one interface per line, since multiple interfaces
    # can be repurposed as DHCP-client WAN at once (empty when the feature
    # is not active for any interface).
    _RWAN_LIST=$($BB cat /tmp/repurpose_active 2>/dev/null | $BB grep -E '^[a-z0-9._-]+$')
    if [ "$VAL" = "1" ]; then
        # ── Enable: apply hotspot isolation ──────────────────────────────────
        _old_lan=$(cat /tmp/hotspot_lan_isolate.mark 2>/dev/null)
        [ -n "$_old_lan" ] && iptables -t filter -D FORWARD -i "$HBR" -d "$_old_lan" -j DROP 2>/dev/null
        _lan_gw=$($BB route -n 2>/dev/null | $BB awk 'NR>1&&$1=="0.0.0.0"&&$2!="0.0.0.0"{print $2;exit}')
        [ -z "$_lan_gw" ] && _lan_gw="192.168.18.1"
        _lan_subnet=$(printf '%s' "$_lan_gw" | $BB sed 's/\.[^.]*$/.0\/24/')
        iptables -t filter -I FORWARD 1 -i "$HBR" -d "$_lan_subnet" -j DROP
        printf '%s\n' "$_lan_subnet" > /tmp/hotspot_lan_isolate.mark
        iptables -t filter -D INPUT -i "$HBR" -p tcp --dport "$_W2P" -j ACCEPT 2>/dev/null
        iptables -t filter -I INPUT 1 -i "$HBR" -p tcp --dport "$_W2P" -j ACCEPT
        # ── Enable: apply repurposed WAN isolation (for every active iface) ───
        if [ -n "$_RWAN_LIST" ]; then
            echo "$_RWAN_LIST" | while IFS= read -r _rwan; do
                [ -z "$_rwan" ] && continue
                iptables -t filter -D FORWARD -i "$_rwan" -o br0 -j DROP 2>/dev/null
                iptables -t filter -I FORWARD 1 -i "$_rwan" -o br0 -j DROP
                iptables -t filter -D INPUT -i "$_rwan" -p tcp --dport "$_W2P" -j ACCEPT 2>/dev/null
                iptables -t filter -I INPUT 1 -i "$_rwan" -p tcp --dport "$_W2P" -j ACCEPT
            done
        fi
        save_coin_env_var "LAN_ISOLATE" "1"
        set_lmehspt_var   "LAN_ISOLATE" "1"
        set_globals_var   "LAN_ISOLATE" "1"
        ok_json '{"ok":true,"lan_isolate":true}'
    else
        # ── Disable: remove hotspot isolation ────────────────────────────────
        _old_lan=$(cat /tmp/hotspot_lan_isolate.mark 2>/dev/null)
        [ -n "$_old_lan" ] && iptables -t filter -D FORWARD -i "$HBR" -d "$_old_lan" -j DROP 2>/dev/null
        rm -f /tmp/hotspot_lan_isolate.mark
        iptables -t filter -D INPUT -i "$HBR" -p tcp --dport "$_W2P" -j ACCEPT 2>/dev/null
        # ── Disable: remove repurposed WAN isolation (for every active iface) ─
        if [ -n "$_RWAN_LIST" ]; then
            echo "$_RWAN_LIST" | while IFS= read -r _rwan; do
                [ -z "$_rwan" ] && continue
                iptables -t filter -D FORWARD -i "$_rwan" -o br0 -j DROP 2>/dev/null
                iptables -t filter -D INPUT -i "$_rwan" -p tcp --dport "$_W2P" -j ACCEPT 2>/dev/null
            done
        fi
        save_coin_env_var "LAN_ISOLATE" "0"
        set_lmehspt_var   "LAN_ISOLATE" "0"
        set_globals_var   "LAN_ISOLATE" "0"
        ok_json '{"ok":true,"lan_isolate":false}'
    fi
fi

# ================================================================
# POST ?action=mac_fix_set   body: enabled=1|0
# Toggles the cookie-based MAC-randomization session-continuity fix (see
# /lmepisowifi/hotspot/macfix.sh). Unlike anti-tether/LAN-isolate there's no
# firewall chain to build or tear down here — it only changes how the
# portal's own CGI scripts (login.sh/status.sh/logout.sh) look up a
# returning device — so this just persists the flag across all three
# config tiers, same as every other simple on/off toggle.
# ================================================================
if echo "$QS" | $BB grep -q "action=mac_fix_set"; then
    read -n "${CONTENT_LENGTH:-0}" POST_DATA
    VAL=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*enabled=\([^&]*\).*/\1/p')
    case "$VAL" in
        1)
            save_coin_env_var "MAC_RANDOMIZATION_FIX" "1"
            set_lmehspt_var   "MAC_RANDOMIZATION_FIX" "1"
            set_globals_var   "MAC_RANDOMIZATION_FIX" "1"
            ok_json '{"ok":true,"mac_randomization_fix":true}'
            ;;
        0)
            save_coin_env_var "MAC_RANDOMIZATION_FIX" "0"
            set_lmehspt_var   "MAC_RANDOMIZATION_FIX" "0"
            set_globals_var   "MAC_RANDOMIZATION_FIX" "0"
            ok_json '{"ok":true,"mac_randomization_fix":false}'
            ;;
        *) err_json "bad_value" ;;
    esac
fi

# ================================================================
# POST ?action=coin_reset
# Wipes the NodeMCU's WiFi config and drops it back into the open
# PisoWifi-Setup AP for re-provisioning. This replaces the old
# coin.sh?action=reset on the PUBLIC captive portal, which had no
# access control at all — any connected hotspot client could hit it.
# This version lives behind the same admin session gate as every
# other action in this file (see top of file), so only an
# authenticated admin can trigger it.
# ================================================================
if echo "$QS" | $BB grep -q "action=coin_reset"; then
    load_coin_env
    NIP="${NODEMCU_IP:-$(read_lmehspt_var NODEMCU_IP)}"
    NPT="${NODEMCU_PORT:-$(read_lmehspt_var NODEMCU_PORT)}"
    CPSK="${COIN_PSK:-$(read_lmehspt_var COIN_PSK)}"
    [ -n "$NIP" ] && [ -n "$NPT" ] && [ -n "$CPSK" ] || err_json "coin_not_configured"

    # Step 1: Get a fresh one-time nonce from NodeMCU
    NONCE_RESP=$(wget -q -T 5 -O - "http://${NIP}:${NPT}/nonce" 2>/dev/null)
    NONCE=$($BB echo "$NONCE_RESP" | $BB grep -o '"nonce":"[^"]*"' | awk -F'"' '{print $4}')
    [ -n "$NONCE" ] || err_json "nodemcu_offline"

    # Step 2: Sign — md5(PSK:nonce:reset)
    TOKEN=$(printf '%s' "${CPSK}:${NONCE}:reset" | md5sum | awk '{print $1}')

    # Step 3: Send signed reset request
    RESP=$(wget -q -T 5 -O - "http://${NIP}:${NPT}/reset?token=${TOKEN}" 2>/dev/null)
    printf '%s' "$RESP" | $BB grep -q '"ok":true' || err_json "reset_failed"

    ok_json '{"ok":true,"msg":"NodeMCU wiped and rebooting into setup AP"}'
fi

# ================================================================
# GET ?action=ifaces_get
# Returns available network interfaces + current config + live bridge members
# ================================================================
if echo "$QS" | $BB grep -q "action=ifaces_get"; then
    load_coin_env
    HBR="${HOTSPOT_BR:-$(read_lmehspt_var HOTSPOT_BR)}"
    HBR="${HBR:-br1}"
    HIF="${HOTSPOT_INTERFACES:-$(read_lmehspt_var HOTSPOT_INTERFACES)}"
    PIP="${PORTAL_IP:-$(read_lmehspt_var PORTAL_IP)}"
    PPT="${PORTAL_PORT:-$(read_lmehspt_var PORTAL_PORT)}"

    HSP_RUNNING="false"; hotspot_running && HSP_RUNNING="true"

    # --- Bridge members (live kernel state) ---
    BRIDGE_MEMBERS="["
    BM_SEP=""
    for ifpath in /sys/class/net/"$HBR"/brif/*; do
        [ -e "$ifpath" ] || continue
        bm=$(basename "$ifpath")
        bm_mac=$(cat "/sys/class/net/$bm/address" 2>/dev/null)
        bm_op=$(cat "/sys/class/net/$bm/operstate" 2>/dev/null)
        bm_up="false"
        [ "$bm_op" = "up" ] && bm_up="true"
        BRIDGE_MEMBERS="${BRIDGE_MEMBERS}${BM_SEP}{\"name\":\"$bm\",\"mac\":\"${bm_mac:-}\",\"up\":$bm_up}"
        BM_SEP=","
    done
    BRIDGE_MEMBERS="${BRIDGE_MEMBERS}]"

    # --- All available interfaces (filter lo/br/sit/ip6/ppp/etc.) ---
    IFACE_LIST="["
    IF_SEP=""
    for ifpath in /sys/class/net/*; do
        iface=$(basename "$ifpath")
        case "$iface" in
            lo|br*|sit*|ip6*|ppp*|tunl*|gre*|dummy*|mon.*|nas*|eth0|pwlan0) continue ;;
            eth0.*)
                case "$iface" in
                    eth0.2.0|eth0.3.0) ;;
                    *) continue ;;
                esac
                ;;
            wlan*)
                [ "$(wlan_iface_disabled "$iface")" = "1" ] && continue
                [ "$(wlan_iface_is_client "$iface")" = "1" ] && continue
                ;;
        esac
        mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null)
        op=$(cat  "/sys/class/net/$iface/operstate" 2>/dev/null)
        type_f=$(cat "/sys/class/net/$iface/type" 2>/dev/null)
        iface_type=""
        case "$iface" in wlan*) iface_type="WLAN" ;; eth*)  iface_type="Ethernet" ;; esac
        is_up="false"; [ "$op" = "up" ] && is_up="true"
        # Check if it's in the bridge right now
        in_bridge="false"
        [ -e "/sys/class/net/$HBR/brif/$iface" ] && in_bridge="true"
        IFACE_LIST="${IFACE_LIST}${IF_SEP}{\"name\":\"$iface\",\"mac\":\"${mac:-}\",\"type\":\"$iface_type\",\"up\":$is_up,\"in_bridge\":$in_bridge}"
        IF_SEP=","
    done
    IFACE_LIST="${IFACE_LIST}]"

    ok_json "{\"ok\":true,
\"hotspot_br\":\"$(esc_json "$HBR")\",
\"hotspot_interfaces\":\"$(esc_json "$HIF")\",
\"portal_ip\":\"$(esc_json "$PIP")\",
\"portal_port\":\"$(esc_json "$PPT")\",
\"hotspot_running\":$HSP_RUNNING,
\"bridge_members\":$BRIDGE_MEMBERS,
\"interfaces\":$IFACE_LIST}"
fi

# ================================================================
# POST ?action=ifaces_set  (form-encoded body)
# Updates HOTSPOT_BR, HOTSPOT_INTERFACES, PORTAL_IP, PORTAL_PORT
# ================================================================
if echo "$QS" | $BB grep -q "action=ifaces_set"; then
    read -n "$CONTENT_LENGTH" POST_DATA

    fget() {
        printf '%s' "$POST_DATA" \
            | $BB tr '&' '\n' \
            | $BB grep "^$1=" \
            | $BB sed 's/^[^=]*=//' \
            | urldecode \
            | head -1
    }

    BR=$(fget hotspot_br); IF=$(fget hotspot_interfaces)
    PIP=$(fget portal_ip);  PPT=$(fget portal_port)

    [ -z "$BR" ] && err_json "missing_hotspot_br"
    [ -z "$IF" ] && err_json "missing_hotspot_interfaces"

    # Capture current values before overwriting — needed to detect changes
    OLD_PIP=$(read_lmehspt_var PORTAL_IP)
    OLD_PPT=$(read_lmehspt_var PORTAL_PORT)

    set_lmehspt_var "HOTSPOT_BR"         "$BR"
    set_lmehspt_var "HOTSPOT_INTERFACES" "$IF"
    set_globals_var "HOTSPOT_BR"         "$BR"
    set_globals_var "HOTSPOT_INTERFACES" "$IF"
    save_coin_env_var "HOTSPOT_BR"         "$BR"
    save_coin_env_var "HOTSPOT_INTERFACES" "$IF"

    [ -n "$PIP" ] && {
        set_lmehspt_var   "PORTAL_IP" "$PIP"
        save_coin_env_var "PORTAL_IP" "$PIP"
        set_globals_var   "PORTAL_IP" "$PIP"
    }
    [ -n "$PPT" ] && {
        set_lmehspt_var   "PORTAL_PORT" "$PPT"
        save_coin_env_var "PORTAL_PORT" "$PPT"
        set_globals_var   "PORTAL_PORT" "$PPT"
    }

    # Trigger a live portal IP/port apply when either value changed and
    # the hotspot watchdog is currently running.  The watchdog picks up
    # /tmp/hotspot_portal_ip_reload on its next tick (≤1 s) and calls
    # apply_portal_ip_change() which rebuilds firewall, DHCP, httpd, and
    # redirect.sh without requiring a full hotspot restart.
    _pip_changed=0; _ppt_changed=0
    [ -n "$PIP" ] && [ "$PIP" != "$OLD_PIP" ] && _pip_changed=1
    [ -n "$PPT" ] && [ "$PPT" != "$OLD_PPT" ] && _ppt_changed=1
    if hotspot_running && { [ "$_pip_changed" = "1" ] || [ "$_ppt_changed" = "1" ]; }; then
        printf '%s\n' "${PIP:-$OLD_PIP}" > /tmp/hotspot_portal_ip_new
        printf '%s\n' "${PPT:-$OLD_PPT}" > /tmp/hotspot_portal_port_new
        # Also stash the pre-change values. save_coin_env_var() above already
        # rewrote /tmp/coin_config.env with the NEW port, and the watchdog
        # re-sources that file every tick — so by the time it processes this
        # reload, its own $PORTAL_PORT may already equal the new port. Without
        # these _old files it has no reliable way left to know what to kill.
        printf '%s\n' "$OLD_PIP" > /tmp/hotspot_portal_ip_old
        printf '%s\n' "$OLD_PPT" > /tmp/hotspot_portal_port_old
        touch /tmp/hotspot_portal_ip_reload
    fi

    touch /tmp/hotspot_qos_reload
    ok_json "{\"ok\":true}"
fi

# ================================================================
# GET ?action=income   -> daily / monthly / yearly / total income
# ================================================================
if echo "$QS" | $BB grep -q "action=income_reset"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    WHICH=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*which=\([^&]*\).*/\1/p' | $BB tr -cd 'a-z')
    case "$WHICH" in
        daily|monthly|yearly|total|all) ;;
        *) err_json "bad_which" ;;
    esac
    OUT=$(/lmepisowifi/hotspot/income.sh reset "$WHICH" 2>/dev/null)
    [ -n "$OUT" ] || err_json "reset_failed"
    ok_json "$OUT"
fi

if echo "$QS" | $BB grep -q "action=income"; then
    OUT=$(/lmepisowifi/hotspot/income.sh get 2>/dev/null)
    [ -n "$OUT" ] || OUT='{"daily":0,"monthly":0,"yearly":0,"total":0,"day":"","month":"","year":"","synced":false}'
    ok_json "$OUT"
fi

# ================================================================
# GET ?action=notify_get   -> current Telegram/Discord alert config
# ================================================================
if echo "$QS" | $BB grep -q "action=notify_get"; then
    NF="$HDATA/notify.env"
    NOTIFY_ENABLED=0; NOTIFY_PROVIDER="telegram"
    TG_BOT_TOKEN=""; TG_CHAT_ID=""; DISCORD_WEBHOOK=""
    # Per-event flags default to enabled (unset -> "1") so existing configs
    # keep every alert firing until the admin explicitly mutes one.
    NOTIFY_EVT_NEW_SALE=1; NOTIFY_EVT_COINS_INSERTED=1; NOTIFY_EVT_ANTI_TROLL=1
    NOTIFY_EVT_SESSION_EXPIRED=1; NOTIFY_EVT_SESSION_PAUSED=1; NOTIFY_EVT_SESSION_RESUMED=1
    NOTIFY_EVT_VOUCHER_REDEEMED=1; NOTIFY_EVT_DAILY_REPORT=1
    NOTIFY_EVT_MONTHLY_REPORT=1; NOTIFY_EVT_YEARLY_REPORT=1
    NOTIFY_DEDUP_WINDOW=30
    [ -f "$NF" ] && . "$NF" 2>/dev/null
    EN_STR="false"; [ "${NOTIFY_ENABLED:-0}" = "1" ] && EN_STR="true"
    case "${NOTIFY_PROVIDER:-telegram}" in discord) PROV="discord" ;; *) PROV="telegram" ;; esac
    case "${NOTIFY_DEDUP_WINDOW:-30}" in ''|*[!0-9]*) DDW=30 ;; *) DDW="$NOTIFY_DEDUP_WINDOW" ;; esac
    # Emit each event flag as a JSON boolean ("1" -> true, anything else -> false)
    _evb() { [ "${1:-1}" = "1" ] && printf 'true' || printf 'false'; }
    ok_json "{\"enabled\":$EN_STR,\"provider\":\"$PROV\",\"tg_bot_token\":\"$(esc_json "$TG_BOT_TOKEN")\",\"tg_chat_id\":\"$(esc_json "$TG_CHAT_ID")\",\"discord_webhook\":\"$(esc_json "$DISCORD_WEBHOOK")\",\"dedup_window\":$DDW,\"events\":{\
\"new_sale\":$(_evb "$NOTIFY_EVT_NEW_SALE"),\
\"coins_inserted\":$(_evb "$NOTIFY_EVT_COINS_INSERTED"),\
\"anti_troll\":$(_evb "$NOTIFY_EVT_ANTI_TROLL"),\
\"session_expired\":$(_evb "$NOTIFY_EVT_SESSION_EXPIRED"),\
\"session_paused\":$(_evb "$NOTIFY_EVT_SESSION_PAUSED"),\
\"session_resumed\":$(_evb "$NOTIFY_EVT_SESSION_RESUMED"),\
\"voucher_redeemed\":$(_evb "$NOTIFY_EVT_VOUCHER_REDEEMED"),\
\"daily_report\":$(_evb "$NOTIFY_EVT_DAILY_REPORT"),\
\"monthly_report\":$(_evb "$NOTIFY_EVT_MONTHLY_REPORT"),\
\"yearly_report\":$(_evb "$NOTIFY_EVT_YEARLY_REPORT")}}"
fi

# ================================================================
# POST ?action=notify_set   (form-encoded) -> save alert config
# ================================================================
if echo "$QS" | $BB grep -q "action=notify_set"; then
    read -n "$CONTENT_LENGTH" POST_DATA

    fget() {
        printf '%s' "$POST_DATA" \
            | $BB tr '&' '\n' \
            | $BB grep "^$1=" \
            | $BB sed 's/^[^=]*=//' \
            | urldecode \
            | head -1
    }
    # Strip chars that could break the sourced env file / inject commands.
    san() { printf '%s' "$1" | $BB tr -d '\r\n"\\$\140'; }

    EN=$(fget enabled);       PROV=$(fget provider)
    TGT=$(san "$(fget tg_bot_token)")
    TGC=$(san "$(fget tg_chat_id)")
    DWH=$(san "$(fget discord_webhook)")

    case "$EN"   in 1|true|on|yes) EN=1 ;; *) EN=0 ;; esac
    case "$PROV" in discord) PROV="discord" ;; *) PROV="telegram" ;; esac

    # Anti-spam cooldown window (seconds). Non-numeric -> default 30;
    # clamp to a sane 0..3600 so a typo can't wedge notifications for hours.
    DDW=$(fget dedup_window | $BB tr -cd '0-9')
    [ -z "$DDW" ] && DDW=30
    [ "$DDW" -gt 3600 ] 2>/dev/null && DDW=3600

    # Per-event mute flags. A missing field defaults to enabled ("1") so a
    # form that doesn't send them (older UI) never accidentally mutes events.
    evt_flag() { case "$(fget "$1")" in 0|false|off|no) printf 0 ;; *) printf 1 ;; esac; }
    EVT_NEW_SALE=$(evt_flag evt_new_sale)
    EVT_COINS_INSERTED=$(evt_flag evt_coins_inserted)
    EVT_ANTI_TROLL=$(evt_flag evt_anti_troll)
    EVT_SESSION_EXPIRED=$(evt_flag evt_session_expired)
    EVT_SESSION_PAUSED=$(evt_flag evt_session_paused)
    EVT_SESSION_RESUMED=$(evt_flag evt_session_resumed)
    EVT_VOUCHER_REDEEMED=$(evt_flag evt_voucher_redeemed)
    EVT_DAILY_REPORT=$(evt_flag evt_daily_report)
    EVT_MONTHLY_REPORT=$(evt_flag evt_monthly_report)
    EVT_YEARLY_REPORT=$(evt_flag evt_yearly_report)

    mkdir -p "$HDATA"
    {
        echo "NOTIFY_ENABLED=\"$EN\""
        echo "NOTIFY_PROVIDER=\"$PROV\""
        echo "TG_BOT_TOKEN=\"$TGT\""
        echo "TG_CHAT_ID=\"$TGC\""
        echo "DISCORD_WEBHOOK=\"$DWH\""
        echo "NOTIFY_DEDUP_WINDOW=\"$DDW\""
        echo "NOTIFY_EVT_NEW_SALE=\"$EVT_NEW_SALE\""
        echo "NOTIFY_EVT_COINS_INSERTED=\"$EVT_COINS_INSERTED\""
        echo "NOTIFY_EVT_ANTI_TROLL=\"$EVT_ANTI_TROLL\""
        echo "NOTIFY_EVT_SESSION_EXPIRED=\"$EVT_SESSION_EXPIRED\""
        echo "NOTIFY_EVT_SESSION_PAUSED=\"$EVT_SESSION_PAUSED\""
        echo "NOTIFY_EVT_SESSION_RESUMED=\"$EVT_SESSION_RESUMED\""
        echo "NOTIFY_EVT_VOUCHER_REDEEMED=\"$EVT_VOUCHER_REDEEMED\""
        echo "NOTIFY_EVT_DAILY_REPORT=\"$EVT_DAILY_REPORT\""
        echo "NOTIFY_EVT_MONTHLY_REPORT=\"$EVT_MONTHLY_REPORT\""
        echo "NOTIFY_EVT_YEARLY_REPORT=\"$EVT_YEARLY_REPORT\""
    } > "$HDATA/notify.env.tmp"
    $BB mv "$HDATA/notify.env.tmp" "$HDATA/notify.env"
    ok_json "{\"ok\":true}"
fi

# ================================================================
# POST ?action=notify_test   -> send a test alert with saved config
# ================================================================
if echo "$QS" | $BB grep -q "action=notify_test"; then
    [ -f "$HDATA/notify.env" ] || err_json "not_configured"
    . /lmepisowifi/hotspot/notify_templates.sh
    ( /lmepisowifi/hotspot/notify.sh "$(tpl_render "$TPL_TEST_ALERT")" force >/dev/null 2>&1 </dev/null & )
    ok_json "{\"ok\":true}"
fi

# ================================================================
# GET ?action=notify_templates_get  -> current message templates
# (falls back to built-in defaults for anything not customized)
# ================================================================
if echo "$QS" | $BB grep -q "action=notify_templates_get"; then
    . /lmepisowifi/hotspot/notify_templates.sh
    ok_json "{\"templates\":{\
\"new_sale\":\"$(esc_json "$TPL_NEW_SALE")\",\
\"coins_inserted\":\"$(esc_json "$TPL_COINS_INSERTED")\",\
\"anti_troll\":\"$(esc_json "$TPL_ANTI_TROLL")\",\
\"session_expired\":\"$(esc_json "$TPL_SESSION_EXPIRED")\",\
\"session_paused\":\"$(esc_json "$TPL_SESSION_PAUSED")\",\
\"session_resumed\":\"$(esc_json "$TPL_SESSION_RESUMED")\",\
\"voucher_redeemed\":\"$(esc_json "$TPL_VOUCHER_REDEEMED")\",\
\"daily_report\":\"$(esc_json "$TPL_DAILY_REPORT")\",\
\"monthly_report\":\"$(esc_json "$TPL_MONTHLY_REPORT")\",\
\"yearly_report\":\"$(esc_json "$TPL_YEARLY_REPORT")\",\
\"test_alert\":\"$(esc_json "$TPL_TEST_ALERT")\"\
}}"
fi

# ================================================================
# POST ?action=notify_templates_set  (form-encoded) -> save customized
# message templates. Any field left blank reverts that event to its
# built-in default (handled by notify_templates.sh at render time).
# ================================================================
if echo "$QS" | $BB grep -q "action=notify_templates_set"; then
    read -n "$CONTENT_LENGTH" POST_DATA

    fget() {
        printf '%s' "$POST_DATA" \
            | $BB tr '&' '\n' \
            | $BB grep "^$1=" \
            | $BB sed 's/^[^=]*=//' \
            | urldecode \
            | head -1
    }
    # Strip CR/LF, quotes, backslashes, $ and backticks so the saved value
    # can't break out of the sourced env file or inject shell commands.
    # Templates still support multi-line layout via the %0A token.
    san() { printf '%s' "$1" | $BB tr -d '\r\n"\\$\140'; }

    mkdir -p "$HDATA"
    {
        echo "TPL_NEW_SALE=\"$(san "$(fget new_sale)")\""
        echo "TPL_COINS_INSERTED=\"$(san "$(fget coins_inserted)")\""
        echo "TPL_ANTI_TROLL=\"$(san "$(fget anti_troll)")\""
        echo "TPL_SESSION_EXPIRED=\"$(san "$(fget session_expired)")\""
        echo "TPL_SESSION_PAUSED=\"$(san "$(fget session_paused)")\""
        echo "TPL_SESSION_RESUMED=\"$(san "$(fget session_resumed)")\""
        echo "TPL_VOUCHER_REDEEMED=\"$(san "$(fget voucher_redeemed)")\""
        echo "TPL_DAILY_REPORT=\"$(san "$(fget daily_report)")\""
        echo "TPL_MONTHLY_REPORT=\"$(san "$(fget monthly_report)")\""
        echo "TPL_YEARLY_REPORT=\"$(san "$(fget yearly_report)")\""
        echo "TPL_TEST_ALERT=\"$(san "$(fget test_alert)")\""
    } > "$HDATA/notify_templates.env.tmp"
    $BB mv "$HDATA/notify_templates.env.tmp" "$HDATA/notify_templates.env"
    ok_json "{\"ok\":true}"
fi

# ================================================================
# POST ?action=notify_templates_reset  -> restore all templates to
# their built-in defaults (deletes the override file)
# ================================================================
if echo "$QS" | $BB grep -q "action=notify_templates_reset"; then
    rm -f "$HDATA/notify_templates.env"
    ok_json "{\"ok\":true}"
fi

# ================================================================
# GET ?action=hotspot_stats  -> running state + session count + income
# ================================================================
if echo "$QS" | $BB grep -q "action=hotspot_stats"; then
    _running=false
    hotspot_running && _running=true
    _sessions=0
    if [ -f "$SESSION_DATA" ]; then
        _sessions=$($BB grep -c '.' "$SESSION_DATA" 2>/dev/null)
        [ -n "$_sessions" ] || _sessions=0
    fi
    _income=$(/lmepisowifi/hotspot/income.sh get 2>/dev/null)
    [ -n "$_income" ] || _income='{"daily":0,"monthly":0,"yearly":0,"total":0,"synced":false}'
    ok_json "{\"running\":${_running},\"sessions\":${_sessions},\"income\":${_income}}"
fi

# ================================================================
# GET ?action=portal_disk_space  -> UBIFS size/used/avail/usable bytes
# usable_bytes = avail_bytes − 10 MB reserve (0 when at or below floor)
# ================================================================
if echo "$QS" | $BB grep -q "action=portal_disk_space"; then
    _dfline=$($BB df -k /lmepisowifi 2>/dev/null | $BB awk 'NR==2')
    _dfl=$( echo "$_dfline" | $BB awk '{print $2+0}')
    _dfu=$( echo "$_dfline" | $BB awk '{print $3+0}')
    _dfa=$( echo "$_dfline" | $BB awk '{print $4+0}')
    _sz_b=$(( ${_dfl:-0} * 1024 ))
    _used_b=$(( ${_dfu:-0} * 1024 ))
    _avail_b=$(( ${_dfa:-0} * 1024 ))
    _reserve_b=10485760
    _usable_b=$(( _avail_b - _reserve_b ))
    [ "$_usable_b" -lt 0 ] && _usable_b=0
    ok_json "{\"ok\":true,\"size_bytes\":${_sz_b},\"used_bytes\":${_used_b},\"avail_bytes\":${_avail_b},\"usable_bytes\":${_usable_b},\"reserve_bytes\":${_reserve_b}}"
fi

# ================================================================
# GET ?action=portal_get  -> title, brand, logo, promos[]
# ================================================================
if echo "$QS" | $BB grep -q "action=portal_get"; then
    PCFG="$HDATA/portal.env"
    PORTAL_TITLE="lmepisowifi"; PORTAL_BRAND="beta"; PORTAL_LOGO="/img/favicon.ico"
    PORTAL_FOOTER="Your device is identified by MAC address. Vouchers are single-use."
    [ -f "$PCFG" ] && . "$PCFG" 2>/dev/null
    # Build promos JSON — detect which promo1..5 files exist
    _pj=""
    for _n in 1 2 3 4 5; do
        for _e in jpg jpeg png gif webp; do
            if [ -f "/lmepisowifi/hotspot/img/promo${_n}.${_e}" ]; then
                _pj="${_pj},\"/img/promo${_n}.${_e}\""
                break
            fi
        done
    done
    # Build audio paths — detect bg_music, coin_sound, and insert_bg_music
    _bg=""; _cs=""; _ins_bg=""
    for _e in mp3 ogg wav; do
        if [ -f "/lmepisowifi/hotspot/audio/bg_music.${_e}" ]; then
            _bg="/audio/bg_music.${_e}"; break
        fi
    done
    for _e in mp3 ogg wav; do
        if [ -f "/lmepisowifi/hotspot/audio/coin_sound.${_e}" ]; then
            _cs="/audio/coin_sound.${_e}"; break
        fi
    done
    for _e in mp3 ogg wav; do
        if [ -f "/lmepisowifi/hotspot/audio/insert_bg_music.${_e}" ]; then
            _ins_bg="/audio/insert_bg_music.${_e}"; break
        fi
    done
    ok_json "{\"ok\":true,\"title\":\"$(esc_json "$PORTAL_TITLE")\",\"brand\":\"$(esc_json "$PORTAL_BRAND")\",\"logo\":\"$(esc_json "$PORTAL_LOGO")\",\"promos\":[${_pj#,}],\"bg_music\":\"$(esc_json "$_bg")\",\"coin_sound\":\"$(esc_json "$_cs")\",\"insert_bg_music\":\"$(esc_json "$_ins_bg")\",\"footer\":\"$(esc_json "$PORTAL_FOOTER")\"}"
fi

# ================================================================
# POST ?action=portal_set  body: title=&brand=&reset_logo=0|1
# Writes title/brand to portal.env; optionally resets logo to default
# ================================================================
if echo "$QS" | $BB grep -q "action=portal_set"; then
    read -n "$CONTENT_LENGTH" POST_DATA

    fget() {
        printf '%s' "$POST_DATA" \
            | $BB tr '&' '\n' \
            | $BB grep "^$1=" \
            | $BB sed 's/^[^=]*=//' \
            | urldecode \
            | head -1
    }
    san_txt() { printf '%s' "$1" | $BB tr -d '\r\n\\"\\`$<>|;&'; }

    PCFG="$HDATA/portal.env"
    PORTAL_TITLE="lmepisowifi"; PORTAL_BRAND="beta"; PORTAL_LOGO="/img/favicon.ico"
    PORTAL_FOOTER="Your device is identified by MAC address. Vouchers are single-use."
    [ -f "$PCFG" ] && . "$PCFG" 2>/dev/null

    NEW_TITLE=$(san_txt "$(fget title)" | $BB cut -c1-64)
    NEW_BRAND=$(san_txt "$(fget brand)" | $BB cut -c1-32)
    NEW_FOOTER=$(san_txt "$(fget footer)" | $BB cut -c1-200)
    RESET_LOGO=$(fget reset_logo)
    [ -n "$NEW_TITLE" ] && PORTAL_TITLE="$NEW_TITLE"
    [ -n "$NEW_BRAND" ] && PORTAL_BRAND="$NEW_BRAND"
    # Allow explicitly clearing footer by sending an empty string
    _footer_raw=$(fget footer)
    [ -n "$_footer_raw" ] && PORTAL_FOOTER="$NEW_FOOTER" || PORTAL_FOOTER=""
    [ "$RESET_LOGO" = "1" ] && { PORTAL_LOGO="/img/favicon.ico"; rm -f /lmepisowifi/hotspot/img/portal_logo.* 2>/dev/null; }

    mkdir -p "$HDATA"
    { printf 'PORTAL_TITLE="%s"\n' "$PORTAL_TITLE"
      printf 'PORTAL_BRAND="%s"\n' "$PORTAL_BRAND"
      printf 'PORTAL_LOGO="%s"\n'  "$PORTAL_LOGO"
      printf 'PORTAL_FOOTER="%s"\n' "$PORTAL_FOOTER"; } > "$PCFG.tmp"
    $BB mv "$PCFG.tmp" "$PCFG"
    ok_json "{\"ok\":true}"
fi

# ================================================================
# POST ?action=portal_upload
# body: img_slot=logo|promo1..promo5 & img_ext=jpg|png|... & img_data=<base64>
# logo   -> saves portal_logo.<ext>, updates portal.env PORTAL_LOGO
# promoN -> saves promoN.<ext> (removes old promoN.* first), no portal.env change
# ================================================================
if echo "$QS" | $BB grep -q "action=portal_upload"; then
    read -n "$CONTENT_LENGTH" POST_DATA

    fget() {
        printf '%s' "$POST_DATA" \
            | $BB tr '&' '\n' \
            | $BB grep "^$1=" \
            | $BB sed 's/^[^=]*=//' \
            | urldecode \
            | head -1
    }

    SLOT=$(fget img_slot | $BB tr -cd 'a-z0-9')
    EXT=$( fget img_ext  | $BB tr -cd 'a-z0-9' | $BB cut -c1-5)
    
    # Bypassing the slow character-by-character awk urldecode for the massive base64 payload.
    # Base64 only percent-encodes +, /, and = which we can decode instantly using sed.
    B64=$(printf '%s' "$POST_DATA" \
        | $BB tr '&' '\n' \
        | $BB grep "^img_data=" \
        | $BB sed 's/^img_data=//; s/%2B/+/g; s/%2F/\//g; s/%3D/=/g; s/%2b/+/g; s/%2f/\//g; s/%3d/=/g')

    case "$SLOT" in logo|promo1|promo2|promo3|promo4|promo5) ;; *) err_json "bad_slot" ;; esac
    case "$EXT"  in jpg|jpeg|png|ico|gif|webp) ;; *) err_json "bad_ext" ;; esac
    [ -z "$B64" ] && err_json "no_data"

    case "$SLOT" in
        logo)
            DEST="/lmepisowifi/hotspot/img/portal_logo.${EXT}"
            ;;
        promo*)
            PNUM="${SLOT#promo}"
            # Remove any existing promo with a different extension before saving
            rm -f "/lmepisowifi/hotspot/img/promo${PNUM}".*  2>/dev/null
            DEST="/lmepisowifi/hotspot/img/promo${PNUM}.${EXT}"
            ;;
    esac

    # Disk-space guard: reject before writing if the file would breach the 10 MB floor
    # B64 chars × 3/4 ≈ decoded bytes (slight overestimate — safe to use for comparison)
    _img_avkb=$($BB df -k /lmepisowifi 2>/dev/null | $BB awk 'NR==2 {print $4+0}')
    _img_avail=$(( ${_img_avkb:-0} * 1024 ))
    _img_b64len=$(printf '%s' "$B64" | $BB wc -c | $BB tr -cd '0-9')
    _img_fsize=$(( (${_img_b64len:-0} * 3 + 3) / 4 ))
    [ $(( _img_avail - _img_fsize )) -lt 10485760 ] && err_json "insufficient_space"

    if ! printf '%s' "$B64" | $BB base64 -d > "${DEST}.tmp" 2>/dev/null; then
        printf '%s' "$B64" | openssl enc -d -base64 -A > "${DEST}.tmp" 2>/dev/null \
            || { rm -f "${DEST}.tmp"; err_json "decode_failed"; }
    fi
    $BB mv "${DEST}.tmp" "$DEST"

    # Only logo upload needs portal.env update
    if [ "$SLOT" = "logo" ]; then
        IMG_PATH="/img/portal_logo.${EXT}"
        PCFG="$HDATA/portal.env"
        PORTAL_TITLE="lmepisowifi"; PORTAL_BRAND="beta"; PORTAL_LOGO="/img/favicon.ico"
        [ -f "$PCFG" ] && . "$PCFG" 2>/dev/null
        PORTAL_LOGO="$IMG_PATH"
        mkdir -p "$HDATA"
        { printf 'PORTAL_TITLE="%s"\n' "$PORTAL_TITLE"
          printf 'PORTAL_BRAND="%s"\n' "$PORTAL_BRAND"
          printf 'PORTAL_LOGO="%s"\n'  "$PORTAL_LOGO"; } > "$PCFG.tmp"
        $BB mv "$PCFG.tmp" "$PCFG"
        ok_json "{\"ok\":true,\"path\":\"$(esc_json "$IMG_PATH")\"}"
    else
        IMG_PATH="/img/promo${PNUM}.${EXT}"
        ok_json "{\"ok\":true,\"path\":\"$(esc_json "$IMG_PATH")\"}"
    fi
fi

# ================================================================
# POST ?action=portal_clear_promo  body: promo_slot=promo1..promo5
# Removes the promo image file(s) for the given slot
# ================================================================
if echo "$QS" | $BB grep -q "action=portal_clear_promo"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    fget() {
        printf '%s' "$POST_DATA" \
            | $BB tr '&' '\n' \
            | $BB grep "^$1=" \
            | $BB sed 's/^[^=]*=//' \
            | urldecode \
            | head -1
    }
    SLOT=$(fget promo_slot | $BB tr -cd 'a-z0-9')
    case "$SLOT" in promo1|promo2|promo3|promo4|promo5) ;; *) err_json "bad_slot" ;; esac
    PNUM="${SLOT#promo}"
    rm -f "/lmepisowifi/hotspot/img/promo${PNUM}".* 2>/dev/null
    ok_json "{\"ok\":true}"
fi

# ================================================================
# POST ?action=portal_audio_upload
# body: audio_slot=bg_music|coin_sound & audio_ext=mp3|ogg|wav & audio_data=<base64>
# Saves audio to /lmepisowifi/hotspot/audio/<slot>.<ext>
# ================================================================
if echo "$QS" | $BB grep -q "action=portal_audio_upload"; then
    read -n "$CONTENT_LENGTH" POST_DATA

    fget() {
        printf '%s' "$POST_DATA" \
            | $BB tr '&' '\n' \
            | $BB grep "^$1=" \
            | $BB sed 's/^[^=]*=//' \
            | urldecode \
            | head -1
    }

    SLOT=$(fget audio_slot | $BB tr -cd 'a-z_')
    EXT=$( fget audio_ext  | $BB tr -cd 'a-z0-9' | $BB cut -c1-4)

    # Base64: only +, /, = and = need re-encoding
    B64=$(printf '%s' "$POST_DATA" \
        | $BB tr '&' '\n' \
        | $BB grep "^audio_data=" \
        | $BB sed 's/^audio_data=//; s/%2B/+/g; s/%2F/\//g; s/%3D/=/g; s/%2b/+/g; s/%2f/\//g; s/%3d/=/g')

    case "$SLOT" in bg_music|coin_sound|insert_bg_music) ;; *) err_json "bad_slot" ;; esac
    case "$EXT"  in mp3|ogg|wav)         ;; *) err_json "bad_ext"  ;; esac
    [ -z "$B64" ] && err_json "no_data"

    mkdir -p /lmepisowifi/hotspot/audio
    # Remove any existing file for this slot (different extension)
    rm -f "/lmepisowifi/hotspot/audio/${SLOT}".* 2>/dev/null
    DEST="/lmepisowifi/hotspot/audio/${SLOT}.${EXT}"

    # Disk-space guard: reject before writing if the file would breach the 10 MB floor
    _aud_avkb=$($BB df -k /lmepisowifi 2>/dev/null | $BB awk 'NR==2 {print $4+0}')
    _aud_avail=$(( ${_aud_avkb:-0} * 1024 ))
    _aud_b64len=$(printf '%s' "$B64" | $BB wc -c | $BB tr -cd '0-9')
    _aud_fsize=$(( (${_aud_b64len:-0} * 3 + 3) / 4 ))
    [ $(( _aud_avail - _aud_fsize )) -lt 10485760 ] && err_json "insufficient_space"

    if ! printf '%s' "$B64" | $BB base64 -d > "${DEST}.tmp" 2>/dev/null; then
        printf '%s' "$B64" | openssl enc -d -base64 -A > "${DEST}.tmp" 2>/dev/null \
            || { rm -f "${DEST}.tmp"; err_json "decode_failed"; }
    fi
    $BB mv "${DEST}.tmp" "$DEST"

    ok_json "{\"ok\":true,\"path\":\"/audio/${SLOT}.${EXT}\"}"
fi

# ================================================================
# POST ?action=portal_audio_clear  body: audio_slot=bg_music|coin_sound
# Removes the audio file for the given slot
# ================================================================
if echo "$QS" | $BB grep -q "action=portal_audio_clear"; then
    read -n "$CONTENT_LENGTH" POST_DATA
    fget() {
        printf '%s' "$POST_DATA" \
            | $BB tr '&' '\n' \
            | $BB grep "^$1=" \
            | $BB sed 's/^[^=]*=//' \
            | urldecode \
            | head -1
    }
    SLOT=$(fget audio_slot | $BB tr -cd 'a-z_')
    case "$SLOT" in bg_music|coin_sound|insert_bg_music) ;; *) err_json "bad_slot" ;; esac
    rm -f "/lmepisowifi/hotspot/audio/${SLOT}".* 2>/dev/null
    ok_json "{\"ok\":true}"
fi

# ================================================================
# POST ?action=anti_tether_set   body: enabled=1|0
# Enables or disables anti-tethering (TTL-based blocking of shared
# sessions).  The iptables chain is managed directly so the change
# takes effect immediately without a hotspot restart.
# ================================================================
if echo "$QS" | $BB grep -q "action=anti_tether_set"; then
    read -n "${CONTENT_LENGTH:-0}" POST_DATA
    VAL=$(printf '%s' "$POST_DATA" | $BB sed -n 's/.*enabled=\([^&]*\).*/\1/p')
    HBR="${HOTSPOT_BR:-$(read_lmehspt_var HOTSPOT_BR)}"
    HBR="${HBR:-br1}"
    AT_CHAIN="HOTSPOT_AT"
    if [ "$VAL" = "1" ]; then
        # Build/refresh the chain
        iptables -t mangle -N "$AT_CHAIN" 2>/dev/null
        iptables -t mangle -F "$AT_CHAIN" 2>/dev/null
        # Try xt_ttl; fall back to u32 matching of TTL byte (offset 0x8, top byte)
        iptables -t mangle -A "$AT_CHAIN" -m ttl --ttl-lt 64 -j DROP 2>/dev/null || \
            iptables -t mangle -A "$AT_CHAIN" -m u32 --u32 "0x8 >> 24 & 0xFF = 0:63" -j DROP 2>/dev/null
        iptables -t mangle -D FORWARD -i "$HBR" -j "$AT_CHAIN" 2>/dev/null
        iptables -t mangle -I FORWARD 1 -i "$HBR" -j "$AT_CHAIN" 2>/dev/null
        save_coin_env_var "ANTI_TETHER" "1"
        set_lmehspt_var   "ANTI_TETHER" "1"
        ok_json "{\"ok\":true,\"anti_tether\":true}"
    else
        # Tear down the chain
        iptables -t mangle -D FORWARD -i "$HBR" -j "$AT_CHAIN" 2>/dev/null
        iptables -t mangle -F "$AT_CHAIN" 2>/dev/null
        iptables -t mangle -X "$AT_CHAIN" 2>/dev/null
        save_coin_env_var "ANTI_TETHER" "0"
        set_lmehspt_var   "ANTI_TETHER" "0"
        ok_json "{\"ok\":true,\"anti_tether\":false}"
    fi
fi

# ================================================================
# Fallback
# ================================================================
printf "Status: 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"ok\":false,\"error\":\"unknown_action\"}"
