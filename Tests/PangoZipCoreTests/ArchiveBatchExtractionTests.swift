import Darwin
import XCTest

@testable import PangoZipCore

final class ArchiveBatchExtractionTests: XCTestCase, @unchecked Sendable {
  private let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Engine/7zz")

  /// Один запуск извлекает много выбранных файлов и не захватывает соседние записи или wildcard.
  func testSelectionUsesOneExtractionProcessAndLiteralNames() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let wrapper = try countingEngine(in: root)
    let service = ArchiveService(executableURL: wrapper)
    let session = try await service.open(root.appendingPathComponent("sample.7z"))
    let results = try await service.exportSelection(
      ["docs", "a*.txt"], from: session, to: root.appendingPathComponent("output"))
    XCTAssertEqual(results.map(\.lastPathComponent), ["a*.txt", "docs"])
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8), "x\n")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: results[1].path).count, 41)
    XCTAssertEqual(try Data(contentsOf: results[1].appendingPathComponent("file17")), Data([17]))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("output/abc.txt").path))
    await service.cleanup()
  }

  /// Полная распаковка тоже использует один процесс и сохраняет quarantine на каждом файле.
  func testWholeArchiveUsesOneExtractionProcessAndPreservesQuarantine() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("sample.7z")
    let quarantine = Data("0083;12345678;Test;".utf8)
    try quarantine.withUnsafeBytes {
      guard setxattr(archive.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) == 0
      else {
        throw POSIXError(.EIO)
      }
    }
    let service = ArchiveService(executableURL: try countingEngine(in: root))
    let output = try await service.extractArchive(archive)
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8), "x\n")
    let file = output.appendingPathComponent("docs/file17")
    var data = Data(count: quarantine.count)
    let count = data.withUnsafeMutableBytes {
      getxattr(file.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
    }
    XCTAssertEqual(count, quarantine.count)
    XCTAssertEqual(data, quarantine)
    await service.cleanup()
  }

  /// Ссылки и превышение общего лимита отклоняются до запуска извлечения всей выборки.
  func testSelectionPreflightRejectsLinksAndAggregateLimitBeforePublishing() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("link").path, withDestinationPath: "docs/file0")
    try run(engine, arguments: ["a", "-snl", "links.7z", "docs", "link"], in: root)
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(root.appendingPathComponent("links.7z"))
    do {
      _ = try await service.exportSelection(
        ["docs", "link"], from: session, to: root.appendingPathComponent("output"))
      XCTFail("Expected unsupported link")
    } catch { XCTAssertEqual(error as? ArchiveError, .unsupportedExtraction) }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("output").path),
      [])
    let safeSession = try await service.open(root.appendingPathComponent("sample.7z"))
    do {
      _ = try await service.exportSelection(
        ["docs", "a*.txt"], from: safeSession, to: root.appendingPathComponent("output"),
        maximumBytes: 40)
      XCTFail("Expected aggregate limit")
    } catch { XCTAssertEqual(error as? ArchiveError, .outputLimit) }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("output").path),
      [])
    let results = try await service.exportSelection(
      ["docs"], from: session, to: root.appendingPathComponent("output"))
    XCTAssertEqual(results.map(\.lastPathComponent), ["docs"])
    XCTAssertEqual(try Data(contentsOf: results[0].appendingPathComponent("file17")), Data([17]))
    await service.cleanup()
  }

  /// Неоднозначные регистром папки и traversal в реальном ZIP не доходят до публикации.
  func testMalformedPathsAndCaseCollisionsNeverPublish() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let fixtures: [(String, String, ArchiveError)] = [
      (
        "collision.zip",
        "UEsDBBQAAAAAAAAAIVAAAAAAAAAAAAAAAAAIAAAARG9jcy9vbmVQSwMEFAAAAAAAAAAhUAAAAAAAAAAAAAAAAAgAAABkb2NzL3R3b1BLAQIUAxQAAAAAAAAAIVAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAACAAQAAAABEb2NzL29uZVBLAQIUAxQAAAAAAAAAIVAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAACAASYAAABkb2NzL3R3b1BLBQYAAAAAAgACAGwAAABMAAAAAAA=",
        .duplicatePath
      ),
      (
        "traversal.zip",
        "UEsDBBQAAAAAAAAAIVAAAAAAAAAAAAAAAAAJAAAALi4vZXNjYXBlUEsBAhQDFAAAAAAAAAAhUAAAAAAAAAAAAAAAAAkAAAAAAAAAAAAAAIABAAAAAC4uL2VzY2FwZVBLBQYAAAAAAQABADcAAAAnAAAAAAA=",
        .unsafePath
      ),
    ]
    for (name, bytes, expected) in fixtures {
      let archive = root.appendingPathComponent(name)
      try XCTUnwrap(Data(base64Encoded: bytes)).write(to: archive)
      do {
        _ = try await service.extractArchive(
          archive, directory: root.appendingPathComponent("output"))
        XCTFail("Expected unsafe archive")
      } catch { XCTAssertEqual(error as? ArchiveError, expected) }
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("output").path),
      [])
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
    await service.cleanup()
  }

  /// ZIP и TAR используют тот же manifest, включая пустые каталоги и точный подкаталог.
  func testBatchExportSupportsZipAndTar() async throws {
    for format in ["zip", "tar"] {
      let root = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let archive = root.appendingPathComponent("sample." + format)
      try run(engine, arguments: ["a", archive.path, "docs"], in: root)
      let service = ArchiveService(executableURL: engine)
      let session = try await service.open(archive)
      let result = try await service.exportItem(
        "docs", from: session, to: root.appendingPathComponent("output/tree"))
      XCTAssertEqual(try Data(contentsOf: result.appendingPathComponent("file17")), Data([17]))
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: result.appendingPathComponent("empty").path))
      await service.cleanup()
    }
  }

  /// Нумерованные части копируются вместе и извлекаются тем же единственным запуском x.
  func testNumericSplitArchiveUsesPrivateVolumeSnapshot() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 67) })
    try payload.write(to: root.appendingPathComponent("large.dat"))
    try run(
      engine, arguments: ["a", "-mx0", "-v1k", "split.7z", "docs", "large.dat"], in: root)
    let service = ArchiveService(executableURL: try countingEngine(in: root))
    let session = try await service.open(root.appendingPathComponent("split.7z.001"))
    XCTAssertFalse(session.canModify)
    let output = try await service.exportSelection(
      ["docs", "large.dat"], from: session, to: root.appendingPathComponent("output"))
    XCTAssertEqual(output.map(\.lastPathComponent), ["docs", "large.dat"])
    XCTAssertEqual(try Data(contentsOf: output[1]), payload)
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8), "x\n")
    await service.cleanup()
  }

  /// Отмена после записи движком остаётся внутри staging и не публикует выбранные корни.
  func testCancellationAfterBatchOutputRemovesPrivateTransaction() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(root.appendingPathComponent("sample.7z"))
    let job = Task {
      try await service.exportSelection(
        ["docs", "a*.txt"], from: session, to: root.appendingPathComponent("output"),
        progress: { value in
          if value.phase == .extracting, (value.fraction ?? 0) > 0 {
            withUnsafeCurrentTask { $0?.cancel() }
          }
        })
    }
    do {
      _ = try await job.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("output").path),
      [])
    try await service.close(session)
  }

  /// Quarantine переносится и на архивные файлы без права записи, сохраняя исходные права.
  func testReadOnlyExtractedFileKeepsPermissionsAndQuarantine() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444], ofItemAtPath: root.appendingPathComponent("docs/file17").path)
    let archive = root.appendingPathComponent("readonly.7z")
    try run(engine, arguments: ["a", archive.path, "docs/file17"], in: root)
    let quarantine = Data("0083;12345678;Test;".utf8)
    try quarantine.withUnsafeBytes {
      guard setxattr(archive.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) == 0
      else {
        throw POSIXError(.EIO)
      }
    }
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    let output = try await service.exportItem(
      "docs", from: session, to: root.appendingPathComponent("output/tree"))
    XCTAssertEqual(
      getxattr(output.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), quarantine.count)
    let file = output.appendingPathComponent("file17")
    let permissions =
      try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o444)
    XCTAssertEqual(
      getxattr(file.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), quarantine.count)
    try await service.close(session)
  }

  /// Listfile сохраняет пробелы и кавычки буквально, не извлекая соседей с обрезанным именем.
  func testBatchListPreservesWhitespaceAndLiteralQuotes() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("names")
    let names = [
      " lead.txt", "lead.txt", "trail.txt ", "trail.txt",
      "\"quoted\"", "hello\"there", "\"start", "end\"", " dir / child ",
    ]
    for (index, name) in names.enumerated() {
      let url = input.appendingPathComponent(name)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("value-\(index)".utf8).write(to: url)
    }
    let archive = root.appendingPathComponent("names.zip")
    try run(engine, arguments: ["a", archive.path, "."], in: input)
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    let destination = root.appendingPathComponent("output")
    let selected = names.filter { !["lead.txt", "trail.txt"].contains($0) }
    _ = try await service.exportSelection(selected, from: session, to: destination)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: destination.path).count, selected.count)
    for (index, name) in names.enumerated() where selected.contains(name) {
      let output = destination.appendingPathComponent(String(name.split(separator: "/").last!))
      XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "value-\(index)")
    }
    try await service.close(session)
  }

  /// Создаёт solid-архив с маленькими файлами, пустым каталогом и буквальным wildcard.
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    for path in ["docs/empty", "output"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    for index in 0..<40 {
      try Data([UInt8(index)]).write(to: root.appendingPathComponent("docs/file\(index)"))
    }
    try Data("literal".utf8).write(to: root.appendingPathComponent("a*.txt"))
    try Data("excluded".utf8).write(to: root.appendingPathComponent("abc.txt"))
    try run(engine, arguments: ["a", "-spd", "sample.7z", "docs", "a*.txt", "abc.txt"], in: root)
    return root
  }

  /// Shim использует execv напрямую, чтобы считать реальные запуски без оболочки.
  private func countingEngine(in root: URL) throws -> URL {
    let source = root.appendingPathComponent("engine.swift")
    let output = root.appendingPathComponent("engine")
    let sourceCode = """
      import Darwin
      import Foundation
      let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
      if CommandLine.arguments.dropFirst().first == "x" {
        let log = root.appendingPathComponent("calls")
        if !FileManager.default.fileExists(atPath: log.path) {
          FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("x\\n".utf8))
        try handle.close()
      }
      let args = [\(String(reflecting: engine.path))] + Array(CommandLine.arguments.dropFirst())
      let pointers = args.map { strdup($0) }
      pointers.withUnsafeBufferPointer { buffer in
        var terminated = Array(buffer) + [nil]
        terminated.withUnsafeMutableBufferPointer { execv(args[0], $0.baseAddress!) }
      }
      exit(127)
      """
    try Data(sourceCode.utf8).write(to: source)
    try run(
      URL(fileURLWithPath: "/usr/bin/xcrun"),
      arguments: ["swiftc", source.path, "-o", output.path], in: root)
    return output
  }

  /// Подготавливает фикстуры прямым запуском процесса.
  private func run(_ executable: URL, arguments: [String], in root: URL) throws {
    let process = Process()
    process.executableURL = executable
    process.currentDirectoryURL = root
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }
}
