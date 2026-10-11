import Foundation

/// Считает логический объём файлов, не обходя ссылки и не блокируя исполнитель архивного сервиса.
struct ArchiveWorkload: Sendable, Equatable {
  let bytes: UInt64
  let files: Int

  /// Суммирует записи файлов; метаданные папок не входят в обработанные байты.
  init(entries: [ArchiveEntry]) throws {
    var bytes: UInt64 = 0
    var files = 0
    for entry in entries where !entry.isDirectory {
      let sum = bytes.addingReportingOverflow(entry.size)
      guard !sum.overflow else { throw ArchiveError.outputLimit }
      bytes = sum.partialValue
      files += 1
    }
    self.bytes = bytes
    self.files = files
  }

  /// Принимает уже подсчитанные значения закрытого рабочего каталога.
  private init(bytes: UInt64, files: Int) {
    self.bytes = bytes
    self.files = files
  }

  /// Измеряет готовые копии, поэтому размер совпадает с данными, передаваемыми движку.
  static func measure(_ directory: URL) async throws -> Self {
    let task = Task.detached(priority: .userInitiated) { try measureBlocking(directory) }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  /// Обходит только реальные каталоги и считает ссылку как запись, а не её содержимое.
  private static func measureBlocking(_ url: URL) throws -> Self {
    try Task.checkCancellation()
    let fingerprint = try FileFingerprint(url)
    if fingerprint.type != .typeDirectory {
      return Self(bytes: fingerprint.size, files: 1)
    }
    var bytes: UInt64 = 0
    var files = 0
    for child in try FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: nil)
    {
      let item = try measureBlocking(child)
      let sum = bytes.addingReportingOverflow(item.bytes)
      guard !sum.overflow else { throw ArchiveError.outputLimit }
      bytes = sum.partialValue
      files += item.files
    }
    return Self(bytes: bytes, files: files)
  }
}

/// Скорость и оставшееся время относятся к текущему этапу, а не к проценту всей транзакции.
struct ArchiveProgressEstimate {
  let speed: Double?
  let remaining: TimeInterval?

  /// Не показывает неустойчивую оценку до первых данных и половины секунды наблюдения.
  init(processed: UInt64?, total: UInt64?, elapsed: TimeInterval) {
    guard let processed, let total, processed > 0, elapsed.isFinite, elapsed >= 0.5 else {
      speed = nil
      remaining = nil
      return
    }
    let rate = Double(processed) / elapsed
    speed = rate.isFinite && rate > 0 ? rate : nil
    let estimate = Double(total - min(processed, total)) / rate
    remaining = estimate.isFinite && estimate >= 0 ? estimate : nil
  }
}

actor ArchiveProgressReporter {
  private let handler: ArchiveProgressHandler?
  private let started = ProcessInfo.processInfo.systemUptime
  private var phaseStarted = ProcessInfo.processInfo.systemUptime
  private var previousPhase: ArchiveProgress.Phase?
  private var previousTotal: UInt64?
  private var previousBytes: UInt64 = 0
  private var lastOutputBytes: UInt64?

  /// Каждый экземпляр принадлежит одной операции, включая подготовку, проверку и публикацию.
  init(_ handler: ArchiveProgressHandler?) { self.handler = handler }

  /// Публикует согласованный снимок счётчиков; системные часы не влияют на скорость операции.
  func report(
    phase: ArchiveProgress.Phase, fraction: Double? = nil,
    processedBytes: UInt64? = nil, totalBytes: UInt64? = nil,
    completedFiles: Int? = nil, totalFiles: Int? = nil, currentFile: String? = nil,
    outputURL: URL? = nil, estimated: Bool = false
  ) async {
    guard let handler else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if previousPhase != phase || previousTotal != totalBytes
      || (processedBytes ?? 0) < previousBytes
    {
      phaseStarted = now
    }
    previousPhase = phase
    previousTotal = totalBytes
    previousBytes = processedBytes ?? 0
    if let outputURL,
      let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
      let size = attributes[.size] as? NSNumber
    {
      lastOutputBytes = size.uint64Value
    }
    let active = [.compressing, .verifying, .extracting].contains(phase)
    let estimate = ArchiveProgressEstimate(
      processed: active ? processedBytes : nil, total: totalBytes, elapsed: now - phaseStarted)
    await handler(
      ArchiveProgress(
        phase: phase, fraction: fraction, processedBytes: processedBytes, totalBytes: totalBytes,
        completedFiles: completedFiles, totalFiles: totalFiles, currentFile: currentFile,
        outputBytes: lastOutputBytes, bytesPerSecond: estimate.speed,
        remainingSeconds: estimate.remaining, elapsedSeconds: now - started,
        bytesAreEstimated: estimated))
  }

  /// Переводит проценты команды в общий прогресс и оценку байтов без преждевременных 100% транзакции.
  nonisolated func engine(
    phase: ArchiveProgress.Phase, from start: Double, to end: Double,
    totalBytes: UInt64, baseBytes: UInt64 = 0, itemBytes: UInt64? = nil,
    completedFiles: Int? = nil, totalFiles: Int? = nil, currentFile: String? = nil,
    outputURL: URL? = nil
  ) -> (@Sendable (Double) async -> Void)? {
    guard handler != nil else { return nil }
    return { fraction in
      let safe = fraction.isFinite ? min(1, max(0, fraction)) : 0
      let item = itemBytes ?? totalBytes
      let bytes = Self.scaledBytes(item, fraction: safe)
      let sum = baseBytes.addingReportingOverflow(bytes)
      let processed = min(totalBytes, sum.overflow ? UInt64.max : sum.partialValue)
      await self.report(
        phase: phase, fraction: start + safe * (end - start), processedBytes: processed,
        totalBytes: totalBytes,
        completedFiles: completedFiles,
        totalFiles: totalFiles, currentFile: currentFile, outputURL: outputURL,
        estimated: safe > 0 && safe < 1)
    }
  }

  /// Избегает переполнения UInt64 на границе округления Double и сохраняет точное завершение файла.
  private nonisolated static func scaledBytes(_ bytes: UInt64, fraction: Double) -> UInt64 {
    if fraction <= 0 { return 0 }
    if fraction >= 1 { return bytes }
    let value = Double(bytes) * fraction
    return value >= Double(UInt64.max) ? bytes : min(bytes, UInt64(value))
  }
}
