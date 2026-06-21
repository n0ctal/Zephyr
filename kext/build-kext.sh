#!/bin/bash
#
# Builds DisableTurboBoost.kext from source using the Command Line Tools
# (no Xcode). Produces ./DisableTurboBoost.kext, ad-hoc signed.
#
set -euo pipefail

cd "$(dirname "$0")"
SDK="$(xcrun --show-sdk-path)"
KHDRS="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
KPRIV="$SDK/System/Library/Frameworks/Kernel.framework/PrivateHeaders"
NAME="DisableTurboBoost"
BUNDLE="$NAME.kext"

echo "Compiling $NAME.cpp ..."
clang \
    -arch x86_64 \
    -target x86_64-apple-macos11.0 \
    -x c++ -std=c++17 \
    -mkernel -nostdinc -fno-builtin -fno-common \
    -fno-exceptions -fno-rtti -fno-stack-protector \
    -fno-strict-aliasing \
    -I"$KHDRS" -I"$KPRIV" \
    -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
    -O2 -Wall \
    -c "$NAME.cpp" -o "$NAME.o"

echo "Linking kext binary ..."
clang \
    -arch x86_64 \
    -target x86_64-apple-macos11.0 \
    -nostdlib \
    -Xlinker -kext \
    -Xlinker -object_path_lto -Xlinker "$NAME.lto.o" \
    "$NAME.o" \
    "$SDK/usr/lib/libkmod.a" \
    -o "$NAME"

echo "Assembling bundle ..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp "$NAME" "$BUNDLE/Contents/MacOS/$NAME"

# kmutil/kextload want sane ownership; ad-hoc sign so the bundle is well-formed.
codesign --force --sign - "$BUNDLE" 2>/dev/null || true

rm -f "$NAME.o" "$NAME.lto.o" "$NAME"

echo "Built $BUNDLE"
echo "Validate with:  kmutil inspect -b com.n0ctal.DisableTurboBoost --bundle-path $BUNDLE 2>/dev/null; codesign -dv $BUNDLE"
