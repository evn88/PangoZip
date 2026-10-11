#!/usr/bin/env python3
"""Проверяет версию тега и формирует описание релиза на английском и русском."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VERSION_PATTERN = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def version_from_tag(tag):
    """Разрешает только окончательные теги SemVer, пригодные для отметки Latest."""
    if not re.fullmatch("v" + VERSION_PATTERN, tag):
        raise ValueError("Expected a final version tag such as v0.7.0; prerelease tags are not supported.")
    return tag[1:]


def validate_version(tag, root=ROOT):
    """Сверяет версию и номер сборки у приложения, worker и Finder Extension."""
    version = version_from_tag(tag)
    builds = set()
    for name in ["Resources/Info.plist", "Resources/WorkerInfo.plist", "FinderExtension/Info.plist"]:
        with (root / name).open("rb") as source:
            info = plistlib.load(source)
        if info.get("CFBundleShortVersionString") != version:
            raise ValueError(f"{name}: bundle version must match {tag}")
        builds.add(info.get("CFBundleVersion"))
    if len(builds) != 1 or None in builds or not next(iter(builds)):
        raise ValueError("Bundle build numbers must match and must not be empty.")
    return version


def render_notes(tag, mode, repository, commit, changes=None):
    """Описывает установку и фактический статус подписи без обещаний неподтверждённых проверок."""
    version = version_from_tag(tag)
    if mode not in ["ad-hoc", "notarized"]:
        raise ValueError("Unknown signing mode")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid GitHub repository")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid source commit")
    changes = {
        "en": [f"See the [source changes](https://github.com/{repository}/commits/{tag}) included in this version."],
        "ru": [f"Изменения этой версии доступны в [истории исходников](https://github.com/{repository}/commits/{tag})."],
    } if changes is None else changes
    if set(changes) != {"en", "ru"} or any(
        not isinstance(lines, list) or not lines or any(not isinstance(line, str) or not line.strip() for line in lines)
        for lines in changes.values()
    ):
        raise ValueError("Release changes must contain non-empty en and ru lists.")
    warning_en = ("Signed with Developer ID Application and notarized by Apple. Notarization tickets are attached to the app and DMG."
                  if mode == "notarized" else
                  "**Ad hoc signed, without Developer ID or Apple notarization. Gatekeeper may block this download. Do not disable macOS security protections.**")
    warning_ru = ("Подписано Developer ID Application и принято сервисом нотариализации Apple. Подтверждения прикреплены к приложению и DMG."
                  if mode == "notarized" else
                  "**Подпись ad hoc, без Developer ID и нотариализации Apple. Gatekeeper может заблокировать скачанное приложение. Не отключайте защиту macOS.**")
    filename = f"PangoZip-{version}-arm64.dmg"
    source = f"https://github.com/{repository}/tree/{commit}"
    en = "\n".join("- " + line for line in changes["en"])
    ru = "\n".join("- " + line for line in changes["ru"])
    return f"""## ENG

PangoZip {version} is a native archive manager for **macOS 26+ on Apple Silicon** (arm64), built with SwiftUI, AppKit and bundled 7-Zip (`7zz`). Intel binaries are not included.

### Changes

{en}

### Installation

1. Download and open `{filename}`.
2. Drag `PangoZip.app` onto `Applications`, then eject the DMG.
3. Launch PangoZip from Applications. Enable the Finder extension in System Settings if requested.

The Finder extension and background helper are included inside the app. To uninstall, quit PangoZip, wait for background operations to finish, and move the app to Trash.

### Signing and verification

{warning_en}

The release pipeline runs tests, verifies the app signatures and checks DMG integrity. After downloading both files, verify the checksum:

```sh
shasum -a 256 -c {filename}.sha256
```

PangoZip uses MIT; bundled 7-Zip has separate LGPL/BSD/unRAR terms. Licenses and the corresponding 7-Zip source archive are included in the app. [Source code for this build]({source}).

## RUS

PangoZip {version} — нативный менеджер архивов для **macOS 26+ на Apple Silicon** (arm64), на SwiftUI, AppKit и встроенном 7-Zip (`7zz`). Сборка для Intel не включена.

### Изменения

{ru}

### Установка

1. Скачайте и откройте `{filename}`.
2. Перетащите `PangoZip.app` на `Applications`, затем извлеките DMG.
3. Запустите PangoZip из Applications. При необходимости разрешите расширение Finder в системных настройках.

Расширение Finder и фоновый помощник находятся внутри приложения. Для удаления закройте PangoZip, дождитесь завершения фоновых операций и переместите приложение в Корзину.

### Подпись и проверка

{warning_ru}

Сценарий выпуска запускает тесты, проверяет подписи приложения и целостность DMG. После скачивания обоих файлов проверьте контрольную сумму:

```sh
shasum -a 256 -c {filename}.sha256
```

Код PangoZip — MIT; встроенный 7-Zip распространяется на отдельных условиях LGPL/BSD/unRAR. Лицензии и соответствующий архив исходников 7-Zip включены в приложение. [Исходники этой сборки]({source}).
"""


def write_metadata(tag, mode, root=ROOT):
    """Сохраняет описание, контрольную сумму и манифест для отдельного задания публикации."""
    version = validate_version(tag, root)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    repository = "evn88/PangoZip"
    directory = root / "build"
    dmg = directory / f"PangoZip-{version}-arm64.dmg"
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    checksum = Path(str(dmg) + ".sha256")
    checksum.write_text(f"{digest}  {dmg.name}\n")
    changes_path = root / f"docs/releases/{tag}.json"
    changes = json.loads(changes_path.read_text()) if changes_path.exists() else None
    (directory / "release-notes.md").write_text(render_notes(tag, mode, repository, commit, changes))
    manifest = {"tag": tag, "version": version, "commit": commit, "signing": mode,
                "assets": {dmg.name: digest, checksum.name: hashlib.sha256(checksum.read_bytes()).hexdigest()}}
    (directory / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main():
    """Разделяет раннюю проверку версии и формирование метаданных после сборки."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["validate", "prepare"])
    parser.add_argument("tag")
    parser.add_argument("--signing", choices=["ad-hoc", "notarized"], default="ad-hoc")
    args = parser.parse_args()
    if args.command == "validate":
        print(validate_version(args.tag))
    else:
        write_metadata(args.tag, args.signing)


if __name__ == "__main__":
    main()
