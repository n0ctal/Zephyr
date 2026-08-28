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
VERSION="1.9.56"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/$CONFIG"
APP_DIR="$PROJECT_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

# A suite nothing runs guards nothing. This is the gate: the binary that is
# about to be bundled runs its own regression checks, and a failure stops the
# build before anything is signed or shipped.
echo "==> self-test"
if ! "$(swift build -c "$CONFIG" --show-bin-path)/Zephyr" --self-test; then
    echo "Self-test failed — not building the bundle." >&2
    exit 1
fi

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

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
    <key>CFBundleVersion</key>         <string>$VERSION</string>
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
