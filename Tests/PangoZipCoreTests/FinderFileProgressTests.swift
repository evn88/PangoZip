import Foundation
import Synchronization
import XCTest

@testable import PangoZipCore

/// Отмечает, что пустой файл был виден во время сжатия.
private final class Flag: Sendable {
  private let value = Mutex(false)
  var isSet: Bool { value.withLock { $0 } }
  func set() { value.withLock { $0 = true } }
}

final class FinderFileProgressTests: XCTestCase, @unchecked Sendable {
  private let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Engine/7zz")

  /// Пустой файл занимает свободное имя, а после завершения исчезает.
  func testReserveTakesFreeNameAndFinishRemovesPlaceholder() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let proposed = root.appendingPathComponent("Sample.tar.gz")
    try Data("busy".utf8).write(to: proposed)
    let progress = FinderFileProgress()
    let target = progress.reserve(
      proposed: proposed, format: "tar.gz", volumes: false, sources: [])
    XCTAssertEqual(target?.lastPathComponent, "Sample (2).tar.gz")
    let placeholder = root.appendingPathComponent("Sample (2).tar.gz")
    let attributes = try FileManager.default.attributesOfItem(atPath: placeholder.path)
    XCTAssertEqual(attributes[.size] as? Int, 0)
    XCTAssertTrue(OwnOutputRegistry.shared.contains(placeholder))
    progress.update(ArchiveProgress(phase: .compressing, fraction: 0.5, totalFiles: 3))
    progress.finish()
    XCTAssertFalse(FileManager.default.fileExists(atPath: placeholder.path))
    XCTAssertFalse(OwnOutputRegistry.shared.contains(placeholder))
    XCTAssertEqual(try String(contentsOf: proposed, encoding: .utf8), "busy")
    progress.finish()
  }

  /// Для набора томов место занимает первый том, а архив публикуется под общей основой имени.
  func testVolumesReserveFirstVolume() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let progress = FinderFileProgress()
    let target = progress.reserve(
      proposed: root.appendingPathComponent("Set.7z"), format: "7z", volumes: true, sources: [])
    XCTAssertEqual(target?.lastPathComponent, "Set.7z")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Set.7z.001").path))
    progress.finish()
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
  }

  /// Чужой файл на месте пустого не удаляется; внутри исходной папки место не занимается.
  func testFinishKeepsReplacedFileAndSkipsSourceFolder() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let proposed = root.appendingPathComponent("Own.zip")
    let progress = FinderFileProgress()
    XCTAssertNotNil(
      progress.reserve(proposed: proposed, format: "zip", volumes: false, sources: []))
    try FileManager.default.removeItem(at: proposed)
    try Data("other".utf8).write(to: proposed)
    progress.finish()
    XCTAssertEqual(try String(contentsOf: proposed, encoding: .utf8), "other")

    let inside = FinderFileProgress()
    XCTAssertNil(
      inside.reserve(
        proposed: root.appendingPathComponent("Inner.zip"), format: "zip", volumes: false,
        sources: [root]))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Inner.zip").path))
  }

  /// Во время сжатия под будущим именем лежит пустой файл, после — готовый архив без остатков.
  func testCreateArchiveShowsPlaceholderWhileCompressing() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("a.txt")
    try Data(repeating: 65, count: 200_000).write(to: source)
    let proposed = root.appendingPathComponent("Result.zip")
    let seen = Flag()
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [source], proposedURL: proposed, format: "zip"
    ) { update in
      guard update.phase == .compressing,
        let size = try? FileManager.default.attributesOfItem(atPath: proposed.path)[.size]
          as? Int, size == 0
      else { return }
      seen.set()
    }
    XCTAssertEqual(archive, proposed)
    XCTAssertTrue(seen.isSet)
    XCTAssertGreaterThan(
      try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int ?? 0, 0)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
      ["Result.zip", "a.txt"])
    await service.cleanup()
  }

  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FinderFileProgressTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
  }
}
