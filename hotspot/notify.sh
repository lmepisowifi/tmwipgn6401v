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

# ============================================================
# notify.sh — send hotspot event messages to Telegram AND/OR Discord, AND
#             (in --bot mode) run the interactive Telegram command
#             router bot. Merged into one file so both share the same
#             config, wget transport, and Telegram JSON parsing.
#
#   Telegram and Discord are independent, not either/or: each fires
#   whenever it's configured (bot token + chat id, or a webhook) or
#   explicitly switched on in notify.env — see _tg_should_send /
#   _dc_should_send below. Configure both and every alert goes to both
#   at once.
#
#   notify.sh "message text"                 send if alerts are enabled
#   notify.sh "message text" force            send even if disabled (test)
#   notify.sh "message text" "" event_key     send only if that event is
#                                              not individually muted
#   notify.sh "msg" "" event_key dedup_key    as above, but also suppress
#                                              rapid repeats of the SAME
#                                              event+dedup_key (anti-spam)
#   notify.sh --drain                         flush queued messages
#   notify.sh --bot                           run the interactive
#                                              command-router bot
#                                              (foreground, long-running —
#                                              launch it backgrounded/
#                                              supervised, it never returns)
#   notify.sh --bot-autostart                 boot-time launcher: starts
#                                              --bot in the background (and
#                                              writes /tmp/telegram_bot.pid)
#                                              IFF BOT_AUTOSTART="1" in
#                                              telegram_bot.env, i.e. the
#                                              admin panel's bot switch was
#                                              left on. No-op otherwise, or
#                                              if already running. Called
#                                              from a boot marker in
#                                              www2/sh/startup.sh that
#                                              hotspot.cgi adds/removes
#                                              when the switch is toggled.
#
# event_key (optional 3rd arg) lets the admin silence one event type
# without disabling everything. Each event maps to a NOTIFY_EVT_<KEY>
# flag in notify.env; when that flag is explicitly "0" the message is
# dropped. Unset/empty flags default to enabled, so older configs keep
# every event firing. "force" (test button) bypasses this check.
#
# Config is read from /lmepisowifi/hotspot_data/notify.env
# Queue dir:  /lmepisowifi/hotspot_data/queued_messages/
# Bot config: /lmepisowifi/hotspot_data/telegram_bot.env (--bot /
#             --bot-autostart modes only)
#
# When internet is unreachable, messages are queued and retried
# automatically when the watchdog calls --drain (every 60s).
#
# No curl on this device — every Telegram/Discord call in this file goes
# through GNU wget with --no-check-certificate (see $WGET below).
# ============================================================

BB="busybox"
bb() { if [ -n "$BB" ]; then "$BB" "$@"; else "$@"; fi; }

# GNU wget (TLS-capable). Do NOT fall back to busybox wget.
WGET="/bin/wget"

NOTIFY_ENV="/lmepisowifi/hotspot_data/notify.env"
QUEUE_DIR="/lmepisowifi/hotspot_data/queued_messages"
TIMEOUT=8
MSG="$1"
FORCE="$2"
EVENT="$3"   # optional event key (e.g. session_paused) for per-event muting
DEDUP="$4"   # optional dedup key (e.g. the device MAC) for anti-spam cooldown

# ── URL-encode for Telegram ───────────────────────────────────────────────────
urlenc() {
    bb awk -v m="$1" 'BEGIN{
        for (i = 0; i <= 255; i++) ord[sprintf("%c", i)] = i
        out = ""; n = length(m)
        for (i = 1; i <= n; i++) {
            c = substr(m, i, 1)
            if (c ~ /[A-Za-z0-9._~-]/) out = out c
            else out = out sprintf("%%%02X", ord[c])
        }
        printf "%s", out
    }'
}

# ── JSON-escape for Discord ───────────────────────────────────────────────────
jsonenc() {
    bb awk -v m="$1" 'BEGIN{
        out = ""; n = length(m)
        for (i = 1; i <= n; i++) {
            c = substr(m, i, 1)
            if (c == "\\")      out = out "\\\\"
            else if (c == "\"") out = out "\\\""
            else if (c == "\n") out = out "\\n"
            else if (c == "\r") out = out "\\r"
            else if (c == "\t") out = out "\\t"
            else                out = out c
        }
        printf "%s", out
    }'
}

# ── Send functions ────────────────────────────────────────────────────────────
send_telegram() {
    [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] || return 1
    URL="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
    ENC=$(urlenc "$MSG")
    "$WGET" -q -T "$TIMEOUT" --no-check-certificate -O /dev/null \
        --post-data="chat_id=${TG_CHAT_ID}&text=${ENC}" \
        "$URL" 2>/dev/null
}

send_discord() {
    [ -n "$DISCORD_WEBHOOK" ] || return 1
    # Prepend a separator line — when the same bot sends back-to-back messages
    # Discord groups them visually into one block, making them look merged.
    # A top divider makes each message clearly distinct even when grouped.
    local DSCMSG
    DSCMSG=$(printf '%s' "$MSG")
    ESC=$(jsonenc "$DSCMSG")
    PAYLOAD="{\"content\":\"${ESC}\"}"
    "$WGET" -q -T "$TIMEOUT" --no-check-certificate -O /dev/null \
        --header="Content-Type: application/json" \
        --post-data="$PAYLOAD" \
        "$DISCORD_WEBHOOK" 2>/dev/null
}

# ── Which provider(s) fire for this send? ─────────────────────────────────
# Telegram and Discord are independent and BOTH send when both apply —
# this isn't an either/or provider pick. Each one fires when:
#   - its NOTIFY_*_ENABLED flag is explicitly "1" or "0" (admin's switch
#     in the Income & Notifications page wins outright), OR
#   - that flag was never set (older config, or never touched) AND the
#     fields it needs to actually send are filled in — so a config that
#     just has a bot token + chat id (or just a webhook) keeps working
#     without anyone having to flip a switch first.
_tg_should_send() {
    case "${NOTIFY_TG_ENABLED:-}" in
        0) return 1 ;;
        1) return 0 ;;
        *) [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] ;;
    esac
}
_dc_should_send() {
    case "${NOTIFY_DISCORD_ENABLED:-}" in
        0) return 1 ;;
        1) return 0 ;;
        *) [ -n "$DISCORD_WEBHOOK" ] ;;
    esac
}

# ── Connectivity check (fast ping — avoids full TLS handshake overhead) ───────
_internet_up() {
    bb ping -c 1 -W 4 8.8.8.8 >/dev/null 2>&1 || \
    bb ping -c 1 -W 4 1.1.1.1 >/dev/null 2>&1
}

# ── Queue a message for later delivery ───────────────────────────────────────
# $1 (optional): "tg" or "dc" — which provider still owes this message.
# Tagged in the filename so --drain retries only the provider(s) that
# actually failed, instead of re-sending to one that already succeeded.
# Omitted/unknown suffix = legacy behavior, retry against whatever is
# configured at drain time (see --drain below).
_enqueue() {
    local provider="$1"
    mkdir -p "$QUEUE_DIR" 2>/dev/null
    local ts suffix
    ts=$(bb awk '{print int($1)}' /proc/uptime 2>/dev/null || bb date +%s)
    suffix=""; [ -n "$provider" ] && suffix=".$provider"
    printf '%s' "$MSG" > "${QUEUE_DIR}/${ts}_$$${suffix}"
}

# ============================================================
# --- Interactive Telegram router bot (--bot mode) ------------------------
#
# Everything below this point is only used when notify.sh is launched as
# `notify.sh --bot`. It's a long-poll command router (status/reboot/
# hotspotstats/...), formerly a standalone telegram_bot.sh, merged in
# here so it shares this file's $WGET transport and config instead of
# duplicating a second curl-based HTTP layer.
# ============================================================

# ---------------------------------------------------------------
# Minimal generic JSON parser (bot mode only) — no jq required.
#
# Flattens any JSON into "path<TAB>value" lines via a grep -Eo tokenizer
# + recursive-descent walker, then looks values up by path, so it
# doesn't depend on field ordering the way naive anchor-based grep/sed
# would.
#
# Usage:  json_get "$JSON_TEXT" "path/to/value"   (array indices are numeric)
#         e.g. json_get "$UPDATE" "result/0/message/from/id"
# ---------------------------------------------------------------

JNL='
'

_json_tokenize() {
    printf '%s' "$1" | grep -Eo '"([^"\\]|\\.)*"|-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?|true|false|null|\{|\}|\[|\]|:|,'
}

_json_peek() { JTOKEN=${JTOKENS%%"$JNL"*}; }

_json_advance() {
    _json_peek
    case "$JTOKENS" in
        *"$JNL"*) JTOKENS=${JTOKENS#*"$JNL"} ;;
        *) JTOKENS="" ;;
    esac
}

# Strip quotes + unescape a JSON string token; numbers/bool/null pass through as-is.
_json_scalar() {
    case "$1" in
        \"*\")
            s=${1#\"}; s=${s%\"}
            printf '%s' "$s" | sed 's/\\"/"/g; s/\\\\/\\/g; s/\\\//\//g'
            ;;
        *) printf '%s' "$1" ;;
    esac
}

_json_value() {
    local p="$1"
    _json_peek
    case "$JTOKEN" in
        '{') _json_object "$p" ;;
        '[') _json_array "$p" ;;
        *)   _json_advance; printf '%s\t%s\n' "$p" "$(_json_scalar "$JTOKEN")" ;;
    esac
}

_json_object() {
    local p="$1" key
    _json_advance
    _json_peek
    [ "$JTOKEN" = '}' ] && { _json_advance; return; }
    while :; do
        _json_advance
        [ -z "$JTOKEN" ] && break        # truncated/malformed JSON guard
        key=$(_json_scalar "$JTOKEN")
        _json_advance                    # consume ':'
        [ -n "$p" ] && _json_value "$p/$key" || _json_value "$key"
        _json_peek
        case "$JTOKEN" in
            ',') _json_advance ;;
            '}') _json_advance; break ;;
            '')  break ;;
        esac
    done
}

_json_array() {
    local p="$1" idx=0
    _json_advance
    _json_peek
    [ "$JTOKEN" = ']' ] && { _json_advance; return; }
    while :; do
        [ -n "$p" ] && _json_value "$p/$idx" || _json_value "$idx"
        idx=$((idx + 1))
        _json_peek
        case "$JTOKEN" in
            ',') _json_advance ;;
            ']') _json_advance; break ;;
            '')  break ;;
        esac
    done
}

# Flatten JSON text ($1) to "path<TAB>value" lines.
json_flatten() {
    JTOKENS=$(_json_tokenize "$1")
    _json_value ""
}

# Get a single value by path, e.g. json_get "$JSON" "result/0/message/text"
json_get() {
    json_flatten "$1" | while IFS="$BOTTAB" read -r p v; do
        if [ "$p" = "$2" ]; then
            printf '%s' "$v"
            break
        fi
    done
}
# ---------------------------------------------------------------

# ---------------------------------------------------------------
# Hotspot session management (bot mode only) — backs the activeusers/
# kick/addtime/removetime commands below. Reads and writes the SAME
# session files the web admin UI and portal CGI scripts use
# ($SESSION_DATA / $USERS_FILE), participating in the identical
# /tmp/hotspot_session.lock mutex protocol as hotspot.cgi, login.sh,
# logout.sh, coin_result.sh, and lmehspt.sh (see hotspot.cgi's _lock for
# the full rationale on the steal-after-dead logic). Duplicated here
# rather than sourced from one of those files, matching this codebase's
# existing convention of every script carrying its own copy of this
# protocol and of _fmt_secs.
# ---------------------------------------------------------------
HDATA="/lmepisowifi/hotspot_data"
SESSION_DATA="/tmp/active_sessions.txt"
USERS_FILE="$HDATA/users.txt"

_hs_unlock() { rm -f /tmp/hotspot_session.lock/pid 2>/dev/null; rmdir /tmp/hotspot_session.lock 2>/dev/null; }
_hs_lock() {
    local i=0
    while ! mkdir /tmp/hotspot_session.lock 2>/dev/null; do
        if [ "$((i % 10))" -eq 0 ] && [ "$i" -gt 0 ]; then
            if [ "$i" -ge 300 ]; then
                bb rm -f /tmp/hotspot_session.lock/pid 2>/dev/null
                rmdir /tmp/hotspot_session.lock 2>/dev/null
            else
                _HPID=$(bb cat /tmp/hotspot_session.lock/pid 2>/dev/null)
                if [ -z "$_HPID" ] || ! kill -0 "$_HPID" 2>/dev/null; then
                    bb rm -f /tmp/hotspot_session.lock/pid 2>/dev/null
                    rmdir /tmp/hotspot_session.lock 2>/dev/null
                fi
            fi
        fi
        bb sleep 0.1 2>/dev/null || sleep 0.1
        i=$((i + 1))
    done
    bb echo $$ > /tmp/hotspot_session.lock/pid 2>/dev/null
    # Deliberately NO `trap _hs_unlock EXIT INT TERM` here, unlike the CGI
    # copies of this lock. Those are one-shot processes where the trap is
    # a harmless safety net; this lock is taken from inside the long-running
    # --bot loop, where installing an INT/TERM trap would change how the
    # whole bot process responds to those signals for the rest of its life
    # (the admin panel's bot stop switch kills it with -9, which no trap
    # can intercept anyway). Every caller below unlocks explicitly instead.
}

_hs_fmt_secs() {
    local s="${1:-0}"
    s="${s#-}"
    case "$s" in ''|*[!0-9]*) s=0 ;; esac
    local d=$(( s / 86400 )) h=$(( (s % 86400) / 3600 )) m=$(( (s % 3600) / 60 ))
    if [ "$d" -gt 0 ]; then printf '%dd %dh %dm' "$d" "$h" "$m"
    elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
    else printf '%dm' "$m"; fi
}

# Stage USERS_FILE.tmp with every line except MAC $1's, WITHOUT committing
# (caller appends a replacement line, then calls _hs_commit). Call inside
# _hs_lock. Refuses (returns 1, tmp file removed) if grep couldn't actually
# read USERS_FILE — see hotspot.cgi's _users_file_stage_excl for the full
# rationale on the existed/rc check.
_hs_stage_excl() {
    local mac="$1" existed=0 rc=0
    [ -e "$USERS_FILE" ] && existed=1
    bb grep -v "^${mac} " "$USERS_FILE" > "${USERS_FILE}.tmp" 2>/dev/null || rc=$?
    if [ "$existed" -eq 1 ] && [ "$rc" -gt 1 ]; then
        rm -f "${USERS_FILE}.tmp" 2>/dev/null
        return 1
    fi
    return 0
}
# Same idea, but drops only the "$mac paused ..." line via awk (keeps any
# active line for the same mac untouched — grep -v "^$mac " would wrongly
# drop both).
_hs_stage_excl_paused() {
    local mac="$1" existed=0 rc=0
    [ -e "$USERS_FILE" ] && existed=1
    bb awk -v m="$mac" '$1==m && $2=="paused"{next}{print}' "$USERS_FILE" > "${USERS_FILE}.tmp" 2>/dev/null || rc=$?
    if [ "$existed" -eq 1 ] && [ "$rc" -ne 0 ]; then
        rm -f "${USERS_FILE}.tmp" 2>/dev/null
        return 1
    fi
    return 0
}
_hs_commit() {
    bb mv "${USERS_FILE}.tmp" "$USERS_FILE"
    sync
}

# Normalize a user-typed MAC (any case, with or without colons) into
# canonical aa:bb:cc:dd:ee:ff form. Prints nothing and returns 1 if it
# isn't exactly 12 hex digits once separators are stripped — so admins can
# type a MAC into Telegram with or without colons and it still resolves.
_hs_norm_mac() {
    local hexonly
    hexonly=$(printf '%s' "$1" | bb tr 'A-Z' 'a-z' | bb tr -cd '0-9a-f')
    case "$hexonly" in
        ????????????) ;;
        *) return 1 ;;
    esac
    printf '%s:%s:%s:%s:%s:%s' \
        "$(printf '%s' "$hexonly" | bb cut -c1-2)"  "$(printf '%s' "$hexonly" | bb cut -c3-4)" \
        "$(printf '%s' "$hexonly" | bb cut -c5-6)"  "$(printf '%s' "$hexonly" | bb cut -c7-8)" \
        "$(printf '%s' "$hexonly" | bb cut -c9-10)" "$(printf '%s' "$hexonly" | bb cut -c11-12)"
}
# ---------------------------------------------------------------

# ---------------------------------------------------------------
# Command registry — "name|description|handler" one per line.
# To add a command: add a line here and a cmd_<name>() function below.
# To remove one: delete its line (or set CMD_ENABLED_<NAME>="0" in
# telegram_bot.env to disable it without touching code).
#
# NOTE: hotspot.cgi extracts this exact block out of THIS file (by
# sed'ing between the CMD_REGISTRY=" line and the closing ") to build
# the admin UI's command list, so keep this assignment's formatting
# (leading `CMD_REGISTRY="` at column 1, closing `"` alone at EOL) as-is.
# ---------------------------------------------------------------
CMD_REGISTRY="status|Check router uptime|cmd_status
reboot|Reboot the router|cmd_reboot
hotspotstats|View hotspot status, sessions, and income|cmd_hotspot_stats
activeusers|List active/paused users: MAC + time left|cmd_active_users
kick|Kick a user offline: /kick <mac>|cmd_kick
addtime|Add time: /addtime <mac> <minutes>|cmd_add_time
removetime|Remove time: /removetime <mac> <minutes>|cmd_remove_time"

esc_json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Is command $1 (bare name, no slash) enabled? Missing/unset flag = enabled,
# so a telegram_bot.env from before this command existed still runs it.
cmd_is_enabled() {
    local key flag
    key=$(printf '%s' "$1" | tr 'a-z' 'A-Z' | tr -cd 'A-Z0-9_')
    [ -n "$key" ] || return 1
    eval "flag=\"\${CMD_ENABLED_${key}:-1}\""
    [ "$flag" != "0" ]
}

# Build the setMyCommands JSON array, skipping disabled commands.
build_commands_json() {
    local first=1 out="" name desc handler
    while IFS='|' read -r name desc handler; do
        [ -z "$name" ] && continue
        cmd_is_enabled "$name" || continue
        if [ "$first" = "1" ]; then first=0; else out="${out},"; fi
        out="${out}{\"command\":\"$(esc_json "$name")\",\"description\":\"$(esc_json "$desc")\"}"
    done <<EOF
$CMD_REGISTRY
EOF
    printf '[%s]' "$out"
}

# Look up the handler function name for bare command $1, empty if none.
lookup_handler() {
    local target="$1" name desc handler
    while IFS='|' read -r name desc handler; do
        if [ "$name" = "$target" ]; then
            printf '%s' "$handler"
            return
        fi
    done <<EOF
$CMD_REGISTRY
EOF
}

# --- Command handlers -------------------------------------------------
# Each sets $RESPONSE (the reply text) and, optionally, $POST_ACTION
# (an action to run AFTER the reply is sent, e.g. "reboot").

cmd_status() {
    RESPONSE=$(tpl_render "$TPL_CMD_STATUS" uptime "$(uptime)")
}

cmd_reboot() {
    RESPONSE=$(tpl_render "$TPL_CMD_REBOOT")
    POST_ACTION="reboot"
}

cmd_hotspot_stats() {
    if [ ! -d /lmepisowifi/hotspot ]; then
        RESPONSE=$(tpl_render "$TPL_CMD_HOTSPOTSTATS_NOTINSTALLED")
        return
    fi

    local running="Stopped"
    if [ -f /tmp/hotspot_watchdog.pid ]; then
        local pid
        pid=$(cat /tmp/hotspot_watchdog.pid 2>/dev/null)
        kill -0 "$pid" 2>/dev/null && running="Running"
    fi

    local sessions=0
    if [ -f /tmp/active_sessions.txt ]; then
        sessions=$(grep -c '.' /tmp/active_sessions.txt 2>/dev/null)
        [ -n "$sessions" ] || sessions=0
    fi

    local income_json daily monthly yearly total
    income_json=$(/lmepisowifi/hotspot/income.sh get 2>/dev/null)
    [ -n "$income_json" ] || income_json='{"daily":0,"monthly":0,"yearly":0,"total":0,"synced":false}'
    daily=$(json_get "$income_json" "daily");     [ -n "$daily" ]   || daily=0
    monthly=$(json_get "$income_json" "monthly"); [ -n "$monthly" ] || monthly=0
    yearly=$(json_get "$income_json" "yearly");   [ -n "$yearly" ]  || yearly=0
    total=$(json_get "$income_json" "total");     [ -n "$total" ]   || total=0

    RESPONSE=$(tpl_render "$TPL_CMD_HOTSPOTSTATS" \
        running "$running" \
        sessions "$sessions" \
        daily "$daily" \
        monthly "$monthly" \
        yearly "$yearly" \
        total "$total")
}

# List every user with a live balance — active (in RAM) or paused (flash-
# persisted) — as a MAC/status/remaining table. Sent as a Markdown code
# block (see RESPONSE_MODE) so the columns actually line up in Telegram.
cmd_active_users() {
    local UPTIME out="" header count=0 mac expiry total rem status fmt

    UPTIME=$(bb awk '{print int($1)}' /proc/uptime 2>/dev/null); [ -n "$UPTIME" ] || UPTIME=0

    if [ -f "$SESSION_DATA" ]; then
        while read -r mac expiry total; do
            [ -n "$mac" ] || continue
            rem=$(( expiry - UPTIME ))
            [ "$rem" -le 0 ] && continue
            count=$(( count + 1 ))
            out="${out}$(printf '%-17s %-7s %s' "$mac" "active" "$(_hs_fmt_secs "$rem")")
"
        done < "$SESSION_DATA"
    fi
    if [ -f "$USERS_FILE" ]; then
        while read -r mac status rem total fmt; do
            [ -n "$mac" ] && [ "$status" = "paused" ] || continue
            count=$(( count + 1 ))
            out="${out}$(printf '%-17s %-7s %s' "$mac" "paused" "$(_hs_fmt_secs "$rem")")
"
        done < "$USERS_FILE"
    fi

    if [ "$count" -eq 0 ]; then
        RESPONSE=$(tpl_render "$TPL_CMD_ACTIVEUSERS_EMPTY")
        return
    fi

    local FENCE
    FENCE='```'
    header=$(printf '%-17s %-7s %s' "MAC" "STATUS" "REMAINING")
    RESPONSE="${FENCE}
${header}
${out}${FENCE}"
    RESPONSE_MODE="Markdown"
}

# /kick <mac> — same as the web admin's Kick button: moves an active
# session to paused with its remaining time preserved (or no-ops with a
# "nothing to kick" reply if the MAC has no session at all), then cuts
# its firewall access immediately. Mirrors hotspot.cgi's action=kick.
cmd_kick() {
    local ARG1 MAC
    ARG1=${CMD_ARGS%% *}
    if [ -z "$ARG1" ]; then
        RESPONSE=$(tpl_render "$TPL_CMD_KICK_USAGE")
        return
    fi
    MAC=$(_hs_norm_mac "$ARG1")
    if [ -z "$MAC" ]; then
        RESPONSE=$(tpl_render "$TPL_CMD_BADMAC" input "$ARG1")
        return
    fi

    local ACTIVITY_FILE="/tmp/hotspot_activity.txt"
    local UPTIME PAUSED="false" REM=0 TOT=0
    UPTIME=$(bb awk '{print int($1)}' /proc/uptime 2>/dev/null); [ -n "$UPTIME" ] || UPTIME=0

    _hs_lock
    if [ -f "$SESSION_DATA" ] && bb grep -q "^$MAC " "$SESSION_DATA"; then
        local LINE K_EXP K_TOT
        LINE=$(bb grep "^$MAC " "$SESSION_DATA" | head -1)
        K_EXP=$(printf '%s' "$LINE" | bb awk '{print $2}')
        K_TOT=$(printf '%s' "$LINE" | bb awk '{print $3}')
        REM=$(( K_EXP - UPTIME )); [ "$REM" -lt 0 ] && REM=0
        [ -z "$K_TOT" ] && K_TOT=$REM
        TOT=$K_TOT

        bb grep -v "^$MAC " "$SESSION_DATA" > /tmp/tgkick_s.tmp; bb mv /tmp/tgkick_s.tmp "$SESSION_DATA"

        mkdir -p "$HDATA"; touch "$USERS_FILE"
        if _hs_stage_excl "$MAC"; then
            [ "$REM" -gt 0 ] && echo "$MAC paused $REM $TOT $(_hs_fmt_secs "$REM")" >> "${USERS_FILE}.tmp"
            _hs_commit
        fi
        PAUSED="true"
    fi
    _hs_unlock

    iptables -t nat    -D HOTSPOT     -m mac --mac-source "$MAC" -j RETURN 2>/dev/null
    iptables -t filter -D HOTSPOT_FWD -m mac --mac-source "$MAC" -j ACCEPT 2>/dev/null
    [ -f "$ACTIVITY_FILE" ] && { bb grep -v "^$MAC " "$ACTIVITY_FILE" > /tmp/tgkick_a.tmp 2>/dev/null; bb mv /tmp/tgkick_a.tmp "$ACTIVITY_FILE"; }
    [ -f /tmp/hotspot_ip_map.txt ] && { bb grep -v "^$MAC " /tmp/hotspot_ip_map.txt > /tmp/tgkick_i.tmp; bb mv /tmp/tgkick_i.tmp /tmp/hotspot_ip_map.txt; }

    if [ "$PAUSED" = "true" ]; then
        RESPONSE=$(tpl_render "$TPL_CMD_KICK_OK" mac "$MAC" remainingtime "$(_hs_fmt_secs "$REM")")
        # Same "session paused" alert the web admin's Kick button fires —
        # a manual pause is a manual pause regardless of which UI did it.
        (
            . /lmepisowifi/hotspot/notify_templates.sh
            _P_ACTIVE=$(bb grep -c '.' "$SESSION_DATA" 2>/dev/null); [ -n "$_P_ACTIVE" ] || _P_ACTIVE=0
            _P_MSG=$(tpl_render "$TPL_SESSION_PAUSED" \
                reason "Manually (Telegram)" \
                remainingtime "$(_hs_fmt_secs "$REM")" \
                totaltime "$(_hs_fmt_secs "$TOT")" \
                mac "$MAC" \
                activeusrcount "${_P_ACTIVE:-0}")
            /lmepisowifi/hotspot/notify.sh "$_P_MSG" "" session_paused "$MAC" >/dev/null 2>&1 </dev/null
        ) &
    else
        RESPONSE=$(tpl_render "$TPL_CMD_KICK_NONE" mac "$MAC")
    fi
}

# /addtime <mac> <minutes> — extends an active or paused session; if the
# MAC has no session at all, creates a fresh active one and opens its
# firewall access (mirrors hotspot.cgi's action=add_time, which always
# succeeds instead of erroring on an unknown MAC).
cmd_add_time() {
    local ARG1 ARG2 MAC MINS ADD UPTIME FOUND=0 REM=0 CREATED=0

    ARG1=${CMD_ARGS%% *}
    case "$CMD_ARGS" in
        *" "*) ARG2=${CMD_ARGS#* } ;;
        *) ARG2="" ;;
    esac
    ARG2=${ARG2%% *}

    if [ -z "$ARG1" ] || [ -z "$ARG2" ]; then
        RESPONSE=$(tpl_render "$TPL_CMD_ADDTIME_USAGE")
        return
    fi
    MAC=$(_hs_norm_mac "$ARG1")
    if [ -z "$MAC" ]; then
        RESPONSE=$(tpl_render "$TPL_CMD_BADMAC" input "$ARG1")
        return
    fi
    MINS=$(printf '%s' "$ARG2" | bb tr -cd '0-9')
    if [ -z "$MINS" ] || [ "$MINS" -le 0 ] 2>/dev/null; then
        RESPONSE=$(tpl_render "$TPL_CMD_BADMINUTES")
        return
    fi

    ADD=$(( MINS * 60 ))
    UPTIME=$(bb awk '{print int($1)}' /proc/uptime 2>/dev/null); [ -n "$UPTIME" ] || UPTIME=0

    _hs_lock
    if [ -f "$SESSION_DATA" ] && bb grep -q "^$MAC " "$SESSION_DATA"; then
        bb awk -v m="$MAC" -v add="$ADD" -v up="$UPTIME" '
            $1==m {
                xe=$2; tot=$3
                if (xe=="") xe=up
                if (tot=="") tot=xe-up
                base=(xe>up?xe:up)
                print m, base+add, tot+add
                next
            }
            { print }
        ' "$SESSION_DATA" > /tmp/tgat_s.tmp && bb mv /tmp/tgat_s.tmp "$SESSION_DATA"

        local NEW_EXP NEW_TOT
        NEW_EXP=$(bb grep "^$MAC " "$SESSION_DATA" | bb awk '{print $2}')
        NEW_TOT=$(bb grep "^$MAC " "$SESSION_DATA" | bb awk '{print $3}')
        REM=$(( NEW_EXP - UPTIME ))
        if _hs_stage_excl "$MAC"; then
            echo "$MAC active $REM $NEW_TOT $(_hs_fmt_secs "$REM")" >> "${USERS_FILE}.tmp"
            _hs_commit
        fi
        FOUND=1
    elif [ -f "$USERS_FILE" ] && bb grep -q "^$MAC paused " "$USERS_FILE"; then
        local OLD_P P_REM P_TOT N_TOT
        OLD_P=$(bb grep "^$MAC paused " "$USERS_FILE" | head -1)
        P_REM=$(printf '%s' "$OLD_P" | bb awk '{print $3}')
        P_TOT=$(printf '%s' "$OLD_P" | bb awk '{print $4}')
        [ -z "$P_TOT" ] && P_TOT=$P_REM
        REM=$(( P_REM + ADD ))
        N_TOT=$(( P_TOT + ADD ))
        if _hs_stage_excl_paused "$MAC"; then
            echo "$MAC paused $REM $N_TOT $(_hs_fmt_secs "$REM")" >> "${USERS_FILE}.tmp"
            _hs_commit
        fi
        FOUND=1
    fi

    if [ "$FOUND" -eq 0 ]; then
        mkdir -p "$HDATA"; touch "$SESSION_DATA"; touch "$USERS_FILE"
        echo "$MAC $(( UPTIME + ADD )) $ADD" >> "$SESSION_DATA"
        if _hs_stage_excl "$MAC"; then
            echo "$MAC active $ADD $ADD $(_hs_fmt_secs "$ADD")" >> "${USERS_FILE}.tmp"
            _hs_commit
        fi
        iptables -t nat    -I HOTSPOT     1 -m mac --mac-source "$MAC" -j RETURN 2>/dev/null
        iptables -t filter -I HOTSPOT_FWD 1 -m mac --mac-source "$MAC" -j ACCEPT 2>/dev/null
        REM=$ADD
        CREATED=1
    fi
    _hs_unlock

    if [ "$CREATED" -eq 1 ]; then
        RESPONSE=$(tpl_render "$TPL_CMD_ADDTIME_CREATED" mac "$MAC" minutes "$MINS")
    else
        RESPONSE=$(tpl_render "$TPL_CMD_ADDTIME_OK" mac "$MAC" minutes "$MINS" remainingtime "$(_hs_fmt_secs "$REM")")
    fi
}

# /removetime <mac> <minutes> — subtracts from an active or paused
# session, clamped to a 60s floor so it can never zero one out (use /kick
# for that). Refuses (unlike /addtime) if the MAC has no session at all —
# mirrors hotspot.cgi's action=remove_time.
cmd_remove_time() {
    local ARG1 ARG2 MAC MINS SUB UPTIME FOUND=0 REM=0 MIN_REM=60

    ARG1=${CMD_ARGS%% *}
    case "$CMD_ARGS" in
        *" "*) ARG2=${CMD_ARGS#* } ;;
        *) ARG2="" ;;
    esac
    ARG2=${ARG2%% *}

    if [ -z "$ARG1" ] || [ -z "$ARG2" ]; then
        RESPONSE=$(tpl_render "$TPL_CMD_REMOVETIME_USAGE")
        return
    fi
    MAC=$(_hs_norm_mac "$ARG1")
    if [ -z "$MAC" ]; then
        RESPONSE=$(tpl_render "$TPL_CMD_BADMAC" input "$ARG1")
        return
    fi
    MINS=$(printf '%s' "$ARG2" | bb tr -cd '0-9')
    if [ -z "$MINS" ] || [ "$MINS" -le 0 ] 2>/dev/null; then
        RESPONSE=$(tpl_render "$TPL_CMD_BADMINUTES")
        return
    fi

    SUB=$(( MINS * 60 ))
    UPTIME=$(bb awk '{print int($1)}' /proc/uptime 2>/dev/null); [ -n "$UPTIME" ] || UPTIME=0

    _hs_lock
    if [ -f "$SESSION_DATA" ] && bb grep -q "^$MAC " "$SESSION_DATA"; then
        bb awk -v m="$MAC" -v deduct="$SUB" -v up="$UPTIME" -v minr="$MIN_REM" '
            $1==m {
                xe=$2; tot=$3
                if (xe=="") xe=up; if (tot=="") tot=xe-up
                newxe = xe - deduct; newtot = tot - deduct
                if (newxe < up + minr) newxe = up + minr
                if (newtot < minr)     newtot = minr
                print m, newxe, newtot; next
            }
            { print }
        ' "$SESSION_DATA" > /tmp/tgrt_s.tmp && bb mv /tmp/tgrt_s.tmp "$SESSION_DATA"

        local NEW_EXP NEW_TOT
        NEW_EXP=$(bb grep "^$MAC " "$SESSION_DATA" | bb awk '{print $2}')
        NEW_TOT=$(bb grep "^$MAC " "$SESSION_DATA" | bb awk '{print $3}')
        REM=$(( NEW_EXP - UPTIME ))
        if _hs_stage_excl "$MAC"; then
            echo "$MAC active $REM $NEW_TOT $(_hs_fmt_secs "$REM")" >> "${USERS_FILE}.tmp"
            _hs_commit
        fi
        FOUND=1
    elif [ -f "$USERS_FILE" ] && bb grep -q "^$MAC paused " "$USERS_FILE"; then
        local OLD_P P_REM P_TOT N_TOT
        OLD_P=$(bb grep "^$MAC paused " "$USERS_FILE" | head -1)
        P_REM=$(printf '%s' "$OLD_P" | bb awk '{print $3}')
        P_TOT=$(printf '%s' "$OLD_P" | bb awk '{print $4}')
        [ -z "$P_TOT" ] && P_TOT=$P_REM
        REM=$(( P_REM - SUB )); [ "$REM" -lt "$MIN_REM" ] && REM=$MIN_REM
        N_TOT=$(( P_TOT - SUB )); [ "$N_TOT" -lt "$MIN_REM" ] && N_TOT=$MIN_REM
        if _hs_stage_excl_paused "$MAC"; then
            echo "$MAC paused $REM $N_TOT $(_hs_fmt_secs "$REM")" >> "${USERS_FILE}.tmp"
            _hs_commit
        fi
        FOUND=1
    fi
    _hs_unlock

    if [ "$FOUND" -eq 0 ]; then
        RESPONSE=$(tpl_render "$TPL_CMD_REMOVETIME_NONE" mac "$MAC")
        return
    fi
    RESPONSE=$(tpl_render "$TPL_CMD_REMOVETIME_OK" mac "$MAC" minutes "$MINS" remainingtime "$(_hs_fmt_secs "$REM")")
}
# ------------------------------------------------------------------------

# wget POST of a JSON body (setMyCommands) — replaces `curl -s -X POST ... -d`.
_bot_post_json() {
    "$WGET" -q -T "$TIMEOUT" --no-check-certificate -O /dev/null \
        --header="Content-Type: application/json" \
        --post-data="$2" \
        "$1" 2>/dev/null
}

# wget POST of a chat_id/text reply — replaces `curl -s -d ... -d ...`.
# $3 (optional) is a Telegram parse_mode ("Markdown") — used by
# cmd_active_users so its table renders as an aligned code block instead
# of plain text with the spacing collapsed.
_bot_send_reply() {
    local chat_id="$1" text="$2" mode="$3" enc body
    enc=$(urlenc "$text")
    body="chat_id=${chat_id}&text=${enc}"
    [ -n "$mode" ] && body="${body}&parse_mode=${mode}"
    "$WGET" -q -T "$TIMEOUT" --no-check-certificate -O /dev/null \
        --post-data="$body" \
        "$BOT_API_URL/sendMessage" 2>/dev/null
}

run_bot() {
    local BOT_OFFSET=0
    BOTTAB="$(printf '\t')"

    # Command-response templates ($TPL_CMD_*) — same customizable-message
    # engine the event notifications use (see notify_templates.sh), just a
    # separate override file/admin UI card. Loaded once here rather than
    # per-message, same as the bot config below: editing a response in the
    # admin panel takes effect on the bot's next start/restart, matching
    # how a CMD_ENABLED_*/BOT_TOKEN edit already behaves.
    . /lmepisowifi/hotspot/notify_templates.sh

    # === Bot configuration ===
    local BOT_ENV="/lmepisowifi/hotspot_data/telegram_bot.env"

    # Seed values only — used to create $BOT_ENV the first time this bot
    # ever runs on a device, and as a last-resort fallback. Once $BOT_ENV
    # exists it is the source of truth; edit that file, not this script.
    # REMEMBER: Revoke and regenerate your token in @BotFather!
    local BOT_TOKEN_SEED="YOUR_BOT_TOKEN_HERE"
    local ALLOWED_USER_IDS="6664530859"

    if [ ! -f "$BOT_ENV" ]; then
        mkdir -p "$(dirname "$BOT_ENV")" 2>/dev/null
        cat > "$BOT_ENV" 2>/dev/null <<EOF
# telegram_bot.env — persisted router-bot config.
# Auto-created on first run. Edit THIS file, not the script — updates to
# notify.sh only replace the code, never this file.
#
# Leave BOT_TOKEN empty to reuse the bot token already configured for
# Telegram alerts in notify.env (one bot for alerts + commands). Set it
# here only if the interactive bot should use a different token.
BOT_TOKEN=""
ALLOWED_USER_IDS="$ALLOWED_USER_IDS"

# Start the router bot automatically on every boot. Kept in sync with the
# bot switch in the admin panel (Hotspot > Income > Telegram Bot Commands)
# -- flipping that switch rewrites this line AND adds/removes a matching
# boot marker in www2/sh/startup.sh, so this file doesn't need hand-
# editing. "1" = launch at boot; "0"/unset = stays off until the admin
# flips the switch again.
BOT_AUTOSTART="0"

# Per-command on/off switches. "0" removes a command from the Telegram
# menu and refuses it if sent anyway. Missing/unset = enabled, so this
# file staying untouched after a new command is added keeps working —
# same convention as NOTIFY_EVT_* in notify.env.
# CMD_ENABLED_STATUS="1"
# CMD_ENABLED_REBOOT="1"
# CMD_ENABLED_HOTSPOTSTATS="1"
# CMD_ENABLED_ACTIVEUSERS="1"
# CMD_ENABLED_KICK="1"
# CMD_ENABLED_ADDTIME="1"
# CMD_ENABLED_REMOVETIME="1"
EOF
    fi

    local BOT_TOKEN=""
    [ -f "$BOT_ENV" ] && . "$BOT_ENV" 2>/dev/null
    local TOKEN="$BOT_TOKEN_SEED"
    [ -n "$BOT_TOKEN" ] && TOKEN="$BOT_TOKEN"
    [ -n "$ALLOWED_USER_IDS" ] || ALLOWED_USER_IDS="6664530859"

    # Merge with the existing notification bot: only falls back to it when
    # this bot's own token was never set (still the placeholder), so an
    # already-working custom token here is never silently swapped out.
    if [ "$TOKEN" = "YOUR_BOT_TOKEN_HERE" ] && [ -f "$NOTIFY_ENV" ]; then
        local TG_BOT_TOKEN=""
        . "$NOTIFY_ENV" 2>/dev/null
        [ -n "$TG_BOT_TOKEN" ] && TOKEN="$TG_BOT_TOKEN"
    fi

    BOT_API_URL="https://api.telegram.org/bot$TOKEN"
    # =====================

    # === Register Telegram Menu Commands for Whitelisted Users ===
    echo "Registering menu commands for authorized users..."

    local COMMANDS_JSON
    COMMANDS_JSON=$(build_commands_json)

    local OIFS="$IFS" ID
    IFS=','
    for ID in $ALLOWED_USER_IDS; do
        # Remove any trailing/leading spaces
        ID=$(printf '%s' "$ID" | tr -d ' ')
        if [ -n "$ID" ]; then
            _bot_post_json "$BOT_API_URL/setMyCommands" \
                "{\"commands\":${COMMANDS_JSON},\"scope\":{\"type\":\"chat\",\"chat_id\":${ID}}}"
        fi
    done
    IFS="$OIFS"
    # =============================================================

    echo "Router Bot Started..."

    local UPDATE OK UPDATE_ID USER_ID CHAT_ID COMMAND RESPONSE RESPONSE_MODE POST_ACTION CMD_NAME CMD_ARGS CBODY HANDLER
    while true; do
        # Fetch updates (max 1 at a time, 30s long-poll timeout; local wget
        # timeout is set higher than that so wget doesn't cut the connection
        # before Telegram's own long-poll returns).
        UPDATE=$("$WGET" -q -T 35 --no-check-certificate -O - \
            "$BOT_API_URL/getUpdates?offset=$BOT_OFFSET&limit=1&timeout=30" 2>/dev/null)

        OK=$(json_get "$UPDATE" "ok")
        if [ "$OK" = "true" ]; then

            UPDATE_ID=$(json_get "$UPDATE" "result/0/update_id")

            if [ -n "$UPDATE_ID" ]; then
                USER_ID=$(json_get "$UPDATE" "result/0/message/from/id")
                CHAT_ID=$(json_get "$UPDATE" "result/0/message/chat/id")
                COMMAND=$(json_get "$UPDATE" "result/0/message/text")

                # --- SECURITY CHECK ---
                # We wrap both the list and the user's ID in commas to ensure exact matches
                case ",$ALLOWED_USER_IDS," in
                    *",${USER_ID},"*)
                        RESPONSE=""
                        RESPONSE_MODE=""
                        POST_ACTION=""

                        # --- COMMAND ROUTING (data-driven — see CMD_REGISTRY) ---
                        # Split "/cmd arg1 arg2..." into CMD_NAME (bare
                        # command, no slash, no "@botname" suffix Telegram
                        # appends in group chats) and CMD_ARGS (everything
                        # after the first space, or "" for a no-arg command
                        # like /status).
                        CMD_NAME=""
                        CMD_ARGS=""
                        case "$COMMAND" in
                            /*)
                                CBODY=${COMMAND#/}
                                CMD_NAME=${CBODY%% *}
                                CMD_NAME=${CMD_NAME%%@*}
                                case "$CBODY" in
                                    *" "*) CMD_ARGS=${CBODY#* } ;;
                                    *) CMD_ARGS="" ;;
                                esac
                                ;;
                        esac

                        HANDLER=""
                        [ -n "$CMD_NAME" ] && HANDLER=$(lookup_handler "$CMD_NAME")

                        if [ -n "$HANDLER" ] && cmd_is_enabled "$CMD_NAME"; then
                            "$HANDLER"
                        else
                            RESPONSE=$(tpl_render "$TPL_CMD_UNKNOWN")
                        fi

                        # Send the response back
                        _bot_send_reply "$CHAT_ID" "$RESPONSE" "$RESPONSE_MODE"

                        # Execute delayed commands (set by the handler) after sending
                        [ "$POST_ACTION" = "reboot" ] && reboot
                        ;;
                    *)
                        # Reject unauthorized users
                        _bot_send_reply "$CHAT_ID" "$(tpl_render "$TPL_CMD_UNAUTHORIZED")"
                        ;;
                esac

                # Increment the offset to tell Telegram we processed this message
                BOT_OFFSET=$((UPDATE_ID + 1))
            fi
        fi
        # 2-second pause to prevent CPU pegging in case of network dropouts
        sleep 2
    done
}
# --- end interactive Telegram router bot -----------------------------------

# ── Dispatch ───────────────────────────────────────────────────────────────
if [ "$MSG" = "--bot" ]; then
    run_bot
    exit $?
fi

# Boot-time launcher — called once from a www2/sh/startup.sh marker (added/
# removed by hotspot.cgi's telegram_bot_toggle action, same as the
# Tailscale switch's boot marker). Starts the bot in the background only
# if the admin panel's switch was left on, and is a silent no-op if it's
# off, never configured, or already running (e.g. a stray pidfile that
# survived an unclean shutdown is verified live, not just present).
if [ "$MSG" = "--bot-autostart" ]; then
    _AS_BOT_ENV="/lmepisowifi/hotspot_data/telegram_bot.env"
    BOT_AUTOSTART="0"
    [ -f "$_AS_BOT_ENV" ] && . "$_AS_BOT_ENV" 2>/dev/null
    if [ "$BOT_AUTOSTART" = "1" ]; then
        if [ -f /tmp/telegram_bot.pid ] && kill -0 "$(cat /tmp/telegram_bot.pid)" 2>/dev/null; then
            exit 0
        fi
        "$0" --bot >/tmp/telegram_bot_start.log 2>&1 &
        echo $! > /tmp/telegram_bot.pid
    fi
    exit 0
fi

[ -n "$MSG" ] || exit 0
[ -f "$NOTIFY_ENV" ] || exit 0

# ── Source notify config ──────────────────────────────────────────────────────
NOTIFY_ENABLED=0
TG_BOT_TOKEN=""; TG_CHAT_ID=""; DISCORD_WEBHOOK=""
NOTIFY_TG_ENABLED=""; NOTIFY_DISCORD_ENABLED=""
. "$NOTIFY_ENV" 2>/dev/null

# ── DRAIN MODE — flush queued messages when internet is back ──────────────────
if [ "$MSG" = "--drain" ]; then
    [ "${NOTIFY_ENABLED:-0}" = "1" ] || exit 0
    [ -d "$QUEUE_DIR" ] || exit 0
    _internet_up || exit 0
    for qf in "${QUEUE_DIR}"/*; do
        [ -f "$qf" ] || continue
        MSG=$(cat "$qf" 2>/dev/null)
        [ -n "$MSG" ] || { rm -f "$qf"; continue; }
        case "$qf" in
            *.tg)
                # Drop it if Telegram got switched off since this was queued
                # rather than leave it stuck forever.
                if _tg_should_send; then send_telegram && rm -f "$qf"; else rm -f "$qf"; fi
                ;;
            *.dc)
                if _dc_should_send; then send_discord && rm -f "$qf"; else rm -f "$qf"; fi
                ;;
            *)
                # Legacy queued file from before dual-provider support (no
                # provider suffix) — retry against whatever's configured now.
                _tried=0; _ok=1
                if _tg_should_send; then _tried=1; send_telegram || _ok=0; fi
                if _dc_should_send; then _tried=1; send_discord || _ok=0; fi
                [ "$_tried" = "1" ] && [ "$_ok" = "1" ] && rm -f "$qf"
                ;;
        esac
    done
    exit 0
fi

# ── REGULAR SEND ──────────────────────────────────────────────────────────────
if [ "$FORCE" != "force" ]; then
    [ "${NOTIFY_ENABLED:-0}" = "1" ] || exit 0

    # Per-event mute: if an event key was supplied and its NOTIFY_EVT_<KEY>
    # flag is explicitly "0", stay silent. Unset/empty defaults to enabled.
    # The key is sanitized to [A-Z_] so the eval below can never expand to
    # anything other than a NOTIFY_EVT_* variable name.
    if [ -n "$EVENT" ]; then
        _EVT_KEY=$(printf '%s' "$EVENT" | bb tr 'a-z' 'A-Z' | bb tr -cd 'A-Z0-9_')
        if [ -n "$_EVT_KEY" ]; then
            eval "_EVT_FLAG=\"\${NOTIFY_EVT_${_EVT_KEY}:-1}\""
            [ "$_EVT_FLAG" = "0" ] && exit 0
        fi
    fi
fi

# ── Rapid-repeat suppression (anti-spam) ─────────────────────────────
# When a dedup key is supplied (e.g. the device MAC), collapse bursts of
# the SAME event+key inside a short cooldown window. This kills the flood
# from a client hammering the Pause/Resume buttons: the first pause and
# first resume still notify, but repeats within the window are dropped.
# Window is NOTIFY_DEDUP_WINDOW seconds (default 30); set it to 0 to
# disable. Uses /proc/uptime (monotonic) so a clock jump can't wedge it.
if [ "$FORCE" != "force" ] && [ -n "$DEDUP" ]; then
    _WIN="${NOTIFY_DEDUP_WINDOW:-30}"
    case "$_WIN" in ''|*[!0-9]*) _WIN=30 ;; esac
    if [ "$_WIN" -gt 0 ]; then
        # Map anything outside [A-Za-z0-9_] to _ so the key is a safe
        # filename (colons in the MAC included) — no path traversal.
        _DKEY=$(printf '%s' "${EVENT}_${DEDUP}" | bb tr -c 'A-Za-z0-9_' '_')
        _DDIR="/tmp/notify_dedup"; mkdir -p "$_DDIR" 2>/dev/null
        _DFILE="${_DDIR}/${_DKEY}"
        _NOWU=$(bb awk '{print int($1)}' /proc/uptime 2>/dev/null || bb date +%s)
        if [ -f "$_DFILE" ]; then
            _LAST=$(cat "$_DFILE" 2>/dev/null)
            case "$_LAST" in ''|*[!0-9]*) _LAST=0 ;; esac
            [ $(( _NOWU - _LAST )) -lt "$_WIN" ] && exit 0
        fi
        printf '%s' "$_NOWU" > "$_DFILE"
    fi
fi

# Skip connectivity check for forced sends (test button — always try)
if [ "$FORCE" != "force" ] && ! _internet_up; then
    _tg_should_send && _enqueue tg
    _dc_should_send && _enqueue dc
    exit 0
fi

# Send to every provider that's configured/enabled — Telegram AND Discord
# both fire for the same event when both apply, instead of picking one.
# Each queues independently on failure so a drain only retries the one(s)
# that actually didn't go through.
if _tg_should_send; then
    send_telegram || { [ "$FORCE" != "force" ] && _enqueue tg; }
fi
if _dc_should_send; then
    send_discord || { [ "$FORCE" != "force" ] && _enqueue dc; }
fi

exit 0
