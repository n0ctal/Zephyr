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

# Without a paid certificate the first launch is refused, and the person who
# downloaded this has no way to know that is expected or what to do. The note
# rides in the window next to the app, where it cannot be missed; the number
# in the name keeps it first in the listing.
NOTE_SRC="$PROJECT_DIR/Resources/first-run.txt"
if [ -f "$NOTE_SRC" ]; then
    textutil -convert rtf -font "SF Pro Text" -fontsize 13 \
        -output "$STAGE/1 Read me first.rtf" "$NOTE_SRC"
else
    echo "    (no Resources/first-run.txt — packaging without the note)" >&2
fi

rm -f "$DMG"
hdiutil create -volname "Zephyr $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

echo "==> $DMG"
echo "    $(du -h "$DMG" | cut -f1)"
echo
echo "    Ad-hoc signed, so the first launch is refused on a machine with"
echo "    Gatekeeper on. The image carries \"1 Read me first.rtf\" saying so."
echo "    For yourself, the short way is still:"
echo "      xattr -dr com.apple.quarantine /Applications/Zephyr.app"
