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

# /lmepisowifi/www2/sh/reboot_sched.sh
# Persistent background daemon — started by startup.sh at boot and by
# lme.cgi whenever the schedule is changed.  No crond required.
#
# Usage:  reboot_sched.sh [--once]
#   (no args)  Run as daemon: loop forever checking the schedule.
#   --once     One-shot check: used for testing; exits after one evaluation.
#
# Config file:  /lmepisowifi/reboot_sched.conf
#   mode=uptime|time|none
#   uptime_secs=N          (uptime mode)
#   tod_time=HH:MM         (time mode, 24-hour)
#   days=0,1,2,...         (time mode, 0=Sun…6=Sat; empty = every day)
#
# PID file:  /tmp/reboot_sched.pid
#   Written on start so lme.cgi can kill the old instance before
#   launching a new one.

SCHED_FILE=/lmepisowifi/reboot_sched.conf
PID_FILE=/tmp/reboot_sched.pid
LOCK_FILE=/tmp/reboot_sched_fired   # prevents double-fire within same minute
CHECK_INTERVAL=30    # seconds between checks (30s gives < 1 min reaction time)
ONE_SHOT=0

[ "$1" = "--once" ] && ONE_SHOT=1

# ── Write our PID so lme.cgi can kill us later ──────────────────────────────
echo $$ > "$PID_FILE"

# ── helpers ──────────────────────────────────────────────────────────────────
get_uptime_secs() {
    busybox awk '{print int($1)}' /proc/uptime 2>/dev/null
}

# day-of-week: 0=Sun … 6=Sat  (matches `date +%w`)
get_dow() {
    busybox date +%w 2>/dev/null
}

get_hhmm() {
    busybox date +%H:%M 2>/dev/null
}

# Returns 0 if $1 (HH:MM string) matches $2 (HH:MM string)
time_match() {
    [ "$1" = "$2" ]
}

# Returns 0 if today's DOW is in comma-separated list $1, or if list is empty
dow_match() {
    _LIST="$1"
    _TODAY=$(get_dow)
    [ -z "$_LIST" ] && return 0   # empty = every day
    IFS=','
    for _D in $_LIST; do
        [ "$_D" = "$_TODAY" ] && unset IFS && return 0
    done
    unset IFS
    return 1
}

do_reboot() {
    logger -t reboot_sched "$1 — rebooting"
    # Flush hotspot_data (users.txt, income.env, ...) to flash first — reboot
    # doesn't guarantee pending writes have left the page cache, and this
    # daemon can fire moments after a login/logout/coin write.
    sync
    reboot
}

# ── main loop ────────────────────────────────────────────────────────────────
while true; do

    # Re-read config on every iteration so changes take effect without restart
    [ ! -f "$SCHED_FILE" ] && { [ "$ONE_SHOT" = "1" ] && exit 0; busybox sleep $CHECK_INTERVAL; continue; }

    MODE=$(busybox grep '^mode=' "$SCHED_FILE" \
           | busybox cut -d'=' -f2- | busybox tr -d '\r\n')

    case "$MODE" in

        uptime)
            THRESHOLD=$(busybox grep '^uptime_secs=' "$SCHED_FILE" \
                        | busybox cut -d'=' -f2- | busybox tr -d '\r\n')
            if [ -n "$THRESHOLD" ] && [ -n "$(get_uptime_secs)" ]; then
                CUR=$(get_uptime_secs)
                if [ "$CUR" -ge "$THRESHOLD" ]; then
                    do_reboot "Uptime ${CUR}s >= threshold ${THRESHOLD}s"
                    exit 0
                fi
            fi
            ;;

        time)
            TOD=$(busybox grep '^tod_time=' "$SCHED_FILE" \
                  | busybox cut -d'=' -f2- | busybox tr -d '\r\n')
            DAYS=$(busybox grep '^days=' "$SCHED_FILE" \
                   | busybox cut -d'=' -f2- | busybox tr -d '\r\n')
            NOW=$(get_hhmm)
            # Zero-pad the stored time so comparison works (e.g. "4:0" -> "04:00")
            TOD_H=$(busybox echo "$TOD" | busybox cut -d':' -f1)
            TOD_M=$(busybox echo "$TOD" | busybox cut -d':' -f2)
            TOD_NORM=$(printf '%02d:%02d' "$TOD_H" "$TOD_M")
            if time_match "$NOW" "$TOD_NORM" && dow_match "$DAYS"; then
                # Guard: only fire once per minute even if loop is fast
                FIRE_STAMP="${NOW}_$(busybox date +%Y%m%d)"
                if [ ! -f "$LOCK_FILE" ] || [ "$(cat $LOCK_FILE)" != "$FIRE_STAMP" ]; then
                    echo "$FIRE_STAMP" > "$LOCK_FILE"
                    do_reboot "Time-of-day match $TOD_NORM"
                    exit 0
                fi
            else
                # Outside the target minute — clear the lock so next occurrence fires
                rm -f "$LOCK_FILE"
            fi
            ;;

        none|*)
            # Schedule disabled — nothing to do, but stay alive so
            # a subsequent config change gets picked up on next poll.
            ;;
    esac

    [ "$ONE_SHOT" = "1" ] && exit 0
    busybox sleep $CHECK_INTERVAL

done
