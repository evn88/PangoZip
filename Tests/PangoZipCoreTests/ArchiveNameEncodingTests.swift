import Foundation
import XCTest

@testable import PangoZipCore

final class ArchiveNameEncodingTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  private func cfEncoding(_ value: CFStringEncodings) -> String.Encoding {
    String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
  }

  private func append(_ value: UInt16, to data: inout Data) {
    data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
  }

  private func append(_ value: UInt32, to data: inout Data) {
    append(UInt16(value & 0xFFFF), to: &data)
    append(UInt16(value >> 16), to: &data)
  }

  private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
    }
    return ~crc
  }

  /// Собирает ZIP без сжатия с именами в заданной кодировке и без признака UTF-8, как в Windows.
  private func makeZip(_ name: String, files: [(name: Data, body: String)]) throws -> URL {
    var archive = Data()
    var directory = Data()
    for file in files {
      let body = Data(file.body.utf8)
      let offset = UInt32(archive.count)
      var fields = Data()
      for value: UInt16 in [20, 0, 0, 0, 0x21] { append(value, to: &fields) }
      append(crc32(body), to: &fields)
      append(UInt32(body.count), to: &fields)
      append(UInt32(body.count), to: &fields)
      append(UInt16(file.name.count), to: &fields)
      append(UInt16(0), to: &fields)
      append(UInt32(0x0403_4B50), to: &archive)
      archive += fields + file.name + body
      append(UInt32(0x0201_4B50), to: &directory)
      append(UInt16(20), to: &directory)
      directory += fields
      for _ in 0..<3 { append(UInt16(0), to: &directory) }
      append(UInt32(0), to: &directory)
      append(offset, to: &directory)
      directory += file.name
    }
    let directoryOffset = UInt32(archive.count)
    archive += directory
    append(UInt32(0x0605_4B50), to: &archive)
    for value: UInt16 in [0, 0, UInt16(files.count), UInt16(files.count)] {
      append(value, to: &archive)
    }
    append(UInt32(directory.count), to: &archive)
    append(directoryOffset, to: &archive)
    append(UInt16(0), to: &archive)
    let url = root.appendingPathComponent(name)
    try archive.write(to: url)
    return url
  }

  func testDetectsDosAndWindowsCyrillic() throws {
    let names = ["Отчёт за год.txt", "Папка/Документ.txt"]
    let dos = try names.map { try XCTUnwrap($0.data(using: cfEncoding(.dosRussian))) }
    let windows = try names.map { try XCTUnwrap($0.data(using: .windowsCP1251)) }

    XCTAssertEqual(ArchiveNameEncoding.detect(dos, preferredLanguages: ["en"])?.codePage, 866)
    XCTAssertEqual(ArchiveNameEncoding.detect(windows, preferredLanguages: ["en"])?.codePage, 1251)
  }

  func testDetectsJapaneseAndWesternNames() throws {
    let japanese = [try XCTUnwrap("日本語のファイル.txt".data(using: .shiftJIS))]
    let german = [try XCTUnwrap("Übersicht für März.txt".data(using: .windowsCP1252))]

    XCTAssertEqual(ArchiveNameEncoding.detect(japanese, preferredLanguages: ["ja"])?.codePage, 932)
    XCTAssertEqual(ArchiveNameEncoding.detect(german, preferredLanguages: ["de"])?.codePage, 1252)
  }

  func testUtf8NamesWithoutFlagNeedNoRepair() throws {
    let url = try makeZip("utf8.zip", files: [(Data("Привет.txt".utf8), "x")])
    XCTAssertNil(ZipNameRepair.legacyNames(in: url))
    XCTAssertNil(ZipNameRepair.legacyNames(in: root.appendingPathComponent("missing.zip")))
  }

  func testRewriteProducesArchiveTheEngineReadsWithOriginalNames() async throws {
    let dos = cfEncoding(.dosRussian)
    let url = try makeZip(
      "dos.zip",
      files: [
        (try XCTUnwrap("Отчёт за год.txt".data(using: dos)), "первый"),
        (Data("plain.txt".utf8), "второй"),
        (try XCTUnwrap("Папка/Документ.txt".data(using: dos)), "третий"),
      ])
    let names = try XCTUnwrap(ZipNameRepair.legacyNames(in: url))
    XCTAssertEqual(names.count, 2)
    let encoding = try XCTUnwrap(ArchiveNameEncoding.detect(names))
    let repaired = root.appendingPathComponent("repaired.zip")
    try ZipNameRepair.rewrite(url, to: repaired, using: encoding)

    // Исправленная копия проходит проверку целостности и чтение движком.
    let service = ArchiveService()
    try await service.testArchive(repaired)
    let session = try await service.open(repaired)
    XCTAssertEqual(
      Set(session.entries.filter { !$0.isDirectory }.map(\.path)),
      ["Отчёт за год.txt", "plain.txt", "Папка/Документ.txt"])
    let entry = try XCTUnwrap(session.entries.first { $0.path == "Папка/Документ.txt" })
    let file = try await service.materialize(entry, in: session)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "третий")
    await service.cleanup()
  }

  func testNamesAlreadyInUtf8AreNotReencodedNextToLegacyOnes() async throws {
    let url = try makeZip(
      "mixed.zip",
      files: [
        (try XCTUnwrap("Отчёт.txt".data(using: cfEncoding(.dosRussian))), "старое"),
        (Data("Заметки.txt".utf8), "новое"),
      ])
    XCTAssertEqual(ZipNameRepair.legacyNames(in: url)?.count, 1)
    let service = ArchiveService()

    let session = try await service.open(url)

    XCTAssertEqual(session.nameEncoding?.codePage, 866)
    XCTAssertEqual(Set(session.entries.map(\.path)), ["Отчёт.txt", "Заметки.txt"])
    let entry = try XCTUnwrap(session.entries.first { $0.path == "Заметки.txt" })
    let file = try await service.materialize(entry, in: session)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "новое")
    await service.cleanup()
  }

  func testOpeningLegacyArchiveRepairsNamesAndKeepsOriginalUntouched() async throws {
    let url = try makeZip(
      "legacy.zip",
      files: [(try XCTUnwrap("Привет мир.txt".data(using: .windowsCP1251)), "содержимое")])
    let original = try Data(contentsOf: url)
    let service = ArchiveService()

    let session = try await service.open(url)
    XCTAssertEqual(session.entries.map(\.path), ["Привет мир.txt"])
    XCTAssertEqual(session.nameEncoding?.codePage, 1251)
    XCTAssertFalse(session.canModify)
    XCTAssertEqual(session.url, url)

    // Ручной выбор другой кодировки меняет прочтение имён, но не сам архив.
    let forced = try await service.open(url, nameEncoding: ArchiveNameEncoding.named(866))
    XCTAssertNotEqual(forced.entries.map(\.path), ["Привет мир.txt"])
    XCTAssertEqual(forced.nameEncoding?.codePage, 866)

    let extracted = try await service.extractArchive(url)
    XCTAssertEqual(
      try String(
        contentsOf: extracted.appendingPathComponent("Привет мир.txt"), encoding: .utf8),
      "содержимое")
    XCTAssertEqual(try Data(contentsOf: url), original)
    await service.cleanup()
  }
}
