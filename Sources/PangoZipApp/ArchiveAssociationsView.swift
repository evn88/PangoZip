import PangoZipCore
import SwiftUI

struct ArchiveAssociationsView: View {
  @StateObject private var model = ArchiveAssociationsModel()

  var body: some View {
    Form {
      Section(L10n.tr("Типы архивов")) {
        Text(
          L10n.tr(
            "Выберите типы, для которых PangoZip станет приложением по умолчанию. Текущая программа указана справа."
          )
        )
        .font(.caption).foregroundStyle(.secondary)

        ForEach(model.rows) { row in
          Toggle(isOn: selection(for: row.type.identifier)) {
            HStack {
              Text(row.type.title)
              Spacer()
              Text(row.defaultApplicationName).foregroundStyle(.secondary)
            }
          }
          .accessibilityLabel(row.type.title)
          .accessibilityHint(row.defaultApplicationName)
          .disabled(model.isApplying)
        }

        if !model.isRunningFromApplications {
          Label(
            L10n.tr(
              "Запущена копия из папки сборки. macOS назначит обработчиком именно этот экземпляр; после его перемещения настройку придётся обновить."
            ),
            systemImage: "exclamationmark.triangle"
          )
          .font(.caption).foregroundStyle(.secondary)
        }

        Button(L10n.tr("Назначить PangoZip для выбранных типов")) {
          Task { await model.applySelection() }
        }
        .disabled(model.selectedTypeIdentifiers.isEmpty || model.isApplying)

        if let errorMessage = model.errorMessage {
          Text(errorMessage).foregroundStyle(.red).font(.caption)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: model.refresh)
  }

  private func selection(for identifier: String) -> Binding<Bool> {
    Binding(
      get: { model.selectedTypeIdentifiers.contains(identifier) },
      set: { isSelected in
        if isSelected {
          model.selectedTypeIdentifiers.insert(identifier)
        } else {
          model.selectedTypeIdentifiers.remove(identifier)
        }
      })
  }
}
