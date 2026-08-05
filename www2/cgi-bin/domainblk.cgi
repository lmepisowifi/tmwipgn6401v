#!/bin/sh
# domainblk.cgi — Domain-based DNS blocking, backed by DOMAIN_BLOCKING_TBL.
#
# GET  ?action=list          → current blocked domains (JSON)
# POST ?action=add   body: domain=<name>
#       → validates, mib add + set + commit, applies iptables DNS-drop
#         rules immediately (domainblk.sh) — no reboot/restart needed
# POST ?action=del   body: idx=<n>
#       → mib del + commit, removes the matching iptables rules immediately

SESSION_TIMEOUT=600

# ── Auth ──────────────────────────────────────────────────────────────────────
BROWSER_SESSION=$(echo "$HTTP_COOKIE" \
    | busybox sed -n 's/.*session=\([^;]*\).*/\1/p' \
    | busybox tr -d '\r\n')
BROWSER_SESSION=$(printf '%s' "$BROWSER_SESSION" \
    | busybox tr -cd 'a-fA-F0-9')
SESSION_FILE="/tmp/sessions/$BROWSER_SESSION"

if [ -z "$BROWSER_SESSION" ] || [ ! -f "$SESSION_FILE" ]; then
    printf "Status: 302 Found\r\nLocation: /login.html\r\n\r\n"
    exit 0
fi

LAST=$(cat "$SESSION_FILE" 2>/dev/null | busybox tr -d '\r\n')
NOW=$(date +%s)
[ -z "$LAST" ] && LAST=$NOW
if [ $((NOW - LAST)) -gt $SESSION_TIMEOUT ]; then
    rm -f "$SESSION_FILE"
    printf "Status: 302 Found\r\nLocation: /login.html\r\n\r\n"
    exit 0
fi

_STMP=$(mktemp /tmp/sessions/.tmp.XXXXXX)
echo "$NOW" > "$_STMP"
busybox mv "$_STMP" "$SESSION_FILE"

# ── Shared logic (functions only — see domainblk.sh for the actual rules) ────
. /lmepisowifi/www2/sh/domainblk.sh --lib

json_esc() { printf '%s' "$1" | busybox sed 's/\\/\\\\/g; s/"/\\"/g'; }

TABLE_KEY="DOMAIN_BLOCKING_TBL"

# Lowercase + strip whitespace/CRLF. Charset is enforced separately at the
# add site (a-z0-9.- only), so nothing here needs JSON escaping downstream.
normalize_domain() {
    printf '%s' "$1" | busybox tr 'A-Z' 'a-z' | busybox tr -d ' \r\n'
}

# ════════════════════════════════════════════════════════════════════════════
# GET
# ════════════════════════════════════════════════════════════════════════════
if [ "$REQUEST_METHOD" = "GET" ]; then

    ACTION=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*action=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')

    if [ "$ACTION" = "list" ]; then
        JSON=$(mib get "$TABLE_KEY" 2>/dev/null | busybox awk -v tbl="$TABLE_KEY" '
        BEGIN { out = ""; sep = ""; idx = "" }
        {
            if (index($0, tbl ".") == 1 && substr($0, length($0), 1) == ":") {
                s = substr($0, length(tbl) + 2)
                sub(/:.*/, "", s)
                idx = s
            }
            if ($0 ~ /DOMAIN[ \t]*=/) {
                d = $0
                sub(/^[^=]*=[ \t]*/, "", d)
                gsub(/\r/, "", d)
                if (d != "") {
                    out = out sep "{\"idx\":" idx ",\"domain\":\"" d "\"}"
                    sep = ","
                }
            }
        }
        END { print "[" out "]" }
        ')

        CAP=0
        cap_enabled && CAP=1

        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"ok":true,"capability":%s,"domains":%s}' "$CAP" "$JSON"
        exit 0
    fi

    printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
    printf "Unknown action"
    exit 0
fi

# ════════════════════════════════════════════════════════════════════════════
# POST
# ════════════════════════════════════════════════════════════════════════════
if [ "$REQUEST_METHOD" = "POST" ]; then

    __CL="${CONTENT_LENGTH:-0}"
    case "$__CL" in *[!0-9]*|"") __CL=0 ;; esac
    [ "$__CL" -gt 65536 ] && __CL=65536
    POST_DATA=$(busybox dd bs=1 count="$__CL" 2>/dev/null)

    ACTION=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*action=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')

    # ── action=set_cap ──────────────────────────────────────────────────
    # Master on/off switch. On -> off tears down every persisted domain's
    # live rules (set_cap calls apply_all internally); off -> on rebuilds
    # them. Either way the mib table of domains itself is untouched.
    if [ "$ACTION" = "set_cap" ]; then
        CAP=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*cap=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')

        case "$CAP" in
            0|1) ;;
            *)
                printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
                printf "Invalid value"
                exit 0
                ;;
        esac

        set_cap "$CAP"

        printf "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n"
        printf '{"ok":true,"capability":%s}' "$CAP"
        exit 0
    fi

    # ── action=add ──────────────────────────────────────────────────────
    if [ "$ACTION" = "add" ]; then
        DOM_RAW=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*domain=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        DOM_DEC=$(busybox httpd -d "$DOM_RAW" | busybox tr -d '\r\n')
        DOMAIN=$(normalize_domain "$DOM_DEC")

        case "$DOMAIN" in
            ''|*[!a-z0-9.-]*)
                printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
                printf "Invalid domain (letters, digits, dots, hyphens only)"
                exit 0
                ;;
        esac
        if [ "${#DOMAIN}" -gt 253 ]; then
            printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
            printf "Domain too long"
            exit 0
        fi

        if mib get "$TABLE_KEY" 2>/dev/null \
                | busybox grep -i "DOMAIN" \
                | busybox grep -qi "= *${DOMAIN}\$"; then
            printf "Status: 409 Conflict\r\nContent-Type: text/plain\r\n\r\n"
            printf "Domain already blocked"
            exit 0
        fi

        ADD_OUT=$(mib add "$TABLE_KEY" 2>/dev/null)
        NEW_NUM=$(echo "$ADD_OUT" \
            | busybox grep "NUM=" \
            | busybox awk -F= '{print $2}' \
            | busybox tr -d ' \r\n')
        case "$NEW_NUM" in
            ''|*[!0-9]*)
                printf "Status: 500 Internal Server Error\r\nContent-Type: text/plain\r\n\r\n"
                printf "Failed to allocate table entry"
                exit 0
                ;;
        esac
        NEW_IDX=$((NEW_NUM - 1))

        mib set "${TABLE_KEY}.${NEW_IDX}.DOMAIN" "$DOMAIN"
        mib commit

        # Apply immediately — live iptables rules, no reboot or restart.
        # Only pushed if the capability switch is on; otherwise this just
        # persists to the mib for when it's turned on later.
        cap_enabled && add_domain_rules "$DOMAIN"

        printf "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n"
        printf '{"ok":true,"idx":%s,"domain":"%s"}' "$NEW_IDX" "$(json_esc "$DOMAIN")"
        exit 0
    fi

    # ── action=del ──────────────────────────────────────────────────────
    if [ "$ACTION" = "del" ]; then
        DEL_IDX=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*idx=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')

        case "$DEL_IDX" in
            ''|*[!0-9]*)
                printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
                printf "Invalid index"
                exit 0
                ;;
        esac

        # Read the domain string before deleting the mib entry — the
        # iptables rule is keyed on --qname <domain>, not on the mib
        # index, so we need the value in hand to remove it afterward.
        DEL_DOMAIN=$(mib get "${TABLE_KEY}.${DEL_IDX}.DOMAIN" 2>/dev/null \
            | busybox grep "=" \
            | busybox cut -d'=' -f2- \
            | busybox tr -d ' \r\n')

        mib del "${TABLE_KEY}.${DEL_IDX}"
        mib commit

        [ -n "$DEL_DOMAIN" ] && del_domain_rules "$DEL_DOMAIN"

        printf "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n"
        printf '{"ok":true}'
        exit 0
    fi
fi

# Fallback
printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
printf "Bad request"
