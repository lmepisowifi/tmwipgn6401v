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


# Delete only this client's session file
BROWSER_SESSION=$(echo "$HTTP_COOKIE" | busybox sed -n 's/.*session=\([^;]*\).*/\1/p' | busybox tr -d '\r\n')
# Sanitize: session IDs are sha256 hex. Strip anything else to block
# path traversal (e.g. Cookie: session=../../config/foo) into rm -f.
BROWSER_SESSION=$(printf '%s' "$BROWSER_SESSION" | busybox tr -cd 'a-fA-F0-9')
if [ -n "$BROWSER_SESSION" ]; then
    rm -f "/tmp/sessions/$BROWSER_SESSION"
fi

printf "Status: 302 Found\r\n"
printf "Set-Cookie: session=; expires=Thu, 01 Jan 1970 00:00:00 UTC; Path=/; HttpOnly\r\n"
printf "Location: /login.html\r\n\r\n"