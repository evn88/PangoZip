import Darwin
import XCTest

@testable import PangoZipCore

final class ArchiveServiceTests: XCTestCase, @unchecked Sendable {
  private var engine: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Resources/Engine/7zz")
  }

  /// Проверяет извлечение одного буквального имени и повторное использование кэша.
  func testOpensRealZipAndExtractsOnlyLiteralSelectedFilename() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let archive = fixture.appendingPathComponent("sample.zip")
    try runEngine(["a", "-tzip", archive.path, "a*.txt", "abc.txt", "docs"], in: fixture)
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    XCTAssertEqual(session.entries.filter { !$0.isDirectory }.count, 3)
    XCTAssertEqual(session.roots.map(\.name), ["docs", "a*.txt", "abc.txt"])
    let selected = try XCTUnwrap(session.entries.first { $0.path == "a*.txt" })
    let file = try await service.materialize(selected, in: session)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "literal star")
    let cached = try await service.materialize(selected, in: session)
    XCTAssertEqual(file, cached)
    await service.cleanup()
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  /// Проверяет чтение заголовков 7z и запрос пароля для защищённого содержимого.
  func testReadsEncrypted7zHeadersAndRequestsPassword() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let archive = fixture.appendingPathComponent("secret.7z")
    try runEngine(["a", "-psecret", "-mhe=on", archive.path, "docs"], in: fixture)
    let service = ArchiveService(executableURL: engine)
    await expect(.passwordRequired) { _ = try await service.open(archive) }
    let session = try await service.open(archive, password: "secret")
    let entry = try XCTUnwrap(session.entries.first { !$0.isDirectory })
    let output = try await service.materialize(entry, in: session, password: "secret")
    XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "Привет")
    await service.cleanup()
  }

  /// Проверяет запрос пароля до извлечения защищённого файла.
  func testZipPasswordIsRequestedWhenOpeningEncryptedFile() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let archive = fixture.appendingPathComponent("secret.zip")
    try runEngine(["a", "-psecret", archive.path, "abc.txt"], in: fixture)
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    let entry = try XCTUnwrap(session.entries.first)
    await expect(.passwordRequired) { _ = try await service.materialize(entry, in: session) }
    let output = try await service.materialize(entry, in: session, password: "secret")
    XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "must not extract")
    await service.cleanup()
  }

  /// Проверяет, что пустой архив создаёт пустое дерево записей.
  func testEmptyZipProducesEmptyTree() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let archive = fixture.appendingPathComponent("empty.zip")
    try (Data([0x50, 0x4b, 0x05, 0x06]) + Data(repeating: 0, count: 18)).write(to: archive)
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    XCTAssertTrue(session.entries.isEmpty)
    XCTAssertTrue(session.roots.isEmpty)
    await service.cleanup()
  }

  /// Проверяет отклонение кэшированного файла после изменения исходного архива.
  func testRejectsChangedArchiveBeforeUsingCachedFile() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let archive = fixture.appendingPathComponent("sample.zip")
    try runEngine(["a", archive.path, "abc.txt"], in: fixture)
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    let entry = try XCTUnwrap(session.entries.first)
    _ = try await service.materialize(entry, in: session)
    let handle = try FileHandle(forWritingTo: archive)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0]))
    try handle.close()
    await expect(.archiveChanged) { _ = try await service.materialize(entry, in: session) }
    await service.cleanup()
  }

  /// Проверяет лимит предпросмотра и отказ закрытой сессии.
  func testRejectsOversizePreviewAndExpiredSession() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let archive = fixture.appendingPathComponent("sample.zip")
    try runEngine(["a", archive.path, "abc.txt"], in: fixture)
    let service = ArchiveService(executableURL: engine, previewLimit: 1)
    let session = try await service.open(archive)
    let entry = try XCTUnwrap(session.entries.first)
    await expect(.fileTooLarge) { _ = try await service.materialize(entry, in: session) }
    await service.cleanup()
    await expect(.sessionExpired) { _ = try await service.materialize(entry, in: session) }
  }

  /// Проверяет предпросмотр обычных TAR-файлов без извлечения ссылок.
  func testTarFilesCanBePreviewedAndLinksCannot() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    try FileManager.default.createSymbolicLink(
      atPath: fixture.appendingPathComponent("link").path, withDestinationPath: "abc.txt")
    let archive = fixture.appendingPathComponent("sample.tar")
    try runEngine(["a", "-snl", archive.path, "abc.txt", "link"], in: fixture)
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    let file = try XCTUnwrap(session.entries.first { $0.path == "abc.txt" })
    let link = try XCTUnwrap(session.entries.first { $0.path == "link" })
    XCTAssertTrue(link.isSymbolicLink)
    let output = try await service.materialize(file, in: session)
    XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "must not extract")
    await expect(.unsupportedEntry) { _ = try await service.materialize(link, in: session) }
    await service.cleanup()
  }

  /// Проверяет различимые ошибки повреждённого архива и отсутствующего движка.
  func testInvalidArchiveAndMissingEngineHaveClearErrors() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let invalid = fixture.appendingPathComponent("abc.txt")
    let service = ArchiveService(executableURL: engine)
    await expect(.invalidArchive) { _ = try await service.open(invalid) }
    await service.cleanup()
    let missing = ArchiveService(executableURL: fixture.appendingPathComponent("missing"))
    await expect(.engineUnavailable) { _ = try await missing.open(invalid) }
  }

  /// Проверяет совместимость предпросмотра с ZIP, созданным стандартной библиотекой Python.
  func testPythonStyleZipFileIsPreviewable() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let archive = fixture.appendingPathComponent("python.zip")
    let bytes = Data(
      base64Encoded:
        "UEsDBBQAAAAAAC+1Sl2GphA2BQAAAAUAAAAJAAAAaGVsbG8udHh0aGVsbG9QSwECFAMUAAAAAAAvtUpdhqYQNgUAAAAFAAAACQAAAAAAAAAAAAAAgAEAAAAAaGVsbG8udHh0UEsFBgAAAAABAAEANwAAACwAAAAAAA=="
    )!
    try bytes.write(to: archive)
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    let entry = try XCTUnwrap(session.entries.first)
    XCTAssertFalse(entry.isSymbolicLink)
    let file = try await service.materialize(entry, in: session)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
    await service.cleanup()
  }

  /// Проверяет перенос атрибута карантина с архива на файл предпросмотра.
  func testPreservesArchiveQuarantineOnPreviewFile() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let archive = fixture.appendingPathComponent("download.zip")
    try runEngine(["a", archive.path, "abc.txt"], in: fixture)
    let attribute = Data("0081;67000000;PangoZipTests;".utf8)
    let result = attribute.withUnsafeBytes {
      setxattr(archive.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
    }
    XCTAssertEqual(result, 0)
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    let file = try await service.materialize(XCTUnwrap(session.entries.first), in: session)
    var buffer = [UInt8](repeating: 0, count: 1024)
    let count = getxattr(file.path, "com.apple.quarantine", &buffer, buffer.count, 0, 0)
    XCTAssertEqual(count, attribute.count)
    if count > 0 { XCTAssertEqual(Data(buffer.prefix(count)), attribute) }
    await service.cleanup()
  }

  /// Проверяет, что операция возвращает ожидаемую ошибку архива.
  private func expect(_ expected: ArchiveError, operation: () async throws -> Void) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)")
    } catch {
      XCTAssertEqual(error as? ArchiveError, expected)
    }
  }

  /// Создаёт временные тестовые данные, не затрагивая пользовательские файлы.
  private func makeFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: url.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try Data("literal star".utf8).write(to: url.appendingPathComponent("a*.txt"))
    try Data("must not extract".utf8).write(to: url.appendingPathComponent("abc.txt"))
    try Data("Привет".utf8).write(to: url.appendingPathComponent("docs/Привет.txt"))
    return url
  }

  /// Запускает 7zz для подготовки архива и проверяет успешный выход.
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
