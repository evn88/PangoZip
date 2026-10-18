import AppKit
import PangoZipCore
import XCTest

@testable import PangoZipApp

final class ArchiveFilePromiseTests: XCTestCase, @unchecked Sendable {
  @MainActor
  /// Проверяет, что последовательный экспорт сохраняет блокировку архива до завершения всех обещаний.
  func testMultiplePromisesExportSequentiallyAndReleaseDragLease() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [root.appendingPathComponent("Folder"), root.appendingPathComponent("File.txt")],
      proposedURL: root.appendingPathComponent("sample.zip"), format: "zip")
    let model = ArchiveBrowserModel(service: service)
    model.open(archive)
    while model.isBusy { await Task.yield() }
    let snapshot = try XCTUnwrap(model.session)
    let dragID = UUID()
    model.beginDragging(id: dragID, paths: ["Folder", "File.txt"])
    XCTAssertFalse(model.canAct)
    model.endDragging(id: dragID, deposited: true)
    async let first = fulfill(
      path: "Folder", isDirectory: true, model: model, session: snapshot, dragID: dragID,
      destination: root.appendingPathComponent("output/Folder"))
    async let second = fulfill(
      path: "File.txt", isDirectory: false, model: model, session: snapshot, dragID: dragID,
      destination: root.appendingPathComponent("output/File.txt"))
    let errors = await [first, second]
    XCTAssertTrue(errors.allSatisfy { $0 == nil })
    while model.isExporting { await Task.yield() }
    XCTAssertTrue(model.canAct)
    XCTAssertEqual(
      try String(
        contentsOf: root.appendingPathComponent("output/Folder/Nested.txt"), encoding: .utf8),
      "nested")
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("output/File.txt"), encoding: .utf8),
      "file")
    let terminated = await model.requestTermination()
    XCTAssertTrue(terminated)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("output/File.txt").path))
  }

  @MainActor
  /// Проверяет освобождение блокировки после отмены и отказ просроченной сессии.
  func testCancelledDragUnlocksArchiveAndClosedSessionRejectsLatePromise() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [root.appendingPathComponent("File.txt")],
      proposedURL: root.appendingPathComponent("sample.zip"), format: "zip")
    let model = ArchiveBrowserModel(service: service)
    model.open(archive)
    while model.isBusy { await Task.yield() }
    let snapshot = try XCTUnwrap(model.session)
    let dragID = UUID()
    model.beginDragging(id: dragID, paths: ["File.txt"])
    model.endDragging(id: dragID, deposited: false)
    XCTAssertTrue(model.canAct)
    let terminated = await model.requestTermination()
    XCTAssertTrue(terminated)
    let target = root.appendingPathComponent("output/File.txt")
    let error = await fulfill(
      path: "File.txt", isDirectory: false, model: model, session: snapshot, dragID: dragID,
      destination: target)
    XCTAssertEqual(error as? ArchiveError, .sessionExpired)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }

  /// Получатель AppKit уже удерживает координацию записи до завершения обещания папки.
  @MainActor
  func testEmptyFolderPromiseCompletesInsideReceiverCoordination() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let empty = root.appendingPathComponent("Empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [empty], proposedURL: root.appendingPathComponent("empty.zip"), format: "zip")
    let model = ArchiveBrowserModel(service: service)
    model.open(archive)
    while model.isBusy { await Task.yield() }
    let snapshot = try XCTUnwrap(model.session)
    let target = root.appendingPathComponent("output/Empty")
    let done = expectation(description: "Receiver releases coordination")
    let completed = expectation(description: "Empty folder promise completed")
    let completion = PromiseCompletion { error in
      XCTAssertNil(error)
      completed.fulfill()
    }
    let dragID = UUID()
    model.beginDragging(id: dragID, paths: ["Empty"])
    let queue = DispatchQueue(label: "test.promise.receiver")
    queue.async {
      var error: NSError?
      NSFileCoordinator().coordinate(writingItemAt: target, options: [], error: &error) { url in
        let signal = DispatchSemaphore(value: 0)
        Task { @MainActor in
          model.fulfillPromise(
            path: "Empty", session: snapshot, to: url, dragID: dragID,
            completion: PromiseCompletion { error in
              completion.finish(error)
              signal.signal()
            })
        }
        XCTAssertEqual(signal.wait(timeout: .now() + 3), .success)
      }
      done.fulfill()
    }
    await fulfillment(of: [done, completed], timeout: 6)
    while model.isExporting { await Task.yield() }
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }

  /// Передаёт запрос promise делегату и проверяет согласованность его имени.
  @MainActor
  private func fulfill(
    path: String, isDirectory: Bool, model: ArchiveBrowserModel, session: ArchiveSession,
    dragID: UUID, destination: URL
  ) async -> Error? {
    let delegate = ArchiveFilePromise(path: path, session: session, dragID: dragID, model: model)
    let provider = delegate.provider(isDirectory: isDirectory)
    XCTAssertEqual(delegate.filePromiseProvider(provider, fileNameForType: provider.fileType), path)
    return await withCheckedContinuation { continuation in
      delegate.filePromiseProvider(provider, writePromiseTo: destination) {
        continuation.resume(returning: $0)
      }
    }
  }

  /// Создаёт отдельные входные и выходные файлы для сценариев File Promise.
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pangozip-promises-" + UUID().uuidString)
    for directory in ["Folder", "output"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    try Data("nested".utf8).write(to: root.appendingPathComponent("Folder/Nested.txt"))
    try Data("file".utf8).write(to: root.appendingPathComponent("File.txt"))
    return root
  }
}
