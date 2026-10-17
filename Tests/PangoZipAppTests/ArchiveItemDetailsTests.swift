import AppKit
import PangoZipCore
import XCTest

@testable import PangoZipApp

final class ArchiveItemDetailsTests: XCTestCase, @unchecked Sendable {
  @MainActor
  func testTableUsesVisitedFolderSizesAndClearsThemForNewSessions() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("docs/nested"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("other"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 0, count: 10).write(to: root.appendingPathComponent("docs/a.txt"))
    try Data(repeating: 0, count: 25).write(to: root.appendingPathComponent("docs/nested/b.txt"))
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [root.appendingPathComponent("docs"), root.appendingPathComponent("other")],
      proposedURL: root.appendingPathComponent("sample.zip"), format: "zip")
    let model = ArchiveBrowserModel(service: service)
    model.open(archive)
    let deadline = Date().addingTimeInterval(5)
    while model.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNotNil(model.session)
    let view = ArchiveOutlineView(model: model)
    let coordinator = view.makeCoordinator()
    let outline = RecordingOutlineView()
    let sizeColumn = NSTableColumn(identifier: .init("size"))
    outline.addTableColumn(sizeColumn)
    outline.dataSource = coordinator
    outline.delegate = coordinator
    coordinator.outline = outline
    coordinator.update(view)
    XCTAssertEqual(outline.numberOfRows, 2)
    let folder = coordinator.outlineView(outline, child: 0, ofItem: nil)
    func sizeCell() throws -> String {
      let cell = try XCTUnwrap(
        coordinator.outlineView(outline, viewFor: sizeColumn, item: folder) as? NSTableCellView)
      return try XCTUnwrap(cell.textField).stringValue
    }
    XCTAssertEqual(try sizeCell(), "—")
    XCTAssertTrue(model.itemDetailsByPath.isEmpty)
    model.selectedPaths = ["docs"]
    XCTAssertEqual(model.selectedItemDetails?.size, 35)
    XCTAssertEqual(model.selectedItemDetails?.fileCount, 2)
    XCTAssertEqual(model.itemDetailsByPath.count, 1)
    coordinator.update(view)
    XCTAssertEqual(outline.reloadedRows, IndexSet(integer: 0))
    XCTAssertEqual(
      try sizeCell(), ByteCountFormatter.string(fromByteCount: 35, countStyle: .file))
    model.searchText = "docs"
    XCTAssertEqual(model.selectedItemDetails?.size, 35)
    model.selectedPaths = ["docs/nested"]
    XCTAssertEqual(model.selectedItemDetails?.size, 25)
    model.selectedPaths = ["docs"]
    XCTAssertEqual(model.itemDetailsByPath.count, 2)
    XCTAssertEqual(model.selectedItemDetails?.size, 35)
    let oldSessionID = model.session?.id
    model.open(archive)
    let reopenDeadline = Date().addingTimeInterval(5)
    while model.isBusy && Date() < reopenDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNotNil(model.session)
    XCTAssertNotEqual(model.session?.id, oldSessionID)
    XCTAssertTrue(model.itemDetailsByPath.isEmpty)
    XCTAssertNil(model.selectedItemDetails)
    model.selectedPaths = ["docs"]
    XCTAssertEqual(model.selectedItemDetails?.size, 35)
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
    XCTAssertTrue(model.itemDetailsByPath.isEmpty)
  }

  func testFolderIncludesAllDescendantsButNotSimilarlyNamedSibling() throws {
    let roots = try ArchiveListing.tree(from: [
      ArchiveEntry(path: "docs", size: 999, isDirectory: true),
      ArchiveEntry(path: "docs/a.txt", size: 10),
      ArchiveEntry(path: "docs/nested/b.txt", size: 25),
      ArchiveEntry(path: "docs/empty", isDirectory: true),
      ArchiveEntry(path: "docs-other/c.txt", size: 100),
    ])
    let details = try XCTUnwrap(ArchiveItemDetails(path: "docs", roots: roots))
    XCTAssertEqual(details.size, 35)
    XCTAssertEqual(details.fileCount, 2)
    XCTAssertEqual(details.folderCount, 2)
  }

  func testImplicitNestedFolderHasDetailsWithoutInventedDates() throws {
    let roots = try ArchiveListing.tree(from: [ArchiveEntry(path: "a/b/file", size: 42)])
    let details = try XCTUnwrap(ArchiveItemDetails(path: "a/b", roots: roots))
    XCTAssertTrue(details.entry.isDirectory)
    XCTAssertNil(details.entry.modifiedAt)
    XCTAssertEqual(details.size, 42)
    XCTAssertEqual(details.fileCount, 1)
    XCTAssertEqual(details.folderCount, 0)
  }

  func testFilePreservesArchiveMetadata() throws {
    let entry = ArchiveEntry(
      path: "folder/file", size: 123, permissions: "-rw-r--r--", owner: "alice", group: "staff",
      isEncrypted: true, checksum: "ABC12345", method: "LZMA2")
    let details = try XCTUnwrap(
      ArchiveItemDetails(path: entry.path, roots: ArchiveListing.tree(from: [entry])))
    XCTAssertEqual(details.entry, entry)
    XCTAssertEqual(details.size, 123)
    XCTAssertEqual(details.fileCount, 0)
    XCTAssertEqual(details.folderCount, 0)
  }

  func testEmptyFolderAndMissingSelection() throws {
    let roots = try ArchiveListing.tree(from: [ArchiveEntry(path: "empty", isDirectory: true)])
    let details = try XCTUnwrap(ArchiveItemDetails(path: "empty", roots: roots))
    XCTAssertEqual(details.size, 0)
    XCTAssertEqual(details.fileCount, 0)
    XCTAssertEqual(details.folderCount, 0)
    XCTAssertNil(ArchiveItemDetails(path: "missing", roots: roots))
  }

  func testOverflowDoesNotWrapOrLoseCounts() throws {
    let roots = try ArchiveListing.tree(from: [
      ArchiveEntry(path: "large/a", size: .max), ArchiveEntry(path: "large/b", size: 1),
    ])
    let details = try XCTUnwrap(ArchiveItemDetails(path: "large", roots: roots))
    XCTAssertNil(details.size)
    XCTAssertEqual(details.fileCount, 2)
  }
}

@MainActor
private final class RecordingOutlineView: NSOutlineView {
  var reloadedRows: IndexSet?

  override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
    reloadedRows = rowIndexes
    super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
  }
}
