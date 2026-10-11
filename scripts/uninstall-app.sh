#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ "$script_dir" == */Contents/SharedSupport ]]; then
  application="${script_dir%/Contents/SharedSupport}"
else
  application="${1:-${HOME}/Applications/PangoZip.app}"
fi
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [PangoZip.app]" >&2
  exit 2
fi
helper="$application/Contents/Helpers/PangoZipUninstall"
[[ -x "$helper" ]] || { echo "PangoZip uninstaller not found: $helper" >&2; exit 1; }
exec "$helper"
