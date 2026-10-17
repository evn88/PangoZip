import AppKit
import PangoZipCore
import SwiftUI
import UniformTypeIdentifiers

struct ArchiveBrowserView: View {
  @ObservedObject var model: ArchiveBrowserModel
  @ObservedObject var integration: FinderIntegrationModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isDropTargeted = false
  @State private var showsMetadata = false
  @FocusState private var searchFocused: Bool

  var body: some View {
    ArchiveSplitView(
      showsPreview: model.showsPreview, reduceMotion: reduceMotion,
      content: archiveContent, preview: preview
    )
    .navigationTitle(model.session?.url.lastPathComponent ?? "PangoZip")
    .navigationSubtitle(
      model.session.map { $0.format.uppercased() + ($0.canModify ? "" : " — Только чтение") } ?? ""
    )
    .searchable(text: $model.searchText, placement: .toolbar, prompt: "Имя или путь в архиве")
    .searchFocused($searchFocused)
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
      ToolbarItem(placement: .automatic) {
        Button("Извлечь…", systemImage: "arrow.up.bin", action: model.extractSelected)
          .labelStyle(.titleAndIcon)
          .help("Извлечь выбранные файлы и папки (⌘⇧E)")
          .disabled(!model.canAct || model.selectedPaths.isEmpty)
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

  private var archiveContent: some View {
    VStack(spacing: 0) {
      FinderIntegrationBanner(model: integration)
      archiveTable
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      statusBar
    }
  }

  @ViewBuilder
  private var archiveTable: some View {
    if model.session != nil {
      ArchiveOutlineView(model: model)
        .overlay {
          if model.visibleRoots.isEmpty {
            ContentUnavailableView(
              model.searchText.isEmpty ? "Архив пуст" : "Ничего не найдено",
              systemImage: model.searchText.isEmpty ? "archivebox" : "magnifyingglass",
              description: Text(
                model.searchText.isEmpty
                  ? "В этом архиве пока нет файлов."
                  : "Попробуйте другое имя или путь в архиве."
              )
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
      ContentUnavailableView {
        Label("Откройте архив", systemImage: "doc.zipper")
      } description: {
        Text("Перетащите архив в окно, чтобы просмотреть и извлечь файлы.")
      } actions: {
        Button("Выбрать архив…", action: model.chooseArchive)
          .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canAct)
        if let message = model.errorMessage {
          Text(message).foregroundStyle(.red).frame(maxWidth: 550).multilineTextAlignment(.center)
        }
      }
    }
  }

  private var preview: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Предпросмотр").font(.headline)
        Spacer()
        Button("Скрыть предпросмотр", systemImage: "xmark", action: model.togglePreview)
          .labelStyle(.iconOnly).buttonStyle(.borderless)
          .help("Скрыть предпросмотр (⌘⇧P)")
      }
      .padding(14)
      Divider()
      if let details = model.selectedItemDetails {
        let entry = details.entry
        VStack(alignment: .leading, spacing: 5) {
          Text(URL(fileURLWithPath: entry.path).lastPathComponent)
            .font(.headline).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
          Text(entry.path).font(.caption).foregroundStyle(.secondary)
            .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(entry.path)
          if !entry.isDirectory {
            Text(ProgressFormatting.bytes(entry.size))
              .font(.caption).foregroundStyle(.secondary).monospacedDigit()
          }
          if model.activeEdits.contains(where: { $0.entry.path == entry.path }) {
            Text("Есть рабочая копия: сохраните файл в редакторе, затем нажмите ⌘S здесь.")
              .font(.caption).foregroundStyle(.secondary)
          }
          if !entry.isDirectory {
            DisclosureGroup("Сведения", isExpanded: $showsMetadata) {
              ScrollView {
                ArchiveMetadataView(details: details).padding(.top, 8)
              }
              .frame(maxHeight: 240)
            }
            .padding(.top, 8)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        Divider()
        if entry.isDirectory {
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
              Label("Папка", systemImage: "folder")
                .font(.title3).foregroundStyle(.secondary)
              ArchiveMetadataView(details: details)
              Text("Размер без сжатия и количество объектов включают все вложенные папки.")
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let url = model.previewURL {
          QuickLookPreview(url: url).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isMaterializing {
          VStack(spacing: 12) {
            ProgressView()
            Text("Подготавливаем предпросмотр…").font(.callout).foregroundStyle(.secondary)
            Button("Отмена") { model.cancelPreview() }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ContentUnavailableView("Предпросмотр недоступен", systemImage: "doc")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        ContentUnavailableView(
          model.selectedPaths.count > 1 ? "Выбрано несколько объектов" : "Выберите файл",
          systemImage: "doc.text.magnifyingglass",
          description: Text("Предпросмотр появится здесь без извлечения всего архива.")
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
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            if model.operationProgress == nil { ProgressView().controlSize(.small) }
            Text(
              model.isClosing ? "Закрываем архив…" : model.operationMessage ?? "Выполняем операцию…"
            )
            .lineLimit(1)
            Spacer()
            Button("Отмена", action: model.cancelCurrentOperation).disabled(model.isClosing)
          }
          if let progress = model.operationProgress {
            OperationProgressView(progress: progress).frame(maxWidth: 620, alignment: .leading)
          }
        }
      } else if let message = model.errorMessage {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        Text(message).textSelection(.enabled).lineLimit(3).help(message)
        Button("Повторить", action: model.retryWithPassword)
      } else if let message = model.operationMessage {
        Text(message).lineLimit(1)
      } else if let session = model.session {
        Text("Объектов: \(session.entries.count)").monospacedDigit()
        Text("Выбрано: \(model.selectedPaths.count)").monospacedDigit()
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
    .padding(.horizontal, 16).padding(.vertical, 10)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var passwordSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Пароль архива", systemImage: "lock.fill").font(.title3.weight(.semibold))
      Text(model.errorMessage ?? "Введите пароль для продолжения операции.")
        .font(.callout).foregroundStyle(.secondary)
      SecureField("Пароль", text: $model.password)
        .textFieldStyle(.roundedBorder).onSubmit { model.retryWithPassword() }
        .accessibilityLabel("Пароль архива")
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

  /// Принимает один архив только без открытого сеанса; загрузка URL завершается асинхронно.
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
