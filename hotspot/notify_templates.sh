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
# notify_templates.sh — customizable Telegram/Discord message
# formats for hotspot events.
#
# Source this file, then render a message with:
#   MSG=$(tpl_render "$TPL_NEW_SALE" totaltime "$total" mac "$mac" ...)
#
# Template syntax:
#   *placeholder*   replaced with the matching value passed to tpl_render
#   %0A             line break (same convention as the MikroTik RouterOS
#                   edition, so templates can be copy-pasted between them)
#
# User overrides live in:
#   /lmepisowifi/hotspot_data/notify_templates.env
# Edit them via the www2 admin UI (Income & Notifications page) or by
# hand. Any TPL_* left unset/empty there falls back to the built-in
# default below, so clearing a field never sends a blank message.
# ============================================================

BB="busybox"

# ── Built-in defaults ─────────────────────────────────────────────────────
DEFAULT_TPL_NEW_SALE='%0A-------New Sale-------%0AMAC: *mac*%0ANodeMCU: *nodemcu*%0ATime Added: *addedtime*%0ATotal Time: *totaltime*%0ARemaining Time: *remainingtime*%0ACoin: ₱*insertcoinamt*%0A%0AOther Information: %0AActive Users: *activeusrcount*%0ADaily: ₱*dailyamt* | Monthly: ₱*monthlyamt* | Yearly: ₱*yearlyamt*%0ADate: *date*%0A%0ASystem Information:%0ACPU Usage: *cpuusage* %0ARAM Usage: *ramusage* %0A'
DEFAULT_TPL_COINS_INSERTED='Coins Inserted%0AAmount: ₱*insertcoinamt*%0ADevice: *mac*%0ANodeMCU: *nodemcu*'
DEFAULT_TPL_ANTI_TROLL='-------Insert Coin Suspended-------%0ADevice: *mac*%0AReached *strikemax* Strikes%0ASuspended For: *cooldownmins* minute(s)'
DEFAULT_TPL_VOUCHER_ANTI_TROLL='-------Voucher Conversion Suspended-------%0ADevice: *mac*%0AReached *strikemax* Strikes%0ASuspended For: *cooldownmins* minute(s)'
DEFAULT_TPL_SESSION_EXPIRED='-------Ran Out of Time-------%0ADevice: *mac*'
DEFAULT_TPL_SESSION_PAUSED='-------Time Paused *reason*-------%0ADevice: *mac*'
DEFAULT_TPL_SESSION_RESUMED='-------Resumed Time-------%0ADevice: *mac*%0ATime Remaining: *remainingtime*%0AActive Users: *activeusrcount*'
DEFAULT_TPL_VOUCHER_REDEEMED='-------Redeemed Voucher-------%0ADevice: *mac*%0AVoucher: *voucher*%0ATime Added: *addedtime*%0ATotal Time: *totaltime*%0ARemaining Time: *remainingtime*%0A'
DEFAULT_TPL_DAILY_REPORT='-------Daily Income-------%0ADate: *label*%0ATotal: ₱*amount*'
DEFAULT_TPL_MONTHLY_REPORT='-------Monthly Income------- Report%0AMonth: *label*%0ATotal: ₱*amount*'
DEFAULT_TPL_YEARLY_REPORT='-------Yearly Income-------%0AYear: *label*%0ATotal: ₱*amount*'
DEFAULT_TPL_TEST_ALERT='this is a test message.'

# ── Built-in defaults: router-bot command responses ───────────────────────
# What notify.sh's --bot command router (/status, /reboot, /hotspotstats,
# /activeusers, /users, /kick, /addtime, /removetime) replies with. Separate from
# the event templates above (different override file, different admin UI
# card — "Bot Command Responses") since they're edited from a different
# place, but rendered through the SAME tpl_render() below.
DEFAULT_TPL_CMD_STATUS='*uptime*'
DEFAULT_TPL_CMD_REBOOT='The system is rebooting..'
DEFAULT_TPL_CMD_HOTSPOTSTATS_NOTINSTALLED='Hotspot module is not installed on this device.'
DEFAULT_TPL_CMD_HOTSPOTSTATS='Hotspot: *running*%0AActive sessions: *sessions*%0A%0AIncome%0AToday: ₱*daily*%0AMonth: ₱*monthly*%0AYear: ₱*yearly*%0AAll-time: ₱*total*'
DEFAULT_TPL_CMD_ACTIVEUSERS_EMPTY='No active users right now.'
DEFAULT_TPL_CMD_USERS_EMPTY='No active or paused users right now.'
DEFAULT_TPL_CMD_KICK_USAGE='Usage: /kick <mac>%0AExample: /kick aa:bb:cc:dd:ee:ff%0ASee /activeusers for a list of connected MACs.'
DEFAULT_TPL_CMD_KICK_OK='Kicked *mac* — had *remainingtime* remaining, now paused (can resume with the same balance).'
DEFAULT_TPL_CMD_KICK_NONE='No active session found for *mac* — nothing to kick.'
DEFAULT_TPL_CMD_ADDTIME_USAGE='Usage: /addtime <mac> <minutes>%0AExample: /addtime aa:bb:cc:dd:ee:ff 30'
DEFAULT_TPL_CMD_ADDTIME_CREATED='No existing session for *mac* — created a new one with *minutes*m.'
DEFAULT_TPL_CMD_ADDTIME_OK='Added *minutes*m to *mac*. Remaining: *remainingtime*.'
DEFAULT_TPL_CMD_REMOVETIME_USAGE='Usage: /removetime <mac> <minutes>%0AExample: /removetime aa:bb:cc:dd:ee:ff 15'
DEFAULT_TPL_CMD_REMOVETIME_NONE='No session found for *mac* — nothing to remove time from.'
DEFAULT_TPL_CMD_REMOVETIME_OK='Removed *minutes*m from *mac*. Remaining: *remainingtime*.'
# Shared across kick/addtime/removetime (same wording for the same mistake
# in every command, one place to edit it instead of three).
DEFAULT_TPL_CMD_BADMAC='That doesn'\''t look like a valid MAC address: *input*'
DEFAULT_TPL_CMD_BADMINUTES='Minutes must be a positive whole number.'
# Dispatch-level replies (unknown /command, or a user not on the allow list).
DEFAULT_TPL_CMD_UNKNOWN='Unknown command.'
DEFAULT_TPL_CMD_UNAUTHORIZED='Unauthorized user. Access denied.'

# ── Load user overrides ──────────────────────────────────────────────────
_TPL_ENV="/lmepisowifi/hotspot_data/notify_templates.env"
[ -f "$_TPL_ENV" ] && . "$_TPL_ENV" 2>/dev/null

# Bot command-response overrides live in their own file (own admin UI card,
# own get/set/reset actions in hotspot.cgi) so saving one never clobbers
# the other.
_BOT_TPL_ENV="/lmepisowifi/hotspot_data/bot_templates.env"
[ -f "$_BOT_TPL_ENV" ] && . "$_BOT_TPL_ENV" 2>/dev/null

# Empty/unset override -> built-in default (":-" covers both cases)
TPL_NEW_SALE="${TPL_NEW_SALE:-$DEFAULT_TPL_NEW_SALE}"
TPL_COINS_INSERTED="${TPL_COINS_INSERTED:-$DEFAULT_TPL_COINS_INSERTED}"
TPL_ANTI_TROLL="${TPL_ANTI_TROLL:-$DEFAULT_TPL_ANTI_TROLL}"
TPL_VOUCHER_ANTI_TROLL="${TPL_VOUCHER_ANTI_TROLL:-$DEFAULT_TPL_VOUCHER_ANTI_TROLL}"
TPL_SESSION_EXPIRED="${TPL_SESSION_EXPIRED:-$DEFAULT_TPL_SESSION_EXPIRED}"
TPL_SESSION_PAUSED="${TPL_SESSION_PAUSED:-$DEFAULT_TPL_SESSION_PAUSED}"
TPL_SESSION_RESUMED="${TPL_SESSION_RESUMED:-$DEFAULT_TPL_SESSION_RESUMED}"
TPL_VOUCHER_REDEEMED="${TPL_VOUCHER_REDEEMED:-$DEFAULT_TPL_VOUCHER_REDEEMED}"
TPL_DAILY_REPORT="${TPL_DAILY_REPORT:-$DEFAULT_TPL_DAILY_REPORT}"
TPL_MONTHLY_REPORT="${TPL_MONTHLY_REPORT:-$DEFAULT_TPL_MONTHLY_REPORT}"
TPL_YEARLY_REPORT="${TPL_YEARLY_REPORT:-$DEFAULT_TPL_YEARLY_REPORT}"
TPL_TEST_ALERT="${TPL_TEST_ALERT:-$DEFAULT_TPL_TEST_ALERT}"

TPL_CMD_STATUS="${TPL_CMD_STATUS:-$DEFAULT_TPL_CMD_STATUS}"
TPL_CMD_REBOOT="${TPL_CMD_REBOOT:-$DEFAULT_TPL_CMD_REBOOT}"
TPL_CMD_HOTSPOTSTATS_NOTINSTALLED="${TPL_CMD_HOTSPOTSTATS_NOTINSTALLED:-$DEFAULT_TPL_CMD_HOTSPOTSTATS_NOTINSTALLED}"
TPL_CMD_HOTSPOTSTATS="${TPL_CMD_HOTSPOTSTATS:-$DEFAULT_TPL_CMD_HOTSPOTSTATS}"
TPL_CMD_ACTIVEUSERS_EMPTY="${TPL_CMD_ACTIVEUSERS_EMPTY:-$DEFAULT_TPL_CMD_ACTIVEUSERS_EMPTY}"
TPL_CMD_USERS_EMPTY="${TPL_CMD_USERS_EMPTY:-$DEFAULT_TPL_CMD_USERS_EMPTY}"
TPL_CMD_KICK_USAGE="${TPL_CMD_KICK_USAGE:-$DEFAULT_TPL_CMD_KICK_USAGE}"
TPL_CMD_KICK_OK="${TPL_CMD_KICK_OK:-$DEFAULT_TPL_CMD_KICK_OK}"
TPL_CMD_KICK_NONE="${TPL_CMD_KICK_NONE:-$DEFAULT_TPL_CMD_KICK_NONE}"
TPL_CMD_ADDTIME_USAGE="${TPL_CMD_ADDTIME_USAGE:-$DEFAULT_TPL_CMD_ADDTIME_USAGE}"
TPL_CMD_ADDTIME_CREATED="${TPL_CMD_ADDTIME_CREATED:-$DEFAULT_TPL_CMD_ADDTIME_CREATED}"
TPL_CMD_ADDTIME_OK="${TPL_CMD_ADDTIME_OK:-$DEFAULT_TPL_CMD_ADDTIME_OK}"
TPL_CMD_REMOVETIME_USAGE="${TPL_CMD_REMOVETIME_USAGE:-$DEFAULT_TPL_CMD_REMOVETIME_USAGE}"
TPL_CMD_REMOVETIME_NONE="${TPL_CMD_REMOVETIME_NONE:-$DEFAULT_TPL_CMD_REMOVETIME_NONE}"
TPL_CMD_REMOVETIME_OK="${TPL_CMD_REMOVETIME_OK:-$DEFAULT_TPL_CMD_REMOVETIME_OK}"
TPL_CMD_BADMAC="${TPL_CMD_BADMAC:-$DEFAULT_TPL_CMD_BADMAC}"
TPL_CMD_BADMINUTES="${TPL_CMD_BADMINUTES:-$DEFAULT_TPL_CMD_BADMINUTES}"
TPL_CMD_UNKNOWN="${TPL_CMD_UNKNOWN:-$DEFAULT_TPL_CMD_UNKNOWN}"
TPL_CMD_UNAUTHORIZED="${TPL_CMD_UNAUTHORIZED:-$DEFAULT_TPL_CMD_UNAUTHORIZED}"

# ── Live system stats (used by the universal *ramusage* / *cpuusage* tokens) ──
# RAM: matches busybox top's own "used" calc (total - free - buffers - cached),
# i.e. excludes reclaimable buffer/cache, so it lines up with the device's
# own `top` output rather than counting cache as "used". Reported in MB
# (rounded to the nearest whole MB) rather than a bare/ambiguous number.
get_ram_usage_mb() {
    $BB awk '
        /^MemTotal:/  { total = $2 }
        /^MemFree:/   { free = $2 }
        /^Buffers:/   { buff = $2 }
        /^Cached:/    { cached = $2 }
        END {
            if (total <= 0) { print 0; exit }
            used = total - free - buff - cached
            if (used < 0) used = 0
            printf "%d", (used + 512) / 1024
        }
    ' /proc/meminfo
}

# CPU: total (non-idle) usage over a short sampling window, computed from
# /proc/stat jiffy deltas — the same source `top` itself reads from. Two
# snapshots ~0.3s apart are needed for an instantaneous reading (a single
# snapshot only gives cumulative totals since boot, which isn't useful).
get_cpu_usage_pct() {
    local line1 line2 t1 i1 t2 i2 dt di
    line1=$($BB awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; printf "%d %d", t, $5}' /proc/stat)
    sleep 0.3 2>/dev/null || sleep 1
    line2=$($BB awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; printf "%d %d", t, $5}' /proc/stat)

    set -- $line1; t1=$1; i1=$2
    set -- $line2; t2=$1; i2=$2

    dt=$(( t2 - t1 ))
    di=$(( i2 - i1 ))
    if [ "$dt" -le 0 ]; then printf '0'; return; fi
    printf '%d' $(( (dt - di) * 100 / dt ))
}

# ── Renderer ──────────────────────────────────────────────────────────────
# tpl_render <template> [<name1> <value1> ...]
# Replaces every *name* token with its value (plain substring search, no
# regex, so values are never mis-interpreted), then converts literal %0A
# sequences to real newlines. Tokens with no matching value are left as-is.
#
# *ramusage* (actual RAM used, e.g. "128 MB") and *cpuusage* (percentage,
# e.g. "8%" — the "%" is already included, don't add your own or it can
# break the Discord/Telegram send) are available in EVERY template
# automatically. They're computed lazily, only when the template actually
# references them, since the CPU sample needs a short ~0.3s window.
tpl_render() {
    local _t="$1"; shift
    case "$_t" in *'*ramusage*'*) set -- "$@" ramusage "$(get_ram_usage_mb) MB" ;; esac
    case "$_t" in *'*cpuusage*'*) set -- "$@" cpuusage "$(get_cpu_usage_pct)%" ;; esac
    while [ "$#" -ge 2 ]; do
        _t=$($BB awk -v t="$_t" -v ph="*$1*" -v val="$2" '
            BEGIN {
                n = length(ph); s = t; out = ""
                while ((i = index(s, ph)) > 0) {
                    out = out substr(s, 1, i - 1) val
                    s = substr(s, i + n)
                }
                printf "%s", out s
            }')
        shift 2
    done
    $BB awk -v t="$_t" 'BEGIN { gsub(/%0A/, "\n", t); printf "%s", t }'
}
