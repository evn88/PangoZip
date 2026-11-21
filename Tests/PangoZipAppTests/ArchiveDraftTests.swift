import Foundation
import PangoZipCore
import XCTest

@testable import PangoZipApp

final class ArchiveDraftTests: XCTestCase, @unchecked Sendable {
  private var root: URL!
  private var service: ArchiveService!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Resources/Engine/7zz")
    service = ArchiveService(executableURL: engine)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func file(_ name: String, _ text: String = "payload") throws -> URL {
    let url = root.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  /// Обычные файлы, брошенные в пустое окно, начинают черновик без повторов и без архива на диске.
  @MainActor
  func testDroppedFilesStartDraftWithoutDuplicates() async throws {
    let first = try file("first.txt")
    let second = try file("second.txt")
    let model = ArchiveBrowserModel(service: service)
    model.receiveDroppedFiles([first, second])
    XCTAssertEqual(model.draft, [first, second])
    model.receiveDroppedFiles([second])
    XCTAssertEqual(model.draft, [first, second])
    XCTAssertTrue(model.canCreateFromDraft)
    XCTAssertFalse(model.canQueueOperations)
    model.removeFromDraft([first])
    XCTAssertEqual(model.draft, [second])
    model.draftSelection = [second]
    model.deleteSelected()
    XCTAssertEqual(model.draft, [])
    XCTAssertFalse(model.canCreateFromDraft)
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    model.discardDraft()
    XCTAssertNil(model.draft)
  }

  /// «Новый архив» закрывает открытый архив и показывает пустой черновик.
  @MainActor
  func testNewArchiveClosesOpenArchive() async throws {
    let source = try file("note.txt")
    let archive = try await service.createArchive(
      from: [source], proposedURL: root.appendingPathComponent("old.zip"), format: "zip")
    let model = ArchiveBrowserModel(service: service)
    model.open(archive)
    while model.isBusy { await Task.yield() }
    XCTAssertNotNil(model.session)
    model.newArchive()
    while model.isBusy { await Task.yield() }
    XCTAssertNil(model.session)
    XCTAssertEqual(model.draft, [])
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
    XCTAssertNil(model.draft)
  }

  /// Созданный архив сразу открывается в окне, а черновик исчезает.
  @MainActor
  func testCreatingDraftOpensNewArchive() async throws {
    let folder = root.appendingPathComponent("Folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try Data("inner".utf8).write(to: folder.appendingPathComponent("inner.txt"))
    let loose = try file("loose.txt")
    let destination = root.appendingPathComponent("Result.7z")
    let model = ArchiveBrowserModel(service: service)
    var offered: [URL] = []
    model.chooseCreation = { items in
      offered = items
      return ArchiveCreationChoice(
        destination: destination, options: CompressionOptions(format: "7z"), password: "")
    }
    model.receiveDroppedFiles([folder, loose])
    model.createArchiveFromDraft()
    while model.draft != nil || model.isBusy || model.session == nil {
      if model.errorMessage != nil { break }
      await Task.yield()
    }
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(offered, [folder.standardizedFileURL, loose.standardizedFileURL])
    XCTAssertNil(model.draft)
    XCTAssertEqual(model.session?.url.standardizedFileURL, destination.standardizedFileURL)
    XCTAssertEqual(
      Set(model.session?.entries.map(\.path) ?? []),
      ["Folder", "Folder/inner.txt", "loose.txt"])
    XCTAssertTrue(model.canQueueModifications)
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }

  /// Отказ в окне создания оставляет черновик как был.
  @MainActor
  func testCancelledCreationKeepsDraft() async throws {
    let loose = try file("loose.txt")
    let model = ArchiveBrowserModel(service: service)
    model.chooseCreation = { _ in nil }
    model.receiveDroppedFiles([loose])
    model.createArchiveFromDraft()
    while model.isCreationDialogPresented { await Task.yield() }
    XCTAssertEqual(model.draft, [loose.standardizedFileURL])
    XCTAssertNil(model.session)
    XCTAssertTrue(model.canCreateFromDraft)
  }

  /// Открытие другого архива не стирает собранный черновик без согласия пользователя.
  @MainActor
  func testOpeningArchiveAsksBeforeDiscardingDraft() async throws {
    let source = try file("note.txt")
    let archive = try await service.createArchive(
      from: [source], proposedURL: root.appendingPathComponent("other.zip"), format: "zip")
    let loose = try file("loose.txt")
    let model = ArchiveBrowserModel(service: service)
    var asked: [Int] = []
    var answer = false
    model.confirmDiscardingDraft = { count in
      asked.append(count)
      return answer
    }
    model.receiveDroppedFiles([loose])
    model.open(archive)
    while model.isBusy { await Task.yield() }
    XCTAssertEqual(asked, [1])
    XCTAssertEqual(model.draft, [loose.standardizedFileURL])
    XCTAssertNil(model.session)
    answer = true
    model.open(archive)
    while model.isBusy { await Task.yield() }
    XCTAssertEqual(asked, [1, 1])
    XCTAssertNil(model.draft)
    XCTAssertNotNil(model.session)
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }
}
