import AppKit
import PangoZipCore
import SwiftUI
import UniformTypeIdentifiers

struct ArchiveBrowserView: View {
  @ObservedObject var model: ArchiveBrowserModel
  @State private var isDropTargeted = false
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      archiveHeader
      Divider()
      HSplitView {
        archiveTable
          .frame(minWidth: 760, idealWidth: 1100, maxWidth: .infinity, maxHeight: .infinity)
        if model.showsPreview {
          preview
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 400, maxHeight: .infinity)
            .layoutPriority(-1)
        }
      }
      Divider()
      statusBar
    }
    .toolbar {
      ToolbarItemGroup(placement: .automatic) {
        Button("Открыть архив…", systemImage: "archivebox", action: model.chooseArchive)
          .labelStyle(.iconOnly)
          .help("Открыть архив (⌘O)").disabled(!model.canAct)
        Button("Закрыть архив", systemImage: "xmark.circle", action: model.closeArchive)
          .labelStyle(.iconOnly)
          .help("Закрыть архив (⌘W)")
          .disabled(model.session == nil && !model.isBusy || model.isClosing)
      }
      ToolbarSpacer(.fixed)
      ToolbarItemGroup(placement: .automatic) {
        Button("Добавить файлы и папки…", systemImage: "plus", action: model.chooseFilesToAdd)
          .labelStyle(.iconOnly)
          .help("Добавить файлы и папки (⌘⇧A)").disabled(!model.canModify)
        Button("Удалить выбранное…", systemImage: "trash", action: model.deleteSelected)
          .labelStyle(.iconOnly)
          .help("Удалить выбранное (⌘⌫)")
          .disabled(!model.canModify || model.selectedPaths.isEmpty)
      }
      ToolbarSpacer(.fixed)
      ToolbarItemGroup(placement: .automatic) {
        Button(
          "Открыть файл", systemImage: "arrow.up.forward.square",
          action: model.openSelectedExternally
        )
        .labelStyle(.iconOnly)
        .help("Открыть выбранный файл (⌘↩)").disabled(!model.canOpenSelection)
        Button("Редактировать файл", systemImage: "pencil", action: model.editSelected)
          .labelStyle(.iconOnly)
          .help("Открыть рабочую копию в редакторе (⌘E)")
          .disabled(!model.canModify || !model.canOpenSelection)
        Button(
          "Сохранить в архив", systemImage: "square.and.arrow.down", action: model.saveWorkingCopies
        )
        .labelStyle(.iconOnly)
        .help("Сначала сохраните файл в редакторе, затем нажмите ⌘S здесь")
        .disabled(!model.canModify || model.activeEdits.isEmpty)
      }
      ToolbarSpacer(.flexible)
      ToolbarItem(placement: .automatic) {
        Button(
          model.showsPreview ? "Скрыть предпросмотр" : "Показать предпросмотр",
          systemImage: "sidebar.right", action: model.togglePreview
        )
        .labelStyle(.iconOnly)
        .help("Переключить предпросмотр (⌘⇧P)")
      }
    }
    .onExitCommand { model.cancelCurrentOperation() }
    .onChange(of: model.searchFocusToken) { _, _ in searchFocused = true }
    .sheet(isPresented: $model.isPasswordPromptPresented) { passwordSheet }
    .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: 12)
          .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [9]))
          .padding(8).allowsHitTesting(false)
      }
    }
  }

  private var archiveHeader: some View {
    HStack(spacing: 12) {
      Image(systemName: "archivebox")
        .foregroundStyle(.tint)
      if let session = model.session {
        Text(session.url.lastPathComponent).font(.headline).lineLimit(1)
        Text(session.format.uppercased()).foregroundStyle(.secondary)
        if !session.canModify { Text("Только чтение").foregroundStyle(.secondary) }
      } else {
        Text("PangoZip").font(.headline)
      }
      Spacer()
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Имя или путь в архиве", text: $model.searchText)
        .textFieldStyle(.roundedBorder)
        .frame(width: 280)
        .focused($searchFocused)
        .disabled(model.session == nil)
        .accessibilityLabel("Поиск в архиве")
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
  }

  @ViewBuilder
  private var archiveTable: some View {
    if model.session != nil {
      ArchiveOutlineView(model: model)
        .overlay {
          if model.visibleRoots.isEmpty {
            ContentUnavailableView(
              model.searchText.isEmpty ? "Архив пуст" : "Ничего не найдено",
              systemImage: "archivebox"
            )
            .allowsHitTesting(false)
          }
        }
    } else if model.loadState == .loading {
      VStack(spacing: 16) {
        ProgressView()
        Text("Читаем содержимое архива…")
        Button("Отмена", action: model.cancelCurrentOperation)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 16) {
        Image(systemName: "doc.zipper").font(.system(size: 46)).foregroundStyle(.secondary)
        Text("Откройте архив").font(.title2)
        Text("Перетащите архив в окно или выберите файл на диске.").foregroundStyle(.secondary)
        Button("Выбрать архив…", action: model.chooseArchive)
          .buttonStyle(.borderedProminent).disabled(!model.canAct)
        if let message = model.errorMessage {
          Text(message).foregroundStyle(.red).frame(maxWidth: 550).multilineTextAlignment(.center)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var preview: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Предпросмотр").font(.headline)
        Spacer()
        Button(action: model.togglePreview) { Image(systemName: "xmark") }
          .buttonStyle(.plain).help("Скрыть предпросмотр")
      }
      .padding(14)
      Divider()
      if let entry = model.selectedEntry {
        VStack(alignment: .leading, spacing: 5) {
          Text(entry.path).font(.callout).lineLimit(2).textSelection(.enabled)
          if model.activeEdits.contains(where: { $0.entry.path == entry.path }) {
            Text("Есть рабочая копия: сохраните файл в редакторе, затем нажмите ⌘S здесь.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        Divider()
        if let url = model.previewURL {
          QuickLookPreview(url: url).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isMaterializing {
          VStack(spacing: 12) {
            ProgressView()
            Text("Подготавливаем предпросмотр…").font(.callout).foregroundStyle(.secondary)
            Button("Отмена", action: model.cancelPreview)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ContentUnavailableView(
            entry.isDirectory ? "Папка" : "Предпросмотр недоступен",
            systemImage: entry.isDirectory ? "folder" : "doc"
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        ContentUnavailableView(
          model.selectedPaths.count > 1 ? "Выбрано несколько объектов" : "Выберите файл",
          systemImage: "doc.text.magnifyingglass"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(.background)
  }

  private var statusBar: some View {
    HStack(spacing: 14) {
      if model.isBusy || model.isExporting || model.isClosing {
        if let progress = model.operationProgress {
          OperationProgressView(progress: progress).frame(width: 220)
        } else {
          ProgressView().controlSize(.small)
        }
        Text(model.isClosing ? "Закрываем архив…" : model.operationMessage ?? "Выполняем операцию…")
        Button("Отмена", action: model.cancelCurrentOperation).disabled(model.isClosing)
      } else if let message = model.errorMessage {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        Text(message).textSelection(.enabled)
        Button("Повторить", action: model.retryWithPassword)
      } else if let message = model.operationMessage {
        Text(message).lineLimit(1)
      } else if let session = model.session {
        Text("Объектов: \(session.entries.count)")
        Text("Выбрано: \(model.selectedPaths.count)")
      } else {
        Text("Готово")
      }
      Spacer()
      if !model.activeEdits.isEmpty {
        Text("Рабочих копий: \(model.activeEdits.count). Для записи в архив нажмите ⌘S.")
          .foregroundStyle(.tint)
      }
    }
    .font(.caption).foregroundStyle(.secondary)
    .padding(.horizontal, 14).padding(.vertical, 8)
  }

  private var passwordSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Пароль архива", systemImage: "lock.fill").font(.title3.weight(.semibold))
      Text(model.errorMessage ?? "Введите пароль для продолжения операции.")
        .font(.callout).foregroundStyle(.secondary)
      SecureField("Пароль", text: $model.password)
        .textFieldStyle(.roundedBorder).onSubmit { model.retryWithPassword() }
      HStack {
        Spacer()
        Button("Отмена", role: .cancel, action: model.cancelPasswordPrompt)
          .keyboardShortcut(.cancelAction)
        Button("Продолжить", action: model.retryWithPassword)
          .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
      }
    }
    .padding(24).frame(width: 400)
  }

  private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    guard model.canAct, model.session == nil, providers.count == 1, let provider = providers.first
    else { return false }
    _ = provider.loadObject(ofClass: URL.self) { url, _ in
      guard let url else { return }
      Task { @MainActor in model.open(url) }
    }
    return true
  }
}
