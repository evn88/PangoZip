import SwiftUI

struct ArchiveMetadataView: View {
  let details: ArchiveItemDetails

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
      field("Тип", details.entry.isDirectory ? "Папка" : "Файл")
      if details.entry.isSymbolicLink { field("Особенность", "Ссылка или специальный файл") }
      field(
        details.entry.isDirectory ? "Размер содержимого" : "Размер без сжатия",
        details.size.map { "\(ProgressFormatting.bytes($0)) (\($0.formatted()) Б)" }
          ?? "Не удалось подсчитать")
      if details.entry.isDirectory {
        field("Файлов", details.fileCount.formatted())
        field("Вложенных папок", details.folderCount.formatted())
      }
      if !details.entry.isDirectory, let packedSize = details.entry.packedSize {
        field("Размер в архиве", ProgressFormatting.bytes(packedSize))
      }
      field(
        "Создан",
        details.entry.createdAt?.formatted(date: .abbreviated, time: .shortened)
          ?? "Не указано")
      field(
        "Изменён",
        details.entry.modifiedAt?.formatted(date: .abbreviated, time: .shortened)
          ?? "Не указано")
      if let permissions = details.entry.permissions { field("Права доступа", permissions) }
      if let owner = details.entry.owner { field("Владелец", owner) }
      if let group = details.entry.group { field("Группа", group) }
      if details.entry.isEncrypted { field("Шифрование", "Да") }
      if let method = details.entry.method { field("Метод сжатия", method) }
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
