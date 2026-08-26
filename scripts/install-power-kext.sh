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

# The boot-time loader goes in BEFORE the first load attempt. macOS stages a
# third-party extension and asks for a restart before it will run it, and after
# that restart something has to load it — if this were installed only on a
# successful load it would never be installed at all.
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

echo "Loading ..."
# Nothing is removed on failure. An earlier version deleted the copy whenever
# kmutil returned non-zero, which included the perfectly normal "staged, needs
# a restart" answer — so the restart it asked for had nothing left to load.
LOAD_OUTPUT="$(kmutil load -p "$DST_DIR/$NAME.kext" 2>&1)" && LOAD_RC=0 || LOAD_RC=$?
[ -n "$LOAD_OUTPUT" ] && echo "$LOAD_OUTPUT"

echo
if sysctl -n kern.zephyr_power_limit >/dev/null 2>&1; then
    LIMIT=$(sysctl -n kern.zephyr_power_limit)
    LOCKED=$(( (LIMIT >> 63) & 1 ))
    echo "Loaded. MSR 0x610 = $LIMIT"
    if [ "$LOCKED" -eq 1 ]; then
        echo "  The firmware has LOCKED this register. Zephyr can read the limits"
        echo "  but not change them, and no software can — that is a hardware"
        echo "  decision, not a limitation of this app."
    else
        echo "  Not locked. The Power tab can set the limits."
    fi
    echo
    echo "The power limit is written by the privileged helper, which this release"
    echo "also updates. If the menu still shows an older helper, run:"
    echo "  sudo \"$SCRIPT_DIR/install-helper.sh\""
    exit 0
fi

# Not loaded yet. Staging is the normal path for a third-party extension, and
# it is not a failure — the difference matters, because one needs a restart and
# the other needs a fix.
if printf '%s' "$LOAD_OUTPUT" | grep -qi "restart\|staged\|reboot"; then
    echo "Staged. macOS will not run a new system extension until the machine"
    echo "restarts, which is what System Settings is asking for."
    echo
    echo "Everything is in place and will stay there: the extension is at"
    echo "  $DST_DIR/$NAME.kext"
    echo "and the boot-time loader at"
    echo "  $DAEMON"
    echo
    echo "Restart, then open Zephyr — the Power tab will show the limits, or say"
    echo "the firmware has locked the register. To check from Terminal instead:"
    echo "  sysctl kern.zephyr_power_limit"
    exit 0
fi

# Code 27 is the ordinary "a human has to say yes" answer, not a fault. It
# needs a click that no script is allowed to make on the user's behalf, so the
# only useful thing to do is say exactly where the click is.
if [ "$LOAD_RC" -eq 27 ] || printf '%s' "$LOAD_OUTPUT" | grep -qi "not approved"; then
    echo "macOS is asking you to approve it, which no script may do for you."
    echo
    echo "  1. Open System Settings, then Privacy & Security."
    echo "  2. Scroll to the bottom, to Security. There is a line about system"
    echo "     software being blocked, with an Allow button."
    echo "  3. Allow it, then restart."
    echo
    echo "Approval is per bundle: the Turbo Boost extension being allowed"
    echo "already does not carry over to this one."
    echo
    echo "Everything stays in place — the extension at"
    echo "  $DST_DIR/$NAME.kext"
    echo "and the boot-time loader at"
    echo "  $DAEMON"
    echo "so after the restart it loads on its own. If the Allow line is not"
    echo "there, run this script again to make macOS ask."
    echo
    echo "There is a way to skip the approval entirely, and it is worth knowing"
    echo "what it costs: 'sudo spctl kext-consent disable' lets ANY unsigned"
    echo "extension load from then on, not just this one. Not recommended, and"
    echo "deliberately not done for you."
    exit 0
fi

echo "The extension did not load and did not ask for a restart (kmutil exit $LOAD_RC)." >&2
echo "Nothing has been removed, so this can be retried after fixing the cause." >&2
echo "Look at what the kernel said with:" >&2
echo "  log show --last 5m --predicate 'sender == \"kernel\"' | grep -i zephyr" >&2
exit 1
