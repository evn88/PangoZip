import PangoZipCore
import SwiftUI

struct ArchiveOperationQueueView: View {
  @ObservedObject var model: ArchiveBrowserModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L10n.tr("Очередь операций")).font(.headline)
      if model.isBusy {
        Label(
          model.operationMessage ?? L10n.tr("Выполняем операцию…"),
          systemImage: "arrow.triangle.2.circlepath"
        )
        .font(.callout).lineLimit(2)
        Button(L10n.tr("Отмена"), action: model.cancelCurrentOperation)
      }
      if model.queuedOperations.isEmpty {
        Text(L10n.tr("Нет ожидающих операций")).foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(model.queuedOperations) { item in
              HStack(spacing: 10) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text(item.title).lineLimit(2).truncationMode(.middle).help(item.title)
                Spacer(minLength: 4)
                Button(L10n.tr("Убрать из очереди"), systemImage: "xmark") {
                  model.removeQueuedOperation(item.id)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
              }
            }
          }
        }.frame(maxHeight: 280)
        Divider()
        HStack {
          Button(L10n.tr("Очистить очередь"), action: model.clearQueuedOperations)
          Spacer()
          if model.isQueuePaused {
            Button(L10n.tr("Продолжить очередь"), action: model.resumeQueuedOperations)
              .disabled(!model.canAct)
          }
        }
      }
    }
    .padding(16).frame(width: 360)
  }
}
