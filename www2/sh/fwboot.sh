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

# fwboot.sh — Realtek Luna dual-image (A/B) boot-slot manager + firmware flasher.
# Back end for www2/cgi-bin/bootpart.cgi (bootpart.html / fwupload.html).
#
# How the Luna bootloader picks a slot (U-Boot env, read/written with `nv`):
#   sw_active     slot currently running (0|1), rewritten by U-Boot every boot
#   sw_commit     slot that boots normally
#   sw_tryactive  0|1 = boot THAT slot once (U-Boot resets it to 2 before
#                 booting, with the watchdog armed, so a bad image falls back
#                 to sw_commit); 2 = no trial pending
#   sw_updater    non-empty (vendor uses "web") makes /etc/scripts/fw_loaded.sh,
#                 run at the end of boot, set sw_commit=sw_active — i.e. a trial
#                 slot that boots cleanly becomes the default
#   sw_version0/1 version string recorded per slot ("0" = nothing recorded)
# Slots live in UBI device 0 as volumes ubi_k<N> (uImage) and ubi_r<N> (rootfs).
#
# Usage:
#   fwboot.sh status                      JSON: slots, running/default/trial, staged state
#   fwboot.sh setdefault <0|1>            make slot N the normal boot slot
#   fwboot.sh bootonce <0|1> <keep 0|1>   trial-boot slot N once (keep=1: keep it if it boots)
#   fwboot.sh cancel                      drop a pending trial boot
#   fwboot.sh check [tar]                 validate a Luna fwu tar (default: staged upload)
#   fwboot.sh fetch <https-url>           download a tar into the staging area, then check it
#   fwboot.sh flash <0|1> [tar]           write uImage+rootfs into slot N (never the running/default slot)
#   fwboot.sh devpath <0|1> <kernel|rootfs>   print the volume device (for downloads)
#   fwboot.sh state | log | discard | reboot
#
# Test hooks: FWBOOT_NV, FWBOOT_UBINFO, FWBOOT_UBIUPDATE, FWBOOT_PROCMTD,
# FWBOOT_DEVDIR, FWBOOT_WORK, FWBOOT_ETCVER, FWBOOT_FLASH, FWBOOT_OTA.

NV="${FWBOOT_NV:-nv}"
UBINFO="${FWBOOT_UBINFO:-ubinfo}"
UBIUPD="${FWBOOT_UBIUPDATE:-ubiupdatevol}"
PROCMTD="${FWBOOT_PROCMTD:-/proc/mtd}"
UBIDEV=0
DEVDIR="${FWBOOT_DEVDIR:-/dev}"
WORK="${FWBOOT_WORK:-/tmp/fwboot}"
ETCVER="${FWBOOT_ETCVER:-/etc/version}"
FLASHCMD="${FWBOOT_FLASH:-flash}"
OTA="${FWBOOT_OTA:-/lmepisowifi/ota.sh}"
SKIP_HW=/tmp/skip_hwver_check          # same sentinel the vendor fwu.sh honours
TAR="$WORK/upload.tar"
MAX_DL_BYTES=67108864                  # refuse downloads past 64 MiB

mkdir -p "$WORK" 2>/dev/null

jesc()  { printf '%s' "$1" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
nvget() { "$NV" getenv "$1" 2>/dev/null | head -n 1 | sed -n 's/^[^=]*=//p'; }
nvset() { "$NV" setenv "$@" >/dev/null 2>&1; }
is_slot() { case "$1" in 0|1) return 0 ;; *) return 1 ;; esac; }
logm()  { echo "$(date +%H:%M:%S) $*" >> "$WORK/log"; }
setstate() { printf '%s' "$1" > "$WORK/state"; printf '%s' "$2" > "$WORK/msg"; logm "[$1] $2"; }
fail()  { setstate error "$1"; echo "ERROR: $1" >&2; exit 1; }
# Version strings go into the bootloader env: keep them short and boring.
clean_ver() { tr -d '\r' | head -n 1 | sed 's/ *--.*$//' | tr -cd 'A-Za-z0-9._+:/ ()-' | cut -c1-64; }

vol_id() {   # $1=k|r $2=slot -> UBI volume id
    "$UBINFO" -d "$UBIDEV" -N "ubi_$1$2" 2>/dev/null \
        | sed -n 's/^Volume ID: *\([0-9][0-9]*\).*/\1/p' | head -n 1
}
vol_dev() { _id=$(vol_id "$1" "$2"); [ -n "$_id" ] && echo "$DEVDIR/ubi${UBIDEV}_$_id"; }
vol_cap() {  # capacity in bytes of the MTD named ubi_<k|r><slot> (what the vendor fwu.sh checks)
    _sz=$(sed -n "s/^[^:]*: *\([0-9a-fA-F][0-9a-fA-F]*\) .*\"ubi_$1$2\".*/\1/p" "$PROCMTD" 2>/dev/null | head -n 1)
    [ -n "$_sz" ] && echo $((0x$_sz))
}
is_present() { case "$1" in ""|0) return 1 ;; *) return 0 ;; esac; }
supported() {
    case "$(nvget sw_active)" in 0|1) ;; *) return 1 ;; esac
    for _s in 0 1; do
        [ -n "$(vol_id k $_s)" ] && [ -n "$(vol_id r $_s)" ] || return 1
    done
    return 0
}

busy() { [ -f "$WORK/pid" ] && kill -0 "$(cat "$WORK/pid" 2>/dev/null)" 2>/dev/null; }

# ---- tar validation ---------------------------------------------------------
# Sets CK_ERR (non-empty = rejected), CK_WARN, CK_VER, CK_HW, CK_KSZ, CK_RSZ, CK_SIZE.
do_check() {
    _t="$1"; CK_ERR=""; CK_WARN=""; CK_VER=""; CK_HW=""; CK_KSZ=0; CK_RSZ=0; CK_SIZE=0
    [ -s "$_t" ] || { CK_ERR="no firmware file is staged"; return 1; }
    CK_SIZE=$(wc -c < "$_t" | tr -d ' ')
    _lst=$(tar -tvf "$_t" 2>/dev/null) || { CK_ERR="not a valid tar archive"; return 1; }
    for _f in uImage rootfs md5.txt; do
        printf '%s\n' "$_lst" | awk -v n="$_f" '$NF==n{f=1} END{exit !f}' \
            || { CK_ERR="not a Luna firmware tar: $_f is missing"; return 1; }
    done
    CK_KSZ=$(printf '%s\n' "$_lst" | awk '$NF=="uImage"{print $3; exit}')
    CK_RSZ=$(printf '%s\n' "$_lst" | awk '$NF=="rootfs"{print $3; exit}')
    case "$CK_KSZ$CK_RSZ" in *[!0-9]*|"") CK_ERR="cannot read member sizes from the tar"; return 1 ;; esac
    [ "$CK_KSZ" -gt 0 ] && [ "$CK_RSZ" -gt 0 ] || { CK_ERR="uImage or rootfs is empty"; return 1; }

    _md=$(tar -xf "$_t" md5.txt -O 2>/dev/null)
    for _f in uImage rootfs; do
        _want=$(printf '%s\n' "$_md" | awk -v n="$_f" '$2==n{print $1; exit}')
        [ -n "$_want" ] || { CK_ERR="md5.txt has no entry for $_f"; return 1; }
        _got=$(tar -xf "$_t" "$_f" -O 2>/dev/null | md5sum | awk '{print $1}')
        [ "$_got" = "$_want" ] || { CK_ERR="$_f checksum mismatch (corrupt or incomplete file)"; return 1; }
    done

    if printf '%s\n' "$_lst" | awk '$NF=="hw_ver"{f=1} END{exit !f}'; then
        _ihw=$(tar -xf "$_t" hw_ver -O 2>/dev/null | tr -d '\r\n')
        CK_HW="$_ihw"
        _chw=$("$FLASHCMD" get HW_HWVER 2>/dev/null | sed 's/^HW_HWVER=//' | tr -d '\r\n')
        if [ "$_ihw" != "skip" ] && [ ! -f "$SKIP_HW" ]; then
            if [ -z "$_chw" ]; then
                CK_WARN="could not read this device's hardware version; hw_ver check skipped"
            elif [ "$_ihw" != "$_chw" ]; then
                CK_ERR="hardware version mismatch: image is for \"$_ihw\", this device is \"$_chw\" (create $SKIP_HW to override)"
                return 1
            fi
        fi
    else
        CK_WARN="no hw_ver in the tar; hardware version not checked"
    fi

    CK_VER=$(tar -xf "$_t" fwu_ver -O 2>/dev/null | clean_ver)
    [ -n "$CK_VER" ] || { CK_VER="custom-$(date +%Y%m%d%H%M)"; CK_WARN="${CK_WARN:+$CK_WARN; }no fwu_ver in the tar; recording \"$CK_VER\""; }
    if printf '%s\n' "$_lst" | awk '$NF=="framework.img"{f=1} END{exit !f}'; then
        CK_WARN="${CK_WARN:+$CK_WARN; }framework.img is present but is not written by this tool"
    fi
    return 0
}

meta_json() {   # prints JSON for the last do_check result
    if [ -n "$CK_ERR" ]; then
        printf '{"ok":false,"error":"%s"}\n' "$(jesc "$CK_ERR")"
    else
        printf '{"ok":true,"version":"%s","hw_ver":"%s","kernel_size":%s,"rootfs_size":%s,"warning":"%s","size":%s}\n' \
            "$(jesc "$CK_VER")" "$(jesc "$CK_HW")" "$CK_KSZ" "$CK_RSZ" "$(jesc "$CK_WARN")" "$CK_SIZE"
    fi
}

cmd_check() {
    _t="${1:-$TAR}"
    if do_check "$_t"; then setstate staged "Firmware verified: $CK_VER"; else setstate error "$CK_ERR"; fi
    meta_json > "$WORK/meta"; cat "$WORK/meta"
}

# ---- boot-slot control ------------------------------------------------------
need_supported() { supported || { echo '{"ok":false,"error":"this device does not expose a dual-image (A/B) layout"}'; exit 0; }; }
res_ok()  { printf '{"ok":true,"message":"%s"}\n' "$(jesc "$1")"; }
res_err() { printf '{"ok":false,"error":"%s"}\n' "$(jesc "$1")"; }

cmd_setdefault() {
    is_slot "$1" || { res_err "slot must be 0 or 1"; return; }
    need_supported
    is_present "$(nvget sw_version$1)" || { res_err "slot $1 has no firmware recorded; flash it first"; return; }
    nvset sw_commit "$1"; nvset sw_tryactive 2; nvset sw_updater
    [ "$(nvget sw_commit)" = "$1" ] || { res_err "bootloader did not accept the change (nv setenv failed)"; return; }
    res_ok "Slot $1 will boot by default after the next reboot"
}

cmd_bootonce() {
    is_slot "$1" || { res_err "slot must be 0 or 1"; return; }
    need_supported
    [ "$1" != "$(nvget sw_active)" ] || { res_err "slot $1 is already the running slot"; return; }
    is_present "$(nvget sw_version$1)" || { res_err "slot $1 has no firmware recorded; flash it first"; return; }
    nvset sw_tryactive "$1"
    if [ "$2" = "1" ]; then nvset sw_updater web; else nvset sw_updater; fi
    [ "$(nvget sw_tryactive)" = "$1" ] || { res_err "bootloader did not accept the change (nv setenv failed)"; return; }
    if [ "$2" = "1" ]; then
        res_ok "Next reboot trial-boots slot $1 and keeps it as the default if it comes up cleanly"
    else
        res_ok "Next reboot boots slot $1 once; the reboot after that returns to slot $(nvget sw_commit)"
    fi
}

cmd_cancel() {
    need_supported
    nvset sw_tryactive 2; nvset sw_updater
    res_ok "Pending trial boot cancelled"
}

# ---- status -----------------------------------------------------------------
cmd_status() {
    _act=$(nvget sw_active); _com=$(nvget sw_commit); _try=$(nvget sw_tryactive); _upd=$(nvget sw_updater)
    _run=$(head -n 1 "$ETCVER" 2>/dev/null | clean_ver)
    if supported; then _sup=true; else _sup=false; fi
    _st=$(cat "$WORK/state" 2>/dev/null); [ -n "$_st" ] || _st=idle
    _msg=$(cat "$WORK/msg" 2>/dev/null)
    _meta=$(cat "$WORK/meta" 2>/dev/null); [ -n "$_meta" ] || _meta=null
    [ -s "$TAR" ] || _meta=null
    _busy=false; busy && _busy=true
    printf '{"supported":%s,"active":"%s","commit":"%s","tryactive":"%s","updater":"%s","running_version":"%s",' \
        "$_sup" "$(jesc "$_act")" "$(jesc "$_com")" "$(jesc "$_try")" "$(jesc "$_upd")" "$(jesc "$_run")"
    printf '"state":"%s","message":"%s","busy":%s,"staged":%s,"slots":[' \
        "$(jesc "$_st")" "$(jesc "$_msg")" "$_busy" "$_meta"
    for _s in 0 1; do
        [ "$_s" = 1 ] && printf ','
        _v=$(nvget sw_version$_s)
        printf '{"id":%s,"version":"%s","present":%s,"kernel_cap":%s,"rootfs_cap":%s}' \
            "$_s" "$(jesc "$_v")" "$(is_present "$_v" && echo true || echo false)" \
            "$(vol_cap k $_s || echo 0)" "$(vol_cap r $_s || echo 0)"
    done
    printf ']}\n'
}

# ---- flashing ---------------------------------------------------------------
preflight() {   # $1=slot -> sets PF_ERR
    PF_ERR=""
    is_slot "$1" || { PF_ERR="slot must be 0 or 1"; return 1; }
    supported || { PF_ERR="this device does not expose a dual-image (A/B) layout"; return 1; }
    [ "$1" != "$(nvget sw_active)" ] || { PF_ERR="slot $1 is the running slot and cannot be overwritten"; return 1; }
    [ "$1" != "$(nvget sw_commit)" ] || { PF_ERR="slot $1 is the default boot slot; make the other slot the default first"; return 1; }
    case "$(nvget sw_tryactive)" in ""|2) ;; *) PF_ERR="a trial boot is pending; reboot or cancel it first"; return 1 ;; esac
    return 0
}

verify_vol() {  # $1=dev $2=bytes $3=expected md5
    _g=$(head -c "$2" "$1" 2>/dev/null | md5sum | awk '{print $1}')
    [ "$_g" = "$3" ]
}

cmd_flash() {
    _slot="$1"; _t="${2:-$TAR}"
    busy && fail "another firmware operation is already running"
    echo $$ > "$WORK/pid"
    trap 'setstate error "interrupted"; rm -f "$WORK/pid" "$WORK/uImage" "$WORK/rootfs"; exit 1' INT TERM HUP
    : > "$WORK/log"
    preflight "$_slot" || { rm -f "$WORK/pid"; fail "$PF_ERR"; }
    setstate verifying "Verifying firmware"
    do_check "$_t" || { rm -f "$WORK/pid"; fail "$CK_ERR"; }

    _kdev=$(vol_dev k "$_slot"); _rdev=$(vol_dev r "$_slot")
    [ -n "$_kdev" ] && [ -n "$_rdev" ] || { rm -f "$WORK/pid"; fail "cannot resolve UBI volumes for slot $_slot"; }
    _kcap=$(vol_cap k "$_slot"); _rcap=$(vol_cap r "$_slot")
    if [ -n "$_kcap" ] && [ "$CK_KSZ" -ge "$_kcap" ]; then rm -f "$WORK/pid"; fail "uImage is too big for slot $_slot ($CK_KSZ >= $_kcap bytes)"; fi
    if [ -n "$_rcap" ] && [ "$CK_RSZ" -ge "$_rcap" ]; then rm -f "$WORK/pid"; fail "rootfs is too big for slot $_slot ($CK_RSZ >= $_rcap bytes)"; fi

    _big=$CK_KSZ; [ "$CK_RSZ" -gt "$_big" ] && _big=$CK_RSZ
    _need=$(( _big / 1024 + 2048 ))
    _avail=$(df -k "$WORK" 2>/dev/null | tail -n 1 | awk '{print $(NF-2)}')
    case "$_avail" in ""|*[!0-9]*) ;; *)
        [ "$_avail" -ge "$_need" ] || { rm -f "$WORK/pid"; fail "not enough free memory in $WORK: need ${_need} KB, have ${_avail} KB"; } ;;
    esac

    # The slot is not bootable until it is complete: clear its recorded version
    # first so an interrupted write can never look like a valid image.
    nvset sw_version"$_slot" 0
    for _p in "k:uImage:$_kdev:$CK_KSZ" "r:rootfs:$_rdev:$CK_RSZ"; do
        _name=$(echo "$_p" | cut -d: -f2); _dev=$(echo "$_p" | cut -d: -f3); _sz=$(echo "$_p" | cut -d: -f4)
        setstate flashing "Writing $_name to slot $_slot"
        tar -xf "$_t" "$_name" -O > "$WORK/$_name" 2>>"$WORK/log" \
            || { rm -f "$WORK/$_name" "$WORK/pid"; fail "could not extract $_name (slot $_slot left invalid)"; }
        _want=$(tar -xf "$_t" md5.txt -O 2>/dev/null | awk -v n="$_name" '$2==n{print $1; exit}')
        "$UBIUPD" "$_dev" "$WORK/$_name" >>"$WORK/log" 2>&1 \
            || { rm -f "$WORK/$_name" "$WORK/pid"; fail "ubiupdatevol failed for $_name; slot $_slot is invalid, re-flash it"; }
        rm -f "$WORK/$_name"
        setstate flashing "Verifying $_name in slot $_slot"
        verify_vol "$_dev" "$_sz" "$_want" \
            || { rm -f "$WORK/pid"; fail "$_name read-back mismatch after writing; slot $_slot is invalid, re-flash it"; }
    done

    nvset sw_version"$_slot" "$CK_VER"
    is_present "$(nvget sw_version$_slot)" || { rm -f "$WORK/pid"; fail "flashed, but could not record the version in the bootloader env"; }
    rm -f "$_t" "$WORK/meta" "$WORK/pid"
    setstate done "Slot $_slot now holds $CK_VER. Use Boot Partitions to boot it."
}

# ---- download from URL ------------------------------------------------------
cmd_fetch() {
    _u="$1"
    busy && fail "another firmware operation is already running"
    printf '%s' "$_u" | grep -q '^https://[A-Za-z0-9._~:/?#@&+,;=%-]*$' \
        || fail "only plain https:// URLs are accepted"
    echo $$ > "$WORK/pid"
    trap 'setstate error "interrupted"; rm -f "$WORK/pid"; exit 1' INT TERM HUP
    : > "$WORK/log"; rm -f "$TAR" "$WORK/meta"
    _wf="-q -T 20"
    [ "$(sh "$OTA" get_insecure_tls 2>/dev/null)" = "1" ] && _wf="$_wf --no-check-certificate"
    setstate downloading "Starting download"
    wget $_wf -O "$TAR" "$_u" >>"$WORK/log" 2>&1 &
    _wp=$!; _last=-1; _stall=0
    while kill -0 "$_wp" 2>/dev/null; do
        sleep 2
        _sz=$(wc -c < "$TAR" 2>/dev/null | tr -d ' '); [ -n "$_sz" ] || _sz=0
        setstate downloading "Downloaded $((_sz / 1024)) KB"
        if [ "$_sz" -gt "$MAX_DL_BYTES" ]; then kill "$_wp" 2>/dev/null; rm -f "$TAR" "$WORK/pid"; fail "download is larger than $((MAX_DL_BYTES / 1048576)) MiB; aborted"; fi
        if [ "$_sz" = "$_last" ]; then _stall=$((_stall + 2)); else _stall=0; _last=$_sz; fi
        if [ "$_stall" -ge 60 ]; then kill "$_wp" 2>/dev/null; rm -f "$TAR" "$WORK/pid"; fail "download stalled for 60 s; aborted"; fi
    done
    wait "$_wp"; _rc=$?
    if [ "$_rc" -ne 0 ]; then
        rm -f "$TAR" "$WORK/pid"
        [ "$_rc" -eq 5 ] && fail "HTTPS certificate verification failed (check the device clock, or see Software Update > Skip certificate check)"
        fail "download failed (wget exit $_rc)"
    fi
    setstate verifying "Verifying download"
    if do_check "$TAR"; then setstate staged "Firmware verified: $CK_VER"; else rm -f "$TAR"; setstate error "$CK_ERR"; fi
    meta_json > "$WORK/meta"; rm -f "$WORK/pid"
}

case "$1" in
    status)     cmd_status ;;
    setdefault) cmd_setdefault "$2" ;;
    bootonce)   cmd_bootonce "$2" "$3" ;;
    cancel)     cmd_cancel ;;
    check)      cmd_check "$2" ;;
    fetch)      cmd_fetch "$2" ;;
    flash)      cmd_flash "$2" "$3" ;;
    devpath)    is_slot "$2" || exit 1
                case "$3" in kernel) vol_dev k "$2" ;; rootfs) vol_dev r "$2" ;; *) exit 1 ;; esac ;;
    state)      cat "$WORK/state" 2>/dev/null ;;
    log)        tail -c 6000 "$WORK/log" 2>/dev/null ;;
    discard)    busy && { res_err "an operation is running"; exit 0; }
                rm -f "$TAR" "$WORK/meta" "$WORK/uImage" "$WORK/rootfs"; setstate idle ""; res_ok "Staged firmware discarded" ;;
    reboot)     ( sleep 3; sync; reboot ) >/dev/null 2>&1 & res_ok "Rebooting" ;;
    *)          echo "usage: $0 status|setdefault N|bootonce N KEEP|cancel|check [tar]|fetch URL|flash N [tar]|devpath N kernel|rootfs|state|log|discard|reboot" >&2; exit 2 ;;
esac
