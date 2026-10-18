import AppKit
import Foundation
import PangoZipCore
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ArchiveBrowserModel: ObservableObject {
  enum LoadState: Equatable { case idle, loading, loaded, failed }
  fileprivate enum Operation {
    case open(URL)
    case preview(ArchiveEntry)
    case external(ArchiveEntry)
    case nested(ArchiveEntry, String)
    case back
    case edit(ArchiveEntry)
    case add([URL], String)
    case delete([String])
    case save
    case autosave([ArchiveEdit])
    case undo
    case create([URL], String)
    case extract([URL])
    case export([String], URL)
  }

  private enum IncomingRequest {
    case open(URL, String)
    case files([URL])
    case finder(FinderRequest)
  }

  struct QueuedOperation: Identifiable {
    let id = UUID()
    let title: String
    fileprivate let operation: Operation
    fileprivate let sessionID: UUID
  }
  @Published private(set) var queuedOperations: [QueuedOperation] = []
  @Published private(set) var isQueuePaused = false
  @Published var isUpdatePending = false
  @Published private(set) var hasUndo = false

  func enqueueExtraction(paths: [String], to directory: URL) {
    guard !paths.isEmpty else { return }
    enqueue(
      .export(paths, directory), title: L10n.tr("Извлечь…") + " " + paths.joined(separator: ", "))
  }

  func removeQueuedOperation(_ id: UUID) {
    queuedOperations.removeAll { $0.id == id }
    if queuedOperations.isEmpty {
      isQueuePaused = false
      drainIncomingRequests()
    }
  }

  func clearQueuedOperations() {
    queuedOperations.removeAll()
    isQueuePaused = false
    drainIncomingRequests()
  }

  func resumeQueuedOperations() {
    guard canAct else { return }
    isQueuePaused = false
    failedOperation = nil
    errorMessage = nil
    drainIncomingRequests()
  }

  private func enqueue(_ operation: Operation, title: String) {
    guard canQueueOperations, let session else { return }
    queuedOperations.append(
      QueuedOperation(title: title, operation: operation, sessionID: session.id))
    drainIncomingRequests()
  }

  private struct ParentLocation {
    let session: ArchiveSession
    let password: String
    let selectedPaths: Set<String>
    let searchText: String
    let activeEdits: [ArchiveEdit]
    let hasUndo: Bool
  }
  @Published private var parentLocations: [ParentLocation] = []
  @Published private(set) var session: ArchiveSession?
  @Published private(set) var itemDetailsByPath: [String: ArchiveItemDetails] = [:]
  @Published private(set) var areFolderDetailsLoading = false
  private(set) var itemDetailsRevision = 0
  @Published private(set) var loadState: LoadState = .idle
  @Published private(set) var isBusy = false
  @Published private(set) var isExporting = false
  @Published private(set) var isClosing = false
  @Published private(set) var isMaterializing = false
  @Published private(set) var previewURL: URL?
  @Published private(set) var errorMessage: String?
  @Published private(set) var operationProgress: ArchiveProgress?
  @Published private(set) var operationMessage: String?
  @Published private(set) var activeEdits: [ArchiveEdit] = []
  @Published var selectedPaths: Set<String> = [] { didSet { selectionChanged() } }
  @Published var searchText = ""
  @Published var password = ""
  @Published var isPasswordPromptPresented = false
  @Published private(set) var showsPreview = true
  @Published private(set) var searchFocusToken = UUID()

  private let service: ArchiveService
  private var autosaveTask: Task<Void, Never>?
  private var savedCopies: [UUID: WorkingCopySnapshot] = [:]
  private var observedCopies: [UUID: WorkingCopySnapshot] = [:]
  private var failedCopies: [UUID: WorkingCopySnapshot] = [:]
  private var acceptsQueuedOperations = false
  private var actionTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var retiredPreviewTasks: [Task<Void, Never>] = []
  private var closingTask: Task<Bool, Never>?
  private var previewGeneration = 0
  private var folderDetailsGeneration = 0
  private var folderCalculation: Task<[String: ArchiveItemDetails], Error>?
  private var folderPublication: Task<Void, Never>?
  private var failedOperation: Operation?
  private var pendingFinderFiles: [URL] = []
  private var incomingRequests: [IncomingRequest] = []
  private var activePanel: NSOpenPanel?
  private var promiseTasks: [UUID: Task<Void, Never>] = [:]
  private var promiseTail: Task<Void, Never>?
  private var dragLeases: [UUID: Set<String>] = [:]
  private var promisePasswordReply: CheckedContinuation<String?, Never>?

  /// Принимает отдельный сервис, чтобы сеанс и временные файлы принадлежали этой модели.
  init(service: ArchiveService = ArchiveService()) { self.service = service }

  var selectedPath: String? { selectedPaths.count == 1 ? selectedPaths.first : nil }
  var selectedEntry: ArchiveEntry? { session?.entries.first { $0.path == selectedPath } }
  var selectedItemDetails: ArchiveItemDetails? {
    guard let selectedPath else { return nil }
    if let details = itemDetailsByPath[selectedPath] { return details }
    guard let entry = selectedEntry, !entry.isDirectory else { return nil }
    return ArchiveItemDetails(entry: entry)
  }
  var canAct: Bool {
    !isUpdatePending && !isBusy && !isExporting && !isClosing && !isPasswordPromptPresented
      && activePanel == nil
  }
  var canQueueOperations: Bool {
    !isUpdatePending && !isClosing && !isExporting && !isPasswordPromptPresented
      && activePanel == nil && session != nil && (!isBusy || acceptsQueuedOperations)
  }
  var canQueueModifications: Bool {
    canQueueOperations && parentLocations.isEmpty && session?.canModify == true
  }
  var canModify: Bool { canAct && parentLocations.isEmpty && session?.canModify == true }
  var isNestedArchive: Bool { !parentLocations.isEmpty }
  var canNavigateBack: Bool { canAct && queuedOperations.isEmpty && isNestedArchive }
  var canUndoLastChange: Bool {
    canModify && hasUndo && activeEdits.isEmpty && queuedOperations.isEmpty
  }
  var canOpenSelection: Bool {
    canAct && selectedEntry.map { !$0.isDirectory && !$0.isSymbolicLink } == true
  }
  var visibleRoots: [ArchiveNode] {
    guard let session else { return [] }
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return session.roots }
    return session.entries.filter { $0.path.localizedCaseInsensitiveContains(query) }.map {
      ArchiveNode(path: $0.path, name: $0.path, entry: $0, children: nil)
    }
  }

  /// Удерживает панель до ответа и откладывает входящие запросы на время выбора.
  func chooseArchive() {
    guard canAct else { return }
    let panel = archivePanel()
    activePanel = panel
    panel.begin { [weak self] response in
      Task { @MainActor in
        guard let self else { return }
        self.activePanel = nil
        guard response == .OK, let url = panel.url else {
          self.drainIncomingRequests()
          return
        }
        self.open(url)
      }
    }
  }

  /// При занятости сохраняет запрос в очереди; смена архива требует решения о рабочих копиях.
  func open(_ url: URL, password suppliedPassword: String = "") {
    guard canAct, queuedOperations.isEmpty else {
      incomingRequests.append(.open(url, suppliedPassword))
      return
    }
    run {
      guard await self.closeCurrentSession() else { return }
      self.password = suppliedPassword
      await self.perform(.open(url))
    }
  }

  /// Открывает выбранный архив перед добавлением файлов; отмена не меняет текущий сеанс.
  func receiveFinderFiles(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    guard canAct else {
      incomingRequests.append(.files(urls))
      return
    }
    let panel = archivePanel()
    panel.message = L10n.tr("Выберите архив, в который нужно добавить выбранные файлы и папки.")
    panel.prompt = L10n.tr("Выбрать архив")
    activePanel = panel
    panel.begin { [weak self] response in
      Task { @MainActor in
        guard let self else { return }
        self.activePanel = nil
        guard response == .OK, let url = panel.url else {
          self.drainIncomingRequests()
          return
        }
        guard self.canAct else {
          self.incomingRequests.append(.files(urls))
          return
        }
        self.run {
          guard await self.closeCurrentSession() else { return }
          self.password = ""
          self.pendingFinderFiles = urls
          await self.perform(.open(url))
        }
      }
    }
  }

  /// Для открытия нескольких архивов создаёт независимые экземпляры приложения.
  func receiveFinderRequest(_ request: FinderRequest) {
    guard canAct else {
      incomingRequests.append(.finder(request))
      return
    }
    switch request.action {
    case .open:
      guard let first = request.urls.first else { return }
      open(first)
      // Каждый архив получает независимый сеанс и собственное окно приложения.
      for url in request.urls.dropFirst() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.open(
          [url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration
        ) { _, _ in }
      }
    default: FinderServices.launchWorker(request)
    }
  }

  /// Добавляет объекты только в изменяемый сеанс после подтверждения возможной замены.
  func addDroppedFiles(_ urls: [URL], directory: String = "") {
    guard canQueueModifications, !urls.isEmpty, confirmAdding() else { return }
    enqueue(.add(urls, directory), title: L10n.tr("Добавить файлы и папки…"))
  }

  /// Фиксирует выделение до показа панели и извлекает без перезаписи существующих объектов.
  func extractSelected() {
    guard canQueueOperations, !selectedPaths.isEmpty else { return }
    let paths = selectedPaths.sorted()
    let chooser = NSOpenPanel()
    chooser.canChooseDirectories = true
    chooser.canChooseFiles = false
    chooser.canCreateDirectories = true
    chooser.prompt = L10n.tr("Извлечь")
    chooser.message =
      L10n.tr(
        "Выберите папку для выделенных файлов и папок. Существующие объекты не перезаписываются.")
    activePanel = chooser
    chooser.begin { [weak self] response in
      Task { @MainActor in
        guard let self else { return }
        self.activePanel = nil
        if response == .OK, let directory = chooser.url {
          self.enqueueExtraction(paths: paths, to: directory)
        } else {
          self.drainIncomingRequests()
        }
      }
    }
  }

  /// Копирует внутренние пути, а не адреса временных извлечённых файлов.
  func copySelectedPaths() {
    guard !selectedPaths.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(selectedPaths.sorted().joined(separator: "\n"), forType: .string)
  }

  /// Удерживает сеанс от изменений, пока получатель перетаскивания не запросил файлы.
  func beginDragging(id: UUID, paths: [String]) {
    dragLeases[id] = Set(paths)
    updateExportState()
  }

  /// Сохраняет успешное перетаскивание до запроса файлов или истечения ожидания.
  func endDragging(id: UUID, deposited: Bool) {
    if !deposited {
      dragLeases.removeValue(forKey: id)
    } else {
      // Получатель обычно запрашивает обещанные файлы сразу после отпускания мыши.
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(120))
        self?.dragLeases.removeValue(forKey: id)
        self?.updateExportState()
      }
    }
    updateExportState()
  }

  /// Выполняет обещания последовательно; завершает ответ AppKit при успехе, ошибке и отмене.
  func fulfillPromise(
    path: String, session snapshot: ArchiveSession, to destination: URL, dragID: UUID,
    completion: PromiseCompletion
  ) {
    let id = UUID()
    let previous = promiseTail
    let task = Task { @MainActor in
      if let previous { await previous.value }
      defer {
        promiseTasks.removeValue(forKey: id)
        dragLeases[dragID]?.remove(path)
        if dragLeases[dragID]?.isEmpty == true { dragLeases.removeValue(forKey: dragID) }
        updateExportState()
      }
      do {
        try Task.checkCancellation()
        guard !isClosing, session?.id == snapshot.id else { throw ArchiveError.sessionExpired }
        await settlePreviews()
        operationMessage = L10n.tr("Извлекаем: %1$@", String(describing: path))
        while true {
          do {
            _ = try await service.exportItem(
              path, from: snapshot, to: destination, password: password, progress: progressHandler)
            break
          } catch ArchiveError.passwordRequired {
            errorMessage = ArchiveError.passwordRequired.localizedDescription
            isPasswordPromptPresented = true
            let answer = await withCheckedContinuation { promisePasswordReply = $0 }
            guard let answer else { throw CancellationError() }
            password = answer
          }
        }
        operationMessage = L10n.tr(
          "Извлечено: %1$@", String(describing: destination.lastPathComponent))
        errorMessage = nil
        completion.finish(nil)
      } catch {
        errorMessage = error is CancellationError ? nil : error.localizedDescription
        operationMessage = nil
        completion.finish(error)
      }
    }
    promiseTasks[id] = task
    promiseTail = task
    updateExportState()
  }

  /// Разрешает новые действия только после освобождения всех задач и удержаний перетаскивания.
  private func updateExportState() {
    let wasExporting = isExporting
    isExporting = !promiseTasks.isEmpty || !dragLeases.isEmpty
    if !isExporting {
      operationProgress = nil
      promiseTail = nil
      drainIncomingRequests()
      if wasExporting { selectionChanged() }
    }
  }

  /// Освобождает запрос пароля до ожидания отменённых задач, чтобы завершение не зависло.
  private func settleExports() async {
    for task in promiseTasks.values { task.cancel() }
    promisePasswordReply?.resume(returning: nil)
    promisePasswordReply = nil
    dragLeases.removeAll()
    let tasks = Array(promiseTasks.values)
    for task in tasks { await task.value }
    updateExportState()
  }

  /// Запоминает папку вставки до выбора файлов и повторно проверяет возможность записи.
  func chooseFilesToAdd() {
    guard canQueueModifications else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.prompt = L10n.tr("Добавить")
    let directory = insertionDirectory
    activePanel = panel
    panel.begin { [weak self] response in
      Task { @MainActor in
        guard let self else { return }
        self.activePanel = nil
        guard response == .OK, self.canQueueModifications, self.confirmAdding() else {
          self.drainIncomingRequests()
          return
        }
        self.enqueue(.add(panel.urls, directory), title: L10n.tr("Добавить файлы и папки…"))
      }
    }
  }

  /// Не удаляет объекты с активными рабочими копиями, включая вложенные файлы.
  func deleteSelected() {
    guard canQueueModifications, !selectedPaths.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = L10n.tr("Удалить выбранные объекты из архива?")
    alert.informativeText =
      L10n.tr(
        "Объектов: %1$@. Содержимое выбранных папок также будет удалено.",
        String(describing: selectedPaths.count))
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.tr("Удалить"))
    alert.addButton(withTitle: L10n.tr("Отмена"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let paths = selectedPaths.sorted()
    if activeEdits.contains(where: { edit in
      paths.contains { edit.entry.path == $0 || edit.entry.path.hasPrefix($0 + "/") }
    }) {
      errorMessage = L10n.tr(
        "Сначала сохраните рабочие копии или закройте архив, выбрав «Не сохранять».")
      return
    }
    enqueue(
      .delete(paths), title: L10n.tr("Удалить выбранное…") + " " + paths.joined(separator: ", "))
  }

  /// Открывает только один обычный файл; временная копия живёт до закрытия сеанса.
  func openSelectedExternally() {
    guard canOpenSelection, queuedOperations.isEmpty, let entry = selectedEntry else { return }
    start(.external(entry))
  }

  func navigateBack() {
    guard canNavigateBack else { return }
    start(.back)
  }

  /// Следит за адресом файла, поэтому атомарное сохранение редактора не теряет наблюдение.
  func watchWorkingCopy(_ edit: ArchiveEdit) throws {
    guard !activeEdits.contains(where: { $0.id == edit.id }) else { return }
    let snapshot = try WorkingCopySnapshot(edit.fileURL)
    activeEdits.append(edit)
    savedCopies[edit.id] = snapshot
    observedCopies[edit.id] = snapshot
    guard autosaveTask == nil else { return }
    autosaveTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let self else { return }
        await self.autosaveChangedCopies()
      }
    }
  }

  /// Два одинаковых снимка подряд дают редактору закончить запись перед транзакцией архива.
  func autosaveChangedCopies() async {
    guard canModify, queuedOperations.isEmpty, !isQueuePaused else { return }
    var changed: [ArchiveEdit] = []
    for edit in activeEdits {
      guard let snapshot = try? WorkingCopySnapshot(edit.fileURL) else { continue }
      if snapshot != savedCopies[edit.id], snapshot == observedCopies[edit.id],
        snapshot != failedCopies[edit.id]
      {
        changed.append(edit)
      }
      observedCopies[edit.id] = snapshot
    }
    if !changed.isEmpty { start(.autosave(changed)) }
  }

  private func stopWatchingCopies() {
    autosaveTask?.cancel()
    autosaveTask = nil
    savedCopies.removeAll()
    observedCopies.removeAll()
    failedCopies.removeAll()
  }

  /// Создаёт рабочую копию и автоматически сохраняет изменения редактора в архив.
  func editSelected() {
    guard canModify, canOpenSelection, let entry = selectedEntry else { return }
    start(.edit(entry))
  }

  /// Записывает все зарегистрированные рабочие копии одной операцией сервиса.
  func saveWorkingCopies() {
    guard canModify, !activeEdits.isEmpty else { return }
    start(.save)
  }

  func undoLastChange() {
    guard canUndoLastChange else { return }
    start(.undo)
  }

  /// Скрытие панели отменяет материализацию, а повторный показ использует текущее выделение.
  func togglePreview() {
    showsPreview.toggle()
    if showsPreview {
      if previewURL == nil { selectionChanged() }
    } else {
      cancelPreview(preservingContent: true)
    }
  }

  /// Меняет токен даже при повторном запросе, чтобы SwiftUI снова перевёл фокус.
  func focusSearch() { searchFocusToken = UUID() }

  /// Отменяет задачи и освобождает ожидание пароля; завершение выполняют сами задачи.
  func cancelCurrentOperation() {
    actionTask?.cancel()
    for task in promiseTasks.values { task.cancel() }
    promisePasswordReply?.resume(returning: nil)
    promisePasswordReply = nil
    if isExporting { isPasswordPromptPresented = false }
    dragLeases.removeAll()
    updateExportState()
    cancelPreview()
  }

  /// Использует общий путь отмены, чтобы также освободить предпросмотр и экспорт.
  func cancelLoading() { cancelCurrentOperation() }

  /// Меняет поколение до отмены задачи, чтобы запоздалый результат не заменил предпросмотр.
  func cancelPreview(preservingContent: Bool = false) {
    previewGeneration += 1
    previewTask?.cancel()
    if let previewTask { retiredPreviewTasks.append(previewTask) }
    previewTask = nil
    // Готовый файл остаётся видимым до конца анимации; смена выделения очищает его.
    if !preservingContent { previewURL = nil }
    isMaterializing = false
  }

  /// Освобождает ожидающее обещание файла и прекращает повтор ранее неудачной операции.
  func cancelPasswordPrompt() {
    promisePasswordReply?.resume(returning: nil)
    promisePasswordReply = nil
    isPasswordPromptPresented = false
    if case .nested(_, let parentPassword) = failedOperation { password = parentPassword }
    failedOperation = nil
    errorMessage = nil
    if session == nil { loadState = .idle }
    pendingFinderFiles = []
    drainIncomingRequests()
  }

  /// Передаёт пароль ожидающему экспорту либо повторяет сохранённую операцию.
  func retryWithPassword() {
    if let reply = promisePasswordReply {
      promisePasswordReply = nil
      isPasswordPromptPresented = false
      reply.resume(returning: password)
      return
    }
    guard !isBusy, !isClosing, let operation = failedOperation else { return }
    isPasswordPromptPresented = false
    failedOperation = nil
    if case .preview(let entry) = operation {
      startPreview(entry)
    } else {
      start(operation)
    }
  }

  /// Объединяет повторные команды закрытия в одну задачу с общим результатом.
  func closeArchive() {
    guard closingTask == nil else { return }
    closingTask = Task { [weak self] in
      guard let self else { return true }
      let result = await self.shutdown(terminate: false)
      self.closingTask = nil
      return result
    }
  }

  /// Учитывает уже начатое закрытие и позволяет пользователю отменить завершение приложения.
  func requestTermination() async -> Bool {
    if let closingTask, !(await closingTask.value) { return false }
    return await shutdown(terminate: true)
  }

  /// Сохраняет тот же порядок очистки и подтверждений, что завершение приложения.
  func cleanup() async { _ = await requestTermination() }

  private var insertionDirectory: String {
    guard let path = selectedPath else { return "" }
    if selectedEntry?.isDirectory == true || selectedEntry == nil { return path }
    return path.split(separator: "/").dropLast().joined(separator: "/")
  }

  /// Не ограничивает расширения: формат содержимого проверяет архивный сервис.
  private func archivePanel() -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.item]
    return panel
  }

  /// Требует явного согласия на замену совпадающих путей при добавлении.
  private func confirmAdding() -> Bool {
    let alert = NSAlert()
    alert.messageText = L10n.tr("Добавить файлы в архив?")
    alert.informativeText = L10n.tr(
      "Файлы с совпадающими именами по выбранному пути будут заменены.")
    alert.addButton(withTitle: L10n.tr("Добавить"))
    alert.addButton(withTitle: L10n.tr("Отмена"))
    return alert.runModal() == .alertFirstButtonReturn
  }

  private var progressHandler: ArchiveProgressHandler {
    { [weak self] value in await self?.receiveProgress(value) }
  }

  /// Обновляет наблюдаемое состояние только на главном акторе.
  private func receiveProgress(_ value: ArchiveProgress) { operationProgress = value }

  /// Сериализует пользовательские операции и после завершения продолжает очередь запросов.
  private func run(
    acceptingQueuedOperations: Bool = false, _ body: @escaping @MainActor () async -> Void
  ) {
    guard !isBusy, !isClosing else { return }
    acceptsQueuedOperations = acceptingQueuedOperations
    isBusy = true
    operationProgress = nil
    actionTask = Task { [weak self] in
      await body()
      self?.operationProgress = nil
      self?.isBusy = false
      self?.acceptsQueuedOperations = false
      self?.actionTask = nil
      if self?.errorMessage == nil { self?.selectionChanged() }
      self?.drainIncomingRequests()
    }
  }

  /// Извлекает один запрос за раз; запущенное действие само продолжит обработку очереди.
  private func drainIncomingRequests() {
    guard canAct else { return }
    while !queuedOperations.isEmpty {
      guard !isQueuePaused else { return }
      let next = queuedOperations.removeFirst()
      guard next.sessionID == session?.id else { continue }
      run(acceptingQueuedOperations: true) { await self.perform(next.operation) }
      return
    }
    guard !incomingRequests.isEmpty else { return }
    let request = incomingRequests.removeFirst()
    switch request {
    case .open(let url, let suppliedPassword): open(url, password: suppliedPassword)
    case .files(let urls): receiveFinderFiles(urls)
    case .finder(let request): receiveFinderRequest(request)
    }
  }

  /// Запускает операцию только когда панель, пароль и экспорт не удерживают сеанс.
  private func start(_ operation: Operation) {
    guard canAct else { return }
    let acceptsQueue =
      switch operation {
      case .external, .nested, .back: false
      default: true
      }
    run(acceptingQueuedOperations: acceptsQueue) { await self.perform(operation) }
  }

  /// Сохраняет остаток пакетной операции для повтора после запроса пароля.
  private func perform(_ operation: Operation) async {
    errorMessage = nil
    var retryOperation = operation
    do {
      try Task.checkCancellation()
      switch operation {
      case .open(let url):
        operationMessage = nil
        loadState = .loading
        let result = try await service.open(url, password: password)
        if Task.isCancelled {
          try await service.close(result)
          loadState = .idle
          return
        }
        await replaceSession(result)
        loadState = .loaded
        if !pendingFinderFiles.isEmpty {
          let urls = pendingFinderFiles
          pendingFinderFiles = []
          if !result.canModify {
            errorMessage = L10n.tr("Этот формат доступен только для чтения.")
          } else if confirmAdding() {
            await perform(.add(urls, ""))
            return
          }
        }
      case .create(let urls, let format):
        await settlePreviews()
        let selection = FinderSelection(urls: urls)
        guard let first = urls.first else { throw ArchiveError.invalidOperation }
        operationMessage = L10n.tr("Создаём архив…")
        let proposed = first.deletingLastPathComponent().appendingPathComponent(
          selection.archiveName + "." + format)
        let result = try await service.createArchive(
          from: urls, proposedURL: proposed, format: format, options: ArchivePreferences.options,
          progress: progressHandler)
        NSWorkspace.shared.activateFileViewerSelecting([result])
        operationMessage = L10n.tr(
          "Создан архив: %1$@", String(describing: result.lastPathComponent))
      case .extract(let urls):
        await settlePreviews()
        var results: [URL] = []
        defer { if !results.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(results) } }
        for (index, url) in urls.enumerated() {
          retryOperation = .extract(Array(urls[index...]))
          operationMessage = L10n.tr(
            "Извлекаем %1$@ из %2$@: %3$@", String(describing: index + 1),
            String(describing: urls.count), String(describing: url.lastPathComponent))
          results.append(
            try await service.extractArchive(url, password: password, progress: progressHandler))
          password = ""
        }
        operationMessage = L10n.tr("Извлечено архивов: %1$@", String(describing: results.count))
      case .export(let paths, let directory):
        guard let session else { throw ArchiveError.sessionExpired }
        await settlePreviews()
        operationMessage = L10n.tr("Извлечение…")
        let results = try await service.exportSelection(
          paths, from: session, to: directory, password: password, progress: progressHandler)
        NSWorkspace.shared.activateFileViewerSelecting(results)
        operationMessage = L10n.tr("Извлечено объектов: %1$@", String(describing: results.count))
      case .preview:
        return
      case .external(let entry):
        guard let session else { return }
        let url = try await service.materialize(entry, in: session, password: password)
        try Task.checkCancellation()
        if selectedPath == entry.path {
          if FinderSelection.isArchive(url) {
            let parentPassword = password
            password = ""
            await perform(.nested(entry, parentPassword))
            return
          }
          openInWorkspace(url)
        }
      case .nested(let entry, let parentPassword):
        guard let parent = session else { throw ArchiveError.sessionExpired }
        await settlePreviews()
        let url = try await service.materialize(entry, in: parent, password: parentPassword)
        let child = try await service.open(url, password: password)
        if Task.isCancelled {
          try await service.close(child)
          throw CancellationError()
        }
        parentLocations.append(
          ParentLocation(
            session: parent, password: parentPassword, selectedPaths: selectedPaths,
            searchText: searchText, activeEdits: activeEdits, hasUndo: hasUndo))
        activeEdits = []
        selectedPaths = []
        searchText = ""
        await replaceSession(child)
        loadState = .loaded
      case .back:
        try await restoreParent()
      case .edit(let entry):
        guard let session, session.canModify else { return }
        let edit = try await service.beginEditing(entry, in: session, password: password)
        try watchWorkingCopy(edit)
        try Task.checkCancellation()
        if selectedPath == entry.path { openInWorkspace(edit.fileURL) }
      case .add(let urls, let directory):
        guard let session, session.canModify else { return }
        await settlePreviews()
        await apply(
          try await service.add(urls, to: session, directory: directory, password: password))
      case .delete(let paths):
        guard let session, session.canModify else { return }
        await settlePreviews()
        await apply(try await service.delete(paths, from: session, password: password))
      case .save:
        try await persistWorkingCopies(activeEdits, retainingWorkingCopies: false)
      case .autosave(let edits):
        try await persistWorkingCopies(edits, retainingWorkingCopies: true)
      case .undo:
        guard let session else { throw ArchiveError.sessionExpired }
        await settlePreviews()
        operationMessage = L10n.tr("Откат последнего изменения…")
        await apply(try await service.undoLastChange(in: session, password: password))
        operationMessage = L10n.tr("Последнее изменение отменено")
      }
      if let session {
        hasUndo = (try? await service.canUndo(session)) ?? false
      } else {
        hasUndo = false
      }
      failedOperation = nil
    } catch is CancellationError {
      if case .nested(_, let parentPassword) = operation { password = parentPassword }
      operationProgress = nil
      operationMessage = nil
      loadState = session == nil ? .idle : .loaded
    } catch ArchiveError.passwordRequired {
      operationProgress = nil
      failedOperation = retryOperation
      operationMessage = nil
      errorMessage = ArchiveError.passwordRequired.localizedDescription
      isPasswordPromptPresented = true
      if session == nil { loadState = .failed }
    } catch {
      if case .nested(_, let parentPassword) = operation { password = parentPassword }
      operationProgress = nil
      failedOperation = retryOperation
      operationMessage = nil
      errorMessage = error.localizedDescription
      if !queuedOperations.isEmpty { isQueuePaused = true }
      if session == nil { loadState = .failed }
    }
  }

  private func persistWorkingCopies(_ edits: [ArchiveEdit], retainingWorkingCopies: Bool)
    async throws
  {
    guard let session, !edits.isEmpty else { return }
    let snapshots = try Dictionary(
      uniqueKeysWithValues: edits.map {
        ($0.id, try WorkingCopySnapshot($0.fileURL))
      })
    await settlePreviews()
    operationMessage = L10n.tr("Автоматическое сохранение в архив…")
    do {
      let updated = try await service.save(
        edits, in: session, password: password, retainingWorkingCopies: retainingWorkingCopies)
      await apply(updated)
      for (id, snapshot) in snapshots {
        savedCopies[id] = snapshot
        failedCopies[id] = nil
      }
      if !retainingWorkingCopies {
        activeEdits.removeAll { edit in edits.contains { $0.id == edit.id } }
        if activeEdits.isEmpty { stopWatchingCopies() }
      }
      operationMessage = L10n.tr("Изменения сохранены в архив")
    } catch {
      for (id, snapshot) in snapshots { failedCopies[id] = snapshot }
      throw error
    }
  }

  /// Удаляет устаревшие пути выделения после изменения содержимого архива.
  func apply(_ refreshed: ArchiveSession) async {
    await replaceSession(refreshed)
    let available = (try? await service.canUndo(refreshed)) ?? false
    if session?.id == refreshed.id { hasUndo = available }
    let validPaths = Set(refreshed.entries.map(\.path)).union(allPaths(refreshed.roots))
    selectedPaths.formIntersection(validPaths)
    selectionChanged()
  }

  /// Отмена завершается до замены снимка; поколение защищает также обновления с тем же UUID.
  private func replaceSession(_ refreshed: ArchiveSession?) async {
    folderDetailsGeneration &+= 1
    let generation = folderDetailsGeneration
    let previousCalculation = folderCalculation
    let previousPublication = folderPublication
    previousCalculation?.cancel()
    previousPublication?.cancel()
    _ = try? await previousCalculation?.value
    await previousPublication?.value
    guard folderDetailsGeneration == generation else { return }
    folderCalculation = nil
    folderPublication = nil
    session = refreshed
    if refreshed == nil { hasUndo = false }
    itemDetailsByPath = [:]
    itemDetailsRevision &+= 1
    areFolderDetailsLoading = refreshed != nil
    guard let refreshed else { return }
    let calculation = Task.detached(priority: .userInitiated) {
      try ArchiveItemDetails.folders(in: refreshed.roots)
    }
    folderCalculation = calculation
    folderPublication = Task { [weak self] in
      let results = try? await calculation.value
      guard !Task.isCancelled, let self, self.folderDetailsGeneration == generation else { return }
      if let results { self.itemDetailsByPath = results }
      self.itemDetailsRevision &+= 1
      self.areFolderDetailsLoading = false
      self.folderCalculation = nil
      self.folderPublication = nil
    }
  }

  deinit {
    folderCalculation?.cancel()
    folderPublication?.cancel()
  }

  /// Включает виртуальные папки, которых может не быть в списке записей архива.
  private func allPaths(_ nodes: [ArchiveNode]) -> Set<String> {
    nodes.reduce(into: Set<String>()) { result, node in
      result.insert(node.path)
      result.formUnion(allPaths(node.children ?? []))
    }
  }

  /// Отменяет прежний предпросмотр до проверки нового выделения.
  private func selectionChanged() {
    cancelPreview()
    guard showsPreview, !isBusy, !isExporting, !isClosing, !isPasswordPromptPresented,
      let entry = selectedEntry,
      !entry.isDirectory, !entry.isSymbolicLink
    else { return }
    startPreview(entry)
  }

  /// Проверяет поколение и идентификатор сеанса перед публикацией извлечённого файла.
  private func startPreview(_ entry: ArchiveEntry) {
    guard showsPreview, !isBusy, !isExporting, !isClosing, let current = session else { return }
    cancelPreview()
    if failedOperation == nil {
      errorMessage = nil
    } else if case .preview = failedOperation {
      failedOperation = nil
      errorMessage = nil
    }
    let generation = previewGeneration
    let suppliedPassword = password
    isMaterializing = true
    previewTask = Task { [weak self, service] in
      defer { self?.drainIncomingRequests() }
      do {
        let url = try await service.materialize(entry, in: current, password: suppliedPassword)
        try Task.checkCancellation()
        guard let self, generation == self.previewGeneration, self.session?.id == current.id else {
          return
        }
        self.previewURL = url
        self.isMaterializing = false
      } catch is CancellationError {
        return
      } catch {
        guard let self, generation == self.previewGeneration else { return }
        self.isMaterializing = false
        self.errorMessage = error.localizedDescription
        self.failedOperation = .preview(entry)
        if case ArchiveError.passwordRequired = error { self.isPasswordPromptPresented = true }
      }
    }
  }

  /// Дожидается отменённых материализаций до изменения или удаления временных файлов.
  private func settlePreviews() async {
    cancelPreview()
    let tasks = retiredPreviewTasks
    retiredPreviewTasks.removeAll()
    for task in tasks { await task.value }
  }

  /// Сохраняет ошибку запуска внешнего приложения в состоянии интерфейса.
  private func openInWorkspace(_ url: URL) {
    if !NSWorkspace.shared.open(url) {
      errorMessage = L10n.tr("Не удалось открыть файл во внешнем приложении.")
    }
  }

  func saveWorkingCopiesBeforeClosing() async -> Bool {
    await perform(.save)
    return !Task.isCancelled && activeEdits.isEmpty
  }

  /// Продолжает закрытие только после сохранения копий или явного отказа от сохранения.
  private func confirmWorkingCopies() async -> Bool {
    guard
      activeEdits.contains(where: { (try? WorkingCopySnapshot($0.fileURL)) != savedCopies[$0.id] })
    else { return true }
    let alert = NSAlert()
    alert.messageText = L10n.tr("Сохранить рабочие копии в архив?")
    alert.informativeText =
      L10n.tr(
        "Сначала сохраните файлы во внешнем редакторе. Рабочих копий: %1$@. При выборе «Не сохранять» они будут удалены.",
        String(describing: activeEdits.count))
    alert.addButton(withTitle: L10n.tr("Сохранить"))
    alert.addButton(withTitle: L10n.tr("Не сохранять"))
    alert.addButton(withTitle: L10n.tr("Отмена"))
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      return await saveWorkingCopiesBeforeClosing()
    case .alertSecondButtonReturn:
      return true
    default:
      return false
    }
  }

  /// Закрывает только дочерний сеанс: его исходный файл принадлежит родителю.
  private func restoreParent() async throws {
    guard let parent = parentLocations.last else { return }
    await settlePreviews()
    if let session { try await service.close(session) }
    parentLocations.removeLast()
    password = parent.password
    activeEdits = parent.activeEdits
    await replaceSession(parent.session)
    selectedPaths = parent.selectedPaths
    searchText = parent.searchText
    hasUndo = parent.hasUndo
    operationMessage = nil
    loadState = .loaded
  }

  private func restoreRoot() async -> Bool {
    if case .nested(_, let parentPassword) = failedOperation { password = parentPassword }
    do {
      while !parentLocations.isEmpty { try await restoreParent() }
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  /// Не сбрасывает сеанс, если пользователь отменил закрытие или очистка завершилась ошибкой.
  private func closeCurrentSession() async -> Bool {
    guard await restoreRoot() else { return false }
    await settlePreviews()
    guard !Task.isCancelled, await confirmWorkingCopies() else { return false }
    await settlePreviews()
    guard !Task.isCancelled else { return false }
    do {
      if let session { try await service.close(session) }
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
    await replaceSession(nil)
    operationMessage = nil
    activeEdits.removeAll()
    stopWatchingCopies()
    selectedPaths = []
    searchText = ""
    pendingFinderFiles = []
    errorMessage = nil
    failedOperation = nil
    isPasswordPromptPresented = false
    loadState = .idle
    return true
  }

  /// Сначала завершает экспорт и операции, затем спрашивает о рабочих копиях и удаляет сеанс.
  private func shutdown(terminate: Bool) async -> Bool {
    guard !isClosing else { return false }
    isClosing = true
    clearQueuedOperations()
    var didClose = false
    defer {
      isClosing = false
      if !terminate || !didClose { drainIncomingRequests() }
    }
    activePanel?.cancel(nil)
    await settleExports()
    isPasswordPromptPresented = false
    actionTask?.cancel()
    await actionTask?.value
    guard await restoreRoot() else { return false }
    await settlePreviews()
    guard await confirmWorkingCopies() else { return false }
    await settlePreviews()
    guard !Task.isCancelled else { return false }
    do {
      if let session { try await service.close(session) }
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
    await replaceSession(nil)
    operationMessage = nil
    activeEdits.removeAll()
    stopWatchingCopies()
    selectedPaths = []
    searchText = ""
    pendingFinderFiles = []
    loadState = .idle
    failedOperation = nil
    isPasswordPromptPresented = false
    errorMessage = nil
    if terminate {
      incomingRequests.removeAll()
      await service.cleanup()
    }
    didClose = true
    return true
  }
}

struct QuickLookPreview: NSViewRepresentable {
  let url: URL
  /// Передаёт Quick Look только уже извлечённый локальный файл.
  func makeNSView(context: Context) -> QLPreviewView {
    let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
    view.previewItem = url as NSURL
    return view
  }
  /// Обновляет тот же Quick Look view при смене файла без создания второго экземпляра.
  func updateNSView(_ nsView: QLPreviewView, context: Context) {
    guard nsView.previewItem?.previewItemURL != url else { return }
    nsView.previewItem = url as NSURL
  }
}
