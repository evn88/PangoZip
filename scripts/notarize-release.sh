#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Секреты берутся только из Keychain; скрипт не принимает пароль в аргументах.
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo "Usage: PANGOZIP_SIGNING_IDENTITY='Developer ID Application: …' PANGOZIP_NOTARY_PROFILE=PangoZip scripts/notarize-release.sh [--skip-build]"
  exit 0
fi
skip_build=false
if [[ "${1:-}" == --skip-build ]]; then skip_build=true; shift; fi
[[ $# -eq 0 ]] || { echo "Unexpected arguments. See --help." >&2; exit 2; }
[[ -n "${PANGOZIP_SIGNING_IDENTITY:-}" && "$PANGOZIP_SIGNING_IDENTITY" != - ]] || {
  echo "PANGOZIP_SIGNING_IDENTITY must specify a Developer ID Application certificate." >&2; exit 1;
}
[[ -n "${PANGOZIP_NOTARY_PROFILE:-}" ]] || { echo "Set PANGOZIP_NOTARY_PROFILE to a validated Keychain profile." >&2; exit 1; }
source scripts/lib/signing.sh
configure_signing
# Ограничиваем ожидание: обработка у Apple может продолжиться после тайм-аута.
timeout="${PANGOZIP_NOTARY_TIMEOUT:-30m}"
[[ "$timeout" =~ ^[1-9][0-9]*[smh]?$ ]] || { echo "Invalid PANGOZIP_NOTARY_TIMEOUT (example: 30m)." >&2; exit 2; }
mkdir -p build/notarization
report_directory="$(mktemp -d "$(pwd)/build/notarization/release.XXXXXX")"
chmod 700 "$report_directory"
echo "Notarization logs: $report_directory"
trap 'status=$?; if [[ $status -ne 0 ]]; then echo "Release stopped. Previous release DMG was not replaced. Logs: $report_directory" >&2; fi' EXIT

# Сохраняет ответ, идентификатор и журнал даже при отказе или тайм-ауте сервиса.
notarize() {
  local artifact="$1" label="$2" result submission status command_status=0
  result="$report_directory/$label-submission.plist"
  echo "Submitting $label to Apple..."
  xcrun notarytool submit "$artifact" --keychain-profile "$PANGOZIP_NOTARY_PROFILE" \
    --wait --timeout "$timeout" --output-format plist > "$result" \
    2> "$report_directory/$label-stderr.log" || command_status=$?
  submission="$(/usr/libexec/PlistBuddy -c 'Print :id' "$result" 2>/dev/null || true)"
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$result" 2>/dev/null || true)"
  if [[ -n "$submission" ]]; then
    echo "Submission $submission: ${status:-unknown}"
    printf '%s\n' "$submission" > "$report_directory/$label-submission-id.txt"
    xcrun notarytool log "$submission" --keychain-profile "$PANGOZIP_NOTARY_PROFILE" \
      "$report_directory/$label-log.json" || true
  fi
  if [[ $command_status -ne 0 || "$status" != Accepted ]]; then
    echo "Apple has not accepted $label. Check logs and the submission status before retrying." >&2
    return 1
  fi
}

if [[ "$skip_build" != true ]]; then scripts/build-app.sh release; fi
# Фиксируем снимок: параллельная локальная сборка не меняет отправленный Apple пакет.
app="$report_directory/PangoZip.app"
ditto "$(pwd)/build/PangoZip.app" "$app"
verify_distribution_app "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$report_directory/PangoZip.zip"
notarize "$report_directory/PangoZip.zip" app
# ZIP не поддерживает staple: подтверждение прикрепляется к приложению ниже.
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"
# Промежуточный образ изолирован от предыдущего опубликованного файла.
PANGOZIP_APP_PATH="$app" PANGOZIP_DMG_DIRECTORY="$report_directory" scripts/package-dmg.sh --skip-build
dmgs=("$report_directory"/*.dmg)
[[ ${#dmgs[@]} -eq 1 && -f "${dmgs[0]}" ]] || { echo "Expected exactly one DMG." >&2; exit 1; }
dmg="${dmgs[0]}"
notarize "$dmg" dmg
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict "$dmg"
hdiutil verify "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
# Хеш считается после staple: прикреплённое подтверждение меняет содержимое образа.
name="$(basename "$dmg")"
(cd "$report_directory" && shasum -a 256 "$name" > "$name.sha256")
mv -f "$dmg" "build/$name"
mv -f "$report_directory/$name.sha256" "build/$name.sha256"
echo "Ready: $(pwd)/build/$name"
echo "Checksum: $(pwd)/build/$name.sha256"
echo "Notarization accepted. Publish these two files together."
