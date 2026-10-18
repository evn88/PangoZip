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
