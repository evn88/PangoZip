import AppKit
import PangoZipCore
import XCTest

@testable import PangoZipApp

final class ArchiveItemDetailsTests: XCTestCase, @unchecked Sendable {
  @MainActor
  func testTableCalculatesAllFolderSizesWithoutSelectionAndClearsThemForNewSessions() async throws {
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
    let detailsDeadline = Date().addingTimeInterval(2)
    while model.itemDetailsByPath.isEmpty && Date() < detailsDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.itemDetailsByPath["docs"]?.size, 35)
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
    XCTAssertEqual(
      try sizeCell(), ByteCountFormatter.string(fromByteCount: 35, countStyle: .file))
    XCTAssertEqual(model.itemDetailsByPath["other"]?.size, 0)
    model.selectedPaths = ["docs"]
    XCTAssertEqual(model.selectedItemDetails?.size, 35)
    XCTAssertEqual(model.selectedItemDetails?.fileCount, 2)
    XCTAssertEqual(model.itemDetailsByPath.count, 3)
    coordinator.update(view)
    XCTAssertEqual(outline.reloadedRows, IndexSet(integersIn: 0..<2))
    XCTAssertEqual(
      try sizeCell(), ByteCountFormatter.string(fromByteCount: 35, countStyle: .file))
    model.searchText = "docs"
    XCTAssertEqual(model.selectedItemDetails?.size, 35)
    model.selectedPaths = ["docs/nested"]
    XCTAssertEqual(model.selectedItemDetails?.size, 25)
    model.selectedPaths = ["docs"]
    XCTAssertEqual(model.itemDetailsByPath.count, 3)
    XCTAssertEqual(model.selectedItemDetails?.size, 35)
    let oldSessionID = model.session?.id
    model.open(archive)
    let reopenDeadline = Date().addingTimeInterval(5)
    while model.isBusy && Date() < reopenDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNotNil(model.session)
    XCTAssertNotEqual(model.session?.id, oldSessionID)
    let calculationDeadline = Date().addingTimeInterval(5)
    while model.areFolderDetailsLoading && Date() < calculationDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.itemDetailsByPath.count, 3)
    XCTAssertNil(model.selectedItemDetails)
    model.selectedPaths = ["docs"]
    XCTAssertEqual(model.selectedItemDetails?.size, 35)
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
    XCTAssertTrue(model.itemDetailsByPath.isEmpty)
  }

  @MainActor
  func testNativeCompressionCellsShowSavedPercentAndUnknownValues() async throws {
    let entries = [
      ArchiveEntry(path: "known", size: 1000, packedSize: 250),
      ArchiveEntry(path: "growth", size: 1000, packedSize: 1250),
      ArchiveEntry(path: "empty", size: 0, packedSize: 0),
      ArchiveEntry(path: "solid", size: 1000),
      ArchiveEntry(path: "folder/file", size: 1000, packedSize: 250),
    ]
    let model = ArchiveBrowserModel()
    await model.apply(
      ArchiveSession(
        url: URL(fileURLWithPath: "/tmp/cells.zip"), entries: entries,
        roots: try ArchiveListing.tree(from: entries)))
    let deadline = Date().addingTimeInterval(5)
    while model.areFolderDetailsLoading && Date() < deadline { await Task.yield() }
    let view = ArchiveOutlineView(model: model)
    let coordinator = view.makeCoordinator()
    let outline = NSOutlineView()
    let column = NSTableColumn(identifier: .init("compression"))
    outline.addTableColumn(column)
    outline.dataSource = coordinator
    outline.delegate = coordinator
    coordinator.outline = outline
    coordinator.update(view)
    func value(_ path: String) throws -> String {
      let index = try XCTUnwrap(model.visibleRoots.firstIndex { $0.path == path })
      let item = coordinator.outlineView(outline, child: index, ofItem: nil)
      let cell = try XCTUnwrap(
        coordinator.outlineView(outline, viewFor: column, item: item) as? NSTableCellView)
      return try XCTUnwrap(cell.textField).stringValue
    }
    XCTAssertEqual(try value("known"), 0.75.formatted(.percent.precision(.fractionLength(0...1))))
    XCTAssertEqual(try value("folder"), try value("known"))
    XCTAssertEqual(
      try value("growth"), (-0.25).formatted(.percent.precision(.fractionLength(0...1))))
    XCTAssertEqual(try value("empty"), "—")
    XCTAssertEqual(try value("solid"), "—")
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }

  func testCompressionSavingsIncludesGrowthAndRejectsUnknownOrEmptySizes() throws {
    XCTAssertEqual(
      try XCTUnwrap(
        ArchiveItemDetails(entry: ArchiveEntry(path: "a", size: 1000, packedSize: 250))
          .compressionSavings), 75, accuracy: 0.0001)
    XCTAssertEqual(
      try XCTUnwrap(
        ArchiveItemDetails(entry: ArchiveEntry(path: "a", size: 1000, packedSize: 1250))
          .compressionSavings), -25, accuracy: 0.0001)
    XCTAssertNil(
      ArchiveItemDetails(entry: ArchiveEntry(path: "empty", packedSize: 0))
        .compressionSavings)
    XCTAssertNil(
      ArchiveItemDetails(entry: ArchiveEntry(path: "solid", size: 1000))
        .compressionSavings)
  }

  func testNestedFolderPackedTotalsRequireEveryFileAndDoNotWrap() throws {
    let roots = try ArchiveListing.tree(from: [
      ArchiveEntry(path: "known/a", size: 1000, packedSize: 250),
      ArchiveEntry(path: "known/nested/b", size: 1000, packedSize: 250),
      ArchiveEntry(path: "unknown/a", size: 1000, packedSize: 250),
      ArchiveEntry(path: "unknown/b", size: 1000),
      ArchiveEntry(path: "overflow/a", size: 1, packedSize: .max),
      ArchiveEntry(path: "overflow/b", size: 1, packedSize: 1),
    ])
    let details = try ArchiveItemDetails.folders(in: roots)
    XCTAssertEqual(details["known"]?.size, 2000)
    XCTAssertEqual(details["known"]?.packedSize, 500)
    XCTAssertEqual(try XCTUnwrap(details["known"]?.compressionSavings), 75, accuracy: 0.0001)
    XCTAssertNil(details["unknown"]?.packedSize)
    XCTAssertNil(details["unknown"]?.compressionSavings)
    XCTAssertNil(details["overflow"]?.packedSize)
    XCTAssertNil(details["overflow"]?.compressionSavings)
  }

  func testCancelledAggregationStopsEvenForEmptyTree() async throws {
    let calculation = Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      return try ArchiveItemDetails.folders(in: [])
    }
    do {
      _ = try await calculation.value
      XCTFail("Отменённый расчёт не должен публиковать результат")
    } catch is CancellationError {
    }
  }

  @MainActor
  func testSameSessionIDRefreshDiscardsPendingResultsAndCloseAwaitsCalculation() async throws {
    let model = ArchiveBrowserModel()
    let id = UUID()
    let largeEntries = (0..<100_000).map {
      ArchiveEntry(path: "folder/nested/file\($0)", size: 4096, packedSize: 1024)
    }
    let large = ArchiveSession(
      id: id, url: URL(fileURLWithPath: "/tmp/synthetic.zip"), entries: largeEntries,
      roots: try ArchiveListing.tree(from: largeEntries))
    await model.apply(large)
    XCTAssertTrue(model.areFolderDetailsLoading)
    model.selectedPaths = ["folder"]
    XCTAssertNil(model.selectedItemDetails)
    let entries = [ArchiveEntry(path: "folder/new", size: 80, packedSize: 20)]
    let refreshed = ArchiveSession(
      id: id, url: large.url, entries: entries, roots: try ArchiveListing.tree(from: entries))
    await model.apply(refreshed)
    let deadline = Date().addingTimeInterval(5)
    while model.areFolderDetailsLoading && Date() < deadline { await Task.yield() }
    XCTAssertFalse(model.areFolderDetailsLoading)
    XCTAssertEqual(model.itemDetailsByPath["folder"]?.size, 80)
    XCTAssertNil(model.itemDetailsByPath["folder/nested"])
    model.searchText = "new"
    XCTAssertEqual(model.selectedItemDetails?.size, 80)
    await model.apply(large)
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
    XCTAssertFalse(model.areFolderDetailsLoading)
    XCTAssertTrue(model.itemDetailsByPath.isEmpty)
    XCTAssertNil(model.session)
  }

  func testFolderIncludesAllDescendantsButNotSimilarlyNamedSibling() throws {
    let roots = try ArchiveListing.tree(from: [
      ArchiveEntry(path: "docs", size: 999, isDirectory: true),
      ArchiveEntry(path: "docs/a.txt", size: 10),
      ArchiveEntry(path: "docs/nested/b.txt", size: 25),
      ArchiveEntry(path: "docs/empty", isDirectory: true),
      ArchiveEntry(path: "docs-other/c.txt", size: 100),
    ])
    let details = try XCTUnwrap(ArchiveItemDetails.folders(in: roots)["docs"])
    XCTAssertEqual(details.size, 35)
    XCTAssertEqual(details.fileCount, 2)
    XCTAssertEqual(details.folderCount, 2)
  }

  func testImplicitNestedFolderHasDetailsWithoutInventedDates() throws {
    let roots = try ArchiveListing.tree(from: [ArchiveEntry(path: "a/b/file", size: 42)])
    let details = try XCTUnwrap(ArchiveItemDetails.folders(in: roots)["a/b"])
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
    let details = ArchiveItemDetails(entry: entry)
    XCTAssertEqual(details.entry, entry)
    XCTAssertEqual(details.size, 123)
    XCTAssertEqual(details.fileCount, 0)
    XCTAssertEqual(details.folderCount, 0)
  }

  func testEmptyFolderAndMissingSelection() throws {
    let roots = try ArchiveListing.tree(from: [ArchiveEntry(path: "empty", isDirectory: true)])
    let details = try XCTUnwrap(ArchiveItemDetails.folders(in: roots)["empty"])
    XCTAssertEqual(details.size, 0)
    XCTAssertEqual(details.fileCount, 0)
    XCTAssertEqual(details.folderCount, 0)
    XCTAssertNil(try ArchiveItemDetails.folders(in: roots)["missing"])
  }

  func testOverflowDoesNotWrapOrLoseCounts() throws {
    let roots = try ArchiveListing.tree(from: [
      ArchiveEntry(path: "large/a", size: .max), ArchiveEntry(path: "large/b", size: 1),
    ])
    let details = try XCTUnwrap(ArchiveItemDetails.folders(in: roots)["large"])
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
