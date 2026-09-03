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
# income.sh — persistent hotspot income counters
#   income.sh add <pesos>   add a sale amount to all buckets
#   income.sh get           print current income as JSON
#
# Stored in /lmepisowifi/hotspot_data/income.env so it survives reboots.
# Uses the (NTP-synced) wall clock to roll daily / monthly / yearly
# buckets back to 0 when the calendar period changes. If the clock is
# clearly not yet synced (year < MIN_YEAR), no reset is performed so a
# pre-NTP boot can't wipe the totals with a bogus 1970/2000 date.
# ============================================================

BB="busybox"
DATA_DIR="/lmepisowifi/hotspot_data"
F="$DATA_DIR/income.env"
LOCK="$DATA_DIR/.income.lock"
MIN_YEAR=2024
NTP_MARK="/tmp/ntp_synced"   # maintained by busybox ntpd's -S handler
NTP_MAX_AGE=1800             # marker must be fresh within 30 min (ntpd fires ~11 min)

# Customizable Telegram/Discord message templates
[ -f /lmepisowifi/hotspot/notify_templates.sh ] && . /lmepisowifi/hotspot/notify_templates.sh

bb() { if [ -n "$BB" ]; then "$BB" "$@"; else "$@"; fi; }

# True only when the clock is GENUINELY NTP-synced: the ntpd -S handler
# wrote /tmp/ntp_synced recently. A stale/missing marker => not synced.
is_ntp_synced() {
    [ -f "$NTP_MARK" ] || return 1
    _mt=$(cat "$NTP_MARK" 2>/dev/null)
    case "$_mt" in ''|*[!0-9]*) return 1 ;; esac
    _now=$(date +%s 2>/dev/null)
    case "$_now" in ''|*[!0-9]*) return 1 ;; esac
    _age=$(( _now - _mt ))
    [ "$_age" -ge 0 ] && [ "$_age" -le "$NTP_MAX_AGE" ]
}

mkdir -p "$DATA_DIR" 2>/dev/null

# ---- defaults ----
INCOME_DAY=""; INCOME_MONTH=""; INCOME_YEAR=""
INCOME_DAILY=0; INCOME_MONTHLY=0; INCOME_YEARLY=0; INCOME_TOTAL=0

load() {
    INCOME_DAY=""; INCOME_MONTH=""; INCOME_YEAR=""
    INCOME_DAILY=0; INCOME_MONTHLY=0; INCOME_YEARLY=0; INCOME_TOTAL=0
    [ -f "$F" ] && . "$F" 2>/dev/null
    # coerce numerics
    case "$INCOME_DAILY"   in ''|*[!0-9]*) INCOME_DAILY=0 ;;   esac
    case "$INCOME_MONTHLY" in ''|*[!0-9]*) INCOME_MONTHLY=0 ;; esac
    case "$INCOME_YEARLY"  in ''|*[!0-9]*) INCOME_YEARLY=0 ;;  esac
    case "$INCOME_TOTAL"   in ''|*[!0-9]*) INCOME_TOTAL=0 ;;   esac
}

save() {
    {
        echo "INCOME_DAY=\"$INCOME_DAY\""
        echo "INCOME_MONTH=\"$INCOME_MONTH\""
        echo "INCOME_YEAR=\"$INCOME_YEAR\""
        echo "INCOME_DAILY=\"$INCOME_DAILY\""
        echo "INCOME_MONTHLY=\"$INCOME_MONTHLY\""
        echo "INCOME_YEARLY=\"$INCOME_YEARLY\""
        echo "INCOME_TOTAL=\"$INCOME_TOTAL\""
    } > "$F.tmp" 2>/dev/null
    mv "$F.tmp" "$F" 2>/dev/null
}

# SYNCED is set to 1 when the wall clock looks valid (NTP done)
SYNCED=0
CHANGED=0   # set to 1 when roll_periods alters stored data (gate flash writes)
# Rollover report queue (label|amount) — filled by roll_periods, sent after unlock
RPT_DAILY=""; RPT_MONTHLY=""; RPT_YEARLY=""
roll_periods() {
    CUR_DAY=$(date +%F   2>/dev/null)
    CUR_MON=$(date +%Y-%m 2>/dev/null)
    CUR_YEAR=$(date +%Y   2>/dev/null)
    SYNCED=0
    case "$CUR_YEAR" in
        ''|*[!0-9]*) return ;;     # date unusable
    esac
    # Require REAL NTP sync (marker from ntpd -S handler), plus a sanity check
    # that the year is plausible. Without a genuine sync we never reset.
    if is_ntp_synced && [ "$CUR_YEAR" -ge "$MIN_YEAR" ] 2>/dev/null; then
        SYNCED=1
    fi
    [ "$SYNCED" = "1" ] || return  # clock not trusted yet -> never reset

    # initialize stamps on first trusted run (no rollover, no report)
    [ -z "$INCOME_DAY" ]   && { INCOME_DAY="$CUR_DAY";   CHANGED=1; }
    [ -z "$INCOME_MONTH" ] && { INCOME_MONTH="$CUR_MON"; CHANGED=1; }
    [ -z "$INCOME_YEAR" ]  && { INCOME_YEAR="$CUR_YEAR"; CHANGED=1; }

    # On each period change: queue a report of the period that just ended
    # (only if it earned > 0, mirroring the MikroTik daily-report behaviour),
    # then zero the bucket and advance the marker.
    if [ "$INCOME_DAY" != "$CUR_DAY" ]; then
        [ "${INCOME_DAILY:-0}" -gt 0 ] 2>/dev/null && RPT_DAILY="${INCOME_DAY}|${INCOME_DAILY}"
        INCOME_DAILY=0; INCOME_DAY="$CUR_DAY"; CHANGED=1
    fi
    if [ "$INCOME_MONTH" != "$CUR_MON" ]; then
        [ "${INCOME_MONTHLY:-0}" -gt 0 ] 2>/dev/null && RPT_MONTHLY="${INCOME_MONTH}|${INCOME_MONTHLY}"
        INCOME_MONTHLY=0; INCOME_MONTH="$CUR_MON"; CHANGED=1
    fi
    if [ "$INCOME_YEAR" != "$CUR_YEAR" ]; then
        [ "${INCOME_YEARLY:-0}" -gt 0 ] 2>/dev/null && RPT_YEARLY="${INCOME_YEAR}|${INCOME_YEARLY}"
        INCOME_YEARLY=0; INCOME_YEAR="$CUR_YEAR"; CHANGED=1
    fi
}

# Send any queued rollover reports via notify.sh (which honours NOTIFY_ENABLED).
# Called AFTER the lock is released so the network call never holds the lock.
send_rollover_reports() {
    NOTIFY="/lmepisowifi/hotspot/notify.sh"
    [ -x "$NOTIFY" ] || return
    # period_emoji is the bar-chart glyph (UTF-8), peso is ₱
    if [ -n "$RPT_DAILY" ]; then
        _lbl=${RPT_DAILY%%|*}; _amt=${RPT_DAILY##*|}
        _msg=$(tpl_render "$TPL_DAILY_REPORT" label "$_lbl" amount "$_amt")
        ( "$NOTIFY" "$_msg" "" daily_report >/dev/null 2>&1 </dev/null & )
    fi
    if [ -n "$RPT_MONTHLY" ]; then
        _lbl=${RPT_MONTHLY%%|*}; _amt=${RPT_MONTHLY##*|}
        _msg=$(tpl_render "$TPL_MONTHLY_REPORT" label "$_lbl" amount "$_amt")
        ( "$NOTIFY" "$_msg" "" monthly_report >/dev/null 2>&1 </dev/null & )
    fi
    if [ -n "$RPT_YEARLY" ]; then
        _lbl=${RPT_YEARLY%%|*}; _amt=${RPT_YEARLY##*|}
        _msg=$(tpl_render "$TPL_YEARLY_REPORT" label "$_lbl" amount "$_amt")
        ( "$NOTIFY" "$_msg" "" yearly_report >/dev/null 2>&1 </dev/null & )
    fi
}

lock() {
    i=0
    while ! mkdir "$LOCK" 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -gt 25 ] && break
        sleep 0.2 2>/dev/null || sleep 1
    done
}
unlock() { rmdir "$LOCK" 2>/dev/null; }

CMD="$1"
case "$CMD" in
    add)
        AMT="$2"
        case "$AMT" in ''|*[!0-9]*) exit 0 ;; esac   # ignore non-numeric
        [ "$AMT" -gt 0 ] || exit 0
        lock
        load
        roll_periods
        INCOME_DAILY=$((INCOME_DAILY + AMT))
        INCOME_MONTHLY=$((INCOME_MONTHLY + AMT))
        INCOME_YEARLY=$((INCOME_YEARLY + AMT))
        INCOME_TOTAL=$((INCOME_TOTAL + AMT))
        save
        unlock
        send_rollover_reports
        ;;
    reset)
        # Manual reset of one (or all) buckets, triggered from the admin UI.
        #   income.sh reset daily|monthly|yearly|total|all
        # The all-time TOTAL is only cleared by an explicit 'total' or 'all'
        # so a stray 'daily' reset can never wipe lifetime earnings.
        WHICH="$2"
        case "$WHICH" in daily|monthly|yearly|total|all) ;; *) exit 1 ;; esac
        lock
        load
        case "$WHICH" in
            daily)   INCOME_DAILY=0 ;;
            monthly) INCOME_MONTHLY=0 ;;
            yearly)  INCOME_YEARLY=0 ;;
            total)   INCOME_TOTAL=0 ;;
            all)     INCOME_DAILY=0; INCOME_MONTHLY=0; INCOME_YEARLY=0; INCOME_TOTAL=0 ;;
        esac
        save
        unlock
        printf '{"ok":true,"reset":"%s"}\n' "$WHICH"
        ;;
    get|"")
        lock
        load
        roll_periods
        [ "$CHANGED" = "1" ] && save   # only touch flash when something changed
        unlock
        send_rollover_reports
        SYNC_STR="false"; [ "$SYNCED" = "1" ] && SYNC_STR="true"
        printf '{"daily":%s,"monthly":%s,"yearly":%s,"total":%s,"day":"%s","month":"%s","year":"%s","synced":%s}\n' \
            "${INCOME_DAILY:-0}" "${INCOME_MONTHLY:-0}" "${INCOME_YEARLY:-0}" "${INCOME_TOTAL:-0}" \
            "$INCOME_DAY" "$INCOME_MONTH" "$INCOME_YEAR" "$SYNC_STR"
        ;;
    *)
        echo "usage: income.sh {add <pesos>|get|reset <daily|monthly|yearly|total|all>}" >&2
        exit 1
        ;;
esac
