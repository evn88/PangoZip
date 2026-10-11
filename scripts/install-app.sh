#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
skip_build=false
destination="${HOME}/Applications/PangoZip.app"
source_app="$repo_root/build/PangoZip.app"
if [[ -d "$script_dir/PangoZip.app" ]]; then
  source_app="$script_dir/PangoZip.app"
  skip_build=true
fi
if [[ "${1:-}" == "--skip-build" ]]; then skip_build=true; shift; fi
if [[ $# -gt 1 ]]; then echo "Usage: $0 [--skip-build] [destination.app]" >&2; exit 2; fi
if [[ $# -eq 1 ]]; then destination="$1"; fi
if [[ "$skip_build" != true ]]; then "$repo_root/scripts/build-app.sh" release; fi
[[ -d "$source_app" ]] || { echo "Built app not found: $source_app" >&2; exit 1; }

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
pbs="/System/Library/CoreServices/pbs"
[[ -x "$lsregister" && -x "$pbs" ]] || { echo "System registration tools unavailable" >&2; exit 1; }
source_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")"
[[ "$source_id" == app.pangozip.desktop ]] || { echo "Invalid application bundle" >&2; exit 1; }
codesign --verify --deep --strict "$source_app"
for resource in Contents/MacOS/PangoZip Contents/Helpers/PangoZipWorker.app/Contents/MacOS/PangoZip Contents/PlugIns/PangoZipFinderSync.appex/Contents/MacOS/PangoZipFinderSync Contents/Helpers/PangoZipUninstall; do
  [[ -x "$source_app/$resource" ]] || { echo "Missing component: $resource" >&2; exit 1; }
done

destination_parent="$(dirname "$destination")"
mkdir -p "$destination_parent"
destination="$(cd "$destination_parent" && pwd)/$(basename "$destination")"
[[ "$destination" != "$(cd "$source_app" && pwd)" ]] || { echo "Source and destination must differ" >&2; exit 1; }
if [[ -e "$destination" ]]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$existing_id" == app.pangozip.desktop ]] || { echo "Refusing to replace an unrelated item: $destination" >&2; exit 1; }
fi
# Дожидаемся штатного закрытия пользователем, не прерываем операции с архивами.
processes="$(/bin/ps -axo comm=)"
for executable in "$destination/Contents/MacOS/PangoZip" "$destination/Contents/Helpers/PangoZipWorker.app/Contents/MacOS/PangoZip"; do
  if /usr/bin/grep -Fxq "$executable" <<< "$processes"; then
    echo "Сначала закройте PangoZip и дождитесь завершения фоновых операций." >&2
    exit 1
  fi
done

transaction="$(mktemp -d "$destination_parent/.PangoZip.install.XXXXXX")"
staging="$transaction/PangoZip.app"
backup="$transaction/previous.bundle"
committed=false
installed_new=false
register() {
  "$lsregister" -f "$destination"
  "$lsregister" -f "$destination/Contents/Helpers/PangoZipWorker.app"
  local extension="$destination/Contents/PlugIns/PangoZipFinderSync.appex"
  local version attempt snapshot
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extension/Contents/Info.plist")"
  for attempt in 1 2 3 4 5; do
    /usr/bin/pluginkit -a "$extension"
    /usr/bin/pluginkit -e use -i app.pangozip.desktop.finder
    snapshot="$(/usr/bin/pluginkit -m -Av -i app.pangozip.desktop.finder)"
    if /usr/bin/grep -F "app.pangozip.desktop.finder($version)" <<< "$snapshot" | /usr/bin/grep -F "$extension" | /usr/bin/grep -q '^+'; then
      "$pbs" -update
      return 0
    fi
    sleep 1
  done
  echo "Не удалось подтвердить регистрацию расширения Finder. Повторите установку." >&2
  return 1
}
cleanup() {
  status=$?
  if [[ "$committed" != true && -d "$backup" ]]; then
    rm -rf "$destination"
    mv "$backup" "$destination"
    register || echo "Не удалось восстановить системную регистрацию; повторите установку." >&2
    committed=true
  fi
  if [[ "$committed" != true && "$installed_new" == true && ! -d "$backup" ]]; then
    /usr/bin/pluginkit -r "$destination/Contents/PlugIns/PangoZipFinderSync.appex" || true
    "$lsregister" -u "$destination/Contents/Helpers/PangoZipWorker.app" || true
    "$lsregister" -u "$destination" || true
    rm -rf "$destination"
    "$pbs" -update || true
  fi
  rm -rf "$transaction"
  exit "$status"
}
trap cleanup EXIT
ditto "$source_app" "$staging"
codesign --verify --deep --strict "$staging"
if [[ -d "$destination" ]]; then
  /usr/bin/pluginkit -r "$destination/Contents/PlugIns/PangoZipFinderSync.appex" || true
  "$lsregister" -u "$destination/Contents/Helpers/PangoZipWorker.app" || true
  "$lsregister" -u "$destination" || true
  while read -r process_id command; do
    if [[ "$command" == "$destination/Contents/PlugIns/PangoZipFinderSync.appex/Contents/MacOS/PangoZipFinderSync" ]]; then
      kill -TERM "$process_id" 2>/dev/null || true
    fi
  done < <(/bin/ps -axo pid=,comm=)
  mv "$destination" "$backup"
fi
mv "$staging" "$destination"
installed_new=true
register
committed=true
rm -rf "$transaction"
trap - EXIT
# Повторная регистрация после удаления резервной копии исключает устаревшую запись PlugInKit.
register
echo "Installed and registered: $destination"
