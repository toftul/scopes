#!/usr/bin/env bash
# Build a distributable, universal (arm64 + x86_64) Vectorscope.app and zip it
# for a GitHub release. Used both locally and by .github/workflows/release.yml.
#
# Usage: ./scripts/release.sh [version]     # e.g. ./scripts/release.sh 0.2.0
#        (default: the version already in Info.plist; a leading "v" is stripped)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Vectorscope"
RAW_VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
VERSION="${RAW_VERSION#v}"
# Stage into build/release/ — deliberately NOT build/Vectorscope.app, which is
# build-app.sh's dev bundle signed with the stable "Vectorscope Dev" identity.
# Clobbering it with this ad-hoc-signed bundle changes its code signature and
# silently drops the dev app's Screen Recording grant.
BUNDLE="build/release/${APP_NAME}.app"
ZIP="build/${APP_NAME}-${VERSION}-universal.zip"

echo "▸ Building universal release (arm64 + x86_64), version ${VERSION}…"
swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/${APP_NAME}"

echo "▸ Assembling ${BUNDLE}…"
rm -rf "$BUNDLE" "$ZIP"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/${APP_NAME}"
cp Info.plist "$BUNDLE/Contents/Info.plist"

# Stamp the release version so Finder/About match the git tag.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$BUNDLE/Contents/Info.plist"

# Ad-hoc sign, deliberately NOT the local "Vectorscope Dev" identity: that cert
# is self-signed and exists only on this machine, so it buys downloaders nothing
# and can't be notarised. An ad-hoc signature is stable for a given binary, so
# Screen Recording permission still persists for users until they update.
echo "▸ Ad-hoc signing…"
codesign --force --sign - "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"

# ditto (not `zip`) — it preserves the bundle's symlinks, resource forks and the
# code signature. A plain `zip` can produce an app macOS refuses to launch.
echo "▸ Zipping ${ZIP}…"
ditto -c -k --keepParent "$BUNDLE" "$ZIP"

echo "✓ ${ZIP}"
lipo -info "$BUNDLE/Contents/MacOS/${APP_NAME}"
shasum -a 256 "$ZIP"
