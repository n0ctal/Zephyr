#!/bin/bash
#
# Installs the MacBookControl privileged helper as a system LaunchDaemon.
# The daemon performs the few operations that require root (SMC fan writes,
# gpuswitch); everything else runs unprivileged in the app.
#
# Usage:  sudo ./scripts/install-helper.sh [path-to-binary]
# Default binary: .build/release/Zephyr, else .build/debug/Zephyr
#
set -euo pipefail

LABEL="com.n0ctal.macbookcontrol.helper"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Work whether run from the source tree (scripts/) or from inside the app
# bundle (Zephyr.app/Contents/Resources/scripts/).
if [[ "$SCRIPT_DIR" == *"/Contents/Resources/scripts" ]]; then
    BUNDLE_APP="$(cd "$SCRIPT_DIR/../../.." && pwd)"
    DEFAULT_HELPER_SRC="$BUNDLE_APP/Contents/MacOS/Zephyr"
    KEXT_SRC="$SCRIPT_DIR/../DisableTurboBoost.kext"
    DEFAULT_APP_FOR_PIN="$BUNDLE_APP"
else
    PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    if [ -f "$PROJECT_DIR/.build/release/Zephyr" ]; then
        DEFAULT_HELPER_SRC="$PROJECT_DIR/.build/release/Zephyr"
    else
        DEFAULT_HELPER_SRC="$PROJECT_DIR/.build/debug/Zephyr"
    fi
    KEXT_SRC="$PROJECT_DIR/kext/DisableTurboBoost.kext"
    DEFAULT_APP_FOR_PIN="$PROJECT_DIR/Zephyr.app"
fi

HELPER_DST="/Library/PrivilegedHelperTools/$LABEL"
PLIST_SRC="$SCRIPT_DIR/$LABEL.plist"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"

if [ "$EUID" -ne 0 ]; then
    echo "This script must run as root. Re-run with: sudo $0" >&2
    exit 1
fi

# Resolve the binary to install (explicit arg overrides the default).
HELPER_SRC="${1:-$DEFAULT_HELPER_SRC}"

if [ ! -f "$HELPER_SRC" ]; then
    echo "Binary not found: $HELPER_SRC (run 'swift build' first)" >&2
    exit 1
fi

echo "Installing helper from: $HELPER_SRC"

# Stop any previous instance.
launchctl bootout "system/$LABEL" 2>/dev/null || true

# Install the binary (root-owned, not group/other writable).
install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$HELPER_SRC" "$HELPER_DST"

# Install the launchd plist.
install -o root -g wheel -m 644 "$PLIST_SRC" "$PLIST_DST"

# Install the Turbo Boost kext (if present) where the helper expects it.
KEXT_DST_DIR="/Library/Application Support/MacBookControl"
if [ -d "$KEXT_SRC" ]; then
    echo "Installing Turbo Boost kext ..."
    install -d -o root -g wheel -m 755 "$KEXT_DST_DIR"
    rm -rf "$KEXT_DST_DIR/DisableTurboBoost.kext"
    cp -R "$KEXT_SRC" "$KEXT_DST_DIR/DisableTurboBoost.kext"
    chown -R root:wheel "$KEXT_DST_DIR/DisableTurboBoost.kext"
else
    echo "(Turbo Boost kext not built — run kext/build-kext.sh to enable it)"
fi

# Pin the authorized app's cdhash so only that exact binary may command the
# daemon (the daemon rejects every other XPC client).
install -d -o root -g wheel -m 755 "$KEXT_DST_DIR"
APP_FOR_PIN="/Applications/Zephyr.app"
[ -d "$APP_FOR_PIN" ] || APP_FOR_PIN="$DEFAULT_APP_FOR_PIN"
if [ -d "$APP_FOR_PIN" ]; then
    CDHASH="$(codesign -dvvv "$APP_FOR_PIN" 2>&1 | awk -F= 'tolower($1)=="cdhash"{print $2; exit}')"
    if [ -n "$CDHASH" ]; then
        printf '%s' "$CDHASH" > "$KEXT_DST_DIR/authorized-cdhash"
        chown root:wheel "$KEXT_DST_DIR/authorized-cdhash"
        chmod 644 "$KEXT_DST_DIR/authorized-cdhash"
        echo "Authorized app cdhash: $CDHASH"
    else
        echo "WARNING: could not read cdhash from $APP_FOR_PIN — daemon will deny all clients" >&2
    fi
else
    echo "WARNING: Zephyr.app not found — install it to /Applications, then re-run to authorize it" >&2
fi

# Load it.
launchctl bootstrap system "$PLIST_DST"

echo "Installed. Daemon will start on first use — open Zephyr, control is now enabled."
