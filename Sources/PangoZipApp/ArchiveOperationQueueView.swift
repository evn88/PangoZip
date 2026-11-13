import PangoZipCore
import SwiftUI

struct ArchiveOperationQueueView: View {
  @ObservedObject var model: ArchiveBrowserModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L10n.tr("Очередь операций")).font(.headline)
      if model.isBusy || model.isExporting {
        currentOperation
      }
      if model.queuedOperations.isEmpty {
        if !model.isBusy && !model.isExporting {
          Text(L10n.tr("Нет ожидающих операций")).foregroundStyle(.secondary)
        }
      } else {
        Text(L10n.tr("В очереди")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
    .padding(16).frame(width: 440)
  }

  /// Единственное место с полосой прогресса: название операции, ход и отмена.
  private var currentOperation: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(model.operationMessage ?? L10n.tr("Выполняем операцию…"))
          .font(.callout.weight(.semibold)).lineLimit(2).truncationMode(.middle)
        Spacer(minLength: 4)
        Button(L10n.tr("Отмена"), action: model.cancelCurrentOperation)
          .controlSize(.small)
      }
      if let progress = model.operationProgress {
        OperationProgressView(progress: progress, isCompact: true).tint(Brand.goldInk)
      } else {
        ProgressView().progressViewStyle(.linear).tint(Brand.goldInk)
      }
    }
    .padding(12)
    .background(Brand.surface, in: RoundedRectangle(cornerRadius: 12))
  }
}
