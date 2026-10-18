import Foundation
import PangoZipCore
import XCTest

@testable import PangoZipApp

final class ArchiveAutosaveTests: XCTestCase, @unchecked Sendable {
  /// Отмена сохранения при закрытии не должна удалять единственную рабочую копию.
  @MainActor
  func testCancelledSaveBeforeCloseKeepsWorkingCopy() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("note.txt")
    try Data("original".utf8).write(to: source)
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [source], proposedURL: root.appendingPathComponent("test.zip"), format: "zip")
    let original = try Data(contentsOf: archive)
    let model = ArchiveBrowserModel(service: service)
    model.open(archive)
    while model.isBusy { await Task.yield() }
    let session = try XCTUnwrap(model.session)
    let edit = try await service.beginEditing(XCTUnwrap(session.entries.first), in: session)
    try model.watchWorkingCopy(edit)
    try Data("unsaved".utf8).write(to: edit.fileURL)
    let closing = Task { await model.saveWorkingCopiesBeforeClosing() }
    closing.cancel()
    let canClose = await closing.value
    XCTAssertFalse(canClose)
    XCTAssertEqual(try Data(contentsOf: archive), original)
    XCTAssertTrue(FileManager.default.fileExists(atPath: edit.fileURL.path))
    model.saveWorkingCopies()
    while model.isBusy { await Task.yield() }
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }

  /// Сохраняет изменённую копию без команды пользователя и продолжает следить за заменённым файлом.
  @MainActor
  func testAutosaveWaitsForStableFileAndKeepsWatchingAtomicSaves() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("note.txt")
    try Data("original".utf8).write(to: source)
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [source], proposedURL: root.appendingPathComponent("test.zip"), format: "zip")
    let model = ArchiveBrowserModel(service: service)
    model.open(archive)
    while model.isBusy { await Task.yield() }
    let initial = try XCTUnwrap(model.session)
    let edit = try await service.beginEditing(XCTUnwrap(initial.entries.first), in: initial)
    try model.watchWorkingCopy(edit)
    for value in ["changed once", "changed twice"] {
      try Data(value.utf8).write(to: edit.fileURL, options: .atomic)
      await model.autosaveChangedCopies()
      XCTAssertFalse(model.isBusy)
      await model.autosaveChangedCopies()
      while model.isBusy { await Task.yield() }
      XCTAssertNil(model.errorMessage)
      let snapshot = try XCTUnwrap(model.session)
      let file = try await service.materialize(XCTUnwrap(snapshot.entries.first), in: snapshot)
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), value)
      XCTAssertTrue(FileManager.default.fileExists(atPath: edit.fileURL.path))
      XCTAssertEqual(model.activeEdits.count, 1)
    }
    await model.autosaveChangedCopies()
    XCTAssertFalse(model.isBusy)
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }
}
