#!/bin/bash
# Packages the built Zephyr.app into a disk image with the usual drag-to-install
# layout. Run ./build.sh first — this does not build, it only wraps.
#
# Written down because the two images already in the tree were made by hand,
# which is how a release ends up subtly different from the last one.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$PROJECT_DIR/Zephyr.app"
[ -d "$APP" ] || { echo "No Zephyr.app — run ./build.sh first."; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist")"
DMG="$PROJECT_DIR/Zephyr-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
# The symlink is what makes the window a drag-and-drop install rather than a
# folder someone has to know what to do with.
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Zephyr $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

echo "==> $DMG"
echo "    $(du -h "$DMG" | cut -f1)"
echo
echo "    Ad-hoc signed, so Gatekeeper will refuse it on first open:"
echo "    right-click the app, Open, then Open again. Or:"
echo "      xattr -dr com.apple.quarantine /Applications/Zephyr.app"
