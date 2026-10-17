import PangoZipCore
import XCTest

@testable import PangoZipApp

final class ArchiveItemDetailsTests: XCTestCase {
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
