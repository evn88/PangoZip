import XCTest

@testable import PangoZipCore

final class FinderIntegrationTests: XCTestCase, @unchecked Sendable {
  private let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
      "Resources/Engine/7zz")

  /// Проверяет доступность команд Finder для разных типов и сочетаний выбора.
  func testMenuDistinguishesFoldersArchivesAndMixedMultipleSelection() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("folder.zip")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let zip = root.appendingPathComponent("data.zip")
    try Data().write(to: zip)
    XCTAssertEqual(FinderSelection(urls: [zip]).archiveName, "data_2")
    let plain = root.appendingPathComponent("a*.txt")
    XCTAssertEqual(
      FinderSelection(urls: [directory, plain]).actions, [.create, .create7z, .createZip])
    XCTAssertEqual(FinderSelection(urls: [plain]).title(for: .createZip), "Добавить в «a*.zip»")
    XCTAssertEqual(FinderSelection(urls: [directory]).archiveName, "folder.zip")
    let selection = FinderSelection(urls: [zip, directory, zip, plain])
    XCTAssertEqual(selection.archives, [zip])
    XCTAssertEqual(try selection.request(for: .extract).urls, [zip])
    XCTAssertEqual(
      try selection.request(for: .create).urls.map(\.path), [zip, directory, plain].map(\.path))
    XCTAssertEqual(
      selection.actions,
      [.open, .extractFiles, .extractHere, .extract, .test, .create, .create7z, .createZip])
    XCTAssertEqual(selection.title(for: .create), "Добавить в архив…")
    XCTAssertEqual(selection.title(for: .create7z), "Добавить в «\(root.lastPathComponent).7z»")
    XCTAssertEqual(selection.title(for: .extract), "Распаковать в «data/»")
    XCTAssertFalse(selection.actions.contains(.add))
    XCTAssertEqual(try selection.request(for: .test).urls, [zip])
    XCTAssertEqual(
      FinderSelection.extractionName(for: root.appendingPathComponent("Photos.tar.gz")), "Photos")
  }

  /// Проверяет обратимость кодирования запроса и отказ небезопасных данных.
  func testRequestRoundTripRejectsRemotePathsAndMalformedTokens() throws {
    let request = try FinderRequest(action: .add, urls: [URL(fileURLWithPath: "/tmp/фото #1.txt")])
    XCTAssertEqual(try FinderRequest.decode(JSONEncoder().encode(request)), request)
    XCTAssertThrowsError(try FinderRequest(action: .create, urls: []))
    XCTAssertThrowsError(
      try FinderRequest(action: .add, urls: [URL(string: "https://example.com/a")!]))
    XCTAssertThrowsError(try FinderRequest.decode(Data("{\"action\":\"add\",\"urls\":[]}".utf8)))
    XCTAssertNil(
      FinderRequest.boardName(from: URL(string: "pangozip://finder?request=../../data")!))
    XCTAssertNotNil(
      FinderRequest.boardName(from: URL(string: "pangozip://finder?request=" + UUID().uuidString)!))
  }

  /// Проверяет сохранение имён при пакетной обработке и защиту существующих результатов.
  func testCreateAndExtractMultipleFilesPreservesNamesAndNeverOverwritesExistingOutputs()
    async throws
  {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    for format in ["zip", "7z"] {
      let proposed = root.appendingPathComponent("Selection." + format)
      let urls = [root.appendingPathComponent("docs"), root.appendingPathComponent("a*.txt")]
      let archive = try await service.createArchive(
        from: urls, proposedURL: proposed, format: format,
        options: CompressionOptions(format: format, level: 0, solid: false, threads: 1))
      let session = try await service.open(archive)
      XCTAssertTrue(
        session.entries.filter { !$0.isDirectory }.allSatisfy {
          $0.method == (format == "zip" ? "Store" : "Copy")
        })
      try await service.close(session)
      let original = try Data(contentsOf: archive)
      let duplicate = try await service.createArchive(
        from: urls, proposedURL: proposed, format: format)
      XCTAssertNotEqual(duplicate, archive)
      XCTAssertEqual(try Data(contentsOf: archive), original)
      let output = try await service.extractArchive(archive)
      XCTAssertEqual(
        try String(contentsOf: output.appendingPathComponent("docs/text.txt"), encoding: .utf8),
        "document")
      XCTAssertEqual(
        try String(contentsOf: output.appendingPathComponent("a*.txt"), encoding: .utf8),
        "literal wildcard")
      let second = try await service.extractArchive(archive)
      XCTAssertNotEqual(output, second)
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: output.appendingPathComponent("docs/empty").path))
    }
    await service.cleanup()
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
        $0.hasPrefix(".zipevra-") || $0.hasPrefix(".pangozip-")
      })
  }

  /// Проверяет распаковку TAR и повтор запроса пароля для зашифрованного архива.
  func testExtractsCompressedTarAndEncryptedArchiveWithPasswordRetry() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    try run(["a", "bundle.tar", "docs"], in: root)
    try run(["a", "bundle.tar.gz", "bundle.tar"], in: root)
    let folder = try await service.extractArchive(root.appendingPathComponent("bundle.tar.gz"))
    XCTAssertEqual(folder.lastPathComponent, "bundle")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("docs/text.txt").path))
    try run(["a", "-psecret", "-mem=AES256", "secret.zip", "docs"], in: root)
    let secret = root.appendingPathComponent("secret.zip")
    do {
      _ = try await service.extractArchive(secret)
      XCTFail("Expected password")
    } catch { XCTAssertEqual(error as? ArchiveError, .passwordRequired) }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("secret").path))
    let extracted = try await service.extractArchive(secret, password: "secret")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: extracted.appendingPathComponent("docs/text.txt").path)
    )
    await service.cleanup()
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
        $0.hasPrefix(".zipevra-") || $0.hasPrefix(".pangozip-")
      })
  }

  /// Проверяет, что опасные ссылки и прерывания не оставляют частичную распаковку.
  func testExtractionLimitLinksAndCancellationLeaveNoPartialResults() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [root.appendingPathComponent("docs")],
      proposedURL: root.appendingPathComponent("limited.zip"), format: "zip")
    do {
      _ = try await service.extractArchive(archive, maximumBytes: 1)
      XCTFail("Expected limit")
    } catch { XCTAssertEqual(error as? ArchiveError, .outputLimit) }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("limited").path))
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("link").path, withDestinationPath: "/tmp")
    try run(["a", "-snl", "link.tar", "link"], in: root)
    do {
      _ = try await service.extractArchive(root.appendingPathComponent("link.tar"))
      XCTFail("Expected unsupported link")
    } catch { XCTAssertEqual(error as? ArchiveError, .unsupportedExtraction) }
    let task = Task { try await service.extractArchive(archive) }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    await service.cleanup()
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
        $0.hasPrefix(".zipevra-") || $0.hasPrefix(".pangozip-")
      })
  }

  /// Проверяет передачу движку только допустимых параметров сжатия.
  func testCompressionSettingsAreValidatedAndSentToEngine() {
    let zip = CompressionOptions(format: "zip", level: 0, solid: true, threads: 2)
    XCTAssertEqual(zip.arguments, ["-mx=0", "-mmt=2"])
    XCTAssertEqual(
      CompressionOptions(format: "7z", level: 9, solid: false).arguments,
      ["-mx=9", "-mmt=on", "-ms=off"])
    XCTAssertEqual(
      CompressionOptions(format: "bad", level: 99, threads: -1),
      CompressionOptions(format: "zip", level: 9, threads: 0))
  }

  /// Проверяет распаковку в выбранное место без лишнего каталога и перезаписи.
  func testExtractHereAndChosenFolderDoNotCreateWrapperOrOverwriteExistingFiles() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [root.appendingPathComponent("a*.txt")],
      proposedURL: root.appendingPathComponent("archive.zip"), format: "zip")
    let here = try await service.extractArchive(archive, createsSubfolder: false)
    XCTAssertEqual(here.standardizedFileURL, root.standardizedFileURL)
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("a*.txt"), encoding: .utf8),
      "literal wildcard")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("a* (2).txt").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("archive").path))
    let chosen = root.appendingPathComponent("chosen")
    try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
    _ = try await service.extractArchive(archive, directory: chosen, createsSubfolder: false)
    XCTAssertEqual(
      try String(contentsOf: chosen.appendingPathComponent("a*.txt"), encoding: .utf8),
      "literal wildcard")
    await service.cleanup()
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
        $0.hasPrefix(".zipevra-") || $0.hasPrefix(".pangozip-")
      })
  }

  /// Проверяет шифрование архива и проверку содержимого без распаковки.
  func testCreatesPasswordProtectedArchivesAndTestsThemWithoutExtracting() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    for format in ["zip", "7z"] {
      let archive = try await service.createArchive(
        from: [root.appendingPathComponent("a*.txt")],
        proposedURL: root.appendingPathComponent("protected-" + format + "." + format),
        format: format,
        password: "secret")
      let before = try Data(contentsOf: archive)
      do {
        try await service.testArchive(archive, password: "wrong")
        XCTFail("Expected password")
      } catch { XCTAssertEqual(error as? ArchiveError, .passwordRequired) }
      try await service.testArchive(archive, password: "secret")
      XCTAssertEqual(try Data(contentsOf: archive), before)
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: root.appendingPathComponent("protected-" + format).path))
      let extracted = try await service.extractArchive(archive, password: "secret")
      XCTAssertEqual(
        try String(contentsOf: extracted.appendingPathComponent("a*.txt"), encoding: .utf8),
        "literal wildcard")
    }
    await service.cleanup()
  }

  /// Готовит файлы и архивы во временном каталоге для команд Finder.
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pangozip-finder-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("docs/empty"), withIntermediateDirectories: true)
    try Data("document".utf8).write(to: root.appendingPathComponent("docs/text.txt"))
    try Data("literal wildcard".utf8).write(to: root.appendingPathComponent("a*.txt"))
    return root
  }

  /// Запускает 7zz при подготовке фикстуры и сообщает об ошибке создания.
  private func run(_ arguments: [String], in root: URL) throws {
    let process = Process()
    process.executableURL = engine
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }
}
