#!/bin/bash
# Builds the committed state in a clone of its own, away from this working
# copy, and runs everything the release path runs.
#
# What it is for: .build survives edits, so a tree that builds here can still
# be missing a file nobody added to git, or depend on something generated once
# and never committed. The only way to find that is to build somewhere that
# has never seen this directory.
#
# It clones the local repository rather than the remote, so it checks what is
# committed — including work that has not been pushed — and works offline.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REF="${1:-HEAD}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zephyr-clean-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "==> Cloning $REF out of $PROJECT_DIR"
git clone -q "$PROJECT_DIR" "$WORK"
git -C "$WORK" -c advice.detachedHead=false checkout -q "$(git -C "$PROJECT_DIR" rev-parse "$REF")"
echo "    at $(git -C "$WORK" rev-parse --short HEAD)"

# Anything uncommitted is invisible to this check by design; say so rather than
# letting somebody read a pass as covering work in progress.
if [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
    echo "    note: the working copy has uncommitted changes, which this does not see"
fi

cd "$WORK"
echo "==> swift build -c release"
swift build -c release

echo "==> self-test"
./.build/release/Zephyr --self-test

echo "==> bundle"
./build.sh >/dev/null
test -x "$WORK/Zephyr.app/Contents/MacOS/Zephyr" || { echo "bundle has no executable" >&2; exit 1; }

echo "==> disk image"
./scripts/make-dmg.sh >/dev/null
IMAGE="$(ls "$WORK"/*.dmg | head -1)"
test -s "$IMAGE" || { echo "no disk image produced" >&2; exit 1; }

# The note inside it is the one piece of the image nothing else checks, and it
# has been wrong twice.
MOUNT="$(hdiutil attach -nobrowse -readonly "$IMAGE" | tail -1 | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p')"
if [ -f "$MOUNT/1 Read me first.rtf" ]; then
    echo "    image carries the first-run note"
else
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    echo "the disk image is missing its first-run note" >&2
    exit 1
fi
hdiutil detach "$MOUNT" >/dev/null

echo "==> clean build reproduces: $(basename "$IMAGE")"
