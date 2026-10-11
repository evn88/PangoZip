import XCTest

@testable import PangoZipCore

final class ArchiveTelemetryTests: XCTestCase, @unchecked Sendable {
  /// Считает скорость по байтам этапа; общий процент с учётом проверки не участвует в оценке.
  func testEstimatesUseStageBytesAndHandleUnknownOrStalledProgress() {
    let estimate = ArchiveProgressEstimate(processed: 30_000_000, total: 90_000_000, elapsed: 3)
    XCTAssertEqual(estimate.speed, 10_000_000)
    XCTAssertEqual(estimate.remaining, 6)
    XCTAssertNil(ArchiveProgressEstimate(processed: 0, total: 100, elapsed: 3).speed)
    XCTAssertNil(ArchiveProgressEstimate(processed: 1, total: 100, elapsed: 0.1).remaining)
    XCTAssertNil(ArchiveProgressEstimate(processed: nil, total: nil, elapsed: 5).speed)
    XCTAssertNil(ArchiveProgressEstimate(processed: 1, total: 2, elapsed: .infinity).speed)
    XCTAssertEqual(ArchiveProgressEstimate(processed: 100, total: 100, elapsed: 1).remaining, 0)
  }

  /// Ограничивает счётчики и не допускает отрицательных либо нечисловых показателей интерфейса.
  func testSnapshotSanitizesTelemetry() {
    let value = ArchiveProgress(
      phase: .extracting, fraction: .nan, processedBytes: 20, totalBytes: 10,
      completedFiles: 9, totalFiles: 2, bytesPerSecond: .infinity,
      remainingSeconds: -1, elapsedSeconds: .nan)
    XCTAssertNil(value.fraction)
    XCTAssertEqual(value.processedBytes, 10)
    XCTAssertEqual(value.completedFiles, 2)
    XCTAssertNil(value.bytesPerSecond)
    XCTAssertNil(value.remainingSeconds)
    XCTAssertEqual(value.elapsedSeconds, 0)
  }

  /// Измеряет пустые файлы и папки, не включая содержимое каталога за символической ссылкой.
  func testWorkloadDoesNotFollowSymlinks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("Input")
    let external = root.appendingPathComponent("Outside")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 100).write(to: external.appendingPathComponent("external.bin"))
    try Data([1, 2, 3]).write(to: input.appendingPathComponent("file.bin"))
    try Data().write(to: input.appendingPathComponent("empty"))
    let link = input.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../Outside")
    let workload = try await ArchiveWorkload.measure(input)
    XCTAssertEqual(workload.files, 3)
    XCTAssertEqual(workload.bytes, 3 + UInt64("../Outside".utf8.count))
  }

  /// Крайние счётчики UInt64 не переполняются; raw 100% не подтверждает файл и всю транзакцию.
  func testReporterMapsBytesAndCompletesFilesWithoutCompletingTransaction() async throws {
    let samples = TelemetrySamples()
    let reporter = ArchiveProgressReporter { await samples.record($0) }
    let callback = try XCTUnwrap(
      reporter.engine(
        phase: .extracting, from: 0.1, to: 0.99, totalBytes: UInt64.max,
        itemBytes: UInt64.max, completedFiles: 0, totalFiles: 1, currentFile: "Huge.bin"))
    await callback(0.5)
    await callback(1)
    let values = await samples.values
    XCTAssertTrue(values[0].bytesAreEstimated)
    XCTAssertLessThan(try XCTUnwrap(values[0].processedBytes), UInt64.max)
    XCTAssertEqual(values[1].processedBytes, UInt64.max)
    XCTAssertEqual(values[1].fraction, 0.99)
    XCTAssertEqual(values[1].completedFiles, 0)
    XCTAssertFalse(values[1].bytesAreEstimated)
    XCTAssertEqual(values[1].currentFile, "Huge.bin")
  }
}

private actor TelemetrySamples {
  private(set) var values: [ArchiveProgress] = []
  /// Сохраняет события из актора отчётов для детерминированной проверки значений.
  func record(_ value: ArchiveProgress) { values.append(value) }
}
