import Foundation

/// Набор параметров сжатия под одним названием. Потоки и служебные файлы в профиль не входят.
public struct CompressionProfile: Codable, Sendable, Equatable, Identifiable {
  /// Идентификатор «Свой»: значения заданы вручную и не совпадают с профилем.
  public static let customID = "custom"

  public let id: String
  public let format: String
  public let level: Int
  public let solid: Bool
  public let encryptsFileNames: Bool
  public let volumeSizeMB: Int?

  /// Приводит значения к допустимым через `CompressionOptions`, чтобы профиль не нёс невозможных сочетаний.
  public init(
    id: String, format: String, level: Int, solid: Bool = true, encryptsFileNames: Bool = true,
    volumeSizeMB: Int? = nil
  ) {
    let options = CompressionOptions(
      format: format, level: level, solid: solid, volumeSizeMB: volumeSizeMB)
    self.id = id
    self.format = options.format
    self.level = options.level
    self.solid = options.solid
    self.encryptsFileNames = encryptsFileNames
    self.volumeSizeMB = options.volumeSizeMB
  }

  public static let fast = Self(id: "fast", format: "zip", level: 1, solid: false)
  public static let normal = Self(id: "normal", format: "zip", level: 5, solid: false)
  public static let maximum = Self(id: "maximum", format: "7z", level: 9, solid: true)
  public static let email = Self(
    id: "email", format: "7z", level: 5, solid: true, volumeSizeMB: 25)

  /// Встроенные профили в порядке показа.
  public static let builtIn: [Self] = [.fast, .normal, .maximum, .email]

  /// Находит встроенный профиль по идентификатору; для «Свой» и неизвестных значений возвращает nil.
  public static func builtIn(id: String) -> Self? { builtIn.first { $0.id == id } }

  /// Название профиля для интерфейса; «Свой» не является значением модели, но имеет подпись.
  public static func title(for id: String) -> String {
    switch id {
    case "fast": L10n.tr("Быстро")
    case "normal": L10n.tr("Обычный")
    case "maximum": L10n.tr("Максимум")
    case "email": L10n.tr("Для почты (тома по 25 МБ)")
    default: L10n.tr("Свой")
    }
  }

  public var title: String { Self.title(for: id) }

  /// Параметры сжатия профиля; потоки и исключение служебных файлов задаёт вызывающий.
  public func options(threads: Int = 0, excludesSystemFiles: Bool = true) -> CompressionOptions {
    CompressionOptions(
      format: format, level: level, solid: solid, threads: threads,
      excludesSystemFiles: excludesSystemFiles, volumeSizeMB: volumeSizeMB,
      encryptsFileNames: encryptsFileNames)
  }

  /// Определяет встроенный профиль, значения которого полностью совпадают с заданными параметрами.
  /// Параметры, не влияющие на формат (например, solid для zip), при сравнении игнорируются.
  public static func matching(
    format: String, level: Int, solid: Bool, encryptsFileNames: Bool, volumeSizeMB: Int?
  ) -> Self? {
    let candidate = CompressionOptions(
      format: format, level: level, solid: solid, volumeSizeMB: volumeSizeMB)
    return builtIn.first { profile in
      let reference = profile.options()
      return reference.format == candidate.format
        && reference.volumeSizeMB == candidate.volumeSizeMB
        && (!CompressionOptions.supportsLevel(reference.format)
          || reference.level == candidate.level)
        && (!CompressionOptions.supportsSolid(reference.format)
          || reference.solid == candidate.solid)
        && (!CompressionOptions.supportsFileNameEncryption(reference.format)
          || profile.encryptsFileNames == encryptsFileNames)
    }
  }
}
