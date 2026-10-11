import Foundation

public typealias ArchiveProgressHandler = @Sendable (ArchiveProgress) async -> Void

public struct ArchiveProgress: Sendable, Equatable {
  public enum Phase: Sendable, Equatable {
    case preparing, compressing, verifying, extracting, finalizing
  }

  public let phase: Phase
  public let fraction: Double?

  /// Ограничивает известную долю диапазоном 0…1; нечисловое значение означает неизвестный прогресс.
  public init(phase: Phase, fraction: Double? = nil) {
    self.phase = phase
    self.fraction = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
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

/// Переводит долю одной команды в диапазон всей операции; без обработчика отключает передачу.
func engineProgress(
  _ handler: ArchiveProgressHandler?, phase: ArchiveProgress.Phase, from start: Double,
  to end: Double
) -> (@Sendable (Double) async -> Void)? {
  guard let handler else { return nil }
  return { fraction in
    await handler(ArchiveProgress(phase: phase, fraction: start + fraction * (end - start)))
  }
}
