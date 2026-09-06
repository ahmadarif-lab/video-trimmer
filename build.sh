#!/bin/bash
# Builds Video Trimmer.app and installs it into ~/Applications.
set -euo pipefail

cd "$(dirname "$0")"

APP="${1:-$HOME/Applications/VideoTrimmer.app}"
BIN="$APP/Contents/MacOS/VideoTrimmer"

echo "Building $APP"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library -O \
  Sources/Theme.swift \
  Sources/Models.swift \
  Sources/Engine.swift \
  Sources/BrewManager.swift \
  Sources/InputMonitor.swift \
  Sources/PlayerModel.swift \
  Sources/Thumbnails.swift \
  Sources/PlayerSurface.swift \
  Sources/Components.swift \
  Sources/App.swift \
  -o "$BIN" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Foundation \
  -framework AVKit \
  -framework AVFoundation \
  -framework UniformTypeIdentifiers

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough to run locally, no developer certificate required.
codesign --force --deep --sign - "$APP"

echo "Done. Launch with: open \"$APP\""
