#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
  echo "Usage: $0 [release|debug]" >&2
  exit 1
fi
source scripts/lib/signing.sh
configure_signing
scripts/build-icon.sh
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
# Новый комплект собирается отдельно, чтобы удалённые ресурсы не оставались от прошлой сборки.
mkdir -p build
build_staging="$(mktemp -d "$(pwd)/build/.PangoZip.build.XXXXXX")"
trap 'rm -rf "$build_staging"' EXIT
app="$build_staging/PangoZip.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/PangoZip" "$app/Contents/MacOS/PangoZip"
cp Resources/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Frameworks"
# ditto сохраняет обязательные для framework символические ссылки и права исполнения.
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework \
  "$app/Contents/Frameworks/Sparkle.framework"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/Sparkle-LICENSE.txt"
cp Resources/Icons/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/Icons/Pangolin.png "$app/Contents/Resources/Pangolin.png"
cp -R Resources/Engine "$app/Contents/Resources/"
cp -R Sources/PangoZipCore/Resources/*.lproj "$app/Contents/Resources/"
chmod +x "$app/Contents/MacOS/PangoZip" "$app/Contents/Resources/Engine/7zz"
extension="$app/Contents/PlugIns/PangoZipFinderSync.appex"
mkdir -p "$extension/Contents/MacOS" "$extension/Contents/Resources"
cp Resources/Icons/AppIcon.icns "$extension/Contents/Resources/AppIcon.icns"
cp FinderExtension/Info.plist "$extension/Contents/Info.plist"
cp -R Sources/PangoZipCore/Resources/*.lproj "$extension/Contents/Resources/"
xcrun swiftc -swift-version 6 -O -parse-as-library -application-extension   -target "$(uname -m)-apple-macos26.0" -module-name PangoZipFinderSync   -Xlinker -e -Xlinker _NSExtensionMain   Sources/PangoZipCore/Localization.swift Sources/PangoZipCore/FinderRequest.swift Sources/PangoZipCore/FinderInstallation.swift Sources/PangoZipCore/QuickAction.swift FinderExtension/FinderSync.swift   -o "$extension/Contents/MacOS/PangoZipFinderSync"
# Quick Action: один appex даёт один пункт, поэтому из одного исполняемого файла собираются два расширения.
quick_binary="$build_staging/PangoZipQuickAction"
xcrun swiftc -swift-version 6 -O -parse-as-library -application-extension \
  -target "$(uname -m)-apple-macos26.0" -module-name PangoZipQuickAction \
  -Xlinker -e -Xlinker _NSExtensionMain \
  Sources/PangoZipCore/Localization.swift Sources/PangoZipCore/FinderRequest.swift \
  Sources/PangoZipCore/FinderInstallation.swift Sources/PangoZipCore/QuickAction.swift \
  QuickActionExtension/QuickActionHandler.swift \
  -o "$quick_binary"
for quick in Extract:PangoZipQuickExtract:extractHere Zip:PangoZipQuickZip:createZip; do
  IFS=: read -r suffix bundle_name mode <<< "$quick"
  quick_appex="$app/Contents/PlugIns/$bundle_name.appex"
  mkdir -p "$quick_appex/Contents/MacOS" "$quick_appex/Contents/Resources"
  cp QuickActionExtension/Info-$suffix.plist "$quick_appex/Contents/Info.plist"
  for key in CFBundleShortVersionString CFBundleVersion; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist")"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$quick_appex/Contents/Info.plist"
  done
  cp Resources/Icons/AppIcon.icns "$quick_appex/Contents/Resources/AppIcon.icns"
  cp "$quick_binary" "$quick_appex/Contents/MacOS/PangoZipQuickAction"
  chmod +x "$quick_appex/Contents/MacOS/PangoZipQuickAction"
  # Имя пункта в «Быстрых действиях» берётся из CFBundleDisplayName; переводы совпадают с названиями Services.
  default_title="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$quick_appex/Contents/Info.plist")"
  for lproj in Sources/PangoZipCore/Resources/*.lproj; do
    target="$quick_appex/Contents/Resources/$(basename "$lproj")"
    mkdir -p "$target"
    title="$(plutil -extract "$default_title" raw -o - "$lproj/ServicesMenu.strings")"
    printf '"CFBundleDisplayName" = "%s";\n' "$title" > "$target/InfoPlist.strings"
  done
done
preview="$app/Contents/PlugIns/PangoZipPreview.appex"
mkdir -p "$preview/Contents/MacOS" "$preview/Contents/Resources"
cp QuickLookExtension/Info.plist "$preview/Contents/Info.plist"
# Версия расширения всегда совпадает с контейнером, включая локальную сборку релиза.
for key in CFBundleShortVersionString CFBundleVersion; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist")"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$preview/Contents/Info.plist"
done
cp LICENSE THIRD_PARTY_NOTICES.md "$preview/Contents/Resources/"
cp -R Sources/PangoZipCore/Resources/*.lproj "$preview/Contents/Resources/"
xcrun swiftc -swift-version 6 -O -whole-module-optimization -parse-as-library -application-extension \
  -I Sources/CLibArchive -target "$(uname -m)-apple-macos26.0" -module-name PangoZipPreview \
  -Xlinker -e -Xlinker _NSExtensionMain \
  Sources/PangoZipCore/*.swift QuickLookExtension/*.swift \
  -o "$preview/Contents/MacOS/PangoZipPreview"
worker="$app/Contents/Helpers/PangoZipWorker.app"
mkdir -p "$worker/Contents/MacOS" "$worker/Contents/Resources"
cp "$app/Contents/MacOS/PangoZip" "$worker/Contents/MacOS/PangoZip"
cp Resources/WorkerInfo.plist "$worker/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$worker/Contents/Resources/"
cp Resources/Icons/AppIcon.icns "$worker/Contents/Resources/AppIcon.icns"
cp -R Resources/Engine "$worker/Contents/Resources/"
cp -R Sources/PangoZipCore/Resources/*.lproj "$worker/Contents/Resources/"
mkdir -p "$app/Contents/SharedSupport"
cp Tools/Uninstall.swift "$build_staging/main.swift"
xcrun swiftc -swift-version 6 -O -target "$(uname -m)-apple-macos26.0" -D PANGOZIP_UNINSTALL Sources/PangoZipCore/Localization.swift "$build_staging/main.swift" -o "$app/Contents/Helpers/PangoZipUninstall"
cp scripts/uninstall-app.sh "$app/Contents/SharedSupport/Uninstall PangoZip.command"
chmod +x "$app/Contents/SharedSupport/Uninstall PangoZip.command"
scripts/sign-app.sh "$app"
# Заменяем только готовую подписанную сборку; ошибка до этого шага сохраняет предыдущую.
rm -rf build/PangoZip.app
mv "$app" build/PangoZip.app
echo "Built: $(pwd)/build/PangoZip.app"
