#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "Usage: $0 <PangoZip.app>" >&2
  exit 2
fi
app="$1"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == app.pangozip.desktop ]] || {
  echo "Not a PangoZip application bundle." >&2; exit 1;
}
source scripts/lib/signing.sh
configure_signing
# Подписываем изнутри наружу; подпись контейнера не заменяет подписи вложенного кода.
for component in \
  "$app/Contents/Resources/Engine/7zz" \
  "$app/Contents/Helpers/PangoZipWorker.app/Contents/Resources/Engine/7zz" \
  "$app/Contents/Helpers/PangoZipWorker.app" \
  "$app/Contents/Helpers/PangoZipUninstall"; do
  codesign "${signing_arguments[@]}" "$component"
done
codesign "${signing_arguments[@]}" --entitlements FinderExtension/Entitlements.plist "$app/Contents/PlugIns/PangoZipFinderSync.appex"
codesign "${signing_arguments[@]}" --entitlements QuickLookExtension/Entitlements.plist "$app/Contents/PlugIns/PangoZipPreview.appex"
codesign "${signing_arguments[@]}" "$app"
codesign --verify --deep --strict "$app"
if [[ "$signing_identity" != - ]]; then verify_distribution_app "$app"; fi
