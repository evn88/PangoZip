import Foundation

public struct CompressionOptions: Sendable, Equatable {
  /// Форматы, которые умеет создавать сервис; tar.gz и tar.xz собираются в два шага.
  public static let supportedFormats = ["zip", "7z", "tar", "tar.gz", "tar.xz", "wim"]
  /// Верхний предел размера тома, МБ; защищает от переполнения при пересчёте в байты.
  public static let maximumVolumeSizeMB = 1_000_000

  public let format: String
  public let level: Int
  public let solid: Bool
  public let threads: Int
  /// Не включать в архив .DS_Store, __MACOSX, ._* и другие служебные файлы систем.
  public let excludesSystemFiles: Bool
  /// Размер тома в мегабайтах; nil означает один файл. Доступен только для zip и 7z.
  public let volumeSizeMB: Int?
  /// Шифровать имена файлов (`-mhe=on`); действует только для 7z с паролем.
  public let encryptsFileNames: Bool

  /// Ограничивает параметры поддерживаемыми значениями; нулевое число потоков выбирает движок.
  public init(
    format: String = "zip", level: Int = 5, solid: Bool = true, threads: Int = 0,
    excludesSystemFiles: Bool = true, volumeSizeMB: Int? = nil, encryptsFileNames: Bool = true
  ) {
    let normalized = Self.supportedFormats.contains(format) ? format : "zip"
    self.format = normalized
    self.level = min(9, max(0, level))
    self.solid = solid
    self.threads = min(64, max(0, threads))
    self.excludesSystemFiles = excludesSystemFiles
    if Self.supportsVolumes(normalized), let size = volumeSizeMB, size > 0 {
      self.volumeSizeMB = min(Self.maximumVolumeSizeMB, size)
    } else {
      self.volumeSizeMB = nil
    }
    self.encryptsFileNames = encryptsFileNames
  }

  /// Пароль принимают только zip (AES-256) и 7z.
  public static func supportsPassword(_ format: String) -> Bool { ["zip", "7z"].contains(format) }
  /// Тома создаёт 7zz для zip и 7z.
  public static func supportsVolumes(_ format: String) -> Bool { ["zip", "7z"].contains(format) }
  /// Сплошное сжатие существует только в 7z.
  public static func supportsSolid(_ format: String) -> Bool { format == "7z" }
  /// У tar и wim создаваемые архивы не сжимаются, поэтому уровень не передаётся.
  public static func supportsLevel(_ format: String) -> Bool { !["tar", "wim"].contains(format) }
  /// Имена файлов шифруются только в 7z.
  public static func supportsFileNameEncryption(_ format: String) -> Bool { format == "7z" }

  /// Ключи сжатия; для tar и wim пусты, для tar.gz и tar.xz относятся к внешнему слою.
  var arguments: [String] {
    guard Self.supportsLevel(format) else { return [] }
    return ["-mx=\(level)", threads == 0 ? "-mmt=on" : "-mmt=\(threads)"]
      + (format == "7z" ? [solid ? "-ms=on" : "-ms=off"] : [])
  }

  /// Ключ размера тома 7zz, например `-v25m`.
  var volumeArguments: [String] { volumeSizeMB.map { ["-v\($0)m"] } ?? [] }
}
