import Foundation
import XCTest

@testable import PangoZipCore

/// Ручная проверка на большом объёме: `PANGOZIP_LARGE_SOURCE=/путь swift test --filter LargeSource`.
/// Источник только читается; архив создаётся в `PANGOZIP_LARGE_OUTPUT` (по умолчанию во временной
/// папке) и удаляется. `PANGOZIP_LARGE_SECONDS` задаёт, через сколько секунд отменить операцию;
/// без неё архив создаётся до конца.
final class ArchiveLargeSourceTests: XCTestCase, @unchecked Sendable {
  func testLargeSourceStartsQuicklyReportsProgressAndCancels() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["PANGOZIP_LARGE_SOURCE"], !path.isEmpty else {
      throw XCTSkip("PANGOZIP_LARGE_SOURCE не задан")
    }
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Engine/7zz")
    let format = environment["PANGOZIP_LARGE_FORMAT"] ?? "zip"
    let level = environment["PANGOZIP_LARGE_LEVEL"].flatMap(Int.init) ?? 5
    let limit = environment["PANGOZIP_LARGE_SECONDS"].flatMap(Double.init)
    let parent = environment["PANGOZIP_LARGE_OUTPUT"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.temporaryDirectory
    let output = parent.appendingPathComponent("pangozip-large-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: output) }
    let service = ArchiveService(executableURL: engine)
    let log = LargeSourceLog()
    let started = ProcessInfo.processInfo.systemUptime
    let task = Task {
      try await service.createArchive(
        from: [URL(fileURLWithPath: path)],
        proposedURL: output.appendingPathComponent("large." + format), format: format,
        options: CompressionOptions(format: format, level: level),
        progress: { await log.record($0, since: started) })
    }
    if let limit {
      try await Task.sleep(for: .seconds(limit))
      let cancelled = ProcessInfo.processInfo.systemUptime
      task.cancel()
      do {
        _ = try await task.value
        print("LARGE: finished before cancellation")
      } catch is CancellationError {
        let delay = ProcessInfo.processInfo.systemUptime - cancelled
        print(String(format: "LARGE: cancelled after %.0f s, stopped in %.2f s", limit, delay))
        XCTAssertLessThan(delay, 5)
      }
    } else {
      let archive = try await task.value
      let size = try FileFingerprint(archive).size
      let elapsed = ProcessInfo.processInfo.systemUptime - started
      print(String(format: "LARGE: created %llu bytes in %.1f s", size, elapsed))
    }
    await service.cleanup()
    await log.summary()
    let first = await log.firstCompression
    XCTAssertNotNil(first, "Сжатие не началось")
    // Подготовка только читает метаданные: счёт идёт на секунды, а не на минуты копирования.
    if let first { XCTAssertLessThan(first, 30) }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
  }
}

private actor LargeSourceLog {
  private(set) var firstCompression: TimeInterval?
  private var firstPercent: TimeInterval?
  private var phases: [ArchiveProgress.Phase: TimeInterval] = [:]
  private var last: ArchiveProgress?
  private var lastPrinted: TimeInterval = -100

  func record(_ value: ArchiveProgress, since started: TimeInterval) {
    let now = ProcessInfo.processInfo.systemUptime - started
    if phases[value.phase] == nil {
      phases[value.phase] = now
      print(String(format: "LARGE: %.2f s phase %@", now, String(describing: value.phase)))
    }
    if value.phase == .compressing {
      if firstCompression == nil { firstCompression = now }
      if firstPercent == nil, (value.fraction ?? 0) > 0 { firstPercent = now }
    }
    if now - lastPrinted >= 15 {
      lastPrinted = now
      print(
        String(
          format: "LARGE: %.0f s %@ %.1f%% %llu/%llu bytes, %.0f MB/s, eta %.0f s, out %llu",
          now, String(describing: value.phase), (value.fraction ?? 0) * 100,
          value.processedBytes ?? 0, value.totalBytes ?? 0,
          (value.bytesPerSecond ?? 0) / 1_000_000, value.remainingSeconds ?? -1,
          value.outputBytes ?? 0))
    }
    last = value
  }

  func summary() {
    print(
      String(
        format: "LARGE: first compression event %.2f s, first percent %.2f s, total %llu bytes",
        firstCompression ?? -1, firstPercent ?? -1, last?.totalBytes ?? 0))
  }
}
