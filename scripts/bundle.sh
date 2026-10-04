#!/usr/bin/env bash
# Builds "build/AWS AutoConnect.app" (ad-hoc signed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -x Resources/openvpn ] || scripts/build-openvpn.sh

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/AWS AutoConnect.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AWSAutoConnect" "$APP/Contents/MacOS/AWSAutoConnect"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/openvpn Resources/AppIcon.icns "$BIN_DIR/dns-relay" helper/* "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
du -sh "$APP"
