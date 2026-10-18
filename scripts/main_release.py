#!/usr/bin/env python3
"""Готовит версию из main и публикует тег проверенного коммита, не меняя защищённый main."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

from release_metadata import BUNDLE_FILES, DEFAULT_CHANGES, version_from_tag

REPOSITORY = "evn88/PangoZip"


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments], text=True, stderr=subprocess.PIPE).strip()


def remote_main(root):
    git(root, "fetch", "origin", "main", "--tags")
    return git(root, "rev-parse", "refs/remotes/origin/main")


def version(tag):
    return tuple(map(int, version_from_tag(tag).split(".")))


def prepare(root, requested, published):
    """Не меняет удалённые refs: номер версии становится видимым только после проверок."""
    if not re.fullmatch(r"[0-9a-f]{40}", requested):
        raise ValueError("Expected the main source commit SHA")
    if git(root, "status", "--porcelain"):
        raise ValueError("Release preparation requires a clean checkout")
    head = remote_main(root)
    message = git(root, "show", "-s", "--format=%B", head)
    marker = re.search(r"^PangoZip-Release-Source: ([0-9a-f]{40})$", message, re.MULTILINE)
    if marker and requested in (head, marker[1]):
        info = plistlib.loads(git(root, "show", f"{head}:Resources/Info.plist").encode())
        tag = "v" + info["CFBundleShortVersionString"]
        version_from_tag(tag)
        parents = git(root, "rev-list", "--parents", "-n", "1", head).split()
        if parents != [head, marker[1]] or git(root, "rev-parse", f"{tag}^{{commit}}") != head:
            raise ValueError("Incomplete release refs cannot be reused")
        if tag in published:
            return {"ready": False}
        git(root, "checkout", "--detach", head)
        return {"ready": True, "source": marker[1], "commit": head, "tag": tag}
    for tag in git(root, "tag", "--list", "v*").splitlines():
        try:
            version_from_tag(tag)
        except ValueError:
            continue
        commit = git(root, "rev-parse", f"{tag}^{{commit}}")
        message = git(root, "show", "-s", "--format=%B", commit)
        if f"PangoZip-Release-Source: {requested}" not in message.splitlines():
            continue
        if git(root, "rev-list", "--parents", "-n", "1", commit).split() != [commit, requested]:
            raise ValueError("Release tag is not based on its recorded source")
        info = plistlib.loads(git(root, "show", f"{commit}:Resources/Info.plist").encode())
        if tag != "v" + info["CFBundleShortVersionString"]:
            raise ValueError("Release tag does not match its bundle version")
        if tag in published or head != requested:
            return {"ready": False}
        git(root, "checkout", "--detach", commit)
        return {"ready": True, "source": requested, "commit": commit, "tag": tag}
    if head != requested:
        return {"ready": False}
    git(root, "checkout", "--detach", requested)
    infos = [plistlib.loads((root / name).read_bytes()) for name in BUNDLE_FILES]
    current = {info["CFBundleShortVersionString"] for info in infos}
    builds = {info["CFBundleVersion"] for info in infos}
    if len(current) != 1 or len(builds) != 1 or not all(re.fullmatch(r"[1-9][0-9]*", x) for x in builds):
        raise ValueError("All four bundles must have matching versions and positive integer builds")
    current = version("v" + current.pop())
    tags = []
    for tag in git(root, "tag", "--list").splitlines():
        try:
            tags.append((version(tag), tag))
        except ValueError:
            continue
    tags.sort()
    latest = tags[-1] if tags else None
    previous = latest[0] if latest else current
    next_version = current if current > previous else (previous[0], previous[1], previous[2] + 1)
    build = int(builds.pop())
    for _, tag in tags:
        info = plistlib.loads(git(root, "show", f"{tag}:Resources/Info.plist").encode())
        build = max(build, int(info["CFBundleVersion"]))
    build += 1
    number = ".".join(map(str, next_version))
    tag = "v" + number
    for name in BUNDLE_FILES:
        path = root / name
        text = path.read_text()
        for key, value in [("CFBundleShortVersionString", number), ("CFBundleVersion", str(build))]:
            text, count = re.subn(rf"(<key>{key}</key>\s*<string>)[^<]*(</string>)",
                                 lambda match: match[1] + value + match[2], text)
            if count != 1:
                raise ValueError(f"Invalid bundle version field: {name}/{key}")
        path.write_text(text)
    readme = root / "README.md"
    text = readme.read_text()
    text = re.sub(r"^Скачать: .*", f"Скачать: [PangoZip {number}](https://github.com/{REPOSITORY}/releases/tag/{tag}).",
                  text, flags=re.MULTILINE)
    text, count = re.subn(r"^(?:Текущая версия|Последняя версия): .*",
                         f"Текущая версия: **{number} ({build})**. [Изменения {number}](https://github.com/{REPOSITORY}/releases/tag/{tag}).",
                         text, flags=re.MULTILINE)
    if count != 1:
        raise ValueError("README current version was not found")
    readme.write_text(text)
    notes = DEFAULT_CHANGES
    path = root / f"docs/releases/{tag}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_text(json.dumps(notes, ensure_ascii=False, indent=2) + "\n")
    git(root, "add", *BUNDLE_FILES, "README.md", str(path.relative_to(root)))
    git(root, "-c", "user.name=github-actions[bot]", "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
        "-c", "commit.gpgsign=false", "commit", "-m", f"chore(release): {tag}",
        "-m", f"PangoZip-Release-Source: {requested}")
    return {"ready": True, "source": requested, "commit": git(root, "rev-parse", "HEAD"), "tag": tag}


def finalize(root, state):
    """Публикует проверенный тег без записи в main и без force push."""
    if not state["ready"]:
        return False
    commit, source, tag = state["commit"], state["source"], state["tag"]
    version_from_tag(tag)
    if git(root, "rev-parse", "HEAD") != commit or git(root, "status", "--porcelain"):
        raise ValueError("Built checkout changed before publication")
    if git(root, "rev-parse", "HEAD^") != source:
        raise ValueError("Release commit is not based on the checked main source")
    head = remote_main(root)
    if tag in git(root, "tag", "--list").splitlines():
        if git(root, "rev-parse", f"{tag}^{{commit}}") != commit:
            raise ValueError("Release tag is already reserved by another commit")
    if head not in (source, commit):
        return False
    if tag not in git(root, "tag", "--list").splitlines():
        git(root, "tag", "--no-sign", tag, commit)
    git(root, "push", "origin", f"refs/tags/{tag}:refs/tags/{tag}")
    return True


def outputs(path, values):
    with path.open("a") as stream:
        for key, value in values.items():
            stream.write(f"{key}={str(value).lower() if isinstance(value, bool) else value}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "finalize"])
    parser.add_argument("--state", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("GITHUB_REF") != "refs/heads/main" or os.environ.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise ValueError("Automatic releases run only on evn88/PangoZip main")
    root = Path(__file__).resolve().parents[1]
    output = Path(os.environ["GITHUB_OUTPUT"])
    if args.command == "prepare":
        pages = json.loads(subprocess.check_output(
            ["gh", "api", f"repos/{REPOSITORY}/releases", "--paginate", "--slurp"], text=True))
        published = {release["tag_name"] for page in pages for release in page if not release["draft"]}
        state = prepare(root, os.environ["GITHUB_SHA"], published)
        args.state.write_text(json.dumps(state))
        outputs(output, state)
        print(f"Prepared {state['tag']}" if state["ready"] else "No release needed for this main event")
    else:
        state = json.loads(args.state.read_text())
        accepted = finalize(root, state)
        outputs(output, {"published_refs": accepted})
        print("Verified release tag published" if accepted else "Main advanced; a newer run will release it")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        message = error.stderr or str(error)
        for name in ("GH_TOKEN", "GITHUB_TOKEN"):
            token = os.environ.get(name)
            if token:
                message = message.replace(token, "<REDACTED>")
        print(message, file=sys.stderr)
        sys.exit(error.returncode or 1)
