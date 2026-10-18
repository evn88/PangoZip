#!/usr/bin/env python3
"""Проверки выпуска без сертификата, сети и обращения к сервису Apple."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

REPOSITORY = Path(__file__).resolve().parents[2]
IDENTITY = "Developer ID Application: Test Developer (TEAMTEST01)"
MOCK_TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, shutil, sys
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["MOCK_TRACE"], "a") as trace:
    trace.write(json.dumps([command, *args]) + "\n")
if command == "security":
    print('  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "' + os.environ["MOCK_IDENTITY"] + '"')
elif command == "codesign" and "--display" in args:
    authority = os.environ.get("MOCK_AUTHORITY", os.environ["MOCK_IDENTITY"])
    print("Authority=" + authority)
    print("TeamIdentifier=TEAMTEST01")
    print("Timestamp=Oct 11, 2026")
    if not os.environ.get("MOCK_NO_RUNTIME"):
        print("CodeDirectory flags=0x10000(runtime)")
elif command == "ditto":
    if "-c" in args:
        pathlib.Path(args[-1]).write_bytes(b"ZIP")
    else:
        shutil.copytree(args[-2], args[-1])
elif command == "xcrun":
    if args[:2] == ["notarytool", "submit"]:
        label = "dmg" if args[2].endswith(".dmg") else "app"
        status = os.environ.get("MOCK_" + label.upper() + "_STATUS", "Accepted")
        sys.stdout.buffer.write(plistlib.dumps({"id": label + "-submission", "status": status}))
        sys.exit(75 if status == "In Progress" else (1 if status == "Invalid" else 0))
    elif args[:2] == ["notarytool", "log"]:
        pathlib.Path(args[-1]).write_text('{"issues": []}')
    elif args[:2] == ["stapler", "validate"] and args[-1].endswith(".dmg"):
        sys.exit(int(os.environ.get("MOCK_DMG_VALIDATE_EXIT", "0")))
'''


class ReleaseScriptsTests(unittest.TestCase):
    """Изолирует сценарии от настоящих системных утилит и пользовательских артефактов."""

    def setUp(self):
        """Создаёт минимальный пакет приложения и подставные инструменты."""
        self.temporary = tempfile.TemporaryDirectory(prefix="pangozip-release-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        shutil.copytree(REPOSITORY / "scripts", self.root / "scripts")
        (self.root / "FinderExtension").mkdir()
        shutil.copy(REPOSITORY / "FinderExtension/Entitlements.plist", self.root / "FinderExtension")
        self.app = self.root / "build/PangoZip.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "app.pangozip.desktop"
        }))
        self.previous = self.root / "build/PangoZip-0.6.0-arm64.dmg"
        self.previous.write_bytes(b"PREVIOUS RELEASE")
        self.bin = self.root / "mock-bin"
        self.bin.mkdir()
        for name in ["security", "codesign", "ditto", "xcrun", "spctl", "hdiutil"]:
            tool = self.bin / name
            tool.write_text(MOCK_TOOL)
            tool.chmod(0o755)
        # Подмена упаковщика ограничена временной копией репозитория.
        (self.root / "scripts/package-dmg.sh").write_text('''#!/bin/bash
set -euo pipefail
mkdir -p "$PANGOZIP_DMG_DIRECTORY"
printf 'NEW DMG' > "$PANGOZIP_DMG_DIRECTORY/PangoZip-0.6.0-arm64.dmg"
''')
        self.trace = self.root / "trace.jsonl"
        self.environment = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                                MOCK_TRACE=str(self.trace), MOCK_IDENTITY=IDENTITY,
                                PANGOZIP_SIGNING_IDENTITY=IDENTITY,
                                PANGOZIP_NOTARY_PROFILE="TestProfile")

    def run_script(self, name, *arguments, **environment):
        """Запускает сценарий с изолированным окружением и возвращает полный результат."""
        return subprocess.run(["bash", str(self.root / "scripts" / name), *arguments],
                              env=dict(self.environment, **environment), cwd=self.root,
                              text=True, capture_output=True)

    def commands(self):
        """Читает порядок обращений к подставным инструментам."""
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def test_developer_id_signs_inside_out_with_runtime_timestamp_and_extension_entitlements(self):
        """Проверяет подписи контейнера, расширений и системного предпросмотра."""
        result = self.run_script("sign-app.sh", str(self.app))
        self.assertEqual(result.returncode, 0, result.stderr)
        signatures = [args for args in self.commands() if args[:2] == ["codesign", "--force"]]
        self.assertEqual(len(signatures), 7)
        for args in signatures:
            self.assertIn("--timestamp", args)
            self.assertEqual(args[args.index("--options") + 1], "runtime")
        self.assertTrue(signatures[0][-1].endswith("Resources/Engine/7zz"))
        self.assertEqual(signatures[-1][-1], str(self.app))
        entitlements = [args for args in signatures if "--entitlements" in args]
        self.assertEqual(len(entitlements), 2)
        self.assertTrue(entitlements[0][-1].endswith(".appex"))
        self.assertTrue(entitlements[1][-1].endswith("PangoZipPreview.appex"))

    def test_ad_hoc_signing_does_not_request_timestamp_or_service(self):
        """Локальная подпись не требует сети и Developer ID."""
        result = self.run_script("sign-app.sh", str(self.app), PANGOZIP_SIGNING_IDENTITY="-")
        self.assertEqual(result.returncode, 0, result.stderr)
        for args in self.commands():
            self.assertEqual(args[0], "codesign")
            self.assertNotIn("--timestamp", args)
            self.assertNotIn("--options", args)

    def test_wrong_certificate_is_rejected_before_signing(self):
        """Apple Development не принимается как сертификат выпуска."""
        result = self.run_script("sign-app.sh", str(self.app),
                                 PANGOZIP_SIGNING_IDENTITY="Apple Development: Test")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_accepted_app_and_dmg_are_stapled_before_final_checksum(self):
        """Публикует только образ, прошедший обе отправки и проверки подтверждений."""
        result = self.run_script("notarize-release.sh", "--skip-build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.previous.read_bytes(), b"NEW DMG")
        commands = self.commands()
        submits = [i for i, args in enumerate(commands) if args[:3] == ["xcrun", "notarytool", "submit"]]
        staples = [i for i, args in enumerate(commands) if args[:3] == ["xcrun", "stapler", "staple"]]
        self.assertEqual(len(submits), 2)
        self.assertEqual(len(staples), 2)
        self.assertLess(submits[0], staples[0])
        self.assertLess(staples[0], submits[1])
        self.assertLess(submits[1], staples[1])
        self.assertTrue(commands[staples[0]][-1].endswith("/PangoZip.app"))
        self.assertNotEqual(commands[staples[0]][-1], str(self.app))
        self.assertTrue(commands[staples[1]][-1].endswith(".dmg"))
        self.assertTrue(Path(str(self.previous) + ".sha256").exists())

    def test_refusal_timeout_and_invalid_dmg_preserve_previous_release(self):
        """Отказ Apple, тайм-аут и ошибка staple не заменяют предыдущий DMG."""
        for overrides in [{"MOCK_APP_STATUS": "Invalid"}, {"MOCK_APP_STATUS": "In Progress"},
                          {"MOCK_DMG_STATUS": "Invalid"}, {"MOCK_DMG_VALIDATE_EXIT": "1"}]:
            with self.subTest(overrides=overrides):
                result = self.run_script("notarize-release.sh", "--skip-build", **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.previous.read_bytes(), b"PREVIOUS RELEASE")
                self.assertFalse(Path(str(self.previous) + ".sha256").exists())
        ids = list((self.root / "build/notarization").glob("*/app-submission-id.txt"))
        self.assertEqual(len(ids), 4)

    def test_foreign_signature_is_rejected_before_upload(self):
        """Готовая сборка должна быть подписана указанным сертификатом."""
        result = self.run_script("notarize-release.sh", "--skip-build",
                                 MOCK_AUTHORITY="Developer ID Application: Other (OTHERTEAM1)")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(args[:3] == ["xcrun", "notarytool", "submit"] for args in self.commands()))

    def test_unavailable_private_key_and_missing_runtime_are_rejected(self):
        """Отклоняет недоступный ключ и сборку без Hardened Runtime до отправки Apple."""
        for overrides in [{"MOCK_IDENTITY": "Developer ID Application: Missing (MISSING001)"},
                          {"MOCK_NO_RUNTIME": "1"}]:
            with self.subTest(overrides=overrides):
                result = self.run_script("notarize-release.sh", "--skip-build", **overrides)
                self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(args[:3] == ["xcrun", "notarytool", "submit"] for args in self.commands()))

    def test_missing_profile_or_identity_is_rejected_without_network(self):
        """Не допускает запуск выпуска без обоих обязательных параметров."""
        for overrides in [{"PANGOZIP_NOTARY_PROFILE": ""}, {"PANGOZIP_SIGNING_IDENTITY": "-"},
                          {"PANGOZIP_NOTARY_TIMEOUT": "forever"}]:
            with self.subTest(overrides=overrides):
                result = self.run_script("notarize-release.sh", "--skip-build", **overrides)
                self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(args[0] == "xcrun" for args in self.commands()))

    def test_dmg_layout_configures_retina_background_volume_icon_and_ds_store(self):
        """Проверяет создание HiDPI-фона, флага иконки тома и позиций элементов в .DS_Store."""
        volume = self.root / "dmg-volume"
        volume.mkdir()
        icon = REPOSITORY / "Resources/Icons/AppIcon.icns"
        result = subprocess.run(
            ["python3", str(REPOSITORY / "scripts/dmg_layout.py"), "configure-volume", str(volume), "--icon", str(icon)],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((volume / ".background/background.tiff").is_file())
        self.assertTrue((volume / ".VolumeIcon.icns").is_file())
        ds_store = (volume / ".DS_Store").read_bytes()
        self.assertEqual(len(ds_store), 10244)
        self.assertIn("Applications".encode("utf-16-be") + b"Ilocblob", ds_store)
        self.assertIn("PangoZip.app".encode("utf-16-be") + b"Ilocblob", ds_store)
        self.assertIn(b"icvpblob", ds_store)
        self.assertIn(b"bwspblob", ds_store)
        self.assertIn(b"pBBkblob", ds_store)


if __name__ == "__main__":
    unittest.main()
