import Darwin
import XCTest

@testable import PangoZipCore

final class QuickLookArchiveServiceTests: XCTestCase, @unchecked Sendable {
  func testListsAndExtractsZipSevenZipAndCompressedTarWithoutChangingSource() async throws {
    for ext in ["zip", "7z", "tar.gz"] {
      let root = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let archive = root.appendingPathComponent("Sample." + ext)
      if ext == "tar.gz" {
        try run(
          ["a", "-ttar", root.appendingPathComponent("Sample.tar").path, "docs", "keep.txt"],
          in: root)
        try run(["a", "-tgzip", archive.path, "Sample.tar"], in: root)
      } else {
        try run(["a", archive.path, "docs", "keep.txt"], in: root)
      }
      let original = try Data(contentsOf: archive)
      try FileManager.default.removeItem(at: root.appendingPathComponent("docs"))
      try FileManager.default.removeItem(at: root.appendingPathComponent("keep.txt"))
      let service = QuickLookArchiveService()
      let session = try await service.open(archive)
      XCTAssertTrue(session.entries.contains { $0.path == "docs/inside.txt" })
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("docs").path))
      let file = try await service.extract(session, to: root, path: "docs/inside.txt")
      XCTAssertEqual(try String(contentsOf: XCTUnwrap(file.first), encoding: .utf8), "inside")
      let folder = try await service.extract(session, to: root, path: "docs")
      XCTAssertEqual(
        try String(
          contentsOf: XCTUnwrap(folder.first).appendingPathComponent("inside.txt"), encoding: .utf8),
        "inside")
      let full = try await service.extract(session, to: root)
      XCTAssertEqual(full.first?.lastPathComponent, "Sample")
      let repeated = try await service.extract(session, to: root)
      XCTAssertEqual(repeated.first?.lastPathComponent, "Sample (2)")
      XCTAssertEqual(try Data(contentsOf: archive), original)
      try await service.close(session)
      do {
        _ = try await service.extract(session, to: root)
        XCTFail("Expected expired session")
      } catch { XCTAssertEqual(error as? ArchiveError, .sessionExpired) }
    }
  }

  func testChangedArchiveCancellationAndQuarantine() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("Sample.zip")
    try run(["a", archive.path, "docs", "keep.txt"], in: root)
    let quarantine = Array("0081;12345678;PangoZip;".utf8)
    XCTAssertEqual(
      quarantine.withUnsafeBytes {
        setxattr(archive.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
      }, 0)
    let service = QuickLookArchiveService()
    let session = try await service.open(archive)
    let result = try await service.extract(session, to: root, path: "keep.txt")
    let target = try XCTUnwrap(result.first)
    var actual = [UInt8](repeating: 0, count: quarantine.count)
    let count = actual.withUnsafeMutableBytes {
      getxattr(target.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
    }
    XCTAssertEqual(count, quarantine.count)
    XCTAssertEqual(actual, quarantine)
    let cancelled = Task { try await service.extract(session, to: root) }
    cancelled.cancel()
    do {
      _ = try await cancelled.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    try Data("changed".utf8).write(to: archive)
    do {
      _ = try await service.extract(session, to: root)
      XCTFail("Expected changed archive")
    } catch { XCTAssertEqual(error as? ArchiveError, .archiveChanged) }
    try await service.close(session)
  }

  func testRejectsTraversalAndCaseUnicodeCollisionsWhileListing() async throws {
    let cases: [([(String, UInt8)], ArchiveError)] = [
      ([("../outside", 48)], .unsafePath),
      ([("/absolute", 48)], .unsafePath),
      ([("keep.txt", 48), ("KEEP.txt", 48)], .duplicatePath),
      ([("caf\u{e9}/first", 48), ("cafe\u{301}/second", 48)], .duplicatePath),
    ]
    for (entries, expected) in cases {
      let root = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let archive = root.appendingPathComponent("Unsafe.tar")
      try tar(entries).write(to: archive)
      let service = QuickLookArchiveService()
      do {
        _ = try await service.open(archive)
        XCTFail("Expected unsafe archive")
      } catch { XCTAssertEqual(error as? ArchiveError, expected) }
    }
  }

  func testListsLinksAndSpecialEntriesButExportsOnlySafeSelection() async throws {
    for type: UInt8 in [49, 50, 54] {
      let root = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let archive = root.appendingPathComponent("Mixed.tar")
      try tar([("safe.txt", 48), ("unsafe", type)]).write(to: archive)
      let service = QuickLookArchiveService()
      let session = try await service.open(archive)
      XCTAssertEqual(session.entries.map(\.path), ["safe.txt", "unsafe"])
      XCTAssertEqual(session.entries.first { $0.path == "unsafe" }?.isSymbolicLink, true)
      let safe = try await service.extract(session, to: root, path: "safe.txt")
      XCTAssertEqual(try Data(contentsOf: XCTUnwrap(safe.first)), Data())
      for path in [nil, "unsafe"] as [String?] {
        do {
          _ = try await service.extract(session, to: root, path: path)
          XCTFail("Expected unsupported extraction")
        } catch { XCTAssertEqual(error as? ArchiveError, .unsupportedExtraction) }
      }
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Mixed").path))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("unsafe").path))
      try await service.close(session)
    }
  }

  func testEncryptedZipUsesPasswordAndEncryptedSevenZipFailsClearly() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let zip = root.appendingPathComponent("Secret.zip")
    try run(["a", "-psecret", zip.path, "keep.txt"], in: root)
    let service = QuickLookArchiveService()
    let session = try await service.open(zip)
    do {
      _ = try await service.extract(session, to: root)
      XCTFail("Expected password")
    } catch { XCTAssertEqual(error as? ArchiveError, .passwordRequired) }
    let results = try await service.extract(session, to: root, password: "secret")
    XCTAssertEqual(
      try String(
        contentsOf: XCTUnwrap(results.first).appendingPathComponent("keep.txt"), encoding: .utf8),
      "keep")
    try await service.close(session)
    let sevenZip = root.appendingPathComponent("Secret.7z")
    try run(["a", "-psecret", "-mhe=on", sevenZip.path, "keep.txt"], in: root)
    do {
      _ = try await service.open(sevenZip, password: "secret")
      XCTFail("Expected unsupported encryption")
    } catch { XCTAssertEqual(error as? ArchiveError, .unsupportedExtraction) }
  }

  /// Минимальные TAR-заголовки нужны для путей, которые файловая система не позволяет создать.
  private func tar(_ entries: [(String, UInt8)]) -> Data {
    var data = Data()
    for (name, type) in entries {
      var header = [UInt8](repeating: 0, count: 512)
      func field(_ value: String, at offset: Int) {
        let bytes = Array(value.utf8)
        header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
      }
      field(name, at: 0)
      field("0000644\0", at: 100)
      field("0000000\0", at: 108)
      field("0000000\0", at: 116)
      field("00000000000\0", at: 124)
      field("00000000000\0", at: 136)
      field("        ", at: 148)
      header[156] = type
      if type == 49 || type == 50 { field("keep.txt", at: 157) }
      field("ustar\0", at: 257)
      field("00", at: 263)
      let checksum = header.reduce(0) { $0 + Int($1) }
      field(String(format: "%06o\0 ", checksum), at: 148)
      data.append(contentsOf: header)
    }
    data.append(Data(repeating: 0, count: 1024))
    return data
  }

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pangozip-libarchive-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("docs/empty"), withIntermediateDirectories: true)
    try Data("inside".utf8).write(to: root.appendingPathComponent("docs/inside.txt"))
    try Data("keep".utf8).write(to: root.appendingPathComponent("keep.txt"))
    return root
  }

  private func run(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Resources/Engine/7zz")
    process.currentDirectoryURL = directory
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }
}
