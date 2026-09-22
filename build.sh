#!/bin/bash
#
# Builds MacBookControl.app (a menu-bar / LSUIElement app) from the SwiftPM
# executable — no Xcode required. Ad-hoc signs so it launches locally.
#
# Usage:  ./build.sh [debug|release]   (default: release)
#
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="Zephyr"
BUNDLE_ID="com.n0ctal.macbookcontrol"   # legacy id kept so the installed helper/agent keep working
# The version a person reads, and the one only a machine compares.
#
# MAJOR is the only part chosen by hand: it goes to 1 when the design is
# finished and not before, which is the whole reason the rest is arithmetic.
# The other two come from the commit count — 50 commits to a minor — so the
# number cannot be forgotten, cannot be argued about, and says how much work
# is behind the build without pretending to say anything else.
#
# CFBundleVersion is the count itself. It is the field anything that compares
# versions actually reads, and it only ever goes up, even on a day when MAJOR
# is reset downwards by hand.
MAJOR=0
COMMITS="$(git -C "$(dirname "$0")" rev-list --count HEAD 2>/dev/null || echo 0)"
if [ "$COMMITS" -eq 0 ]; then
    # Built from something that is not a checkout. Better a version that says
    # so than one that quietly claims to be the first commit.
    VERSION="$MAJOR.0.0-unknown"
    BUILD="0"
else
    VERSION="$MAJOR.$((COMMITS / 50)).$((COMMITS % 50))"
    BUILD="$COMMITS"
fi

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/$CONFIG"
APP_DIR="$PROJECT_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

# A suite nothing runs guards nothing. This is the gate: the binary that is
# about to be bundled runs its own regression checks, and a failure stops the
# build before anything is signed or shipped.
# Cheap, and it guards a failure nothing else can see: a preference a feature
# reads once and can never re-read stops taking effect the moment the settings
# window (another process now) changes it.
echo "==> reload mirrors init"
"$PROJECT_DIR/scripts/check-reload-mirrors-init.sh"

echo "==> self-test"
if ! "$(swift build -c "$CONFIG" --show-bin-path)/Zephyr" --self-test; then
    echo "Self-test failed — not building the bundle." >&2
    exit 1
fi

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

# Local symbols are half the binary — 4.5 MB down to 2.1 — and nothing at run
# time reads them: Swift's own metadata, which reflection and Codable need,
# lives in __TEXT and __DATA and is untouched. What they are for is
# symbolicating a crash, and the unstripped binary stays in $BUILD_DIR for
# exactly that. Before the signing, because stripping invalidates it.
strip -x "$APP_DIR/Contents/MacOS/$APP_NAME"

# App icon (generate the .icns if it isn't present yet).
if [ ! -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    echo "==> Generating app icon"
    swift "$PROJECT_DIR/scripts/make-icon.swift" "$PROJECT_DIR/Resources" >/dev/null 2>&1 || true
    iconutil -c icns "$PROJECT_DIR/Resources/AppIcon.iconset" \
        -o "$PROJECT_DIR/Resources/AppIcon.icns" 2>/dev/null || true
fi
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleVersion</key>         <string>$BUILD</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHumanReadableCopyright</key><string>Open source</string>
</dict>
</plist>
PLIST

# Bundle the privileged-helper installer inside the app so "Install helper…"
# works wherever the app lives (e.g. /Applications). Must happen before signing.
echo "==> Bundling helper installer + kext"
mkdir -p "$APP_DIR/Contents/Resources/scripts"
cp "$PROJECT_DIR/scripts/install-helper.sh" \
   "$PROJECT_DIR/scripts/uninstall-helper.sh" \
   "$PROJECT_DIR/scripts/install-power-kext.sh" \
   "$PROJECT_DIR/scripts/$BUNDLE_ID.helper.plist" \
   "$APP_DIR/Contents/Resources/scripts/" 2>/dev/null || true
for k in DisableTurboBoost ZephyrPower; do
    if [ -d "$PROJECT_DIR/kext/$k.kext" ]; then
        cp -R "$PROJECT_DIR/kext/$k.kext" "$APP_DIR/Contents/Resources/"
    fi
done

# Ad-hoc signature (no Developer ID needed for local use).
echo "==> Ad-hoc codesign"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || \
    codesign --force --sign - "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "==> Done: $APP_DIR"
echo
echo "    Replacing the copy in /Applications (sudo: an installed bundle is"
echo "    root-owned, and the helper only accepts the build it was pinned to):"
echo "      osascript -e 'quit app \"Zephyr\"'; sleep 1"
echo "      sudo rm -rf /Applications/Zephyr.app"
echo "      sudo cp -R \"$APP_DIR\" /Applications/"
echo "      sudo \"/Applications/Zephyr.app/Contents/Resources/scripts/install-helper.sh\""
echo "      open /Applications/Zephyr.app"
echo "    Launch:  open \"$APP_DIR\""
echo "    Helper:  sudo \"$PROJECT_DIR/scripts/install-helper.sh\""
