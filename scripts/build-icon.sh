#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Иконка собирается в build/: sips разных версий macOS даёт побайтно разные PNG,
# и пересборка поверх файлов в репозитории оставляла рабочую копию изменённой
# (выпуск релиза из такой копии отказывается публиковать тег).
master="Resources/Icons/AppIcon-master.png"
output="build/Icons"
iconset="$output/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$output/AppIcon.icns"
