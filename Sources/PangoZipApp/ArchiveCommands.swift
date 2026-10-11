import SwiftUI

struct ArchiveCommands: Commands {
  @ObservedObject var model: ArchiveBrowserModel

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("Открыть архив…", action: model.chooseArchive)
        .keyboardShortcut("o", modifiers: .command)
        .disabled(!model.canAct)
    }
    CommandGroup(replacing: .saveItem) {
      Button("Сохранить в архив", action: model.saveWorkingCopies)
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!model.canModify || model.activeEdits.isEmpty)
    }
    CommandGroup(before: .windowArrangement) {
      Button("Закрыть архив", action: model.closeArchive)
        .keyboardShortcut("w", modifiers: .command)
        .disabled(model.session == nil && !model.isBusy || model.isClosing)
    }
    CommandMenu("Архив") {
      Button("Добавить файлы и папки…", action: model.chooseFilesToAdd)
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .disabled(!model.canModify)
      Button("Извлечь выбранное…", action: model.extractSelected)
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(!model.canAct || model.selectedPaths.isEmpty)
      Button("Удалить выбранное…", action: model.deleteSelected)
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(!model.canModify || model.selectedPaths.isEmpty)
      Divider()
      Button("Открыть выбранный файл", action: model.openSelectedExternally)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!model.canOpenSelection)
      Button("Редактировать файл", action: model.editSelected)
        .keyboardShortcut("e", modifiers: .command)
        .disabled(!model.canModify || !model.canOpenSelection)
      Divider()
      Button(
        model.showsPreview ? "Скрыть предпросмотр" : "Показать предпросмотр",
        action: model.togglePreview
      )
      .keyboardShortcut("p", modifiers: [.command, .shift])
      Button("Поиск в архиве", action: model.focusSearch)
        .keyboardShortcut("f", modifiers: .command)
    }
  }
}
