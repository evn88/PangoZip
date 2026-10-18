import PangoZipCore
import SwiftUI

struct ArchiveCommands: Commands {
  @ObservedObject var model: ArchiveBrowserModel

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button(L10n.tr("Открыть архив…"), action: model.chooseArchive)
        .keyboardShortcut("o", modifiers: .command)
        .disabled(!model.canAct)
    }
    CommandGroup(replacing: .saveItem) {
      Button(L10n.tr("Сохранить в архив"), action: model.saveWorkingCopies)
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!model.canModify || model.activeEdits.isEmpty)
    }
    CommandGroup(before: .windowArrangement) {
      Button(L10n.tr("Закрыть архив"), action: model.closeArchive)
        .keyboardShortcut("w", modifiers: .command)
        .disabled(model.session == nil && !model.isBusy || model.isClosing)
    }
    CommandMenu(L10n.tr("Архив")) {
      Button(L10n.tr("Назад"), action: model.navigateBack)
        .keyboardShortcut("[", modifiers: .command)
        .disabled(!model.canNavigateBack)
      Button(L10n.tr("Откатить последнее изменение архива"), action: model.undoLastChange)
        .keyboardShortcut("z", modifiers: [.command, .option])
        .disabled(!model.canUndoLastChange)
      Divider()

      Button(L10n.tr("Добавить файлы и папки…"), action: model.chooseFilesToAdd)
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .disabled(!model.canQueueModifications)
      Button(L10n.tr("Извлечь выбранное…"), action: model.extractSelected)
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(!model.canQueueOperations || model.selectedPaths.isEmpty)
      Button(L10n.tr("Удалить выбранное…"), action: model.deleteSelected)
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(!model.canQueueModifications || model.selectedPaths.isEmpty)
      Divider()
      Button(L10n.tr("Открыть выбранный файл"), action: model.openSelectedExternally)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!model.canOpenSelection)
      Button(L10n.tr("Редактировать файл"), action: model.editSelected)
        .keyboardShortcut("e", modifiers: .command)
        .disabled(!model.canModify || !model.canOpenSelection)
      Divider()
      Button(
        model.showsPreview ? L10n.tr("Скрыть предпросмотр") : L10n.tr("Показать предпросмотр"),
        action: model.togglePreview
      )
      .keyboardShortcut("p", modifiers: [.command, .shift])
      Button(L10n.tr("Поиск в архиве"), action: model.focusSearch)
        .keyboardShortcut("f", modifiers: .command)
    }
  }
}
