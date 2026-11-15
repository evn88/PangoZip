import Foundation
import XCTest

@testable import PangoZipCore

final class ArchiveCreationBatchTests: XCTestCase {
  private var root: URL!
  private let service = ArchiveService()

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    await service.cleanup()
    try? FileManager.default.removeItem(at: root)
  }

  private func file(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try Data(name.utf8).write(to: url)
    return url.standardizedFileURL
  }

  /// Записывает вызовы вместо настоящей Корзины, чтобы тест не засорял её.
  private final class TrashLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var failing = false

    func trash(_ url: URL) throws {
      if failing { throw CocoaError(.fileWriteNoPermission) }
      lock.withLock { urls.append(url) }
    }

    var names: [String] { lock.withLock { urls.map(\.lastPathComponent) } }
  }

  func testSeparateModeCreatesOneArchivePerItem() async throws {
    let sources = [try file("First.txt"), try file("Second.txt")]
    let log = TrashLog()

    let outcome = try await service.createArchives(
      from: sources, proposedURL: root.appendingPathComponent("Both.zip"), format: "zip",
      separately: true, trashesSources: false, trash: log.trash)

    XCTAssertEqual(outcome.urls.map(\.lastPathComponent), ["First.zip", "Second.zip"])
    XCTAssertNil(outcome.trashFailure)
    XCTAssertTrue(log.names.isEmpty)
    let second = try await service.open(outcome.urls[1])
    XCTAssertEqual(second.entries.map(\.path), ["Second.txt"])
  }

  func testCombinedModeTrashesSourcesOnlyAfterArchiveExists() async throws {
    let sources = [try file("First.txt"), try file("Second.txt")]
    let log = TrashLog()

    let outcome = try await service.createArchives(
      from: sources, proposedURL: root.appendingPathComponent("Both.zip"), format: "zip",
      separately: false, trashesSources: true, trash: log.trash)

    XCTAssertEqual(outcome.urls.map(\.lastPathComponent), ["Both.zip"])
    XCTAssertEqual(Set(log.names), ["First.txt", "Second.txt"])
    XCTAssertNil(outcome.trashFailure)
  }

  func testFailedArchiveLeavesSourcesAndTrashFailureIsReported() async throws {
    let source = try file("Only.txt")
    let log = TrashLog()
    do {
      _ = try await service.createArchives(
        from: [source], proposedURL: root.appendingPathComponent("Only.rar"), format: "rar",
        separately: false, trashesSources: true, trash: log.trash)
      XCTFail("Неподдерживаемый формат должен завершиться ошибкой")
    } catch {
      XCTAssertTrue(log.names.isEmpty)
    }

    log.failing = true
    let outcome = try await service.createArchives(
      from: [source], proposedURL: root.appendingPathComponent("Only.zip"), format: "zip",
      separately: false, trashesSources: true, trash: log.trash)
    XCTAssertEqual(outcome.urls.count, 1)
    XCTAssertNotNil(outcome.trashFailure)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }
}
