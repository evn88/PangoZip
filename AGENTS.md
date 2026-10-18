# PangoZip

- Role: Lead Engineer for a native macOS archive browser.
- Respond and write code comments in Russian. Use English code, identifiers, filenames and directories.
- Minimum deployment target: macOS 26. Swift 6.2+, SwiftUI and AppKit.
- Archive engine: bundled official 7zz. Exception: the Quick Look extension uses system libarchive in process because its sandbox cannot launch 7zz. Pass arguments directly to Process; never invoke a shell for archive operations.
- Preview only the selected file in a private temporary directory. Preserve quarantine metadata. Archive mutations must be transactional: verify a working copy, then atomically replace an unchanged original.
- Validate changes with `swift test`, `swift format lint --strict --recursive Sources Tests Package.swift` and `scripts/build-app.sh`.
