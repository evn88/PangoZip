import PangoZipCore
import SwiftUI

struct ArchiveMetadataView: View {
  let details: ArchiveItemDetails

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
      field(L10n.tr("Тип"), details.entry.isDirectory ? L10n.tr("Папка") : L10n.tr("Файл"))
      if details.entry.isSymbolicLink {
        field(L10n.tr("Особенность"), L10n.tr("Ссылка или специальный файл"))
      }
      field(
        details.entry.isDirectory ? L10n.tr("Размер содержимого") : L10n.tr("Размер без сжатия"),
        details.size.map {
          L10n.tr(
            "%1$@ (%2$@ Б)", String(describing: ProgressFormatting.bytes($0)),
            String(describing: $0.formatted()))
        }
          ?? L10n.tr("Не удалось подсчитать"))
      if details.entry.isDirectory {
        field(L10n.tr("Файлов"), details.fileCount.formatted())
        field(L10n.tr("Вложенных папок"), details.folderCount.formatted())
      }
      if !details.entry.isDirectory, let packedSize = details.entry.packedSize {
        field(L10n.tr("Размер в архиве"), ProgressFormatting.bytes(packedSize))
      }
      field(
        L10n.tr("Создан"),
        details.entry.createdAt?.formatted(date: .abbreviated, time: .shortened)
          ?? L10n.tr("Не указано"))
      field(
        L10n.tr("Изменён"),
        details.entry.modifiedAt?.formatted(date: .abbreviated, time: .shortened)
          ?? L10n.tr("Не указано"))
      if let permissions = details.entry.permissions {
        field(L10n.tr("Права доступа"), permissions)
      }
      if let owner = details.entry.owner { field(L10n.tr("Владелец"), owner) }
      if let group = details.entry.group { field(L10n.tr("Группа"), group) }
      if details.entry.isEncrypted { field(L10n.tr("Шифрование"), L10n.tr("Да")) }
      if let method = details.entry.method { field(L10n.tr("Метод сжатия"), method) }
      if let checksum = details.entry.checksum { field("CRC", checksum) }
    }
    .font(.callout)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func field(_ title: String, _ value: String) -> some View {
    GridRow(alignment: .top) {
      Text(title).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
  }
}
