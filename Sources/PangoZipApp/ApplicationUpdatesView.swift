import PangoZipCore
import SwiftUI

struct ApplicationUpdatesView: View {
  @Bindable var updater: ApplicationUpdater

  var body: some View {
    Form {
      Section(L10n.tr("Обновления")) {
        Toggle(
          L10n.tr("Автоматически проверять обновления"),
          isOn: $updater.automaticallyChecksForUpdates
        )
        .disabled(updater.isInstalling)
        Text(
          L10n.tr(
            "Новые версии загружаются из GitHub Releases. Перед установкой PangoZip проверяет цифровую подпись и предлагает перезапуск."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
        Button(L10n.tr("Проверить обновления…"), action: updater.checkForUpdates)
          .disabled(!updater.canCheckForUpdates || updater.isInstalling)
        if updater.isInstalling {
          ProgressView(L10n.tr("Установка обновления…"))
        }
        if let error = updater.lastError {
          Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
      }
    }.formStyle(.grouped)
  }
}
