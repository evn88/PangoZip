import Foundation

public struct CompressionOptions: Sendable, Equatable {
  public let format: String
  public let level: Int
  public let solid: Bool
  public let threads: Int

  /// Ограничивает параметры поддерживаемыми значениями; нулевое число потоков выбирает движок.
  public init(format: String = "zip", level: Int = 5, solid: Bool = true, threads: Int = 0) {
    self.format = ["zip", "7z"].contains(format) ? format : "zip"
    self.level = min(9, max(0, level))
    self.solid = solid
    self.threads = min(64, max(0, threads))
  }

  var arguments: [String] {
    ["-mx=\(level)", threads == 0 ? "-mmt=on" : "-mmt=\(threads)"]
      + (format == "7z" ? [solid ? "-ms=on" : "-ms=off"] : [])
  }
}
