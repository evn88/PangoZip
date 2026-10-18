#!/usr/bin/env python3
"""Проверяет описание, версии и границы автоматической публикации без GitHub-запросов."""

import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import sys
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_metadata import generate_update_feed, render_notes, validate_update_feed, validate_version, version_from_tag

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
        self.signature = base64.b64encode(b"s" * 64).decode()
        self.feed_content = (f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                             f'<sparkle:version>12</sparkle:version><sparkle:shortVersionString>0.7.0</sparkle:shortVersionString>'
                             f'<enclosure url="https://github.com/evn88/PangoZip/releases/download/{self.tag}/{self.dmg.name}" '
                             f'length="3" sparkle:edSignature="{self.signature}"/></item></channel></rss>\n').encode()
        self.write_feed(self.feed_content)
        self.write_manifest()
        (self.directory / "release-notes.md").write_text(render_notes(self.tag, "ad-hoc", "evn88/PangoZip", COMMIT))

    def write_feed(self, content):
        """Создаёт структуру подписанной ленты; криптографию отдельно проверяет официальный инструмент."""
        feed = self.directory / "appcast.xml"
        feed.write_bytes(content + f"<!-- sparkle-signatures:\nedSignature: {self.signature}\nlength: {len(content)}\n-->\n".encode())
        self.manifest["assets"][feed.name] = hashlib.sha256(feed.read_bytes()).hexdigest()

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
        files = ["Resources/Info.plist", "Resources/WorkerInfo.plist", "FinderExtension/Info.plist",
                 "QuickLookExtension/Info.plist"]
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

    def test_completed_publication_retry_does_not_replace_assets_or_latest(self):
        """Повтор после успешного PATCH не перезагружает файлы и не откатывает Latest."""
        release = {"tag_name": self.tag, "draft": False, "prerelease": False,
                   "html_url": "https://github.com/evn88/PangoZip/releases/tag/v0.7.0",
                   "assets": [{"name": name, "state": "uploaded", "size": (self.directory / name).stat().st_size,
                               "digest": "sha256:" + digest} for name, digest in self.manifest["assets"].items()]}
        with patch.object(publisher, "api", return_value={"sha": COMMIT}) as api, \
             patch.object(publisher.subprocess, "check_output", return_value=json.dumps([[release]])):
            publisher.publish(self.directory, "evn88/PangoZip", self.tag)
            self.assertEqual(api.call_count, 1)
        release["assets"][0]["digest"] = "sha256:" + "0" * 64
        with patch.object(publisher, "api", return_value={"sha": COMMIT}) as api, \
             patch.object(publisher.subprocess, "check_output", return_value=json.dumps([[release]])):
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

    def test_latest_is_set_only_after_verifying_all_uploaded_assets(self):
        """Успешный путь публикует DMG, checksum и подписанную ленту с явной отметкой Latest."""
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

    def test_feed_rejects_missing_signature_foreign_url_length_and_version(self):
        """Даже пересчитанный SHA не разрешает ленту для другого архива или версии."""
        variants = [self.feed_content.replace(b"sparkle:edSignature", b"sparkle:unused"),
                    self.feed_content.replace(b"github.com", b"example.com"),
                    self.feed_content.replace(b'length="3"', b'length="4"'),
                    self.feed_content.replace(b">0.7.0<", b">0.6.1<")]
        for content in variants:
            with self.subTest(content=content):
                self.write_feed(content)
                self.write_manifest()
                with self.assertRaises(ValueError):
                    publisher.validate_artifacts(self.directory, self.tag)
        (self.directory / "appcast.xml").write_bytes(self.feed_content)
        with self.assertRaises(ValueError):
            validate_update_feed(self.directory, self.tag)

    def test_feed_uses_incremented_bundle_build(self):
        """Проверяет машинную версию отдельно от отображаемого SemVer."""
        validate_update_feed(self.directory, self.tag, "12")
        with self.assertRaises(ValueError):
            validate_update_feed(self.directory, self.tag, "11")

    def test_update_feed_contains_only_short_localized_change_lists(self):
        """Старые полные заметки заменяются списками на всех языках приложения."""
        from release_metadata import localize_update_feed
        root = ET.fromstring(self.feed_content)
        item = root.find("channel/item")
        ET.SubElement(item, "description").text = "ENG RUS Installation Merge pull request"
        ET.SubElement(item, "{http://www.andymatuschak.org/xml-namespaces/sparkle}releaseNotesLink").text = "https://example.invalid/full"
        feed = self.directory / "appcast.xml"
        feed.write_bytes(ET.tostring(root))
        localize_update_feed(feed, {"en": ["Short update notes."], "ru": ["Короткие заметки.", "<script>unsafe</script>"]})
        item = ET.parse(feed).find("channel/item")
        descriptions = {node.get("{http://www.w3.org/XML/1998/namespace}lang"): node.text
                        for node in item.findall("description")}
        self.assertEqual(set(descriptions), {"en", "ru", "sr-Latn", "de", "fr", "es", "it", "pt", "pl", "uk", "tr", "zh-Hans", "ja", "ko"})
        self.assertIn("Короткие заметки.", descriptions["ru"])
        self.assertNotIn("Short update notes.", descriptions["ru"])
        self.assertIn("&lt;script&gt;unsafe&lt;/script&gt;", descriptions["ru"])
        self.assertEqual(descriptions["ru"].count("<li>"), 2)
        self.assertIn('lang="ja"', descriptions["ja"])
        self.assertIn("<ul>", descriptions["ja"])
        self.assertFalse(item.findall("{http://www.andymatuschak.org/xml-namespaces/sparkle}releaseNotesLink"))
        for text in descriptions.values():
            for unwanted in ["ENG", "RUS", "Installation", "Merge pull request", "<h1>"]:
                self.assertNotIn(unwanted, text)

    def test_final_feed_is_signed_after_localization_and_then_verified(self):
        """Подпись старого XML не переносится на изменённую ленту."""
        resources = self.directory / "Resources"
        resources.mkdir()
        (resources / "Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "12"}))
        phases = []
        def signed(data):
            return data + f"<!-- sparkle-signatures:\nedSignature: {self.signature}\nlength: {len(data)}\n-->\n".encode()
        def run(command, **kwargs):
            if command[0].endswith("generate_appcast"):
                phases.append("generate")
                staging = Path(command[-1])
                self.assertFalse(list(staging.glob("*.md")))
                (staging / "appcast.xml").write_bytes(signed(self.feed_content))
            elif "--verify" in command:
                phases.append("verify-feed" if command[-1].endswith("appcast.xml") else "verify-dmg")
            else:
                phases.append("sign")
                feed = Path(command[-1])
                data = feed.read_bytes()
                self.assertNotIn(b"sparkle-signatures", data)
                descriptions = ET.fromstring(data).findall("channel/item/description")
                self.assertEqual(len(descriptions), 14)
                self.assertTrue(any("Короткие заметки" in node.text for node in descriptions))
                feed.write_bytes(signed(data))
        with patch("release_metadata.os.environ", {}), patch("release_metadata.subprocess.run", side_effect=run):
            generate_update_feed(self.tag, self.directory, self.directory,
                                 {"en": ["Short update notes."], "ru": ["Короткие заметки."]})
        self.assertEqual(phases, ["generate", "sign", "verify-feed", "verify-dmg"])

    @unittest.skipUnless((Path(__file__).resolve().parents[2] / ".build/artifacts/sparkle/Sparkle/bin/sign_update").exists(),
                         "Sparkle signing tool is available after swift build")
    def test_real_signature_rejects_modified_localized_notes(self):
        """Одноразовый seed проверяет подпись XML без Keychain и ключа приложения."""
        from release_metadata import localize_update_feed
        tool = Path(__file__).resolve().parents[2] / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
        feed = self.directory / "appcast.xml"
        localize_update_feed(feed, {"en": ["Short notes."], "ru": ["Короткие заметки."]})
        seed = base64.b64encode(os.urandom(32)).decode()
        def run(*args):
            return subprocess.run([str(tool), "--ed-key-file", "-", *args, str(feed)],
                                  input=seed, text=True, capture_output=True)
        self.assertEqual(run().returncode, 0)
        self.assertEqual(run("--verify").returncode, 0)
        feed.write_bytes(feed.read_bytes().replace("Короткие".encode(), "Новые".encode(), 1))
        self.assertNotEqual(run("--verify").returncode, 0)

    def test_ci_refuses_missing_or_invalid_private_key_without_printing_it(self):
        """Публикация не переключается на другой ключ и не раскрывает некорректный секрет."""
        for secret in [None, "not-a-valid-private-secret"]:
            environment = {"GITHUB_ACTIONS": "true"}
            if secret:
                environment["PANGOZIP_SPARKLE_PRIVATE_KEY"] = secret
            with patch("release_metadata.os.environ", environment), patch("release_metadata.subprocess.run") as run:
                with self.assertRaises(ValueError) as error:
                    generate_update_feed(self.tag, self.directory)
                self.assertNotIn(secret or "None", str(error.exception))
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
