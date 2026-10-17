import XCTest

@testable import PangoZipCore

final class ArchiveListingTests: XCTestCase {
  func testPackedSizeIsNotInventedForMissingOrBlockBasedValues() throws {
    let entries = try ArchiveListing.parse(
      """
      Path = zip.txt
      Size = 100
      Packed Size = 45

      Path = solid-a.txt
      Size = 100
      Packed Size = 60
      Block = 0

      Path = solid-b.txt
      Size = 100
      Packed Size =
      Block = 0

      Path = empty.txt
      Size = 0
      Packed Size = 0

      Path = single-block.txt
      Size = 100
      Packed Size = 32
      Block = 1

      """.replacingOccurrences(of: "Packed Size =\n", with: "Packed Size = \n"))
    XCTAssertEqual(entries[0].packedSize, 45)
    XCTAssertNil(entries[1].packedSize)
    XCTAssertNil(entries[2].packedSize)
    XCTAssertEqual(entries[3].packedSize, 0)
    XCTAssertEqual(entries[4].packedSize, 32)
  }

  /// Проверяет разбор Unicode-имён и восстановление каталогов, отсутствующих в листинге.
  func testReadsUnicodeNamesAndImplicitFoldersFromTechnicalListing() throws {
    let entries = try ArchiveListing.parse(
      """
      Path = docs/Привет = мир.txt
      Folder = -
      Size = 26
      Attributes =  -rw-r--r--

      Path = empty
      Folder = +
      Size = 0
      Attributes = D drwxr-xr-x

      """)
    XCTAssertEqual(entries.map(\.path), ["docs/Привет = мир.txt", "empty"])
    XCTAssertEqual(entries.first?.size, 26)
    XCTAssertTrue(entries.last?.isDirectory == true)
  }
  /// Проверяет сохранение имеющихся метаданных и отсутствие выдуманных значений.
  func testArchiveMetadataIsReadWithoutInventingMissingValues() throws {
    let entry = try XCTUnwrap(
      ArchiveListing.parse(
        "Path = docs/file.txt\nSize = 5\nMode = -rw-r-----\nModified = 2026-10-10 12:30:45.1234567\nCreated = 2026-10-09 08:00:00\nUser = alice\nGroup = staff\nEncrypted = +\nCRC = 3610A686\n\n"
      ).first)
    XCTAssertEqual(entry.permissions, "-rw-r-----")
    XCTAssertEqual(entry.owner, "alice")
    XCTAssertEqual(entry.group, "staff")
    XCTAssertNotNil(entry.modifiedAt)
    XCTAssertNotNil(entry.createdAt)
    XCTAssertTrue(entry.isEncrypted)
    XCTAssertEqual(entry.checksum, "3610A686")
    let missing = try XCTUnwrap(ArchiveListing.parse("Path = no-metadata\nSize = 0\n\n").first)
    XCTAssertNil(missing.owner)
    XCTAssertNil(missing.createdAt)
    XCTAssertNil(missing.permissions)
    XCTAssertNil(missing.packedSize)
  }
}
