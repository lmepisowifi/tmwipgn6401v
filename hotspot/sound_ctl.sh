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
# sound_ctl.sh — portal sound library for lmepisowifi
#
# Lets the admin pick portal sounds that are published in the project repo
# (sounds/ + sounds.txt) instead of uploading a file. sounds.txt is its OWN
# manifest — separate from manifest.txt (base OTA) and modules.txt — so adding
# a sound never needs a release and never touches the OTA machinery.
#
#   sound_ctl.sh catalog [refresh]   # JSON: every library sound + which one is installed
#   sound_ctl.sh select <slot> <id>  # download + sha256-verify + install into hotspot/audio/
#
# A sound belongs to exactly ONE slot (the manifest's "slot=" field), so the
# three kinds are never mixed. Slots are the names the portal already uses:
#   bg_music         portal background music (loops)
#   insert_bg_music  music that loops while the insert-coin window is open
#   coin_sound       one-shot "coin inserted" sound
#
# "select" installs to hotspot/audio/<slot>.<ext> — exactly where an upload
# lands — so portal_config.sh, the portal page and the OTA PRESERVE list need
# no changes. Nothing is stored about WHICH sound is active: the catalog flags
# the entry whose sha256 equals the installed file's, so a later upload or
# Remove can never leave a stale record behind.
#
# Test hooks: SOUND_CTL_ROOT, SOUND_CTL_BB, SOUND_CTL_TMP, SOUND_CTL_LOG.
# ============================================================

ROOT="${SOUND_CTL_ROOT:-/lmepisowifi}"
BB="${SOUND_CTL_BB:-busybox}"
WORK="${SOUND_CTL_TMP:-/tmp/sound_lib}"
LOG="${SOUND_CTL_LOG:-/tmp/sound_ctl.log}"
AUDIO_DIR="$ROOT/hotspot/audio"
ENV_FILE="$ROOT/ota.env"
CATALOG="$WORK/sounds.txt"
DNS_HELPER="$ROOT/www2/sh/ensure_dns.sh"

DEFAULT_REPO="lmepisowifi/tmwipgn6401v"
OTA_REPO="$DEFAULT_REPO"
OTA_BRANCH="main"
OTA_MANIFEST_URL=""
OTA_CACERT="$ROOT/cacert.pem"   # operator-supplied bundle (optional override)
OTA_INSECURE_TLS="0"            # ota.env: 1 = skip HTTPS certificate verification (NOT recommended)
# Shipped defaults (defaults.ota.env), then device-local overrides (ota.env).
[ -f "$ROOT/defaults.ota.env" ] && . "$ROOT/defaults.ota.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
# Same shipped-bundle fallback as ota.sh / module_ctl.sh.
[ -f "$OTA_CACERT" ] || OTA_CACERT="$ROOT/www2/sh/cacert.pem"

CATALOG_TTL=600          # seconds a downloaded sounds.txt is reused before refetching
MAX_BYTES=8388608        # refuse a single sound larger than 8 MB
FREE_FLOOR=3145728       # keep >= 3 MB free on /lmepisowifi (same floor as portal uploads)

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }
json_err() { printf '{"ok":false,"error":"%s"}\n' "$1"; }

# ── Where the library lives ─────────────────────────────────────────────────
# Follows the same repo/branch (or OTA_MANIFEST_URL mirror) the OTA uses, so a
# fork or a custom mirror gets its own library. Both values end up inside URLs,
# so anything unexpected falls back to the stock repo instead of being used.
printf '%s' "$OTA_REPO"   | $BB grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || OTA_REPO="$DEFAULT_REPO"
printf '%s' "$OTA_BRANCH" | $BB grep -qE '^[A-Za-z0-9._-]+$'                 || OTA_BRANCH="main"
if [ -n "$OTA_MANIFEST_URL" ]; then
    LIB_BASE=$(printf '%s' "$OTA_MANIFEST_URL" | $BB sed 's#/manifest\.txt$##')
else
    LIB_BASE="https://cdn.jsdelivr.net/gh/${OTA_REPO}@${OTA_BRANCH}"
fi
printf '%s' "$LIB_BASE" | $BB grep -qE '^https://[A-Za-z0-9._~:/@%+-]+$' \
    || LIB_BASE="https://cdn.jsdelivr.net/gh/${DEFAULT_REPO}@main"

# Same raw.githubusercontent.com -> jsDelivr rewrite ota.sh/module_ctl.sh use
# (GitHub's raw host rate-limits with HTTP 429; the CDN does not).
cdnify() {
    case "$1" in
        https://raw.githubusercontent.com/*)
            _rest=${1#https://raw.githubusercontent.com/}
            _o=$(echo "$_rest" | cut -d/ -f1); _r=$(echo "$_rest" | cut -d/ -f2)
            _ref=$(echo "$_rest" | cut -d/ -f3); _p=$(echo "$_rest" | cut -d/ -f4-)
            [ -n "$_o" ] && [ -n "$_r" ] && [ -n "$_ref" ] && [ -n "$_p" ] \
                && echo "https://cdn.jsdelivr.net/gh/${_o}/${_r}@${_ref}/${_p}" || echo "$1" ;;
        *) echo "$1" ;;
    esac
}
SOUNDS_URL=$(cdnify "$LIB_BASE/sounds.txt")
FILES_BASE=$(cdnify "$LIB_BASE/sounds/")   # the admin browser previews straight from here

# ── Download plumbing (same rules as module_ctl.sh) ─────────────────────────
_tls_opts() {
    if [ "$OTA_INSECURE_TLS" = "1" ]; then
        printf '%s' "--no-check-certificate"
    elif [ -f "$OTA_CACERT" ]; then
        printf '%s' "--ca-certificate=$OTA_CACERT"
    else
        log "WARNING: no CA bundle installed - HTTPS certificate NOT verified"
        printf '%s' "--no-check-certificate"
    fi
}
_DNS_SEEN=""
dns_guard() { # dns_guard <url> — adds the public-resolver fallback only if the host really doesn't resolve
    [ -f "$DNS_HELPER" ] || return 0
    _dgh=${1#https://}; _dgh=${_dgh%%/*}; _dgh=${_dgh%%:*}
    case " $_DNS_SEEN " in *" $_dgh "*) return 0 ;; esac
    _DNS_SEEN="$_DNS_SEEN $_dgh"
    sh "$DNS_HELPER" "$_dgh" || log "dns_guard: $_dgh does not resolve (no internet, or DNS is broken beyond the public-resolver fallback)"
    return 0
}
fetch() { # fetch <url> <outfile>
    _u=$(cdnify "$1")
    dns_guard "$_u"
    _wf="--https-only -t 2 -T 20 --retry-connrefused -U lmepisowifi-sounds $(_tls_opts)"
    wget $_wf -q -O "$2" "$_u"
}

# ── Catalog (sounds.txt) ────────────────────────────────────────────────────
catalog_fresh() {
    [ -s "$CATALOG" ] || return 1
    _mt=$($BB stat -c %Y "$CATALOG" 2>/dev/null) || return 1
    _age=$(( $(date +%s) - _mt ))
    [ "$_age" -ge 0 ] && [ "$_age" -lt "$CATALOG_TTL" ]   # a negative age = clock jumped; refetch
}

# ensure_catalog <force 0|1>
# Sets CAT_STALE=1 when the fetch failed and an older cached copy is served
# instead (e.g. the router is offline). Returns 1 only when there is nothing.
ensure_catalog() {
    CAT_STALE=0
    mkdir -p "$WORK" 2>/dev/null
    if [ "$1" != "1" ] && catalog_fresh; then return 0; fi
    _tmp="$WORK/sounds.txt.new"
    rm -f "$_tmp"
    # The CDN can answer 200 with an error page; never cache one of those.
    if fetch "$SOUNDS_URL" "$_tmp" && [ -s "$_tmp" ] \
       && ! $BB grep -qiE '<html|rate.limit|Too Many Requests|404: Not Found' "$_tmp"; then
        $BB mv "$_tmp" "$CATALOG"
        return 0
    fi
    rm -f "$_tmp"
    log "catalog: fetch of $SOUNDS_URL failed"
    [ -s "$CATALOG" ] && { CAT_STALE=1; return 0; }
    return 1
}

# parse_catalog — reads sounds.txt on stdin, prints one validated sound per line:
#   id <TAB> slot <TAB> name <TAB> file <TAB> size <TAB> sha256 <TAB> description
# Entries that fail validation are dropped, never repaired. `file` must be
# <slot>/<name>.(mp3|ogg|wav) with no "..", which is what keeps every download
# URL inside the repo's sounds/ folder (the manifest carries no URLs at all).
# " \ and control characters are stripped first, so nothing downstream needs
# JSON escaping.
parse_catalog() {
    $BB tr -d '"\\\r\000-\010\013\014\016-\037\177' | $BB awk '
    function flush(   key) {
        if (id != "" && id ~ /^[a-z0-9][a-z0-9_-]*$/ && length(id) <= 48 \
            && (slot == "bg_music" || slot == "insert_bg_music" || slot == "coin_sound") \
            && file ~ /^[a-z_]+\/[A-Za-z0-9._-]+$/ && file ~ /\.(mp3|ogg|wav)$/ \
            && index(file, "..") == 0 && substr(file, 1, index(file, "/") - 1) == slot \
            && length(sha) == 64 && sha ~ /^[0-9a-f]+$/) {
            key = slot "/" id
            if (!(key in seen)) {
                seen[key] = 1
                if (size !~ /^[0-9]+$/) size = 0
                if (name == "") name = id
                gsub(/\t/, " ", name); gsub(/\t/, " ", desc)
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, slot, substr(name, 1, 60), file, size, sha, substr(desc, 1, 160)
            }
        }
        id = ""; slot = ""; name = ""; file = ""; size = ""; sha = ""; desc = ""
    }
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { flush(); next }
    {
        eq = index($0, "=")
        if (!eq) next
        k = substr($0, 1, eq - 1); v = substr($0, eq + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", k)
        gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (k == "id")               { if (id != "") flush(); id = v }
        else if (k == "slot")        slot = v
        else if (k == "name")        name = v
        else if (k == "file")        file = v
        else if (k == "size")        size = v
        else if (k == "sha256")      sha = v
        else if (k == "description") desc = v
    }
    END { flush() }'
}

# sha256 of the audio file currently installed for a slot ("" when none).
# Same mp3 > ogg > wav order portal_config.sh uses to pick the active file.
active_sha() {
    for _e in mp3 ogg wav; do
        if [ -f "$AUDIO_DIR/$1.$_e" ]; then
            sha256sum "$AUDIO_DIR/$1.$_e" 2>/dev/null | $BB awk '{print $1}'
            return
        fi
    done
}

do_catalog() { # do_catalog [refresh]
    _force=0; [ "$1" = "refresh" ] && _force=1
    if ! ensure_catalog "$_force"; then json_err catalog_fetch_failed; return 1; fi
    _stale=false; [ "$CAT_STALE" = 1 ] && _stale=true
    printf '{"ok":true,"base":"%s","stale":%s,"sounds":[' "$FILES_BASE" "$_stale"
    parse_catalog < "$CATALOG" | $BB awk -F'\t' \
        -v a_bg="$(active_sha bg_music)" -v a_ins="$(active_sha insert_bg_music)" -v a_coin="$(active_sha coin_sound)" '
        BEGIN { first = 1 }
        {
            act = "false"
            if ($2 == "bg_music"        && a_bg   != "" && $6 == a_bg)   act = "true"
            if ($2 == "insert_bg_music" && a_ins  != "" && $6 == a_ins)  act = "true"
            if ($2 == "coin_sound"      && a_coin != "" && $6 == a_coin) act = "true"
            printf "%s{\"id\":\"%s\",\"slot\":\"%s\",\"name\":\"%s\",\"file\":\"%s\",\"size\":%s,\"sha256\":\"%s\",\"description\":\"%s\",\"active\":%s}", \
                (first ? "" : ","), $1, $2, $3, $4, $5, $6, $7, act
            first = 0
        }'
    printf ']}\n'
}

# ── Install ─────────────────────────────────────────────────────────────────
LOCK="$WORK/lock"
release_lock() { rm -rf "$LOCK" 2>/dev/null; }
acquire_lock() {
    mkdir -p "$WORK" 2>/dev/null
    if mkdir "$LOCK" 2>/dev/null; then echo "$$" > "$LOCK/pid"; return 0; fi
    _lp=$($BB tr -d ' \t\r\n' < "$LOCK/pid" 2>/dev/null)
    [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null && return 1
    rm -rf "$LOCK" 2>/dev/null          # stale: its owner died before cleaning up
    mkdir "$LOCK" 2>/dev/null && { echo "$$" > "$LOCK/pid"; return 0; }
    return 1
}

find_entry() { # find_entry <slot> <id> -> "file<TAB>size<TAB>sha256" or nothing
    parse_catalog < "$CATALOG" | $BB awk -F'\t' -v s="$1" -v i="$2" '$2 == s && $1 == i { print $4 "\t" $5 "\t" $6; exit }'
}

do_select() { # do_select <slot> <id>
    _s="$1"; _i="$2"
    case "$_s" in bg_music|insert_bg_music|coin_sound) ;; *) json_err bad_slot; return 1 ;; esac
    case "$_i" in ""|*[!a-z0-9_-]*) json_err bad_id; return 1 ;; esac
    [ "${#_i}" -le 48 ] || { json_err bad_id; return 1; }

    if ! acquire_lock; then json_err busy; return 1; fi
    trap release_lock EXIT INT TERM
    : > "$LOG" 2>/dev/null

    # An id that isn't in the cached copy may simply be newer than it: refetch once.
    ensure_catalog 0 || { json_err catalog_fetch_failed; return 1; }
    _entry=$(find_entry "$_s" "$_i")
    if [ -z "$_entry" ]; then
        ensure_catalog 1 || { json_err catalog_fetch_failed; return 1; }
        _entry=$(find_entry "$_s" "$_i")
    fi
    [ -n "$_entry" ] || { json_err not_found; return 1; }
    _file=$(printf '%s' "$_entry" | $BB cut -f1)
    _want=$(printf '%s' "$_entry" | $BB cut -f3)
    _ext=${_file##*.}

    # Download into RAM first; the installed file is only touched once the
    # download has passed its checksum.
    _dl="$WORK/dl"
    rm -rf "$_dl"; mkdir -p "$_dl"
    _tmp="$_dl/$_s.$_ext"
    log "select: $_s <- $_file"
    if ! fetch "$FILES_BASE$_file" "$_tmp" || [ ! -s "$_tmp" ]; then
        rm -rf "$_dl"; json_err download_failed; return 1
    fi
    _size=$($BB wc -c < "$_tmp" | $BB tr -d ' \t\r\n')
    if [ "${_size:-0}" -le 0 ] || [ "$_size" -gt "$MAX_BYTES" ]; then
        rm -rf "$_dl"; json_err bad_size; return 1
    fi
    _got=$(sha256sum "$_tmp" 2>/dev/null | $BB awk '{print $1}')
    if [ -z "$_got" ] || [ "$_got" != "$_want" ]; then
        log "select: sha256 MISMATCH for $_file — want=$_want got=${_got:-<empty>}"
        rm -rf "$_dl"; json_err checksum_mismatch; return 1
    fi

    # Free-space guard. The file this replaces is about to be freed, so it
    # counts in the new file's favour (otherwise a swap on a nearly-full
    # device would be refused even though it needs no extra room).
    _avkb=$($BB df -k "$ROOT" 2>/dev/null | $BB awk 'NR==2 {print $4+0}')
    _old=0
    for _e in mp3 ogg wav; do
        [ -f "$AUDIO_DIR/$_s.$_e" ] || continue
        _o=$($BB wc -c < "$AUDIO_DIR/$_s.$_e" | $BB tr -d ' \t\r\n')
        _old=$(( _old + ${_o:-0} ))
    done
    if [ $(( ${_avkb:-0} * 1024 + _old - _size )) -lt "$FREE_FLOOR" ]; then
        rm -rf "$_dl"; json_err insufficient_space; return 1
    fi

    mkdir -p "$AUDIO_DIR"
    _dest="$AUDIO_DIR/$_s.$_ext"
    if ! cp "$_tmp" "$_dest.tmp" 2>/dev/null \
       || [ "$($BB wc -c < "$_dest.tmp" 2>/dev/null | $BB tr -d ' \t\r\n')" != "$_size" ]; then
        rm -f "$_dest.tmp"; rm -rf "$_dl"; json_err write_failed; return 1
    fi
    $BB mv "$_dest.tmp" "$_dest"
    # The slot holds one file: drop a leftover with another extension
    # (portal_config.sh would otherwise serve the older mp3 over a new ogg).
    for _e in mp3 ogg wav; do
        [ "$_e" = "$_ext" ] || rm -f "$AUDIO_DIR/$_s.$_e"
    done
    sync
    rm -rf "$_dl"
    log "select: installed $_dest"
    printf '{"ok":true,"slot":"%s","id":"%s","path":"/audio/%s.%s"}\n' "$_s" "$_i" "$_s" "$_ext"
}

case "$1" in
    catalog) do_catalog "$2" ;;
    select)  do_select "$2" "$3" ;;
    *) echo "usage: $0 {catalog [refresh]|select <slot> <id>}" >&2; exit 2 ;;
esac
