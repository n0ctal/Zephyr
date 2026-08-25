#!/bin/bash
#
# Installs and loads ZephyrPower.kext, which publishes the Intel package power
# limit (MSR 0x610) to userspace over three sysctls.
#
# Separate from install-helper.sh on purpose. The helper is what makes fans,
# GPU and the charge ceiling work at all; this one is optional, needs System
# Integrity Protection disabled, and puts code in the kernel. That is a
# decision worth making deliberately rather than as a side effect of installing
# an app, so it is its own command.
#
# Run:  sudo ./install-power-kext.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="ZephyrPower"
BUNDLE_ID="com.n0ctal.$NAME"
DST_DIR="/Library/Application Support/MacBookControl"
DAEMON="/Library/LaunchDaemons/$BUNDLE_ID.plist"

# Bundled inside the app, or sitting in the source tree during development.
for candidate in "$SCRIPT_DIR/../$NAME.kext" "$SCRIPT_DIR/../kext/$NAME.kext"; do
    if [ -d "$candidate" ]; then SRC="$candidate"; break; fi
done
if [ -z "${SRC:-}" ]; then
    echo "$NAME.kext not found. Build it with kext/build-kext.sh $NAME" >&2
    exit 1
fi

if csrutil status | grep -q "enabled"; then
    echo "System Integrity Protection is enabled, so an unsigned kext cannot load." >&2
    echo "Nothing has been installed." >&2
    exit 1
fi

echo "Installing $NAME.kext ..."
mkdir -p "$DST_DIR"
rm -rf "${DST_DIR:?}/$NAME.kext"
cp -R "$SRC" "$DST_DIR/$NAME.kext"
chown -R root:wheel "$DST_DIR/$NAME.kext"

echo "Loading ..."
kmutil load -p "$DST_DIR/$NAME.kext"

# Without this the sysctls disappear at the next reboot and the Power tab
# quietly goes back to "not available" with no explanation.
echo "Installing the boot-time loader ..."
cat > "$DAEMON" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/kmutil</string>
        <string>load</string>
        <string>-p</string>
        <string>$DST_DIR/$NAME.kext</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST
chown root:wheel "$DAEMON"
chmod 644 "$DAEMON"

echo
echo "Checking the registers are readable ..."
if sysctl -n kern.zephyr_power_limit >/dev/null 2>&1; then
    LIMIT=$(sysctl -n kern.zephyr_power_limit)
    LOCKED=$(( (LIMIT >> 63) & 1 ))
    echo "  MSR 0x610 = $LIMIT"
    if [ "$LOCKED" -eq 1 ]; then
        echo "  The firmware has LOCKED this register. Zephyr can read the limits but"
        echo "  not change them, and no software can — that is a hardware decision."
    else
        echo "  Not locked. The Power tab can set the limits."
    fi
else
    echo "  The sysctls did not appear. The kext may have been refused; check:" >&2
    echo "    log show --last 2m --predicate 'sender == \"kernel\"' | grep -i zephyr" >&2
    exit 1
fi
