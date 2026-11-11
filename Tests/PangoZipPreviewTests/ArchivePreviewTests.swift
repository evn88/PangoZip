import AppKit
import Foundation
import PangoZipCore
import XCTest

@testable import PangoZipPreview

final class ArchivePreviewTests: XCTestCase, @unchecked Sendable {
  @MainActor
  func testPreviewListsWithoutExtractingAndExportsChosenItemAndNamedArchive() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("Hello.txt")
    try Data("hello".utf8).write(to: input)
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [input], proposedURL: root.appendingPathComponent("Sample.zip"), format: "zip")
    let original = try Data(contentsOf: archive)
    try FileManager.default.removeItem(at: input)
    let model = ArchivePreviewModel()
    try await model.prepare(archive)
    XCTAssertEqual(model.session?.entries.map(\.path), ["Hello.txt"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
    let selected = try await model.extract(to: root, path: "Hello.txt")
    XCTAssertEqual(try String(contentsOf: XCTUnwrap(selected.first), encoding: .utf8), "hello")
    let all = try await model.extract(to: root)
    XCTAssertEqual(all.first?.lastPathComponent, "Sample")
    XCTAssertEqual(
      try String(
        contentsOf: XCTUnwrap(all.first).appendingPathComponent("Hello.txt"), encoding: .utf8),
      "hello")
    let repeated = try await model.extract(to: root)
    XCTAssertNotEqual(repeated.first, all.first)
    XCTAssertEqual(try Data(contentsOf: archive), original)
    await model.close()
    XCTAssertNil(model.session)
  }
  /// Множественный выбор извлекает только верхние объекты; сводка считает размеры папок.
  @MainActor
  func testMultipleSelectionSkipsNestedItemsAndSummaryCountsFolders() async throws {
    XCTAssertEqual(
      ArchivePreviewModel.topLevelPaths(["A/B/c.txt", "A", "A2/x", "A/B", "A2/x"]), ["A", "A2/x"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let nested = root.appendingPathComponent("Docs/Inner")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("12345".utf8).write(to: nested.appendingPathComponent("Deep.txt"))
    try Data("123".utf8).write(to: root.appendingPathComponent("Docs/Note.txt"))
    try Data("1".utf8).write(to: root.appendingPathComponent("Top.txt"))
    let archive = try await ArchiveService().createArchive(
      from: [root.appendingPathComponent("Docs"), root.appendingPathComponent("Top.txt")],
      proposedURL: root.appendingPathComponent("Sample.zip"), format: "zip")
    let model = ArchivePreviewModel()
    try await model.prepare(archive)
    XCTAssertEqual(model.totalSize, 9)
    XCTAssertEqual(model.folderSizes["Docs"], 8)
    XCTAssertEqual(model.folderSizes["Docs/Inner"], 5)
    XCTAssertFalse(model.hasEncryptedEntries)
    let output = root.appendingPathComponent("Output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    let results = try await model.extract(
      to: output, paths: ["Top.txt", "Docs/Inner/Deep.txt", "Docs"])
    XCTAssertEqual(results.map(\.lastPathComponent), ["Docs", "Top.txt"])
    XCTAssertEqual(
      try String(
        contentsOf: output.appendingPathComponent("Docs/Inner/Deep.txt"), encoding: .utf8),
      "12345")
    XCTAssertFalse(model.isBusy)
    await model.close()
    XCTAssertEqual(model.totalSize, 0)
  }

  @MainActor
  func testSwitchingPreviewCancelsEarlierRequestAndClosingReleasesSession() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("Hello.txt")
    try Data("hello".utf8).write(to: input)
    let service = ArchiveService()
    let firstURL = try await service.createArchive(
      from: [input], proposedURL: root.appendingPathComponent("First.zip"), format: "zip")
    let secondURL = root.appendingPathComponent("Second.zip")
    try FileManager.default.copyItem(at: firstURL, to: secondURL)
    let controller = PreviewViewController()
    let first = Task { try await controller.preparePreviewOfFile(at: firstURL) }
    await Task.yield()
    try await controller.preparePreviewOfFile(at: secondURL)
    _ = try? await first.value
    XCTAssertEqual(controller.model.session?.url, secondURL)
    controller.viewWillDisappear()
    for _ in 0..<100 where controller.model.session != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(controller.model.session)
    let opening = Task { try await controller.preparePreviewOfFile(at: firstURL) }
    await Task.yield()
    controller.viewWillDisappear()
    _ = try? await opening.value
    XCTAssertNil(controller.model.session)
  }

}
