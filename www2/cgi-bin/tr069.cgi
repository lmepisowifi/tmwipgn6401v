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

# tr069.cgi — TR-069 (CWMP) client settings
#
# GET  ?action=status    -> {ok,installed,running,pid,autoexec,cwmp_enabled,url,username,
#                            password,inform,interval,conreq_name,conreq_pw,conreq_path,
#                            conreq_port,acl_enable}
# POST ?action=save      body: autoexec,cwmp_enabled,url,username,password,inform,
#                              interval,conreq_name,conreq_pw,conreq_path,conreq_port
#       -> validates, writes the CWMP_* MIB entries, commits, and (if anything
#          changed) restarts /bin/cwmpClient in the background.
# POST ?action=restart   -> restarts /bin/cwmpClient without changing anything
#
# MIB keys / flag bits are the vendor firmware's own (SDK: user/boa/src/LINUX/
# mibtbl.c + mib.h, and the vendor TR-069 page form_src_generic/fmtr069.c):
#   CWMP_FLAG  (byte)  0x20 AUTORUN  - start cwmpClient at boot / on apply
#   CWMP_FLAG2 (int)   0x80 CWMP_DISABLE - "EnableCWMP" parameter, inverted
# CWMP_FLAG / CWMP_FLAG2 also carry unrelated state bits, so they are only
# ever updated read-modify-write on the one bit this page owns.

SESSION_TIMEOUT=600
BB=busybox
CTL="/lmepisowifi/www2/sh/tr069_ctl.sh"
CWMP_BIN="/bin/cwmpClient"

# ── Auth ──────────────────────────────────────────────────────────────────────
BROWSER_SESSION=$(echo "$HTTP_COOKIE" \
    | $BB sed -n 's/.*session=\([^;]*\).*/\1/p' \
    | $BB tr -d '\r\n')
BROWSER_SESSION=$(printf '%s' "$BROWSER_SESSION" \
    | $BB tr -cd 'a-fA-F0-9')
SESSION_FILE="/tmp/sessions/$BROWSER_SESSION"

if [ -z "$BROWSER_SESSION" ] || [ ! -f "$SESSION_FILE" ]; then
    printf "Status: 302 Found\r\nLocation: /login.html\r\n\r\n"
    exit 0
fi

LAST=$(cat "$SESSION_FILE" 2>/dev/null | $BB tr -d '\r\n')
NOW=$(date +%s)
[ -z "$LAST" ] && LAST=$NOW
if [ $((NOW - LAST)) -gt $SESSION_TIMEOUT ]; then
    rm -f "$SESSION_FILE"
    printf "Status: 302 Found\r\nLocation: /login.html\r\n\r\n"
    exit 0
fi

_STMP=$(mktemp /tmp/sessions/.tmp.XXXXXX)
echo "$NOW" > "$_STMP"
$BB mv "$_STMP" "$SESSION_FILE"

# ── Helpers ───────────────────────────────────────────────────────────────────
send_json() { printf "Status: 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n%s" "$1"; }
ok_json()   { send_json "$1"; exit 0; }
err_json()  { send_json "{\"ok\":false,\"error\":\"$1\"}"; exit 0; }

case "${CONTENT_LENGTH:-0}" in *[!0-9]*|"") CONTENT_LENGTH=0 ;; esac
[ "$CONTENT_LENGTH" -gt 8192 ] && CONTENT_LENGTH=8192

QS="$QUERY_STRING"
ACT=$(echo "$QS" | $BB grep -o 'action=[^&]*' | $BB sed 's/action=//' | $BB head -n 1)

# `mib get NAME` prints "NAME=value"; keep the value exactly as stored.
mib_get() {
    mib get "$1" 2>/dev/null | $BB sed -n "s/^$1=//p" | $BB head -n 1 | $BB tr -d '\r'
}

# `mib set` signals failure in its output as well as (sometimes) its exit
# code, so check both. Output is discarded: it echoes the value being set,
# which can be a password.
mib_set_checked() {
    _o=$(mib set "$1" "$2" 2>&1); _rc=$?
    case "$_o" in *fail*|*error*) _rc=1 ;; esac
    return $_rc
}

jesc() {
    printf '%s' "$1" | $BB tr -d '\r\n\t' | $BB sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Unsigned decimal, falling back to $2 if $1 is empty / not a number.
num_or() {
    case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

# Strip leading zeros so "007" == "7" (and never feed user text to $(( )),
# where a leading 0 means octal).
norm_num() {
    printf '%s' "$1" | $BB sed 's/^0*\([0-9]\)/\1/'
}

# Printable ASCII only (space..~) and at most $2 chars. Anything else is
# refused rather than stripped: the vendor config writer drops non-UTF-8
# bytes, and silently altering a password would lock the device out of its
# ACS with no hint why.
is_text() {
    [ "${#1}" -le "$2" ] || return 1
    case "$1" in *[!\ -~]*) return 1 ;; esac
    return 0
}

load_current() {
    OLD_CWMP_ACS_URL=$(mib_get CWMP_ACS_URL)
    OLD_CWMP_ACS_USERNAME=$(mib_get CWMP_ACS_USERNAME)
    OLD_CWMP_ACS_PASSWORD=$(mib_get CWMP_ACS_PASSWORD)
    OLD_CWMP_INFORM_ENABLE=$(num_or "$(mib_get CWMP_INFORM_ENABLE)" 0)
    OLD_CWMP_INFORM_INTERVAL=$(num_or "$(mib_get CWMP_INFORM_INTERVAL)" 43200)
    OLD_CWMP_CONREQ_USERNAME=$(mib_get CWMP_CONREQ_USERNAME)
    OLD_CWMP_CONREQ_PASSWORD=$(mib_get CWMP_CONREQ_PASSWORD)
    OLD_CWMP_CONREQ_PATH=$(mib_get CWMP_CONREQ_PATH)
    OLD_CWMP_CONREQ_PORT=$(num_or "$(mib_get CWMP_CONREQ_PORT)" 7547)
    OLD_CWMP_FLAG=$(num_or "$(mib_get CWMP_FLAG)" 0)
    OLD_CWMP_FLAG2=$(num_or "$(mib_get CWMP_FLAG2)" 0)
    OLD_CWMP_ACL_ENABLE=$(num_or "$(mib_get CWMP_ACL_ENABLE)" 0)
}

# Run the restart helper detached so it outlives this CGI (same idiom as
# ota.cgi). $1 = 1 when the Connection Request port changed.
run_apply() {
    ( setsid sh "$CTL" apply "$1" >/dev/null 2>&1 </dev/null & ) 2>/dev/null || \
        ( sh "$CTL" apply "$1" >/dev/null 2>&1 </dev/null & )
}

[ -f "$CTL" ] || err_json "helper_missing"

# ================================================================
# GET ?action=status
# ================================================================
if [ "$ACT" = "status" ]; then
    load_current
    PID=$(sh "$CTL" pid 2>/dev/null | $BB tr -cd '0-9')
    [ -z "$PID" ] && PID=0
    RUNNING=false; [ "$PID" -gt 0 ] && RUNNING=true
    INSTALLED=false; [ -x "$CWMP_BIN" ] && INSTALLED=true
    AUTOEXEC=$(( (OLD_CWMP_FLAG & 32) != 0 ? 1 : 0 ))
    CWMP_ENABLED=$(( (OLD_CWMP_FLAG2 & 128) != 0 ? 0 : 1 ))

    ok_json "$(printf '{"ok":true,"installed":%s,"running":%s,"pid":%s,"autoexec":%s,"cwmp_enabled":%s,"url":"%s","username":"%s","password":"%s","inform":%s,"interval":%s,"conreq_name":"%s","conreq_pw":"%s","conreq_path":"%s","conreq_port":%s,"acl_enable":%s}' \
        "$INSTALLED" "$RUNNING" "$PID" "$AUTOEXEC" "$CWMP_ENABLED" \
        "$(jesc "$OLD_CWMP_ACS_URL")" "$(jesc "$OLD_CWMP_ACS_USERNAME")" "$(jesc "$OLD_CWMP_ACS_PASSWORD")" \
        "$OLD_CWMP_INFORM_ENABLE" "$OLD_CWMP_INFORM_INTERVAL" \
        "$(jesc "$OLD_CWMP_CONREQ_USERNAME")" "$(jesc "$OLD_CWMP_CONREQ_PASSWORD")" \
        "$(jesc "$OLD_CWMP_CONREQ_PATH")" "$OLD_CWMP_CONREQ_PORT" "$OLD_CWMP_ACL_ENABLE")"
fi

# Everything below changes state: POST only.
[ "$REQUEST_METHOD" = "POST" ] || err_json "post_required"

# ================================================================
# POST ?action=restart
# ================================================================
if [ "$ACT" = "restart" ]; then
    [ -x "$CWMP_BIN" ] || err_json "not_installed"
    send_json '{"ok":true}'
    run_apply 0
    exit 0
fi

# ================================================================
# POST ?action=save
# ================================================================
if [ "$ACT" = "save" ]; then
    [ -x "$CWMP_BIN" ] || err_json "not_installed"
    read -n "$CONTENT_LENGTH" BODY

    # Fetch + percent-decode one form field (single line).
    form_get() {
        _raw=$(printf '%s' "$BODY" | $BB tr '&' '\n' | $BB grep "^$1=" | $BB head -n 1 | $BB sed 's/^[^=]*=//')
        [ -n "$_raw" ] && $BB httpd -d "$_raw" | $BB tr -d '\r\n'
    }

    load_current

    AUTOEXEC=$(form_get autoexec)
    CWMP_ENABLED=$(form_get cwmp_enabled)
    URL=$(form_get url)
    USERNAME=$(form_get username)
    PASSWORD=$(form_get password)
    INFORM=$(form_get inform)
    INTERVAL=$(form_get interval)
    CR_NAME=$(form_get conreq_name)
    CR_PW=$(form_get conreq_pw)
    CR_PATH=$(form_get conreq_path)
    CR_PORT=$(form_get conreq_port)

    # ── Validate everything before touching the MIB ──
    case "$AUTOEXEC"      in 0|1) ;; *) err_json "bad_request" ;; esac
    case "$CWMP_ENABLED"  in 0|1) ;; *) err_json "bad_request" ;; esac
    case "$INFORM"        in 0|1) ;; *) err_json "bad_request" ;; esac

    is_text "$URL" 256 || err_json "bad_url"
    case "$URL" in
        http://?*|https://?*) ;;
        *) err_json "bad_url" ;;
    esac
    case "$URL" in *\ *) err_json "bad_url" ;; esac

    is_text "$USERNAME" 256 || err_json "bad_username"
    is_text "$PASSWORD" 256 || err_json "bad_password"
    is_text "$CR_NAME"  256 || err_json "bad_conreq_name"
    is_text "$CR_PW"    256 || err_json "bad_conreq_pw"

    # The path array is 32 bytes incl. NUL. Only URL-path-safe characters.
    [ "${#CR_PATH}" -le 31 ] || err_json "bad_path"
    case "$CR_PATH" in *[!A-Za-z0-9/_.~%-]*) err_json "bad_path" ;; esac

    case "$CR_PORT" in ''|*[!0-9]*) err_json "bad_port" ;; esac
    [ "${#CR_PORT}" -le 5 ] || err_json "bad_port"
    CR_PORT=$(norm_num "$CR_PORT")
    [ "$CR_PORT" -ge 1 ] && [ "$CR_PORT" -le 65535 ] || err_json "bad_port"

    if [ "$INFORM" = "1" ]; then
        case "$INTERVAL" in ''|*[!0-9]*) err_json "bad_interval" ;; esac
        [ "${#INTERVAL}" -le 10 ] || err_json "bad_interval"
        INTERVAL=$(norm_num "$INTERVAL")
        [ "$INTERVAL" -ge 1 ] && [ "$INTERVAL" -le 2147483647 ] || err_json "bad_interval"
    else
        # Periodic Inform off: the interval field is not edited (vendor
        # page does the same), keep whatever is stored.
        INTERVAL="$OLD_CWMP_INFORM_INTERVAL"
    fi

    # ── Flags: read-modify-write only the bit this page owns ──
    NEW_FLAG=$(( (OLD_CWMP_FLAG & ~32) | (AUTOEXEC * 32) ))
    NEW_FLAG2=$(( (OLD_CWMP_FLAG2 & ~128) | ((1 - CWMP_ENABLED) * 128) ))

    # ── Apply only what changed ──
    CHANGED=0
    APPLIED=""

    rollback() {
        for _n in $APPLIED; do
            eval "_ov=\$OLD_$_n"
            mib set "$_n" "$_ov" >/dev/null 2>&1
        done
    }

    # $1 = MIB name (old value is in $OLD_<name>), $2 = new value
    set_if_changed() {
        eval "_old=\$OLD_$1"
        [ "$_old" = "$2" ] && return 0
        CHANGED=1
        APPLIED="$APPLIED $1"
        mib_set_checked "$1" "$2"
    }

    # Vendor storeOldACS(): remember the previous ACS URL (the TR-069 client
    # uses it to tell that the ACS changed) before overwriting it.
    if [ "$OLD_CWMP_ACS_URL" != "$URL" ] && [ -n "$OLD_CWMP_ACS_URL" ]; then
        printf '%s' "$OLD_CWMP_ACS_URL" > /var/oldacs 2>/dev/null
        printf '%s' "$OLD_CWMP_ACS_URL" > /var/oldacs_wan 2>/dev/null
    fi

    set_if_changed CWMP_ACS_URL          "$URL"       &&
    set_if_changed CWMP_ACS_USERNAME     "$USERNAME"  &&
    set_if_changed CWMP_ACS_PASSWORD     "$PASSWORD"  &&
    set_if_changed CWMP_INFORM_ENABLE    "$INFORM"    &&
    set_if_changed CWMP_INFORM_INTERVAL  "$INTERVAL"  &&
    set_if_changed CWMP_CONREQ_USERNAME  "$CR_NAME"   &&
    set_if_changed CWMP_CONREQ_PASSWORD  "$CR_PW"     &&
    set_if_changed CWMP_CONREQ_PATH      "$CR_PATH"   &&
    set_if_changed CWMP_CONREQ_PORT      "$CR_PORT"   &&
    set_if_changed CWMP_FLAG             "$NEW_FLAG"  &&
    set_if_changed CWMP_FLAG2            "$NEW_FLAG2" \
        || { rollback; err_json "set_failed"; }

    if [ "$CHANGED" = "0" ]; then
        ok_json '{"ok":true,"changed":false}'
    fi

    if ! mib commit >/dev/null 2>&1; then
        rollback
        err_json "commit_failed"
    fi

    PORT_CHANGED=0
    [ "$OLD_CWMP_CONREQ_PORT" != "$CR_PORT" ] && PORT_CHANGED=1

    send_json "{\"ok\":true,\"changed\":true,\"port_changed\":$PORT_CHANGED}"
    run_apply "$PORT_CHANGED"
    exit 0
fi

err_json "unknown_action"
