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

# freewifi.sh — "Free WiFi" claim tracking, sourced (never executed) by
# login.sh (the claim itself) and status.sh (to tell the portal whether to
# show the button). Shared so both agree on exactly one definition of
# "may this device claim right now".
#
# A device may claim FREE_WIFI_MINUTES of internet by tapping one button on
# the portal, then has to wait FREE_WIFI_COOLDOWN minutes (0 = once per
# device, never again) before it can claim again. State is one flat,
# MAC-keyed file in hotspot_data/ (survives reboots and OTAs):
#
#     MAC LAST_CLAIM_EPOCH CLAIM_COUNT
#
# Wall-clock (date +%s) rather than uptime on purpose: the cooldown must
# outlive a reboot, or power-cycling the box would reset everyone's wait.
# That is also why a claim is refused until the clock looks synced (see
# fw_clock_ok) — a claim stamped with a 1970 clock would be meaningless.
#
# Expiry (optional): the free time can carry a validity window using the very
# same bucket as a WiFi Rate's ":validity" (ratevalidity.sh, rv_grant) - so it
# forfeits if the device pauses and doesn't resume in time, and stacks onto an
# existing unexpired bucket exactly the way rate validity does. fw_validity_mins
# resolves FREE_WIFI_EXPIRY_MODE (none | custom | claim) to minutes.
#
# Requires the sourcing script to already define: BB. fw_record must be
# called INSIDE the caller's _lock (same as every other hotspot_data write).

FREE_CLAIM_FILE="/lmepisowifi/hotspot_data/free_claims.txt"
# Anything earlier than 2025-01-01 can only be an unsynced RTC/boot clock.
FW_MIN_EPOCH=1735689600
# Hard cap on the file when FREE_WIFI_COOLDOWN=0 (rows never expire then),
# so a flood of randomized MACs can't grow it forever. Oldest rows go first.
FW_MAX_ROWS=5000

# _fw_num <value> <fallback>: digits-only, leading zeros stripped (so "010" is
# ten, never octal 8 / a crash in busybox ash arithmetic), else <fallback>.
_fw_num() {
    case "$1" in ''|*[!0-9]*) echo "$2"; return ;; esac
    local v="$1"
    v="${v#"${v%%[!0]*}"}"
    echo "${v:-0}"
}
_fw_now() { _fw_num "$(date +%s 2>/dev/null)" 0; }

fw_clock_ok() { [ "$(_fw_now)" -ge "$FW_MIN_EPOCH" ]; }

# fw_validity_mins  ->  prints the validity window, in minutes, that a free
# claim's time carries (0 = no expiry). Modes:
#   custom - FREE_WIFI_EXPIRY_MINUTES
#   claim  - the same length as the claimed session (FREE_WIFI_MINUTES)
#   other  - none (anything unrecognised fails safe to the old behavior)
fw_validity_mins() {
    local fmin vmin
    case "${FREE_WIFI_EXPIRY_MODE:-none}" in
        claim)
            fmin=$(_fw_num "${FREE_WIFI_MINUTES:-10}" 10)
            [ "$fmin" -ge 1 ] || fmin=10
            echo "$fmin"
            ;;
        custom)
            vmin=$(_fw_num "${FREE_WIFI_EXPIRY_MINUTES:-60}" 60)
            echo "$vmin"
            ;;
        *) echo 0 ;;
    esac
}

# fw_wait <mac>  ->  sets FW_WAIT:
#    0  = this device may claim now
#   >0  = seconds until it may claim again
#   -1  = already claimed and the admin set "once per device"
fw_wait() {
    local mac="$1" row last cd now el
    FW_WAIT=0
    row=$($BB grep "^${mac} " "$FREE_CLAIM_FILE" 2>/dev/null | $BB head -1)
    [ -n "$row" ] || return 0
    last=$(_fw_num "$(printf '%s' "$row" | $BB awk '{print $2}')" "")
    [ -n "$last" ] || return 0
    cd=$(_fw_num "${FREE_WIFI_COOLDOWN:-1440}" 1440)
    if [ "$cd" -eq 0 ]; then FW_WAIT=-1; return 0; fi
    cd=$(( cd * 60 ))
    now=$(_fw_now)
    # Clock behind the stored stamp (not synced yet after a reboot, or
    # stepped backwards): fail closed with the full cooldown instead of
    # treating a tiny "elapsed" as permission.
    if [ "$now" -lt "$last" ]; then FW_WAIT=$cd; return 0; fi
    el=$(( now - last ))
    [ "$el" -ge "$cd" ] || FW_WAIT=$(( cd - el ))
    return 0
}

# fw_record <mac>  — stamp "claimed just now" (count+1) for this MAC and
# prune rows whose cooldown has long since elapsed. Returns 1, leaving the
# file untouched, if it can't be read/rewritten safely (same read-error
# guard as login.sh's _users_file_stage_excl: a transient flash read glitch
# must not be committed over the file as an empty result, which would
# silently forgive every device's cooldown).
fw_record() {
    local mac="$1" now cd cutoff cnt existed=0 rc=0 tmp="${FREE_CLAIM_FILE}.tmp"
    now=$(_fw_now)
    cd=$(_fw_num "${FREE_WIFI_COOLDOWN:-1440}" 1440)
    cutoff=0
    [ "$cd" -gt 0 ] && cutoff=$(( now - cd * 60 ))
    [ "$cutoff" -lt 0 ] && cutoff=0
    [ -e "$FREE_CLAIM_FILE" ] && existed=1
    cnt=$(_fw_num "$($BB grep "^${mac} " "$FREE_CLAIM_FILE" 2>/dev/null | $BB head -1 | $BB awk '{print $3}')" 0)
    cnt=$(( cnt + 1 ))
    $BB awk -v m="$mac" -v cut="$cutoff" '$1 != m && $2 + 0 >= cut' "$FREE_CLAIM_FILE" > "$tmp" 2>/dev/null || rc=$?
    if [ "$existed" -eq 1 ] && [ "$rc" -ne 0 ]; then
        rm -f "$tmp" 2>/dev/null
        logger -t lmehspt "free_claims.txt: refused rewrite after read error (rc=$rc) - kept existing file" 2>/dev/null
        return 1
    fi
    printf '%s %s %s\n' "$mac" "$now" "$cnt" >> "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    if [ "$cd" -eq 0 ]; then
        $BB tail -n "$FW_MAX_ROWS" "$tmp" > "${tmp}2" 2>/dev/null && $BB mv "${tmp}2" "$tmp"
    fi
    $BB mv "$tmp" "$FREE_CLAIM_FILE" || { rm -f "$tmp" 2>/dev/null; return 1; }
    # Links a real customer MAC to a timestamp — same 600 as users.txt,
    # re-applied on every commit because mv carries over the .tmp's mode.
    $BB chmod 600 "$FREE_CLAIM_FILE" 2>/dev/null
    # Force it to NAND now: a power cut right after a claim must not roll
    # the cooldown back and hand the same device another free session.
    sync
    return 0
}
