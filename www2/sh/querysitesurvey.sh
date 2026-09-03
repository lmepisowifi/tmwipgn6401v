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


# 1. Capture the input argument (0 or 1)
INPUT=$1

# POSIX-compliant validation (works on all minimal shells)
case "$INPUT" in
    0|1) ;;
    *)
        echo "Error: Please provide 0 or 1 as an argument (e.g., $0 0)"
        exit 1
        ;;
esac

# Construct the interface name
INTERFACE="wlan${INPUT}"

# 2. Check if the interface exists and is UP using ifconfig (highly compatible)
if ! ifconfig "$INTERFACE" 2>/dev/null | grep -q "UP"; then
    echo "Error: Interface $INTERFACE is not UP or does not exist."
    echo "To try bringing it up, run: ifconfig $INTERFACE up"
    exit 1
fi

echo "Interface $INTERFACE is UP. Proceeding with site survey..."

# 3. Trigger the site survey
iwpriv "$INTERFACE" at_ss 1

# Wait until the "waitting" status is cleared
while grep -q "waitting" "/proc/$INTERFACE/SS_Result" 2>/dev/null; do
    sleep 1
done

# Print the final clean result
cat "/proc/$INTERFACE/SS_Result"

