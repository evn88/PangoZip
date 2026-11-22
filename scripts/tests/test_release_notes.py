#!/usr/bin/env python3
"""Проверяет разбор раздела Release notes в описании pull request."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import release_notes  # noqa: E402


class ReleaseNotesTests(unittest.TestCase):
    def test_sections_in_both_languages_are_parsed_until_next_heading(self):
        body = ("## Problem\r\n- internal detail\r\n\r\n## Release notes\r\n<!-- hint -->\r\n### EN\r\n- One.\r\n* Two.\r\n"
                "### RU\r\n- Один.\r\n- Два.\r\n\r\n## Verification\r\n- swift test")
        self.assertEqual(release_notes.parse(body), {"en": ["One.", "Two."], "ru": ["Один.", "Два."]})

    def test_bold_and_colon_language_labels(self):
        body = "### Release notes\n**EN**\n- One.\nRU:\n- Один.\n### Other"
        self.assertEqual(release_notes.parse(body), {"en": ["One."], "ru": ["Один."]})

    def test_missing_section_none_and_template_placeholders(self):
        self.assertIsNone(release_notes.parse("## Summary\n- text"))
        self.assertEqual(release_notes.parse("## Release notes\n- none\n"), {})
        self.assertEqual(release_notes.parse("## Release notes\nНет"), {})
        template = (Path(__file__).resolve().parents[2] / ".github/pull_request_template.md").read_text()
        with self.assertRaises(ValueError):
            release_notes.validate(release_notes.parse(template))

    def test_validation_requires_english_and_russian(self):
        release_notes.validate({})
        release_notes.validate({"en": ["One."], "ru": ["Один."]})
        for changes in [None, {"en": ["One."]}, {"ru": ["Один."]}, {"en": ["x" * 500], "ru": ["Один."]}]:
            with self.assertRaises(ValueError):
                release_notes.validate(changes)

    def test_merge_skips_empty_parts_and_falls_back_to_english(self):
        merged = release_notes.merge([None, {}, {"en": ["A"], "ru": ["А"], "uk": ["А-uk"]}, {"en": ["B"], "ru": ["Б"]}])
        self.assertEqual(merged, {"en": ["A", "B"], "ru": ["А", "Б"], "uk": ["А-uk", "B"]})
        self.assertIsNone(release_notes.merge([None, {}]))


if __name__ == "__main__":
    unittest.main()
