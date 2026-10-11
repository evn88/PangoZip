#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && -d "${RUNNER_TEMP:-}" ]] || {
  echo 'This script is only for a disposable GitHub-hosted runner.' >&2; exit 1;
}
keychain="$RUNNER_TEMP/PangoZip-signing.keychain-db"
certificate="$RUNNER_TEMP/PangoZip-signing.p12"
if [[ "${1:-}" == cleanup ]]; then
  if [[ -f "$keychain" ]]; then security delete-keychain "$keychain"; fi
  rm -f "$certificate"
  exit 0
fi
[[ "${1:-}" == setup ]] || { echo 'Usage: ci-signing.sh setup|cleanup' >&2; exit 2; }
for required in PANGOZIP_CERTIFICATE_BASE64 PANGOZIP_CERTIFICATE_PASSWORD PANGOZIP_SIGNING_IDENTITY PANGOZIP_APPLE_ID PANGOZIP_APPLE_TEAM_ID PANGOZIP_APPLE_APP_PASSWORD; do
  [[ -n "${!required:-}" ]] || { echo "Missing GitHub Actions secret: $required" >&2; exit 1; }
done
# Приватный ключ существует только в закрытой папке временного runner и удаляется после сборки.
umask 077
python3 - <<'PY'
import base64
import os
from pathlib import Path
Path(os.environ["RUNNER_TEMP"], "PangoZip-signing.p12").write_bytes(
    base64.b64decode(os.environ["PANGOZIP_CERTIFICATE_BASE64"], validate=True))
PY
password="$(openssl rand -hex 32)"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$certificate" -k "$keychain" -P "$PANGOZIP_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"
security default-keychain -d user -s "$keychain"
xcrun notarytool store-credentials PangoZip-CI --apple-id "$PANGOZIP_APPLE_ID" \
  --team-id "$PANGOZIP_APPLE_TEAM_ID" --password "$PANGOZIP_APPLE_APP_PASSWORD" >/dev/null
rm -f "$certificate"
