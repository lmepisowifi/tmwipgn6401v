#!/bin/sh
# domainblk.sh — DOMAIN_BLOCKING_TBL-backed DNS domain blocking
# Installed at: /lmepisowifi/www2/sh/domainblk.sh
#
# Blocks a domain by dropping DNS queries for it (udp+tcp/53) in the
# "domainblk" iptables chain via xt_dns --qname --rmatch, e.g.:
#   iptables -A domainblk -p udp --dport 53 -m dns --qname facebook.com --rmatch -j DROP
#   iptables -A domainblk -p tcp --dport 53 -m dns --qname facebook.com --rmatch -j DROP
#
# On stock M2-2050-G40 firmware (DOMAIN_BLOCKING_SUPPORT) the "domainblk"
# chain and its hook into the router's own DNS server path already exist
# out of the box — this only ever needs to add/remove --qname rules in it.
# ensure_chain()'s `iptables -N domainblk` is a defensive no-op fallback
# for that assumption, matching the same opportunistic -N pattern already
# used elsewhere in this codebase (hotspot.cgi's AT_CHAIN, lmehspt.sh's
# HOTSPOT/HOTSPOT_FWD) — harmless if the chain is already there.
#
# IMPORTANT CAVEAT: this only blocks clients that resolve DNS through the
# router itself. A client pointed at an external resolver (1.1.1.1,
# 8.8.8.8, DoH/DoT, etc.) never sends the router a DNS query to match
# against, so the domain stays reachable for that client.
#
# --lib mode: `. domainblk.sh --lib` sources just the functions below
# (used by domainblk.cgi), without running the apply_all CLI dispatch at
# the bottom. Same convention as ipacl.sh --lib.

BB="busybox"
[ "$1" = "--lib" ] && DOMAINBLK_LIB_ONLY=1

CHAIN="domainblk"
CAP_KEY="DOMAINBLK_CAPABILITY"

mib_field() {
    mib get "$1" 2>/dev/null | $BB grep "=" | $BB cut -d'=' -f2- | $BB tr -d ' \r\n'
}

# Master on/off switch for the whole feature, independent of which domains
# are in the table. Mirrors the vendor's own default — config_custom_default.xml
# ships DOMAINBLK_CAPABILITY=0 — so an unset/invalid value is treated as
# disabled, same "unknown means off" convention ipacl.sh uses for ACC_TBL.
cap_enabled() {
    [ "$(mib_field "$CAP_KEY")" = "1" ]
}

# Print each domain currently persisted in DOMAIN_BLOCKING_TBL, one per line.
domain_list() {
    mib get DOMAIN_BLOCKING_TBL 2>/dev/null \
        | $BB awk -F= '/DOMAIN[ \t]*=/ { v=$2; gsub(/^[ \t]+|[ \t\r]+$/, "", v); if (v != "") print v }'
}

# Idempotent — see the DOMAIN_BLOCKING_SUPPORT note above for why this is
# normally a no-op.
ensure_chain() {
    iptables -N "$CHAIN" 2>/dev/null
    return 0
}

# Idempotently delete every rule (udp+tcp) matching this domain, looping
# -D until none remain (same convention as ipacl.sh's _ipacl_del_all) so
# re-adding the same domain twice never leaves duplicate DROP rules.
del_domain_rules() {
    _DB_DOMAIN="$1"
    [ -z "$_DB_DOMAIN" ] && return 1
    while iptables -D "$CHAIN" -p udp --dport 53 -m dns --qname "$_DB_DOMAIN" --rmatch -j DROP 2>/dev/null; do :; done
    while iptables -D "$CHAIN" -p tcp --dport 53 -m dns --qname "$_DB_DOMAIN" --rmatch -j DROP 2>/dev/null; do :; done
}

# add_domain_rules <domain> — clears any existing match for the domain
# first, then adds the UDP+TCP DNS-drop pair.
add_domain_rules() {
    _DB_DOMAIN="$1"
    [ -z "$_DB_DOMAIN" ] && return 1
    ensure_chain
    del_domain_rules "$_DB_DOMAIN"
    iptables -A "$CHAIN" -p udp --dport 53 -m dns --qname "$_DB_DOMAIN" --rmatch -j DROP 2>/dev/null
    iptables -A "$CHAIN" -p tcp --dport 53 -m dns --qname "$_DB_DOMAIN" --rmatch -j DROP 2>/dev/null
}

# Strip every domain's rules from the live chain, without touching the
# mib table itself — used when the capability switch is off, and as the
# building block for apply_all's disabled branch.
remove_all() {
    domain_list | while IFS= read -r _DB_D; do
        [ -n "$_DB_D" ] && del_domain_rules "$_DB_D"
    done
}

# apply_all — reconciles the live "domainblk" chain with current state:
# capability off -> every persisted domain's rules are torn down (so a
# disabled feature genuinely stops blocking instead of leaving stale
# DROPs behind); capability on -> rebuilt from DOMAIN_BLOCKING_TBL.
# iptables rules are volatile (lost on reboot); the mib values (both the
# table and the capability switch) are not — this is the boot-time
# bridge between the two, same role as ipacl.sh's apply_all. Called from
# www2/sh/startup.sh at boot (rc35), and from set_cap below for an
# immediate live sync when the switch is flipped from the UI.
apply_all() {
    ensure_chain
    if cap_enabled; then
        domain_list | while IFS= read -r _DB_D; do
            [ -n "$_DB_D" ] && add_domain_rules "$_DB_D"
        done
    else
        remove_all
    fi
}

# set_cap <0|1> — persists the capability switch and immediately
# reconciles the live rules to match, so toggling it in the UI takes
# effect without a reboot. Called from domainblk.cgi's action=set_cap.
set_cap() {
    mib set "$CAP_KEY" "$1"
    mib commit
    apply_all
}

# ── CLI dispatch (skipped when sourced with --lib) ────────────────────────
if [ -z "$DOMAINBLK_LIB_ONLY" ]; then
    case "$1" in
        apply_all) apply_all ;;
    esac
fi
