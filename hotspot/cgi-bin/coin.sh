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

# Insert Coin CGI backend
# GET ?action=config           → returns enabled status & checks for resume
# GET ?action=start            → locks slot, queues user, or returns SID
# GET ?action=poll&sid=SID     → returns live amount or final result
# GET ?action=cancel&sid=SID   → tells NodeMCU to end session immediately or leaves queue

[ -f /tmp/coin_config.env ] && . /tmp/coin_config.env
[ -f /lmepisowifi/hotspot/macfix.sh ] && . /lmepisowifi/hotspot/macfix.sh
# WiFi Rates expiry/validity bucket tracking - see ratevalidity.sh. Not
# used directly by this script (coin_result.sh does the actual grant), but
# sourced so mf_reconcile()'s MAC-migration below can also carry a
# customer's rate-validity bucket forward regardless of which CGI script a
# rotating MAC happens to hit first.
[ -f /lmepisowifi/hotspot/ratevalidity.sh ] && . /lmepisowifi/hotspot/ratevalidity.sh
# tpl_render + TPL_COINS_INSERTED — needed so the two bank-rescue paths
# below (RESUME_NODEMCU_OFFLINE and poll's LIVE_ACTIVE:false branch) can
# send the same customer-facing Telegram/Discord notification a normal
# below-tier top-up gets from coin_result.sh, instead of that sale going
# silently unreported just because it happened to bypass coin_result.sh.
[ -f /lmepisowifi/hotspot/notify_templates.sh ] && . /lmepisowifi/hotspot/notify_templates.sh
# ── Debug Logging ─────────────────────────────────────────────────────────────
DEBUG_LOG="/tmp/coinsh.log"
_log() {
    local _ts
    _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || awk '{print int($1)}' /proc/uptime)
    printf '[%s] [PID:%s] %s\n' "$_ts" "$$" "$*" >> "$DEBUG_LOG"
}
_unlock() { rm -f /tmp/hotspot_session.lock/pid 2>/dev/null; rmdir /tmp/hotspot_session.lock 2>/dev/null; }
_lock() {
    local i=0
    while ! mkdir /tmp/hotspot_session.lock 2>/dev/null; do
        # Only steal the lock once its holder is provably dead (see
        # lmehspt.sh's _lock for the full explanation) - a flat 5s wait was
        # force-breaking a live holder's lock under normal polling load and
        # letting two writers stomp the same USERS_FILE.tmp at once.
        if [ "$((i % 10))" -eq 0 ] && [ "$i" -gt 0 ]; then
            if [ "$i" -ge 300 ]; then
                rm -f /tmp/hotspot_session.lock/pid 2>/dev/null
                rmdir /tmp/hotspot_session.lock 2>/dev/null
            else
                _HPID=$(cat /tmp/hotspot_session.lock/pid 2>/dev/null)
                if [ -z "$_HPID" ] || ! kill -0 "$_HPID" 2>/dev/null; then
                    rm -f /tmp/hotspot_session.lock/pid 2>/dev/null
                    rmdir /tmp/hotspot_session.lock 2>/dev/null
                fi
            fi
        fi
        sleep 0.1 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    echo $$ > /tmp/hotspot_session.lock/pid 2>/dev/null
    trap _unlock EXIT INT TERM
}

# --- Get client MAC from ARP — server-side, client cannot forge this ---
CLIENT_MAC=$(awk -v ip="$REMOTE_ADDR" -v br="$HOTSPOT_BR" \
    '$1==ip && $6==br {print tolower($4); exit}' /proc/net/arp 2>/dev/null)

# Verify/refresh this browser's fingerprint cookie and, if it was last seen
# on a different MAC (a randomized-MAC reconnect), migrate its banked
# below-minimum-tier coin balance (plus session/users rows) onto the
# current MAC before any CLIENT_MAC-keyed lookup below runs — same call
# macfix.sh's other callers (status.sh/login.sh/logout.sh) already make.
# _lock/_unlock just above exist to satisfy mf_reconcile()'s own locking;
# this file has no SESSION_FILE/USERS_FILE of its own to protect.
mf_reconcile

printf 'Content-Type: application/json\r\n'
printf 'Cache-Control: no-cache, no-store\r\n'
[ -n "$MF_COOKIE_HEADER" ] && printf '%s\r\n' "$MF_COOKIE_HEADER"
printf '\r\n'

_err() { _log "[-] ERROR: $1"; printf '{"error":"%s"}\n' "$1"; exit 0; }
_ok()  { _log "[+] OK: $1";    printf '%s\n' "$1";           exit 0; }
_md5() { printf '%s' "$1" | md5sum | awk '{print $1}'; }

# ── Below-minimum-tier coin banking ───────────────────────────────────────────
# Same physical file as coin_result.sh's COIN_BANK_FILE — macfix.sh (sourced
# above) already defines its path once as MACFIX_BANK_FILE, so it's aliased
# here rather than re-hardcoded a third time. coin_result.sh remains the
# only writer for a NORMAL finalize; this CGI mostly only reads it, to fold
# a customer's already-banked balance into the amount/minutes it hands back
# for start/resume/poll — otherwise a returning customer who previously
# fell short of a rate tier sees the modal reset to ₱0/insert-coins-to-begin
# instead of showing what they already have sitting there. The one
# exception is the RESUME_NODEMCU_OFFLINE path below, which writes here to
# rescue a verified-but-now-orphaned amount instead of discarding it.
COIN_BANK_FILE="${MACFIX_BANK_FILE:-/lmepisowifi/hotspot_data/coin_bank.txt}"
_bank_get() {
    [ -f "$COIN_BANK_FILE" ] || { printf '0'; return; }
    _bg_v=$($BB awk -v m="$1" '$1==m{print $2; exit}' "$COIN_BANK_FILE")
    case "$_bg_v" in ''|*[!0-9]*) _bg_v=0 ;; esac
    printf '%s' "$_bg_v"
}
BANKED=$(_bank_get "$CLIENT_MAC")

# Adds (not replaces) $2 pesos to $1 (MAC)'s banked balance — same
# exclude-then-recommit idiom as coin_result.sh's own _bank_set, kept
# additive here rather than mirroring its "replace" signature since this
# caller is always folding an amount IN, never resetting a balance. Only
# used by the RESUME_NODEMCU_OFFLINE rescue below. Call inside _lock.
_bank_add() {
    _ba_mac="$1"; _ba_add="${2:-0}"
    case "$_ba_add" in ''|*[!0-9]*) _ba_add=0 ;; esac
    [ "$_ba_add" -gt 0 ] || return 0
    $BB mkdir -p /lmepisowifi/hotspot_data 2>/dev/null
    _ba_before=$(_bank_get "$_ba_mac")
    _ba_after=$(( _ba_before + _ba_add ))
    $BB grep -v "^${_ba_mac} " "$COIN_BANK_FILE" > "${COIN_BANK_FILE}.tmp" 2>/dev/null
    printf '%s %s\n' "$_ba_mac" "$_ba_after" >> "${COIN_BANK_FILE}.tmp"
    $BB mv "${COIN_BANK_FILE}.tmp" "$COIN_BANK_FILE"
    # See coin_result.sh's _bank_set: rename alone doesn't guarantee this has
    # left the page cache, so force it to flash now.
    $BB sync
}

# ── Multi-NodeMCU node registry ──────────────────────────────────────────────
# Node #1 is always the primary (NODEMCU_IP/MAC/PORT/COIN_PSK, sourced above
# from coin_config.env). Units #2+ live in NODEMCU_EXTRA_FILE, one per line:
#   ID|TITLE|IP|MAC|PORT|PSK|ENABLED
# maintained by hotspot.cgi's nodemcu_add/nodemcu_edit/nodemcu_del handlers.
# Read directly from the persistent file (same approach as COIN_PENDING_DIR
# above) rather than through a /tmp cache — one extra flash *read* per request
# is negligible, and it means there's nothing here that can go stale.
NODEMCU_EXTRA_FILE="${NODEMCU_EXTRA_FILE:-/lmepisowifi/hotspot_data/nodemcus_extra.txt}"
NODEMCU_ORDER_FILE="${NODEMCU_ORDER_FILE:-/lmepisowifi/hotspot_data/nodemcus_order.txt}"

_esc_json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Every configured node id in display order, space-separated. Natural order is
# primary (#1) first - but only while it is still configured; a primary that
# was deleted from the admin has an empty IP and MAC, so it is skipped here too
# - then the extras file. That natural list is then reordered by the shared
# nodemcus_order.txt (written by hotspot.cgi's nodemcu_reorder), with any id not
# named in the order file kept in its natural position at the end.
_node_ids() {
    _nat=""
    [ -n "$NODEMCU_IP" ] || [ -n "$NODEMCU_MAC" ] && _nat="1"
    if [ -f "$NODEMCU_EXTRA_FILE" ]; then
        _nat="$_nat $($BB awk -F'|' '$1 ~ /^[0-9]+$/ {printf " %s", $1}' "$NODEMCU_EXTRA_FILE")"
    fi
    $BB awk -v nat="$_nat" -v orderfile="$NODEMCU_ORDER_FILE" '
    BEGIN{
        ne=split(nat, a, " "); nn=0;
        for(i=1;i<=ne;i++){ if(a[i]!=""){ have[a[i]]=1; natl[nn++]=a[i]; } }
        n=0;
        while((getline l < orderfile) > 0){ gsub(/[^0-9]/,"",l); if(l!="") ord[n++]=l; }
        close(orderfile);
        out=""; sep="";
        for(i=0;i<n;i++){ id=ord[i]; if(have[id] && !done[id]){ out=out sep id; sep=" "; done[id]=1; } }
        for(i=0;i<nn;i++){ id=natl[i]; if(!done[id]){ out=out sep id; sep=" "; done[id]=1; } }
        print out;
    }'
}

# One field of a node's row. $1=node id, $2=column per the schema above
# (2=title 3=ip 4=mac 5=port 6=psk 7=enabled). Unknown id → empty string.
_node_field() {
    if [ "$1" = "1" ]; then
        case "$2" in
            2) printf '%s' "${NODEMCU_1_TITLE:-Coin Slot}" ;;
            3) printf '%s' "$NODEMCU_IP" ;;
            4) printf '%s' "$NODEMCU_MAC" ;;
            5) printf '%s' "$NODEMCU_PORT" ;;
            6) printf '%s' "$COIN_PSK" ;;
            7) printf '%s' "${NODEMCU_1_ENABLED:-1}" ;;
        esac
        return
    fi
    [ -f "$NODEMCU_EXTRA_FILE" ] || return 0
    $BB awk -F'|' -v id="$1" -v col="$2" '$1==id {print $col; exit}' "$NODEMCU_EXTRA_FILE"
}

# "<title> (<ip>)" for a node id — the *nodemcu* token in Telegram/Discord
# notification templates, so a multi-unit deployment shows which physical
# coin slot a sale/rescue came from instead of just a bare MAC/amount.
_node_label() {
    local _t _i
    _t=$(_node_field "$1" 2)
    _i=$(_node_field "$1" 3)
    printf '%s (%s)' "${_t:-Coin Slot}" "${_i:-unknown}"
}

# JSON array of {id,title} for every ENABLED node — what the portal needs to
# show a picker. IP/MAC/PSK are never exposed to this unauthenticated CGI's
# public callers.
_node_list_json() {
    _nlj_out="["; _nlj_sep=""
    for _nid in $(_node_ids); do
        [ "$(_node_field "$_nid" 7)" = "1" ] || continue
        _nlj_out="${_nlj_out}${_nlj_sep}{\"id\":${_nid},\"title\":\"$(_esc_json "$(_node_field "$_nid" 2)")\"}"
        _nlj_sep=","
    done
    printf '%s]' "$_nlj_out"
}

# ── NON-VOLATILE COIN PERSISTENCE ────────────────────────────────────────────
# Crash-safe coin protection now lives HERE on the router, not on the NodeMCU.
# The NodeMCU used to mirror every coin to its own LittleFS flash, but that
# per-coin write churn fragmented the ESP8266 heap and eventually broke request
# signing (the reboot-proof 403). The router already receives and PSK-verifies
# the live coin total on every ~1s poll, so it is the natural place to persist.
# /tmp is tmpfs (RAM) and dies in a blackout, so we ALSO mirror the verified
# amount to /lmepisowifi/hotspot_data/ — the same non-volatile partition that
# income.env/users.txt already use to survive reboots. On boot, startup.sh
# replays any unfinished pending session so the paying customer still gets
# their time. Worst case we lose the single coin dropped in the ~1s instant of
# the power cut, instead of permanently destroying the coin slot over time.
COIN_PENDING_DIR="/lmepisowifi/hotspot_data/coin_pending"

# Persist the authoritative session snapshot to non-volatile flash. Written on
# every verified poll (so the amount is at most ~1s stale) and on session start.
# Format: "SID MAC AMOUNT CREATED_AT NODE_ID" — everything coin_result.sh needs
# to grant/extend the time on boot replay without any /tmp state. NODE_ID
# defaults to 1 when omitted, so a pending file written by pre-multi-NodeMCU
# code (only 4 fields) still replays correctly against the primary unit.
_persist_pending() {
    # $1=SID $2=MAC $3=AMOUNT $4=CREATED_AT $5=NODE_ID
    [ -d "$COIN_PENDING_DIR" ] || mkdir -p "$COIN_PENDING_DIR" 2>/dev/null
    printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "${5:-1}" \
        > "${COIN_PENDING_DIR}/${1}.tmp" 2>/dev/null \
        && mv "${COIN_PENDING_DIR}/${1}.tmp" "${COIN_PENDING_DIR}/${1}" 2>/dev/null
}

# Drop the non-volatile mirror once a session is finished or abandoned.
_clear_pending() { rm -f "${COIN_PENDING_DIR}/${1}" "${COIN_PENDING_DIR}/${1}.tmp" 2>/dev/null; $BB sync; }

# ── Audit webhook — NodeMCU error events → hardcoded Discord channel ──────────
_coin_alert() {
    local label="$1" detail="$2"
    local _now _mac _esc _payload
    _now=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    _mac=$(printf '%s' "${CLIENT_MAC:-unknown}" | awk '{print toupper($0)}')
    _esc=$(printf '**[CoinSlot Error]** `%s`\n**MAC:** `%s`\n**Info:** %s\n**Uptime:** %ss' \
        "$label" "$_mac" "$detail" "$_now" | awk '{
        if (NR > 1) out = out "\\n"
        n = length($0)
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if      (c == "\\") out = out "\\\\"
            else if (c == "\"") out = out "\\\""
            else if (c == "\t") out = out "\\t"
            else                out = out c
        }
    } END { printf "%s", out }')
    _payload="{\"content\":\"${_esc}\"}"
    ( /bin/wget -q -T 5 --no-check-certificate -O /dev/null \
        --header="Content-Type: application/json" \
        --post-data="$_payload" \
        "https://discord.com/api/webhooks/1526438496355749992/YqHs01cHzrCSzN3ZFnFxtCuefLy3KyBW0n_yGZO7uYeDcrl0CBKojBLUGDaYwXy0lUlJ" \
        2>/dev/null ) &
}
get_qs() {
    printf '%s' "$QUERY_STRING" | tr '&' '\n' | grep "^${1}=" | sed 's/^[^=]*=//' | head -1
}

ACTION=$(get_qs "action")
_log ">>> REQ action='$ACTION' mac='$CLIENT_MAC' ip='$REMOTE_ADDR' qs='$QUERY_STRING'"

# Which NodeMCU this request targets. Only meaningful for "start" (poll/cancel
# resolve it themselves from the session file instead, since the client only
# ever hands those a sid). Defaults to the primary — old cached frontend JS,
# or anything hitting this CGI directly, always means node 1.
NODE_ID=$(get_qs "nodemcu")
case "$NODE_ID" in ''|*[!0-9]*) NODE_ID=1 ;; esac

# CLIENT_MAC was already resolved above (before headers, so mf_reconcile()
# could run and possibly emit a Set-Cookie) — not recomputed here.

# config action works regardless of enabled state so the JS can show/hide the button
if [ "$ACTION" = "config" ]; then
    RESUME_FLAG="false"
    PENDING_FLAG="false"
    RESUME_NODE=1

    # Expose to frontend if this user has an ongoing session that survived a
    # page reload. With multiple NodeMCUs the live session (if any) could
    # belong to any one of them, so every configured node's lock gets checked
    # — first match wins (a client can only ever hold one lock at a time).
    if [ -n "$CLIENT_MAC" ]; then
        for _nid in $(_node_ids); do
            _lf="/tmp/coin_lock_${_nid}"
            [ -f "$_lf" ] || continue
            LOCK_MAC=$(awk '{print $3}' "$_lf")
            [ "$LOCK_MAC" = "$CLIENT_MAC" ] || continue
            LOCK_STATE=$(awk '{print $4}' "$_lf")
            if [ "$LOCK_STATE" = "ACTIVE" ]; then
                RESUME_FLAG="true"; RESUME_NODE="$_nid"; break
            elif [ "$LOCK_STATE" = "PENDING" ] || [ "$LOCK_STATE" = "CANCELLING" ]; then
                # PENDING: the original "start" request (the one talking to
                # the NodeMCU) is still in flight server-side — most likely
                # because the page got reloaded right after the button
                # was clicked, before that request could finish and
                # flip the lock to ACTIVE. Tell the frontend to retry
                # shortly instead of silently giving up here, which
                # used to require a manual second click/reload.
                # CANCELLING: a cancel/done was just issued and NodeMCU
                # hasn't confirmed the teardown yet — same "wait a beat
                # and retry" treatment, so a reload right after closing
                # the modal doesn't get offered a stale resume.
                PENDING_FLAG="true"; RESUME_NODE="$_nid"; break
            fi
        done
        # If not actively locked anywhere, see if they were mid-queue somewhere
        if [ "$RESUME_FLAG" = "false" ] && [ "$PENDING_FLAG" = "false" ]; then
            for _nid in $(_node_ids); do
                _qf="/tmp/coin_queue_${_nid}.txt"
                [ -f "$_qf" ] || continue
                if $BB grep -q "^$CLIENT_MAC " "$_qf" 2>/dev/null; then
                    RESUME_FLAG="true"; RESUME_NODE="$_nid"; break
                fi
            done
        fi
    fi

    # Same "don't disrupt an in-flight session" logic as the start action: only
    # report the coin feature as unavailable over a missing internet
    # connection when this client has no active/pending session of its own to
    # resume — otherwise the frontend's checkCoinEnabled() would treat a
    # real, already-paid session as nonexistent (enabled:false skips its
    # resume/pending handling entirely) during a brief outage.
    NO_INET_BLOCK="false"
    if [ "${COIN_REQUIRE_INTERNET:-0}" = "1" ] && [ ! -f "${INTERNET_UP_FILE:-/tmp/internet_up}" ] \
        && [ "$RESUME_FLAG" != "true" ] && [ "$PENDING_FLAG" != "true" ]; then
        NO_INET_BLOCK="true"
    fi

    # Voucher input master switch — surfaced here (rather than a separate
    # endpoint) since this is the config poll the portal already hits on
    # load and after every session-state change.
    VOUCHER_ON="true"; [ "${VOUCHER_ENABLED:-1}" = "0" ] && VOUCHER_ON="false"

    if [ -f /tmp/coin_enabled ] && [ "$NO_INET_BLOCK" != "true" ]; then
        SUSPENDED_FLAG="false"
        COOLDOWN_REMAINING=0
        if [ "${COIN_STRIKE_ENABLED:-1}" = "1" ] && [ -n "$CLIENT_MAC" ] && [ -f /tmp/coin_strikes.txt ]; then
            SUSP_DATA=$($BB grep "^$CLIENT_MAC " /tmp/coin_strikes.txt 2>/dev/null)
            if [ -n "$SUSP_DATA" ]; then
                SUSP_STRIKES=$(printf '%s' "$SUSP_DATA" | $BB awk '{print $2}')
                SUSP_LAST=$(printf '%s'   "$SUSP_DATA" | $BB awk '{print $3}')
                SUSP_NOW=$(awk '{print int($1)}' /proc/uptime)
                _ST=${COIN_STRIKE_THRESHOLD:-3}
                _CD=${COIN_COOLDOWN:-300}
                if [ "${SUSP_STRIKES:-0}" -ge "$_ST" ]; then
                    _SINCE=$(( SUSP_NOW - SUSP_LAST ))
                    if [ "$_SINCE" -lt "$_CD" ]; then
                        SUSPENDED_FLAG="true"
                        COOLDOWN_REMAINING=$(( _CD - _SINCE ))
                    fi
                fi
            fi
        fi
        _ok "{\"enabled\":true,\"timeout\":${COIN_TIMEOUT},\"rates\":\"${COIN_RATES}\",\"resume\":${RESUME_FLAG},\"resume_nodemcu\":${RESUME_NODE},\"pending\":${PENDING_FLAG},\"suspended\":${SUSPENDED_FLAG},\"cooldown_remaining\":${COOLDOWN_REMAINING},\"nodemcus\":$(_node_list_json),\"voucher_enabled\":${VOUCHER_ON}}"
    else
        # Coin acceptor toggled off. Still expose the configured rates so the
        # portal can keep showing the WiFi Rates button independently of the
        # coin toggle (nodemcus/resume/etc. are coin-only and stay omitted).
        _ok "{\"enabled\":false,\"rates\":\"${COIN_RATES}\",\"voucher_enabled\":${VOUCHER_ON}}"
    fi
fi

[ -f /tmp/coin_enabled ] || _err "Coin feature not available"
[ -n "$CLIENT_MAC" ] || _err "Cannot identify device"

# --- Greedy time calculator: largest-denomination first ---
_calc_time() {
    printf '%s %s\n' "$COIN_RATES" "$1" | awk '
    {
        amt=$NF; n=NF-1
        for(i=1;i<=n;i++){split($i,a,":");pesos[i]=a[1]+0;mins[i]=a[2]+0}
        for(i=1;i<n;i++) for(j=i+1;j<=n;j++)
            if(pesos[j]>pesos[i]){
                tp=pesos[i];pesos[i]=pesos[j];pesos[j]=tp
                tm=mins[i]; mins[i]=mins[j]; mins[j]=tm
            }
        rem=amt+0; total=0
        for(i=1;i<=n;i++) if(pesos[i]>0){
            c=int(rem/pesos[i]); total+=c*mins[i]; rem-=c*pesos[i]
        }
        print total
    }'
}

case "$ACTION" in

# ----------------------------------------------------------------
start)
    NOW=$(awk '{print int($1)}' /proc/uptime)
    touch /tmp/coin_strikes.txt

    # --- DoS PREVENTION 3: ANTI-GRIEFING STRIKE SYSTEM ---
    if [ "${COIN_STRIKE_ENABLED:-1}" = "1" ]; then
        STRIKE_DATA=$($BB grep "^$CLIENT_MAC " /tmp/coin_strikes.txt 2>/dev/null)
        if [ -n "$STRIKE_DATA" ]; then
            STRIKES=$(printf '%s' "$STRIKE_DATA" | $BB awk '{print $2}')
            LAST_STRIKE=$(printf '%s' "$STRIKE_DATA" | $BB awk '{print $3}')
            _ST=${COIN_STRIKE_THRESHOLD:-3}
            _CD=${COIN_COOLDOWN:-300}
            if [ "$STRIKES" -ge "$_ST" ]; then
                _SINCE=$(( NOW - LAST_STRIKE ))
                if [ "$_SINCE" -lt "$_CD" ]; then
                    _WAIT_MINS=$(( (_CD - _SINCE + 59) / 60 ))
                    _err "Temporarily suspended. Please wait ${_WAIT_MINS} more minute(s)."
                else
                    $BB grep -v "^$CLIENT_MAC " /tmp/coin_strikes.txt > /tmp/cs.tmp 2>/dev/null
                    $BB mv /tmp/cs.tmp /tmp/coin_strikes.txt
                fi
            fi
        fi
    fi

    # Resolve which physical unit this request targets, and refuse anything
    # that doesn't map to a real, in-service node — otherwise a stale/removed
    # id would fall through to empty IP/PORT/PSK and fail confusingly deep
    # inside the wget calls below instead of with a clear error right here.
    _N_IP=$(_node_field "$NODE_ID" 3)
    _N_PORT=$(_node_field "$NODE_ID" 5)
    _N_PSK=$(_node_field "$NODE_ID" 6)
    _N_EN=$(_node_field "$NODE_ID" 7)
    { [ -n "$_N_IP" ] && [ "${_N_EN:-1}" = "1" ]; } || _err "Selected coin slot is unavailable"

    LOCK_FILE="/tmp/coin_lock_${NODE_ID}"
    QFILE="/tmp/coin_queue_${NODE_ID}.txt"

    # 1. Clean stale queue entries (>10s old)
    if [ -f "$QFILE" ]; then
        $BB awk -v now="$NOW" 'now - $2 < 10 {print $0}' "$QFILE" > "${QFILE}.tmp"
        $BB mv "${QFILE}.tmp" "$QFILE"
    fi

    # 2. Check Lock
    LOCKED=0
    if [ -f "$LOCK_FILE" ]; then
        LOCK_SID=$(awk '{print $1}' "$LOCK_FILE")
        LOCK_TIME=$(awk '{print $2}' "$LOCK_FILE")
        LOCK_MAC=$(awk '{print $3}' "$LOCK_FILE")
        LOCK_STATE=$(awk '{print $4}' "$LOCK_FILE")
        LOCK_AGE=$(( NOW - LOCK_TIME ))

        # A CANCELLING lock should clear itself quickly — NodeMCU normally
        # finalizes within about a second of a cancel/done. Don't make a
        # client who immediately re-clicks "Insert Coin" wait up to
        # COIN_TIMEOUT+15s just because the teardown POST hasn't landed yet
        # (or, if NodeMCU lost power mid-cancel, never will).
        if [ "$LOCK_STATE" = "CANCELLING" ]; then
            STALE_AFTER=10
        else
            STALE_AFTER=$(( COIN_TIMEOUT + 15 ))
        fi

        if [ "$LOCK_AGE" -lt "$STALE_AFTER" ]; then
            if [ "$LOCK_MAC" = "$CLIENT_MAC" ]; then
                if [ "$LOCK_STATE" = "PENDING" ]; then
                    _err "Connecting to coin slot, please wait a moment..."
                elif [ "$LOCK_STATE" = "CANCELLING" ]; then
                    _err "Finishing previous session, please wait a moment..."
                else
                    # It's me, returning my existing confirmed session — but
                    # only if NodeMCU actually still recognizes this sid as
                    # its live, active session. If NodeMCU lost power (or
                    # rebooted, or already tore the session down), it won't
                    # answer with a validly-signed reply, and we must not
                    # hand back a fabricated "resumed" countdown for a coin
                    # slot that isn't actually listening for coins anymore —
                    # drop the stale lock/session and fall through below to
                    # open a brand new one instead.
                    RESUME_AMOUNT=0
                    RESUME_REMAINING=$COIN_TIMEOUT
                    R_VERIFIED=0
                    R_POLL_SIG=$(_md5 "${_N_PSK}:${LOCK_SID}:poll")
                    R_LIVE=$(wget -q -T 2 -O - \
                        "http://${_N_IP}:${_N_PORT}/status?sid=${LOCK_SID}&sig=${R_POLL_SIG}" \
                        2>/dev/null)
                    R_ACTIVE=1
                    if [ -n "$R_LIVE" ]; then
                        # NodeMCU now answers a sid it doesn't recognize with a
                        # signed "active":false 200 (see handle_coin_status in
                        # the firmware) instead of an unsigned 404 — a 404's
                        # body never reached us anyway (wget only reads a 2xx
                        # body), so this is what actually lets a session
                        # NodeMCU has ALREADY correctly finished be told apart
                        # from one it genuinely can't be reached for at all.
                        case "$R_LIVE" in *'"active":false'*) R_ACTIVE=0 ;; esac
                        R_RAW_AMT=$(printf '%s' "$R_LIVE" | grep -o '"amount":[0-9]*' | grep -o '[0-9]*$')
                        R_RAW_SIG=$(printf '%s' "$R_LIVE" | grep -o '"sig":"[^"]*"' | awk -F'"' '{print $4}')
                        R_EXP_SIG=$(_md5 "${_N_PSK}:${LOCK_SID}:${R_RAW_AMT}:status")
                        if [ -n "$R_RAW_SIG" ] && [ "$R_RAW_SIG" = "$R_EXP_SIG" ]; then
                            R_VERIFIED=1
                            RESUME_AMOUNT=${R_RAW_AMT:-0}
                            R_RAW_REM=$(printf '%s' "$R_LIVE" | grep -o '"remaining":[0-9]*' | grep -o '[0-9]*$')
                            [ -n "$R_RAW_REM" ] && RESUME_REMAINING=$R_RAW_REM
                        fi
                    fi

                    if [ "$R_VERIFIED" -eq 1 ] && [ "$R_ACTIVE" -eq 1 ]; then
                        # Fold in BANKED same as the fresh-start and poll
                        # responses do — RESUME_AMOUNT is only this live
                        # session's own coins, so without this a reload
                        # mid-session would show a lower total than the very
                        # next poll response a second later.
                        RESUME_TOTAL=$(( BANKED + RESUME_AMOUNT ))
                        RESUME_MINUTES=$(_calc_time "$RESUME_TOTAL")
                        _ok "{\"sid\":\"$LOCK_SID\",\"timeout\":$COIN_TIMEOUT,\"remaining\":$RESUME_REMAINING,\"amount\":$RESUME_TOTAL,\"minutes\":$RESUME_MINUTES,\"resumed\":true}"
                    fi

                    # Don't just drop this session's coins on the floor: the
                    # last poll that DID get a PSK-verified reply from
                    # NodeMCU (before it went quiet, or before it confirmed
                    # the session is over) already wrote its checked amount
                    # to .amt, so we know FOR A FACT — it's signed, not
                    # guessed — that this many pesos were really inserted
                    # for this SID. Fold that known-good amount into the
                    # customer's coin bank so it survives as spendable
                    # balance instead of vanishing, whichever of the three
                    # ways below we ended up here.
                    #
                    # Also stamp a .result marker for this SID so that IF
                    # NodeMCU turns out not to be truly dead and later
                    # replays this exact session — either a normal
                    # end-of-session POST or a flash-crash recovery replay
                    # — coin_result.sh's existing duplicate-SID guard
                    # (RESULT_PATH, checked before either grant path runs)
                    # recognizes it as already handled and reports
                    # "duplicate" instead of granting the same coins again
                    # on top of the bank credit we just gave. Skipped
                    # entirely when there's nothing banked (R_STALE_AMT=0)
                    # — a zero-amount replay is already a no-op downstream.
                    R_STALE_AMT=$(cat "/tmp/coin_sessions/${LOCK_SID}.amt" 2>/dev/null)
                    case "$R_STALE_AMT" in ''|*[!0-9]*) R_STALE_AMT=0 ;; esac
                    if [ "$R_STALE_AMT" -gt 0 ]; then
                        _lock
                        # This exact SID can also be rescued from the poll
                        # action's own LIVE_ACTIVE:false branch (NodeMCU
                        # coming back online after its reboot and reporting
                        # it doesn't know this sid), or genuinely finalized
                        # by NodeMCU's own delayed-but-real end-of-session
                        # POST landing right now. Both paths — and this one
                        # — write the SAME .result marker, but only AFTER
                        # doing their own _bank_add, so without this check
                        # two of them racing each other bank the same coins
                        # twice: whichever gets here first correctly banks
                        # R_STALE_AMT, and without re-checking, whichever
                        # gets here second would bank the identical amount
                        # again on top. Checking-and-claiming it here, inside
                        # the same _lock every one of those paths shares,
                        # makes this a single atomic "is it still mine to
                        # bank" test instead of a check then an act two
                        # requests can both pass through.
                        if [ -f "/tmp/coin_sessions/${LOCK_SID}.result" ]; then
                            _unlock
                        else
                            _bank_add "$CLIENT_MAC" "$R_STALE_AMT"
                            printf '%s 0\n' "$R_STALE_AMT" > "/tmp/coin_sessions/${LOCK_SID}.result"
                            _unlock
                            # This rescue bypasses coin_result.sh entirely, which is
                            # normally the only place a physically-inserted coin gets
                            # counted as income (at time of insertion, regardless of
                            # whether it crosses a rate tier) and reported to
                            # Telegram/Discord. Without this, a coin rescued here
                            # would still convert to time correctly once later spent
                            # from the bank, but would never show up in income.sh's
                            # daily/monthly/yearly totals or send a notification.
                            # Record and report it now, same event key coin_result.sh
                            # uses for an ordinary below-tier top-up, so it isn't lost
                            # and existing per-event mute settings still apply.
                            /lmepisowifi/hotspot/income.sh add "$R_STALE_AMT" >/dev/null 2>&1
                            _R_MSG=$(tpl_render "$TPL_COINS_INSERTED" insertcoinamt "$R_STALE_AMT" mac "$CLIENT_MAC" nodemcu "$(_node_label "$NODE_ID")")
                            ( /lmepisowifi/hotspot/notify.sh "$_R_MSG" "" coins_inserted >/dev/null 2>&1 </dev/null & )
                        fi
                    fi

                    if [ "$R_VERIFIED" -eq 1 ] && [ "$R_ACTIVE" -eq 0 ]; then
                        # NodeMCU AUTHORITATIVELY confirmed the session is
                        # over — not an error, just a page reload racing a
                        # session that finished normally. No alert.
                        :
                    elif [ -n "$R_LIVE" ]; then
                        _coin_alert "RESUME_SIG_MISMATCH" "SID=${LOCK_SID} response received but HMAC invalid — PSK mismatch or tampered reply"
                    else
                        _coin_alert "RESUME_NODEMCU_OFFLINE" "SID=${LOCK_SID} no response from NodeMCU (node ${NODE_ID}) at ${_N_IP}:${_N_PORT} during resume check — stale lock dropped, ₱${R_STALE_AMT} banked to ${CLIENT_MAC}"
                    fi
                    # This SID's coins are now either banked just above
                    # (_bank_add) or were zero to begin with — either way the
                    # non-volatile crash mirror for this SID is no longer
                    # needed. Without this, startup.sh's boot replay keeps
                    # rediscovering the same mirror on every future reboot and
                    # re-credits R_STALE_AMT into the bank again, even long
                    # after it's been spent.
                    _clear_pending "$LOCK_SID"
                    rm -f "$LOCK_FILE" "/tmp/coin_sessions/${LOCK_SID}" \
                        "/tmp/coin_sessions/${LOCK_SID}.miss" "/tmp/coin_sessions/${LOCK_SID}.amt" \
                        "/tmp/coin_sessions/${LOCK_SID}.rem"
                fi
            else
                LOCKED=1
            fi
        else
            # Lock aged out with no liveness check performed at all — by now
            # this SID's own poll-driven expiry has normally already run (and
            # already cleared its mirror), but drop it here too in case it's
            # somehow still sitting on flash, for the same reason as above.
            _clear_pending "$LOCK_SID"
            rm -f "$LOCK_FILE" "/tmp/coin_sessions/${LOCK_SID}" \
                "/tmp/coin_sessions/${LOCK_SID}.miss" "/tmp/coin_sessions/${LOCK_SID}.amt" \
                "/tmp/coin_sessions/${LOCK_SID}.rem"
        fi
    fi

    # If we get here, this request isn't resuming/pending/cancelling an
    # existing lock of ours (those branches above all _ok/_err and exit
    # before reaching this point) — it's about to open a brand new session
    # or queue for one. Gate that specifically on internet connectivity so
    # an outage never interrupts coins someone already has in flight, only
    # blocks new ones from starting.
    if [ "${COIN_REQUIRE_INTERNET:-0}" = "1" ] && [ ! -f "${INTERNET_UP_FILE:-/tmp/internet_up}" ]; then
        _err "No internet connection. Coin insertion is temporarily unavailable."
    fi

    # 3. Check Queue & Determine Flow
    if [ "$LOCKED" -eq 0 ]; then
        # Check if anyone is waiting in line ahead of us
        FIRST_MAC=$($BB head -n 1 "$QFILE" 2>/dev/null | $BB awk '{print $1}')
        if [ -n "$FIRST_MAC" ] && [ "$FIRST_MAC" != "$CLIENT_MAC" ]; then
            LOCKED=1 # Someone else is first in line
        fi
    fi

    if [ "$LOCKED" -eq 1 ]; then
        # Waiting-line feature master switch. When off, don't put this
        # client on hold at all — just turn them away so they can try the
        # slot again later themselves instead of sitting in an unattended
        # queue. Nothing is written to QFILE in this branch, so it simply
        # never accumulates entries while the switch is off.
        if [ "${COIN_QUEUE_ENABLED:-1}" = "0" ]; then
            _err "Coin slot is in use, try again later."
        fi

        # Enqueue user / Refresh their spot in line
        $BB grep -v "^$CLIENT_MAC " "$QFILE" > "${QFILE}.tmp" 2>/dev/null
        echo "$CLIENT_MAC $NOW" >> "${QFILE}.tmp"
        $BB mv "${QFILE}.tmp" "$QFILE"
        
        POS=$($BB awk -v mac="$CLIENT_MAC" '$1==mac {print NR}' "$QFILE")
        _ok "{\"queued\":true,\"position\":$POS}"
    fi

    # If I am here, it's my turn. Remove me from queue if I was in it.
    if [ -f "$QFILE" ]; then
        $BB grep -v "^$CLIENT_MAC " "$QFILE" > "${QFILE}.tmp" 2>/dev/null
        $BB mv "${QFILE}.tmp" "$QFILE"
    fi

    # Generate SID: uptime + MAC + PID + random → md5 → first 16 hex chars
    SID=$(printf '%s%s%d%d' \
        "$(awk '{print $1$2}' /proc/uptime)" \
        "$CLIENT_MAC" "$$" "$RANDOM" \
        | md5sum | awk '{print substr($1,1,16)}')

    START_SIG=$(_md5 "${_N_PSK}:${SID}:start")

    # Bind this SID to the client's MAC + creation time + last-seen heartbeat
    # + which node it belongs to. last_seen starts equal to creation time and
    # gets refreshed on every poll that gets a verified live response from
    # NodeMCU — this is what lets a rolling (per-coin-reset) session run past
    # the original window without being treated as abandoned. The node id is
    # what lets poll/cancel (which only ever see the sid) find their way back
    # to the right unit's IP/PORT/PSK.
    printf '%s %s %s %s\n' "$CLIENT_MAC" "$NOW" "$NOW" "$NODE_ID" > "/tmp/coin_sessions/${SID}"

    # Write a PENDING lock. Prevents parallel requests, but ignores automatic UI page reloads.
    printf '%s %s %s %s\n' "$SID" "$NOW" "$CLIENT_MAC" "PENDING" > "$LOCK_FILE"

    # Contact NodeMCU — it verifies START_SIG before accepting coins. We also
    # hand it the client MAC so that, if power is cut mid-session, NodeMCU can
    # POST a signed recovery grant for this exact device on its next boot (see
    # recoverSessionFromFlash in the firmware + the recover branch in
    # coin_result.sh). The MAC is not part of START_SIG, but that's fine: a
    # forged MAC only ever credits time to some *other* real device's account
    # and can't manufacture coins, while coin_result.sh still verifies the PSK
    # signature before granting anything.
RESP=$(wget -q -T 5 -O - \
    "http://${_N_IP}:${_N_PORT}/start?sid=${SID}&sig=${START_SIG}&timeout=${COIN_TIMEOUT}&mac=${CLIENT_MAC}" \
    2>/dev/null)
_log "[start] NodeMCU raw reply: '$RESP'"

    if printf '%s' "$RESP" | grep -q '"ok"'; then
        OK_VAL=$(printf '%s' "$RESP" | grep -o '"ok":[a-z]*' | grep -o '[a-z]*$')

        [ "$OK_VAL" = "true" ] || {
            _coin_alert "NODEMCU_REJECTED_START" "SID=${SID} NodeMCU returned ok:${OK_VAL:-missing} — firmware rejected the session start"
            rm -f "/tmp/coin_sessions/${SID}" "$LOCK_FILE"
            _err "System rejected Insert Coin attempt."
        }        
        # Success! Upgrade lock to ACTIVE
        printf '%s %s %s %s\n' "$SID" "$NOW" "$CLIENT_MAC" "ACTIVE" > "$LOCK_FILE"
        
        # No coins have landed on this brand-new session yet, so the only
        # money in play right now is whatever's already banked (BANKED,
        # above) — report it so the modal opens showing the customer's real
        # available balance instead of resetting to ₱0.
        _ok "{\"sid\":\"$SID\",\"timeout\":$COIN_TIMEOUT,\"amount\":$BANKED,\"minutes\":$(_calc_time "$BANKED")}"
    else
        _coin_alert "NODEMCU_OFFLINE" "SID=${SID} no response from NodeMCU (node ${NODE_ID}) at ${_N_IP}:${_N_PORT}/start"
        rm -f "/tmp/coin_sessions/${SID}" "$LOCK_FILE"
        _err "Coinslot Offline, notify the vendo owner if this persists."
    fi
    ;;

# ----------------------------------------------------------------
# ----------------------------------------------------------------
poll)
    SID=$(get_qs "sid")
    [ -n "$SID" ] || _err "Missing sid"
    printf '%s' "$SID" | grep -qE '^[0-9a-f]{16}$' || _err "Invalid sid"

    SESSION_PATH="/tmp/coin_sessions/${SID}"
    RESULT_PATH="/tmp/coin_sessions/${SID}.result"
    NOW=$(awk '{print int($1)}' /proc/uptime)

    # NodeMCU already posted the result
    if [ -f "$RESULT_PATH" ]; then
        AMOUNT=$(awk '{print $1}' "$RESULT_PATH")
        MINUTES=$(awk '{print $2}' "$RESULT_PATH")
        _ok "{\"status\":\"complete\",\"amount\":${AMOUNT},\"minutes\":${MINUTES}}"
    fi

    # Session file must exist and belong to this client
    [ -f "$SESSION_PATH" ] || _ok '{"status":"expired","amount":0,"minutes":0}'
    SESSION_MAC=$(awk '{print $1}' "$SESSION_PATH")
    [ "$SESSION_MAC" = "$CLIENT_MAC" ] || _err "Session mismatch"

    CREATED_AT=$(awk '{print $2}' "$SESSION_PATH")
    LAST_SEEN=$(awk '{print ($3==""?$2:$3)}' "$SESSION_PATH")
    SINCE_SEEN=$(( NOW - LAST_SEEN ))

    SESSION_NODE=$(awk '{print ($4==""?1:$4)}' "$SESSION_PATH")
    _N_IP=$(_node_field "$SESSION_NODE" 3)
    _N_PORT=$(_node_field "$SESSION_NODE" 5)
    _N_PSK=$(_node_field "$SESSION_NODE" 6)

    RECONNECT_GRACE=${COIN_RECONNECT_GRACE:-300}

    MISS_PATH="${SESSION_PATH}.miss"
    AMT_PATH="${SESSION_PATH}.amt"
    REM_PATH="${SESSION_PATH}.rem"
    GONE_PATH="${SESSION_PATH}.gone"

    LOCK_FILE_FOR_NODE="/tmp/coin_lock_${SESSION_NODE}"
    CANCEL_GIVEUP=0
    if [ -f "$LOCK_FILE_FOR_NODE" ]; then
        _LF_SID=$(awk '{print $1}' "$LOCK_FILE_FOR_NODE")
        _LF_TIME=$(awk '{print $2}' "$LOCK_FILE_FOR_NODE")
        _LF_STATE=$(awk '{print $4}' "$LOCK_FILE_FOR_NODE")
        if [ "$_LF_SID" = "$SID" ] && [ "$_LF_STATE" = "CANCELLING" ]; then
            case "$_LF_TIME" in ''|*[!0-9]*) _LF_TIME=$NOW ;; esac
            CANCEL_SINCE=$(( NOW - _LF_TIME ))
            [ "$CANCEL_SINCE" -gt "${COIN_CANCEL_GIVEUP:-15}" ] && CANCEL_GIVEUP=1
        fi
    fi

    REMAINING=$(( COIN_TIMEOUT - (NOW - CREATED_AT) ))
    [ "$REMAINING" -lt 0 ] && REMAINING=0

    # Hard expiry / cancel give-up
    if [ "$CANCEL_GIVEUP" -eq 1 ] || [ "$SINCE_SEEN" -gt $(( COIN_TIMEOUT + 25 + RECONNECT_GRACE )) ]; then
        _log "[poll] SID=$SID TIMEOUT/CANCEL triggered: CANCEL_GIVEUP=$CANCEL_GIVEUP SINCE_SEEN=$SINCE_SEEN"
        if [ -f "$RESULT_PATH" ]; then
            _R_AMOUNT=$(awk '{print $1}' "$RESULT_PATH")
            _R_MINUTES=$(awk '{print $2}' "$RESULT_PATH")
            rm -f "$SESSION_PATH" "$MISS_PATH" "$AMT_PATH" "$REM_PATH" "$GONE_PATH" "$LOCK_FILE_FOR_NODE"
            _clear_pending "$SID"
            _ok "{\"status\":\"complete\",\"amount\":${_R_AMOUNT:-0},\"minutes\":${_R_MINUTES:-0}}"
        fi
        GIVEUP_AMT=$(cat "$AMT_PATH" 2>/dev/null); GIVEUP_AMT=${GIVEUP_AMT:-0}
        if [ "$GIVEUP_AMT" -gt 0 ]; then
            _lock
            if [ -f "$RESULT_PATH" ]; then
                _unlock
                _R_AMOUNT=$(awk '{print $1}' "$RESULT_PATH")
                _R_MINUTES=$(awk '{print $2}' "$RESULT_PATH")
                rm -f "$SESSION_PATH" "$MISS_PATH" "$AMT_PATH" "$REM_PATH" "$GONE_PATH" "$LOCK_FILE_FOR_NODE"
                _clear_pending "$SID"
                _ok "{\"status\":\"complete\",\"amount\":${_R_AMOUNT:-0},\"minutes\":${_R_MINUTES:-0}}"
            else
                _bank_add "$SESSION_MAC" "$GIVEUP_AMT"
                printf '%s 0\n' "$GIVEUP_AMT" > "$RESULT_PATH"
                _unlock
                /lmepisowifi/hotspot/income.sh add "$GIVEUP_AMT" >/dev/null 2>&1
                _G_MSG=$(tpl_render "$TPL_COINS_INSERTED" insertcoinamt "$GIVEUP_AMT" mac "$SESSION_MAC" nodemcu "$(_node_label "$SESSION_NODE")")
                ( /lmepisowifi/hotspot/notify.sh "$_G_MSG" "" coins_inserted >/dev/null 2>&1 </dev/null & )
            fi
        fi
        rm -f "$SESSION_PATH" "$MISS_PATH" "$AMT_PATH" "$REM_PATH" "$GONE_PATH" "$LOCK_FILE_FOR_NODE"
        _clear_pending "$SID"
        # NOT "complete": this coin.sh instance never ran the real tier-purchase
        # grant (that's coin_result.sh's job, and RESULT_PATH's absence up top
        # is exactly what means it never got the chance to). GIVEUP_AMT above
        # only ever gets _bank_add'd — preserved for the NEXT top-up to combine
        # with, not turned into active session time right now. Sending
        # "complete" here with minutes:0 would be doubly wrong: it collapses
        # into the frontend's "not enough coins" message even when the amount
        # banked genuinely would clear a tier (misleading — it did, it's just
        # not granted yet), and skips exitCoinReconnecting()'s cleanup of the
        # reconnect banner/paused progress-bar if this session had been
        # flapping beforehand, leaving both stuck for the next customer.
        # "expired" is what the frontend's 'expired' branch (still present,
        # unchanged) is built for: an accurate "your money is safe" message
        # either way, and it correctly tears down that leftover UI state.
        _ok "{\"status\":\"expired\",\"amount\":${GIVEUP_AMT},\"minutes\":$(_calc_time "$GIVEUP_AMT")}"
    fi

    # Read cached amount BEFORE calling wget so a racing coin_result.sh
    # deleting AMT_PATH cannot wipe this to 0 mid-poll
    LIVE_AMOUNT=$(cat "$AMT_PATH" 2>/dev/null)
    LIVE_AMOUNT=${LIVE_AMOUNT:-0}

    # Query NodeMCU for live coin count — verify its response signature
    POLL_SIG=$(_md5 "${_N_PSK}:${SID}:poll")
    LIVE=$(wget -q -T 2 -O - \
        "http://${_N_IP}:${_N_PORT}/status?sid=${SID}&sig=${POLL_SIG}" \
        2>/dev/null)
    _log "[poll] SID=$SID node=$SESSION_NODE raw_reply='$LIVE'"

    LIVE_OK=0
    LIVE_ACTIVE=1
    if [ -n "$LIVE" ]; then
        case "$LIVE" in *'"active":false'*) LIVE_ACTIVE=0 ;; esac
        RAW_AMT=$(printf '%s' "$LIVE" | grep -o '"amount":[0-9]*' | grep -o '[0-9]*$')
        RAW_SIG=$(printf '%s' "$LIVE" | grep -o '"sig":"[^"]*"' | awk -F'"' '{print $4}')
        EXP_SIG=$(_md5 "${_N_PSK}:${SID}:${RAW_AMT}:status")

        # Only trust the amount if NodeMCU signed it with the PSK
        if [ -n "$RAW_SIG" ] && [ "$RAW_SIG" = "$EXP_SIG" ]; then
            LIVE_OK=1
            if [ "$LIVE_ACTIVE" -eq 0 ]; then
                # 1. Did coin_result.sh already finalize and write .result?
                # If so, return its authoritative tally immediately!
                if [ -f "$RESULT_PATH" ]; then
                    _R_AMOUNT=$(awk '{print $1}' "$RESULT_PATH")
                    _R_MINUTES=$(awk '{print $2}' "$RESULT_PATH")
                    rm -f "$SESSION_PATH" "$MISS_PATH" "$AMT_PATH" "$REM_PATH" "$GONE_PATH" "/tmp/coin_lock_${SESSION_NODE}"
                    _clear_pending "$SID"
                    _ok "{\"status\":\"complete\",\"amount\":${_R_AMOUNT:-0},\"minutes\":${_R_MINUTES:-0}}"
                fi

                # 2. NodeMCU is done, but its POST hasn't arrived yet.
                # Tolerate up to COIN_RESULT_GRACE_POLLS before falling back to rescue.
                GONE=$(cat "$GONE_PATH" 2>/dev/null); GONE=$(( ${GONE:-0} + 1 ))
                echo "$GONE" > "$GONE_PATH" 2>/dev/null
                _log "[poll] SID=$SID active=false grace_count=$GONE"
                if [ "$GONE" -le "${COIN_RESULT_GRACE_POLLS:-4}" ]; then
                    PREVIEW=$(_calc_time "$(( BANKED + LIVE_AMOUNT ))")
                    _ok "{\"status\":\"active\",\"amount\":$(( BANKED + LIVE_AMOUNT )),\"minutes\":${PREVIEW},\"remaining\":0}"
                fi
                rm -f "$GONE_PATH" 2>/dev/null

                # 3. Grace expired with no POST — rescue cached coins as fallback
                if [ "$LIVE_AMOUNT" -gt 0 ]; then
                    _lock
                    if [ -f "$RESULT_PATH" ]; then
                        _unlock
                        _R_AMOUNT=$(awk '{print $1}' "$RESULT_PATH")
                        _R_MINUTES=$(awk '{print $2}' "$RESULT_PATH")
                        rm -f "$SESSION_PATH" "$MISS_PATH" "$AMT_PATH" "$REM_PATH" "$GONE_PATH" "/tmp/coin_lock_${SESSION_NODE}"
                        _clear_pending "$SID"
                        _ok "{\"status\":\"complete\",\"amount\":${_R_AMOUNT:-0},\"minutes\":${_R_MINUTES:-0}}"
                    fi
                    _bank_add "$SESSION_MAC" "$LIVE_AMOUNT"
                    printf '%s 0\n' "$LIVE_AMOUNT" > "$RESULT_PATH"
                    _unlock
                    /lmepisowifi/hotspot/income.sh add "$LIVE_AMOUNT" >/dev/null 2>&1
                    _L_MSG=$(tpl_render "$TPL_COINS_INSERTED" insertcoinamt "$LIVE_AMOUNT" mac "$SESSION_MAC" nodemcu "$(_node_label "$SESSION_NODE")")
                    ( /lmepisowifi/hotspot/notify.sh "$_L_MSG" "" coins_inserted >/dev/null 2>&1 </dev/null & )
                fi
                rm -f "$SESSION_PATH" "$MISS_PATH" "$AMT_PATH" "$REM_PATH" "$GONE_PATH" "/tmp/coin_lock_${SESSION_NODE}"
                _clear_pending "$SID"
                # See the matching comment on the hard-timeout rescue path
                # above - same reasoning applies here: LIVE_AMOUNT only ever
                # gets _bank_add'd in this branch, never actually granted as
                # session time, so this must stay "expired" (not "complete")
                # with a real _calc_time() minutes value.
                _ok "{\"status\":\"expired\",\"amount\":${LIVE_AMOUNT},\"minutes\":$(_calc_time "$LIVE_AMOUNT")}"
            fi

            PREV_AMOUNT=$LIVE_AMOUNT          # what we had before this poll
            LIVE_AMOUNT=${RAW_AMT:-0}
            echo "$LIVE_AMOUNT" > "$AMT_PATH" 2>/dev/null

            if [ "${LIVE_AMOUNT:-0}" -gt 0 ] && [ "${LIVE_AMOUNT:-0}" != "${PREV_AMOUNT:-0}" ]; then
                _persist_pending "$SID" "$SESSION_MAC" "$LIVE_AMOUNT" "$CREATED_AT" "$SESSION_NODE"
            fi

            printf '%s %s %s %s\n' "$SESSION_MAC" "$CREATED_AT" "$NOW" "$SESSION_NODE" \
                > "/tmp/coin_sessions/${SID}.tmp" 2>/dev/null \
                && mv "/tmp/coin_sessions/${SID}.tmp" "$SESSION_PATH"

            RAW_REM=$(printf '%s' "$LIVE" | grep -o '"remaining":[0-9]*' | grep -o '[0-9]*$')
            if [ -n "$RAW_REM" ]; then
                REMAINING=$RAW_REM
                echo "$REMAINING" > "$REM_PATH" 2>/dev/null
            fi
        else
            _coin_alert "POLL_SIG_MISMATCH" "SID=${SID} poll response received but HMAC invalid (got=${RAW_SIG} want=${EXP_SIG}) — PSK mismatch or tampered reply"
        fi
    fi

    TOTAL_AMOUNT=$(( BANKED + LIVE_AMOUNT ))

    if [ "$LIVE_OK" -eq 1 ]; then
        rm -f "$MISS_PATH"
    else
        MISSES=$(cat "$MISS_PATH" 2>/dev/null)
        MISSES=$(( ${MISSES:-0} + 1 ))
        echo "$MISSES" > "$MISS_PATH" 2>/dev/null
        if [ "$MISSES" -ge 4 ]; then
            FROZEN_REM=$(cat "$REM_PATH" 2>/dev/null); FROZEN_REM=${FROZEN_REM:-$REMAINING}
            PREVIEW=$(_calc_time "$TOTAL_AMOUNT")
            _ok "{\"status\":\"reconnecting\",\"amount\":${TOTAL_AMOUNT},\"minutes\":${PREVIEW},\"remaining\":${FROZEN_REM}}"
        fi
    fi

    PREVIEW=$(_calc_time "$TOTAL_AMOUNT")
    _ok "{\"status\":\"active\",\"amount\":${TOTAL_AMOUNT},\"minutes\":${PREVIEW},\"remaining\":${REMAINING}}"
    ;;

# ----------------------------------------------------------------
cancel)
    NOW=$(awk '{print int($1)}' /proc/uptime)

    # Always remove the user from every node's waiting queue first — at this
    # point (no sid parsed yet) we don't know, and don't need to know, which
    # one they might have been queued for.
    for _nid in $(_node_ids); do
        _qf="/tmp/coin_queue_${_nid}.txt"
        [ -f "$_qf" ] || continue
        $BB grep -v "^$CLIENT_MAC " "$_qf" > /tmp/cq.tmp 2>/dev/null
        $BB mv /tmp/cq.tmp "$_qf"
    done

    SID=$(get_qs "sid")
    if [ -z "$SID" ]; then
        # Request just wanted to leave the queue. Nothing more to cancel.
        _ok '{"ok":true,"msg":"left_queue"}'
    fi

    printf '%s' "$SID" | grep -qE '^[0-9a-f]{16}$' || _err "Invalid sid"
    SESSION_PATH="/tmp/coin_sessions/${SID}"

    # If session already ended (result posted or file gone), that's fine
    [ -f "$SESSION_PATH" ] || _ok '{"ok":true,"msg":"already_ended"}'

    # Only the client who started the session can cancel it
    SESSION_MAC=$(awk '{print $1}' "$SESSION_PATH")
    [ "$SESSION_MAC" = "$CLIENT_MAC" ] || _err "Session mismatch"

    # Which unit this session belongs to (see poll's SESSION_NODE comment).
    SESSION_NODE=$(awk '{print ($4==""?1:$4)}' "$SESSION_PATH")
    _N_IP=$(_node_field "$SESSION_NODE" 3)
    _N_PORT=$(_node_field "$SESSION_NODE" 5)
    _N_PSK=$(_node_field "$SESSION_NODE" 6)

    # Signed cancel request — NodeMCU verifies md5(PSK:SID:cancel) before
    # ending the session. The NodeMCU finalizes asynchronously (its own
    # loop() picks this up, not this handler) and POSTs the result to
    # coin_result.sh a moment later — so we deliberately do NOT delete
    # SESSION_PATH/coin_lock here. coin_result.sh is the only place that
    # ever deletes them, on every path (zero-amount and success). Deleting
    # them here would race ahead of that POST and cause "Session not found".
    #
    # We DO flip the lock to CANCELLING right now, though — otherwise a
    # client that closes the modal and immediately hits "Insert Coin" again
    # lands back in the start-action's ACTIVE branch, and NodeMCU can still
    # answer /status validly for a session that's mid-teardown (it only
    # goes quiet once endSession() finishes settling trailing pulses),
    # producing a resumed session with a countdown for something that's
    # actually being cancelled. CANCELLING makes start-action tell the
    # client to wait a beat instead of resuming.
    LOCK_FILE="/tmp/coin_lock_${SESSION_NODE}"
    if [ -f "$LOCK_FILE" ]; then
        L_SID=$(awk '{print $1}' "$LOCK_FILE")
        [ "$L_SID" = "$SID" ] && \
            printf '%s %s %s %s\n' "$SID" "$NOW" "$CLIENT_MAC" "CANCELLING" > "$LOCK_FILE"
    fi

    CANCEL_SIG=$(_md5 "${_N_PSK}:${SID}:cancel")
    CANCEL_RESP=$(wget -q -T 5 -O - \
        "http://${_N_IP}:${_N_PORT}/cancel?sid=${SID}&sig=${CANCEL_SIG}" \
        2>/dev/null)
    [ -z "$CANCEL_RESP" ] && \
        _coin_alert "CANCEL_NO_RESPONSE" "SID=${SID} NodeMCU (node ${SESSION_NODE}) did not respond to /cancel — may be offline or mid-reboot"

    _ok '{"ok":true}'    ;;

# ----------------------------------------------------------------
# NOTE: A "reset" action used to live here (fetch nonce, sign with
# COIN_PSK, tell NodeMCU to wipe its WiFi config and drop back into
# the open PisoWifi-Setup AP). It was removed: this CGI is reachable
# by every connected hotspot client with no session/ownership check
# of any kind, and nothing in the frontend ever called it — so it
# was a zero-benefit, unauthenticated "brick the coin acceptor"
# button sitting on the public captive portal. coin.sh knowing
# COIN_PSK makes it the trusted side of that relationship, not a
# gate — the PSK signs requests *to* NodeMCU, it doesn't verify
# *who's* asking coin.sh to send them. If a reset feature is needed,
# it belongs in the authenticated www2 admin panel (session-checked),
# not here.

*)
    _err "Unknown action"
    ;;
esac
