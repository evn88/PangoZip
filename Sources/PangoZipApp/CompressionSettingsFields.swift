import PangoZipCore
import SwiftUI
import UniformTypeIdentifiers

/// Названия и типы файлов форматов, которые приложение умеет создавать.
enum ArchiveFormatPresentation {
  static func title(for format: String) -> String {
    switch format {
    case "zip": "ZIP"
    case "tar": "TAR"
    case "tar.gz": "TAR.GZ"
    case "tar.xz": "TAR.XZ"
    case "wim": "WIM"
    default: format
    }
  }

  /// Расширение имени файла совпадает с идентификатором формата («tar.gz» остаётся составным).
  static func contentType(for format: String) -> UTType {
    switch format {
    case "tar.gz": .gzip
    case "tar.xz": UTType(filenameExtension: "xz") ?? .data
    default: UTType(filenameExtension: format) ?? .data
    }
  }

  /// Заменяет известное расширение архива в имени на расширение выбранного формата.
  static func renamed(_ name: String, to format: String) -> String {
    let lower = name.lowercased()
    for suffix in CompressionOptions.supportedFormats.sorted(by: { $0.count > $1.count }) {
      if lower.hasSuffix("." + suffix) {
        return String(name.dropLast(suffix.count + 1)) + "." + format
      }
    }
    return name
  }
}

/// Общий блок параметров сжатия для настроек и окна создания архива.
/// Выбор профиля подставляет значения; ручное изменение любого параметра переключает на «Свой».
struct CompressionSettingsFields: View {
  @Binding var profile: String
  @Binding var format: String
  @Binding var level: Int
  @Binding var solid: Bool
  @Binding var encryptsFileNames: Bool
  /// Размер тома в мегабайтах; 0 означает один файл.
  @Binding var volumeSizeMB: Int
  var formatTitle = L10n.tr("Формат архива")
  var levelTitle = L10n.tr("Уровень сжатия")
  var solidTitle = L10n.tr("Сплошное сжатие")

  private static let volumePresets = [10, 25, 100, 500, 1000, 4000]

  var body: some View {
    Picker(L10n.tr("Профиль"), selection: profileSelection) {
      ForEach(CompressionProfile.builtIn) { Text($0.title).tag($0.id) }
      Text(CompressionProfile.title(for: CompressionProfile.customID))
        .tag(CompressionProfile.customID)
    }
    Picker(formatTitle, selection: manual($format)) {
      ForEach(CompressionOptions.supportedFormats, id: \.self) {
        Text(ArchiveFormatPresentation.title(for: $0)).tag($0)
      }
    }
    Picker(levelTitle, selection: manual($level)) {
      Text(L10n.tr("Без сжатия")).tag(0)
      Text(L10n.tr("Быстрая")).tag(1)
      Text(L10n.tr("Обычная")).tag(5)
      Text(L10n.tr("Максимальная")).tag(7)
      Text(L10n.tr("Ультра")).tag(9)
    }
    .disabled(!CompressionOptions.supportsLevel(format))
    Toggle(isOn: manual($solid)) {
      HStack(spacing: 6) {
        Text(solidTitle)
        Image(systemName: "questionmark.circle")
          .foregroundStyle(.secondary)
          .help(Self.solidHelp)
          .accessibilityHidden(true)
      }
    }
    .accessibilityLabel(solidTitle)
    .accessibilityHint(Self.solidHelp)
    .disabled(!CompressionOptions.supportsSolid(format))
    Toggle(L10n.tr("Шифровать имена файлов"), isOn: manual($encryptsFileNames))
      .help(
        L10n.tr("Для 7z с паролем: скрывает не только содержимое, но и список файлов в архиве.")
      )
      .disabled(!CompressionOptions.supportsFileNameEncryption(format))
    Picker(L10n.tr("Размер тома"), selection: manual($volumeSizeMB)) {
      Text(L10n.tr("Один файл")).tag(0)
      ForEach(volumeChoices, id: \.self) {
        Text(L10n.tr("%1$@ МБ", String(describing: $0))).tag($0)
      }
    }
    .disabled(!CompressionOptions.supportsVolumes(format))
  }

  private static var solidHelp: String {
    L10n.tr(
      "Сжимает файлы вместе: архив обычно меньше, но извлечение одного файла может занять больше времени."
    )
  }

  /// Готовые размеры плюс текущее значение, если оно пришло из профиля или старых настроек.
  private var volumeChoices: [Int] {
    Array(Set(Self.volumePresets + (volumeSizeMB > 0 ? [volumeSizeMB] : []))).sorted()
  }

  /// Ручное изменение параметра сбрасывает профиль на «Свой».
  private func manual<Value>(_ binding: Binding<Value>) -> Binding<Value> {
    Binding(
      get: { binding.wrappedValue },
      set: {
        binding.wrappedValue = $0
        profile = CompressionProfile.customID
      })
  }

  /// Выбор профиля подставляет все значения; «Свой» оставляет текущие.
  private var profileSelection: Binding<String> {
    Binding(
      get: { profile },
      set: { id in
        if let selected = CompressionProfile.builtIn(id: id) {
          format = selected.format
          level = selected.level
          solid = selected.solid
          encryptsFileNames = selected.encryptsFileNames
          volumeSizeMB = selected.volumeSizeMB ?? 0
        }
        profile = id
      })
  }
}
