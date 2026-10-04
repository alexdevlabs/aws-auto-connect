#!/usr/bin/env bash
# Regenerates the app icon from Assets/AppIcon.svg (needs Google Chrome for SVG rendering):
#   Assets/AppIcon-1024.png   master PNG (App Store, web)
#   Assets/AppIcon.iconset/   all macOS sizes
#   Resources/AppIcon.icns    bundled by scripts/bundle.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "Google Chrome is needed to render the SVG" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/index.html" <<HTML
<html><body style="margin:0;background:transparent">$(cat Assets/AppIcon.svg)</body></html>
HTML
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --window-size=1024,1024 --screenshot="$ROOT/Assets/AppIcon-1024.png" "file://$TMP/index.html" 2>/dev/null

SET=Assets/AppIcon.iconset
rm -rf "$SET" && mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s Assets/AppIcon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Assets/AppIcon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Wrote Assets/AppIcon-1024.png, $SET, Resources/AppIcon.icns"
