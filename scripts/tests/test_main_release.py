#!/usr/bin/env python3
"""Проверяет выпуск на настоящих временных Git-репозиториях без сети и секретов."""

import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


class MainReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="pangozip-main-release-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.remote = self.directory / "origin.git"
        self.root = self.directory / "checkout"
        subprocess.run(["git", "init", "--bare", str(self.remote)], check=True, capture_output=True)
        subprocess.run(["git", "clone", str(self.remote), str(self.root)], check=True, capture_output=True)
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release@example.invalid")
        self.git("checkout", "-b", "main")
        self.files = ["Resources/Info.plist", "Resources/WorkerInfo.plist", "FinderExtension/Info.plist",
                      "QuickLookExtension/Info.plist"]
        for name in self.files:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.7.0", "CFBundleVersion": "12"}))
        (self.root / "README.md").write_text(
            "Скачать: [PangoZip 0.7.0](https://github.com/evn88/PangoZip/releases/tag/v0.7.0).\n"
            "Текущая версия: **0.7.0 (12)**. [Изменения 0.7.0](docs/release-0.7.0.md).\n")
        self.git("add", ".")
        self.git("commit", "-m", "Initial release")
        self.git("tag", "v0.7.0")
        self.git("push", "origin", "main", "v0.7.0")
        (self.root / "feature.txt").write_text("New behavior\n")
        self.git("add", ".")
        self.git("commit", "-m", "Improve archive extraction")
        self.git("push", "origin", "main")
        self.source = self.git("rev-parse", "HEAD")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True, stderr=subprocess.PIPE).strip()

    def test_preparation_bumps_all_bundles_and_notes_without_publishing(self):
        import main_release
        state = main_release.prepare(self.root, self.source, {"v0.7.0"})
        self.assertTrue(state["ready"])
        self.assertEqual(state["tag"], "v0.7.1")
        self.assertEqual(state["source"], self.source)
        self.assertEqual(self.git("rev-parse", "HEAD^"), self.source)
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/main").split()[0], self.source)
        self.assertEqual(self.git("tag", "--list", "v0.7.1"), "")
        for name in self.files:
            info = plistlib.loads((self.root / name).read_bytes())
            self.assertEqual((info["CFBundleShortVersionString"], info["CFBundleVersion"]), ("0.7.1", "13"))
        changes = json.loads((self.root / "docs/releases/v0.7.1.json").read_text())
        self.assertNotIn("Improve archive extraction", " ".join(changes["en"]))
        self.assertEqual(changes["ru"], ["Техническое обновление приложения."])
        self.assertIn("0.7.1 (13)", (self.root / "README.md").read_text())
        self.assertEqual(self.git("status", "--porcelain"), "")

    def advance_main(self):
        other = self.directory / "other"
        subprocess.run(["git", "clone", "-b", "main", str(self.remote), str(other)], check=True, capture_output=True)
        def run(*args):
            return subprocess.check_output(["git", "-C", str(other), *args], text=True, stderr=subprocess.PIPE).strip()
        run("config", "user.name", "Another Developer")
        run("config", "user.email", "other@example.invalid")
        run("config", "commit.gpgsign", "false")
        (other / "newer.txt").write_text("A newer main commit")
        run("add", ".")
        run("commit", "-m", "Another change")
        run("push", "origin", "main")
        return run("rev-parse", "HEAD")

    def test_finalize_publishes_matching_main_and_tag_atomically(self):
        import main_release
        state = main_release.prepare(self.root, self.source, {"v0.7.0"})
        self.assertTrue(main_release.finalize(self.root, state))
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/main").split()[0], state["commit"])
        self.assertEqual(self.git("ls-remote", "origin", "refs/tags/v0.7.1").split()[0], state["commit"])

    def test_superseded_event_does_not_prepare_an_old_release(self):
        import main_release
        self.advance_main()
        self.assertFalse(main_release.prepare(self.root, self.source, {"v0.7.0"})["ready"])
        self.assertEqual(self.git("rev-parse", "HEAD"), self.source)

    def test_main_advanced_during_build_is_not_overwritten(self):
        import main_release
        state = main_release.prepare(self.root, self.source, {"v0.7.0"})
        newer = self.advance_main()
        self.assertFalse(main_release.finalize(self.root, state))
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/main").split()[0], newer)
        self.assertEqual(self.git("ls-remote", "origin", "refs/tags/v0.7.1"), "")

    def test_reserved_tag_never_moves_or_advances_main(self):
        import main_release
        state = main_release.prepare(self.root, self.source, {"v0.7.0"})
        self.git("push", "origin", f"{self.source}:refs/tags/v0.7.1")
        with self.assertRaises(ValueError):
            main_release.finalize(self.root, state)
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/main").split()[0], self.source)

    def test_retry_after_refs_are_pushed_reuses_version_and_commit(self):
        import main_release
        state = main_release.prepare(self.root, self.source, {"v0.7.0"})
        self.assertTrue(main_release.finalize(self.root, state))
        self.git("checkout", "--detach", self.source)
        resumed = main_release.prepare(self.root, self.source, {"v0.7.0"})
        self.assertEqual(resumed, state)
        self.assertTrue(main_release.finalize(self.root, resumed))
        self.assertEqual(self.git("tag", "--list", "v0.7.2"), "")

    def test_rerun_of_published_source_or_manual_dispatch_is_no_op(self):
        import main_release
        state = main_release.prepare(self.root, self.source, {"v0.7.0"})
        main_release.finalize(self.root, state)
        for requested in [self.source, state["commit"]]:
            self.git("checkout", "--detach", requested)
            self.assertFalse(main_release.prepare(self.root, requested, {"v0.7.0", "v0.7.1"})["ready"])
        self.assertEqual(self.git("tag", "--list", "v0.7.2"), "")

    def test_race_after_last_remote_check_cannot_publish_a_tag_alone(self):
        import main_release
        from unittest.mock import patch
        state = main_release.prepare(self.root, self.source, {"v0.7.0"})
        original = main_release.git
        newer = []
        def race(root, *args):
            if args[0] == "push":
                newer.append(self.advance_main())
            return original(root, *args)
        with patch.object(main_release, "git", side_effect=race):
            self.assertFalse(main_release.finalize(self.root, state))
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/main").split()[0], newer[0])
        self.assertEqual(self.git("ls-remote", "origin", "refs/tags/v0.7.1"), "")

    def test_explicit_minor_version_is_preserved_and_build_increments(self):
        import main_release
        for name in self.files:
            path = self.root / name
            info = plistlib.loads(path.read_bytes())
            info["CFBundleShortVersionString"] = "0.8.0"
            path.write_bytes(plistlib.dumps(info))
        self.git("add", ".")
        self.git("commit", "-m", "Prepare next minor")
        self.git("push", "origin", "main")
        state = main_release.prepare(self.root, self.git("rev-parse", "HEAD"), {"v0.7.0"})
        self.assertEqual(state["tag"], "v0.8.0")
        self.assertEqual(plistlib.loads((self.root / self.files[0]).read_bytes())["CFBundleVersion"], "13")

    def test_versions_and_builds_advance_past_tags_outside_main(self):
        import main_release
        self.git("checkout", "--detach")
        for name in self.files:
            path = self.root / name
            info = plistlib.loads(path.read_bytes())
            info.update(CFBundleShortVersionString="0.9.0", CFBundleVersion="42")
            path.write_bytes(plistlib.dumps(info))
        self.git("add", ".")
        self.git("commit", "-m", "Release from another branch")
        self.git("tag", "v0.9.0")
        self.git("push", "origin", "v0.9.0")
        self.git("checkout", "--detach", self.source)
        state = main_release.prepare(self.root, self.source, {"v0.7.0", "v0.9.0"})
        self.assertEqual(state["tag"], "v0.9.1")
        self.assertEqual(plistlib.loads((self.root / self.files[0]).read_bytes())["CFBundleVersion"], "43")

    def test_mismatched_quicklook_version_is_rejected(self):
        import main_release
        path = self.root / self.files[-1]
        info = plistlib.loads(path.read_bytes())
        info["CFBundleShortVersionString"] = "0.6.0"
        path.write_bytes(plistlib.dumps(info))
        self.git("add", ".")
        self.git("commit", "-m", "Mismatched component")
        self.git("push", "origin", "main")
        source = self.git("rev-parse", "HEAD")
        with self.assertRaises(ValueError):
            main_release.prepare(self.root, source, {"v0.7.0"})
        self.assertEqual(self.git("rev-parse", "HEAD"), source)

    def test_rejected_remote_write_fails_without_publishing_refs(self):
        import main_release
        state = main_release.prepare(self.root, self.source, {"v0.7.0"})
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        with self.assertRaises(subprocess.CalledProcessError):
            main_release.finalize(self.root, state)
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/main").split()[0], self.source)
        self.assertEqual(self.git("ls-remote", "origin", "refs/tags/v0.7.1"), "")


if __name__ == "__main__":
    unittest.main()
