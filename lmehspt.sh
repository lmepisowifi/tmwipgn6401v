#!/bin/sh

# ============================================================
# lmehspt.sh — Piso Wifi Hotspot Controller
# RTL9607C ONT | BusyBox | iptables captive portal
# ============================================================

BB="busybox"
HOTSPOT_INTERFACES="eth0.2.0 wlan0 wlan1"
HOTSPOT_BR="br1"
PORTAL_IP="10.0.0.1"
PORTAL_PORT="80"
DHCP_START="5"      # dynamic DHCP pool first host octet (within PORTAL_IP's /24)
DHCP_END="254"      # dynamic DHCP pool last host octet
DHCP_DNS="1.1.1.1"  # space-separated DNS servers pushed to clients (udhcpd "option dns")
WWW2_PORT="8080"   # busybox httpd -h /lmepisowifi/www2 -p 8080 (admin UI). /admin on the portal redirects here.
SESSION_FILE="/tmp/active_sessions.txt"
USERS_FILE="/lmepisowifi/hotspot_data/users.txt"
# Two alternating backup generations (refreshed every 5 min, see
# backup_users_file) rather than one — so a crash mid-write to one
# generation still leaves the other, already-durable, copy intact.
USERS_BACKUP_A="${USERS_FILE}_backup_a"
USERS_BACKUP_B="${USERS_FILE}_backup_b"
USERS_BACKUP_GEN="${USERS_FILE}_backup_gen"   # tiny marker: which of A/B was written last
INCOME_FILE="/lmepisowifi/hotspot_data/income.env"
INCOME_BACKUP_A="${INCOME_FILE}_backup_a"
INCOME_BACKUP_B="${INCOME_FILE}_backup_b"
INCOME_BACKUP_GEN="${INCOME_FILE}_backup_gen"
WHITELIST_FILE="/lmepisowifi/hotspot_data/whitelist.txt"
# Additional NodeMCU coin acceptors beyond the primary (#1, configured via
# NODEMCU_IP/MAC/PORT/COIN_PSK above). One line per unit:
#   ID|TITLE|IP|MAC|PORT|PSK|ENABLED
# Absent or empty on any existing install — the box simply behaves as a
# single-NodeMCU system, unchanged, until an admin adds a unit via the UI.
NODEMCU_EXTRA_FILE="/lmepisowifi/hotspot_data/nodemcus_extra.txt"

WAN_INT_DEFAULT="br0"
WAN_INT="br0"
BR0_GATEWAY="192.168.18.1"   # FALLBACK only. The live gateway is auto-detected from br0's
                             # current IP (see resolve_br0_gateway); this value is used only
                             # if br0 has no IPv4 address yet.
GLOBAL_RATE="20mbit"
INACTIVITY_TIMEOUT="300"
AUTO_PAUSE_ENABLED="1"
BOOT_MARKER="/tmp/hotspot_boot.mark"
ACTIVITY_FILE="/tmp/hotspot_activity.txt"
PER_USER_RATE="5mbit"
PER_USER_BURST="100k"
UNAUTH_RATE="1000kbit"
IP_MAP_FILE="/tmp/hotspot_ip_map.txt"

HOTSPOT_ENABLED="1"
ANTI_TETHER="1"
LAN_ISOLATE="1"
MAC_RANDOMIZATION_FIX="1"
# Any address in these ranges is private (RFC1918) and, by definition, can
# only ever be a LAN device — ours, or someone else's upstream gateway in a
# chained/double-NAT setup (e.g. a repurposed-WAN uplink whose own gateway
# is itself behind another private hop). Blocking hotspot clients from all
# three ranges (rather than just the one subnet directly attached to br0 or
# to the repurposed WAN) closes off every hop in a private chain at once,
# no matter how many layers deep, while leaving real public-internet
# destinations untouched.
LAN_ISOLATE_PRIVATE_NETS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
COIN_ENABLED="1"
NODEMCU_IP="10.0.0.2"
NODEMCU_MAC="ecfabcc8d65a"
NODEMCU_PORT="8080"
COIN_PSK="2Au6410y1O15YV9610wHmr52"
NODEMCU_1_TITLE="Coin Slot"
NODEMCU_1_ENABLED="1"
COIN_TIMEOUT="30"
COIN_RATES="1:15 5:90 10:210 15:360 20:720 25:1080 30:2160 35:2880 40:3600 45:4320 50:5040 55:5760"
COIN_STRIKE_THRESHOLD="3"
COIN_COOLDOWN="60"
# Seconds the portal keeps a mid-insert coin session alive while the NodeMCU is
# unreachable (reporting "reconnecting", coins preserved, countdown frozen)
# before giving up. Keep equal to the firmware's MAX_PAUSE_MS (300s).
COIN_RECONNECT_GRACE="300"

# NTP servers used by busybox ntpd to discipline the system clock over the WAN.
NTP_SERVERS="pool.ntp.org time.google.com time.cloudflare.com"
NTP_EVENT="/lmepisowifi/hotspot/ntp_event.sh"

# ── Defaults + persistent globals ─────────────────────────────────────────────
# Layering (later overrides earlier):
#   1. built-in defaults hardcoded above (ultimate fallback),
#   2. /lmepisowifi/defaults.env  — canonical defaults, SHIPPED/REPLACED by OTA,
#   3. /lmepisowifi/globals.env   — user settings (PRESERVED across OTA), written
#                                   by www2/cgi-bin/hotspot.cgi when settings are
#                                   saved in the admin UI.
#
# seed_globals() copies any key present in defaults.env but MISSING from
# globals.env into globals.env, so when an OTA introduces a new tunable, old
# devices automatically gain it (with its default) in their preserved
# globals.env and it shows up pre-filled in the admin UI. It never overwrites a
# key the user already set, and is idempotent (safe to run on every boot).
#
# Exception — primary NodeMCU identity (NODEMCU_IP/NODEMCU_MAC/COIN_PSK): on a
# box that already has a globals.env (i.e. this isn't its very first-ever
# boot), these three being ABSENT means "no primary configured" just as much
# as hotspot.cgi's nodemcu_del explicitly blanking them to "" does (see
# NID=1 handling in hotspot.cgi) — it's simply a box that never had a primary
# set up (e.g. a hotspot-only/Orange Pi build using only extra units) rather
# than one that had it deleted. Auto-seeding defaults.env's placeholder IP/MAC/
# PSK into globals.env in that case silently manufactures a primary the admin
# never configured, and it comes back on every OTA even after being deleted
# via the old (pre-blanking) delete behavior. So these three are only ever
# seeded on a device's true first boot, when globals.env doesn't exist yet and
# the defaults really do represent factory-shipped values.
seed_globals() {
    _def="/lmepisowifi/defaults.env"
    _glob="/lmepisowifi/globals.env"
    [ -f "$_def" ] || return 0
    if [ -f "$_glob" ]; then
        _glob_is_new=0
    else
        _glob_is_new=1
        : > "$_glob"   # create empty file if it doesn't exist yet
    fi
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            ''|\#*) continue ;;               # skip blank lines and comments
        esac
        _key=${_line%%=*}
        case "$_key" in
            ''|*[!A-Za-z0-9_]*) continue ;;   # skip lines that aren't KEY=value
        esac
        if [ "$_glob_is_new" != "1" ]; then
            case "$_key" in
                NODEMCU_IP|NODEMCU_MAC|COIN_PSK) continue ;;
            esac
        fi
        # append only if globals.env has no assignment for this key yet
        grep -q "^${_key}=" "$_glob" 2>/dev/null || printf '%s\n' "$_line" >> "$_glob"
    done < "$_def"
}

[ -f /lmepisowifi/defaults.env ] && . /lmepisowifi/defaults.env
seed_globals
[ -f /lmepisowifi/globals.env ] && . /lmepisowifi/globals.env
# ─────────────────────────────────────────────────────────────────────────────

# Customizable Telegram/Discord message templates
[ -f /lmepisowifi/hotspot/notify_templates.sh ] && . /lmepisowifi/hotspot/notify_templates.sh

# --lib mode: source this file to get all functions without running the main
# boot sequence. Used by hotspot.cgi's hotspot_stop to call cleanup_old_hotspot
# with the exact same logic the script itself trusts.
[ "$1" = "--lib" ] && LMEHSPT_LIB_ONLY=1

# ============================================================
# UTILITY
# ============================================================
_unlock() { rm -f /tmp/hotspot_session.lock/pid 2>/dev/null; rmdir /tmp/hotspot_session.lock 2>/dev/null; }
_lock() {
    local i=0
    while ! mkdir /tmp/hotspot_session.lock 2>/dev/null; do
        # Only steal the lock once its holder is provably dead (PID recorded
        # below no longer exists) - never just because THIS waiter got tired
        # of polling. login.sh/logout.sh/status.sh/coin_result.sh all poll
        # this same lock roughly once a second from every connected client,
        # so a busy box can legitimately queue past a few seconds. The old
        # flat "5s and I grab it" rule force-removed a lock a still-running
        # holder was mid-write on, letting two writers stomp the same *.tmp
        # file at once and blackhole USERS_FILE for every user, not just
        # whoever triggered the second writer.
        if [ "$((i % 10))" -eq 0 ] && [ "$i" -gt 0 ]; then
            if [ "$i" -ge 300 ]; then
                # Absolute last-resort failsafe (~30s) in case PID tracking
                # itself is ever unreliable - don't wedge forever.
                $BB rm -f /tmp/hotspot_session.lock/pid 2>/dev/null
                rmdir /tmp/hotspot_session.lock 2>/dev/null
            else
                _HPID=$($BB cat /tmp/hotspot_session.lock/pid 2>/dev/null)
                if [ -z "$_HPID" ] || ! kill -0 "$_HPID" 2>/dev/null; then
                    $BB rm -f /tmp/hotspot_session.lock/pid 2>/dev/null
                    rmdir /tmp/hotspot_session.lock 2>/dev/null
                fi
            fi
        fi
        $BB sleep 0.1 2>/dev/null || sleep 0.1 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    $BB echo $$ > /tmp/hotspot_session.lock/pid 2>/dev/null
}

# Rewrites USERS_FILE with every line except the one starting "$1 ", but
# refuses to commit if grep couldn't actually read USERS_FILE in the first
# place. `grep -v` exit status: 0 = some lines kept, 1 = every line was a
# genuine match (also what a truly-empty file returns - normal when the
# last user is being removed), 2+ = read/access error. Without this check,
# a single transient flash read glitch produces an empty tmp file that then
# gets moved over USERS_FILE unconditionally, wiping every user's balance
# in one request - no concurrency needed at all. Call this INSIDE _lock.

# Stages "${USERS_FILE}.tmp" with every line except the one starting "$1 ",
# WITHOUT committing it - callers that need to append a replacement line
# (pause_session, the expiry watchdog's replace-with-nothing case, etc.) can
# do so into the .tmp file before calling _users_file_commit. Refuses
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
    $BB grep -v "^${mac} " "$USERS_FILE" > "${USERS_FILE}.tmp" 2>/dev/null || rc=$?
    if [ "$existed" -eq 1 ] && [ "$rc" -gt 1 ]; then
        rm -f "${USERS_FILE}.tmp" 2>/dev/null
        logger -t lmehspt "users.txt: refused overwrite after read error (rc=$rc) - kept existing file" 2>/dev/null
        return 1
    fi
    return 0
}
# Commits a staged "${USERS_FILE}.tmp" (see _users_file_stage_excl above) -
# whatever the caller appended to it, exclusion and replacement together,
# lands in USERS_FILE via a single atomic mv. This is what makes the
# empty-expected marker below trustworthy: it's evaluated exactly once,
# against the file's true final content for this operation, never against
# a transient mid-operation state that a separate later append could still
# change out from under it.
_users_file_commit() {
    $BB mv "${USERS_FILE}.tmp" "$USERS_FILE"
    # Rename is atomic/crash-consistent on ubifs, but that only guarantees
    # you never see a half-written file - it says nothing about whether
    # this specific write has actually reached the NAND yet vs. still
    # sitting dirty in the page cache. Force it out now so a power-cut
    # moments after an inactivity pause or expiry can't silently roll
    # this update back.
    sync
    # Record whether this guarded commit legitimately left USERS_FILE
    # empty (e.g. the sole remaining user just expired/logged out/got
    # removed) vs non-empty. The runtime self-heal below (search
    # restore_users_file_from_backup) uses this to tell "correctly zero
    # active users right now" apart from "file went empty some other
    # way" - without it, the self-heal can't distinguish the two and
    # resurrects an already-expired user from the last backup snapshot
    # on its very next ~1s tick. /tmp is tmpfs, so this costs no flash
    # writes and is naturally cleared on reboot (when we DO want the
    # boot-time restore to run its normal crash-recovery logic).
    if [ -s "$USERS_FILE" ]; then rm -f /tmp/hotspot_users_empty_expected 2>/dev/null; else : > /tmp/hotspot_users_empty_expected 2>/dev/null; fi
}
# Pure-removal convenience wrapper for callers with no replacement line to
# append (e.g. the expiry watchdog below, which just drops the mac
# entirely). Stage+commit in one call, still fails closed on a read error.
_users_file_replace_excl() {
    if _users_file_stage_excl "$1"; then
        _users_file_commit
        return 0
    fi
    return 1
}
_fmt_secs() {
    # 1. If s is empty, default it to 0
    local s="${1:-0}"
    
    # 2. Strip any negative sign if present
    s="${s#-}"
    
    # 3. If s contains any non-digit characters, force it to 0
    case "$s" in
        ""|*[!0-9]*) s=0 ;;
    esac

    # 4. Now perform the math safely
    local d=$(( s / 86400 ))
    local h=$(( (s % 86400) / 3600 ))
    local m=$(( (s % 3600) / 60 ))

    if [ "$d" -gt 0 ]; then 
        printf '%dd %dh %dm' "$d" "$h" "$m"
    elif [ "$h" -gt 0 ]; then 
        printf '%dh %dm' "$h" "$m"
    else 
        printf '%dm' "$m"
    fi
}
sync_to_persistent_db() {
    local USERS_TMP="${USERS_FILE}.tmp"
    local NOW
    NOW=$($BB awk '{print int($1)}' /proc/uptime)

    # Guard: this function merges SESSION_FILE + USERS_FILE into USERS_TMP via
    # plain `while read` loops below and then, unlike every other USERS_FILE
    # writer in this codebase, used to `mv` the result over USERS_FILE
    # unconditionally. A `while read < file` loop doesn't surface a mid-read
    # I/O error the way `grep`'s exit status does elsewhere - a transient
    # flash read glitch on USERS_FILE just looks like early EOF, silently
    # truncating the merge, and this function runs on an unattended 5-minute
    # timer plus once at every boot. Probe both sources with `cat` first,
    # whose exit status DOES reflect a real read failure, and skip the sync
    # entirely (leaving the existing USERS_FILE untouched) if either a
    # non-empty SESSION_FILE or a non-empty USERS_FILE can't actually be
    # read back right now. Call this INSIDE _lock, same as the other
    # USERS_FILE writers.
    if [ -s "$SESSION_FILE" ] && ! $BB cat "$SESSION_FILE" >/dev/null 2>&1; then
        logger -t lmehspt "sync_to_persistent_db: active_sessions.txt unreadable (I/O error) - skipped sync, kept existing users.txt" 2>/dev/null
        return 1
    fi
    if [ -s "$USERS_FILE" ] && ! $BB cat "$USERS_FILE" >/dev/null 2>&1; then
        logger -t lmehspt "sync_to_persistent_db: users.txt unreadable (I/O error) - skipped sync, kept existing file" 2>/dev/null
        return 1
    fi

    > "$USERS_TMP"
    if [ -f "$SESSION_FILE" ]; then
        while read -r mac expiry total; do
            [ -n "$mac" ] && [ -n "$expiry" ] || continue
            local remaining=$(( expiry - NOW ))
            [ "$remaining" -le 0 ] && continue
            [ -z "$total" ] && total=$remaining
            echo "$mac active $remaining $total $(_fmt_secs "$remaining")" >> "$USERS_TMP"
        done < "$SESSION_FILE"
    fi
    if [ -f "$USERS_FILE" ]; then
        while read -r mac status remaining total fmt; do
            [ -n "$mac" ] && [ -n "$status" ] || continue
            if [ -f "$SESSION_FILE" ] && $BB grep -q "^$mac " "$SESSION_FILE" 2>/dev/null; then continue; fi
            [ "$status" = "active" ] && status="paused"
            [ "$remaining" -le 0 ] && continue
            [ -z "$total" ] && total=$remaining
            echo "$mac $status $remaining $total $(_fmt_secs "$remaining")" >> "$USERS_TMP"
        done < "$USERS_FILE"
    fi
    $BB mv "$USERS_TMP" "$USERS_FILE"
    if [ -s "$USERS_FILE" ]; then rm -f /tmp/hotspot_users_empty_expected 2>/dev/null; else : > /tmp/hotspot_users_empty_expected 2>/dev/null; fi
}

# ── users.txt / income.env crash-safety: 2-generation backup + validated restore ──
# Refreshed every 5 min (see LAST_SNAPSHOT in the main loop), right after
# sync_to_persistent_db, and also once right after boot. Alternates between
# the "_backup_a"/"_backup_b" generations (tracked by a tiny "_backup_gen"
# marker) so a crash mid-write to one generation still leaves the other,
# already-durable, copy intact. Skipped when the source is empty so a
# genuinely empty hotspot (or a bad read) never overwrites a good backup
# with nothing. Callers are expected to run `sync` right after this so the
# new generation is actually durable, not just renamed in the page cache.
_backup_rotate() {
    # $1=source $2=backup_a $3=backup_b $4=gen_marker
    local src="$1" a="$2" b="$3" genf="$4" gen target
    [ -s "$src" ] || return 0
    gen=$($BB cat "$genf" 2>/dev/null)
    if [ "$gen" = "a" ]; then target="$b"; gen="b"; else target="$a"; gen="a"; fi
    $BB cp "$src" "${target}.tmp" 2>/dev/null \
        && $BB mv "${target}.tmp" "$target" 2>/dev/null \
        && printf '%s' "$gen" > "$genf" 2>/dev/null
}
backup_users_file()  { _backup_rotate "$USERS_FILE"  "$USERS_BACKUP_A"  "$USERS_BACKUP_B"  "$USERS_BACKUP_GEN"; }
backup_income_file() { _backup_rotate "$INCOME_FILE" "$INCOME_BACKUP_A" "$INCOME_BACKUP_B" "$INCOME_BACKUP_GEN"; }

# Validates and restores one users.txt backup candidate. Only lines that
# look like genuine entries (real MAC, active/paused status, numeric
# remaining/total with remaining > 0) are kept — a half-written or
# otherwise mangled backup can't graft garbage sessions onto a fresh boot.
_restore_users_candidate() {
    local candidate="$1" tmp valid=0 mac status remaining total fmt
    [ -s "$candidate" ] || return 1
    tmp="${USERS_FILE}.restore_tmp"
    > "$tmp"
    while read -r mac status remaining total fmt; do
        [ -n "$mac" ] || continue
        printf '%s' "$mac" | $BB grep -qE '^[0-9a-f:]{17}$' || continue
        case "$status" in active|paused) ;; *) continue ;; esac
        printf '%s' "$remaining" | $BB grep -qE '^[0-9]+$' || continue
        printf '%s' "$total"     | $BB grep -qE '^[0-9]+$' || continue
        [ "$remaining" -gt 0 ] || continue
        echo "$mac $status $remaining $total $fmt" >> "$tmp"
        valid=1
    done < "$candidate"
    if [ "$valid" = "1" ]; then
        $BB mv "$tmp" "$USERS_FILE" 2>/dev/null && return 0
    fi
    $BB rm -f "$tmp" 2>/dev/null
    return 1
}

# Validates and restores one income.env backup candidate — must contain a
# genuine INCOME_TOTAL assignment to be trusted.
_restore_income_candidate() {
    local candidate="$1"
    [ -s "$candidate" ] || return 1
    $BB grep -qE '^INCOME_TOTAL=' "$candidate" 2>/dev/null || return 1
    $BB cp "$candidate" "$INCOME_FILE" 2>/dev/null
}

# Boot-time safety net: if users.txt/income.env is missing or 0 bytes but a
# backup generation has valid data, restore it before anything else reads
# the file, so paused/active sessions and income totals resume normally
# instead of every user/every counter starting over at zero. Tries the
# most-recently-written generation first, falls back to the other one if
# that one is missing or fails validation.
_restore_from_backup() {
    # $1=label $2=live_file $3=backup_a $4=backup_b $5=gen_marker $6=validate_fn
    local label="$1" live="$2" a="$3" b="$4" genf="$5" validate="$6" gen first second
    [ -s "$live" ] && return 0
    gen=$($BB cat "$genf" 2>/dev/null)
    if [ "$gen" = "a" ]; then first="$a"; second="$b"; else first="$b"; second="$a"; fi
    if "$validate" "$first"; then
        logger -t lmehspt "$label restored from backup ($first) after empty/missing file at boot" 2>/dev/null
        return 0
    fi
    if "$validate" "$second"; then
        logger -t lmehspt "$label restored from backup ($second) after empty/missing file at boot" 2>/dev/null
        return 0
    fi
    logger -t lmehspt "$label empty/missing at boot and no valid backup found" 2>/dev/null
    return 1
}
restore_users_file_from_backup()  {
    # If the last guarded write to USERS_FILE deliberately left it empty
    # (see the marker comment in _users_file_replace_excl above) and it's
    # still empty now, that's the expected "no active/paused users right
    # now" state - e.g. the sole remaining user just ran out of time. Don't
    # restore over it: backup_users_file() only refreshes the backup every
    # 5 minutes (skipping entirely while the source is empty, by design -
    # see _backup_rotate), so for up to that whole window the backup still
    # holds the user's last non-empty snapshot (say "3 minutes remaining").
    # Without this check, this function - called every ~1s - would restore
    # that stale snapshot right back, making an already-expired user's time
    # appear to come back.
    [ -e /tmp/hotspot_users_empty_expected ] && [ ! -s "$USERS_FILE" ] && return 0
    _restore_from_backup "users.txt"   "$USERS_FILE"  "$USERS_BACKUP_A"  "$USERS_BACKUP_B"  "$USERS_BACKUP_GEN"  _restore_users_candidate
}
restore_income_file_from_backup() { _restore_from_backup "income.env"  "$INCOME_FILE" "$INCOME_BACKUP_A" "$INCOME_BACKUP_B" "$INCOME_BACKUP_GEN" _restore_income_candidate; }

# ============================================================

# Normalise a tc rate string to always use bit-based units understood by tc.
# Handles: bare m/k/g → mbit/kbit/gbit; mbps/kbps/gbps → *bit (*8);
# already-correct forms (mbit, kbit, gbit, bit) pass through unchanged.
_norm_rate() {
    local r="$1"
    case "$r" in
        # Already correct
        *bit|*bit) echo "$r"; return ;;
        # Bytes-per-second variants → convert to bits
        *[Mm][Bb][Pp][Ss]) r="${r%????}"; r="$(( r * 8 ))mbit" ;;
        *[Kk][Bb][Pp][Ss]) r="${r%????}"; r="$(( r * 8 ))kbit" ;;
        *[Gg][Bb][Pp][Ss]) r="${r%????}"; r="$(( r * 8 ))gbit" ;;
        # Bare suffix shortcuts
        *[Mm]) r="${r%?}mbit" ;;
        *[Kk]) r="${r%?}kbit" ;;
        *[Gg]) r="${r%?}gbit" ;;
    esac
    echo "$r"
}

format_mac() {
    printf '%s' "$1" | tr -d ':' | tr 'A-F' 'a-f' | \
        sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/'
}
iface_in_bridge() {
    local link
    link=$(readlink -f "/sys/class/net/$1/brport/bridge" 2>/dev/null)
    [ -n "$link" ] && [ "$(basename "$link")" = "$HOTSPOT_BR" ]
}
is_whitelisted() {
    [ -f "$WHITELIST_FILE" ] || return 1
    local raw
    raw=$(printf '%s' "$1" | tr -d ':' | tr 'A-F' 'a-f')
    $BB grep -qi "^${raw}$" "$WHITELIST_FILE"
}

# DNS watchdog: monitors and recovers name resolution when loopback resolver fails
check_and_fix_dns() {
    # Check if DNS resolution is broken
    if ! $BB nslookup google.com >/dev/null 2>&1 && ! $BB nslookup pool.ntp.org >/dev/null 2>&1; then
        # DNS is not resolving. Check if we already modified resolv.conf to prevent infinite writes
        if ! $BB grep -q "1.1.1.1" /etc/resolv.conf 2>/dev/null; then
            # Backup original resolv.conf if not already backed up
            [ -f /etc/resolv.conf.bak ] || cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null
            
            # Rewrite resolv.conf to use reliable public DNS servers first, keeping loopback as fallback
            cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 127.0.0.1
nameserver ::1
EOF
        fi
    fi
}



wait_for_wlan_ready() {
    local max_wait=90 waited=0

    # No interfaces configured — nothing to wait for.
    [ -z "$HOTSPOT_INTERFACES" ] && return

    # Wait for every interface in HOTSPOT_INTERFACES to be added to br0
    # by the vendor init — not just wlan*. eth0.2.0 (and any other eth
    # VLAN sub-if) joins br0 within ~12s of boot, well before wlan even
    # starts its MIB setup, so including it here costs nothing (it's
    # already satisfied on the very first check); it just means this
    # loop stays correct if HOTSPOT_INTERFACES ever changes shape,
    # instead of hardcoding a wlan-only assumption.
    #
    # The wlan side is still the real gate: the full iwpriv set_mib
    # sequence (SSID, auth, crypto) for wlanX always completes before
    # brctl addif br0 wlanX on all Realtek SDK builds, regardless of
    # where in rc35 monitord happens to be launched.
    #
    # Do NOT use monitord: on (PGN6401V) it launches at
    # the START of rc35 (~10s), 13+ seconds before WLAN MIB is written.
    # Do NOT use wlan0-vap0 existence: that's just MAC setup in rc32.
    while [ "$waited" -lt "$max_wait" ]; do
        local all_ready=1 uptime_now _if
        uptime_now="$(cut -d. -f1 /proc/uptime 2>/dev/null)"

        for _if in $HOTSPOT_INTERFACES; do
            [ -d "/sys/class/net/br0/brif/$_if" ] && continue

            # System has been up over 60s and this interface still isn't
            # in br0 — this is no longer a mid-boot timing race (that
            # window is well within 60s on both firmwares), so assume
            # it's already ready rather than waiting out the rest of
            # max_wait.
            if [ -n "$uptime_now" ] && [ "$uptime_now" -gt 60 ]; then
                continue
            fi

            all_ready=0
        done

        [ "$all_ready" -eq 1 ] && break
        sleep 1
        waited=$((waited + 1))
    done

    # Settle: VAP MIBs and ebtables portmapping rules finish shortly
    # after the radios join br0 (~1-2s on both firmwares).
    sleep 2

    ip route add default via "$(resolve_br0_gateway)" dev br0 2>/dev/null
}


# ── Extra NodeMCU coin-acceptor firewall isolation ─────────────────────────
# Applies the same "unreachable except via the router's own proxy scripts"
# FORWARD DROP the primary NodeMCU gets (see setup_firewall/cleanup_old_hotspot
# below) to every additional unit in NODEMCU_EXTRA_FILE. Re-entrant: always
# tears down whatever it applied last time (via the .mark file, same idea as
# hotspot_lan_isolate.mark below) before re-reading the current file, so
# edits/removals take effect cleanly on re-run without orphaned rules. Called
# both from setup_firewall and from the watchdog's hot-reload tick.
NODEMCU_EXTRA_FW_MARK="/tmp/hotspot_nodemcu_extra.mark"
apply_extra_nodemcu_fw() {
    if [ -f "$NODEMCU_EXTRA_FW_MARK" ]; then
        while IFS= read -r _old_ip; do
            [ -n "$_old_ip" ] && iptables -t filter -D FORWARD -d "$_old_ip" -j DROP 2>/dev/null
        done < "$NODEMCU_EXTRA_FW_MARK"
    fi
    : > "$NODEMCU_EXTRA_FW_MARK"
    [ -f "$NODEMCU_EXTRA_FILE" ] || return 0
    while IFS='|' read -r _nid _ntitle _nip _nmac _nport _npsk _nen; do
        case "$_nid" in ''|*[!0-9]*) continue ;; esac
        [ "${_nen:-1}" = "1" ] || continue
        [ -n "$_nip" ] || continue
        iptables -t filter -I FORWARD -d "$_nip" -j DROP 2>/dev/null
        printf '%s\n' "$_nip" >> "$NODEMCU_EXTRA_FW_MARK"
    done < "$NODEMCU_EXTRA_FILE"
}

cleanup_old_hotspot() {
    tc qdisc del dev $WAN_INT root 2>/dev/null
    for iface in $HOTSPOT_INTERFACES; do
        tc qdisc del dev "$iface" root 2>/dev/null
    done
    teardown_anti_tether 2>/dev/null
    [ -f /tmp/hotspot_watchdog.pid ] && { kill -9 "$(cat /tmp/hotspot_watchdog.pid)" 2>/dev/null; rm -f /tmp/hotspot_watchdog.pid; }
    MY_PID=$$
    for pid in $($BB ps ww | $BB grep "run_test.sh" | $BB grep -v grep | $BB awk '{print $1}'); do
        [ "$pid" -ne "$MY_PID" ] && kill -9 "$pid" 2>/dev/null
    done
    [ -f /tmp/hotspot_dhcp.pid ] && { kill -9 "$(cat /tmp/hotspot_dhcp.pid)" 2>/dev/null; rm -f /tmp/hotspot_dhcp.pid; }
    for pid in $($BB ps ww | $BB grep "hotspot_dhcp.conf" | $BB grep -v grep | $BB awk '{print $1}'); do kill -9 "$pid" 2>/dev/null; done
    for pid in $($BB ps ww| $BB grep "httpd" | $BB grep -v grep | $BB grep -F "$PORTAL_IP:$PORTAL_PORT" | $BB awk '{print $1}'); do kill -9 "$pid" 2>/dev/null; done
    
    # Kill any spawned ntpd instances for this hotspot to prevent orphaned processes
    for pid in $($BB ps ww | $BB grep "ntpd -S" | $BB grep -v grep | $BB awk '{print $1}'); do
        kill -9 "$pid" 2>/dev/null
    done

    iptables -t filter -D FORWARD -i $HOTSPOT_BR -j HOTSPOT_FWD 2>/dev/null
    iptables -t filter -F HOTSPOT_FWD 2>/dev/null
    iptables -t filter -X HOTSPOT_FWD 2>/dev/null
    iptables -t nat -D PREROUTING -i $HOTSPOT_BR -j HOTSPOT 2>/dev/null
    _cleanup_subnet=$(cat /tmp/hotspot_subnet.mark 2>/dev/null)
    [ -z "$_cleanup_subnet" ] && _cleanup_subnet=$(printf '%s' "${PORTAL_IP:-192.168.99.1}" | $BB sed 's/\.[^.]*$/.0\/24/')
    iptables -t nat -D POSTROUTING -s "$_cleanup_subnet" -j MASQUERADE 2>/dev/null
    rm -f /tmp/hotspot_subnet.mark
    iptables -t nat -F HOTSPOT 2>/dev/null
    iptables -t nat -X HOTSPOT 2>/dev/null
    iptables -t filter -D FORWARD -d $NODEMCU_IP -j DROP 2>/dev/null
    if [ -f "$NODEMCU_EXTRA_FW_MARK" ]; then
        while IFS= read -r _old_ip; do
            [ -n "$_old_ip" ] && iptables -t filter -D FORWARD -d "$_old_ip" -j DROP 2>/dev/null
        done < "$NODEMCU_EXTRA_FW_MARK"
    fi
    iptables -t filter -D INPUT -p tcp --dport $PORTAL_PORT -m state --state NEW -m comment --comment "lmehspt_ratelimit" -j DROP 2>/dev/null
    iptables -t filter -D INPUT -p tcp --dport $PORTAL_PORT -m state --state NEW -j DROP 2>/dev/null
    iptables -t filter -D INPUT -p tcp --dport $PORTAL_PORT -m state --state NEW -m limit --limit 20/sec --limit-burst 40 -m comment --comment "lmehspt_ratelimit" -j ACCEPT 2>/dev/null
    iptables -t filter -D INPUT -p tcp --dport $PORTAL_PORT -m state --state NEW -m limit --limit 20/sec --limit-burst 40 -j ACCEPT 2>/dev/null
    _lan_isolate=$(cat /tmp/hotspot_lan_isolate.mark 2>/dev/null)
    [ -n "$_lan_isolate" ] && iptables -t filter -D FORWARD -i $HOTSPOT_BR -d "$_lan_isolate" -j DROP 2>/dev/null
    rm -f /tmp/hotspot_lan_isolate.mark
    for _priv_net in $LAN_ISOLATE_PRIVATE_NETS; do
        iptables -t filter -D FORWARD -i $HOTSPOT_BR -d "$_priv_net" -j DROP 2>/dev/null
    done
    iptables -t filter -D INPUT -i $HOTSPOT_BR -p tcp --dport $WWW2_PORT -j ACCEPT 2>/dev/null
    # Return hotspot-enslaved interfaces to br0 (the LAN bridge) BEFORE tearing
    # down the hotspot bridge. Without this, disabling the hotspot leaves the
    # wlan/eth ports orphaned in the (now removed) bridge and offline. We walk
    # the live bridge members so it works even if HOTSPOT_INTERFACES changed.
    for ifpath in /sys/class/net/"$HOTSPOT_BR"/brif/*; do
        [ -e "$ifpath" ] || continue
        bm=$($BB basename "$ifpath")
        $BB brctl delif "$HOTSPOT_BR" "$bm" 2>/dev/null
        $BB brctl addif br0 "$bm" 2>/dev/null
        ifconfig "$bm" 0.0.0.0 up 2>/dev/null
    done
    # Belt-and-suspenders: also rebind anything still listed in the config.
    for iface in $HOTSPOT_INTERFACES; do
        $BB brctl delif "$HOTSPOT_BR" "$iface" 2>/dev/null
        $BB brctl addif br0 "$iface" 2>/dev/null
        ifconfig "$iface" 0.0.0.0 up 2>/dev/null
    done
    ifconfig $HOTSPOT_BR down 2>/dev/null
    $BB brctl delbr $HOTSPOT_BR 2>/dev/null
    rm -f /tmp/hotspot_dhcp.conf /tmp/udhcpd.leases

    # Restore original system DNS configuration if a backup exists
    [ -f /etc/resolv.conf.bak ] && { mv /etc/resolv.conf.bak /etc/resolv.conf 2>/dev/null; }
}

# Returns the interface to use as the hotspot upstream (upload direction).
# /tmp/repurpose_active is a shared registry (one interface per line) since
# multiple interfaces can be repurposed as DHCP-client WAN at once — but
# only ONE of them can meaningfully carry the real default route, so this
# picks whichever configured interface has its default-route flag set
# (/tmp/repurpose_defroute_<iface>; missing file = "1", which matches the
# old pre-multi-interface behaviour where the single repurposed WAN was
# always the default route). Falls back to br0 if none is flagged.
resolve_wan_int() {
    local rif flag
    if [ -f /tmp/repurpose_active ]; then
        while IFS= read -r rif; do
            [ -z "$rif" ] && continue
            flag=$($BB tr -d '\r\n' < "/tmp/repurpose_defroute_${rif}" 2>/dev/null)
            flag="${flag:-1}"
            if [ "$flag" = "1" ] && ip link show "$rif" >/dev/null 2>&1; then
                echo "$rif"; return
            fi
        done < /tmp/repurpose_active
    fi
    echo "$WAN_INT_DEFAULT"
}

# Returns the upstream default-route gateway for br0, detected dynamically
# from br0's own IPv4 address (assumes the gateway is the .1 host of br0's
# /24 subnet, e.g. br0=192.168.18.42 -> gateway 192.168.18.1). Falls back to
# the configured BR0_GATEWAY only when br0 has no IPv4 address yet.
resolve_br0_gateway() {
    local _ip _gw
    # Prefer `ip`; parse the first IPv4 assigned to br0.
    _ip=$(ip -4 addr show br0 2>/dev/null | $BB grep -o 'inet [0-9.]*' | $BB awk '{print $2}' | head -1)
    # Fallback to ifconfig output (older busybox "inet addr:x.x.x.x" format too).
    if [ -z "$_ip" ]; then
        _ip=$(ifconfig br0 2>/dev/null | $BB grep -o 'inet \(addr:\)\?[0-9.]*' | $BB grep -o '[0-9.]*' | head -1)
    fi
    if [ -n "$_ip" ]; then
        _gw=$(printf '%s' "$_ip" | $BB sed 's/\.[^.]*$/.1/')
        [ -n "$_gw" ] && { echo "$_gw"; return; }
    fi
    echo "$BR0_GATEWAY"
}

# Deauthenticate every station currently associated to a wlan* netdev so it
# re-associates and pulls a fresh DHCP lease. Called right after an interface
# is enslaved into HOTSPOT_BR: any STA that connected while the radio was still
# on br0 is holding a br0 LAN IP and will bypass the captive portal entirely.
# Kicking forces a reconnect → new udhcpd lease from the portal subnet on br1.
#
# Station MACs are read from /proc/<iface>/sta_info (same source wlansta.cgi
# parses) and kicked with `iwpriv <iface> del_sta <hexmac>` (12-hex-digit form,
# exactly what wlansta.cgi's disconnect action uses). Non-wlan (e.g. ethernet)
# interfaces have no sta_info and are skipped automatically.
kick_iface_stas() {
    local _if="$1" _sf _mac _hx
    case "$_if" in wlan*) ;; *) return ;; esac
    _sf="/proc/${_if}/sta_info"
    [ -f "$_sf" ] || return
    for _mac in $($BB grep -i '^[ \t]*hwaddr:' "$_sf" 2>/dev/null \
                    | $BB sed 's/^[^:]*:[ \t]*//'); do
        _hx=$(printf '%s' "$_mac" | $BB tr 'A-Z' 'a-z' | $BB sed 's/[^0-9a-f]//g')
        [ ${#_hx} -eq 12 ] || continue
        logger -t lmehspt "kick STA $_hx on $_if after br1 bind (was on br0)" 2>/dev/null
        iwpriv "$_if" del_sta "$_hx" >/dev/null 2>&1
    done
}

# Deauthenticate ONE specific station by MAC, on whichever hotspot wlan
# interface it's currently associated to — unlike kick_iface_stas above,
# every OTHER connected station (customers included) is left untouched.
#
# Used right after (re)writing a NodeMCU's static DHCP lease (coin.sh's
# NodeMCU config add/edit, and the primary's config_set path in hotspot.cgi).
# Bouncing udhcpd alone only changes what the *server* will offer next; it
# does nothing to a station that already holds a lease and has no reason to
# ask again. Forcing a deauth here makes the device re-associate and issue a
# fresh DHCPDISCOVER immediately, so it actually picks up the newly-assigned
# static IP instead of silently sitting on whatever address it already had
# until its own lease renewal timer (or a manual power-cycle) comes around.
kick_sta_mac() {
    local _target _hx _if
    _target=$(printf '%s' "$1" | $BB tr 'A-Z' 'a-z' | $BB sed 's/[^0-9a-f]//g')
    [ ${#_target} -eq 12 ] || return 1
    for _if in $HOTSPOT_INTERFACES; do
        case "$_if" in wlan*) ;; *) continue ;; esac
        [ -f "/proc/${_if}/sta_info" ] || continue
        iwpriv "$_if" del_sta "$_target" >/dev/null 2>&1
    done
}

setup_network() {
    $BB brctl addbr $HOTSPOT_BR 2>/dev/null
    # Release any interface still enslaved in HOTSPOT_BR that is no longer
    # listed in HOTSPOT_INTERFACES (the admin unbound it) back to br0 first.
    # Without this, an unbound interface just sits orphaned in the hotspot
    # bridge — off the LAN and unusable — until a full hotspot restart.
    for ifpath in /sys/class/net/"$HOTSPOT_BR"/brif/*; do
        [ -e "$ifpath" ] || continue
        bm=$($BB basename "$ifpath")
        case " $HOTSPOT_INTERFACES " in
            *" $bm "*) ;;  # still wanted — leave enslaved
            *)
                $BB brctl delif "$HOTSPOT_BR" "$bm" 2>/dev/null
                $BB brctl addif br0 "$bm" 2>/dev/null
                ifconfig "$bm" 0.0.0.0 up 2>/dev/null
                ;;
        esac
    done
    for iface in $HOTSPOT_INTERFACES; do
        $BB brctl delif br0 $iface 2>/dev/null
        $BB brctl addif $HOTSPOT_BR $iface 2>/dev/null
        ifconfig $iface 0.0.0.0 up
    done
    ifconfig $HOTSPOT_BR $PORTAL_IP netmask 255.255.255.0 up

    # Bounce every station now that the wlan interfaces are enslaved to the
    # portal bridge. Anything that associated while the radio was still part of
    # br0 already grabbed a LAN IP and would otherwise never see the captive
    # portal; kicking forces a reconnect and a fresh DHCP lease on br1. This
    # runs on the first boot-time setup_network AND whenever the watchdog
    # re-binds after an Interfaces-tab change, covering both requested cases.
    for iface in $HOTSPOT_INTERFACES; do
        kick_iface_stas "$iface"
    done
}

setup_firewall() {
    iptables -t nat -N HOTSPOT 2>/dev/null
    iptables -t nat -F HOTSPOT
    iptables -t nat -A HOTSPOT -d $PORTAL_IP -j RETURN
    iptables -t nat -A HOTSPOT -p tcp --dport 80 -j DNAT --to-destination $PORTAL_IP:$PORTAL_PORT
    iptables -t nat -A HOTSPOT -p tcp --dport 443 -j DNAT --to-destination $PORTAL_IP:$PORTAL_PORT
    iptables -t nat -D PREROUTING -i $HOTSPOT_BR -j HOTSPOT 2>/dev/null
    iptables -t nat -I PREROUTING -i $HOTSPOT_BR -j HOTSPOT
    _portal_subnet=$(printf '%s' "$PORTAL_IP" | $BB sed 's/\.[^.]*$/.0\/24/')
    printf '%s\n' "$_portal_subnet" > /tmp/hotspot_subnet.mark
    iptables -t nat -D POSTROUTING -s "$_portal_subnet" -j MASQUERADE 2>/dev/null
    iptables -t nat -A POSTROUTING -s "$_portal_subnet" -j MASQUERADE
    iptables -t filter -N HOTSPOT_FWD 2>/dev/null
    iptables -t filter -F HOTSPOT_FWD
    iptables -t filter -A HOTSPOT_FWD -m state --state ESTABLISHED,RELATED -o $HOTSPOT_BR -j ACCEPT
    iptables -t filter -A HOTSPOT_FWD -p udp --dport 53 -j ACCEPT
    iptables -t filter -A HOTSPOT_FWD -d $PORTAL_IP -j ACCEPT
    iptables -t filter -A HOTSPOT_FWD -j DROP
    iptables -t filter -D FORWARD -i $HOTSPOT_BR -j HOTSPOT_FWD 2>/dev/null
    iptables -t filter -I FORWARD -i $HOTSPOT_BR -j HOTSPOT_FWD
    iptables -t filter -I FORWARD -d $NODEMCU_IP -j DROP 2>/dev/null
    apply_extra_nodemcu_fw
    # ── LAN isolation ──────────────────────────────────────────────────────────
    case "${LAN_ISOLATE:-1}" in
    1|yes|true)
        # Block hotspot clients (including authenticated sessions) from reaching
        # any LAN device on br0. Inserted at position 1 in FORWARD so it fires
        # before the HOTSPOT_FWD jump, overriding the per-MAC session ACCEPT rules.
        # www2 ($PORTAL_IP:$WWW2_PORT) is served locally and reached via INPUT —
        # not FORWARD — so no exception is needed here.
        _old_lan=$(cat /tmp/hotspot_lan_isolate.mark 2>/dev/null)
        [ -n "$_old_lan" ] && iptables -t filter -D FORWARD -i $HOTSPOT_BR -d "$_old_lan" -j DROP 2>/dev/null
        _lan_gw=$(resolve_br0_gateway)
        _lan_subnet=$(printf '%s' "$_lan_gw" | $BB sed 's/\.[^.]*$/.0\/24/')
        iptables -t filter -I FORWARD 1 -i $HOTSPOT_BR -d "$_lan_subnet" -j DROP
        printf '%s\n' "$_lan_subnet" > /tmp/hotspot_lan_isolate.mark
        # Blanket-block every RFC1918 private range too, not just br0's own
        # subnet. A repurposed-WAN uplink's own gateway (e.g. 192.168.69.1)
        # may itself be double/triple-NATed behind further private hops
        # (e.g. 192.168.7.1) that we can't enumerate in advance — since those
        # are still private addresses, this catches them at any depth without
        # needing to know the chain. Public internet destinations, which is
        # everything hotspot clients actually need, are never in these ranges.
        for _priv_net in $LAN_ISOLATE_PRIVATE_NETS; do
            iptables -t filter -D FORWARD -i $HOTSPOT_BR -d "$_priv_net" -j DROP 2>/dev/null
            iptables -t filter -I FORWARD 1 -i $HOTSPOT_BR -d "$_priv_net" -j DROP
        done
        # Guarantee www2 is reachable from the hotspot bridge even if another rule
        # in INPUT would otherwise block it.
        iptables -t filter -D INPUT -i $HOTSPOT_BR -p tcp --dport $WWW2_PORT -j ACCEPT 2>/dev/null
        iptables -t filter -I INPUT 1 -i $HOTSPOT_BR -p tcp --dport $WWW2_PORT -j ACCEPT
        ;;
    *)
        # Isolation disabled — clean up any rule left from a prior enabled state.
        _old_lan=$(cat /tmp/hotspot_lan_isolate.mark 2>/dev/null)
        [ -n "$_old_lan" ] && iptables -t filter -D FORWARD -i $HOTSPOT_BR -d "$_old_lan" -j DROP 2>/dev/null
        rm -f /tmp/hotspot_lan_isolate.mark
        for _priv_net in $LAN_ISOLATE_PRIVATE_NETS; do
            iptables -t filter -D FORWARD -i $HOTSPOT_BR -d "$_priv_net" -j DROP 2>/dev/null
        done
        iptables -t filter -D INPUT -i $HOTSPOT_BR -p tcp --dport $WWW2_PORT -j ACCEPT 2>/dev/null
        ;;
    esac
    # ──────────────────────────────────────────────────────────────────────────
    # Tag with a comment so the port-80 watchdog can tell these apart from
    # vendor-added rules later. Not every embedded iptables build has the
    # comment match module compiled in, so fall back to untagged rules
    # rather than let a missing module silently drop the rate-limit
    # protection entirely.
    iptables -t filter -I INPUT -p tcp --dport $PORTAL_PORT -m state --state NEW -m comment --comment "lmehspt_ratelimit" -j DROP 2>/dev/null \
        || iptables -t filter -I INPUT -p tcp --dport $PORTAL_PORT -m state --state NEW -j DROP 2>/dev/null
    iptables -t filter -I INPUT -p tcp --dport $PORTAL_PORT -m state --state NEW -m limit --limit 20/sec --limit-burst 40 -m comment --comment "lmehspt_ratelimit" -j ACCEPT 2>/dev/null \
        || iptables -t filter -I INPUT -p tcp --dport $PORTAL_PORT -m state --state NEW -m limit --limit 20/sec --limit-burst 40 -j ACCEPT 2>/dev/null
    # ------------------------------------------------------------
    # OPTIMIZATION: TCP MSS Clamping to prevent MTU blackholes/packet loss
    # ------------------------------------------------------------
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    iptables -t mangle -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null

    echo 1 > /proc/sys/net/ipv4/ip_forward
    # Apply anti-tethering if enabled
    case "${ANTI_TETHER:-0}" in 1|yes|true) setup_anti_tether ;; esac
}

# ============================================================
# PORT 80 WATCHDOG — only does anything while PORTAL_PORT="80"
# The vendor firmware's own "boa" httpd binds port 80 for the router's
# stock admin UI, which collides with our BusyBox httpd trying to bind
# $PORTAL_IP:80, and some vendor init scripts add their own INPUT/
# FORWARD firewall rules reserving port 80 for it. Both fights are
# only worth having if the admin has explicitly chosen port 80 for the
# portal (instead of the default 808) — e.g. for client devices whose
# captive-portal detection only follows a redirect to plain port 80.
# ============================================================
PORT80_LOG="/tmp/portal80_watchdog.log"

ensure_port80_clear() {
    [ "$PORTAL_PORT" = "80" ] || return 0

    # 1. Kill boa. A vendor process monitor may respawn it, so this is
    #    meant to be called repeatedly (from the main watchdog loop),
    #    not just once.
    if $BB pidof boa >/dev/null 2>&1; then
        $BB killall boa 2>/dev/null
        $BB pidof boa >/dev/null 2>&1 && $BB killall -9 boa 2>/dev/null
        printf '[%s] portal80: killed boa\n' "$($BB date)" >> "$PORT80_LOG"
    fi

    # 2. Remove any DROP/REJECT rule targeting dport 80 in INPUT/FORWARD
    #    that isn't our own "lmehspt_ratelimit"-tagged rule. Vendor
    #    firmware sometimes reserves port 80 for boa at the firewall
    #    level too, which would silently blackhole the portal even with
    #    boa's process dead. Skipped entirely on builds whose iptables
    #    doesn't support -S (rule dump) — nothing to safely act on then.
    for _chain in INPUT FORWARD; do
        iptables -S "$_chain" 2>/dev/null | while read -r _rule; do
            case "$_rule" in
                *"--dport 80"*"-j DROP"*|*"--dport 80"*"-j REJECT"*)
                    case "$_rule" in
                        *"lmehspt_ratelimit"*) continue ;;  # ours — keep
                    esac
                    _spec=$(printf '%s' "$_rule" | $BB sed "s/^-A $_chain //")
                    if iptables -D "$_chain" $_spec 2>/dev/null; then
                        printf '[%s] portal80: removed blocking rule from %s: %s\n' \
                            "$($BB date)" "$_chain" "$_rule" >> "$PORT80_LOG"
                    fi
                    ;;
            esac
        done
    done
}

restore_fw_sessions() {
    [ -f "$SESSION_FILE" ] || return
    local NOW
    NOW=$($BB awk '{print int($1)}' /proc/uptime)
    while read -r mac expiry total; do
        [ -n "$mac" ] && [ -n "$expiry" ] || continue
        [ "$expiry" -gt "$NOW" ] || continue
        iptables -t nat -I HOTSPOT 1 -m mac --mac-source "$mac" -j RETURN 2>/dev/null
        iptables -t filter -I HOTSPOT_FWD 1 -m mac --mac-source "$mac" -j ACCEPT 2>/dev/null
    done < "$SESSION_FILE"
}

setup_whitelist() {
    [ -f "$WHITELIST_FILE" ] || return
    while read -r rawmac; do
        [ -z "$rawmac" ] && continue
        case "$rawmac" in \#*) continue ;; esac
        local mac
        mac=$(format_mac "$rawmac")
        iptables -t nat -I HOTSPOT 1 -m mac --mac-source "$mac" -j RETURN 2>/dev/null
        iptables -t filter -I HOTSPOT_FWD 1 -m mac --mac-source "$mac" -j ACCEPT 2>/dev/null
    done < "$WHITELIST_FILE"
}

ip_to_cid() {
    local _pfx
    _pfx=$(printf '%s' "$PORTAL_IP" | $BB sed 's/\.[^.]*$//')
    printf '%s' "$1" | $BB awk -F. -v p="$_pfx" \
        'BEGIN{n=split(p,a,".")} (NF==4&&$1==a[1]&&$2==a[2]&&$3==a[3]&&$4+0>=5&&$4+0<=254){print $4+400}'
}
save_ip_map() {
    local mac=$1 ip=$2
    $BB grep -vi "^$mac " "$IP_MAP_FILE" > /tmp/ip_map.tmp 2>/dev/null
    echo "$mac $ip" >> /tmp/ip_map.tmp
    $BB mv /tmp/ip_map.tmp "$IP_MAP_FILE"
}
get_ip_for_mac() {
    local mac=$1 ip
    # Scope this to $HOTSPOT_BR only. A bare "arp -n | grep mac" can match a
    # stale/unrelated neighbor entry for the same MAC on a different
    # interface (e.g. wlan0-vxd) whose IP isn't even on the portal subnet -
    # ip_to_cid() then silently returns empty for it, which skips QoS class
    # creation, zeroes out download packet counting in check_inactivity(),
    # and sends the liveness ping to the wrong address, all at once. Filter
    # out FAILED entries too; STALE/DELAY are still usable mappings.
    ip=$(ip neigh show dev "$HOTSPOT_BR" 2>/dev/null | $BB grep -i "$mac" | $BB grep -vi FAILED | $BB awk '{print $1}' | head -1)
    if [ -n "$ip" ]; then
        save_ip_map "$mac" "$ip"
        echo "$ip"
        return
    fi
    $BB grep -i "^$mac " "$IP_MAP_FILE" 2>/dev/null | $BB awk '{print $2}' | head -1
}

add_user_qos() {
    local mac=$1 ip cid
    ip=$(get_ip_for_mac "$mac")
    [ -z "$ip" ] && return
    cid=$(ip_to_cid "$ip")
    [ -z "$cid" ] && return

    # Normalise rate strings (handles bare m/k/g and mbps/kbps suffixes)
    GLOBAL_RATE=$(_norm_rate "$GLOBAL_RATE")
    PER_USER_RATE=$(_norm_rate "$PER_USER_RATE")

    iptables -t mangle -I FORWARD 1 -i $HOTSPOT_BR -m mac --mac-source "$mac" -j MARK --set-mark $cid 2>/dev/null
    
    # ============================================================
    # UPLOAD (WAN) Leaf QoS - Gaming Prioritization
    # ============================================================
    tc class add dev $WAN_INT parent 1:1 classid 1:$cid htb rate $PER_USER_RATE ceil $GLOBAL_RATE burst $PER_USER_BURST quantum 1500 2>/dev/null
    
    # Create 2 priority bands (Band 1 = Gaming/VIP, Band 2 = Bulk). Priomap defaults everything to Band 2.
    tc qdisc add dev $WAN_INT parent 1:$cid handle ${cid}: prio bands 2 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 2>/dev/null
    
    # OPTIMIZATION: Lowered limits enforce early tail-drop (pseudo-AQM) since fq_codel is missing.
    # Band 1 (Gaming/VIP) gets limit 32 so queued latency never exceeds ~15-20ms.
    # Band 2 (Bulk) gets limit 64 to prevent TCP starvation while keeping bloat reasonable.
    tc qdisc add dev $WAN_INT parent ${cid}:1 handle $((cid+1000)): sfq perturb 10 limit 32 2>/dev/null
    tc qdisc add dev $WAN_INT parent ${cid}:2 handle $((cid+2000)): sfq perturb 10 limit 64 2>/dev/null
    
    tc filter add dev $WAN_INT parent 1:0 prio $cid handle $cid fw flowid 1:$cid 2>/dev/null
    
    # Band 1 Filters: Route Games (UDP < 512B), Ping (ICMP), DNS, and small TCP ACKs (< 128B) into the VIP Lane
    tc filter add dev $WAN_INT parent ${cid}:0 protocol ip prio 1 u32 match ip protocol 17 0xff match u16 0x0000 0xfe00 at 2 flowid ${cid}:1 2>/dev/null
    tc filter add dev $WAN_INT parent ${cid}:0 protocol ip prio 2 u32 match ip protocol 1 0xff flowid ${cid}:1 2>/dev/null
    tc filter add dev $WAN_INT parent ${cid}:0 protocol ip prio 3 u32 match ip protocol 6 0xff match u16 0x0000 0xff80 at 2 flowid ${cid}:1 2>/dev/null
    # OPTIMIZATION: Catch outbound DNS (UDP 53) for fast domain resolution
    tc filter add dev $WAN_INT parent ${cid}:0 protocol ip prio 4 u32 match ip protocol 17 0xff match ip dport 53 0xffff flowid ${cid}:1 2>/dev/null

    # ============================================================
    # DOWNLOAD (LAN Bridge) Leaf QoS - Gaming Prioritization
    # ============================================================
    tc class add dev $HOTSPOT_BR parent 2:1 classid 2:$cid htb rate $PER_USER_RATE ceil $GLOBAL_RATE burst $PER_USER_BURST quantum 1500 2>/dev/null
    
    tc qdisc add dev $HOTSPOT_BR parent 2:$cid handle $((cid+500)): prio bands 2 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 2>/dev/null
    
    # OPTIMIZATION: Same strict limits for download (Bridge)
    tc qdisc add dev $HOTSPOT_BR parent $((cid+500)):1 handle $((cid+3000)): sfq perturb 10 limit 32 2>/dev/null
    tc qdisc add dev $HOTSPOT_BR parent $((cid+500)):2 handle $((cid+4000)): sfq perturb 10 limit 64 2>/dev/null

    tc filter add dev $HOTSPOT_BR protocol ip parent 2:0 prio $cid u32 match ip dst $ip/32 flowid 2:$cid 2>/dev/null
    
    # Band 1 Filters for Download
    tc filter add dev $HOTSPOT_BR parent $((cid+500)):0 protocol ip prio 1 u32 match ip protocol 17 0xff match u16 0x0000 0xfe00 at 2 flowid $((cid+500)):1 2>/dev/null
    tc filter add dev $HOTSPOT_BR parent $((cid+500)):0 protocol ip prio 2 u32 match ip protocol 1 0xff flowid $((cid+500)):1 2>/dev/null
    tc filter add dev $HOTSPOT_BR parent $((cid+500)):0 protocol ip prio 3 u32 match ip protocol 6 0xff match u16 0x0000 0xff80 at 2 flowid $((cid+500)):1 2>/dev/null
    # OPTIMIZATION: Catch inbound DNS replies (UDP 53)
    tc filter add dev $HOTSPOT_BR parent $((cid+500)):0 protocol ip prio 4 u32 match ip protocol 17 0xff match ip sport 53 0xffff flowid $((cid+500)):1 2>/dev/null
}




del_user_qos() {
    local mac=$1 ip cid
    ip=$(get_ip_for_mac "$mac")
    [ -z "$ip" ] && ip=$($BB grep -i "^$mac " "$IP_MAP_FILE" 2>/dev/null | $BB awk '{print $2}')
    [ -z "$ip" ] && return
    cid=$(ip_to_cid "$ip")
    [ -z "$cid" ] && return
    iptables -t mangle -D FORWARD -i $HOTSPOT_BR -m mac --mac-source "$mac" -j MARK --set-mark $cid 2>/dev/null
    tc filter del dev $WAN_INT parent 1:0 prio $cid 2>/dev/null
    tc qdisc  del dev $WAN_INT parent 1:$cid 2>/dev/null
    tc class  del dev $WAN_INT classid 1:$cid 2>/dev/null
    tc filter del dev $HOTSPOT_BR protocol ip parent 2:0 prio $cid 2>/dev/null
    tc qdisc  del dev $HOTSPOT_BR parent 2:$cid 2>/dev/null
    tc class  del dev $HOTSPOT_BR classid 2:$cid 2>/dev/null
    $BB grep -vi "^$mac " "$IP_MAP_FILE" > /tmp/ip_map_del.tmp 2>/dev/null
    $BB mv /tmp/ip_map_del.tmp "$IP_MAP_FILE"
}

restore_qos_sessions() {
    [ -f "$SESSION_FILE" ] || return
    local NOW mac expiry total ip cid
    NOW=$($BB awk '{print int($1)}' /proc/uptime)
    while read -r mac expiry total; do
        [ -n "$mac" ] && [ -n "$expiry" ] || continue
        [ "$expiry" -gt "$NOW" ] || continue
        ip=$(get_ip_for_mac "$mac")
        [ -z "$ip" ] && continue
        cid=$(ip_to_cid "$ip")
        [ -z "$cid" ] && continue
        tc class show dev $WAN_INT classid 1:$cid 2>/dev/null | $BB grep -q ":" && continue
        add_user_qos "$mac"
    done < "$SESSION_FILE"
}

start_dhcp() {
    local _pb
    _pb=$(printf '%s' "$PORTAL_IP" | $BB sed 's/\.[^.]*$//')
    $BB touch /tmp/udhcpd.leases
    $BB cat > /tmp/hotspot_dhcp.conf << EOF
start           ${_pb}.${DHCP_START:-5}
end             ${_pb}.${DHCP_END:-254}
interface       $HOTSPOT_BR
option subnet   255.255.255.0
option router   $PORTAL_IP
option dns      ${DHCP_DNS:-1.1.1.1}
lease_file      /tmp/udhcpd.leases
pidfile         /tmp/hotspot_dhcp.pid
EOF
    if [ "$COIN_ENABLED" = "1" ] && [ -n "$NODEMCU_MAC" ] && [ "${NODEMCU_1_ENABLED:-1}" = "1" ]; then
        printf 'static_lease    %s %s\n' "$(format_mac "$NODEMCU_MAC")" "$NODEMCU_IP" >> /tmp/hotspot_dhcp.conf
    fi
    # Additional coin acceptor units (#2+), each pinned to its own IP the same
    # way the primary is above. A malformed/blank row is skipped rather than
    # aborting the whole lease file.
    if [ "$COIN_ENABLED" = "1" ] && [ -f "$NODEMCU_EXTRA_FILE" ]; then
        while IFS='|' read -r _nid _ntitle _nip _nmac _nport _npsk _nen; do
            case "$_nid" in ''|*[!0-9]*) continue ;; esac
            [ "${_nen:-1}" = "1" ] || continue
            [ -n "$_nmac" ] && [ -n "$_nip" ] || continue
            printf 'static_lease    %s %s\n' "$(format_mac "$_nmac")" "$_nip" >> /tmp/hotspot_dhcp.conf
        done < "$NODEMCU_EXTRA_FILE"
    fi
    $BB udhcpd /tmp/hotspot_dhcp.conf
}

# ============================================================
# ANTI-TETHERING
# Marks tethered packets (TTL=62 Android/Linux, TTL=126 Windows) via iptables
# mangle FORWARD *before* MASQUERADE rewrites the source IP, scoped to the
# hotspot bridge (-i $HOTSPOT_BR) so br0 LAN devices are never affected.
# The netfilter mark (0x666) survives NAT and is read by a fw classifier on
# WAN egress — the same mark+fw mechanism already used by per-user QoS.
# Falls back to bare tc u32 TTL match at WAN egress if xt_ttl is unavailable;
# in that mode the choke still works but cannot distinguish br0 LAN devices
# that happen to arrive with TTL=62/126 (secondary-router scenario).
# ============================================================
#supported iptables modules:
# string state physdev mac limit conntrack conntrack
# conntrack connlabel comment set connmark2 connmark mark2 mark icmp weburl tcpmss
# iprange tos dscp dns set set set set set udplite udp tcp
setup_anti_tether() {
    local wan_if
    wan_if=$(resolve_wan_int)

    # 1. Add the Choke Class to the active WAN interface (1kbit ≈ 0 speed)
    tc class add dev "$wan_if" parent 1:1 classid 1:666 htb rate 1kbit ceil 1kbit burst 1k 2>/dev/null

    # 2. Preferred path: mark tethered packets at FORWARD stage using xt_ttl
    # Note: Linux routes the packet (decrementing TTL by 1) BEFORE traversing the FORWARD chain.
    # Therefore, a normal device (TTL 64 or 128) will have a TTL of 63 or 127 in FORWARD.
    # A tethered device (TTL 63 or 127) will have a TTL of 62 or 126 in FORWARD.
    # We must match 62, 61, 126, and 125 here to avoid falsely blocking normal users.
    if iptables -t mangle -A FORWARD -i "$HOTSPOT_BR" -m ttl --ttl-eq 62  -j MARK --set-mark 0x666 2>/dev/null \
    && iptables -t mangle -A FORWARD -i "$HOTSPOT_BR" -m ttl --ttl-eq 61  -j MARK --set-mark 0x666 2>/dev/null \
    && iptables -t mangle -A FORWARD -i "$HOTSPOT_BR" -m ttl --ttl-eq 126 -j MARK --set-mark 0x666 2>/dev/null \
    && iptables -t mangle -A FORWARD -i "$HOTSPOT_BR" -m ttl --ttl-eq 125 -j MARK --set-mark 0x666 2>/dev/null; then
        tc filter add dev "$wan_if" parent 1:0 prio 1 handle 0x666 fw flowid 1:666 2>/dev/null
        return
    fi

    # Clean up partial state if xt_ttl failed
    iptables -t mangle -D FORWARD -i "$HOTSPOT_BR" -m ttl --ttl-eq 62  -j MARK --set-mark 0x666 2>/dev/null
    iptables -t mangle -D FORWARD -i "$HOTSPOT_BR" -m ttl --ttl-eq 61  -j MARK --set-mark 0x666 2>/dev/null
    iptables -t mangle -D FORWARD -i "$HOTSPOT_BR" -m ttl --ttl-eq 126 -j MARK --set-mark 0x666 2>/dev/null
    iptables -t mangle -D FORWARD -i "$HOTSPOT_BR" -m ttl --ttl-eq 125 -j MARK --set-mark 0x666 2>/dev/null

    # Fallback A: Try Ingress filtering directly on the Hotspot Bridge.
    # This is 100% safe as it physically acts on br1 and cannot touch br0.
    # Note: Ingress runs before routing. The TTL has NOT been decremented yet.
    # Checking for 63, 62, 127, 126 here is STILL CORRECT.
    if tc qdisc add dev "$HOTSPOT_BR" handle ffff: ingress 2>/dev/null; then
        # Add each TTL rule independently; u32 entries under the same prio coexist
        _at_ok=0
        tc filter add dev "$HOTSPOT_BR" parent ffff: protocol ip prio 1 u32 match u8 63  0xff at 8 police rate 1kbit burst 1k drop 2>/dev/null && _at_ok=1
        tc filter add dev "$HOTSPOT_BR" parent ffff: protocol ip prio 1 u32 match u8 62  0xff at 8 police rate 1kbit burst 1k drop 2>/dev/null && _at_ok=1
        tc filter add dev "$HOTSPOT_BR" parent ffff: protocol ip prio 1 u32 match u8 127 0xff at 8 police rate 1kbit burst 1k drop 2>/dev/null && _at_ok=1
        tc filter add dev "$HOTSPOT_BR" parent ffff: protocol ip prio 1 u32 match u8 126 0xff at 8 police rate 1kbit burst 1k drop 2>/dev/null && _at_ok=1
        [ "$_at_ok" = "1" ] && return
        tc qdisc del dev "$HOTSPOT_BR" ingress 2>/dev/null
    fi

    # Fallback B: Try iptables TOS injection (older, highly compatible target)
    iptables -t mangle -D FORWARD -i "$HOTSPOT_BR" -j TOS --set-tos 0x10 2>/dev/null
    if iptables -t mangle -A FORWARD -i "$HOTSPOT_BR" -j TOS --set-tos 0x10 2>/dev/null; then
        # This matches packets on the WAN egress, so routing has already decremented the TTL.
        # Like the Preferred path, we must match 62, 61, 126, 125 here.
        tc filter add dev "$wan_if" parent 1:0 protocol ip prio 1 u32 match u8 62  0xff at 8 match u8 0x10 0xff at 1 flowid 1:666 2>/dev/null
        tc filter add dev "$wan_if" parent 1:0 protocol ip prio 1 u32 match u8 61  0xff at 8 match u8 0x10 0xff at 1 flowid 1:666 2>/dev/null
        tc filter add dev "$wan_if" parent 1:0 protocol ip prio 1 u32 match u8 126 0xff at 8 match u8 0x10 0xff at 1 flowid 1:666 2>/dev/null
        tc filter add dev "$wan_if" parent 1:0 protocol ip prio 1 u32 match u8 125 0xff at 8 match u8 0x10 0xff at 1 flowid 1:666 2>/dev/null
        return
    fi
}

teardown_anti_tether() {
    local wan_if
    wan_if=$(resolve_wan_int)

    # Remove direct ingress filters (this also removes all tc filters under ffff:)
    tc qdisc del dev "$HOTSPOT_BR" ingress 2>/dev/null

    # Remove iptables mangle marks (single-hop and double-hop, all TTL variants)
    # We remove both the old buggy values (63, 127) and the new fixed values (62, 126) 
    # to cleanly handle state left behind from the prior buggy version.
    iptables -t mangle -D FORWARD -i "$HOTSPOT_BR" -m ttl --ttl-eq 63  -j MARK --set-mark 0x666 2>/dev/null
    iptables -t mangle -D FORWARD -i "$HOTSPOT_BR" -m ttl --ttl-eq 62  -j MARK --set-mark 0x666 2>/dev/null
    iptables -t mangle -D FORWARD -i "$HOTSPOT_BR" -m ttl --ttl-eq 61  -j MARK --set-mark 0x666 2>/dev/null
    iptables -t mangle -D FORWARD -i "$HOTSPOT_BR" -m ttl --ttl-eq 127 -j MARK --set-mark 0x666 2>/dev/null
    iptables -t mangle -D FORWARD -i "$HOTSPOT_BR" -m ttl --ttl-eq 126 -j MARK --set-mark 0x666 2>/dev/null
    iptables -t mangle -D FORWARD -i "$HOTSPOT_BR" -m ttl --ttl-eq 125 -j MARK --set-mark 0x666 2>/dev/null
    iptables -t mangle -D FORWARD -i "$HOTSPOT_BR" -j TOS --set-tos 0x10 2>/dev/null

    # Remove prio 1 tc filters (fw classifier + u32 Fallback B rules)
    tc filter del dev "$wan_if" parent 1:0 prio 1 2>/dev/null

    # Remove the choke class
    tc class  del dev "$wan_if" classid 1:666 2>/dev/null
}
setup_qos() {
    # Normalise rate strings (handles bare m/k/g and mbps/kbps suffixes)
    GLOBAL_RATE=$(_norm_rate "$GLOBAL_RATE")
    UNAUTH_RATE=$(_norm_rate "$UNAUTH_RATE")

    tc qdisc del dev $WAN_INT  root 2>/dev/null
    tc qdisc del dev $HOTSPOT_BR root 2>/dev/null
    
    # ------------------------------------------------------------
    # UPLOAD (WAN) CONFIGURATION
    # ------------------------------------------------------------
    # Root HTB with r2q 1 prevents incorrect automatic quantum calculations at low speeds
    tc qdisc add dev $WAN_INT root handle 1: htb default 99 r2q 1
    # OPTIMIZATION: Lowered root burst from 32k to 15k to prevent dumping too many packets into the modem's hardware queues (reduces ping spikes)
    tc class add dev $WAN_INT parent 1:  classid 1:1  htb rate $GLOBAL_RATE  burst 15k
    
    # Default unauth class with precise quantum
    tc class add dev $WAN_INT parent 1:1 classid 1:99 htb rate $UNAUTH_RATE  ceil $GLOBAL_RATE burst 4k quantum 1500
    # SFQ with a low packet limit (12) to drop early and trigger TCP backoff
    tc qdisc add dev $WAN_INT parent 1:99 handle 990: sfq perturb 10 limit 12
    # PCQ Emulation: force unauth upload SFQ to hash strictly by source IP
    tc filter add dev $WAN_INT parent 990: protocol ip prio 1 flow hash keys src perturb 10 divisor 1024 2>/dev/null

    # ------------------------------------------------------------
    # DOWNLOAD (LAN Bridge) CONFIGURATION
    # ------------------------------------------------------------
    tc qdisc add dev $HOTSPOT_BR root handle 2: htb default 99 r2q 1
    # OPTIMIZATION: Lowered root burst from 32k to 15k to prevent Wi-Fi MAC layer bufferbloat
    tc class add dev $HOTSPOT_BR parent 2:  classid 2:1  htb rate $GLOBAL_RATE  burst 15k
    
    # Default unauth class with precise quantum
    tc class add dev $HOTSPOT_BR parent 2:1 classid 2:99 htb rate $UNAUTH_RATE  ceil $GLOBAL_RATE burst 4k quantum 1500
    # SFQ with low packet limit (12)
    tc qdisc add dev $HOTSPOT_BR parent 2:99 handle 299: sfq perturb 10 limit 12
    # PCQ Emulation: force unauth download SFQ to hash strictly by destination IP
    tc filter add dev $HOTSPOT_BR parent 299: protocol ip prio 1 flow hash keys dst perturb 10 divisor 1024 2>/dev/null

    # Apply anti-tethering filters after QoS resets
    case "${ANTI_TETHER:-0}" in 1|yes|true) setup_anti_tether ;; esac
}
# ============================================================
# SESSION MANAGEMENT (3-COLUMN AWARE)
# ============================================================

pause_session() {
    local mac=$1 expiry=$2 now=$3 total=$4 reason=${5:-Automatically}
    local remaining=$(( expiry - now ))
    [ "$remaining" -le 0 ] && return
    [ -z "$total" ] && total=$remaining

    iptables -t nat -D HOTSPOT -m mac --mac-source "$mac" -j RETURN 2>/dev/null
    iptables -t filter -D HOTSPOT_FWD -m mac --mac-source "$mac" -j ACCEPT 2>/dev/null

    _lock
    $BB grep -v "^$mac " "$SESSION_FILE" > "${SESSION_FILE}.tmp" 2>/dev/null
    $BB mv "${SESSION_FILE}.tmp" "$SESSION_FILE"

    if _users_file_stage_excl "$mac"; then
        echo "$mac paused $remaining $total $(_fmt_secs "$remaining")" >> "${USERS_FILE}.tmp"
        _users_file_commit
    fi
    _unlock

    $BB grep -v "^$mac " "$ACTIVITY_FILE" > /tmp/activity_pause.tmp 2>/dev/null
    $BB mv /tmp/activity_pause.tmp "$ACTIVITY_FILE"

    # Fire the "session paused" alert. Fire-and-forget (same pattern as the
    # expiry alert) so the watchdog never blocks on a network call. The
    # session_paused event key lets the admin mute just this alert from the
    # www2 UI. reason defaults to "Automatically" (inactivity timeout).
    #
    # Re-source templates right before rendering: this whole script (and its
    # TPL_* variables) is sourced ONCE when the watchdog forks at boot and
    # then lives for days in the background loop below. If the admin edits
    # a template in the www2 UI later, that only rewrites
    # notify_templates.env on disk — it doesn't touch this already-running
    # process's memory. Without this re-source, the daemon keeps using
    # whatever TPL_SESSION_PAUSED value it had at startup (a stale custom
    # value, or the built-in default) no matter what's saved afterward.
    [ -f /lmepisowifi/hotspot/notify_templates.sh ] && . /lmepisowifi/hotspot/notify_templates.sh
    _P_ACTIVE=$($BB grep -c '.' "$SESSION_FILE" 2>/dev/null)
    [ -n "$_P_ACTIVE" ] || _P_ACTIVE=0
    _P_MSG=$(tpl_render "$TPL_SESSION_PAUSED" \
        reason "$reason" \
        remainingtime "$(_fmt_secs "$remaining")" \
        totaltime "$(_fmt_secs "$total")" \
        mac "$mac" \
        activeusrcount "${_P_ACTIVE:-0}")
    ( /lmepisowifi/hotspot/notify.sh "$_P_MSG" "" session_paused "$mac" >/dev/null 2>&1 </dev/null & )
}

check_inactivity() {
    [ "${AUTO_PAUSE_ENABLED:-1}" = "1" ] || return
    [ -z "$INACTIVITY_TIMEOUT" ] && return
    [ "$INACTIVITY_TIMEOUT" -le 0 ] 2>/dev/null && return
    [ -f "$SESSION_FILE" ] || return

    local NOW mac expiry total pkts ul_pkts dl_pkts record last_pkts last_active inactive_for
    local TO_PAUSE entry FWD_DUMP client_ip is_alive cid
    NOW=$($BB awk '{print int($1)}' /proc/uptime)
    FWD_DUMP=$(iptables -t filter -L HOTSPOT_FWD -v -n 2>/dev/null)
    TO_PAUSE=""

    _lock
    while read -r mac expiry total; do
        [ -n "$mac" ] && [ -n "$expiry" ] || continue
        [ "$expiry" -gt "$NOW" ] || continue
        is_whitelisted "$mac" && continue

        # Upload-direction packets: HOTSPOT_FWD only sees traffic entering
        # FORWARD *from* the hotspot bridge (client -> WAN), so this counts
        # genuine uploads plus whatever ACKs a download happens to generate
        # - but a client that's purely downloading (e.g. a one-way UDP
        # stream, or just a download quiet enough that no ACK lands inside
        # a given 1s tick) can sit at a constant ul_pkts count while still
        # very much active. Add the per-client download leaf class's packet
        # counter too (set up by add_user_qos() on $HOTSPOT_BR, classid
        # 2:$cid - see the DOWNLOAD Leaf QoS section) so a single inbound
        # packet moves the total just as visibly as a single outbound one.
        ul_pkts=$(printf '%s' "$FWD_DUMP" | $BB grep -i "MAC $mac" | $BB awk 'NR==1{print $1+0}')
        [ -z "$ul_pkts" ] && continue

        client_ip=$(get_ip_for_mac "$mac")
        dl_pkts=0
        if [ -n "$client_ip" ]; then
            cid=$(ip_to_cid "$client_ip")
            if [ -n "$cid" ]; then
                dl_pkts=$(tc -s class show dev $HOTSPOT_BR classid 2:$cid 2>/dev/null \
                    | $BB awk '/^[[:space:]]*Sent/{print $4+0; exit}')
            fi
            [ -z "$dl_pkts" ] && dl_pkts=0
        fi
        pkts=$(( ul_pkts + dl_pkts ))

        record=$($BB grep "^$mac " "$ACTIVITY_FILE" 2>/dev/null)
        last_pkts=$(printf '%s' "$record" | $BB awk '{print $2}')
        last_active=$(printf '%s' "$record" | $BB awk '{print $3}')

        if [ -n "$last_pkts" ] && [ "$pkts" = "$last_pkts" ]; then
            last_active=${last_active:-$NOW}
            inactive_for=$(( NOW - last_active ))
            if [ "$inactive_for" -ge "$INACTIVITY_TIMEOUT" ]; then
                # No upload OR download packets for a full timeout window,
                # BUT that only proves the client isn't running any
                # data-hungry app right now (phone screen off, doze mode,
                # etc.) — it does NOT prove the client actually walked
                # away / disconnected. Before pausing, do a direct LAN-side
                # liveness probe (ARP reply / ICMP ping) to the client's own
                # IP. This checks the device's network stack directly, which
                # answers instantly even when no app is generating traffic,
                # so a device that is genuinely still connected won't get
                # falsely paused.
                is_alive=0
                if [ -n "$client_ip" ]; then
                    if $BB ping -c 1 -W 1 "$client_ip" >/dev/null 2>&1; then
                        is_alive=1
                    fi
                fi

                if [ "$is_alive" = "1" ]; then
                    # Still reachable on the LAN → treat as active, reset the
                    # inactivity clock (pkts unchanged, but last_active moves
                    # up to NOW) instead of pausing.
                    (
                        $BB grep -v "^$mac " "$ACTIVITY_FILE" 2>/dev/null
                        echo "$mac $pkts $NOW"
                    ) > /tmp/activity_upd.tmp
                    $BB mv /tmp/activity_upd.tmp "$ACTIVITY_FILE"
                else
                    [ -z "$total" ] && total=$(( expiry - NOW ))
                    TO_PAUSE="$TO_PAUSE ${mac}|${expiry}|${total}"
                fi
            fi
        else
            (
                $BB grep -v "^$mac " "$ACTIVITY_FILE" 2>/dev/null
                echo "$mac $pkts $NOW"
            ) > /tmp/activity_upd.tmp
            $BB mv /tmp/activity_upd.tmp "$ACTIVITY_FILE"
        fi
    done < "$SESSION_FILE"
    _unlock

    for entry in $TO_PAUSE; do
        mac=$(printf '%s' "$entry"   | $BB awk -F'|' '{print $1}')
        expiry=$(printf '%s' "$entry" | $BB awk -F'|' '{print $2}')
        total=$(printf '%s' "$entry" | $BB awk -F'|' '{print $3}')
        pause_session "$mac" "$expiry" "$NOW" "$total"
    done
}

write_coin_config() {
    mkdir -p /tmp/coin_sessions
    rm -f /tmp/coin_sessions/*.result /tmp/coin_sessions/* \
          /tmp/coin_lock /tmp/coin_lock_* /tmp/coin_strikes.txt \
          /tmp/coin_queue.txt /tmp/coin_queue_*.txt 2>/dev/null
    # Always write coin_config.env regardless of COIN_ENABLED so hotspot.cgi
    # can read and update all vars at runtime without restarting the script.
    {
        printf 'NODEMCU_IP="%s"\n'          "$NODEMCU_IP"
        printf 'NODEMCU_MAC="%s"\n'         "$NODEMCU_MAC"
        printf 'NODEMCU_PORT="%s"\n'        "$NODEMCU_PORT"
        printf 'COIN_PSK="%s"\n'            "$COIN_PSK"
        printf 'NODEMCU_1_TITLE="%s"\n'     "$NODEMCU_1_TITLE"
        printf 'NODEMCU_1_ENABLED="%s"\n'   "$NODEMCU_1_ENABLED"
        printf 'NODEMCU_EXTRA_FILE="%s"\n'  "$NODEMCU_EXTRA_FILE"
        printf 'COIN_TIMEOUT="%s"\n'        "$COIN_TIMEOUT"
        printf 'COIN_RATES="%s"\n'          "$COIN_RATES"
        printf 'COIN_STRIKE_THRESHOLD="%s"\n' "$COIN_STRIKE_THRESHOLD"
        printf 'COIN_COOLDOWN="%s"\n'       "$COIN_COOLDOWN"
        printf 'COIN_RECONNECT_GRACE="%s"\n' "$COIN_RECONNECT_GRACE"
        printf 'COIN_ENABLED="%s"\n'        "$COIN_ENABLED"
        printf 'HOTSPOT_BR="%s"\n'          "$HOTSPOT_BR"
        printf 'SESSION_FILE="%s"\n'        "$SESSION_FILE"
        printf 'PAUSED_FILE="%s"\n'         "$PAUSED_FILE"
        printf 'BB="%s"\n'                  "$BB"
        # QoS vars — also written so hotspot.cgi can update them live
        printf 'GLOBAL_RATE="%s"\n'         "$GLOBAL_RATE"
        printf 'PER_USER_RATE="%s"\n'       "$PER_USER_RATE"
        printf 'PER_USER_BURST="%s"\n'      "$PER_USER_BURST"
        printf 'UNAUTH_RATE="%s"\n'         "$UNAUTH_RATE"
        printf 'INACTIVITY_TIMEOUT="%s"\n'  "$INACTIVITY_TIMEOUT"
        printf 'AUTO_PAUSE_ENABLED="%s"\n'  "${AUTO_PAUSE_ENABLED:-1}"
        printf 'PORTAL_IP="%s"\n'           "$PORTAL_IP"
        printf 'PORTAL_PORT="%s"\n'         "$PORTAL_PORT"
        printf 'DHCP_START="%s"\n'          "$DHCP_START"
        printf 'DHCP_END="%s"\n'            "$DHCP_END"
        printf 'DHCP_DNS="%s"\n'            "$DHCP_DNS"
        printf 'ANTI_TETHER="%s"\n'         "${ANTI_TETHER:-0}"
        printf 'LAN_ISOLATE="%s"\n'         "${LAN_ISOLATE:-1}"
        printf 'MAC_RANDOMIZATION_FIX="%s"\n' "${MAC_RANDOMIZATION_FIX:-1}"
    } > /tmp/coin_config.env
    if [ "$COIN_ENABLED" = "1" ]; then
        touch /tmp/coin_enabled
    else
        rm -f /tmp/coin_enabled
    fi
}

# ============================================================
# redirect.sh (captive-portal 302 CGI) — SINGLE source of truth
# ------------------------------------------------------------
# Previously this file was generated in TWO places (initial startup and
# apply_portal_ip_change), which meant any hand-edited redirect.sh was
# clobbered on every boot / IP change. This helper is the only generator.
#
# The emitted script resolves the portal IP DYNAMICALLY at request time and,
# critically, NEVER produces an empty host: an empty Location host makes the
# browser re-request the same URL, causing ERR_TOO_MANY_REDIRECTS. The current
# PORTAL_IP/PORTAL_PORT/WWW2_PORT are baked in as the guaranteed last-resort
# fallback so the target is always a reachable portal address.
# ============================================================
write_redirect_cgi() {
    $BB mkdir -p /lmepisowifi/hotspot/cgi-bin
    # NB: unquoted heredoc — ${PORTAL_IP}/${PORTAL_PORT}/${WWW2_PORT} expand NOW
    # (baked defaults); every runtime CGI var is escaped as \$VAR.
    cat > /lmepisowifi/hotspot/cgi-bin/redirect.sh <<EOF
#!/bin/sh
# 404 handler + captive-portal redirector (dynamic IP, host-agnostic).
BB="busybox"
[ -f /tmp/coin_config.env ] && . /tmp/coin_config.env

# 1. patched httpd exports the local socket addr the client actually hit
_srv_ip="\$SERVER_ADDR"
_srv_port="\$SERVER_PORT"

# 2. fallback: ask the kernel which local IP faces this client
if [ -z "\$_srv_ip" ] && [ -n "\$REMOTE_ADDR" ]; then
    _srv_ip=\$(ip -4 route get "\$REMOTE_ADDR" 2>/dev/null \\
        | \$BB awk '{for(i=1;i<=NF;i++) if(\$i=="src"){print \$(i+1); exit}}')
fi

# 3. config override, then the baked-in portal IP
[ -z "\$_srv_ip" ] && _srv_ip="\${PORTAL_IP:-${PORTAL_IP}}"

# 4. HARD guarantee: never allow an empty host (empty host => redirect loop)
_srv_ip="\${_srv_ip:-${PORTAL_IP}}"
_srv_port="\${_srv_port:-\${PORTAL_PORT:-${PORTAL_PORT}}}"

case "\${REQUEST_URI%%\\?*}" in
    /admin|/admin/|/admin/*)
        _loc="http://\${_srv_ip}:${WWW2_PORT}/"
        ;;
    *)
        _cb="\$(\$BB date +%s)"
        _loc="http://\${_srv_ip}:\${_srv_port}/index.html?v=\${_cb}"
        ;;
esac

echo "Status: 302 Found"
echo "Location: \${_loc}"
echo "Content-Type: text/html"
echo "Cache-Control: no-cache, no-store"
echo "Pragma: no-cache"
echo "Connection: close"
echo ""
echo "<!DOCTYPE html><html><head>"
echo "<meta http-equiv=\\"refresh\\" content=\\"0;url=\${_loc}\\">"
echo "</head><body>"
echo "Redirecting to <a href=\\"\${_loc}\\">\${_loc}</a>..."
echo "</body></html>"
EOF
    $BB chmod +x /lmepisowifi/hotspot/cgi-bin/redirect.sh 2>/dev/null
}

# ============================================================
# PORTAL IP CHANGE — live apply without hotspot restart
# Called by the watchdog when /tmp/hotspot_portal_ip_reload appears.
# Rebuilds the bridge IP, firewall, DHCP, httpd, and redirect.sh
# to match the new PORTAL_IP (and optionally PORTAL_PORT).
# ============================================================
apply_portal_ip_change() {
    local new_ip="$1" new_port="${2:-$PORTAL_PORT}"
    # old_ip/old_port are passed explicitly by the caller (3rd/4th args) when
    # available. Do NOT fall back to reading $PORTAL_IP/$PORTAL_PORT here as
    # the "current" value — the watchdog loop re-sources /tmp/coin_config.env
    # every tick (which hotspot.cgi's save_coin_env_var already updated to
    # the NEW port before this function runs), so by the time we get here
    # those globals may already equal new_ip/new_port. Trusting them for
    # "old" would make the old-httpd kill below a no-op and leak a stray
    # busybox httpd bound to the previous port forever.
    local old_ip="${3:-$PORTAL_IP}" old_port="${4:-$PORTAL_PORT}"
    local old_subnet new_subnet _pb

    old_subnet=$(cat /tmp/hotspot_subnet.mark 2>/dev/null)
    [ -z "$old_subnet" ] && old_subnet=$(printf '%s' "$old_ip" | $BB sed 's/\.[^.]*$/.0\/24/')
    new_subnet=$(printf '%s' "$new_ip" | $BB sed 's/\.[^.]*$/.0\/24/')

    # 1. Update in-memory variables (watchdog will use them immediately)
    PORTAL_IP="$new_ip"
    PORTAL_PORT="$new_port"

    # 2. Reconfigure the bridge interface to the new gateway IP
    ifconfig "$HOTSPOT_BR" "$PORTAL_IP" netmask 255.255.255.0 up 2>/dev/null

    # 3. Tear down old firewall INPUT rate-limit rules (port-specific)
    iptables -t filter -D INPUT -p tcp --dport "$old_port" \
        -m state --state NEW -m comment --comment "lmehspt_ratelimit" -j DROP 2>/dev/null
    iptables -t filter -D INPUT -p tcp --dport "$old_port" \
        -m state --state NEW -j DROP 2>/dev/null
    iptables -t filter -D INPUT -p tcp --dport "$old_port" \
        -m state --state NEW -m limit --limit 20/sec --limit-burst 40 -m comment --comment "lmehspt_ratelimit" -j ACCEPT 2>/dev/null
    iptables -t filter -D INPUT -p tcp --dport "$old_port" \
        -m state --state NEW -m limit --limit 20/sec --limit-burst 40 -j ACCEPT 2>/dev/null

    # 4. Tear down old NAT chains (flush + delete so setup_firewall can recreate)
    iptables -t nat -D PREROUTING -i "$HOTSPOT_BR" -j HOTSPOT 2>/dev/null
    iptables -t nat -F HOTSPOT 2>/dev/null
    iptables -t nat -X HOTSPOT 2>/dev/null
    iptables -t nat -D POSTROUTING -s "$old_subnet" -j MASQUERADE 2>/dev/null

    # 5. Tear down old filter chain
    iptables -t filter -D FORWARD -i "$HOTSPOT_BR" -j HOTSPOT_FWD 2>/dev/null
    iptables -t filter -F HOTSPOT_FWD 2>/dev/null
    iptables -t filter -X HOTSPOT_FWD 2>/dev/null

    # 6. Rebuild firewall for new IP/port (writes new subnet marker)
    setup_firewall
    restore_fw_sessions
    setup_whitelist

    # 7. Restart DHCP with new pool.
    #    Only wipe the lease file when the pool itself changed (new_subnet
    #    != old_subnet). A port-only change -- or any change that leaves
    #    the /24 the same -- means every lease already in that file is
    #    still valid; deleting it would forget currently-connected clients
    #    and let the fresh udhcpd hand their in-use IP to someone else.
    [ -f /tmp/hotspot_dhcp.pid ] && { kill -9 "$(cat /tmp/hotspot_dhcp.pid)" 2>/dev/null; rm -f /tmp/hotspot_dhcp.pid; }
    for _pid in $($BB ps ww | $BB grep "hotspot_dhcp.conf" | $BB grep -v grep | $BB awk '{print $1}'); do
        kill -9 "$_pid" 2>/dev/null
    done
    [ "$new_subnet" != "$old_subnet" ] && rm -f /tmp/udhcpd.leases
    start_dhcp

    # 8. Restart captive-portal httpd on new IP:port
    # Match on the hotspot's httpd.conf rather than just "$old_ip:$old_port" —
    # that string can be stale (see comment above old_ip/old_port) and would
    # silently fail to match, leaving the previous instance running forever.
    # Killing every hotspot-portal httpd NOT bound to the new address is
    # self-healing: it also mops up any stray instance left behind by a
    # prior occurrence of that bug, without needing a reboot.
    for _pid in $($BB ps ww | $BB grep httpd | $BB grep -v grep | $BB grep -F "hotspot/httpd.conf" | $BB grep -v -F "$PORTAL_IP:$PORTAL_PORT" | $BB awk '{print $1}'); do
        kill -9 "$_pid" 2>/dev/null
    done
    ensure_port80_clear
    $BB httpd -p "$PORTAL_IP:$PORTAL_PORT" -h /lmepisowifi/hotspot \
        -c /lmepisowifi/hotspot/httpd.conf 2>/dev/null
    $BB chmod +x /lmepisowifi/hotspot/cgi-bin/*.sh 2>/dev/null

    # 9. Regenerate redirect.sh with the new portal URL (single source of truth)
    write_redirect_cgi

    # 10. Refresh coin_config.env so coin.sh picks up new IP
    write_coin_config
}


# Runs busybox ntpd as a CLIENT daemon. Its -S handler maintains
# /tmp/ntp_synced so income.sh can tell when the clock is genuinely
# synchronized before trusting the date for period resets.
# Client mode routes out the WAN default route (br0) automatically — we
# deliberately do NOT pass -I (that would turn ntpd into a SERVER bound
# to the interface and listen on UDP/123).
# ============================================================
start_ntp() {
    # NTP must only run while the hotspot is enabled. The watchdog that calls
    # this only exists when HOTSPOT_ENABLED=1, but re-check here so a runtime
    # toggle to 0 (written into coin_config.env and re-sourced each tick) stops
    # us from reviving ntpd for a disabled hotspot.
    [ "${HOTSPOT_ENABLED:-1}" = "1" ] || return 0

    # Ensure DNS resolution is healthy before starting or checking ntpd
    check_and_fix_dns

    # Don't spawn a second instance (avoids two daemons fighting over the clock).
    # We use ps | grep here because BusyBox pidof fails to find ntpd when run via the multicall binary.
    $BB ps ww | $BB grep "ntpd -S" | $BB grep -v grep >/dev/null 2>&1 && return 0
    [ -x "$NTP_EVENT" ] || $BB chmod +x "$NTP_EVENT" 2>/dev/null
    NTP_PEERS=""
    for s in $NTP_SERVERS; do NTP_PEERS="$NTP_PEERS -p $s"; done
    [ -n "$NTP_PEERS" ] || return 0

    # NOTE: we deliberately do NOT pass -N. On this RTL9607C busybox build the
    # high-priority -N flag needs CAP_SYS_NICE; without it ntpd aborts at launch
    # and no daemon is left running (the reported `ps | grep ntp` showed none).
    # No -n  -> ntpd daemonizes itself; no -I -> client mode (routes out the WAN
    # default route, never binds UDP/123 as a server). -S handler maintains the
    # /tmp/ntp_synced marker income.sh relies on. We still background + disown
    # the call and confirm a pid appeared, retrying once, so a transient failure
    # to fork doesn't silently leave income resets paused forever.
    _try=0
    while [ "$_try" -lt 2 ]; do
        ( $BB ntpd -S "$NTP_EVENT" $NTP_PEERS >/dev/null 2>&1 & )
        $BB sleep 1
        $BB ps ww | $BB grep "ntpd -S" | $BB grep -v grep >/dev/null 2>&1 && return 0
        _try=$(( _try + 1 ))
    done
    return 1
}

# Guard: if the admin UI stopped the hotspot, exit without starting.
# Default is "1" (missing var → start normally) so the very first run,
# before the admin page has ever saved anything, still works.
if [ "${HOTSPOT_ENABLED:-1}" != "1" ] && [ "$1" != "--force" ] && [ -z "$LMEHSPT_LIB_ONLY" ]; then
    exit 0
fi

if [ -z "$LMEHSPT_LIB_ONLY" ]; then
wait_for_wlan_ready
cleanup_old_hotspot


if [ ! -f "$BOOT_MARKER" ]; then
    touch "$SESSION_FILE" 2>/dev/null
    _lock
    restore_users_file_from_backup
    restore_income_file_from_backup
    sync_to_persistent_db
    sync
    backup_users_file
    backup_income_file
    sync
    _unlock
    touch "$BOOT_MARKER"
fi

(
    cd /lmepisowifi/hotspot

    # OS captive-portal probe paths must be served by busybox httpd.
    # BusyBox httpd only executes CGI when the URL path starts with /cgi-bin/
    # or matches a file-extension interpreter mapping in httpd.conf.
    # Probe paths like /generate_204, /ncsi.txt, /hotspot-detect.html have
    # fixed names dictated by each OS — we cannot make busybox execute them
    # as CGI.  Symlinks to index.html are the correct approach: unauthenticated
    # probe requests hit the captive portal page (which causes the OS popup);
    # authenticated MACs have an iptables nat RETURN rule that bypasses DNAT
    # entirely, so their probes go directly to the real internet and get the
    # correct 204/Success response there. detect.sh (an earlier, MAC/session-aware
    # take on this same redirect) was removed — 404to302 + redirect.sh below
    # is the actual, simpler path every unauthenticated probe hits in production.

    # Create the 302 redirect CGI script (single source of truth). This is the
    # magic that reliably triggers the "Sign in to network" prompt for any
    # arbitrary OS probe path by returning a standard HTTP 302 Found status code.
    write_redirect_cgi

    # Create httpd.conf.
    #
    # Primary path (custom "404to302" directive, added via our httpd.c patch):
    # for ANY unknown/not-found URL the patched httpd emits a real "302 Found"
    # with "Location: /cgi-bin/redirect.sh" directly from send_headers(), before
    # it would ever try to serve an error-page body. The browser then makes an
    # ordinary (non-error) GET to /cgi-bin/redirect.sh, which BusyBox executes as
    # CGI and which resolves the real portal IP (SERVER_ADDR) and answers with the
    # final 302 to the splash page. A relative "/cgi-bin/redirect.sh" is used on
    # purpose so nothing here is tied to PORTAL_IP/port (no regeneration on IP
    # change); redirect.sh itself supplies the absolute, host-correct target.
    #
    # Fallback path (E404): on an UNPATCHED busybox build the 404to302 line is an
    # unknown directive and is simply ignored, so E404 still serves the tiny
    # static redirect.html (whose meta-refresh/JS hits the same CGI). E404 must
    # point at a static file, not a CGI, because an unpatched build would serve a
    # CGI error target as raw source. On a patched build E404 stays dormant
    # because the 404 is turned into a 302 before any error page is considered.
cat > httpd.conf <<'EOF'
404to302:cgi-bin/redirect.sh
EOF


    # Static E404 target referenced above. Kept host-agnostic (relative URL,
    # no embedded PORTAL_IP/port) so it never needs regenerating on a live
    # portal IP/port change (see apply_portal_ip_change). The meta-refresh +
    # JS both fire an ordinary (non-error) GET to /cgi-bin/redirect.sh, which
    # BusyBox executes as CGI and answers with the real 302 Found.

    # /admin -> www2 admin UI. Served as a real static page (not a 404), so it

    # /admin -> www2 admin UI. Served as a real static page (not a 404), so it
    # works even on busybox builds that don't run the E404 CGI. The target host
    # is resolved client-side from the address the visitor actually used
    # (location.hostname), so the portal IP is never hardcoded here; only the
    # www2 port (${WWW2_PORT}) is baked in. A meta-refresh + link fallback (using
    # the configured PORTAL_IP) covers the rare no-JavaScript case.
    $BB mkdir -p admin
    cat > admin/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Admin</title>
<script>
(function(){
  var h = location.hostname || "${PORTAL_IP}";
  location.replace(location.protocol + "//" + h + ":${WWW2_PORT}/");
})();
</script>
<meta http-equiv="refresh" content="1;url=http://${PORTAL_IP}:${WWW2_PORT}/">
</head>
<body style="font-family:sans-serif;text-align:center;margin-top:3em">
Redirecting to the admin dashboard&hellip;
<p><a id="l" href="http://${PORTAL_IP}:${WWW2_PORT}/">Continue</a></p>
<script>
(function(){
  var h = location.hostname || "${PORTAL_IP}";
  document.getElementById("l").href = location.protocol + "//" + h + ":${WWW2_PORT}/";
})();
</script>
</body>
</html>
EOF
)

setup_network
setup_firewall
restore_fw_sessions
setup_whitelist
start_dhcp
WAN_INT=$(resolve_wan_int)
setup_qos
write_coin_config
check_and_fix_dns
start_ntp

if ! $BB ps ww | $BB grep "httpd" | $BB grep -v grep | $BB grep -q -F "$PORTAL_IP:$PORTAL_PORT"; then
    ensure_port80_clear
    $BB httpd -p $PORTAL_IP:$PORTAL_PORT -h /lmepisowifi/hotspot -c /lmepisowifi/hotspot/httpd.conf
    $BB chmod +x /lmepisowifi/hotspot/cgi-bin/*.sh
fi

( 
    LAST_SNAPSHOT=0
    LAST_QOS_SYNC=0
    LAST_INCOME=0
    LAST_PORT80_SCAN=0
    while true; do
        # Re-source the runtime config every tick so config_set / qos_apply
        # changes take effect without a hotspot restart.
        # INACTIVITY_TIMEOUT is read by check_inactivity() each call.
        # Rate vars (GLOBAL_RATE etc.) are used by setup_qos on the next
        # self-heal trigger, which fires within 1s of the root qdisc being removed.
        [ -f /tmp/coin_config.env ] && . /tmp/coin_config.env

        # QoS reload requested by hotspot.cgi (qos_apply action).
        # This is safer than letting the CGI delete qdiscs directly because
        # the watchdog knows the correct WAN_INT (may differ from br0 if
        # the repurpose-as-WAN feature is active).
        if [ -f /tmp/hotspot_qos_reload ]; then
            rm -f /tmp/hotspot_qos_reload
            setup_qos
            restore_qos_sessions
        fi

        # Portal IP/port change requested by hotspot.cgi (ifaces_set action).
        # apply_portal_ip_change() rebuilds bridge IP, firewall, DHCP, httpd,
        # and redirect.sh atomically without requiring a full hotspot restart.
        if [ -f /tmp/hotspot_portal_ip_reload ]; then
            rm -f /tmp/hotspot_portal_ip_reload
            _new_pip=$(cat /tmp/hotspot_portal_ip_new 2>/dev/null)
            _new_ppt=$(cat /tmp/hotspot_portal_port_new 2>/dev/null)
            _old_pip=$(cat /tmp/hotspot_portal_ip_old 2>/dev/null)
            _old_ppt=$(cat /tmp/hotspot_portal_port_old 2>/dev/null)
            rm -f /tmp/hotspot_portal_ip_new /tmp/hotspot_portal_port_new \
                  /tmp/hotspot_portal_ip_old /tmp/hotspot_portal_port_old
            [ -n "$_new_pip" ] && apply_portal_ip_change "$_new_pip" "${_new_ppt:-$PORTAL_PORT}" "$_old_pip" "$_old_ppt"
        fi

        # DHCP range / DNS change requested by hotspot.cgi (dhcp_set action)
        # that did NOT move the gateway (a gateway move goes through the
        # portal_ip_reload path above, which restarts DHCP itself). Rebuild the
        # lease pool in place: DHCP_START/DHCP_END/DHCP_DNS were already
        # re-sourced from coin_config.env at the top of this tick. The lease DB
        # is wiped because the pool boundaries moved - keeping stale leases could
        # hand an in-pool address to a client now outside it, or collide with a
        # NodeMCU static lease.
        if [ -f /tmp/hotspot_dhcp_reload ]; then
            rm -f /tmp/hotspot_dhcp_reload
            [ -f /tmp/hotspot_dhcp.pid ] && { kill -9 "$(cat /tmp/hotspot_dhcp.pid)" 2>/dev/null; rm -f /tmp/hotspot_dhcp.pid; }
            for _pid in $($BB ps ww | $BB grep "hotspot_dhcp.conf" | $BB grep -v grep | $BB awk '{print $1}'); do
                kill -9 "$_pid" 2>/dev/null
            done
            rm -f /tmp/udhcpd.leases
            start_dhcp
            # Nudge every NodeMCU to re-DHCP now so a moved pool (new static
            # IPs) takes effect immediately instead of at its next lease renewal.
            [ -n "$NODEMCU_MAC" ] && kick_sta_mac "$NODEMCU_MAC"
            if [ -f "$NODEMCU_EXTRA_FILE" ]; then
                while IFS='|' read -r _dnid _dnt _dnip _dnmac _dnp _dnk _dne; do
                    case "$_dnid" in ''|*[!0-9]*) continue ;; esac
                    [ -n "$_dnmac" ] && kick_sta_mac "$_dnmac"
                done < "$NODEMCU_EXTRA_FILE"
            fi
        fi

        # Anti-tether hot-toggle: if ANTI_TETHER changed since last tick, apply.
        _at_want="${ANTI_TETHER:-0}"
        if [ "${_at_last:-}" != "$_at_want" ]; then
            _at_last="$_at_want"
            teardown_anti_tether 2>/dev/null
            case "$_at_want" in 1|yes|true) setup_anti_tether ;; esac
        fi

        # LAN isolation hot-toggle: if LAN_ISOLATE changed since last tick, apply.
        _li_want="${LAN_ISOLATE:-1}"
        if [ "${_li_last:-unset}" != "$_li_want" ]; then
            _li_last="$_li_want"
            # Tear down first (clean slate regardless of new state)
            _old_lan=$(cat /tmp/hotspot_lan_isolate.mark 2>/dev/null)
            [ -n "$_old_lan" ] && iptables -t filter -D FORWARD -i $HOTSPOT_BR -d "$_old_lan" -j DROP 2>/dev/null
            rm -f /tmp/hotspot_lan_isolate.mark
            for _priv_net in $LAN_ISOLATE_PRIVATE_NETS; do
                iptables -t filter -D FORWARD -i $HOTSPOT_BR -d "$_priv_net" -j DROP 2>/dev/null
            done
            iptables -t filter -D INPUT -i $HOTSPOT_BR -p tcp --dport $WWW2_PORT -j ACCEPT 2>/dev/null
            case "$_li_want" in
            1|yes|true)
                _lan_gw=$(resolve_br0_gateway)
                _lan_subnet=$(printf '%s' "$_lan_gw" | $BB sed 's/\.[^.]*$/.0\/24/')
                iptables -t filter -I FORWARD 1 -i $HOTSPOT_BR -d "$_lan_subnet" -j DROP
                printf '%s\n' "$_lan_subnet" > /tmp/hotspot_lan_isolate.mark
                for _priv_net in $LAN_ISOLATE_PRIVATE_NETS; do
                    iptables -t filter -I FORWARD 1 -i $HOTSPOT_BR -d "$_priv_net" -j DROP
                done
                iptables -t filter -I INPUT 1 -i $HOTSPOT_BR -p tcp --dport $WWW2_PORT -j ACCEPT
                ;;
            esac
        fi

        # Re-evaluate upstream interface (repurpose may have been toggled)
        _new_wan=$(resolve_wan_int)
        if [ "$_new_wan" != "$WAN_INT" ]; then
            tc qdisc del dev "$WAN_INT" root 2>/dev/null
            WAN_INT="$_new_wan"
            setup_qos
            restore_qos_sessions
        fi

        # Normalise rate variables (handles bare m/k/g and mbps/kbps suffixes)
        GLOBAL_RATE=$(_norm_rate "$GLOBAL_RATE")
        PER_USER_RATE=$(_norm_rate "$PER_USER_RATE")
        UNAUTH_RATE=$(_norm_rate "$UNAUTH_RATE")

        need_setup=0
        for iface in $HOTSPOT_INTERFACES; do
            iface_in_bridge "$iface" || need_setup=1
        done
        # Reverse check: an interface still enslaved in HOTSPOT_BR that was
        # removed from HOTSPOT_INTERFACES (unbound). The loop above only
        # ever catches interfaces missing FROM the bridge, so a pure removal
        # would otherwise never trigger setup_network at all.
        for ifpath in /sys/class/net/"$HOTSPOT_BR"/brif/*; do
            [ -e "$ifpath" ] || continue
            bm=$($BB basename "$ifpath")
            case " $HOTSPOT_INTERFACES " in
                *" $bm "*) ;;
                *) need_setup=1 ;;
            esac
        done
        [ "$need_setup" = "1" ] && setup_network

        if ! iptables -t nat -L HOTSPOT -n >/dev/null 2>&1 || ! iptables -t filter -L HOTSPOT_FWD -n >/dev/null 2>&1; then
            setup_firewall
            restore_fw_sessions
            setup_whitelist
        fi

        if ! $BB ps ww | $BB grep -v grep | $BB grep -q "hotspot_dhcp.conf"; then start_dhcp; fi
        if ! tc qdisc show dev $WAN_INT 2>/dev/null | $BB grep -q "sfq\|htb"; then
            setup_qos
            restore_qos_sessions   # immediately re-add per-user classes so active
                                   # sessions aren't stuck in the unauth bucket
        fi

        # Runtime self-heal: if users.txt was ever found empty/missing (e.g.
        # a lock race let two writers stomp its .tmp file), restore it from
        # the last good generation immediately instead of leaving every
        # paused/active entry lost until the box is next rebooted (the boot
        # sequence above only ever runs this once, at startup). Safe to call
        # every ~1s loop tick: _restore_from_backup's very first check is
        # `[ -s "$live" ] && return 0`, so this is a no-op on the healthy path.
        _lock
        restore_users_file_from_backup
        _unlock

        if [ -f "$SESSION_FILE" ]; then
            NOW=$($BB awk '{print int($1)}' /proc/uptime)
            _SES_TMP="${SESSION_FILE}.tmp"
            > "$_SES_TMP"
            
            _lock
            while read -r mac expiry total; do
                if [ -n "$mac" ] && [ -n "$expiry" ]; then
                    if [ "$NOW" -gt "$expiry" ]; then
                        iptables -t nat -D HOTSPOT -m mac --mac-source "$mac" -j RETURN 2>/dev/null
                        iptables -t filter -D HOTSPOT_FWD -m mac --mac-source "$mac" -j ACCEPT 2>/dev/null
                        $BB grep -v "^$mac " "$ACTIVITY_FILE" > /tmp/activity_exp.tmp 2>/dev/null
                        $BB mv /tmp/activity_exp.tmp "$ACTIVITY_FILE" 2>/dev/null
                        del_user_qos "$mac"
                        
                        _users_file_replace_excl "$mac"
                        
                        # See pause_session()'s identical comment: re-source
                        # so this long-running watchdog picks up template
                        # edits made via the www2 UI after it started.
                        [ -f /lmepisowifi/hotspot/notify_templates.sh ] && . /lmepisowifi/hotspot/notify_templates.sh
                        _exp_active=$($BB grep -c '.' "$SESSION_FILE" 2>/dev/null)
                        [ -n "$_exp_active" ] || _exp_active=0
                        _exp_msg=$(tpl_render "$TPL_SESSION_EXPIRED" \
                            mac "$mac" \
                            activeusrcount "$_exp_active")
                        ( /lmepisowifi/hotspot/notify.sh "$_exp_msg" "" session_expired >/dev/null 2>&1 </dev/null & )
                    else
                        [ -z "$total" ] && total=$(( expiry - NOW ))
                        echo "$mac $expiry $total" >> "$_SES_TMP"
                    fi
                fi
            done < "$SESSION_FILE"
            $BB mv "$_SES_TMP" "$SESSION_FILE"
            _unlock
        fi

        check_inactivity

        NOW=$($BB awk '{print int($1)}' /proc/uptime)
        if [ $((NOW - LAST_SNAPSHOT)) -ge 300 ]; then
            _lock
            sync_to_persistent_db
            sync
            backup_users_file
            backup_income_file
            sync
            _unlock
            LAST_SNAPSHOT=$NOW
        fi

        if [ $((NOW - LAST_QOS_SYNC)) -ge 30 ]; then
            _lock
            restore_qos_sessions
            _unlock
            LAST_QOS_SYNC=$NOW
        fi

        # Every 60s, keep the NTP client alive and poke income.sh so the
        # daily/monthly/yearly buckets roll over (and rollover reports fire)
        # at the period boundary even with no coin activity. income.sh only
        # writes flash when something changes, and only resets once NTP has
        # genuinely synced the clock.
        if [ $((NOW - LAST_INCOME)) -ge 60 ]; then
            start_ntp
            /lmepisowifi/hotspot/income.sh get >/dev/null 2>&1
            # Drain queued notifications now that we have a periodic internet check
            ( /lmepisowifi/hotspot/notify.sh --drain >/dev/null 2>&1 </dev/null & )
            LAST_INCOME=$NOW
        fi

        # Port 80 watchdog — only relevant while PORTAL_PORT="80". Throttled
        # like the other periodic maintenance above since it's a safety net
        # (the real-time triggers are the explicit calls at hotspot startup
        # and on a live portal-port change); boa respawning mid-session is
        # an edge case, not something that needs sub-second reaction time.
        if [ "$PORTAL_PORT" = "80" ] && [ $((NOW - LAST_PORT80_SCAN)) -ge 10 ]; then
            ensure_port80_clear
            LAST_PORT80_SCAN=$NOW
        fi

        # Default route watchdog: if vendor firmware (nas*, etc.) steals the
        # default route, restore it so hotspot clients keep internet access.
        _ww=$(resolve_wan_int)
        if [ "$_ww" != "$WAN_INT_DEFAULT" ]; then
            # Repurpose mode: use the gateway learned by udhcpc
            _ww_gw_f="/tmp/repurpose_gw_${_ww}"
            [ -f "$_ww_gw_f" ] && _ww_gw=$($BB tr -d '\r\n' < "$_ww_gw_f" 2>/dev/null)
        else
            _ww_gw="$(resolve_br0_gateway)"
        fi
        if [ -n "$_ww_gw" ]; then
            _cur_def=$(ip route show default 2>/dev/null | head -1)
            case "$_cur_def" in
                *"dev $_ww"*) ;; # correct interface — leave it alone
                *)
                    ip route del default 2>/dev/null
                    ip route add default via "$_ww_gw" dev "$_ww" 2>/dev/null
                    ;;
            esac
        fi

        $BB sleep 1
    done
) &
echo $! > /tmp/hotspot_watchdog.pid
fi # end LMEHSPT_LIB_ONLY guard — nothing below this line runs in --lib moded
