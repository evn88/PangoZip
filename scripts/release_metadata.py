#!/usr/bin/env python3
"""Проверяет версию тега и формирует описание релиза на английском и русском."""

import argparse
import base64
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_FILES = ("Resources/Info.plist", "Resources/WorkerInfo.plist", "FinderExtension/Info.plist",
                "QuickLookExtension/Info.plist")
VERSION_PATTERN = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"

DEFAULT_CHANGES = {
    "en": ["App maintenance update."],
    "ru": ["Техническое обновление приложения."],
    "sr-Latn": ["Tehničko ažuriranje aplikacije."],
    "de": ["Technisches Update der App."],
    "fr": ["Mise à jour technique de l’application."],
    "es": ["Actualización de mantenimiento de la aplicación."],
    "it": ["Aggiornamento di manutenzione dell’app."],
    "pt": ["Atualização de manutenção do aplicativo."],
    "pl": ["Aktualizacja techniczna aplikacji."],
    "uk": ["Технічне оновлення застосунку."],
    "tr": ["Uygulama bakım güncellemesi."],
    "zh-Hans": ["应用维护更新。"],
    "ja": ["アプリのメンテナンス更新。"],
    "ko": ["앱 유지보수 업데이트."],
}


def release_changes(changes):
    """Не выдумывает исправления и не подставляет названия коммитов вместо пользовательских заметок."""
    changes = DEFAULT_CHANGES if changes is None else changes
    if not {"en", "ru"}.issubset(changes) or not set(changes).issubset(DEFAULT_CHANGES) or any(
        not isinstance(lines, list) or not lines or any(not isinstance(line, str) or not line.strip() for line in lines)
        for lines in changes.values()
    ):
        raise ValueError("Release changes require non-empty en and ru lists and supported language codes.")
    return changes


def localize_update_feed(path, changes):
    """Sparkle выбирает description по xml:lang; HTML содержит только короткий список изменений."""
    changes = release_changes(changes)
    tree = ET.parse(path)
    items = tree.findall("channel/item")
    if len(items) != 1:
        raise ValueError("Expected exactly one update item")
    item = items[0]
    namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    for child in list(item):
        if child.tag in ("description", namespace + "releaseNotesLink", namespace + "fullReleaseNotesLink"):
            item.remove(child)
    for language, fallback in DEFAULT_CHANGES.items():
        lines = changes.get(language, fallback)
        content = "".join("<li>" + html.escape(line) + "</li>" for line in lines)
        node = ET.SubElement(item, "description", {"{http://www.w3.org/XML/1998/namespace}lang": language})
        node.text = (f'<html lang="{language}"><head><meta charset="utf-8">'
                     '<style>:root{color-scheme:light dark}body{font:13px -apple-system;line-height:1.5;'
                     'margin:12px}ul{padding-left:20px}li{margin:6px 0}</style></head>'
                     f'<body><ul>{content}</ul></body></html>')
    ET.register_namespace("sparkle", namespace[1:-1])
    tree.write(path, encoding="utf-8", xml_declaration=True)


def version_from_tag(tag):
    """Разрешает только окончательные теги SemVer, пригодные для отметки Latest."""
    if not re.fullmatch("v" + VERSION_PATTERN, tag):
        raise ValueError("Expected a final version tag such as v0.7.0; prerelease tags are not supported.")
    return tag[1:]


def validate_version(tag, root=ROOT):
    """Сверяет версию и номер сборки у приложения, worker, Finder и Quick Look."""
    version = version_from_tag(tag)
    builds = set()
    for name in BUNDLE_FILES:
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
    changes = release_changes(changes)
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


def validate_update_feed(directory, tag, build=None):
    """Отклоняет неподписанную ленту и ссылку, длину или версии не от этого выпуска."""
    version = version_from_tag(tag)
    dmg = directory / f"PangoZip-{version}-arm64.dmg"
    data = (directory / "appcast.xml").read_bytes()
    signing = re.search(rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([0-9]+)\n-->\n$", data)
    if signing is None or int(signing[2]) != signing.start():
        raise ValueError("Update feed must have a Sparkle Ed25519 signature")
    items = ET.fromstring(data[:signing.start()]).findall("channel/item")
    if len(items) != 1:
        raise ValueError("Update feed must contain exactly one release")
    item = items[0]
    namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    enclosure = item.find("enclosure")
    if enclosure is None or enclosure.get("url") != f"https://github.com/evn88/PangoZip/releases/download/{tag}/{dmg.name}":
        raise ValueError("Update feed download URL does not match the release")
    signature = enclosure.get(namespace + "edSignature", "")
    if not re.fullmatch(r"[A-Za-z0-9+/]{86}==", signature):
        raise ValueError("Update archive must have an Ed25519 signature matching the app's key")
    if enclosure.get("length") != str(dmg.stat().st_size):
        raise ValueError("Update archive length does not match the feed")
    if item.findtext(namespace + "shortVersionString") != version:
        raise ValueError("Update feed version does not match the release")
    if build is not None and item.findtext(namespace + "version") != build:
        raise ValueError("Update feed build does not match the application")
    return signature


def generate_update_feed(tag, directory, root=ROOT, changes=None):
    """Проверяет ключ приложения и подписывает архив и ленту официальным инструментом Sparkle."""
    version_from_tag(tag)
    tool = root / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
    environment = dict(os.environ)
    secret = environment.pop("PANGOZIP_SPARKLE_PRIVATE_KEY", None)
    if environment.get("GITHUB_ACTIONS") == "true" and not secret:
        raise ValueError("Configure the PANGOZIP_SPARKLE_PRIVATE_KEY repository secret before releasing.")
    if secret:
        secret = secret.strip()
        try:
            valid_secret = len(base64.b64decode(secret, validate=True)) in [32, 64, 96]
        except ValueError:
            valid_secret = False
        if not valid_secret:
            raise ValueError("PANGOZIP_SPARKLE_PRIVATE_KEY is not a valid exported Sparkle key")
    command = [str(tool), "--download-url-prefix", f"https://github.com/evn88/PangoZip/releases/download/{tag}/",
               "--link", f"https://github.com/evn88/PangoZip/releases/tag/{tag}",
               "--maximum-deltas", "0", "--maximum-versions", "1"]
    command += ["--ed-key-file", "-"] if secret else ["--account", "app.pangozip.desktop"]
    # Отдельная папка исключает прежние DMG и не даёт генератору перемещать старые релизы.
    with tempfile.TemporaryDirectory(prefix=".update-feed-", dir=directory) as temporary:
        staging = Path(temporary)
        dmg = directory / f"PangoZip-{version_from_tag(tag)}-arm64.dmg"
        shutil.copy2(dmg, staging / dmg.name)
        subprocess.run([*command, str(staging)], input=secret, env=environment, check=True, text=True, timeout=300)
        shutil.copy2(staging / "appcast.xml", directory / "appcast.xml")
    # Генератор подписывает исходную ленту; локализованные описания требуют новой подписи всего XML.
    localize_update_feed(directory / "appcast.xml", changes)
    verifier = str(tool.with_name("sign_update"))
    credentials = ["--ed-key-file", "-"] if secret else ["--account", "app.pangozip.desktop"]
    subprocess.run([verifier, *credentials, str(directory / "appcast.xml")],
                   input=secret, env=environment, check=True, text=True, timeout=60)
    with (root / "Resources/Info.plist").open("rb") as source:
        build = plistlib.load(source)["CFBundleVersion"]
    signature = validate_update_feed(directory, tag, build)
    for file, arguments in [(directory / "appcast.xml", []),
                            (directory / f"PangoZip-{version_from_tag(tag)}-arm64.dmg", [signature])]:
        subprocess.run([verifier, *credentials, "--verify", str(file), *arguments],
                       input=secret, env=environment, check=True, text=True, timeout=60)


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
    notes = render_notes(tag, mode, repository, commit, changes)
    (directory / "release-notes.md").write_text(notes)
    generate_update_feed(tag, directory, root, changes)
    manifest = {"tag": tag, "version": version, "commit": commit, "signing": mode,
                "assets": {dmg.name: digest, checksum.name: hashlib.sha256(checksum.read_bytes()).hexdigest(),
                           "appcast.xml": hashlib.sha256((directory / "appcast.xml").read_bytes()).hexdigest()}}
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
