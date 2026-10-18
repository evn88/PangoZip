import XCTest

@testable import PangoZipCore

final class ArchiveExportTests: XCTestCase, @unchecked Sendable {
  private let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
      "Resources/Engine/7zz")

  /// Проверяет устранение повторного экспорта потомков и сохранение структуры каталогов.
  func testExportSelectionCollapsesDescendantsAndKeepsFolderStructure() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(root.appendingPathComponent("sample.zip"))
    let paths = try ArchiveSelection.topLevelPaths(
      ["docs", "docs/inside.txt", "keep.txt", "docs"], entries: session.entries)
    XCTAssertEqual(paths, ["docs", "keep.txt"])
    let destination = root.appendingPathComponent("output")
    let results = try await service.exportSelection(paths, from: session, to: destination)
    XCTAssertEqual(results.map(\.lastPathComponent), ["docs", "keep.txt"])
    XCTAssertEqual(
      try String(
        contentsOf: destination.appendingPathComponent("docs/inside.txt"), encoding: .utf8),
      "inside")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: destination.appendingPathComponent("docs/empty").path))
    let preview = try await service.materialize(
      XCTUnwrap(session.entries.first { $0.path == "keep.txt" }), in: session)
    try await service.close(session)
    XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: destination.appendingPathComponent("keep.txt").path))
    await service.cleanup()
  }

  /// Проверяет точный путь назначения и защиту существующего файла от перезаписи.
  func testPromiseUsesExactDestinationAndNeverOverwritesExistingFile() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let archive = root.appendingPathComponent("sample.zip")
    let original = try Data(contentsOf: archive)
    let session = try await service.open(archive)
    let target = root.appendingPathComponent("output/Finder renamed.txt")
    let result = try await service.exportItem("docs/inside.txt", from: session, to: target)
    XCTAssertEqual(result, target)
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "inside")
    try Data("existing".utf8).write(to: target)
    do {
      _ = try await service.exportItem("keep.txt", from: session, to: target)
      XCTFail("Expected conflict")
    } catch { XCTAssertEqual((error as? POSIXError)?.code, .EEXIST) }
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "existing")
    XCTAssertEqual(try Data(contentsOf: archive), original)
    await service.cleanup()
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        .contains { $0.hasPrefix(".zipevra-") || $0.hasPrefix(".pangozip-") })
  }

  /// Проверяет разрешение совпадающих имён и экспорт только выбранных путей.
  func testExportSelectionResolvesBasenameCollisionsAndDoesNotExportUnselectedFiles() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(root.appendingPathComponent("sample.zip"))
    let result = try await service.exportSelection(
      ["docs/inside.txt", "other/inside.txt"], from: session,
      to: root.appendingPathComponent("output"))
    XCTAssertEqual(result.map(\.lastPathComponent), ["inside.txt", "inside (2).txt"])
    XCTAssertEqual(try String(contentsOf: result[1], encoding: .utf8), "other")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("output").path
      ).count, 2)
    XCTAssertThrowsError(try ArchiveSelection.topLevelPaths(["missing"], entries: session.entries))
    await service.cleanup()
  }

  /// Проверяет, что отмена и ошибки лимитов не оставляют частичный результат.
  func testCancelledExpiredAndOversizedExportsLeaveNoPartialFile() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(root.appendingPathComponent("sample.zip"))
    let target = root.appendingPathComponent("output/export.txt")
    do {
      _ = try await service.exportItem("keep.txt", from: session, to: target, maximumBytes: 1)
      XCTFail("Expected limit")
    } catch { XCTAssertEqual(error as? ArchiveError, .outputLimit) }
    let task = Task { try await service.exportItem("docs", from: session, to: target) }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    try await service.close(session)
    do {
      _ = try await service.exportItem("keep.txt", from: session, to: target)
      XCTFail("Expected expired session")
    } catch { XCTAssertEqual(error as? ArchiveError, .sessionExpired) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    await service.cleanup()
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("output").path), [])
  }

  /// Отмена перед публикацией пустой папки завершает задачу и не оставляет частичный результат.
  func testEmptyFolderCancellationAtFinalizingLeavesNoOutput() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(root.appendingPathComponent("sample.zip"))
    let target = root.appendingPathComponent("output/empty")
    let job = Task {
      try await service.exportItem(
        "docs/empty", from: session, to: target,
        progress: { value in
          if value.phase == .finalizing { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
    do {
      _ = try await job.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    try await service.close(session)
  }

  /// Создаёт архив с вложенными путями для проверки выборочного экспорта.
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pangozip-export-" + UUID().uuidString)
    let manager = FileManager.default
    for directory in ["docs/empty", "other", "output"] {
      try manager.createDirectory(
        at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    try Data("inside".utf8).write(to: root.appendingPathComponent("docs/inside.txt"))
    try Data("other".utf8).write(to: root.appendingPathComponent("other/inside.txt"))
    try Data("keep".utf8).write(to: root.appendingPathComponent("keep.txt"))
    let process = Process()
    process.executableURL = engine
    process.currentDirectoryURL = root
    process.arguments = ["a", "sample.zip", "docs", "other", "keep.txt"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return root
  }
}
