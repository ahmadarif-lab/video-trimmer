#!/bin/bash
# Builds the app and packages it into a distributable .dmg.
set -euo pipefail

cd "$(dirname "$0")"

VOLUME_NAME="Video Trimmer"
DIST="dist"
DMG="$DIST/VideoTrimmer.dmg"

rm -rf "$DIST"
mkdir -p "$DIST"

# Build a fresh copy inside dist/ so the DMG never depends on what's in ~/Applications.
APP="$DIST/VideoTrimmer.app"
./build.sh "$PWD/$APP"

# Staging folder: the app plus a shortcut to /Applications for drag-to-install.
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG"

echo
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
