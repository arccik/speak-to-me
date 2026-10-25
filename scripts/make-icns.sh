#!/bin/bash
# Renders the icon (default variant: bubble) and builds Resources/AppIcon.icns with every size macOS uses.
# Usage: scripts/make-icns.sh [orb|bubble|smile]
set -euo pipefail
cd "$(dirname "$0")/.."
VARIANT="${1:-bubble}"
WORK=$(mktemp -d)
mkdir -p Resources "$WORK/AppIcon.iconset"
swift scripts/make-icon.swift Resources/AppIcon-1024.png "$VARIANT"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon-1024.png --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double Resources/AppIcon-1024.png --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
rm -rf "$WORK"
echo "Wrote Resources/AppIcon.icns ($VARIANT)"
