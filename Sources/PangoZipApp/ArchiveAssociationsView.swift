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
          Toggle(isOn: isDefault(row)) {
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

        Button(L10n.tr("Назначить PangoZip для всех типов")) {
          Task { await model.assignAll() }
        }
        .disabled(model.areAllAssigned || model.isApplying)

        if !model.isRunningFromApplications {
          Label(
            L10n.tr(
              "Запущена копия из папки сборки. macOS назначит обработчиком именно этот экземпляр; после его перемещения настройку придётся обновить."
            ),
            systemImage: "exclamationmark.triangle"
          )
          .font(.caption).foregroundStyle(.secondary)
        }

        if let errorMessage = model.errorMessage {
          Text(errorMessage).foregroundStyle(.red).font(.caption)
        }
      }

      Section(L10n.tr("Снимки настроек")) {
        Text(
          L10n.tr(
            "PangoZip запомнил программы для архивов при первом запуске. К исходным настройкам и к любому из десяти последних снимков можно вернуться в любой момент."
          )
        )
        .font(.caption).foregroundStyle(.secondary)

        ForEach(model.snapshots) { snapshot in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              let date = snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)
              Text(snapshot.isInitial ? L10n.tr("Исходные настройки") : date)
              if snapshot.isInitial {
                Text(date).font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer()
            Button(L10n.tr("Вернуть")) { Task { await model.restore(snapshot) } }
              .disabled(model.isApplying)
          }
          .accessibilityElement(children: .combine)
        }

        Button(L10n.tr("Сохранить снимок"), action: model.saveSnapshot)
          .disabled(model.isApplying)
      }
    }
    .formStyle(.grouped)
    .onAppear {
      model.captureInitialSnapshotIfNeeded()
      model.refresh()
    }
  }

  /// Переключатель показывает системное назначение и меняет его сразу, без отдельной кнопки.
  private func isDefault(_ row: ArchiveAssociationsModel.Row) -> Binding<Bool> {
    Binding(
      get: { row.isPangoZipDefault },
      set: { isEnabled in Task { await model.setPangoZipDefault(isEnabled, for: row.type) } })
  }
}
