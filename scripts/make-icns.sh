#!/bin/bash
# Renders the icon and builds Resources/AppIcon.icns with every size macOS uses.
# Usage: scripts/make-icns.sh
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
mkdir -p Resources "$WORK/AppIcon.iconset"
swift -O scripts/make-icon.swift Resources/AppIcon-1024.png
swift -O scripts/make-icon.swift "$WORK/small.png" small
for size in 16 32 128 256 512; do
    master=Resources/AppIcon-1024.png
    [[ $size -le 32 ]] && master="$WORK/small.png"
    sips -z $size $size "$master" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$master" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
rm -rf "$WORK"
echo "Wrote Resources/AppIcon.icns"
