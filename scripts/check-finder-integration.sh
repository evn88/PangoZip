#!/bin/bash
set -euo pipefail

# Диагностика не регистрирует и не включает расширения, не перезапускает Finder.
app="${1:-/Applications/PangoZip.app}"
if [[ $# -gt 1 || ! -d "$app" ]]; then
  echo "Укажите путь к установленному PangoZip.app." >&2
  exit 2
fi
app="$(cd "$app" && pwd -P)"
extension="$app/Contents/PlugIns/PangoZipFinderSync.appex"
[[ -d "$extension" ]] || { echo "Расширение Finder отсутствует в приложении." >&2; exit 1; }

echo "Приложение: $app"
if ! /usr/bin/codesign --verify --deep --strict "$app"; then
  echo "Проверка подписи не пройдена." >&2
  exit 1
fi
echo "Проверка подписи: успешно."

if ! snapshot="$(/usr/bin/pluginkit -m -Av -i app.pangozip.desktop.finder 2>&1)"; then
  echo "Не удалось прочитать системный реестр расширений:" >&2
  echo "$snapshot" >&2
  exit 1
fi
echo "$snapshot"
# Проверяем именно установленный комплект, а не другую копию с тем же идентификатором.
if ! /usr/bin/awk -v path="$extension" '
  $1 == "+" && substr($0, length($0) - length(path) + 1) == path { found = 1 }
  END { exit !found }
' <<< "$snapshot"; then
  echo "Указанное расширение отсутствует в реестре или не выбрано для использования." >&2
  echo "Откройте установленный PangoZip и проверьте его статус меню Finder." >&2
  exit 1
fi
echo "Регистрация указанного расширения: активно."

# Quick Action: проверяется регистрация каждого встроенного расширения; отсутствие не считается ошибкой Finder Sync.
quick_missing=0
for quick in PangoZipQuickExtract:extract PangoZipQuickZip:zip; do
  quick_appex="$app/Contents/PlugIns/${quick%%:*}.appex"
  [[ -d "$quick_appex" ]] || { echo "Quick Action ${quick%%:*}: отсутствует в приложении."; quick_missing=1; continue; }
  quick_snapshot="$(/usr/bin/pluginkit -m -Av -i "app.pangozip.desktop.quickaction.${quick##*:}" 2>&1 || true)"
  if /usr/bin/awk -v path="$quick_appex" '
    $1 == "+" && substr($0, length($0) - length(path) + 1) == path { found = 1 }
    END { exit !found }
  ' <<< "$quick_snapshot"; then
    echo "Quick Action ${quick%%:*}: активно."
  else
    echo "Quick Action ${quick%%:*}: не зарегистрировано или отключено (Системные настройки → Расширения)."
    quick_missing=1
  fi
done
if [[ "$quick_missing" -ne 0 ]]; then
  echo "Quick Action необязательны для меню Finder Sync; в облачных папках они работают вместе со Services."
fi
echo "Наличие записи не подтверждает показ меню в конкретной папке: это проверяется в Finder."
