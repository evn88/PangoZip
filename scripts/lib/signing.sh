#!/bin/bash

# Готовит единые параметры подписи; Developer ID проверяется до долгой сборки.
configure_signing() {
  signing_identity="${PANGOZIP_SIGNING_IDENTITY:--}"
  signing_arguments=(--force --sign "$signing_identity")
  if [[ "$signing_identity" != - ]]; then
    [[ "$signing_identity" == 'Developer ID Application: '* ]] || {
      echo "Use the full Developer ID Application certificate name, or '-' for a local ad hoc build." >&2
      return 1
    }
    local identities
    identities="$(security find-identity -v -p codesigning)"
    [[ "$identities" == *"\"$signing_identity\""* ]] || {
      echo "Developer ID Application identity with a private key was not found in the Keychain." >&2
      return 1
    }
    signing_arguments+=(--options runtime --timestamp)
  fi
}

# Проверяет подпись каждого исполняемого компонента и принадлежность одной команде.
verify_distribution_app() {
  local app="$1" component details team expected_team=""
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == app.pangozip.desktop ]] || {
    echo "Not a PangoZip application bundle." >&2; return 1;
  }
  codesign --verify --deep --strict "$app"
  local -a components=(
    "$app/Contents/Resources/Engine/7zz"
    "$app/Contents/Helpers/PangoZipWorker.app/Contents/Resources/Engine/7zz"
    "$app/Contents/Helpers/PangoZipWorker.app"
    "$app/Contents/Helpers/PangoZipUninstall"
    "$app/Contents/PlugIns/PangoZipFinderSync.appex"
    "$app/Contents/PlugIns/PangoZipPreview.appex"
    "$app")
  local framework="$app/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$framework" ]]; then
    components+=(
      "$framework/Versions/B/Autoupdate"
      "$framework/Versions/B/Updater.app"
      "$framework/Versions/B/XPCServices/Downloader.xpc"
      "$framework/Versions/B/XPCServices/Installer.xpc"
      "$framework")
  fi
  for component in "${components[@]}"; do
    codesign --verify --strict "$component"
    details="$(codesign --display --verbose=4 "$component" 2>&1)"
    [[ "$details" == *"Authority=$signing_identity"* && "$details" == *'Timestamp='* && "$details" == *'(runtime)'* ]] || {
      echo "Missing Developer ID, secure timestamp or Hardened Runtime: $component" >&2
      return 1
    }
    team="$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p')"
    [[ -n "$team" && "$team" != not\ set ]] || { echo "Missing signing team: $component" >&2; return 1; }
    if [[ -z "$expected_team" ]]; then expected_team="$team"; fi
    [[ "$team" == "$expected_team" ]] || { echo "Signing team mismatch: $component" >&2; return 1; }
  done
}
