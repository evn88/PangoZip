#!/usr/bin/env python3
"""Собирает пользовательский список изменений релиза из разделов «Release notes» в описаниях pull request."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from release_metadata import DEFAULT_CHANGES, render_notes, version_from_tag

REPOSITORY = "evn88/PangoZip"
LANGUAGES = {code.lower(): code for code in DEFAULT_CHANGES}
LANGUAGES.update({"eng": "en", "rus": "ru"})
NONE_WORDS = {"none", "нет", "no user-facing changes", "нет изменений для пользователя"}
SECTION = re.compile(r"^(#{2,3})\s*(?:release notes|заметки к релизу)\s*:?\s*$", re.IGNORECASE)
LANGUAGE_LINE = re.compile(r"^(?:#{3,6}\s*|\*\*)?\s*([A-Za-z-]{2,7})\s*(?:\*\*)?\s*:?\s*(?:\*\*)?\s*$")
BULLET = re.compile(r"^\s*[-*•]\s+(.*\S)\s*$")
MAX_LINE = 400

TEMPLATE_HINT = """Add a section like this to the pull request description (what users see in the update window):

## Release notes
### EN
- Short sentence about what changed for the user.
### RU
- То же самое по-русски.

If the change is not visible to users, write `none` under `## Release notes`."""


def parse(body):
    """Возвращает None без раздела, {} для явного «none», иначе словарь язык → пункты."""
    text = re.sub(r"<!--.*?-->", "", (body or "").replace("\r\n", "\n"), flags=re.DOTALL)
    lines = text.split("\n")
    start = level = None
    for index, line in enumerate(lines):
        match = SECTION.match(line.strip())
        if match:
            start, level = index + 1, len(match[1])
            break
    if start is None:
        return None
    section = []
    for line in lines[start:]:
        heading = re.match(r"^(#{1,6})\s", line.strip())
        if heading and len(heading[1]) <= level:
            break
        section.append(line)
    changes, language, plain = {}, None, []
    for line in section:
        stripped = line.strip()
        if not stripped:
            continue
        candidate = LANGUAGE_LINE.match(stripped)
        if candidate and candidate[1].lower() in LANGUAGES:
            language = LANGUAGES[candidate[1].lower()]
            continue
        bullet = BULLET.match(line)
        item = bullet[1] if bullet else stripped.lstrip("#").strip()
        plain.append(item.strip("`*_ .").lower())
        if bullet and language and item.strip("`*_ .").lower() not in NONE_WORDS:
            changes.setdefault(language, []).append(item)
    if not changes and plain and all(word in NONE_WORDS for word in plain):
        return {}
    # Пустые заготовки шаблона не означают «none»: проверка потребует заполнить списки.
    return changes or {"en": [], "ru": []}


def validate(changes):
    """Описание с разделом должно давать короткие пункты на английском и русском."""
    if changes is None:
        raise ValueError("The pull request description has no `## Release notes` section.")
    if changes == {}:
        return
    missing = [code for code in ("en", "ru") if not changes.get(code)]
    if missing:
        raise ValueError("Release notes need bullet points for: " + ", ".join(missing).upper() + ".")
    for lines in changes.values():
        for line in lines:
            if len(line) > MAX_LINE:
                raise ValueError(f"A release note is longer than {MAX_LINE} characters: {line[:60]}…")


def merge(parts):
    """Объединяет заметки нескольких pull request; отсутствующий перевод берётся из английского пункта."""
    parts = [part for part in parts if part and part.get("en") and part.get("ru")]
    if not parts:
        return None
    languages = [code for code in DEFAULT_CHANGES if any(code in part for part in parts)]
    return {code: [line for part in parts for line in part.get(code, part["en"])] for code in languages}


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments], text=True, stderr=subprocess.PIPE).strip()


def release_source(root, tag):
    """Релизный тег указывает на служебный коммит; его родитель записан в сообщении."""
    commit = git(root, "rev-parse", f"{tag}^{{commit}}")
    marker = re.search(r"^PangoZip-Release-Source: ([0-9a-f]{40})$",
                       git(root, "show", "-s", "--format=%B", commit), re.MULTILINE)
    return marker[1] if marker else commit


def pull_requests(root, start, end):
    """Номера pull request в first-parent истории main между двумя исходными коммитами, по порядку слияния."""
    revisions = f"{start}..{end}" if start else end
    numbers = []
    for subject in git(root, "log", "--first-parent", "--reverse", "--format=%s", revisions).splitlines():
        match = re.match(r"^Merge pull request #(\d+) ", subject) or re.search(r"\(#(\d+)\)$", subject)
        if match and int(match[1]) not in numbers:
            numbers.append(int(match[1]))
    return numbers


def github_body(number):
    return subprocess.check_output(["gh", "api", f"repos/{REPOSITORY}/pulls/{number}", "--jq", ".body // \"\""],
                                   text=True, stderr=subprocess.PIPE)


def collect(root, start, end, fetch_body):
    """Без заметок возвращает None, и выпуск использует нейтральный список по умолчанию."""
    parts = []
    for number in pull_requests(root, start, end):
        # Ошибка чтения останавливает выпуск: неполный список записался бы в релизный коммит навсегда.
        changes = parse(fetch_body(number))
        if changes is None:
            print(f"warning: pull request #{number} has no release notes section", file=sys.stderr)
        parts.append(changes)
    return merge(parts)


def version_tags(root):
    tags = []
    for tag in git(root, "tag", "--list", "v*").splitlines():
        try:
            tags.append((tuple(map(int, version_from_tag(tag).split("."))), tag))
        except ValueError:
            continue
    return [tag for _, tag in sorted(tags)]


def changes_for_tag(root, tag, fetch_body):
    """Ручной docs/releases/vX.json в текущем checkout важнее заметок из pull request."""
    path = root / f"docs/releases/{tag}.json"
    if path.exists():
        return json.loads(path.read_text())
    tags = version_tags(root)
    if tag not in tags:
        raise ValueError(f"Unknown release tag {tag}")
    index = tags.index(tag)
    start = release_source(root, tags[index - 1]) if index else None
    return collect(root, start, release_source(root, tag), fetch_body)


def refresh(root, tag):
    """Переписывает описание опубликованного GitHub Release; ассеты и лента обновлений не меняются."""
    version_from_tag(tag)
    current = subprocess.check_output(["gh", "release", "view", tag, "--repo", REPOSITORY, "--json", "body", "--jq", ".body"],
                                      text=True)
    mode = "notarized" if "notarized by Apple" in current else "ad-hoc"
    changes = changes_for_tag(root, tag, github_body)
    if changes is None:
        raise ValueError(f"No release notes found for {tag}; add docs/releases/{tag}.json")
    notes = render_notes(tag, mode, REPOSITORY, git(root, "rev-parse", f"{tag}^{{commit}}"), changes)
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as stream:
        stream.write(notes)
    try:
        subprocess.run(["gh", "release", "edit", tag, "--repo", REPOSITORY, "--notes-file", stream.name], check=True)
    finally:
        os.unlink(stream.name)
    print(f"Updated release notes for {tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "refresh"])
    parser.add_argument("tags", nargs="*")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.command == "check":
        try:
            changes = parse(os.environ.get("PR_BODY", ""))
            validate(changes)
        except ValueError as error:
            print(f"::error::{error}\n\n{TEMPLATE_HINT}")
            sys.exit(1)
        print("No user-facing changes." if changes == {} else json.dumps(changes, ensure_ascii=False, indent=2))
    else:
        if not args.tags:
            parser.error("refresh needs at least one tag")
        for tag in args.tags:
            refresh(root, tag)


if __name__ == "__main__":
    main()
