#!/bin/bash
#
# Removes the MacBookControl privileged helper LaunchDaemon.
# Usage:  sudo ./scripts/uninstall-helper.sh
#
set -euo pipefail

LABEL="com.n0ctal.macbookcontrol.helper"
HELPER_DST="/Library/PrivilegedHelperTools/$LABEL"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"

if [ "$EUID" -ne 0 ]; then
    echo "This script must run as root. Re-run with: sudo $0" >&2
    exit 1
fi

# Return fans to automatic before tearing the daemon down, in case a fan
# is currently forced (the firmware otherwise keeps the last target briefly).
launchctl bootout "system/$LABEL" 2>/dev/null || true

rm -f "$PLIST_DST" "$HELPER_DST"

echo "Uninstalled $LABEL."
