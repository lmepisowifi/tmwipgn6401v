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


export GOMIPS=softfloat
export GOGC=20
export GOMEMLIMIT=1MiB
export GOMAXPROCS=2
export XDG_CACHE_HOME=/tmp

# ============================================================
# tailscale_ctl.sh — Tailscale (userspace) lifecycle for lmepisowifi
# ============================================================

ROOT="/lmepisowifi"
TS_DIR="$ROOT/tailscale"
DAEMON="$TS_DIR/tailscaled-small"
CLI="$TS_DIR/tailscale-small"

CFG_DIR="/config/tailscale"
CFG="$CFG_DIR/config.env"
STATE_DIR="/config/tailscale-state"

SOCK="/tmp/tailscaled.sock"
PIDF="/tmp/tailscaled.pid"
UPPIDF="/tmp/tailscale_up.pid"
LOGIN_URL_FILE="/tmp/tailscale_login_url"
DAEMON_LOG="/tmp/tailscaled.log"
UP_LOG="/tmp/tailscale_up.log"
STATUS_CACHE="/tmp/tailscale_status_cache.json"

STARTUP="$ROOT/www2/sh/startup.sh"
BB="busybox"

LOCKDIR="/tmp/tailscale_ctl.lock"

TS_ENABLED=0
TS_ROUTES=""
TS_SSH=0
TS_EXIT_NODE=0
TS_ACCEPT_ROUTES=0
TS_ACCEPT_DNS=0
TS_HOSTNAME=""
TS_TAGS=""

[ -f "$CFG" ] && . "$CFG"

json_esc() {
    printf '%s' "$1" | $BB sed 's/\\/\\\\/g; s/"/\\"/g'
}

ensure_exec() {
    # Fresh copies/extracts of this folder (tar, scp, sdcard image, etc.)
    # don't reliably preserve the executable bit, which otherwise shows
    # up as a silent {"ok":false} on start with nothing written to /tmp.
    # Self-heal it here so every subcommand below can assume both
    # binaries are runnable. The -x check in launch_daemon_once() stays
    # in place as a fallback for cases chmod can't fix (e.g. a noexec
    # mount).
    [ -x "$DAEMON" ] || chmod +x "$DAEMON" 2>/dev/null
    [ -x "$CLI" ] || chmod +x "$CLI" 2>/dev/null
}

save_cfg() {
    mkdir -p "$CFG_DIR" 2>/dev/null
    {
        echo "TS_ENABLED=\"$TS_ENABLED\""
        echo "TS_ROUTES=\"$TS_ROUTES\""
        echo "TS_SSH=\"$TS_SSH\""
        echo "TS_EXIT_NODE=\"$TS_EXIT_NODE\""
        echo "TS_ACCEPT_ROUTES=\"$TS_ACCEPT_ROUTES\""
        echo "TS_ACCEPT_DNS=\"$TS_ACCEPT_DNS\""
        echo "TS_HOSTNAME=\"$TS_HOSTNAME\""
        echo "TS_TAGS=\"$TS_TAGS\""
    } > "$CFG"
    sync
}

lock() {
    _i=0
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        _i=$((_i + 1))
        if [ "$_i" -gt 30 ]; then
            echo '{"ok":false,"error":"timeout acquiring lock"}' >&2
            exit 1
        fi
        sleep 1
    done
    echo $$ > "$LOCKDIR/pid" 2>/dev/null
}

unlock() {
    rm -rf "$LOCKDIR" 2>/dev/null
}

trap unlock EXIT INT TERM

daemon_pid() {
    [ -f "$PIDF" ] || return 1
    cat "$PIDF" 2>/dev/null
}

up_pid() {
    [ -f "$UPPIDF" ] || return 1
    cat "$UPPIDF" 2>/dev/null
}

daemon_running() {
    _pid="$(daemon_pid)"
    [ -n "$_pid" ] || return 1
    [ -d "/proc/$_pid" ] || return 1
    $BB grep -q 'tailscaled-small' "/proc/$_pid/cmdline" 2>/dev/null || return 1
    [ -e "$SOCK" ] || return 1
    return 0
}

up_running() {
    $BB ps 2>/dev/null | $BB awk '
        /tailscale-small/ && / up( |$)/ { found=1 }
        END { exit !found }
    '
}

query_status_json() {
    $BB timeout 6 "$CLI" --socket="$SOCK" status --json 2>/dev/null
}

cleanup_stray_daemons() {
    _pid="$(daemon_pid)"
    [ -n "$_pid" ] && kill -9 "$_pid" 2>/dev/null

    _upid="$(up_pid)"
    [ -n "$_upid" ] && kill -9 "$_upid" 2>/dev/null

    for _p in $($BB ps 2>/dev/null | $BB awk '
        /tailscaled-small/ || (/tailscale-small/ && / up( |$)/) { print $1 }
    '); do
        kill -9 "$_p" 2>/dev/null
    done

    rm -f "$PIDF" "$UPPIDF" "$SOCK" "$LOGIN_URL_FILE" "$DAEMON_LOG" "$UP_LOG" "$STATUS_CACHE"
}

launch_daemon_once() {
    [ -x "$DAEMON" ] || return 1
    mkdir -p "$STATE_DIR" 2>/dev/null
    rm -f "$DAEMON_LOG" "$PIDF"

    "$DAEMON" \
        --statedir="$STATE_DIR" \
        --socket="$SOCK" \
        --tun=userspace-networking \
        --socks5-server=127.0.0.1:1055 \
        --outbound-http-proxy-listen=127.0.0.1:1055 \
        < /dev/null >"$DAEMON_LOG" 2>&1 &
    _pid=$!
    echo "$_pid" > "$PIDF"
    sleep 1

    kill -0 "$_pid" 2>/dev/null || return 1
    return 0
}

wait_for_daemon_ready() {
    _i=0
    while [ "$_i" -lt 15 ]; do
        if ! [ -e "$SOCK" ]; then
            sleep 1
            _i=$((_i + 1))
            continue
        fi

        _json="$(query_status_json)"
        if [ -n "$_json" ]; then
            return 0
        fi

        if $BB grep -qi 'segmentation fault\|panic\|fatal' "$DAEMON_LOG" 2>/dev/null; then
            return 1
        fi

        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

start_daemon() {
    daemon_running && return 0

    cleanup_stray_daemons

    _try=0
    while [ "$_try" -lt 2 ]; do
        launch_daemon_once || {
            _try=$((_try + 1))
            cleanup_stray_daemons
            continue
        }

        if wait_for_daemon_ready; then
            return 0
        fi

        echo "tailscaled crashed or hung during startup. Attempting recovery..." >&2
        cleanup_stray_daemons
        _try=$((_try + 1))
    done

    return 1
}

apply_settings() {
    daemon_running || return 1

    _upid="$(up_pid)"
    if [ -n "$_upid" ] && kill -0 "$_upid" 2>/dev/null; then
        kill -9 "$_upid" 2>/dev/null
    fi

    # If the backend is already fully Running, reconfigure in place with
    # `tailscale set` instead of a down/up cycle. `set` applies
    # advertise-routes/accept-routes/accept-dns/ssh/exit-node/tags changes
    # to the already-registered node without dropping and re-establishing
    # the session, so existing connections/routes aren't interrupted.
    # Explicit "=false"/"" forms are used for every toggle so unsetting a
    # previously-enabled option is applied, not just left alone. Hostname
    # is the one exception: it's only passed when non-blank, since an
    # empty --hostname value isn't a documented way to reset it and could
    # abort the whole `set` call -- see the field hint in tailscale.html.
    _json="$(query_status_json)"
    _backend="$(_parse_status_field "$_json" BackendState)"

    if [ "$_backend" = "Running" ]; then
        _set_args="--socket=$SOCK set"
        if [ -n "$TS_ROUTES" ]; then
            _set_args="$_set_args --advertise-routes=$TS_ROUTES"
        else
            _set_args="$_set_args --advertise-routes="
        fi
        if [ "$TS_SSH" = "1" ]; then
            _set_args="$_set_args --ssh"
        else
            _set_args="$_set_args --ssh=false"
        fi
        if [ "$TS_EXIT_NODE" = "1" ]; then
            _set_args="$_set_args --advertise-exit-node"
        else
            _set_args="$_set_args --advertise-exit-node=false"
        fi
        if [ "$TS_ACCEPT_ROUTES" = "1" ]; then
            _set_args="$_set_args --accept-routes"
        else
            _set_args="$_set_args --accept-routes=false"
        fi
        if [ "$TS_ACCEPT_DNS" = "1" ]; then
            _set_args="$_set_args --accept-dns=true"
        else
            _set_args="$_set_args --accept-dns=false"
        fi
        _set_args="$_set_args --advertise-tags=$TS_TAGS"
        [ -n "$TS_HOSTNAME" ] && _set_args="$_set_args --hostname=$TS_HOSTNAME"

        rm -f "$UP_LOG" "$UPPIDF"
        $BB timeout 15 "$CLI" $_set_args >"$UP_LOG" 2>&1
        return 0
    fi

    # Backend isn't fully up yet (e.g. NeedsLogin, Starting) -- `set`
    # can't be relied on to register these changes with the control
    # server in that state, so fall back to a full down/up cycle to
    # (re)establish everything cleanly. `--reset` already zeroes out
    # anything not listed below, so toggles only need to be added when on.
    $BB timeout 5 "$CLI" --socket="$SOCK" down >/dev/null 2>&1

    _args="--socket=$SOCK up --reset"
    [ -n "$TS_ROUTES" ] && _args="$_args --advertise-routes=$TS_ROUTES"
    [ "$TS_SSH" = "1" ] && _args="$_args --ssh"
    [ "$TS_EXIT_NODE" = "1" ] && _args="$_args --advertise-exit-node"
    [ "$TS_ACCEPT_ROUTES" = "1" ] && _args="$_args --accept-routes"
    if [ "$TS_ACCEPT_DNS" = "1" ]; then
        _args="$_args --accept-dns=true"
    else
        _args="$_args --accept-dns=false"
    fi
    [ -n "$TS_TAGS" ] && _args="$_args --advertise-tags=$TS_TAGS"
    [ -n "$TS_HOSTNAME" ] && _args="$_args --hostname=$TS_HOSTNAME"

    rm -f "$UP_LOG" "$UPPIDF"
    $BB timeout 30 "$CLI" $_args >"$UP_LOG" 2>&1 &
    _upid=$!
    echo "$_upid" > "$UPPIDF"

    _i=0
    while [ "$_i" -lt 10 ]; do
        $BB grep -qi 'Success\|already logged in\|logged in' "$UP_LOG" 2>/dev/null && break
        kill -0 "$_upid" 2>/dev/null || break
        sleep 1
        _i=$((_i + 1))
    done
    return 0
}

stop_daemon() {
    if daemon_running; then
        $BB timeout 3 "$CLI" --socket="$SOCK" down >/dev/null 2>&1
    fi
    cleanup_stray_daemons
}

ts_up() {
    daemon_running || start_daemon || return 1

    if up_running; then
        return 0
    fi

    _args="--socket=$SOCK up --reset"
    [ -n "$TS_ROUTES" ] && _args="$_args --advertise-routes=$TS_ROUTES"
    [ "$TS_SSH" = "1" ] && _args="$_args --ssh"
    [ "$TS_EXIT_NODE" = "1" ] && _args="$_args --advertise-exit-node"
    [ "$TS_ACCEPT_ROUTES" = "1" ] && _args="$_args --accept-routes"
    if [ "$TS_ACCEPT_DNS" = "1" ]; then
        _args="$_args --accept-dns=true"
    else
        _args="$_args --accept-dns=false"
    fi
    [ -n "$TS_TAGS" ] && _args="$_args --advertise-tags=$TS_TAGS"
    [ -n "$TS_HOSTNAME" ] && _args="$_args --hostname=$TS_HOSTNAME"

    rm -f "$LOGIN_URL_FILE" "$UP_LOG" "$UPPIDF"

    $BB timeout 30 "$CLI" $_args >"$UP_LOG" 2>&1 &
    _upid=$!
    echo "$_upid" > "$UPPIDF"

    _i=0
    while [ "$_i" -lt 20 ]; do
        _u=$($BB grep -o 'https://login\.tailscale\.com/[A-Za-z0-9/._-]*' "$UP_LOG" 2>/dev/null | $BB head -1)
        if [ -n "$_u" ]; then
            printf '%s\n' "$_u" > "$LOGIN_URL_FILE"
            break
        fi

        if $BB grep -qi 'Success\|already logged in\|logged in' "$UP_LOG" 2>/dev/null; then
            break
        fi

        if ! kill -0 "$_upid" 2>/dev/null; then
            break
        fi

        sleep 1
        _i=$((_i + 1))
    done

    return 0
}

_has_anchors() {
    $BB grep -q 'BEGIN_TAILSCALE' "$STARTUP" 2>/dev/null
}

_set_marker() {
    [ -f "$STARTUP" ] || return 0

    $BB awk -v line="$1" '
        BEGIN { inblk = 0 }
        /BEGIN_TAILSCALE/ {
            print
            if (line != "") print line
            inblk = 1
            next
        }
        /END_TAILSCALE/ {
            inblk = 0
            print
            next
        }
        inblk { next }
        { print }
    ' "$STARTUP" > "$STARTUP.tmp" 2>/dev/null && $BB mv "$STARTUP.tmp" "$STARTUP"
    sync
}

add_boot_marker() {
    [ -f "$STARTUP" ] || return 0
    if _has_anchors; then
        _set_marker '( /lmepisowifi/tailscale/tailscale_ctl.sh boot ) &'
    else
        printf '\n# --- BEGIN_TAILSCALE ---\n( /lmepisowifi/tailscale/tailscale_ctl.sh boot ) &\n# --- END_TAILSCALE ---\n' >> "$STARTUP"
        sync
    fi
}

remove_boot_marker() {
    [ -f "$STARTUP" ] || return 0
    _has_anchors || return 0
    _set_marker ''
}

_parse_status_field() {
    # $1 = json blob, $2 = field name
    # tailscaled pretty-prints --json output, so a key and its value (or,
    # for arrays like TailscaleIPs, the opening bracket and first element)
    # can land on separate lines. Flatten to one line first so the sed
    # pattern below -- which only matches within a single line -- works
    # regardless of how the JSON happens to be formatted.
    printf '%s' "$1" | $BB tr -d '\n' | $BB sed -n "s/.*\"$2\":[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | $BB head -1
}

_parse_first_ip() {
    printf '%s' "$1" | $BB tr -d '\n' | $BB sed -n 's/.*"TailscaleIPs":[[:space:]]*\[[[:space:]]*"\([^"]*\)".*/\1/p' | $BB head -1
}

_parse_second_ip() {
    # Second element of the same TailscaleIPs array -- the IPv6 (ULA) address
    # that sits alongside the IPv4 one _parse_first_ip already grabs.
    printf '%s' "$1" | $BB tr -d '\n' | $BB sed -n 's/.*"TailscaleIPs":[[:space:]]*\[[[:space:]]*"[^"]*"[[:space:]]*,[[:space:]]*"\([^"]*\)".*/\1/p' | $BB head -1
}

_parse_health_array() {
    # Health is a flat array of plain strings that tailscaled has already
    # JSON-escaped, so the captured contents can be spliced straight into
    # our own output array without re-escaping (re-escaping would double
    # up any backslashes). Empty/absent Health (null, [], or missing)
    # simply fails to match and yields "", which the caller renders as [].
    printf '%s' "$1" | $BB tr -d '\n' | $BB sed -n 's/.*"Health":[[:space:]]*\[\([^]]*\)\].*/\1/p' | $BB head -1
}

emit_status() {
    _run="false"
    _en="false"
    _ssh="false"
    _exit_node="false"
    _accept_routes="false"
    _accept_dns="false"
    _ip=""
    _ipv6=""
    _backend=""
    _authurl=""
    _login=""
    _email=""
    _username=""
    _profile_pic=""
    _device_hostname=""
    _dns_name=""
    _relay=""
    _key_expiry=""
    _version=""
    _health=""

    [ "$TS_ENABLED" = "1" ] && _en="true"
    [ "$TS_SSH" = "1" ] && _ssh="true"
    [ "$TS_EXIT_NODE" = "1" ] && _exit_node="true"
    [ "$TS_ACCEPT_ROUTES" = "1" ] && _accept_routes="true"
    [ "$TS_ACCEPT_DNS" = "1" ] && _accept_dns="true"

    if daemon_running; then
        _json="$(query_status_json)"
        if [ -z "$_json" ]; then
            sleep 1
            _json="$(query_status_json)"
        fi

        _blob=""
        if [ -n "$_json" ]; then
            _blob="$_json"
            printf '%s' "$_json" > "$STATUS_CACHE" 2>/dev/null
        elif [ -f "$STATUS_CACHE" ]; then
            # RPC stalled both tries -- reuse the last known-good snapshot
            # so every field stays in sync instead of going blank.
            _blob="$(cat "$STATUS_CACHE" 2>/dev/null)"
        fi

        if [ -n "$_blob" ]; then
            _backend="$(_parse_status_field "$_blob" BackendState)"
            _authurl="$(_parse_status_field "$_blob" AuthURL | $BB sed 's#\\/#/#g')"
            _email="$(_parse_status_field "$_blob" LoginName)"
            _username="$(_parse_status_field "$_blob" DisplayName)"
            _profile_pic="$(_parse_status_field "$_blob" ProfilePicURL | $BB sed 's#\\/#/#g')"
            _version="$(_parse_status_field "$_blob" Version)"
            _health="$(_parse_health_array "$_blob")"
            # HostName, DNSName, Relay, TailscaleIPs all appear inside
            # every Peer entry too. The sed patterns use greedy .* so they
            # land on the LAST occurrence -- which is the last peer, not
            # Self. Strip the Peer section (and everything after it) first
            # so the greedy match always resolves to Self's own values.
            # LoginName/DisplayName/ProfilePicURL/Version/Health are parsed
            # from the full blob above because LoginName, DisplayName, and
            # ProfilePicURL all live in the User section (after Peer) and
            # Version/Health are unambiguous at the top level.
            _self_blob="$(printf '%s' "$_blob" | $BB tr -d '\n' | $BB sed 's/"Peer":[[:space:]]*{.*//')"
            _ip="$(_parse_first_ip "$_self_blob")"
            _ipv6="$(_parse_second_ip "$_self_blob")"
            _device_hostname="$(_parse_status_field "$_self_blob" HostName)"
            _dns_name="$(_parse_status_field "$_self_blob" DNSName | $BB sed 's/\.$//')"
            _relay="$(_parse_status_field "$_self_blob" Relay)"
            _key_expiry="$(_parse_status_field "$_self_blob" KeyExpiry)"
        fi

        # Derive "running" from the actual backend state, not just from
        # the process being alive -- otherwise the badge can say "Running"
        # while the backend text next to it says "Stopped" (e.g. mid
        # down/up cycle, or want=false persisted but process not yet
        # reaped).
        case "$_backend" in
            Running|Starting) _run="true" ;;
            *) _run="false" ;;
        esac
    fi

    _login="$_authurl"
    [ -z "$_login" ] && _login=$(cat "$LOGIN_URL_FILE" 2>/dev/null)

    if [ "$_backend" = "Running" ]; then
        _login=""
    fi

    printf '{"ok":true,"running":%s,"enabled":%s,"ssh":%s,"exit_node":%s,"accept_routes":%s,"accept_dns":%s,"routes":"%s","hostname":"%s","tags":"%s","ip":"%s","ipv6":"%s","backend":"%s","login_url":"%s","email":"%s","username":"%s","profile_pic_url":"%s","device_hostname":"%s","dns_name":"%s","relay":"%s","key_expiry":"%s","version":"%s","health":[%s]}\n' \
        "$_run" "$_en" "$_ssh" "$_exit_node" "$_accept_routes" "$_accept_dns" \
        "$(json_esc "$TS_ROUTES")" "$(json_esc "$TS_HOSTNAME")" "$(json_esc "$TS_TAGS")" \
        "$(json_esc "$_ip")" "$(json_esc "$_ipv6")" "$(json_esc "$_backend")" "$(json_esc "$_login")" \
        "$(json_esc "$_email")" "$(json_esc "$_username")" "$(json_esc "$_profile_pic")" "$(json_esc "$_device_hostname")" "$(json_esc "$_dns_name")" \
        "$(json_esc "$_relay")" "$(json_esc "$_key_expiry")" "$(json_esc "$_version")" "$_health"
}

do_start() {
    TS_ENABLED=1
    save_cfg
    add_boot_marker
    start_daemon || return 1
    ts_up || return 1
    return 0
}

do_stop() {
    TS_ENABLED=0
    save_cfg
    remove_boot_marker
    stop_daemon
    return 0
}

# Signs the node fully out of the tailnet -- distinct from `stop`, which
# just disconnects but keeps the same node identity/key so it silently
# reconnects later. `logout` invalidates the node key with the control
# server, so the device drops off the tailnet's node list and any future
# `up` needs a fresh interactive login. This is an RPC over the daemon's
# socket, so it requires the daemon to already be running; TS_ENABLED is
# left untouched since being logged in/out is orthogonal to whether the
# service is meant to run at boot.
do_logout() {
    daemon_running || return 1
    $BB timeout 10 "$CLI" --socket="$SOCK" logout >/dev/null 2>&1 || return 1

    # The old Self/User identity (email, username, avatar, hostname...)
    # cached below is now stale. Drop it, then immediately call ts_up so
    # a fresh AuthURL is generated right away instead of leaving the
    # admin panel with a blank "not logged in" state until the next
    # separate "up" call.
    rm -f "$LOGIN_URL_FILE" "$UP_LOG" "$UPPIDF" "$STATUS_CACHE"
    ts_up
    return 0
}

do_boot() {
    [ "$TS_ENABLED" = "1" ] || return 0
    [ -x "$DAEMON" ] || return 0
    start_daemon || return 1
    ts_up || return 1
    return 0
}

do_set_config() {
    TS_ROUTES="$2"
    [ "$3" = "1" ] && TS_SSH=1 || TS_SSH=0
    [ "$4" = "1" ] && TS_EXIT_NODE=1 || TS_EXIT_NODE=0
    [ "$5" = "1" ] && TS_ACCEPT_ROUTES=1 || TS_ACCEPT_ROUTES=0
    [ "$6" = "1" ] && TS_ACCEPT_DNS=1 || TS_ACCEPT_DNS=0
    TS_HOSTNAME="$7"
    TS_TAGS="$8"
    save_cfg
    daemon_running && apply_settings
    return 0
}

do_set_enabled() {
    if [ "$2" = "1" ]; then
        TS_ENABLED=1
        save_cfg
        add_boot_marker
        start_daemon || return 1
        ts_up || return 1
    else
        TS_ENABLED=0
        save_cfg
        remove_boot_marker
        stop_daemon
    fi
    return 0
}

do_postinstall() {
    mkdir -p "$CFG_DIR" "$STATE_DIR" 2>/dev/null
    [ -f "$CFG" ] || save_cfg
    chmod +x "$DAEMON" "$CLI" 2>/dev/null
    if [ "$TS_ENABLED" = "1" ]; then
        add_boot_marker
        start_daemon || return 1
        ts_up || return 1
    fi
    return 0
}

do_preuninstall() {
    remove_boot_marker
    stop_daemon
    return 0
}

ensure_exec

case "$1" in
    start)
        lock
        do_start && echo '{"ok":true}' || echo '{"ok":false}'
        ;;
    stop)
        lock
        do_stop && echo '{"ok":true}' || echo '{"ok":false}'
        ;;
    boot)
        lock
        do_boot >/dev/null 2>&1
        ;;
    up)
        lock
        ts_up && echo '{"ok":true}' || echo '{"ok":false}'
        ;;
    logout)
        lock
        do_logout && echo '{"ok":true}' || echo '{"ok":false}'
        ;;
    set-config)
        lock
        do_set_config "$@" && echo '{"ok":true}' || echo '{"ok":false}'
        ;;
    set-enabled)
        lock
        do_set_enabled "$@" && echo '{"ok":true}' || echo '{"ok":false}'
        ;;
    status)
        emit_status
        ;;
    postinstall)
        lock
        do_postinstall && echo '{"ok":true}' || echo '{"ok":false}'
        ;;
    preuninstall)
        lock
        do_preuninstall && echo '{"ok":true}' || echo '{"ok":false}'
        ;;
    *)
        echo "usage: $0 {start|stop|boot|up|logout|status|set-config <routes> <ssh01> <exit01> <accept_routes01> <accept_dns01> <hostname> <tags>|set-enabled <01>|postinstall|preuninstall}" >&2
        exit 2
        ;;
esac
