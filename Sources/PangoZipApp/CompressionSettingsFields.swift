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
  /// Строки, которые компактная раскладка ставит в начало правой колонки, перед флажками.
  /// Если они заданы, блок занимает две колонки с подписями слева вместо списка настроек.
  var compactTrailing: [CompactSettingsRow]?

  /// Размер тома в мегабайтах 7-Zip и носитель или ограничение, под которое он подобран.
  private static let volumePresets: [(size: Int, note: String?)] = [
    (10, nil), (25, "e-mail"), (100, nil), (700, "CD"), (1000, nil), (2047, "FAT16"),
    (4095, "FAT32"), (4480, "DVD"), (8100, "DVD DL"), (23800, "Blu-ray"),
  ]
  private static let customVolumeTag = -1
  /// Пользователь выбрал «Другой размер…», даже если введённое число совпало с готовым.
  @State private var isCustomVolume = false

  var body: some View {
    if let compactTrailing {
      compactGrid(trailing: compactTrailing)
    } else {
      profilePicker
      formatPicker
      levelPicker
      solidToggle
      fileNameEncryptionToggle
      volumePicker
      if showsCustomVolume { customVolumeField }
    }
  }

  /// Одна сетка вместо двух независимых форм: строки обеих колонок стоят на одной высоте,
  /// а у полей постоянная ширина, поэтому блок не шире панели сохранения при любом языке.
  private func compactGrid(trailing: [CompactSettingsRow]) -> some View {
    // Строка своего размера занята всегда, чтобы высота панели сохранения не прыгала.
    let customVolume = CompactSettingsRow(
      L10n.tr("Размер тома, МБ"), hidden: !showsCustomVolume,
      customVolumeField.disabled(!showsCustomVolume))
    let leading = [
      CompactSettingsRow(L10n.tr("Профиль"), profilePicker),
      CompactSettingsRow(formatTitle, formatPicker),
      CompactSettingsRow(levelTitle, levelPicker),
      CompactSettingsRow(L10n.tr("Размер тома"), volumePicker),
      customVolume,
    ]
    let right =
      trailing + [
        CompactSettingsRow(nil, solidToggle), CompactSettingsRow(nil, fileNameEncryptionToggle),
      ]
    return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
      ForEach(0..<max(leading.count, right.count), id: \.self) { index in
        GridRow(alignment: .firstTextBaseline) {
          compactCells(index < leading.count ? leading[index] : nil)
          compactCells(index < right.count ? right[index] : nil, gap: 16)
        }
      }
    }
  }

  /// Подпись и поле одной колонки. Подписанные поля прячут свою подпись и получают общую
  /// ширину; флажок без подписи оставляет свой текст и встаёт в колонку полей.
  @ViewBuilder
  private func compactCells(_ row: CompactSettingsRow?, gap: CGFloat = 0) -> some View {
    Text(row?.title ?? "")
      .padding(.leading, gap)
      .gridColumnAlignment(.trailing)
      .opacity(row?.hidden == true ? 0 : 1)
      .accessibilityHidden(row?.title == nil || row?.hidden == true)
    if let row, row.title != nil {
      row.control
        .labelsHidden()
        .frame(width: CompactSettingsRow.controlWidth)
        .opacity(row.hidden ? 0 : 1)
        .accessibilityHidden(row.hidden)
    } else if let row {
      row.control.fixedSize()
    } else {
      Color.clear.frame(width: CompactSettingsRow.controlWidth, height: 0)
    }
  }

  private var profilePicker: some View {
    Picker(L10n.tr("Профиль"), selection: profileSelection) {
      ForEach(CompressionProfile.builtIn) { Text($0.title).tag($0.id) }
      Text(CompressionProfile.title(for: CompressionProfile.customID))
        .tag(CompressionProfile.customID)
    }
  }

  private var formatPicker: some View {
    Picker(formatTitle, selection: manual($format)) {
      ForEach(CompressionOptions.supportedFormats, id: \.self) {
        Text(ArchiveFormatPresentation.title(for: $0)).tag($0)
      }
    }
  }

  private var levelPicker: some View {
    Picker(levelTitle, selection: manual($level)) {
      Text(L10n.tr("Без сжатия")).tag(0)
      Text(L10n.tr("Быстрая")).tag(1)
      Text(L10n.tr("Обычная")).tag(5)
      Text(L10n.tr("Максимальная")).tag(7)
      Text(L10n.tr("Ультра")).tag(9)
    }
    .disabled(!CompressionOptions.supportsLevel(format))
  }

  private var solidToggle: some View {
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
  }

  private var fileNameEncryptionToggle: some View {
    Toggle(L10n.tr("Шифровать имена файлов"), isOn: manual($encryptsFileNames))
      .help(
        L10n.tr("Для 7z с паролем: скрывает не только содержимое, но и список файлов в архиве.")
      )
      .disabled(!CompressionOptions.supportsFileNameEncryption(format))
  }

  private var volumePicker: some View {
    Picker(L10n.tr("Размер тома"), selection: volumeSelection) {
      Text(L10n.tr("Один файл")).tag(0)
      ForEach(Self.volumePresets, id: \.size) { preset in
        Text(Self.volumeTitle(preset.size, note: preset.note)).tag(preset.size)
      }
      Text(L10n.tr("Другой размер…")).tag(Self.customVolumeTag)
    }
    .disabled(!CompressionOptions.supportsVolumes(format))
  }

  private var customVolumeField: some View {
    TextField(L10n.tr("Размер тома, МБ"), value: customVolumeSize, format: .number)
      .disabled(!CompressionOptions.supportsVolumes(format))
  }

  private static var solidHelp: String {
    L10n.tr(
      "Сжимает файлы вместе: архив обычно меньше, но извлечение одного файла может занять больше времени."
    )
  }

  private static func volumeTitle(_ size: Int, note: String?) -> String {
    let title = L10n.tr("%1$@ МБ", size.formatted())
    return note.map { title + " (" + $0 + ")" } ?? title
  }

  /// Поле своего размера видно и для значения не из списка — из профиля или старых настроек.
  private var showsCustomVolume: Bool {
    isCustomVolume
      || (volumeSizeMB > 0 && !Self.volumePresets.contains { $0.size == volumeSizeMB })
  }

  private var volumeSelection: Binding<Int> {
    Binding(
      get: { showsCustomVolume ? Self.customVolumeTag : volumeSizeMB },
      set: { choice in
        isCustomVolume = choice == Self.customVolumeTag
        if !isCustomVolume {
          manual($volumeSizeMB).wrappedValue = choice
        } else if volumeSizeMB == 0 {
          manual($volumeSizeMB).wrappedValue = 100
        }
      })
  }

  /// Свой размер держится в допустимых пределах: ноль означал бы «один файл».
  private var customVolumeSize: Binding<Int> {
    Binding(
      get: { volumeSizeMB },
      set: {
        manual($volumeSizeMB).wrappedValue = min(max(1, $0), CompressionOptions.maximumVolumeSizeMB)
      })
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

/// Строка компактной сетки параметров: подпись слева и элемент управления постоянной ширины.
/// Без подписи (флажок) элемент стоит в колонке полей под остальными.
struct CompactSettingsRow {
  /// Ширина полей и всплывающих меню: одинаковая, чтобы края колонки совпадали.
  static let controlWidth: CGFloat = 170
  let title: String?
  let hidden: Bool
  let control: AnyView

  init(_ title: String?, hidden: Bool = false, _ control: some View) {
    self.title = title
    self.hidden = hidden
    self.control = AnyView(control)
  }
}
