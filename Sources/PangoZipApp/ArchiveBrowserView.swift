import AppKit
import PangoZipCore
import SwiftUI
import UniformTypeIdentifiers

struct ArchiveBrowserView: View {
  @ObservedObject var model: ArchiveBrowserModel
  @ObservedObject var integration: FinderIntegrationModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  // Смена оформления пересобирает предпросмотр: от неё зависит выбор между Quick Look и текстом.
  @Environment(\.colorScheme) private var colorScheme
  @State private var isDropTargeted = false
  @AppStorage("hideSystemFiles") private var hidesSystemFiles = true
  @State private var showsMetadata = false
  @State private var showsOperationQueue = false
  @FocusState private var searchFocused: Bool

  var body: some View {
    ArchiveSplitView(
      showsPreview: model.showsPreview, reduceMotion: reduceMotion,
      content: archiveContent, preview: preview
    )
    .navigationTitle(windowTitle)
    .toolbar(removing: .title)
    .toolbar {
      primaryToolbar
      secondaryToolbar
    }
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .toolbarColorScheme(.dark, for: .windowToolbar)
    .background {
      // Шапка занимает ровно высоту панели инструментов и уходит под её стекло.
      GeometryReader { proxy in
        BrandHeaderBackground()
          .frame(height: proxy.safeAreaInsets.top)
          .frame(maxHeight: .infinity, alignment: .top)
          .ignoresSafeArea(edges: .top)
      }
    }
    .onExitCommand { model.cancelCurrentOperation() }
    .onChange(of: model.searchFocusToken) { _, _ in searchFocused = true }
    .sheet(isPresented: $model.isPasswordPromptPresented) { passwordSheet }
    .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: 12)
          .stroke(Brand.gold, style: StrokeStyle(lineWidth: 3, dash: [9]))
          .padding(8).allowsHitTesting(false)
      }
    }
  }

  private var windowTitle: String { model.session?.url.lastPathComponent ?? "PangoZip" }

  private var windowSubtitle: String {
    model.session.map {
      $0.format.uppercased()
        + ($0.canModify && !model.isNestedArchive ? "" : L10n.tr(" — Только чтение"))
    } ?? ""
  }

  @ToolbarContentBuilder
  private var primaryToolbar: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      if model.isNestedArchive {
        Button(L10n.tr("Назад"), systemImage: "chevron.left", action: model.navigateBack)
          .labelStyle(.iconOnly)
          .help(L10n.tr("Назад"))
          .disabled(!model.canNavigateBack)
      }
    }
    // Системный заголовок не гарантирует светлый текст на синей шапке, поэтому рисуем свой.
    ToolbarItem(placement: .navigation) {
      VStack(alignment: .leading, spacing: 1) {
        Text(windowTitle).font(.headline).lineLimit(1).truncationMode(.middle)
        if !windowSubtitle.isEmpty {
          Text(windowSubtitle).font(.caption).opacity(0.8).lineLimit(1)
        }
      }
      // Длинное имя архива сокращается в середине и не вытесняет кнопки; полное имя в подсказке.
      .foregroundStyle(.white).padding(.horizontal, 4)
      .frame(maxWidth: 340, alignment: .leading).help(windowTitle)
      .accessibilityElement(children: .combine)
    }
    .sharedBackgroundVisibility(.hidden)
    // Заголовок занимает левый край, все кнопки собраны одним блоком справа.
    ToolbarSpacer(.flexible)
    ToolbarItem(placement: .automatic) {
      Button(action: model.extractSelected) {
        Label(L10n.tr("Извлечь"), systemImage: "arrow.up.bin")
          .labelStyle(.titleAndIcon).fontWeight(.semibold).foregroundStyle(Brand.onGold)
      }
      .buttonStyle(.borderedProminent).tint(Brand.gold)
      .help(L10n.tr("Извлечь выбранные файлы и папки (⌘⇧E)"))
      .disabled(!model.canQueueOperations || model.selectedPaths.isEmpty)
    }
    ToolbarSpacer(.fixed)
    modificationToolbar
  }

  /// Правый край по рекомендациям Apple: очередь, меню «Ещё», поиск и кнопка боковой панели
  /// предпросмотра у самого края, над этой панелью.
  @ToolbarContentBuilder
  private var secondaryToolbar: some ToolbarContent {
    ToolbarSpacer(.fixed)
    queueToolbar
    ToolbarItem(placement: .automatic) { moreMenu }
    ToolbarItem(placement: .automatic) { searchField }
    ToolbarSpacer(.fixed)
    previewToolbar
  }

  /// Подписанные кнопки стоят отдельно, значки действий над выделением делят одну подложку.
  @ToolbarContentBuilder
  private var modificationToolbar: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      Button(action: model.chooseFilesToAdd) {
        Label(L10n.tr("Добавить"), systemImage: "plus").labelStyle(.titleAndIcon)
      }
      .help(L10n.tr("Добавить файлы и папки (⌘⇧A)")).disabled(!model.canQueueModifications)
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
      Button(L10n.tr("Удалить выбранное…"), systemImage: "trash", action: model.deleteSelected)
        .labelStyle(.iconOnly)
        .help(L10n.tr("Удалить выбранное (⌘⌫)"))
        .disabled(!model.canQueueModifications || model.selectedPaths.isEmpty)
    }
    if !model.activeEdits.isEmpty {
      ToolbarSpacer(.fixed)
      ToolbarItem(placement: .automatic) {
        Button(action: model.saveWorkingCopies) {
          Label(L10n.tr("Сохранить в архив"), systemImage: "square.and.arrow.down")
            .labelStyle(.titleAndIcon)
        }
        .help(L10n.tr("Сохранить рабочие копии сейчас"))
        .disabled(!model.canModify)
      }
    }
  }

  /// Собственное поле поиска: системное всегда встаёт последним и не пускает кнопку панели
  /// предпросмотра к правому краю.
  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField(L10n.tr("Имя или путь в архиве"), text: $model.searchText)
        .textFieldStyle(.plain).focused($searchFocused)
        .accessibilityLabel(L10n.tr("Имя или путь в архиве"))
      if !model.searchText.isEmpty {
        Button(L10n.tr("Отмена"), systemImage: "xmark.circle.fill") { model.searchText = "" }
          .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 10).frame(width: 250)
  }

  /// Собирает редкие действия в одно меню, чтобы на панели остались только частые.
  private var moreMenu: some View {
    Menu {
      Button(L10n.tr("Открыть архив…"), systemImage: "archivebox", action: model.chooseArchive)
        .disabled(!model.canAct)
      Button(L10n.tr("Закрыть архив"), systemImage: "xmark.circle", action: model.closeArchive)
        .disabled(model.session == nil && !model.isBusy || model.isClosing)
      Divider()
      Button(
        L10n.tr("Откатить последнее изменение архива"), systemImage: "arrow.uturn.backward",
        action: model.undoLastChange
      )
      .disabled(!model.canUndoLastChange)
      Divider()
      if let url = model.session?.url {
        ShareLink(item: url) {
          Label(L10n.tr("Поделиться архивом"), systemImage: "square.and.arrow.up")
        }
        .disabled(!model.canAct)
      }
      ArchiveColumnsMenu()
    } label: {
      Label(L10n.tr("Ещё действия"), systemImage: "ellipsis")
    }
    .labelStyle(.iconOnly)
    .help(L10n.tr("Ещё действия"))
  }

  /// Доля выполнения известна только после подготовки; до неё показывается индикатор ожидания.
  private var operationFraction: Double? {
    guard let progress = model.operationProgress, progress.phase != .preparing else { return nil }
    return progress.fraction
  }

  @ToolbarContentBuilder
  private var queueToolbar: some ToolbarContent {
    // Кнопка очереди появляется только при работе или ожидающих операциях.
    if model.isBusy || model.isExporting || !model.queuedOperations.isEmpty || showsOperationQueue {
      ToolbarItem(placement: .automatic) {
        queueButton
      }
    }
  }

  private var queueButton: some View {
    Group {
      Button {
        showsOperationQueue.toggle()
      } label: {
        HStack(spacing: 6) {
          if model.isBusy || model.isExporting {
            if let fraction = operationFraction {
              OperationProgressRing(fraction: fraction)
              Text("\(Int((fraction * 100).rounded(.down)))%").monospacedDigit()
                .foregroundStyle(.white)
            } else {
              ProgressView().controlSize(.small)
            }
          } else {
            Image(systemName: model.isQueuePaused ? "pause.circle" : "list.bullet.rectangle")
          }
          if !model.queuedOperations.isEmpty {
            Text(String(model.queuedOperations.count)).font(.caption2.weight(.bold))
              .monospacedDigit().padding(.horizontal, 5).padding(.vertical, 1)
              .background(Brand.gold, in: Capsule()).foregroundStyle(Brand.onGold)
          }
        }
      }
      .accessibilityLabel(L10n.tr("Очередь операций"))
      .help(L10n.tr("Очередь операций") + " (" + String(model.queuedOperations.count) + ")")
      .popover(isPresented: $showsOperationQueue) { ArchiveOperationQueueView(model: model) }
    }
  }

  @ToolbarContentBuilder
  private var previewToolbar: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      Button(
        model.showsPreview ? L10n.tr("Скрыть предпросмотр") : L10n.tr("Показать предпросмотр"),
        systemImage: "sidebar.right", action: model.togglePreview
      )
      .labelStyle(.iconOnly)
      .help(L10n.tr("Переключить предпросмотр (⌘⇧P)"))
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
          if model.visibleRoots(hidingSystemFiles: hidesSystemFiles).isEmpty {
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
      VStack(alignment: .leading, spacing: 14) {
        Image(systemName: "arrow.down.to.line")
          .font(.system(size: 24, weight: .medium)).foregroundStyle(Brand.gold)
          .frame(width: 52, height: 52)
          .background(Brand.header, in: RoundedRectangle(cornerRadius: 16))
          .accessibilityHidden(true)
        Text(L10n.tr("Откройте архив")).font(.largeTitle.weight(.bold)).padding(.top, 6)
        Text(L10n.tr("Перетащите архив в окно, чтобы просмотреть и извлечь файлы."))
          .font(.body).foregroundStyle(.secondary)
        if let message = model.errorMessage {
          Text(message).foregroundStyle(.red).textSelection(.enabled)
        }
        Button(action: model.chooseArchive) {
          Text(L10n.tr("Выбрать архив…")).fontWeight(.semibold).foregroundStyle(Brand.onGold)
        }
        .buttonStyle(.borderedProminent).tint(Brand.gold).controlSize(.extraLarge)
        .disabled(!model.canAct).padding(.top, 10)
      }
      .padding(40).frame(maxWidth: 520, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 22)
          .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [7]))
      )
      .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text(
              L10n.tr(
                "Изменения автоматически сохраняются в архив после сохранения файла в редакторе.")
            )
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
          if FinderSelection.isArchive(url) {
            Button(L10n.tr("Открыть архив…"), action: model.openSelectedExternally)
              .buttonStyle(.borderedProminent)
              .disabled(!model.canOpenSelection)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if PlainTextPreview.shouldReplaceQuickLook(for: url) {
            PlainTextPreview(url: url).frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(Color(nsColor: Brand.tableNS))
          } else {
            QuickLookPreview(url: url).frame(maxWidth: .infinity, maxHeight: .infinity)
          }
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
    .background(Brand.surface)
  }

  /// Путь к единственному выделенному объекту: имя архива и компоненты пути внутри него.
  private var selectionBreadcrumb: [String] {
    guard let session = model.session else { return [] }
    let components = model.selectedPath?.split(separator: "/").map(String.init) ?? []
    return [session.url.lastPathComponent] + components
  }

  /// Ход операции показывает только кнопка очереди; здесь остаются путь, счётчики и сообщения.
  private var statusBar: some View {
    HStack(spacing: 12) {
      if model.isClosing {
        ProgressView().controlSize(.small)
        Text(L10n.tr("Закрываем архив…")).lineLimit(1)
      } else if model.isBusy || model.isExporting {
        Text(model.operationMessage ?? L10n.tr("Выполняем операцию…"))
          .lineLimit(1).truncationMode(.middle)
      } else if let message = model.errorMessage {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        Text(message).textSelection(.enabled).lineLimit(3).help(message)
        Button(L10n.tr("Повторить"), action: model.retryWithPassword)
      } else if let message = model.operationMessage {
        Text(message).lineLimit(1)
      } else if model.session != nil {
        let path = selectionBreadcrumb
        HStack(spacing: 6) {
          ForEach(Array(path.enumerated()), id: \.offset) { index, component in
            if index > 0 { Image(systemName: "chevron.right").imageScale(.small) }
            Text(component).lineLimit(1).truncationMode(.middle)
              .fontWeight(index > 0 && index == path.count - 1 ? .semibold : .regular)
              .foregroundStyle(index > 0 && index == path.count - 1 ? .primary : .secondary)
          }
        }
        .accessibilityElement(children: .combine)
      } else {
        Text(L10n.tr("Готово"))
      }
      Spacer(minLength: 8)
      if let session = model.session {
        Text(L10n.tr("Объектов: %1$@", String(describing: session.entries.count))).monospacedDigit()
        Text(L10n.tr("Выбрано: %1$@", String(describing: model.selectedPaths.count)))
          .monospacedDigit()
      }
      if !model.activeEdits.isEmpty {
        Image(systemName: "pencil.circle")
          .foregroundStyle(Brand.goldInk)
          .help(
            L10n.tr(
              "Изменения автоматически сохраняются в архив после сохранения файла в редакторе."))
      }
    }
    .font(.caption).foregroundStyle(.secondary)
    .padding(.horizontal, 16).padding(.vertical, 9)
    .background(Brand.surface)
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
