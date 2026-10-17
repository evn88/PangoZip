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
      model.session.map {
        $0.format.uppercased() + ($0.canModify ? "" : L10n.tr(" — Только чтение"))
      } ?? ""
    )
    .searchable(
      text: $model.searchText, placement: .toolbar, prompt: L10n.tr("Имя или путь в архиве")
    )
    .searchFocused($searchFocused)
    .toolbar {
      ToolbarItemGroup(placement: .automatic) {
        Button(L10n.tr("Открыть архив…"), systemImage: "archivebox", action: model.chooseArchive)
          .labelStyle(.iconOnly)
          .help(L10n.tr("Открыть архив (⌘O)")).disabled(!model.canAct)
        Button(L10n.tr("Закрыть архив"), systemImage: "xmark.circle", action: model.closeArchive)
          .labelStyle(.iconOnly)
          .help(L10n.tr("Закрыть архив (⌘W)"))
          .disabled(model.session == nil && !model.isBusy || model.isClosing)
      }
      ToolbarSpacer(.fixed)
      ToolbarItem(placement: .automatic) {
        Button(L10n.tr("Извлечь…"), systemImage: "arrow.up.bin", action: model.extractSelected)
          .labelStyle(.titleAndIcon)
          .help(L10n.tr("Извлечь выбранные файлы и папки (⌘⇧E)"))
          .disabled(!model.canAct || model.selectedPaths.isEmpty)
      }
      ToolbarSpacer(.fixed)
      ToolbarItemGroup(placement: .automatic) {
        Button(
          L10n.tr("Добавить файлы и папки…"), systemImage: "plus", action: model.chooseFilesToAdd
        )
        .labelStyle(.iconOnly)
        .help(L10n.tr("Добавить файлы и папки (⌘⇧A)")).disabled(!model.canModify)
        Button(L10n.tr("Удалить выбранное…"), systemImage: "trash", action: model.deleteSelected)
          .labelStyle(.iconOnly)
          .help(L10n.tr("Удалить выбранное (⌘⌫)"))
          .disabled(!model.canModify || model.selectedPaths.isEmpty)
      }
      ToolbarSpacer(.fixed)
      ToolbarItemGroup(placement: .automatic) {
        Button(
          L10n.tr("Открыть файл"), systemImage: "arrow.up.forward.square",
          action: model.openSelectedExternally
        )
        .labelStyle(.iconOnly)
        .help(L10n.tr("Открыть выбранный файл (⌘↩)")).disabled(!model.canOpenSelection)
        Button(L10n.tr("Редактировать файл"), systemImage: "pencil", action: model.editSelected)
          .labelStyle(.iconOnly)
          .help(L10n.tr("Открыть рабочую копию в редакторе (⌘E)"))
          .disabled(!model.canModify || !model.canOpenSelection)
        Button(
          L10n.tr("Сохранить в архив"), systemImage: "square.and.arrow.down",
          action: model.saveWorkingCopies
        )
        .labelStyle(.iconOnly)
        .help(L10n.tr("Сначала сохраните файл в редакторе, затем нажмите ⌘S здесь"))
        .disabled(!model.canModify || model.activeEdits.isEmpty)
      }
      ToolbarSpacer(.flexible)
      ToolbarItem(placement: .automatic) {
        Button(
          model.showsPreview ? L10n.tr("Скрыть предпросмотр") : L10n.tr("Показать предпросмотр"),
          systemImage: "sidebar.right", action: model.togglePreview
        )
        .labelStyle(.iconOnly)
        .help(L10n.tr("Переключить предпросмотр (⌘⇧P)"))
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
              model.searchText.isEmpty ? L10n.tr("Архив пуст") : L10n.tr("Ничего не найдено"),
              systemImage: model.searchText.isEmpty ? "archivebox" : "magnifyingglass",
              description: Text(
                model.searchText.isEmpty
                  ? L10n.tr("В этом архиве пока нет файлов.")
                  : L10n.tr("Попробуйте другое имя или путь в архиве.")
              )
            )
            .allowsHitTesting(false)
          }
        }
    } else if model.loadState == .loading {
      VStack(spacing: 16) {
        ProgressView()
        Text(L10n.tr("Читаем содержимое архива…"))
        Button(L10n.tr("Отмена"), action: model.cancelCurrentOperation)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView {
        Label(L10n.tr("Откройте архив"), systemImage: "doc.zipper")
      } description: {
        Text(L10n.tr("Перетащите архив в окно, чтобы просмотреть и извлечь файлы."))
      } actions: {
        Button(L10n.tr("Выбрать архив…"), action: model.chooseArchive)
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
        Text(L10n.tr("Предпросмотр")).font(.headline)
        Spacer()
        Button(L10n.tr("Скрыть предпросмотр"), systemImage: "xmark", action: model.togglePreview)
          .labelStyle(.iconOnly).buttonStyle(.borderless)
          .help(L10n.tr("Скрыть предпросмотр (⌘⇧P)"))
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
            Text(L10n.tr("Есть рабочая копия: сохраните файл в редакторе, затем нажмите ⌘S здесь."))
              .font(.caption).foregroundStyle(.secondary)
          }
          if !entry.isDirectory {
            DisclosureGroup(L10n.tr("Сведения"), isExpanded: $showsMetadata) {
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
              Label(L10n.tr("Папка"), systemImage: "folder")
                .font(.title3).foregroundStyle(.secondary)
              ArchiveMetadataView(details: details)
              Text(L10n.tr("Размер без сжатия и количество объектов включают все вложенные папки."))
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
            Text(L10n.tr("Подготавливаем предпросмотр…")).font(.callout).foregroundStyle(.secondary)
            Button(L10n.tr("Отмена")) { model.cancelPreview() }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ContentUnavailableView(L10n.tr("Предпросмотр недоступен"), systemImage: "doc")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else if model.selectedPath != nil && model.areFolderDetailsLoading {
        VStack(spacing: 12) {
          ProgressView().controlSize(.small)
          Text(L10n.tr("Подсчитываем размеры папок…"))
            .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView(
          model.selectedPaths.count > 1
            ? L10n.tr("Выбрано несколько объектов") : L10n.tr("Выберите файл"),
          systemImage: "doc.text.magnifyingglass",
          description: Text(L10n.tr("Предпросмотр появится здесь без извлечения всего архива."))
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
              model.isClosing
                ? L10n.tr("Закрываем архив…")
                : model.operationMessage ?? L10n.tr("Выполняем операцию…")
            )
            .lineLimit(1)
            Spacer()
            Button(L10n.tr("Отмена"), action: model.cancelCurrentOperation).disabled(
              model.isClosing)
          }
          if let progress = model.operationProgress {
            OperationProgressView(progress: progress).frame(maxWidth: 620, alignment: .leading)
          }
        }
      } else if let message = model.errorMessage {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        Text(message).textSelection(.enabled).lineLimit(3).help(message)
        Button(L10n.tr("Повторить"), action: model.retryWithPassword)
      } else if let message = model.operationMessage {
        Text(message).lineLimit(1)
      } else if let session = model.session {
        Text(L10n.tr("Объектов: %1$@", String(describing: session.entries.count))).monospacedDigit()
        Text(L10n.tr("Выбрано: %1$@", String(describing: model.selectedPaths.count)))
          .monospacedDigit()
      } else {
        Text(L10n.tr("Готово"))
      }
      Spacer()
      if !model.activeEdits.isEmpty {
        Text(
          L10n.tr(
            "Рабочих копий: %1$@. Для записи в архив нажмите ⌘S.",
            String(describing: model.activeEdits.count))
        )
        .foregroundStyle(.tint)
      }
    }
    .font(.caption).foregroundStyle(.secondary)
    .padding(.horizontal, 16).padding(.vertical, 10)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var passwordSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label(L10n.tr("Пароль архива"), systemImage: "lock.fill").font(.title3.weight(.semibold))
      Text(model.errorMessage ?? L10n.tr("Введите пароль для продолжения операции."))
        .font(.callout).foregroundStyle(.secondary)
      SecureField(L10n.tr("Пароль"), text: $model.password)
        .textFieldStyle(.roundedBorder).onSubmit { model.retryWithPassword() }
        .accessibilityLabel(L10n.tr("Пароль архива"))
      HStack {
        Spacer()
        Button(L10n.tr("Отмена"), role: .cancel, action: model.cancelPasswordPrompt)
          .keyboardShortcut(.cancelAction)
        Button(L10n.tr("Продолжить"), action: model.retryWithPassword)
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
