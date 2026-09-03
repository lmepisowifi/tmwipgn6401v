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

# check_lockout.cgi — reports the current global login-lockout state so
# login.html can reflect it even on a fresh page load (no ?locked=/?error=
# query string), e.g. a lockout tripped from a different tab/device.
#
# Output (text/plain): "locked <secs_remaining>" or "ok <attempts_remaining>"

. /lmepisowifi/www2/sh/auth_lockout.sh --lib

printf "Content-Type: text/plain\r\n\r\n"
lockout_status
