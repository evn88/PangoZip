# PangoZip

[English](README.md) | [Русский](README.ru.md) | [Српски](README.sr.md) | [Українська](README.uk.md)

<img src="Resources/Icons/AppIcon-master.png" width="128" alt="PangoZip: a golden pangolin">

A native archive manager for macOS. Browse archive contents, extract files, and edit individual files.

Latest version: [download PangoZip](https://github.com/evn88/PangoZip/releases/latest).

Website: [pangozip.app](https://pangozip.app).

## Features

- Browse and extract ZIP, 7z, RAR, TAR, and other formats supported by 7-Zip.
- Create ZIP and 7z archives, including password-protected archives.
- Browse a file tree, search, customize columns, and drag files between an archive and Finder.
- Edit files in an external app and automatically save changes back to the archive.
- Preview archives by pressing Space in Finder, and create or extract archives from its context menu.
- Extract multiple archives, queue operations, and undo the last change.
- Get automatic updates from GitHub Releases and use the interface in 14 languages.

ZIP, 7z, and TAR archives can be modified. RAR, multi-volume, and self-extracting archives are read-only. Format support in system previews may differ from the main app: [Quick Look](docs/quick-look.md).

To modify a file, use **Edit (⌘E)**. When you save it in an external editor, PangoZip updates the archive automatically. Opening a file normally creates a copy without tracking changes.

Passwords are not saved in preferences, but may be visible to local process inspection tools.

## Installation

Requires **macOS 26+ and Apple Silicon (M1 or later)**. Prebuilt Intel versions are not published yet.

1. Download `PangoZip-<version>-arm64.dmg` from the [latest release](https://github.com/evn88/PangoZip/releases/latest).
2. Open the disk image and drag PangoZip to Applications.
3. Eject the disk image and launch the app from Applications.

If Finder menus or previews do not appear, enable the PangoZip extensions in macOS System Settings. You can choose which archive types open in PangoZip in the app's settings.

See the release description for signing details. Builds without Apple notarization may be blocked on first launch. For installation and removal details, see the [instructions](docs/installation.txt).

## Development

The app uses SwiftUI and AppKit. You need **Xcode 26+ and Swift 6.2+**. Read [AGENTS.md](AGENTS.md) before making changes.

```sh
git clone https://github.com/evn88/PangoZip.git
cd PangoZip
./scripts/build-app.sh
open build/PangoZip.app
```

You can open `Package.swift` in Xcode. The 7zz engine is included in the repository; Sparkle is downloaded through Swift Package Manager on the first build.

To test Finder integration, install the built app in `~/Applications` with `./scripts/install-app.sh --skip-build`.

Before submitting a pull request to `main`, run the build and checks:

```sh
swift test
swift format lint --strict --recursive Sources FinderExtension QuickLookExtension Tests Tools Package.swift
python3 -m unittest discover -s scripts/tests
./scripts/build-app.sh
```

More details: [file interactions](docs/file-interactions.md), [localization](docs/localization.md), [releases](docs/github-releases.md), [signing and notarization](docs/notarization.md).

## Feedback

Report bugs and suggest improvements in [GitHub Issues](https://github.com/evn88/PangoZip/issues). Include your PangoZip and macOS versions, archive format, and steps to reproduce the issue. Only attach examples without personal data or passwords.

You can support development through [GitHub Sponsors](https://github.com/sponsors/evn88).

## License

PangoZip's own code and documentation are licensed under [MIT](LICENSE). The bundled 7-Zip and Sparkle components have their own licenses: [third-party components, sources, and distribution terms](THIRD_PARTY_NOTICES.md).
