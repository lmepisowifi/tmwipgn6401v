#!/bin/sh
# ---------------------------------------------------------------------------
# lmepisowifi — https://github.com/lmepisowifi/tmwim2-2050-g40
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The lmepisowifi Project — see AUTHORS
#
# Licensed under the GNU AGPLv3 (see LICENSE). Modifying or rewriting this
# file — including by running it through an LLM — does not remove these
# obligations: keep this notice, mark your changes, and offer Corresponding
# Source to network users (AGPLv3 §5, §13). See PROVENANCE.md before
# presenting this as your own original work.
# ---------------------------------------------------------------------------

# /lmepisowifi/hotspot/ratevalidity.sh — WiFi Rates expiry/validity buckets
# ============================================================================
# A rate in COIN_RATES can carry a third ":validity" field (minutes; 0/absent
# = never expires): "5:90:540" = ₱5 buys 90 minutes that must be used or
# resumed within 540 minutes (9h) of being granted, or whatever's left
# forfeits. Rates with no validity behave exactly as before.
#
# A customer's remaining time is really up to TWO pools: an expiring pool
# (backed by this file) with a hard deadline, and an implicit no-expiry pool
# that is just the rest of USERS_FILE/SESSION_FILE's own REMAIN/TOTAL — this
# file never needs to know that second number, only how much of it is the
# expiring kind. Expiring time is always treated as spent before no-expiry
# time (see rv_grant), so once the expiring pool hits zero the rest of a
# customer's balance is ordinary unlimited-validity time again.
#
# The deadline only matters while a session is PAUSED (offline, not
# ticking): pausing freezes the expiring pool's remaining seconds; if the
# customer doesn't resume before the deadline, that frozen chunk forfeits at
# the next Resume/top-up attempt (see rv_apply_resume) — the pool is never
# force-checked mid-session while a customer stays actively connected.
# Deliberate scope limit: if a validity window is configured shorter than
# its own rate's duration, a customer who never pauses simply never
# triggers a forfeiture (they'll naturally burn through the whole grant,
# expiring bucket first, well before the deadline could matter).
#
# CLOCK — everything here is /proc/uptime, never the wall clock. A device
# with no RTC (or one that hasn't synced yet after a cold boot) can't be
# trusted to know what time it is, so a wall-clock deadline is either
# unenforceable or wrong on exactly the devices that need it most. Uptime
# has no such problem, but it comes with a real trade-off: an uptime value
# only means anything within the boot that produced it. That trade-off is
# deliberately turned into the reboot policy below rather than worked
# around.
#
# REBOOT POLICY — a bucket that's PAUSED (frozen) forfeits outright the
# moment a reboot happens in between, whether or not its deadline would
# otherwise still have time left. This is intentional, not a side effect:
# there is no way to recover how much real time actually elapsed across a
# reboot from uptime alone, so rather than silently mis-crediting or
# mis-debiting that gap, an elapsed reboot is simply treated as the same
# trigger as a missed deadline. Detected via FREEZE_UPTIME, recorded at the
# moment a bucket is frozen: since uptime only ever increases within one
# boot, a later reading LOWER than FREEZE_UPTIME can only mean the box
# rebooted in between. Known, accepted gap in that check: if the new boot
# is already up for longer than FREEZE_UPTIME's own value by the time this
# is next read (e.g. paused shortly after a boot, then rebooted again and
# not checked again until well into the next boot), the comparison alone
# can't tell that boot apart from the original one and the reboot goes
# undetected — the bucket is then judged purely on its ordinary deadline,
# same as if no reboot had happened. That's the safe-for-the-customer
# direction (nobody loses time this check merely failed to flag) and is a
# narrow window in practice.
#
# A LIVE (actively ticking, not paused) bucket has no reboot policy to
# apply directly — same as a paused bucket, there's no way to recover real
# elapsed time from uptime alone across a reboot. Historically this file
# just left it at that: RV_LIVE_FILE is tmpfs, so a live bucket was simply
# gone after any reboot, forced or not, same as SESSION_FILE — except
# SESSION_FILE's balance actually survives a reboot too, via
# lmehspt.sh's periodic sync_to_persistent_db() mirroring it into
# persistent USERS_FILE every 5 minutes and once at boot. A live bucket
# had no equivalent, so its deadline/validity constraint (not the
# underlying money-value time itself) was the one thing that didn't
# survive — it just silently stopped being enforced, rather than
# forfeiting like the paused case already correctly does.
#
# rv_snapshot_live() closes that gap: called on the same 5-minute cadence
# as sync_to_persistent_db() (see lmehspt.sh's main loop), it writes each
# currently-live bucket's remaining-seconds/deadline into RV_FROZEN_FILE as
# a dormant shadow row, without touching RV_LIVE_FILE or the session
# itself. rv_peek() always checks RV_LIVE_FILE first, so a live MAC's own
# shadow row is inert and never consulted while that MAC really is live —
# it only becomes visible once RV_LIVE_FILE is wiped out from under it by
# a reboot, at which point the already-existing FREEZE_UPTIME
# reboot-detection in _rv_forfeited() applies to it exactly as it would to
# a real pause, forfeiting the same way. rv_freeze()/rv_apply_resume()
# both already clear any stale RV_FROZEN_FILE row for a MAC before writing
# their own real one, so a leftover shadow row never conflicts with an
# actual freeze or resume — the real event always wins. Worst case, a
# shadow row can be up to ~5 minutes stale at the moment of a reboot, the
# same staleness SESSION_FILE's own USERS_FILE mirror already accepts.
#
# STORAGE — split the same way SESSION_FILE/USERS_FILE already are: while a
# bucket is "live" (ticking down as part of an active session) it's kept
# in a boundary form anchored to /proc/uptime — meaningless across a
# reboot — so that half lives in tmpfs. Once frozen (paused, or a live
# bucket's periodic shadow copy), a bucket is a plain seconds count plus
# the uptime deadline/reboot-detection pair above, all three perfectly
# safe to persist, so that half lives in hotspot_data, exactly like
# USERS_FILE's paused rows. A MAC is never in both files with a row that
# actually MATTERS at once — a live MAC's shadow row in RV_FROZEN_FILE is
# real storage but a dormant standby, not a second live bucket.
#   RV_LIVE_FILE   "MAC BOUNDARY_UPTIME DEADLINE_UPTIME"              (tmpfs)
#   RV_FROZEN_FILE "MAC REMAIN_SECS FREEZE_UPTIME DEADLINE_UPTIME"    (hotspot_data)
# Absence from both = no expiring bucket at all (the common case for a
# purely no-expiry balance, or a rate purchased with no validity set).
#
# Sourced by: coin_result.sh (rv_grant), coin.sh/login.sh/logout.sh/
# status.sh (mf_reconcile's rv_reconcile_mac call + their own pause/resume/
# display use), lmehspt.sh (pause_session + the expiry watchdog + the
# periodic rv_snapshot_live() call alongside sync_to_persistent_db()),
# macfix.sh (optionally, via rv_reconcile_mac — see there), hotspot.cgi and
# notify.sh's Telegram bot (the admin "kick" == pause action in each).
# Requires the sourcing script to already define BB.
# ============================================================================

RV_LIVE_FILE="/tmp/rate_validity_live.txt"
RV_FROZEN_FILE="/lmepisowifi/hotspot_data/rate_validity.txt"

_rv_now_uptime() { $BB awk '{print int($1)}' /proc/uptime 2>/dev/null; }

_rv_grep_row() {
    # $1=file $2=mac
    [ -f "$1" ] || return 0
    $BB grep "^$2 " "$1" 2>/dev/null | $BB head -1
}

# Stages "$1.tmp" with every line of file $1 except MAC $2's, WITHOUT
# committing — same exclude-then-recommit idiom (and the same refuse-on-
# read-error guard) as _users_file_stage_excl elsewhere in this project.
# Call this INSIDE the caller's own _lock.
_rv_stage_excl() {
    local file="$1" mac="$2" existed=0 rc=0
    [ -e "$file" ] && existed=1
    $BB grep -v "^${mac} " "$file" > "${file}.tmp" 2>/dev/null || rc=$?
    if [ "$existed" -eq 1 ] && [ "$rc" -gt 1 ]; then
        rm -f "${file}.tmp" 2>/dev/null
        return 1
    fi
    return 0
}
_rv_commit() {
    $BB mkdir -p /lmepisowifi/hotspot_data 2>/dev/null
    $BB mv "${1}.tmp" "$1"
}

# Removes MAC $1's row from both files. A bucket can only ever legitimately
# be "no row anywhere", or exactly one row in exactly one of the two files
# — never both at once, so clearing both is always safe.
rv_clear() {
    local mac="$1"
    _rv_stage_excl "$RV_LIVE_FILE" "$mac"   && _rv_commit "$RV_LIVE_FILE"
    _rv_stage_excl "$RV_FROZEN_FILE" "$mac" && _rv_commit "$RV_FROZEN_FILE"
}

# Sets RV_REMAIN / RV_DEADLINE to MAC $1's CURRENT expiring-bucket state —
# both 0 if it has none. Also sets RV_FREEZE_UPTIME (0 unless the bucket is
# currently frozen), for the reboot-detection check in rv_peek_forfeit /
# rv_apply_resume below — see REBOOT POLICY above. Checks the live file
# first (decaying its boundary against $2, defaulting to right now, if
# found), then the frozen one (already static values, no decay needed).
# Read-only; never itself judges forfeiture.
rv_peek() {
    local mac="$1" now_up="${2:-$(_rv_now_uptime)}" row boundary deadline remain freeze_up
    RV_REMAIN=0; RV_DEADLINE=0; RV_FREEZE_UPTIME=0

    row=$(_rv_grep_row "$RV_LIVE_FILE" "$mac")
    if [ -n "$row" ]; then
        boundary=$($BB echo "$row" | $BB awk '{print $2}')
        deadline=$($BB echo "$row" | $BB awk '{print $3}')
        case "$boundary" in ''|*[!0-9]*) boundary=0 ;; esac
        case "$deadline" in ''|*[!0-9]*) deadline=0 ;; esac
        remain=$(( boundary - now_up ))
        [ "$remain" -lt 0 ] && remain=0
        RV_REMAIN=$remain
        RV_DEADLINE=$deadline
        return 0
    fi

    row=$(_rv_grep_row "$RV_FROZEN_FILE" "$mac")
    if [ -n "$row" ]; then
        remain=$($BB echo "$row" | $BB awk '{print $2}')
        freeze_up=$($BB echo "$row" | $BB awk '{print $3}')
        deadline=$($BB echo "$row" | $BB awk '{print $4}')
        case "$remain" in ''|*[!0-9]*) remain=0 ;; esac
        case "$freeze_up" in ''|*[!0-9]*) freeze_up=0 ;; esac
        case "$deadline" in ''|*[!0-9]*) deadline=0 ;; esac
        RV_REMAIN=$remain
        RV_DEADLINE=$deadline
        RV_FREEZE_UPTIME=$freeze_up
    fi
}

# True (rc 0) if MAC $1's currently-frozen bucket (RV_REMAIN/RV_DEADLINE/
# RV_FREEZE_UPTIME — call rv_peek first) has forfeited as of uptime $2:
# either its deadline has passed, or a reboot happened since it was frozen
# — see REBOOT POLICY above. Pure predicate — reads the RV_* globals rv_peek
# already set, writes nothing, judges nothing about a live (non-frozen)
# bucket (RV_FREEZE_UPTIME is 0 there, so only the deadline arm can fire,
# same as before this bucket ever had a reboot to worry about).
_rv_forfeited() {
    local now_up="$1"
    [ "${RV_REMAIN:-0}" -gt 0 ] || return 1

    # If a reboot occurred while frozen (now_up < FREEZE_UPTIME),
    # only forfeit if it had ALREADY expired before the freeze/reboot.
    if [ "${RV_FREEZE_UPTIME:-0}" -gt 0 ] && [ "$now_up" -lt "$RV_FREEZE_UPTIME" ]; then
        if [ "${RV_DEADLINE:-0}" -gt 0 ] && [ "${RV_FREEZE_UPTIME:-0}" -ge "${RV_DEADLINE:-0}" ]; then
            return 0
        fi
        return 1
    fi

    # Normal check within the same boot
    if [ "${RV_DEADLINE:-0}" -gt 0 ] && [ "$now_up" -gt "$RV_DEADLINE" ]; then
        return 0
    fi
    return 1
}

# Read-only variant for a hot, frequently-polled caller (status.sh): sets
# RV_FORFEITABLE to how many seconds of MAC $1's bucket WOULD forfeit if
# resumed/checked right now (0 if none, or it's not yet forfeit-eligible).
# Never writes anything — the actual forfeiture is only ever committed by
# rv_apply_resume, at an actual resume/top-up.
rv_peek_forfeit() {
    local now_up="${2:-$(_rv_now_uptime)}"
    rv_peek "$1" "$now_up"
    RV_FORFEITABLE=0
    _rv_forfeited "$now_up" && RV_FORFEITABLE=$RV_REMAIN
}

# Call whenever a session pauses (auto-pause, manual logout, admin kick) —
# freezes MAC $1's expiring bucket, if it has one, out of the live file and
# into the frozen one at pause time $2 (uptime), recording $2 itself as the
# new FREEZE_UPTIME (see REBOOT POLICY above). $3, if given, clamps the
# frozen amount to at most that many seconds (the ACTUAL total being
# paused) as a defensive safety net. No-op (and clears any stale row) once
# there's nothing left to freeze. Mirrors rv_apply_resume/rv_peek_forfeit's
# scope note: freezing an already-frozen bucket (re-kicking, in practice
# never reachable — pause_session()/logout.sh/hotspot.cgi/notify.sh all
# only ever call this on a currently-active MAC) does not itself re-check
# forfeiture; that's only ever evaluated at the next Resume/top-up attempt.
rv_freeze() {
    local mac="$1" pause_up="$2" clamp="${3:-}"
    rv_peek "$mac" "$pause_up"
    if [ -n "$clamp" ] && [ "${RV_REMAIN:-0}" -gt "$clamp" ]; then
        RV_REMAIN=$clamp
    fi

    # Re-anchor deadline if freezing across a reboot
    if [ "${RV_FREEZE_UPTIME:-0}" -gt 0 ] && [ "$pause_up" -lt "$RV_FREEZE_UPTIME" ]; then
        if [ "${RV_DEADLINE:-0}" -gt "$RV_FREEZE_UPTIME" ]; then
            RV_DEADLINE=$(( pause_up + (RV_DEADLINE - RV_FREEZE_UPTIME) ))
        fi
    fi

    _rv_stage_excl "$RV_LIVE_FILE" "$mac" && _rv_commit "$RV_LIVE_FILE"

    if [ "${RV_REMAIN:-0}" -le 0 ]; then
        _rv_stage_excl "$RV_FROZEN_FILE" "$mac" && _rv_commit "$RV_FROZEN_FILE"
        return 0
    fi
    if _rv_stage_excl "$RV_FROZEN_FILE" "$mac"; then
        printf '%s %d %d %d\n' "$mac" "$RV_REMAIN" "$pause_up" "${RV_DEADLINE:-0}" >> "${RV_FROZEN_FILE}.tmp"
        _rv_commit "$RV_FROZEN_FILE"
    fi
}

# Call whenever a paused session is about to become active again (an
# explicit Resume tap, or a voucher/coin top-up stacking onto a paused
# balance). $2 = uptime "now" for the resulting active session. Moves any
# still-valid frozen bucket into the live file anchored at $2, or forfeits
# (drops) one whose deadline has passed or that was rebooted through while
# frozen — see REBOOT POLICY above. Sets RV_FORFEITED to the seconds just
# forfeited (0 if none) — the caller MUST subtract this from whatever
# remaining/total it is about to grant back.
rv_apply_resume() {
    local mac="$1" resume_up="$2"
    rv_peek "$mac" "$resume_up"
    RV_FORFEITED=0

    _rv_stage_excl "$RV_LIVE_FILE" "$mac"   && _rv_commit "$RV_LIVE_FILE"
    _rv_stage_excl "$RV_FROZEN_FILE" "$mac" && _rv_commit "$RV_FROZEN_FILE"

    [ "${RV_REMAIN:-0}" -gt 0 ] || return 0

    if _rv_forfeited "$resume_up"; then
        RV_FORFEITED=$RV_REMAIN
        return 0
    fi

    # Across a reboot, re-anchor the deadline to the new boot's uptime:
    if [ "${RV_FREEZE_UPTIME:-0}" -gt 0 ] && [ "$resume_up" -lt "$RV_FREEZE_UPTIME" ]; then
        if [ "${RV_DEADLINE:-0}" -gt "$RV_FREEZE_UPTIME" ]; then
            RV_DEADLINE=$(( resume_up + (RV_DEADLINE - RV_FREEZE_UPTIME) ))
        fi
    fi

    # 1. Update RAM live file
    if _rv_stage_excl "$RV_LIVE_FILE" "$mac"; then
        printf '%s %d %d\n' "$mac" "$(( resume_up + RV_REMAIN ))" "${RV_DEADLINE:-0}" >> "${RV_LIVE_FILE}.tmp"
        _rv_commit "$RV_LIVE_FILE"
    fi

    # 2. IMMEDIATELY record shadow row to persistent storage on Flash
    if _rv_stage_excl "$RV_FROZEN_FILE" "$mac"; then
        printf '%s %d %d %d\n' "$mac" "$RV_REMAIN" "$resume_up" "${RV_DEADLINE:-0}" >> "${RV_FROZEN_FILE}.tmp"
        _rv_commit "$RV_FROZEN_FILE"
        sync
    fi
}

# Merges a freshly-purchased expiring bucket into MAC $1's existing one (if
# any) and writes the result as a single live row anchored at $4 (uptime
# "now" of the resulting session — always active, since a successful grant
# always leaves the customer connected).
#   $2 = seconds of THIS purchase that came from a rate tier with a
#        validity window (0 if none)
#   $3 = that tier's validity duration in seconds (0 if $2 is 0)
#   $4 = current uptime
#
# Combining two different validity windows into one pool is a deliberate
# simplification: rather than tracking every purchase as its own
# generation with its own deadline, this keeps a single combined expiring
# pool per customer and applies the EARLIER (soonest) of the two deadlines
# to the whole pool. That's conservative — it can only forfeit a top-up's
# minutes sooner than that top-up's own validity alone would, never later
# than any individual purchase's promised window.
rv_grant() {
    local mac="$1" new_secs="${2:-0}" new_valid_secs="${3:-0}" now_up="$4"
    local exist_remain exist_deadline new_deadline combined_remain combined_deadline

    if [ "$new_secs" -gt 0 ] && [ "$new_valid_secs" -gt 0 ]; then
        rv_apply_resume "$mac" "$now_up"
        rv_peek "$mac" "$now_up"
        exist_remain=${RV_REMAIN:-0}
        exist_deadline=${RV_DEADLINE:-0}

        combined_remain=$(( exist_remain + new_secs ))

        # STACK VALIDITY:
        # If the customer already has an active deadline in the future,
        # add the new validity window on top of the existing deadline.
        if [ "$exist_deadline" -gt "$now_up" ]; then
            combined_deadline=$(( exist_deadline + new_valid_secs ))
        else
            combined_deadline=$(( now_up + new_valid_secs ))
        fi

        # 1. Update RAM live file
        if _rv_stage_excl "$RV_LIVE_FILE" "$mac"; then
            printf '%s %d %d\n' "$mac" "$(( now_up + combined_remain ))" "$combined_deadline" >> "${RV_LIVE_FILE}.tmp"
            _rv_commit "$RV_LIVE_FILE"
        fi

        # 2. IMMEDIATELY record shadow row to persistent storage on Flash
        if _rv_stage_excl "$RV_FROZEN_FILE" "$mac"; then
            printf '%s %d %d %d\n' "$mac" "$combined_remain" "$now_up" "$combined_deadline" >> "${RV_FROZEN_FILE}.tmp"
            _rv_commit "$RV_FROZEN_FILE"
            sync
        fi
    else
        # This purchase itself carries no validity, but a pre-existing
        # expiring bucket must still be resolved rather than left stranded.
        rv_apply_resume "$mac" "$now_up" >/dev/null
    fi
}

# Renames MAC $2 (old)'s row in file $1 onto MAC $3 (new) — or, if $3
# already has a row of its own there, leaves BOTH exactly where they are
# rather than guess how to combine them (same philosophy as macfix.sh's
# own _mf_reconcile_row declining to merge a "users" collision it isn't
# sure about).
_rv_migrate_file() {
    local file="$1" old="$2" new="$3" old_row existed=0 rc=0
    [ -f "$file" ] || return 0
    old_row=$($BB grep "^${old} " "$file" 2>/dev/null | $BB head -1)
    [ -n "$old_row" ] || return 0
    $BB grep -q "^${new} " "$file" 2>/dev/null && return 0

    [ -e "$file" ] && existed=1
    $BB grep -v "^${old} " "$file" > "${file}.tmp" 2>/dev/null || rc=$?
    if [ "$existed" -eq 1 ] && [ "$rc" -gt 1 ]; then
        rm -f "${file}.tmp" 2>/dev/null
        return 1
    fi
    printf '%s\n' "${new}${old_row#"$old"}" >> "${file}.tmp"
    $BB mv "${file}.tmp" "$file"
}

# MAC-randomization continuity: called from macfix.sh's mf_reconcile() once
# CLIENT_MAC's users.txt row has already been migrated the same way, so a
# customer's expiring bucket follows their browser across a MAC rotation
# instead of being orphaned under the old MAC.
rv_reconcile_mac() {
    _rv_migrate_file "$RV_LIVE_FILE"   "$1" "$2"
    _rv_migrate_file "$RV_FROZEN_FILE" "$1" "$2"
}

# Call on the same periodic cadence as lmehspt.sh's sync_to_persistent_db()
# (same 5-minute main-loop tick, inside the same _lock). Gives every
# currently-LIVE expiring bucket a persistent shadow copy in RV_FROZEN_FILE
# so it survives a reboot instead of just vanishing — see the REBOOT POLICY
# section above for why this is safe to sit alongside a live MAC's real
# RV_LIVE_FILE row. $1 = uptime "now" for this snapshot (defaults to a
# fresh read). Never touches RV_LIVE_FILE or the session itself — this is
# a backup, not a state transition. No-op if nothing is currently live.
#
# Same I/O-glitch guard as sync_to_persistent_db(): a `while read` loop
# doesn't surface a mid-read flash error the way grep's exit status does,
# so probe both files with `cat` first and skip the whole rebuild (leaving
# RV_FROZEN_FILE untouched) rather than risk silently truncating a real
# paused customer's row on a transient read failure.
rv_snapshot_live() {
    local now_up="${1:-$(_rv_now_uptime)}"
    [ -s "$RV_LIVE_FILE" ] || return 0

    if [ -s "$RV_FROZEN_FILE" ] && ! $BB cat "$RV_FROZEN_FILE" >/dev/null 2>&1; then
        return 1
    fi
    if ! $BB cat "$RV_LIVE_FILE" >/dev/null 2>&1; then
        return 1
    fi

    : > "${RV_FROZEN_FILE}.tmp"

    # Carry over every existing frozen row EXCEPT one whose MAC is also
    # currently live — that MAC's old row (a real paused freeze, or a
    # now-stale shadow from a previous tick) is superseded by the fresh
    # shadow snapshot written just below instead.
    if [ -f "$RV_FROZEN_FILE" ]; then
        local fmac frest
        while read -r fmac frest; do
            [ -n "$fmac" ] || continue
            $BB grep -q "^${fmac} " "$RV_LIVE_FILE" 2>/dev/null && continue
            printf '%s %s\n' "$fmac" "$frest" >> "${RV_FROZEN_FILE}.tmp"
        done < "$RV_FROZEN_FILE"
    fi

    # One dormant shadow row per live MAC that still has time left.
    local mac boundary deadline remain
    while read -r mac boundary deadline; do
        [ -n "$mac" ] || continue
        case "$boundary" in ''|*[!0-9]*) boundary=0 ;; esac
        remain=$(( boundary - now_up ))
        [ "$remain" -gt 0 ] || continue
        printf '%s %d %d %d\n' "$mac" "$remain" "$now_up" "${deadline:-0}" >> "${RV_FROZEN_FILE}.tmp"
    done < "$RV_LIVE_FILE"

    _rv_commit "$RV_FROZEN_FILE"
}
