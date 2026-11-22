import XCTest

@testable import PangoZipCore

final class ArchiveProgressTests: XCTestCase, @unchecked Sendable {
  /// Проверяет разбор разорванного прогресса и перерисовки терминала без ложных процентов из имён.
  func testParserHandlesSplitPercentAndTerminalRedrawWithoutReadingFilenamesAsProgress() {
    var parser = EngineProgressParser()
    XCTAssertEqual(parser.consume(Data("  1".utf8)), [])
    XCTAssertEqual(
      parser.consume(Data("2% + file 99%.txt".utf8)),
      [EngineProgressUpdate(fraction: 0.12, file: "file 99%.txt")])
    XCTAssertEqual(
      parser.consume(Data("\u{8}\u{8}    \u{8}  45% 2 file".utf8)),
      [EngineProgressUpdate(fraction: 0.45, files: 2, file: "file")])
    XCTAssertEqual(
      parser.consume(Data("\r  40%\nERROR 90%\n101%\n  100%".utf8)),
      [EngineProgressUpdate(fraction: 1)])
    XCTAssertEqual(parser.consume(Data("\r 100%".utf8)), [])
    XCTAssertEqual(String(decoding: parser.messages, as: UTF8.self), "ERROR 90%\n101%\n")
  }

  /// Счётчик файлов, команда и имя читаются из записи; смена файла при том же проценте видна.
  func testParserReportsFileCountAndCurrentNameBetweenPercentSteps() {
    var parser = EngineProgressParser()
    XCTAssertEqual(
      parser.consume(Data("  3% 7 + Folder/ name with  spaces .txt".utf8)),
      [EngineProgressUpdate(fraction: 0.03, files: 7, file: "Folder/ name with  spaces .txt")])
    let erase =
      String(repeating: "\u{8}", count: 5) + "     " + String(repeating: "\u{8}", count: 5)
    XCTAssertEqual(
      parser.consume(Data((erase + "  3% 8 + 2024 report.pdf").utf8)),
      [EngineProgressUpdate(fraction: 0.03, files: 8, file: "2024 report.pdf")])
    // Повтор той же записи и стирающие пробелы новых событий не дают.
    XCTAssertEqual(parser.consume(Data((erase + "  3% 8 + 2024 report.pdf").utf8)), [])
    XCTAssertEqual(
      parser.consume(Data((erase + "  4% 8 T 2024 report.pdf").utf8)),
      [EngineProgressUpdate(fraction: 0.04, files: 8, file: "2024 report.pdf")])
    // Запись, разорванная между чтениями, уточняется следующим чтением.
    XCTAssertEqual(
      parser.consume(Data((erase + "  5% 9 + par").utf8)),
      [EngineProgressUpdate(fraction: 0.05, files: 9, file: "par")])
    XCTAssertEqual(
      parser.consume(Data("t.bin".utf8)),
      [EngineProgressUpdate(fraction: 0.05, files: 9, file: "part.bin")])
    // Сообщение без перевода строки в конце вывода сохраняется для разбора ошибки.
    XCTAssertEqual(parser.consume(Data((erase + "\nERROR: Wrong password").utf8)), [])
    XCTAssertEqual(parser.finish(), [])
    XCTAssertEqual(String(decoding: parser.messages, as: UTF8.self), "ERROR: Wrong password\n")
  }

  /// Проверяет монотонность прогресса и целостность двоичных данных в реальных операциях.
  func testRealEngineCreationExtractionAndFolderExportHaveMonotonicProgressAndKeepBinaryData()
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Input")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("Empty"), withIntermediateDirectories: true)
    let payload = Data((0..<262_144).map { UInt8(truncatingIfNeeded: $0) })
    try payload.write(to: source.appendingPathComponent("binary.dat"))
    try Data().write(to: source.appendingPathComponent("zero.dat"))
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let created = ProgressSamples()
    let archive = try await service.createArchive(
      from: [source], proposedURL: root.appendingPathComponent("sample.7z"), format: "7z",
      progress: { await created.record($0) })
    let createValues = await created.values
    assertValid(createValues)
    XCTAssertTrue(createValues.contains { $0.phase == .compressing })
    XCTAssertTrue(createValues.contains { $0.phase == .verifying })
    XCTAssertEqual(createValues.last?.totalBytes, UInt64(payload.count))
    XCTAssertEqual(createValues.last?.processedBytes, UInt64(payload.count))
    XCTAssertEqual(createValues.last?.completedFiles, 2)
    XCTAssertEqual(
      createValues.last?.outputBytes,
      try FileFingerprint(archive).size)
    XCTAssertTrue(
      createValues.filter { $0.phase == .compressing }.allSatisfy {
        $0.totalBytes == UInt64(payload.count) && $0.totalFiles == 2
      })
    let extracted = ProgressSamples()
    let output = try await service.extractArchive(archive, progress: { await extracted.record($0) })
    let extractValues = await extracted.values
    assertValid(extractValues)
    XCTAssertTrue(extractValues.contains { $0.phase == .extracting })
    XCTAssertEqual(extractValues.last?.processedBytes, UInt64(payload.count))
    XCTAssertEqual(extractValues.last?.completedFiles, 2)
    XCTAssertTrue(extractValues.contains { $0.currentFile == "Input/binary.dat" })
    XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("Input/binary.dat")), payload)
    let session = try await service.open(archive)
    let exported = ProgressSamples()
    let export = try await service.exportItem(
      "Input", from: session, to: root.appendingPathComponent("export"),
      progress: { await exported.record($0) })
    let exportValues = await exported.values
    assertValid(exportValues)
    XCTAssertEqual(exportValues.last?.processedBytes, UInt64(payload.count))
    XCTAssertEqual(exportValues.last?.totalFiles, 2)
    XCTAssertEqual(exportValues.last?.completedFiles, 2)
    XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("binary.dat")), payload)
    await service.cleanup()
  }

  /// Проверяет границы, порядок и успешное завершение последовательности прогресса.
  private func assertValid(
    _ values: [ArchiveProgress], file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(values.first?.phase, .preparing, file: file, line: line)
    XCTAssertEqual(values.last?.fraction, 1, file: file, line: line)
    let fractions = values.compactMap(\.fraction)
    XCTAssertEqual(fractions, fractions.sorted(), file: file, line: line)
    XCTAssertTrue(fractions.allSatisfy { $0 >= 0 && $0 <= 1 }, file: file, line: line)
    XCTAssertTrue(fractions.dropLast().allSatisfy { $0 < 1 }, file: file, line: line)
  }
}

private actor ProgressSamples {
  private(set) var values: [ArchiveProgress] = []
  /// Сохраняет событие прогресса для проверки последовательности вызовов.
  func record(_ value: ArchiveProgress) { values.append(value) }
}
