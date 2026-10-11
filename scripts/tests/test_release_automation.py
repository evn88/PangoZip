#!/usr/bin/env python3
"""Проверяет описание, версии и границы автоматической публикации без GitHub-запросов."""

import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_metadata import render_notes, validate_version, version_from_tag

spec = importlib.util.spec_from_file_location("publisher", Path(__file__).resolve().parents[1] / "publish-release.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
COMMIT = "a" * 40


class ReleaseAutomationTests(unittest.TestCase):
    """Использует минимальные артефакты и подставные ответы API."""

    def setUp(self):
        """Создаёт манифест и двуязычное описание для условного нового релиза."""
        temporary = tempfile.TemporaryDirectory(prefix="pangozip-publish-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.tag = "v0.7.0"
        self.dmg = self.directory / "PangoZip-0.7.0-arm64.dmg"
        self.dmg.write_bytes(b"DMG")
        self.digest = hashlib.sha256(self.dmg.read_bytes()).hexdigest()
        self.checksum = Path(str(self.dmg) + ".sha256")
        self.checksum.write_text(f"{self.digest}  {self.dmg.name}\n")
        self.manifest = {"tag": self.tag, "version": "0.7.0", "commit": COMMIT, "signing": "ad-hoc",
                         "assets": {self.dmg.name: self.digest,
                                    self.checksum.name: hashlib.sha256(self.checksum.read_bytes()).hexdigest()}}
        self.write_manifest()
        (self.directory / "release-notes.md").write_text(render_notes(self.tag, "ad-hoc", "evn88/PangoZip", COMMIT))

    def write_manifest(self):
        """Сохраняет текущий тестовый манифест."""
        (self.directory / "release-manifest.json").write_text(json.dumps(self.manifest))

    def test_only_final_tags_are_accepted(self):
        """Не допускает prerelease, неоднозначные версии и пути вместо тега."""
        self.assertEqual(version_from_tag("v1.2.3"), "1.2.3")
        for tag in ["v1.2", "v01.2.3", "v1.2.3-beta", "v1.2.3+meta", "../../file", "v1.2.3\n"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                version_from_tag(tag)

    def test_bundle_versions_and_build_numbers_must_match(self):
        """Релиз с несогласованными версиями отклоняется до сборки."""
        files = ["Resources/Info.plist", "Resources/WorkerInfo.plist", "FinderExtension/Info.plist"]
        for name in files:
            path = self.directory / name
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.7.0", "CFBundleVersion": "11"}))
        self.assertEqual(validate_version(self.tag, self.directory), "0.7.0")
        (self.directory / files[-1]).write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.6.0", "CFBundleVersion": "11"}))
        with self.assertRaises(ValueError):
            validate_version(self.tag, self.directory)

    def test_notes_include_both_languages_and_accurate_signing_status(self):
        """Не приписывает ad hoc сборке нотариализацию Apple."""
        notes = render_notes(self.tag, "ad-hoc", "evn88/PangoZip", COMMIT)
        for phrase in ["## ENG", "## RUS", "without Developer ID", "без Developer ID", self.dmg.name]:
            self.assertIn(phrase, notes)
        notarized = render_notes(self.tag, "notarized", "evn88/PangoZip", COMMIT)
        self.assertIn("notarized by Apple", notarized)
        self.assertNotIn("Ad hoc signed", notarized)
        with self.assertRaises(ValueError):
            render_notes(self.tag, "ad-hoc", "evn88/PangoZip", COMMIT, {"en": ["English only"]})

    def test_tampered_assets_or_missing_translation_are_rejected(self):
        """Публикация не принимает изменённый DMG и одноязычное описание."""
        publisher.validate_artifacts(self.directory, self.tag)
        self.dmg.write_bytes(b"TAMPERED")
        with self.assertRaises(ValueError):
            publisher.validate_artifacts(self.directory, self.tag)
        self.dmg.write_bytes(b"DMG")
        (self.directory / "release-notes.md").write_text("## ENG\nEnglish only")
        with self.assertRaises(ValueError):
            publisher.validate_artifacts(self.directory, self.tag)

    def test_remote_tag_change_prevents_any_release_mutation(self):
        """Переуказанный тег не позволяет опубликовать ранее собранный файл."""
        with patch.object(publisher, "api", return_value={"sha": "b" * 40}) as api:
            with self.assertRaises(ValueError):
                publisher.publish(self.directory, "evn88/PangoZip", self.tag)
            self.assertEqual(api.call_count, 1)

    def test_published_release_is_never_overwritten(self):
        """Повторный запуск не меняет уже доступные пользователям файлы."""
        with patch.object(publisher, "api", return_value={"sha": COMMIT}) as api, \
             patch.object(publisher.subprocess, "check_output", return_value=json.dumps([[{
                 "tag_name": self.tag, "draft": False, "prerelease": False}]])):
            with self.assertRaises(ValueError):
                publisher.publish(self.directory, "evn88/PangoZip", self.tag)
            self.assertEqual(api.call_count, 1)

    def test_upload_failure_leaves_only_a_draft(self):
        """Ошибка передачи не раскрывает пользователям неполный релиз."""
        calls = []

        def api(endpoint, method="GET", payload=None, **kwargs):
            """Имитирует успешное создание черновика и отказ загрузки."""
            calls.append((endpoint, method, payload))
            if "/commits/" in endpoint:
                return {"sha": COMMIT}
            if method == "POST" and endpoint.endswith("/releases"):
                return {"id": 123, "assets": []}
            raise RuntimeError("upload failed")

        with patch.object(publisher, "api", side_effect=api), \
             patch.object(publisher.subprocess, "check_output", return_value="[[]]"):
            with self.assertRaises(RuntimeError):
                publisher.publish(self.directory, "evn88/PangoZip", self.tag)
        self.assertTrue(calls[1][2]["draft"])
        self.assertFalse(any(method == "PATCH" for _, method, _ in calls))

    def test_latest_is_set_only_after_verifying_both_uploaded_assets(self):
        """Успешный путь публикует два проверенных файла с явной отметкой Latest."""
        calls = []

        def api(endpoint, method="GET", payload=None, **kwargs):
            """Возвращает последовательно черновик, загруженные файлы и последний релиз."""
            calls.append((endpoint, method, payload))
            if "/commits/" in endpoint:
                return {"sha": COMMIT}
            if method == "POST" and endpoint.endswith("/releases"):
                return {"id": 123, "assets": []}
            if endpoint.endswith("/releases/123") and method == "GET":
                return {"assets": [{"name": name, "state": "uploaded", "size": (self.directory / name).stat().st_size,
                                    "digest": "sha256:" + digest} for name, digest in self.manifest["assets"].items()]}
            if endpoint.endswith("/latest"):
                return {"id": 123, "html_url": "https://github.com/evn88/PangoZip/releases/tag/v0.7.0"}
            return {}

        with patch.object(publisher, "api", side_effect=api), \
             patch.object(publisher.subprocess, "check_output", return_value="[[]]"):
            publisher.publish(self.directory, "evn88/PangoZip", self.tag)
        publication = [payload for _, method, payload in calls if method == "PATCH"]
        self.assertEqual(len(publication), 1)
        self.assertFalse(publication[0]["draft"])
        self.assertFalse(publication[0]["prerelease"])
        self.assertEqual(publication[0]["make_latest"], "true")


if __name__ == "__main__":
    unittest.main()
