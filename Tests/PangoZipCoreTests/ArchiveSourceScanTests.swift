import Foundation
import XCTest

@testable import PangoZipCore

final class ArchiveSourceScanTests: XCTestCase, @unchecked Sendable {
  private let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Engine/7zz")

  /// Обход считает файлы и ссылки, не входит в ссылки и собирает точные пути служебных файлов.
  func testScanCountsFilesAndCollectsSystemFileExclusions() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = [
      ArchiveSource(url: root.appendingPathComponent("Folder"), name: "Folder"),
      ArchiveSource(url: root.appendingPathComponent("top.bin"), name: "top.bin"),
    ]
    let scan = try await ArchiveSourceScan.scan(sources, skippingSystemFiles: true)
    // data.bin (5) + nested/deep.txt (4) + ссылка (длина пути назначения) + top.bin (3).
    XCTAssertEqual(scan.files, 4)
    XCTAssertEqual(scan.bytes, 5 + 4 + UInt64("../Outside".utf8.count) + 3)
    XCTAssertEqual(
      scan.excluded.sorted(),
      ["Folder/.DS_Store", "Folder/__MACOSX", "Folder/nested/._deep.txt"])
    let full = try await ArchiveSourceScan.scan(sources, skippingSystemFiles: false)
    XCTAssertEqual(full.files, 7)
    XCTAssertTrue(full.excluded.isEmpty)
    // Служебные файлы не входят в отпечаток, поэтому он не зависит от режима их исключения.
    XCTAssertEqual(full.signature, scan.signature)
  }

  /// Отпечаток меняется при правке, добавлении и удалении файлов, но не из-за .DS_Store.
  func testSignatureTracksUserFilesAndIgnoresSystemFiles() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Folder")
    let sources = [ArchiveSource(url: folder, name: "Folder")]
    let initial = try await ArchiveSourceScan.scan(sources, skippingSystemFiles: false)
    let repeated = try await ArchiveSourceScan.scan(sources, skippingSystemFiles: false)
    XCTAssertEqual(initial, repeated)
    try Data("finder".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
    try Data("finder".utf8).write(to: folder.appendingPathComponent("nested/.DS_Store"))
    let afterFinder = try await ArchiveSourceScan.scan(sources, skippingSystemFiles: false)
    XCTAssertEqual(afterFinder.signature, initial.signature)
    // Новая цель ссылки той же длины меняет отпечаток, хотя размер записи прежний.
    let link = folder.appendingPathComponent("link")
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../Outsidf")
    let afterRetarget = try await ArchiveSourceScan.scan(sources, skippingSystemFiles: false)
    XCTAssertNotEqual(afterRetarget.signature, initial.signature)
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../Outside")
    try Data("12345+".utf8).write(to: folder.appendingPathComponent("data.bin"))
    let afterEdit = try await ArchiveSourceScan.scan(sources, skippingSystemFiles: false)
    XCTAssertNotEqual(afterEdit.signature, initial.signature)
    try Data("new".utf8).write(to: folder.appendingPathComponent("nested/new.txt"))
    let afterAdd = try await ArchiveSourceScan.scan(sources, skippingSystemFiles: false)
    XCTAssertNotEqual(afterAdd.signature, afterEdit.signature)
    try FileManager.default.removeItem(at: folder.appendingPathComponent("nested/new.txt"))
    let afterRemove = try await ArchiveSourceScan.scan(sources, skippingSystemFiles: false)
    XCTAssertEqual(afterRemove.signature, afterEdit.signature)
  }

  /// Недоступный и специальный файлы останавливают операцию до начала сжатия.
  func testScanRejectsUnreadableAndSpecialFiles() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Folder")
    let sources = [ArchiveSource(url: folder, name: "Folder")]
    let locked = folder.appendingPathComponent("locked.bin")
    try Data("secret".utf8).write(to: locked)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    do {
      _ = try await ArchiveSourceScan.scan(sources, skippingSystemFiles: true)
      XCTFail("Expected permission error")
    } catch {
      XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoPermission)
    }
    try FileManager.default.removeItem(at: locked)
    XCTAssertEqual(mkfifo(folder.appendingPathComponent("pipe").path, 0o600), 0)
    do {
      _ = try await ArchiveSourceScan.scan(sources, skippingSystemFiles: true)
      XCTFail("Expected unsupported entry")
    } catch { XCTAssertEqual(error as? ArchiveError, .unsupportedEntry) }
  }

  /// Файлы сжимаются со своего места: объекты из разных папок попадают в корень архива,
  /// служебные исключаются по точным путям, включая «Icon\r», а ссылка остаётся ссылкой.
  func testCreationReadsSourcesInPlaceFromDifferentFolders() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Folder")
    try Data().write(to: folder.appendingPathComponent("Icon\r"))
    try Data("keep".utf8).write(to: folder.appendingPathComponent("Icon"))
    try Data("keep".utf8).write(to: folder.appendingPathComponent("nested/.DS_Store.txt"))
    let other = root.appendingPathComponent("Elsewhere/sub")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try Data("far".utf8).write(to: other.appendingPathComponent("far away.txt"))
    try Data("x".utf8).write(to: other.appendingPathComponent(".DS_Store"))
    let service = ArchiveService(executableURL: engine)
    let expected = [
      "Folder", "Folder/Icon", "Folder/data.bin", "Folder/link", "Folder/nested",
      "Folder/nested/.DS_Store.txt", "Folder/nested/deep.txt", "sub", "sub/far away.txt",
      "top.bin",
    ]
    for format in ["zip", "7z", "tar"] {
      let archive = try await service.createArchive(
        from: [folder, root.appendingPathComponent("top.bin"), other],
        proposedURL: root.appendingPathComponent("out." + format), format: format)
      let session = try await service.open(archive)
      XCTAssertEqual(session.entries.map(\.path).sorted(), expected, format)
      let link = try XCTUnwrap(session.entries.first { $0.path == "Folder/link" })
      XCTAssertTrue(link.isSymbolicLink, format)
      let data = try XCTUnwrap(session.entries.first { $0.path == "Folder/data.bin" })
      XCTAssertEqual(data.size, 5, format)
      try await service.close(session)
    }
    // Сжатый TAR собирается конвейером двух процессов без промежуточного файла.
    for format in ["tar.gz", "tar.xz"] {
      let archive = try await service.createArchive(
        from: [root.appendingPathComponent("top.bin"), other],
        proposedURL: root.appendingPathComponent("piped." + format), format: format)
      let session = try await service.open(archive)
      XCTAssertEqual(session.entries.map(\.path), ["piped.tar"], format)
      try await service.close(session)
      let output = try await service.extractArchive(archive)
      let found = try XCTUnwrap(FileManager.default.enumerator(atPath: output.path))
        .compactMap { $0 as? String }.sorted()
      XCTAssertEqual(found, ["sub", "sub/far away.txt", "top.bin"], format)
      XCTAssertEqual(
        try Data(contentsOf: output.appendingPathComponent("sub/far away.txt")), Data("far".utf8))
      try FileManager.default.removeItem(at: output)
    }
    // Исходники остаются на месте и не меняются.
    XCTAssertEqual(
      try Data(contentsOf: folder.appendingPathComponent("data.bin")), Data("12345".utf8))
    await service.cleanup()
  }

  /// Одинаковые имена из разных папок не могут занять одно место в корне архива.
  func testCreationRejectsEqualTopLevelNamesFromDifferentFolders() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let other = root.appendingPathComponent("Elsewhere")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try Data("b".utf8).write(to: other.appendingPathComponent("top.bin"))
    let service = ArchiveService(executableURL: engine)
    do {
      _ = try await service.createArchive(
        from: [root.appendingPathComponent("top.bin"), other.appendingPathComponent("top.bin")],
        proposedURL: root.appendingPathComponent("dup.zip"), format: "zip")
      XCTFail("Expected duplicate path")
    } catch { XCTAssertEqual(error as? ArchiveError, .duplicatePath) }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("dup.zip").path))
    await service.cleanup()
  }

  /// Файл, изменённый во время сжатия, не даёт опубликовать архив со смесью старого и нового.
  func testCreationFailsWhenSourceChangesDuringCompression() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("Folder/data.bin")
    let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let wrapper = root.appendingPathComponent("editing-engine")
    let script = """
      #!/bin/sh
      if [ "$1" = a ]; then printf 'changed while reading' > \(quote(target.path)); fi
      exec \(quote(engine.path)) "$@"
      """
    try Data(script.utf8).write(to: wrapper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let service = ArchiveService(executableURL: wrapper)
    do {
      _ = try await service.createArchive(
        from: [root.appendingPathComponent("Folder")],
        proposedURL: root.appendingPathComponent("changed.zip"), format: "zip")
      XCTFail("Expected source change")
    } catch { XCTAssertEqual(error as? ArchiveError, .sourceChanged) }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("changed.zip").path))
    await service.cleanup()
  }

  /// Создание не ограничено по времени и сообщает о подготовке, файлах и имени до первого процента.
  func testCreationReportsPreparationAndEngineDetails() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let samples = ScanSamples()
    _ = try await service.createArchive(
      from: [root.appendingPathComponent("Folder")],
      proposedURL: root.appendingPathComponent("progress.zip"), format: "zip",
      progress: { await samples.record($0) })
    let values = await samples.values
    XCTAssertEqual(values.first?.phase, .preparing)
    let compressing = values.filter { $0.phase == .compressing }
    XCTAssertEqual(compressing.first?.fraction, 0)
    XCTAssertTrue(compressing.allSatisfy { $0.totalFiles == 3 })
    XCTAssertEqual(values.last?.fraction, 1)
    XCTAssertEqual(values.last?.completedFiles, 3)
    await service.cleanup()
  }

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("Folder")
    let manager = FileManager.default
    try manager.createDirectory(
      at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try manager.createDirectory(
      at: folder.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
    try manager.createDirectory(
      at: root.appendingPathComponent("Outside"), withIntermediateDirectories: true)
    try Data("outside".utf8).write(to: root.appendingPathComponent("Outside/secret.txt"))
    try Data("12345".utf8).write(to: folder.appendingPathComponent("data.bin"))
    try Data("deep".utf8).write(to: folder.appendingPathComponent("nested/deep.txt"))
    try Data("x".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
    try Data("xx".utf8).write(to: folder.appendingPathComponent("__MACOSX/._data.bin"))
    try Data("xxx".utf8).write(to: folder.appendingPathComponent("nested/._deep.txt"))
    try manager.createSymbolicLink(
      atPath: folder.appendingPathComponent("link").path, withDestinationPath: "../Outside")
    try Data("top".utf8).write(to: root.appendingPathComponent("top.bin"))
    return root
  }
}

private actor ScanSamples {
  private(set) var values: [ArchiveProgress] = []
  /// Сохраняет событие прогресса для проверки последовательности вызовов.
  func record(_ value: ArchiveProgress) { values.append(value) }
}
