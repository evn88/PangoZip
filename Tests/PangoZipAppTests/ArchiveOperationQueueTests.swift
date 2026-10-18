import Foundation
import PangoZipCore
import XCTest

@testable import PangoZipApp

final class ArchiveOperationQueueTests: XCTestCase, @unchecked Sendable {
  /// После изменения снимка доступен один откат, который обновляет таблицу исходным составом.
  @MainActor
  func testUndoRestoresDisplayedArchiveAndConsumesHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("original.txt")
    let addition = root.appendingPathComponent("added.txt")
    try Data("original".utf8).write(to: source)
    try Data("added".utf8).write(to: addition)
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [source], proposedURL: root.appendingPathComponent("test.zip"), format: "zip")
    let session = try await service.open(archive)
    let changed = try await service.add([addition], to: session)
    let model = ArchiveBrowserModel(service: service)
    await model.apply(changed)
    XCTAssertTrue(model.canUndoLastChange)
    model.undoLastChange()
    while model.isBusy { await Task.yield() }
    XCTAssertEqual(model.session?.entries.map(\.path), ["original.txt"])
    XCTAssertFalse(model.canUndoLastChange)
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }

  /// Очередь выполняет запросы по порядку и позволяет удалить ещё не начавшуюся задачу.
  @MainActor
  func testQueuedExportsRunInOrderAndRemovedTaskNeverWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let file = root.appendingPathComponent("note.txt")
    try Data("queued payload".utf8).write(to: file)
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [file], proposedURL: root.appendingPathComponent("test.zip"), format: "zip")
    let output = root.appendingPathComponent("output")
    try manager.createDirectory(at: output, withIntermediateDirectories: false)
    let removed = root.appendingPathComponent("removed")
    try manager.createDirectory(at: removed, withIntermediateDirectories: false)
    let model = ArchiveBrowserModel(service: service)
    model.open(archive)
    while model.isBusy { await Task.yield() }
    model.enqueueExtraction(paths: ["note.txt"], to: output)
    model.enqueueExtraction(paths: ["note.txt"], to: removed)
    model.enqueueExtraction(paths: ["note.txt"], to: output)
    XCTAssertEqual(model.queuedOperations.count, 2)
    if let first = model.queuedOperations.first { model.removeQueuedOperation(first.id) }
    XCTAssertEqual(model.queuedOperations.count, 1)
    while model.isBusy || !model.queuedOperations.isEmpty { await Task.yield() }
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(
      try manager.contentsOfDirectory(atPath: output.path).sorted(), ["note (2).txt", "note.txt"])
    XCTAssertEqual(try manager.contentsOfDirectory(atPath: removed.path), [])
    model.open(archive)
    XCTAssertFalse(model.canQueueOperations)
    model.enqueueExtraction(paths: ["note.txt"], to: removed)
    XCTAssertTrue(model.queuedOperations.isEmpty)
    while model.isBusy { await Task.yield() }
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }

  /// Ошибка не запускает следующие запросы до явного продолжения очереди.
  @MainActor
  func testFailurePausesRemainingExportsUntilExplicitResume() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("note.txt")
    try Data("payload".utf8).write(to: file)
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [file], proposedURL: root.appendingPathComponent("test.zip"), format: "zip")
    let output = root.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    let model = ArchiveBrowserModel(service: service)
    model.open(archive)
    while model.isBusy { await Task.yield() }
    model.enqueueExtraction(paths: ["missing.txt"], to: output)
    model.enqueueExtraction(paths: ["note.txt"], to: output)
    while model.isBusy { await Task.yield() }
    XCTAssertTrue(model.isQueuePaused)
    XCTAssertEqual(model.queuedOperations.count, 1)
    XCTAssertNotNil(model.errorMessage)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    model.resumeQueuedOperations()
    while model.isBusy { await Task.yield() }
    XCTAssertFalse(model.isQueuePaused)
    XCTAssertTrue(model.queuedOperations.isEmpty)
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(
      try String(contentsOf: output.appendingPathComponent("note.txt"), encoding: .utf8), "payload")
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }

  /// Закрытие отменяет ожидающие операции, не выполняя их после очистки сеанса.
  @MainActor
  func testClosingCancelsQueuedOperations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("note.txt")
    try Data("payload".utf8).write(to: file)
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [file], proposedURL: root.appendingPathComponent("test.zip"), format: "zip")
    let output = root.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    let model = ArchiveBrowserModel(service: service)
    model.open(archive)
    while model.isBusy { await Task.yield() }
    model.enqueueExtraction(paths: ["note.txt"], to: output)
    model.enqueueExtraction(paths: ["note.txt"], to: output)
    XCTAssertEqual(model.queuedOperations.count, 1)
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
    XCTAssertTrue(model.queuedOperations.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: output.appendingPathComponent("note (2).txt").path))
  }
}
