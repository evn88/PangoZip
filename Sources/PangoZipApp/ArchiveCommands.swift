import AppKit
import PangoZipCore
import SwiftUI

struct ArchiveCommands: Commands {
  @ObservedObject var model: ArchiveBrowserModel
  @FocusedValue(\.dismissAboutWindow) private var dismissAboutWindow
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button(L10n.tr("Новый архив…")) {
        // Окно могло быть закрыто, пока PangoZip работает в фоне ради острова.
        openWindow(id: "main")
        model.newArchive()
      }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(!model.canStartNewArchive)
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
      if let dismissAboutWindow {
        Button(L10n.tr("Закрыть")) { dismissAboutWindow() }
          .keyboardShortcut("w", modifiers: .command)
      } else {
        Button(L10n.tr("Закрыть архив"), action: model.closeArchive)
          .keyboardShortcut("w", modifiers: .command)
          .disabled(!model.canCloseArchive)
      }
    }
    CommandGroup(replacing: .help) {
      Button(L10n.tr("Сайт PangoZip")) { NSWorkspace.shared.open(SupportConfiguration.websiteURL) }
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
        .disabled(!model.canAddFiles)
      Button(L10n.tr("Извлечь выбранное…"), action: model.extractSelected)
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(!model.canQueueOperations || model.selectedPaths.isEmpty)
      Button(
        model.isDrafting ? L10n.tr("Убрать из списка") : L10n.tr("Удалить выбранное…"),
        action: model.deleteSelected
      )
      .keyboardShortcut(.delete, modifiers: .command)
      .disabled(!model.canRemoveSelection)
      Divider()
      Button(L10n.tr("Проверить архив"), action: model.verifyArchive)
        .keyboardShortcut("t", modifiers: [.command, .option])
        .disabled(!model.canQueueOperations)
      Button(L10n.tr("Контрольные суммы…"), action: model.showChecksums)
        .keyboardShortcut("k", modifiers: [.command, .option])
        .disabled(!model.canAct || model.session == nil)
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
