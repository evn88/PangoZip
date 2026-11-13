import CryptoKit
import XCTest

@testable import PangoZipCore

final class ArchiveChecksumsTests: XCTestCase, @unchecked Sendable {
  private static let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  private static let emptySHA256 =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  private var engine: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Resources/Engine/7zz")
  }

  /// Известные тестовые векторы CRC32 и SHA-256 для файла на диске.
  func testFileChecksumsMatchKnownVectors() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let abc = directory.appendingPathComponent("abc.txt")
    try Data("abc".utf8).write(to: abc)
    let record = try await ArchiveChecksums.compute(fileAt: abc)
    XCTAssertEqual(record.crc32, "352441C2")
    XCTAssertEqual(record.sha256, Self.abcSHA256)
    XCTAssertEqual(record.size, 3)
    let digits = directory.appendingPathComponent("digits.txt")
    try Data("123456789".utf8).write(to: digits)
    let digitsRecord = try await ArchiveChecksums.compute(fileAt: digits)
    XCTAssertEqual(digitsRecord.crc32, "CBF43926")
    let empty = directory.appendingPathComponent("empty")
    try Data().write(to: empty)
    let emptyRecord = try await ArchiveChecksums.compute(fileAt: empty)
    XCTAssertEqual(emptyRecord.crc32, "00000000")
    XCTAssertEqual(emptyRecord.sha256, Self.emptySHA256)
  }

  /// Файл больше нескольких блоков хешируется потоком с тем же результатом, что и целиком.
  func testStreamingMatchesOneShotForMultiChunkFile() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var data = Data()
    for index in 0..<(2_700_000 / 9) { data.append(Data("\(index % 10)87654321".utf8)) }
    let file = directory.appendingPathComponent("big.bin")
    try data.write(to: file)
    let record = try await ArchiveChecksums.compute(fileAt: file)
    XCTAssertEqual(
      record.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    var whole = ChecksumAccumulator()
    whole.update(data)
    XCTAssertEqual(record.crc32, whole.finish().crc32)
    XCTAssertEqual(record.size, UInt64(data.count))
    let progressCalls = ProgressCounter()
    _ = try await ArchiveChecksums.compute(
      fileAt: file, progress: { _, _ in await progressCalls.increment() })
    let calls = await progressCalls.value
    XCTAssertGreaterThanOrEqual(calls, 1)
  }

  /// Отмена прерывает хеширование и не возвращает частичный результат.
  func testCancellationStopsHashing() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("big.bin")
    try Data(count: 20 * 1024 * 1024).write(to: file)
    let task = Task { try await ArchiveChecksums.compute(fileAt: file) }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }

  /// Каталоги и отсутствующие файлы не хешируются.
  func testRejectsDirectoryAndMissingFile() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for url in [directory, directory.appendingPathComponent("missing")] {
      do {
        _ = try await ArchiveChecksums.compute(fileAt: url)
        XCTFail("Expected failure")
      } catch {}
    }
  }

  /// Суммы элементов архива совпадают с суммами исходных файлов; папка раскрывается в файлы.
  func testEntryChecksumsInZipAndSelectedFolderExpands() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("abc".utf8).write(to: directory.appendingPathComponent("abc.txt"))
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try Data("123456789".utf8).write(to: directory.appendingPathComponent("docs/digits.txt"))
    try Data().write(to: directory.appendingPathComponent("docs/empty.txt"))
    let archive = directory.appendingPathComponent("sample.zip")
    try runEngine(["a", "-tzip", archive.path, "abc.txt", "docs"], in: directory)
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    let single = try await service.checksums(of: ["abc.txt"], in: session)
    XCTAssertEqual(single.count, 1)
    XCTAssertEqual(single[0].name, "abc.txt")
    XCTAssertEqual(single[0].crc32, "352441C2")
    XCTAssertEqual(single[0].sha256, Self.abcSHA256)
    let folder = try await service.checksums(of: ["docs"], in: session)
    XCTAssertEqual(folder.map(\.name), ["docs/digits.txt", "docs/empty.txt"])
    XCTAssertEqual(folder[0].crc32, "CBF43926")
    XCTAssertEqual(folder[1].sha256, Self.emptySHA256)
    // Временные файлы суммы удаляются, архив остаётся неизменным.
    _ = try await service.open(archive)
    await service.cleanup()
  }

  /// Для защищённого паролем 7z нужен пароль; с ним суммы совпадают с известными значениями.
  func testEntryChecksumsRequirePasswordForEncryptedArchive() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("abc".utf8).write(to: directory.appendingPathComponent("abc.txt"))
    let archive = directory.appendingPathComponent("secret.7z")
    try runEngine(["a", "-psecret", "-mhe=on", archive.path, "abc.txt"], in: directory)
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive, password: "secret")
    do {
      _ = try await service.checksums(of: ["abc.txt"], in: session, password: "wrong")
      XCTFail("Expected password failure")
    } catch {
      XCTAssertEqual(error as? ArchiveError, .passwordRequired)
    }
    let records = try await service.checksums(of: ["abc.txt"], in: session, password: "secret")
    XCTAssertEqual(records.first?.sha256, Self.abcSHA256)
    XCTAssertEqual(records.first?.crc32, "352441C2")
    // После ошибки сеанс не остаётся занятым.
    let again = try await service.checksums(of: ["abc.txt"], in: session, password: "secret")
    XCTAssertEqual(again, records)
    await service.cleanup()
  }

  /// Суммы самого файла архива считаются тем же потоковым хешированием.
  func testArchiveFileChecksumMatchesCryptoKit() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("abc".utf8).write(to: directory.appendingPathComponent("abc.txt"))
    let archive = directory.appendingPathComponent("sample.7z")
    try runEngine(["a", archive.path, "abc.txt"], in: directory)
    let record = try await ArchiveChecksums.compute(fileAt: archive)
    let bytes = try Data(contentsOf: archive)
    XCTAssertEqual(
      record.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
  }

  /// Проверка архива сообщает прогресс и завершается на 100%; повреждённый архив отклоняется.
  func testArchiveTestReportsProgressAndDetectsCorruption() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(repeating: 65, count: 400_000).write(to: directory.appendingPathComponent("a.bin"))
    let archive = directory.appendingPathComponent("sample.7z")
    try runEngine(["a", "-mx=0", archive.path, "a.bin"], in: directory)
    let service = ArchiveService(executableURL: engine)
    let collector = ProgressCollector()
    try await service.testArchive(archive, progress: { await collector.add($0) })
    let values = await collector.values
    XCTAssertEqual(values.first?.phase, .preparing)
    XCTAssertEqual(values.last?.phase, .finalizing)
    XCTAssertEqual(values.last?.fraction, 1)
    var bytes = try Data(contentsOf: archive)
    bytes[100] ^= 0xFF
    let broken = directory.appendingPathComponent("broken.7z")
    try bytes.write(to: broken)
    do {
      try await service.testArchive(broken)
      XCTFail("Expected corruption failure")
    } catch {
      XCTAssertEqual(error as? ArchiveError, .invalidArchive)
    }
    await service.cleanup()
  }

  /// Сравнение игнорирует регистр и любые пробелы, пустой ввод не считается совпадением.
  func testComparisonIgnoresCaseAndWhitespace() {
    XCTAssertTrue(
      ChecksumComparison.matches(
        " BA7816BF 8F01CFEA\n414140DE 5DAE2223 B00361A3 96177A9C B410FF61 F20015AD ",
        Self.abcSHA256))
    XCTAssertTrue(ChecksumComparison.matches("352441c2", "352441C2"))
    XCTAssertTrue(ChecksumComparison.matches("\t352441C2 ", "352441c2"))
    XCTAssertFalse(ChecksumComparison.matches("352441C3", "352441C2"))
    XCTAssertFalse(ChecksumComparison.matches("", ""))
    XCTAssertFalse(ChecksumComparison.matches("   ", "352441C2"))
    // Частичное значение не считается совпадением.
    XCTAssertFalse(ChecksumComparison.matches("352441", "352441C2"))
    XCTAssertEqual(
      ChecksumComparison.result(for: "  ", candidates: ["352441C2"]), .empty)
    XCTAssertEqual(
      ChecksumComparison.result(for: "352441c2", candidates: ["00000000", "352441C2"]), .match)
    XCTAssertEqual(
      ChecksumComparison.result(for: "deadbeef", candidates: ["352441C2"]), .mismatch)
  }

  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func runEngine(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = engine
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }
}

private actor ProgressCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

private actor ProgressCollector {
  private(set) var values: [ArchiveProgress] = []
  func add(_ value: ArchiveProgress) { values.append(value) }
}
