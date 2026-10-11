import Foundation

public typealias ArchiveProgressHandler = @Sendable (ArchiveProgress) async -> Void

public struct ArchiveProgress: Sendable, Equatable {
  public enum Phase: Sendable, Equatable {
    case preparing, compressing, verifying, extracting, finalizing
  }

  public let phase: Phase
  public let fraction: Double?
  public let processedBytes: UInt64?
  public let totalBytes: UInt64?
  public let completedFiles: Int?
  public let totalFiles: Int?
  public let currentFile: String?
  public let outputBytes: UInt64?
  public let bytesPerSecond: Double?
  public let remainingSeconds: TimeInterval?
  public let elapsedSeconds: TimeInterval
  public let updatedAt: Date
  public let bytesAreEstimated: Bool

  /// Ограничивает известную долю диапазоном 0…1; нечисловое значение означает неизвестный прогресс.
  public init(
    phase: Phase, fraction: Double? = nil, processedBytes: UInt64? = nil,
    totalBytes: UInt64? = nil, completedFiles: Int? = nil, totalFiles: Int? = nil,
    currentFile: String? = nil, outputBytes: UInt64? = nil, bytesPerSecond: Double? = nil,
    remainingSeconds: TimeInterval? = nil, elapsedSeconds: TimeInterval = 0,
    updatedAt: Date = Date(), bytesAreEstimated: Bool = false
  ) {
    self.phase = phase
    self.fraction = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    self.totalBytes = totalBytes
    self.processedBytes = processedBytes.map { min($0, totalBytes ?? $0) }
    let safeTotalFiles = totalFiles.map { max(0, $0) }
    self.totalFiles = safeTotalFiles
    self.completedFiles = completedFiles.map { min(max(0, $0), safeTotalFiles ?? max(0, $0)) }
    self.currentFile = currentFile
    self.outputBytes = outputBytes
    self.bytesPerSecond = bytesPerSecond.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    self.remainingSeconds = remainingSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    self.elapsedSeconds = elapsedSeconds.isFinite ? max(0, elapsedSeconds) : 0
    self.updatedAt = updatedAt
    self.bytesAreEstimated = bytesAreEstimated
  }
}

// 7zz перерисовывает строку через backspace; запись может разрываться между чтениями.
struct EngineProgressParser {
  private var digits = ""
  private var ignoresRecord = false
  private var lastPercent = -1

  /// Сохраняет незавершённые проценты между чтениями и пропускает повторные или убывающие значения.
  mutating func consume(_ data: Data) -> [Double] {
    var values: [Double] = []
    for byte in data {
      if [8, 10, 13].contains(byte) {
        digits = ""
        ignoresRecord = false
      } else if !ignoresRecord {
        if byte == 32 || byte == 9 {
          if !digits.isEmpty { ignoresRecord = true }
        } else if (48...57).contains(byte), digits.count < 3 {
          digits.append(Character(UnicodeScalar(byte)))
        } else if byte == 37, let percent = Int(digits), percent <= 100 {
          if percent > lastPercent {
            values.append(Double(percent) / 100)
            lastPercent = percent
          }
          ignoresRecord = true
        } else {
          ignoresRecord = true
        }
      }
    }
    return values
  }
}
