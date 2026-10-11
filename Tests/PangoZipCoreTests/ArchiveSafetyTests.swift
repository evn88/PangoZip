import XCTest

@testable import PangoZipCore

final class ArchiveSafetyTests: XCTestCase {
  /// Проверяет отказ для путей, которые могут вывести распаковку за безопасный каталог.
  func testRejectsTraversalAbsolutePathsAndAmbiguousNames() {
    for path in [
      "../escape", "/tmp/escape", "C:/escape", "safe/../escape", "a\\b", "a//b", "./file",
    ] {
      XCTAssertThrowsError(
        try ArchiveListing.parse("Path = \(path)\nFolder = -\nSize = 1\n\n"), path)
    }
    XCTAssertThrowsError(
      try ArchiveListing.parse("Path = file\nSize = 1\n\nPath = file\nSize = 2\n\n"))
    XCTAssertThrowsError(try ArchiveListing.parse("Path = file\nSize = -1\n\n"))
    XCTAssertThrowsError(try ArchiveListing.parse("Path = line\nbreak.txt\nSize = 1\n\n"))
  }

  /// Проверяет, что пустые поля ссылки не превращают обычный TAR-файл в ссылку.
  func testTarRegularFileWithEmptyLinkMetadataIsPreviewable() throws {
    let entries = try ArchiveListing.parse(
      "Path = readme.txt\nFolder = -\nSize = 5\nMode = -rw-r--r--\nSymbolic Link = \nHard Link = \n\n"
    )
    XCTAssertFalse(try XCTUnwrap(entries.first).isSymbolicLink)
  }

  /// Проверяет распознавание символических ссылок без перехода по ним.
  func testRecognizesSymbolicLinksWithoutFollowingThem() throws {
    let entries = try ArchiveListing.parse(
      "Path = link\nSize = 6\nAttributes = A lrwxrwxrwx\nSymbolic Link = target\n\n")
    XCTAssertTrue(entries.first?.isSymbolicLink == true)
  }
}
