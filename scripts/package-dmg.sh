#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

skip_build=false
if [[ "${1:-}" == --skip-build ]]; then skip_build=true; shift; fi
if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--skip-build]" >&2
  exit 2
fi
if [[ "$skip_build" != true ]]; then ./scripts/build-app.sh release; fi
app="$(pwd)/build/PangoZip.app"
[[ -d "$app" ]] || { echo "Built app not found: $app" >&2; exit 1; }
codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*([.-][A-Za-z0-9]+)*$ ]] || { echo "Invalid bundle version: $version" >&2; exit 1; }
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
[[ "$identifier" == app.pangozip.desktop ]] || { echo "Invalid application bundle" >&2; exit 1; }

# Имя образа отражает архитектуру всего приложения, а не универсального движка 7-Zip.
architecture_name() {
  local architectures
  architectures="$(lipo -archs "$1")"
  case "$architectures" in
    arm64|x86_64) echo "$architectures" ;;
    'arm64 x86_64'|'x86_64 arm64') echo universal2 ;;
    *) echo "Unsupported architectures: $architectures" >&2; return 1 ;;
  esac
}
architecture="$(architecture_name "$app/Contents/MacOS/PangoZip")"
for executable in \
  Contents/MacOS/PangoZip \
  Contents/Helpers/PangoZipWorker.app/Contents/MacOS/PangoZip \
  Contents/PlugIns/PangoZipFinderSync.appex/Contents/MacOS/PangoZipFinderSync \
  Contents/Helpers/PangoZipUninstall; do
  [[ -x "$app/$executable" ]] || { echo "Missing component: $executable" >&2; exit 1; }
  [[ "$(architecture_name "$app/$executable")" == "$architecture" ]] || { echo "Architecture mismatch: $executable" >&2; exit 1; }
done
# Сохраняем лицензии и полные соответствующие исходники в обоих комплектах движка.
for bundle in "$app" "$app/Contents/Helpers/PangoZipWorker.app"; do
  for resource in LICENSE THIRD_PARTY_NOTICES.md Engine/7zz Engine/License.txt Engine/PROVENANCE.md Engine/Licenses/LGPL-2.1.txt Engine/Licenses/unRarLicense.txt; do
    [[ -s "$bundle/Contents/Resources/$resource" ]] || { echo "Missing resource: $resource" >&2; exit 1; }
  done
  shopt -s nullglob
  sources=("$bundle"/Contents/Resources/Engine/Source/7z*-src.tar.xz)
  shopt -u nullglob
  [[ ${#sources[@]} -gt 0 ]] || { echo "Missing 7-Zip source archive" >&2; exit 1; }
  for source in "${sources[@]}"; do [[ -s "$source" ]] || exit 1; done
  for cpu in $(lipo -archs "$app/Contents/MacOS/PangoZip"); do
    lipo -verify_arch "$cpu" "$bundle/Contents/Resources/Engine/7zz"
  done
done

mkdir -p build
workspace="$(mktemp -d "$(pwd)/build/.PangoZip.dmg.XXXXXX")"
# Удаляем только созданную этой командой временную папку, включая незавершённый образ.
cleanup() {
  local status=$?
  rm -rf "$workspace"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
payload="$workspace/payload"
mkdir "$payload"
ditto "$app" "$payload/PangoZip.app"
cp scripts/install-app.sh "$payload/Install PangoZip.command"
cp scripts/uninstall-app.sh "$payload/Uninstall PangoZip.command"
cp docs/installation.txt "$payload/Read me.txt"
chmod +x "$payload/Install PangoZip.command" "$payload/Uninstall PangoZip.command"
codesign --verify --deep --strict "$payload/PangoZip.app"
output="$(pwd)/build/PangoZip-$version-$architecture.dmg"
# Готовый файл заменяется только после проверки сжатого образа UDZO.
hdiutil create -srcfolder "$payload" -fs HFS+ -format UDZO -imagekey zlib-level=9 -volname "PangoZip $version" "$workspace/PangoZip.dmg"
hdiutil verify "$workspace/PangoZip.dmg"
mv -f "$workspace/PangoZip.dmg" "$output"
echo "Packaged: $output"
