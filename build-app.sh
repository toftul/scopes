#!/usr/bin/env bash
# Build the SwiftPM executable and wrap it in a proper .app bundle so that
# ScreenCaptureKit's Screen Recording permission is attributed to "Vectorscope"
# (not your terminal). Works with just the Command Line Tools — no Xcode needed.
#
# Usage: ./build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Vectorscope"
BUNDLE="build/${APP_NAME}.app"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"
BIN=".build/${CONFIG}/${APP_NAME}"

echo "▸ Assembling ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/${APP_NAME}"
cp Info.plist "$BUNDLE/Contents/Info.plist"

# Prefer a stable identity so Screen Recording (TCC) permission persists across
# rebuilds. Note: our self-signed cert is untrusted-but-usable, so we look it up
# with `find-identity -p codesigning` WITHOUT `-v` (which filters to trusted).
SIGN_ID="${CODESIGN_ID:-Vectorscope Dev}"
if security find-identity -p codesigning | grep -q "$SIGN_ID"; then
    echo "▸ Signing with \"$SIGN_ID\"…"
    codesign --force --sign "$SIGN_ID" "$BUNDLE"
else
    echo "▸ No stable identity — ad-hoc signing (permission will NOT persist across rebuilds)."
    echo "  Run ./scripts/make-signing-cert.sh once to fix this."
    codesign --force --sign - "$BUNDLE"
fi

echo "✓ Built ${BUNDLE}"
echo "  Run it:  open \"${BUNDLE}\""
echo "  First launch will ask for Screen Recording permission — grant it, then relaunch."
