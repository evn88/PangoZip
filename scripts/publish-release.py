#!/usr/bin/env python3
"""Публикует проверенные артефакты сначала в черновик, затем делает релиз Latest."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

from release_metadata import validate_update_feed, version_from_tag


def api(endpoint, method="GET", payload=None, file=None, binary=False):
    """Вызывает GitHub CLI без shell, передавая JSON отдельно от аргументов команды."""
    command = ["gh", "api", "--method", method, endpoint]
    if binary:
        command += ["-H", "Content-Type: application/octet-stream", "--input", str(file)]
    elif payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout) if result.stdout.strip() else None


def validate_artifacts(directory, tag):
    """Проверяет имена, SHA-256 и соответствие манифеста выбранному тегу."""
    version = version_from_tag(tag)
    manifest = json.loads((directory / "release-manifest.json").read_text())
    dmg = f"PangoZip-{version}-arm64.dmg"
    if manifest.get("tag") != tag or manifest.get("version") != version:
        raise ValueError("Artifact version does not match the tag")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest.get("commit", "")):
        raise ValueError("Invalid source commit")
    if manifest.get("signing") not in ["ad-hoc", "notarized"]:
        raise ValueError("Invalid signing mode")
    if set(manifest.get("assets", {})) != {dmg, dmg + ".sha256", "appcast.xml"}:
        raise ValueError("Unexpected release assets")
    for name, digest in manifest["assets"].items():
        if hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f"Checksum mismatch: {name}")
    if (directory / (dmg + ".sha256")).read_text() != f"{manifest['assets'][dmg]}  {dmg}\n":
        raise ValueError("Invalid checksum file")
    validate_update_feed(directory, tag)
    notes = (directory / "release-notes.md").read_text()
    if "## ENG\n" not in notes or "## RUS\n" not in notes:
        raise ValueError("Both English and Russian release notes are required")
    return manifest, notes


def verify_uploaded(release, manifest, directory):
    assets = release.get("assets", [])
    if {asset["name"] for asset in assets} != set(manifest["assets"]) or len(assets) != len(manifest["assets"]):
        raise ValueError("Published asset set does not match this build")
    for asset in assets:
        name = asset["name"]
        if asset["state"] != "uploaded" or asset["size"] != (directory / name).stat().st_size:
            raise ValueError(f"Incomplete upload: {name}")
        if asset.get("digest") != "sha256:" + manifest["assets"][name]:
            raise ValueError(f"Uploaded asset digest mismatch: {name}")


def publish(directory, repository, tag):
    """Не меняет опубликованные релизы; восстанавливает только собственный черновик этого тега."""
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid repository")
    manifest, notes = validate_artifacts(directory, tag)
    base = f"repos/{repository}"
    if api(f"{base}/commits/{tag}")["sha"] != manifest["commit"]:
        raise ValueError("Remote tag no longer matches the built commit")
    # Список включает черновики; поиск по тегу в CLI не всегда возвращает их.
    releases = json.loads(subprocess.check_output(
        ["gh", "api", f"{base}/releases", "--paginate", "--slurp"], text=True))
    releases = [release for page in releases for release in page]
    existing = next((release for release in releases if release["tag_name"] == tag), None)
    if existing and not existing["draft"]:
        verify_uploaded(existing, manifest, directory)
        print(existing["html_url"])
        return
    current = tuple(map(int, manifest["version"].split(".")))
    for release in releases:
        if not release["draft"] and not release["prerelease"]:
            try:
                previous = tuple(map(int, version_from_tag(release["tag_name"]).split(".")))
            except ValueError:
                continue
            if previous >= current:
                raise ValueError("New release version must be greater than published versions")
    release = existing or api(f"{base}/releases", "POST", {
        "tag_name": tag, "target_commitish": manifest["commit"], "name": f"PangoZip {manifest['version']}",
        "body": notes, "draft": True, "prerelease": False, "make_latest": "false"})
    release_id = release["id"]
    expected = set(manifest["assets"])
    if any(asset["name"] not in expected for asset in release.get("assets", [])):
        raise ValueError("Draft has unexpected assets; refusing to replace them")
    for asset in release.get("assets", []):
        api(f"{base}/releases/assets/{asset['id']}", "DELETE")
    for name in sorted(expected):
        api(f"https://uploads.github.com/{base}/releases/{release_id}/assets?name={name}",
            "POST", file=directory / name, binary=True)
    uploaded = api(f"{base}/releases/{release_id}")
    verify_uploaded(uploaded, manifest, directory)
    if api(f"{base}/commits/{tag}")["sha"] != manifest["commit"]:
        raise ValueError("Remote tag changed during asset upload")
    api(f"{base}/releases/{release_id}", "PATCH", {
        "name": f"PangoZip {manifest['version']}", "body": notes,
        "draft": False, "prerelease": False, "make_latest": "true"})
    latest = api(f"{base}/releases/latest")
    if latest["id"] != release_id:
        raise ValueError("Published release was not selected as Latest")
    print(latest["html_url"])


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Usage: publish-release.py <artifact-directory> <owner/repo> <tag>")
    publish(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
