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

# Called by NodeMCU via HTTP POST when a coin session ends (normal timeout or cancel).
# Verifies PSK signature + MAC, calculates time, grants or extends session.

# --- 1. Load configuration so environment variables are populated ---
[ -f /tmp/coin_config.env ] && . /tmp/coin_config.env

# --- 2. Fallback definitions in case they are missing from env ---
SESSION_FILE="${SESSION_FILE:-/tmp/active_sessions.txt}"
USERS_FILE="${USERS_FILE:-/lmepisowifi/hotspot_data/users.txt}"

# --- 2b. Customizable Telegram/Discord message templates ---
[ -f /lmepisowifi/hotspot/notify_templates.sh ] && . /lmepisowifi/hotspot/notify_templates.sh

# --- 2c. WiFi Rates expiry/validity bucket tracking (see ratevalidity.sh) ---
[ -f /lmepisowifi/hotspot/ratevalidity.sh ] && . /lmepisowifi/hotspot/ratevalidity.sh

# --- 3. Define response and processing helpers ---
_err() { printf '{"error":"%s"}\n' "$1"; exit 0; }
_ok()  { printf '%s\n' "$1";           exit 0; }
_md5() { printf '%s' "$1" | md5sum | awk '{print $1}'; }

# ── Multi-NodeMCU node registry (see coin.sh for the full explanation) ──────
NODEMCU_EXTRA_FILE="${NODEMCU_EXTRA_FILE:-/lmepisowifi/hotspot_data/nodemcus_extra.txt}"
_node_ids() {
    printf '1'
    [ -f "$NODEMCU_EXTRA_FILE" ] && $BB awk -F'|' '$1 ~ /^[0-9]+$/ {printf " %s", $1}' "$NODEMCU_EXTRA_FILE"
    printf '\n'
}
# $1=node id, $2=column (2=title 3=ip 4=mac 5=port 6=psk 7=enabled)
_node_field() {
    if [ "$1" = "1" ]; then
        case "$2" in
            2) printf '%s' "${NODEMCU_1_TITLE:-Coin Slot}" ;;
            3) printf '%s' "$NODEMCU_IP" ;;
            4) printf '%s' "$NODEMCU_MAC" ;;
            6) printf '%s' "$COIN_PSK" ;;
        esac
        return
    fi
    [ -f "$NODEMCU_EXTRA_FILE" ] || return 0
    $BB awk -F'|' -v id="$1" -v col="$2" '$1==id {print $col; exit}' "$NODEMCU_EXTRA_FILE"
}

# "<title> (<ip>)" for a node id — same convention as coin.sh's _node_label(),
# duplicated here since this CGI keeps its own copy of the node-registry
# helpers rather than sourcing coin.sh.
_node_label() {
    local _t _i
    _t=$(_node_field "$1" 2)
    _i=$(_node_field "$1" 3)
    printf '%s (%s)' "${_t:-Coin Slot}" "${_i:-unknown}"
}

# Non-volatile pending-session mirror written by coin.sh's poll handler. Once a
# session is granted/finalized here, drop its mirror so startup.sh won't replay
# (and double-grant) it on the next boot.
COIN_PENDING_DIR="/lmepisowifi/hotspot_data/coin_pending"
_clear_pending() { rm -f "${COIN_PENDING_DIR}/${1}" "${COIN_PENDING_DIR}/${1}.tmp" 2>/dev/null; sync; }

# ── Below-minimum-tier coin banking ──────────────────────────────────────────
# When a coin session's total (see the greedy calculator below) doesn't reach
# even the cheapest configured rate tier, none of it converts to time — that
# money used to just be gone from the customer's perspective (still recorded
# as income, just with nothing to show for it). This file carries that
# leftover forward per-MAC so the next coin top-up picks up where the last
# one left off instead of losing it. Reconciled across MAC-randomization
# reconnects by macfix.sh's mf_reconcile() (MACFIX_BANK_FILE — same physical
# file, path duplicated there the same way USERS_FILE's path already is).
COIN_BANK_FILE="/lmepisowifi/hotspot_data/coin_bank.txt"
# See lmehspt.sh's AUTO_PAUSED_FILE comment — cleared below whenever a
# top-up stacks coin time onto a paused session, since that session is no
# longer paused (whatever originally paused it no longer applies).
AUTO_PAUSED_FILE="/lmepisowifi/hotspot_data/auto_paused.txt"

# Currently banked pesos for $1 (a MAC) — empty if none. Call inside _lock.
_bank_get() {
    [ -f "$COIN_BANK_FILE" ] || return 0
    $BB awk -v m="$1" '$1==m{print $2; exit}' "$COIN_BANK_FILE"
}

# Replaces $1 (MAC)'s banked amount with $2 pesos, dropping the row
# entirely once it reaches 0 rather than leaving a stale "MAC 0" line
# around forever. Same exclude-then-recommit idiom as
# _users_file_stage_excl elsewhere in this file. Call inside _lock.
_bank_set() {
    local mac="$1" amt="${2:-0}"
    case "$amt" in ''|*[!0-9]*) amt=0 ;; esac
    mkdir -p /lmepisowifi/hotspot_data 2>/dev/null
    $BB grep -v "^${mac} " "$COIN_BANK_FILE" > "${COIN_BANK_FILE}.tmp" 2>/dev/null
    [ "$amt" -gt 0 ] && printf '%s %s\n' "$mac" "$amt" >> "${COIN_BANK_FILE}.tmp"
    mv "${COIN_BANK_FILE}.tmp" "$COIN_BANK_FILE"
    # Rename is atomic/crash-consistent on ubifs, but that says nothing about
    # whether this write has actually reached NAND yet vs. still sitting dirty
    # in the page cache. Force it out now so a power-cut/crash right after a
    # customer's banked balance is spent can't roll COIN_BANK_FILE back to the
    # pre-spend amount on the next boot (same reasoning as _users_file_commit).
    sync
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

# Stages "${USERS_FILE}.tmp" with every line except the one starting "$1 ",
# WITHOUT committing it - the caller appends its replacement line (grant/
# extend/pause) directly into that same tmp file, then calls
# _users_file_commit once, so the exclusion and the new line land in a
# single atomic mv instead of two separate writes to the live file. Refuses
# (returns 1, tmp file removed) if grep couldn't actually read USERS_FILE in
# the first place. `grep -v` exit status: 0 = some lines kept, 1 = every
# line was a genuine match (also what a truly-empty file returns - normal
# when the last user is being removed), 2+ = read/access error. Without this
# check, a single transient flash read glitch produces an empty tmp file
# that then gets committed over USERS_FILE unconditionally, wiping every
# user's balance in one request - no concurrency needed at all. Call this
# INSIDE _lock.
_users_file_stage_excl() {
    local mac="$1" existed=0 rc=0
    [ -e "$USERS_FILE" ] && existed=1
    grep -v "^${mac} " "$USERS_FILE" > "${USERS_FILE}.tmp" 2>/dev/null || rc=$?
    if [ "$existed" -eq 1 ] && [ "$rc" -gt 1 ]; then
        rm -f "${USERS_FILE}.tmp" 2>/dev/null
        logger -t lmehspt "users.txt: refused overwrite after read error (rc=$rc) - kept existing file" 2>/dev/null
        return 1
    fi
    return 0
}
# Commits a staged "${USERS_FILE}.tmp" via a single atomic mv, so the
# empty-expected marker is evaluated exactly once against the file's true
# final content for this operation (exclusion + replacement together) -
# never against a transient mid-operation state that a separate later
# append could still change out from under it.
_users_file_commit() {
    mv "${USERS_FILE}.tmp" "$USERS_FILE"
    # Rename is atomic/crash-consistent on ubifs, but that only guarantees
    # you never see a half-written file - it says nothing about whether
    # this specific write has actually reached the NAND yet vs. still
    # sitting dirty in the page cache. Force it out now so a power-cut
    # moments after a coin grant can't silently roll this request back.
    sync
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

# --- 4. Send Correct HTTP Headers ---
printf 'Content-Type: application/json\r\n'
printf 'Cache-Control: no-cache, no-store\r\n'
printf '\r\n'

# ── LOCAL BOOT-REPLAY MODE ───────────────────────────────────────────────────
# startup.sh replays power-outage sessions from non-volatile flash on boot by
# execing THIS script directly (not over HTTP) so it can reuse the exact same
# grant/extend logic below with zero duplication. A direct CLI/exec invocation
# has an EMPTY $REMOTE_ADDR (boa always sets it for a real network request), so
# LOCAL_REPLAY can only ever be true for something already running as root on
# the box — a network attacker can neither set COIN_BOOT_REPLAY nor blank out
# REMOTE_ADDR. In this mode the params come from the environment and the
# network guards below are skipped, but the PSK signature is STILL verified
# (defense in depth) exactly as in the normal recover path.
LOCAL_REPLAY=0
if [ "$COIN_BOOT_REPLAY" = "1" ] && [ -z "$REMOTE_ADDR" ]; then
    LOCAL_REPLAY=1
fi

if [ "$LOCAL_REPLAY" != "1" ]; then
    # --- Guard 1: Only requests from a configured NodeMCU's IP are processed ---
    # Identify WHICH unit is calling by matching its source IP against the
    # registry — the same "who is this" signal the single-node version used,
    # generalized from one hardcoded address to every configured node.
    CALL_NODE=""
    for _nid in $(_node_ids); do
        [ "$(_node_field "$_nid" 3)" = "$REMOTE_ADDR" ] && { CALL_NODE="$_nid"; break; }
    done
    [ -n "$CALL_NODE" ] || _err "Forbidden"
    N_MAC=$(_node_field "$CALL_NODE" 4)

    # --- Guard 2: Verify NodeMCU MAC via ARP (fail closed) ---
    EXPECTED_MAC=$(printf '%s' "$N_MAC" | tr -d ':' | tr 'A-F' 'a-f' | \
        sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/')
    CALLER_MAC=$(awk -v ip="$REMOTE_ADDR" '$1==ip {print tolower($4); exit}' /proc/net/arp 2>/dev/null)
    if [ -z "$CALLER_MAC" ]; then
        # Cache miss (e.g. stale/expired ARP entry) — force a resolution
        # attempt before deciding anything. Silently falling through to
        # Guard 1's source-IP-only check here would make this endpoint
        # spoofable by anyone on the shared LAN segment; a missing ARP
        # entry must be treated the same as a mismatched one, not skipped.
        ping -c 1 -W 1 "$REMOTE_ADDR" >/dev/null 2>&1
        CALLER_MAC=$(awk -v ip="$REMOTE_ADDR" '$1==ip {print tolower($4); exit}' /proc/net/arp 2>/dev/null)
    fi
    [ -n "$CALLER_MAC" ] && [ "$CALLER_MAC" = "$EXPECTED_MAC" ] || _err "MAC mismatch"

    [ "$REQUEST_METHOD" = "POST" ] || _err "POST required"

    BODY=""
    [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null && \
        BODY=$(head -c "$CONTENT_LENGTH")
    [ -n "$BODY" ] || _err "Empty body"
fi

_post() {
    printf '%s' "$BODY" | tr '&' '\n' | grep "^${1}=" | sed 's/^[^=]*=//' | head -1
}

if [ "$LOCAL_REPLAY" = "1" ]; then
    # Params supplied by startup.sh via the environment; always a recovery grant.
    SID="$SID"
    AMOUNT="$AMOUNT"
    SIG="$SIG"
    RECOVER=1
    RECOVER_MAC="$RECOVER_MAC"
    CALL_NODE="${NODE_ID:-1}"
else
    SID=$(_post "sid")
    AMOUNT=$(_post "amount")
    SIG=$(_post "sig")
    RECOVER=$(_post "recover")   # "1" when NodeMCU is replaying a power-outage session on boot
    RECOVER_MAC=$(_post "mac")   # paying client's MAC, only trusted in recovery mode
fi
N_PSK=$(_node_field "$CALL_NODE" 6)

[ -n "$SID" ] && [ -n "$AMOUNT" ] && [ -n "$SIG" ] || _err "Missing params"
printf '%s' "$SID"    | grep -qE '^[0-9a-f]{16}$' || _err "Invalid sid"
printf '%s' "$AMOUNT" | grep -qE '^[0-9]+$'        || _err "Invalid amount"

SESSION_PATH="/tmp/coin_sessions/${SID}"
RESULT_PATH="/tmp/coin_sessions/${SID}.result"
NOW=$(awk '{print int($1)}' /proc/uptime)

if [ "$RECOVER" = "1" ]; then
    # ── POWER-OUTAGE RECOVERY PATH ──────────────────────────────────────
    # A blackout wiped both the NodeMCU RAM total AND the portal's /tmp
    # bookkeeping, but the NodeMCU mirrored the session to its flash and is
    # now replaying it on boot. There is therefore NO session file to read
    # the MAC from, so the MAC is carried in the POST and folded into the
    # signature: sig = md5(PSK:SID:AMOUNT:MAC:recover). Because the PSK is
    # secret, only the real NodeMCU can produce this — a LAN attacker can't
    # forge a grant. We validate the MAC shape, then jump straight to the
    # grant/extend logic below.
    printf '%s' "$RECOVER_MAC" | grep -qE '^[0-9a-f:]{17}$' || _err "Invalid mac"
    R_EXP_SIG=$(_md5 "${N_PSK}:${SID}:${AMOUNT}:${RECOVER_MAC}:recover")
    [ "$SIG" = "$R_EXP_SIG" ] || _err "Bad sig"

    # Idempotency: if this exact recovery SID was already credited (NodeMCU
    # retried on a later boot before clearing its flash), don't double-grant.
    if [ -f "$RESULT_PATH" ]; then
        PREV_MIN=$(awk '{print $2}' "$RESULT_PATH")
        _clear_pending "$SID"   # already credited → mirror no longer needed
        _ok "{\"ok\":true,\"minutes\":${PREV_MIN},\"duplicate\":true,\"recovered\":true}"
    fi

    CLIENT_MAC="$RECOVER_MAC"
    # A recovery with no coins is meaningless — nothing to restore.
    [ "${AMOUNT:-0}" -gt 0 ] || { _clear_pending "$SID"; _ok '{"ok":true,"amount":0,"minutes":0,"recovered":true}'; }
else
    # ── NORMAL END-OF-SESSION PATH ──────────────────────────────────────
    # --- Guard 3: Verify PSK-based signature ---
    EXP_SIG=$(_md5 "${N_PSK}:${SID}:${AMOUNT}:end")
    [ "$SIG" = "$EXP_SIG" ] || _err "Bad sig"

    [ -f "$SESSION_PATH" ] || _err "Session not found"

    if [ -f "$RESULT_PATH" ]; then
        PREV_MIN=$(awk '{print $2}' "$RESULT_PATH")
        _clear_pending "$SID"
        _ok "{\"ok\":true,\"minutes\":${PREV_MIN},\"duplicate\":true}"
    fi

    # --- Guard 4: Reject stale replays ---
    LAST_SEEN=$(awk '{print ($3==""?$2:$3)}' "$SESSION_PATH")
    SESSION_AGE=$(( NOW - LAST_SEEN ))
    [ "$SESSION_AGE" -le $(( COIN_TIMEOUT + 30 )) ] || _err "Session expired"

    CLIENT_MAC=$(awk '{print $1}' "$SESSION_PATH")
fi

if [ "${AMOUNT:-0}" -eq 0 ]; then
    # A session ending with literally zero coins THIS time is only a true
    # no-op — and only counts as an anti-troll strike — when the customer
    # also has nothing sitting in the coin bank. Otherwise this is just a
    # customer cashing in a pre-existing banked balance (e.g. rescued by
    # coin.sh's RESUME_NODEMCU_OFFLINE/stale-lock paths, which bank coins
    # directly without ever routing through here) by pressing Done on a
    # fresh session they didn't feed any new coins into. Bouncing that with
    # "0 minutes" here both denies time they already paid for and unfairly
    # flags them as a troll. Peek at the bank now (outside _lock — this is
    # only a branch decision; the authoritative, lock-protected read still
    # happens below where it's actually spent) and fall through to the
    # normal fold/grant logic whenever it's nonzero.
    _PEEK_BANKED=$(_bank_get "$CLIENT_MAC")
    case "$_PEEK_BANKED" in ''|*[!0-9]*) _PEEK_BANKED=0 ;; esac

    if [ "$_PEEK_BANKED" -eq 0 ]; then
        if [ "${COIN_STRIKE_ENABLED:-1}" = "1" ]; then
            STRIKES=$($BB grep "^$CLIENT_MAC " /tmp/coin_strikes.txt 2>/dev/null | $BB awk '{print $2}')
            STRIKES=$(( ${STRIKES:-0} + 1 ))
            $BB grep -v "^$CLIENT_MAC " /tmp/coin_strikes.txt > /tmp/cs.tmp 2>/dev/null
            printf '%s %s %s\n' "$CLIENT_MAC" "$STRIKES" "$NOW" >> /tmp/cs.tmp
            $BB mv /tmp/cs.tmp /tmp/coin_strikes.txt

            # Notify once when suspension is first triggered (strikes exactly == threshold)
            _ST=${COIN_STRIKE_THRESHOLD:-3}
            _CD=${COIN_COOLDOWN:-300}
            if [ "$STRIKES" -eq "$_ST" ]; then
                _CD_MINS=$(( _CD / 60 ))
                _SUSP_MSG=$(tpl_render "$TPL_ANTI_TROLL" \
                    mac "$CLIENT_MAC" strikes "$STRIKES" strikemax "$_ST" cooldownmins "$_CD_MINS")
                ( /lmepisowifi/hotspot/notify.sh "$_SUSP_MSG" "" anti_troll >/dev/null 2>&1 </dev/null & )
            fi
        fi

        printf '0 0\n' > "$RESULT_PATH"
        rm -f "$SESSION_PATH" "${SESSION_PATH}.miss" "${SESSION_PATH}.amt" "${SESSION_PATH}.rem" "/tmp/coin_lock_${CALL_NODE}"
        _clear_pending "$SID"
        _ok '{"ok":true,"amount":0,"minutes":0}'
    fi
    # else: fall through — the banked balance gets folded and evaluated
    # against the rate tiers below, same as any other top-up.
fi

# Fold in whatever's already banked for this MAC (see COIN_BANK_FILE above)
# before converting to time, so a customer topping up in small increments
# gets credited once the RUNNING TOTAL crosses a tier — instead of every
# top-up being evaluated, and lost, in isolation. Wrapped in the same lock
# used below for the session/users grant so a below-tier top-up racing
# against another request for the same MAC can't read a stale balance.
_lock
BANKED=$(_bank_get "$CLIENT_MAC")
case "$BANKED" in ''|*[!0-9]*) BANKED=0 ;; esac
TOTAL_FOR_TIME=$(( BANKED + AMOUNT ))

_MB=$(printf '%s %s\n' "$COIN_RATES" "$TOTAL_FOR_TIME" | awk '
{
    amt=$NF; n=NF-1
    for(i=1;i<=n;i++){split($i,a,":");pesos[i]=a[1]+0;mins[i]=a[2]+0;vals[i]=a[3]+0}
    for(i=1;i<n;i++) for(j=i+1;j<=n;j++)
        if(pesos[j]>pesos[i]){
            tp=pesos[i];pesos[i]=pesos[j];pesos[j]=tp
            tm=mins[i]; mins[i]=mins[j]; mins[j]=tm
            tv=vals[i]; vals[i]=vals[j]; vals[j]=tv
        }
rem=amt+0; total=0; expmins=0; totval=0
    for(i=1;i<=n;i++) if(pesos[i]>0){
        c=int(rem/pesos[i])
        if(c>0){
            total+=c*mins[i]; rem-=c*pesos[i]
            if(vals[i]>0){
                expmins+=c*mins[i]
                totval+=c*vals[i]
            }
        }
    }
    print total, rem, expmins, totval
}')
MINUTES=$(printf '%s' "$_MB" | awk '{print $1}')
BANK_AFTER=$(printf '%s' "$_MB" | awk '{print $2}')
EXP_MINUTES=$(printf '%s' "$_MB" | awk '{print $3}')
VALID_MINUTES=$(printf '%s' "$_MB" | awk '{print $4}')

# Whatever's left over (0 once TOTAL_FOR_TIME exactly covers whole tiers)
# REPLACES the pre-top-up balance rather than adding to it — BANKED was
# already folded into TOTAL_FOR_TIME above, so re-adding it here would
# double-count it.
_bank_set "$CLIENT_MAC" "$BANK_AFTER"

# Total pesos that actually earned THIS grant — the pre-existing banked
# balance plus whatever landed this session, minus whatever still didn't
# reach a tier and rolled forward again (BANK_AFTER). Used for reporting
# (the Telegram new-sale message + the amount handed back through poll's
# "complete" status) instead of $AMOUNT alone, which is only the fraction
# that happened to be inserted in THIS particular session — a customer
# topping up an earlier below-minimum balance would otherwise see e.g.
# "₱1" reported for a sale that actually took ₱2 (₱1 banked + ₱1 just
# inserted) to reach the rate.
CONSUMED=$(( TOTAL_FOR_TIME - BANK_AFTER ))

# --- Grant or extend session (3-COLUMN AWARE) ---
if [ "${MINUTES:-0}" -gt 0 ]; then
    $BB grep -v "^$CLIENT_MAC " /tmp/coin_strikes.txt > /tmp/cs.tmp 2>/dev/null
    $BB mv /tmp/cs.tmp /tmp/coin_strikes.txt

    SECS=$(( MINUTES * 60 ))
    EXISTING=$(grep "^$CLIENT_MAC " "$SESSION_FILE" 2>/dev/null | head -1)
    PAUSED=$(grep "^$CLIENT_MAC paused " "$USERS_FILE" 2>/dev/null | head -1)

    if [ -n "$EXISTING" ]; then
        OLD_EXP=$(printf '%s' "$EXISTING" | awk '{print $2}')
        OLD_TOTAL=$(printf '%s' "$EXISTING" | awk '{print $3}')
        [ -z "$OLD_TOTAL" ] && OLD_TOTAL=$(( OLD_EXP - NOW ))

        if [ "$OLD_EXP" -gt "$NOW" ]; then
            NEW_EXP=$(( OLD_EXP + SECS ))
            NEW_TOTAL=$(( OLD_TOTAL + SECS ))
        else
            NEW_EXP=$(( NOW + SECS ))
            NEW_TOTAL=$SECS
        fi
        grep -v "^$CLIENT_MAC " "$SESSION_FILE" > "${SESSION_FILE}.tmp" 2>/dev/null
        printf '%s %s %s\n' "$CLIENT_MAC" "$NEW_EXP" "$NEW_TOTAL" >> "${SESSION_FILE}.tmp"
        mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
    else
        # Correctly stack coin time onto paused sessions
        if [ -n "$PAUSED" ]; then
            PAUSED_REM=$(printf '%s' "$PAUSED" | awk '{print $3}')
            PAUSED_TOT=$(printf '%s' "$PAUSED" | awk '{print $4}')
            [ -z "$PAUSED_TOT" ] && PAUSED_TOT=$PAUSED_REM

            SECS=$(( SECS + PAUSED_REM ))
            NEW_TOTAL=$(( PAUSED_TOT + (MINUTES * 60) ))
        else
            NEW_TOTAL=$SECS
        fi

        NEW_EXP=$(( NOW + SECS ))
        printf '%s %s %s\n' "$CLIENT_MAC" "$NEW_EXP" "$NEW_TOTAL" >> "$SESSION_FILE"
        iptables -t nat -I HOTSPOT 1 -m mac --mac-source "$CLIENT_MAC" -j RETURN 2>/dev/null
        iptables -t filter -I HOTSPOT_FWD 1 -m mac --mac-source "$CLIENT_MAC" -j ACCEPT 2>/dev/null
    fi

    # Immediately write state to persistent Flash database as 'active'
    N_REMAIN=$(( NEW_EXP - NOW ))
    if _users_file_stage_excl "$CLIENT_MAC"; then
        printf '%s active %s %s %s\n' "$CLIENT_MAC" "$N_REMAIN" "$NEW_TOTAL" "$(_fmt_secs "$N_REMAIN")" >> "${USERS_FILE}.tmp"
        _users_file_commit
    fi
    # No longer paused if it was — see AUTO_PAUSED_FILE's declaration above.
    [ -f "$AUTO_PAUSED_FILE" ] && { grep -vx "$CLIENT_MAC" "$AUTO_PAUSED_FILE" > /tmp/coin_ap.tmp 2>/dev/null; mv /tmp/coin_ap.tmp "$AUTO_PAUSED_FILE"; }

    # Merge this grant's expiring portion (if the rate tier(s) it came from
    # carry a validity window) into the customer's rate-validity bucket —
    # see ratevalidity.sh. A purchase with no validity at all (the common
    # case for existing/legacy rates) leaves the bucket untouched beyond
    # resolving whatever was already there.
    rv_grant "$CLIENT_MAC" "$(( ${EXP_MINUTES:-0} * 60 ))" "$(( ${VALID_MINUTES:-0} * 60 ))" "$NOW"
fi
_unlock

# --- Income tracking + coin-sale notification ----------------------------
if [ "${AMOUNT:-0}" -gt 0 ]; then
    # Record revenue first so income.sh get returns updated totals
    /lmepisowifi/hotspot/income.sh add "$AMOUNT" >/dev/null 2>&1

    # Format seconds as Xd Xh Xm (omit leading zero components)
    _fmt_dhm() {
        awk -v s="$1" 'BEGIN{
            s=int(s); if(s<0)s=0
            d=int(s/86400); s=s%86400
            h=int(s/3600);  s=s%3600
            m=int(s/60)
            out=""; sep=""
            if(d>0){out=out sep d"d"; sep=" "}
            if(h>0||d>0){out=out sep h"h"; sep=" "}
            out=out sep m"m"
            print out
        }'
    }

    if [ "${MINUTES:-0}" -gt 0 ]; then
        # Fetch updated income totals
        _INCOME=$(/lmepisowifi/hotspot/income.sh get 2>/dev/null)
        _I_D=$(printf '%s' "$_INCOME" | awk -F'"daily":'   '{split($2,a,"[,}]"); print a[1]+0}')
        _I_M=$(printf '%s' "$_INCOME" | awk -F'"monthly":' '{split($2,a,"[,}]"); print a[1]+0}')
        _I_Y=$(printf '%s' "$_INCOME" | awk -F'"yearly":'  '{split($2,a,"[,}]"); print a[1]+0}')

        # Active sessions count (includes this session, already written)
        _ACTIVE=$($BB grep -c '.' "$SESSION_FILE" 2>/dev/null)
        [ -n "$_ACTIVE" ] || _ACTIVE=0

        # NTP-synced system time
        _DT=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)

        N_REMAIN=$(( NEW_EXP - NOW ))
        N_MSG=$(tpl_render "$TPL_NEW_SALE" \
            totaltime "$(_fmt_dhm ${NEW_TOTAL:-0})" \
            addedtime "$(_fmt_dhm $(( MINUTES * 60 )))" \
            remainingtime "$(_fmt_dhm ${N_REMAIN:-0})" \
            insertcoinamt "$CONSUMED" \
            mac "$CLIENT_MAC" \
            nodemcu "$(_node_label "$CALL_NODE")" \
            activeusrcount "${_ACTIVE:-0}" \
            dailyamt "${_I_D:-0}" \
            monthlyamt "${_I_M:-0}" \
            yearlyamt "${_I_Y:-0}" \
            date "$_DT")
        N_EVT="new_sale"
    else
        N_MSG=$(tpl_render "$TPL_COINS_INSERTED" insertcoinamt "$AMOUNT" mac "$CLIENT_MAC" nodemcu "$(_node_label "$CALL_NODE")")
        N_EVT="coins_inserted"
    fi
    ( /lmepisowifi/hotspot/notify.sh "$N_MSG" "" "$N_EVT" >/dev/null 2>&1 </dev/null & )
fi
# -------------------------------------------------------------------------

printf '%s %s\n' "$CONSUMED" "$MINUTES" > "$RESULT_PATH"
rm -f "$SESSION_PATH" "${SESSION_PATH}.miss" "${SESSION_PATH}.amt" "${SESSION_PATH}.rem" "/tmp/coin_lock_${CALL_NODE}"
_clear_pending "$SID"   # coins credited → drop the non-volatile crash mirror

if [ "$RECOVER" = "1" ]; then
    _ok "{\"ok\":true,\"amount\":${AMOUNT},\"minutes\":${MINUTES},\"banked\":${BANK_AFTER:-0},\"recovered\":true}"
fi
_ok "{\"ok\":true,\"amount\":${AMOUNT},\"minutes\":${MINUTES},\"banked\":${BANK_AFTER:-0}}"
