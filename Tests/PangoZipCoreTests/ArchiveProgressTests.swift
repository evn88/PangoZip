import XCTest

@testable import PangoZipCore

final class ArchiveProgressTests: XCTestCase, @unchecked Sendable {
  /// Проверяет разбор разорванного прогресса и перерисовки терминала без ложных процентов из имён.
  func testParserHandlesSplitPercentAndTerminalRedrawWithoutReadingFilenamesAsProgress() {
    var parser = EngineProgressParser()
    XCTAssertEqual(parser.consume(Data("  1".utf8)), [])
    XCTAssertEqual(parser.consume(Data("2% + file 99%.txt".utf8)), [0.12])
    XCTAssertEqual(parser.consume(Data("\u{8}\u{8}    \u{8}  45% 2 file".utf8)), [0.45])
    XCTAssertEqual(parser.consume(Data("\r  40%\nERROR 90%\n101%\n  100%".utf8)), [1])
    XCTAssertEqual(parser.consume(Data("\r 100%".utf8)), [])
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
    let extracted = ProgressSamples()
    let output = try await service.extractArchive(archive, progress: { await extracted.record($0) })
    let extractValues = await extracted.values
    assertValid(extractValues)
    XCTAssertTrue(extractValues.contains { $0.phase == .extracting })
    XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("Input/binary.dat")), payload)
    let session = try await service.open(archive)
    let exported = ProgressSamples()
    let export = try await service.exportItem(
      "Input", from: session, to: root.appendingPathComponent("export"),
      progress: { await exported.record($0) })
    let exportValues = await exported.values
    assertValid(exportValues)
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
