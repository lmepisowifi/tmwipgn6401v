#!/bin/sh
(
    # --- STEP 1: Wait for /lmepisowifi/ to be writable ---
    while [ ! -w "/lmepisowifi" ]; do
        sleep 2
    done
    # --- STEP 1.1: Save MAC Address and SN ---
    [ ! -d /lmepisowifi/httpd/configdefault ] && mkdir -p /lmepisowifi//httpd/configdefault
    [ ! -f /lmepisowifi/httpd/configdefault/mac.txt ] && flash get ELAN_MAC_ADDR | awk -F'=' '{print $2}' > /lmepisowifi/httpd/configdefault/mac.txt
    [ ! -f /lmepisowifi/httpd/configdefault/sn.txt ] && flash get GPON_SN | awk -F'=' '{print $2}' > /lmepisowifi//httpd/configdefault/sn.txt
    [ ! -f /lmepisowifi/httpd/configdefault/version.txt ] && cp /etc/version /lmepisowifi/httpd/configdefault/version.txt
    # neutralize the aclblock and ipfilter causing www2 & hotspot issues in pgn6401v
    iptables -t filter -F aclblock
iptables -t filter -A aclblock -j ACCEPT
iptables -t filter -F ipfilter
iptables -t filter -A ipfilter -j ACCEPT

    # --- STEP 1.2: Run custom admin scripts ---
    if [ -f /lmepisowifi/httpd/run_admin.sh ]; then
        chmod +x /lmepisowifi/httpd/run_admin.sh
        /lmepisowifi/httpd/run_admin.sh
    fi
    if [ -f /lmepisowifi/httpd/run_adminhidden.sh ]; then
        chmod +x /lmepisowifi/httpd/run_adminhidden.sh
        /lmepisowifi/httpd/run_adminhidden.sh
    fi

    # --- STEP 1.3: Restore version.txt bind mount if modified ---
    if [ -f /lmepisowifi/httpd/version.txt ]; then
        grep -q '/etc/version' /proc/mounts || mount --bind /lmepisowifi/httpd/version.txt /etc/version
    fi

    # --- STEP 1.4: Block HTTP from WAN ---
    iptables -I INPUT ! -i br0 -p tcp --dport 80 -j DROP 2>/dev/null
    

    # --- STEP 1.5: Start boa from custom httpd ---
    killall -9 boa
    boa -c /lmepisowifi/httpd &
    sleep 1
    busybox httpd -h /lmepisowifi/www2 -p 8080
    # Hotspot is now an installable module (see module_ctl.sh + the www2
    # Modules page). reconcile enforces the saved install/uninstall state and,
    # on the first boot after this update, migrates an existing built-in
    # hotspot to "installed" so nothing changes for current operators. Only
    # launch the hotspot controller when the module is installed.
    chmod +x /lmepisowifi/module_ctl.sh 2>/dev/null
    /lmepisowifi/module_ctl.sh reconcile >/dev/null 2>&1
    # Fail-safe default: a device that reboots before ota.sh's self-heal has
    # restored a missing module_ctl.sh (see ensure_module_ctl in ota.sh) can't
    # ask it anything here — treat that as "start hotspot," not "don't," same
    # default module_ctl.sh's own migrate_installed() uses for an existing
    # install. A real uninstall can only happen through module_ctl.sh, so if
    # hotspot was ever genuinely uninstalled, module_ctl.sh necessarily exists
    # and this still defers to its actual answer below.
    if [ ! -x /lmepisowifi/module_ctl.sh ] || /lmepisowifi/module_ctl.sh is-active hotspot >/dev/null 2>&1; then
        chmod +x /lmepisowifi/lmehspt.sh 2>/dev/null
        [ -x /lmepisowifi/lmehspt.sh ] && /lmepisowifi/lmehspt.sh &
    fi
    chmod +x /lmepisowifi/www2/sh/startup.sh
    /lmepisowifi/www2/sh/startup.sh &

    # --- STEP 1.5b: Replay power-outage coin sessions ---
    # A Piso-Wifi unit and its coin slot share a power brick, so a blackout kills
    # both mid-session. The NodeMCU is now stateless (it no longer wears out its
    # flash mirroring coins), so the router owns crash recovery: coin.sh mirrors
    # each PSK-verified poll total to the non-volatile partition below (since
    # /tmp is tmpfs and dies in a blackout). On boot we grant the customer the
    # time they already paid for by re-running coin_result.sh's exact grant logic
    # locally, then drop the mirror. Backgrounded so it can wait for lmehspt.sh
    # to (re)publish /tmp/coin_config.env — which holds COIN_PSK, needed to sign
    # the grant — after that script's boot-time wipe of /tmp/coin_sessions.
    (
        COIN_PENDING_DIR="/lmepisowifi/hotspot_data/coin_pending"
        [ -d "$COIN_PENDING_DIR" ] || exit 0

        # Wait (up to ~90s) for lmehspt.sh to publish the runtime coin config.
        i=0
        while [ ! -f /tmp/coin_config.env ] && [ "$i" -lt 90 ]; do
            sleep 1
            i=$((i + 1))
        done
        [ -f /tmp/coin_config.env ] || exit 0
        . /tmp/coin_config.env
        [ -n "$COIN_PSK" ] || exit 0

        # PSK for a given node id — mirrors coin.sh/coin_result.sh's
        # _node_field lookup, just scoped to the one column this loop needs.
        _node_psk() {
            if [ "$1" = "1" ] || [ -z "$1" ]; then
                printf '%s' "$COIN_PSK"
                return
            fi
            [ -n "$NODEMCU_EXTRA_FILE" ] && [ -f "$NODEMCU_EXTRA_FILE" ] || return 0
            awk -F'|' -v id="$1" '$1==id {print $6; exit}' "$NODEMCU_EXTRA_FILE"
        }

        for f in "$COIN_PENDING_DIR"/*; do
            [ -f "$f" ] || continue          # empty dir → literal glob, skip
            case "$f" in *.tmp) continue ;; esac  # skip half-written mirrors

            # Mirror format written by coin.sh: "SID MAC AMOUNT CREATED_AT NODE_ID"
            # (NODE_ID is a coin.sh addition — a mirror from before that field
            # existed only has 4 words, so P_NODE reads back empty and the
            # fallback below treats it as the primary, exactly as it always
            # implicitly was.)
            read -r P_SID P_MAC P_AMOUNT P_CREATED P_NODE < "$f"
            P_NODE="${P_NODE:-1}"

            # Validate the mirrored fields before trusting them; drop junk.
            printf '%s' "$P_SID"    | grep -qE '^[0-9a-f]{16}$'  || { rm -f "$f"; continue; }
            printf '%s' "$P_MAC"    | grep -qE '^[0-9a-f:]{17}$' || { rm -f "$f"; continue; }
            printf '%s' "$P_AMOUNT" | grep -qE '^[0-9]+$'        || { rm -f "$f"; continue; }
            [ "${P_AMOUNT:-0}" -gt 0 ] || { rm -f "$f"; continue; }

            P_PSK=$(_node_psk "$P_NODE")
            [ -n "$P_PSK" ] || P_PSK="$COIN_PSK"   # unknown/removed node id → best-effort fallback

            # Sign exactly as the NodeMCU recovery POST did:
            #   sig = md5(PSK:SID:AMOUNT:MAC:recover)
            # coin_result.sh re-verifies this (defense in depth) and clears the
            # mirror itself on a successful/duplicate grant.
            P_SIG=$(printf '%s' "${P_PSK}:${P_SID}:${P_AMOUNT}:${P_MAC}:recover" \
                    | md5sum | awk '{print $1}')

            # Reuse coin_result.sh's grant/extend logic via a direct LOCAL exec
            # (not HTTP). REMOTE_ADDR is empty for a local root invocation, which
            # is exactly what its boot-replay guard requires — a network caller
            # can neither blank REMOTE_ADDR nor set COIN_BOOT_REPLAY.
            COIN_BOOT_REPLAY=1 REMOTE_ADDR="" \
            SID="$P_SID" AMOUNT="$P_AMOUNT" SIG="$P_SIG" RECOVER_MAC="$P_MAC" NODE_ID="$P_NODE" \
                /bin/sh /lmepisowifi/hotspot/cgi-bin/coin_result.sh >/dev/null 2>&1

            # Safety net: if coin_result.sh couldn't clear it (e.g. a transient
            # failure) the mirror stays and is retried on the next boot. A
            # successful grant already removed it, so this is a no-op then.
        done
    ) &

    # --- STEP 1.6: Start crond ---
    # /etc/crontabs is on the read-only squashfs rootfs, so crond is pointed
    # at /config/crontabs instead (writable, persists across reboots).
    # The OTA update check (a long, fixed 6h interval, stateless check) is
    # scheduled here instead of a hand-rolled sleep-loop. Written once;
    # the BEGIN/END marker guards against duplicating the line on every boot.
    mkdir -p /config/crontabs
    touch /config/crontabs/root
    if ! busybox grep -q '^# --- BEGIN_OTA_CRON ---$' /config/crontabs/root 2>/dev/null; then
        {
            echo "# --- BEGIN_OTA_CRON ---"
            echo "0 */6 * * * [ -x /lmepisowifi/ota.sh ] && /lmepisowifi/ota.sh cron >/dev/null 2>&1"
            echo "# --- END_OTA_CRON ---"
        } >> /config/crontabs/root
    fi
    busybox pidof crond >/dev/null || busybox crond -c /config/crontabs -l 8 &
    # SSH (dropbear) lifecycle is managed entirely by ipacl.sh, called via
    # www2/sh/startup.sh → apply_all at boot. It reads ACC_TBL.0.ssh (level)
    # and ACC_TBL.0.ssh_port from the mib and calls dropbear_start /
    # dropbear_stop / dropbear_restart accordingly. An unconditional launch
    # here would ignore the configured access level and port, and race against
    # apply_all — if level=0 (blocked), dropbear would start and then
    # immediately be killed a moment later by apply_all's dropbear_stop.
) &
