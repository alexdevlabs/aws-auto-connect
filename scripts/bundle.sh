#!/usr/bin/env bash
# Builds "build/AWS AutoConnect.app" (ad-hoc signed).
# SWIFT_BUILD_FLAGS adds flags to `swift build` (Homebrew passes --disable-sandbox).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -x Resources/openvpn ] || scripts/build-openvpn.sh

# shellcheck disable=SC2086
swift build -c release ${SWIFT_BUILD_FLAGS:-}
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c release ${SWIFT_BUILD_FLAGS:-} --show-bin-path)"

APP="$ROOT/build/AWS AutoConnect.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AWSAutoConnect" "$APP/Contents/MacOS/AWSAutoConnect"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/openvpn Resources/AppIcon.icns "$BIN_DIR/dns-relay" helper/* "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
du -sh "$APP"
