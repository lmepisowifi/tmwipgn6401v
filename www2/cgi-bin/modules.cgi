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


SESSION_TIMEOUT=600

# ---------------------------------------------------------------
# Auth gate — same pattern as hotspot.cgi / lme.cgi
# ---------------------------------------------------------------
BROWSER_SESSION=$(echo "$HTTP_COOKIE" | busybox sed -n 's/.*session=\([^;]*\).*/\1/p' | busybox tr -d '\r\n')
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

case "${CONTENT_LENGTH:-0}" in *[!0-9]*|"") CONTENT_LENGTH=0 ;; esac
[ "$CONTENT_LENGTH" -gt 4096 ] && CONTENT_LENGTH=4096

BB="busybox"
MC="/lmepisowifi/module_ctl.sh"
[ -x "$MC" ] || $BB chmod +x "$MC" 2>/dev/null

ok_json()  { printf "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n%s" "$1"; exit 0; }
err_json() { printf "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n{\"ok\":false,\"error\":\"%s\"}" "$1"; exit 0; }

QS="$QUERY_STRING"
ACT=$(echo "$QS" | $BB grep -o 'action=[^&]*' | $BB sed 's/action=//')

# Read + whitelist the module id from a POST body (only known ids allowed).
post_id() {
    read -n "$CONTENT_LENGTH" BODY
    _v=$(printf '%s' "$BODY" | $BB tr '&' '\n' | $BB grep '^id=' | $BB sed 's/^id=//' | $BB tr -cd 'a-z0-9_-')
    printf '%s' "$_v"
}

[ -x "$MC" ] || err_json "module_ctl_missing"

case "$ACT" in
    list)
        OUT=$("$MC" list 2>/dev/null)
        [ -n "$OUT" ] && ok_json "$OUT" || err_json "list_failed"
        ;;
    status)
        ID=$(echo "$QS" | $BB grep -o 'id=[^&]*' | $BB sed 's/id=//' | $BB tr -cd 'a-z0-9_-')
        [ -z "$ID" ] && ID=hotspot
        OUT=$("$MC" status "$ID" 2>/dev/null)
        [ -n "$OUT" ] && ok_json "$OUT" || err_json "status_failed"
        ;;
    install)
        ID=$(post_id)
        # Any id in module_ctl.sh's own $MODULES list is valid — hardcoding
        # "hotspot" here was a leftover from before tailscale existed as a
        # second module, and silently rejected every other install. Only
        # reject empty (a malformed/missing POST body); module_ctl.sh does
        # the real $MODULES-based validation and returns this same
        # unknown_module error for any id it doesn't recognize.
        [ -n "$ID" ] || err_json "unknown_module"
        # Use per-module files so two concurrent installs (e.g. hotspot + tailscale)
        # don't clobber each other's status/result and produce "unknown_error".
        # MOD_STATUS_FILE is read by module_ctl.sh's set_mod_status() to emit
        # granular phase labels (downloading, verifying, …) that the UI polls.
        _STATUSF="/tmp/module_status_${ID}"
        _RESULTF="/tmp/module_result_${ID}"
        # If a job for this exact module is already running, don't fork a
        # second one on top of it — that race is what used to let an extra
        # click (or a second tab open to this page) send two installs after
        # the same $DL/stage and $ROOT, which could leave the result file
        # empty if both tried to write it at once (the "unknown_error" this
        # used to surface). module_ctl.sh's own install lock is the real
        # guarantee against that; this is just a fast, cheap early-out so a
        # duplicate click doesn't even pay for a second wget/tar. A status
        # file untouched for 20+ minutes is treated as abandoned (e.g. the
        # box lost power mid-install) rather than still running, so a stuck
        # status can never permanently block a fresh attempt.
        _cur=$(cat "$_STATUSF" 2>/dev/null)
        case "$_cur" in
            ""|idle|done) : ;;
            *) [ -z "$($BB find "$_STATUSF" -mmin +20 2>/dev/null)" ] && ok_json '{"ok":true,"started":false,"already_running":true}' ;;
        esac
        printf 'queued' > "$_STATUSF"
        rm -f "$_RESULTF" 2>/dev/null
        ( MOD_STATUS_FILE="$_STATUSF" "$MC" install "$ID" > "$_RESULTF" 2>/dev/null
          printf 'done' > "$_STATUSF" ) &
        ok_json '{"ok":true,"started":true}'
        ;;
    install_status)
        # id is required — without it we can't look up the right per-module files.
        _sid=$(echo "$QS" | $BB grep -o 'id=[^&]*' | $BB sed 's/id=//' | $BB tr -cd 'a-z0-9_-')
        if [ -z "$_sid" ]; then
            ok_json '{"ok":true,"status":"idle","result":null}'; exit 0
        fi
        _STATUSF="/tmp/module_status_${_sid}"
        _RESULTF="/tmp/module_result_${_sid}"
        ST=$(cat "$_STATUSF" 2>/dev/null); [ -z "$ST" ] && ST="idle"
        RES=$(cat "$_RESULTF" 2>/dev/null)
        case "$RES" in {*}) : ;; *) RES="null" ;; esac
        # If the status still shows an in-progress phase but module_ctl.sh's
        # own install lock for this id is gone, or its owning pid is no
        # longer alive, the background job died without writing a result —
        # most likely the device lost power or the process was killed.
        # Report that plainly now instead of leaving the UI to poll a phase
        # that will otherwise never change until its own multi-minute ceiling
        # gives up.
        case "$ST" in
            idle|done) : ;;
            *)
                _LOCKD="/lmepisowifi/modules/${_sid}.installing"
                _lp=$($BB cat "$_LOCKD/pid" 2>/dev/null | $BB tr -d ' \t\r\n')
                if [ ! -d "$_LOCKD" ] || { [ -n "$_lp" ] && ! kill -0 "$_lp" 2>/dev/null; }; then
                    ST="done"; RES='{"ok":false,"error":"install_interrupted"}'
                fi
                ;;
        esac
        ok_json "{\"ok\":true,\"status\":\"$ST\",\"result\":$RES}"
        ;;
    uninstall)
        ID=$(post_id)
        # Same fix as install above — defer id validation to module_ctl.sh.
        [ -n "$ID" ] || err_json "unknown_module"
        OUT=$("$MC" uninstall "$ID" 2>/dev/null)
        [ -n "$OUT" ] && ok_json "$OUT" || err_json "uninstall_failed"
        ;;
    get_auto)
        _v=$("$MC" get_auto 2>/dev/null); [ -z "$_v" ] && _v="1"
        ok_json "{\"auto\":\"$_v\"}"
        ;;
    set_auto)
        read -n "$CONTENT_LENGTH" BODY
        _v=$(printf '%s' "$BODY" | $BB tr '&' '\n' | $BB grep '^auto=' | $BB sed 's/^auto=//' | $BB tr -cd '01' | $BB cut -c1)
        [ -z "$_v" ] && _v=0
        RES=$("$MC" set_auto "$_v" 2>/dev/null)
        ok_json "{\"auto\":\"${RES:-$_v}\"}"
        ;;
    *)
        err_json "unknown_action"
        ;;
esac
