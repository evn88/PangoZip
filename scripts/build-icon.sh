#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
master="Resources/Icons/AppIcon-master.png"
iconset="Resources/Icons/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/Icons/AppIcon.icns
