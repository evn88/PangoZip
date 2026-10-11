#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/signing.sh
configure_signing

skip_build=false
if [[ "${1:-}" == --skip-build ]]; then skip_build=true; shift; fi
if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--skip-build]" >&2
  exit 2
fi
if [[ "$skip_build" != true ]]; then ./scripts/build-app.sh release; fi
app="${PANGOZIP_APP_PATH:-$(pwd)/build/PangoZip.app}"
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
    lipo "$bundle/Contents/Resources/Engine/7zz" -verify_arch "$cpu"
  done
done

mkdir -p build
workspace="$(mktemp -d "$(pwd)/build/.PangoZip.dmg.XXXXXX")"
# Удаляем только созданную этой командой временную папку, включая незавершённый образ.
cleanup() {
  local status="${1:-$?}"
  rm -rf "$workspace"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
payload="$workspace/payload"
mkdir "$payload"
ditto "$app" "$payload/PangoZip.app"
ln -s /Applications "$payload/Applications"
if [[ "$signing_identity" == - ]]; then
  cp docs/installation.txt "$payload/Read me.txt"
else
  verify_distribution_app "$app"
  # Нотариализация выполняется после упаковки; не обещаем её в ещё не принятом образе.
  sed -e 's/Текущая сборка подписана ad hoc, без сертификата Developer ID и нотариализации Apple, поэтому предупреждение Gatekeeper может появиться./Сборка подписана сертификатом Developer ID Application. Статус нотариализации указан в описании релиза./' \
      -e 's/Текущая сборка подписана ad hoc, без сертификата Developer ID и нотариализации Apple. Это не подтверждённая Apple подпись разработчика; macOS может заблокировать открытие загруженного приложения./Сборка подписана сертификатом Developer ID Application. До публикации релиз должен пройти нотариализацию Apple./' \
      docs/installation.txt > "$payload/Read me.txt"
fi
codesign --verify --deep --strict "$payload/PangoZip.app"
output_directory="${PANGOZIP_DMG_DIRECTORY:-$(pwd)/build}"
mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
output="$output_directory/PangoZip-$version-$architecture.dmg"
# Готовый файл заменяется только после проверки сжатого образа UDZO.
hdiutil create -srcfolder "$payload" -fs HFS+ -format UDZO -imagekey zlib-level=9 -volname "PangoZip $version" "$workspace/PangoZip.dmg"
if [[ "$signing_identity" != - ]]; then
  codesign --force --sign "$signing_identity" --timestamp "$workspace/PangoZip.dmg"
  codesign --verify --strict "$workspace/PangoZip.dmg"
fi
hdiutil verify "$workspace/PangoZip.dmg"
mountpoint="$workspace/mount"
mkdir "$mountpoint"
hdiutil attach -readonly -nobrowse -mountpoint "$mountpoint" "$workspace/PangoZip.dmg" >/dev/null
mounted=true
trap 'status=$?; if [[ "${mounted:-false}" == true ]]; then hdiutil detach "$mountpoint" >/dev/null || true; fi; cleanup "$status"' EXIT
[[ -d "$mountpoint/PangoZip.app" ]] || { echo "Missing PangoZip.app in DMG" >&2; exit 1; }
[[ -L "$mountpoint/Applications" && "$(readlink "$mountpoint/Applications")" == /Applications ]] || { echo "Invalid Applications link in DMG" >&2; exit 1; }
[[ -f "$mountpoint/Read me.txt" ]] || { echo "Missing Read me.txt in DMG" >&2; exit 1; }
[[ "$(find "$mountpoint" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 3 ]] || { echo "Unexpected DMG root contents" >&2; exit 1; }
hdiutil detach "$mountpoint" >/dev/null
mounted=false
mv -f "$workspace/PangoZip.dmg" "$output"
echo "Packaged: $output"
