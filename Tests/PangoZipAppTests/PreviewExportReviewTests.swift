import AppKit
import PangoZipCore
import XCTest

@testable import PangoZipApp

final class PreviewExportReviewTests: XCTestCase, @unchecked Sendable {
  @MainActor
  func testHiddenPreviewKeepsContentUntilSelectionChanges() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("First.txt")
    let second = root.appendingPathComponent("Second.txt")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [first, second], proposedURL: root.appendingPathComponent("sample.zip"), format: "zip")
    let model = ArchiveBrowserModel(service: service)
    model.open(archive)
    try await waitUntil { !model.isBusy }
    model.selectedPaths = ["First.txt"]
    try await waitUntil { model.previewURL != nil }
    let preview = try XCTUnwrap(model.previewURL)
    model.togglePreview()
    XCTAssertFalse(model.showsPreview)
    XCTAssertEqual(model.previewURL, preview, "Содержимое не должно мигать во время скрытия")
    model.togglePreview()
    XCTAssertEqual(model.previewURL, preview)
    XCTAssertFalse(model.isMaterializing)
    model.togglePreview()
    model.selectedPaths = ["Second.txt"]
    XCTAssertNil(model.previewURL, "Смена выделения должна убрать прежний файл")
    model.togglePreview()
    try await waitUntil { model.previewURL != nil }
    let secondPreview = try XCTUnwrap(model.previewURL)
    XCTAssertEqual(try Data(contentsOf: secondPreview), Data("second".utf8))
    _ = await model.requestTermination()
  }

  /// Выделение во время экспорта откладывает предпросмотр до освобождения архива без ложной ошибки.
  @MainActor
  func testSelectionDuringExportResumesPreviewAfterPromiseCompletes() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? Data().write(to: root.appendingPathComponent("release-x"))
      try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("output"), withIntermediateDirectories: false)
    let input = root.appendingPathComponent("File.txt")
    try Data("preview after export".utf8).write(to: input)
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Resources/Engine/7zz")
    let preparation = ArchiveService(executableURL: engine)
    let archive = try await preparation.createArchive(
      from: [input], proposedURL: root.appendingPathComponent("sample.zip"), format: "zip")
    await preparation.cleanup()
    let wrapper = root.appendingPathComponent("gated-engine")
    let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let script = """
      #!/bin/sh
      gate=\(quote(root.path))
      if [ "$1" = x ]; then
        touch "$gate/ready-x"
        until [ -f "$gate/release-x" ]; do sleep 0.01; done
      fi
      exec \(quote(engine.path)) "$@"
      """
    try Data(script.utf8).write(to: wrapper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let model = ArchiveBrowserModel(service: ArchiveService(executableURL: wrapper, timeout: 10))
    model.open(archive)
    try await waitUntil { !model.isBusy }
    let snapshot = try XCTUnwrap(model.session)
    let dragID = UUID()
    model.beginDragging(id: dragID, paths: ["File.txt"])
    var completed = false
    var exportError: Error?
    model.fulfillPromise(
      path: "File.txt", session: snapshot, to: root.appendingPathComponent("output/File.txt"),
      dragID: dragID,
      completion: PromiseCompletion {
        exportError = $0
        completed = true
      })
    try await waitUntil {
      FileManager.default.fileExists(atPath: root.appendingPathComponent("ready-x").path)
    }
    model.selectedPaths = ["File.txt"]
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(model.isExporting)
    XCTAssertFalse(model.isMaterializing)
    XCTAssertNil(model.errorMessage)
    try Data().write(to: root.appendingPathComponent("release-x"))
    try await waitUntil { completed && !model.isExporting && !model.isMaterializing }
    XCTAssertNil(exportError)
    XCTAssertNil(model.errorMessage)
    let preview = try XCTUnwrap(model.previewURL)
    XCTAssertEqual(try Data(contentsOf: preview), Data("preview after export".utf8))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("output/File.txt")),
      Data("preview after export".utf8))
    let terminated = await model.requestTermination()
    XCTAssertTrue(terminated)
  }

  /// Ограничивает ожидание состояния модели, сохраняя главный актор доступным задачам интерфейса.
  @MainActor
  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard condition() else {
      throw NSError(
        domain: "PreviewExportReviewTests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for export or preview"])
    }
  }
}
