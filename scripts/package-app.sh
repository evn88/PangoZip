#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" != --skip-build ]]; then scripts/build-app.sh; fi
package="build/PangoZip-Installer"
mkdir -p "$package"
# В пакет входят самодостаточные команды: исходники и Xcode не нужны.
rm -rf "$package/PangoZip.app"
ditto build/PangoZip.app "$package/PangoZip.app"
cp scripts/install-app.sh "$package/Install PangoZip.command"
cp scripts/uninstall-app.sh "$package/Uninstall PangoZip.command"
cp docs/installation.txt "$package/Read me.txt"
chmod +x "$package/Install PangoZip.command" "$package/Uninstall PangoZip.command"
ditto -c -k --sequesterRsrc --keepParent "$package" build/PangoZip-Installer.zip
echo "Packaged: $(pwd)/build/PangoZip-Installer.zip"
