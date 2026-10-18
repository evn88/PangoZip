import AppKit
import PangoZipCore
import SwiftUI

enum ArchiveColumn: String, CaseIterable, Identifiable {
  case name, size, kind, compression, modified, packed, method, created, permissions, owner, group
  case encrypted, checksum, path, specialFile, fileCount, folderCount
  case accessed, attributes, hostOS, version, volumeIndex, offset, block, symbolicLink, hardLink
  case comment, userID, groupID, otherMetadata

  var id: String { rawValue }

  var title: String {
    switch self {
    case .name: L10n.tr("Имя")
    case .size: L10n.tr("Размер")
    case .kind: L10n.tr("Тип")
    case .compression: L10n.tr("Сжатие")
    case .modified: L10n.tr("Изменён")
    case .packed: L10n.tr("В архиве")
    case .method: L10n.tr("Метод")
    case .created: L10n.tr("Создан")
    case .permissions: L10n.tr("Права доступа")
    case .owner: L10n.tr("Владелец")
    case .group: L10n.tr("Группа")
    case .encrypted: L10n.tr("Шифрование")
    case .checksum: "CRC"
    case .path: L10n.tr("Путь в архиве")
    case .specialFile: L10n.tr("Ссылка или специальный файл")
    case .fileCount: L10n.tr("Вложенных файлов")
    case .folderCount: L10n.tr("Вложенных папок")
    case .accessed: L10n.tr("Последний доступ")
    case .attributes: L10n.tr("Атрибуты")
    case .hostOS: L10n.tr("ОС создания")
    case .version: L10n.tr("Версия формата")
    case .volumeIndex: L10n.tr("Номер тома")
    case .offset: L10n.tr("Смещение")
    case .block: L10n.tr("Блок")
    case .symbolicLink: L10n.tr("Цель символической ссылки")
    case .hardLink: L10n.tr("Цель жёсткой ссылки")
    case .comment: L10n.tr("Комментарий")
    case .userID: L10n.tr("ID пользователя")
    case .groupID: L10n.tr("ID группы")
    case .otherMetadata: L10n.tr("Другие метаданные")
    }
  }

  var metadataKey: String? {
    switch self {
    case .accessed: "Accessed"
    case .attributes: "Attributes"
    case .hostOS: "Host OS"
    case .version: "Version"
    case .volumeIndex: "Volume Index"
    case .offset: "Offset"
    case .block: "Block"
    case .symbolicLink: "Symbolic Link"
    case .hardLink: "Hard Link"
    case .comment: "Comment"
    case .userID: "User ID"
    case .groupID: "Group ID"
    default: nil
    }
  }

  var width: CGFloat {
    switch self {
    case .name: 340
    case .size: 90
    case .kind, .modified, .created, .permissions: 150
    case .path, .symbolicLink, .hardLink, .comment, .otherMetadata: 280
    case .accessed, .attributes: 180
    case .specialFile: 200
    case .fileCount, .folderCount: 140
    default: 100
    }
  }

  var isNumeric: Bool {
    [
      .size, .packed, .compression, .fileCount, .folderCount, .volumeIndex, .offset, .block,
      .userID,
      .groupID,
    ].contains(self)
  }
}

@MainActor
final class ArchiveColumnSettings: ObservableObject {
  static let shared = ArchiveColumnSettings()
  static let storageKey = "archiveVisibleColumns"
  static let defaultColumns: Set<ArchiveColumn> = [.name, .size, .kind, .compression, .modified]
  @Published private(set) var visibleColumns: Set<ArchiveColumn>
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let stored = defaults.stringArray(forKey: Self.storageKey) {
      visibleColumns = Set(stored.compactMap(ArchiveColumn.init(rawValue:))).union([.name])
    } else {
      visibleColumns = Self.defaultColumns
    }
  }

  func isVisible(_ column: ArchiveColumn) -> Bool { visibleColumns.contains(column) }

  func setVisible(_ visible: Bool, for column: ArchiveColumn) {
    guard column != .name else { return }
    if visible { visibleColumns.insert(column) } else { visibleColumns.remove(column) }
    defaults.set(ArchiveColumn.allCases.filter(isVisible).map(\.rawValue), forKey: Self.storageKey)
  }

  func reset() {
    visibleColumns = Self.defaultColumns
    defaults.removeObject(forKey: Self.storageKey)
  }
}

struct ArchiveColumnsMenu: View {
  @ObservedObject var settings: ArchiveColumnSettings = .shared

  var body: some View {
    Menu {
      ForEach(ArchiveColumn.allCases) { column in
        Toggle(
          column.title,
          isOn: Binding(
            get: { settings.isVisible(column) },
            set: { settings.setVisible($0, for: column) })
        ).disabled(column == .name)
      }
      Divider()
      Button(L10n.tr("Стандартные колонки")) { settings.reset() }
    } label: {
      Label(L10n.tr("Колонки"), systemImage: "tablecells")
    }
    .help(L10n.tr("Показать или скрыть колонки"))
  }
}
