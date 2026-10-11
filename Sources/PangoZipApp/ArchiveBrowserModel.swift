import AppKit
import Foundation
import PangoZipCore
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ArchiveBrowserModel: ObservableObject {
  enum LoadState: Equatable { case idle, loading, loaded, failed }
  private enum Operation {
    case open(URL)
    case preview(ArchiveEntry)
    case external(ArchiveEntry)
    case edit(ArchiveEntry)
    case add([URL], String)
    case delete([String])
    case save
    case create([URL], String)
    case extract([URL])
    case export([String], URL)
  }

  private enum IncomingRequest {
    case open(URL, String)
    case files([URL])
    case finder(FinderRequest)
  }

  @Published private(set) var session: ArchiveSession?
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
  private var actionTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var retiredPreviewTasks: [Task<Void, Never>] = []
  private var closingTask: Task<Bool, Never>?
  private var previewGeneration = 0
  private var failedOperation: Operation?
  private var pendingFinderFiles: [URL] = []
  private var incomingRequests: [IncomingRequest] = []
  private var activePanel: NSOpenPanel?
  private var promiseTasks: [UUID: Task<Void, Never>] = [:]
  private var promiseTail: Task<Void, Never>?
  private var dragLeases: [UUID: Set<String>] = [:]
  private var promisePasswordReply: CheckedContinuation<String?, Never>?

  init(service: ArchiveService = ArchiveService()) { self.service = service }

  var selectedPath: String? { selectedPaths.count == 1 ? selectedPaths.first : nil }
  var selectedEntry: ArchiveEntry? { session?.entries.first { $0.path == selectedPath } }
  var canAct: Bool {
    !isBusy && !isExporting && !isClosing && !isPasswordPromptPresented && activePanel == nil
  }
  var canModify: Bool { canAct && session?.canModify == true }
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

  func open(_ url: URL, password suppliedPassword: String = "") {
    guard canAct else {
      incomingRequests.append(.open(url, suppliedPassword))
      return
    }
    run {
      guard await self.closeCurrentSession() else { return }
      self.password = suppliedPassword
      await self.perform(.open(url))
    }
  }

  func receiveFinderFiles(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    guard canAct else {
      incomingRequests.append(.files(urls))
      return
    }
    let panel = archivePanel()
    panel.message = "Выберите архив, в который нужно добавить выбранные файлы и папки."
    panel.prompt = "Выбрать архив"
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

  func addDroppedFiles(_ urls: [URL], directory: String = "") {
    guard canModify, !urls.isEmpty, confirmAdding() else { return }
    start(.add(urls, directory))
  }

  func extractSelected() {
    guard canAct, session != nil, !selectedPaths.isEmpty else { return }
    let paths = selectedPaths.sorted()
    let chooser = NSOpenPanel()
    chooser.canChooseDirectories = true
    chooser.canChooseFiles = false
    chooser.canCreateDirectories = true
    chooser.prompt = "Извлечь"
    chooser.message =
      "Выберите папку для выделенных файлов и папок. Существующие объекты не перезаписываются."
    activePanel = chooser
    chooser.begin { [weak self] response in
      Task { @MainActor in
        guard let self else { return }
        self.activePanel = nil
        if response == .OK, let directory = chooser.url {
          self.start(.export(paths, directory))
        } else {
          self.drainIncomingRequests()
        }
      }
    }
  }

  func copySelectedPaths() {
    guard !selectedPaths.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(selectedPaths.sorted().joined(separator: "\n"), forType: .string)
  }

  func beginDragging(id: UUID, paths: [String]) {
    dragLeases[id] = Set(paths)
    updateExportState()
  }

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
        operationMessage = "Извлекаем: " + path
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
        operationMessage = "Извлечено: " + destination.lastPathComponent
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

  private func updateExportState() {
    isExporting = !promiseTasks.isEmpty || !dragLeases.isEmpty
    if !isExporting {
      operationProgress = nil
      promiseTail = nil
      drainIncomingRequests()
    }
  }

  private func settleExports() async {
    for task in promiseTasks.values { task.cancel() }
    promisePasswordReply?.resume(returning: nil)
    promisePasswordReply = nil
    dragLeases.removeAll()
    let tasks = Array(promiseTasks.values)
    for task in tasks { await task.value }
    updateExportState()
  }

  func chooseFilesToAdd() {
    guard canModify else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.prompt = "Добавить"
    let directory = insertionDirectory
    activePanel = panel
    panel.begin { [weak self] response in
      Task { @MainActor in
        guard let self else { return }
        self.activePanel = nil
        guard response == .OK, self.canModify, self.confirmAdding() else {
          self.drainIncomingRequests()
          return
        }
        self.start(.add(panel.urls, directory))
      }
    }
  }

  func deleteSelected() {
    guard canModify, !selectedPaths.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = "Удалить выбранные объекты из архива?"
    alert.informativeText =
      "Объектов: \(selectedPaths.count). Содержимое выбранных папок также будет удалено."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Удалить")
    alert.addButton(withTitle: "Отмена")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let paths = selectedPaths.sorted()
    if activeEdits.contains(where: { edit in
      paths.contains { edit.entry.path == $0 || edit.entry.path.hasPrefix($0 + "/") }
    }) {
      errorMessage = "Сначала сохраните рабочие копии или закройте архив, выбрав «Не сохранять»."
      return
    }
    start(.delete(paths))
  }

  func openSelectedExternally() {
    guard canOpenSelection, let entry = selectedEntry else { return }
    start(.external(entry))
  }

  func editSelected() {
    guard canModify, canOpenSelection, let entry = selectedEntry else { return }
    start(.edit(entry))
  }

  func saveWorkingCopies() {
    guard canModify, !activeEdits.isEmpty else { return }
    start(.save)
  }

  func togglePreview() {
    showsPreview.toggle()
    if showsPreview { selectionChanged() } else { cancelPreview() }
  }

  func focusSearch() { searchFocusToken = UUID() }

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

  func cancelLoading() { cancelCurrentOperation() }

  func cancelPreview() {
    previewGeneration += 1
    previewTask?.cancel()
    if let previewTask { retiredPreviewTasks.append(previewTask) }
    previewTask = nil
    previewURL = nil
    isMaterializing = false
  }

  func cancelPasswordPrompt() {
    promisePasswordReply?.resume(returning: nil)
    promisePasswordReply = nil
    isPasswordPromptPresented = false
    failedOperation = nil
    pendingFinderFiles = []
    drainIncomingRequests()
  }

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

  func closeArchive() {
    guard closingTask == nil else { return }
    closingTask = Task { [weak self] in
      guard let self else { return true }
      let result = await self.shutdown(terminate: false)
      self.closingTask = nil
      return result
    }
  }

  func requestTermination() async -> Bool {
    if let closingTask, !(await closingTask.value) { return false }
    return await shutdown(terminate: true)
  }

  func cleanup() async { _ = await requestTermination() }

  private var insertionDirectory: String {
    guard let path = selectedPath else { return "" }
    if selectedEntry?.isDirectory == true || selectedEntry == nil { return path }
    return path.split(separator: "/").dropLast().joined(separator: "/")
  }

  private func archivePanel() -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.item]
    return panel
  }

  private func confirmAdding() -> Bool {
    let alert = NSAlert()
    alert.messageText = "Добавить файлы в архив?"
    alert.informativeText = "Файлы с совпадающими именами по выбранному пути будут заменены."
    alert.addButton(withTitle: "Добавить")
    alert.addButton(withTitle: "Отмена")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private var progressHandler: ArchiveProgressHandler {
    { [weak self] value in await self?.receiveProgress(value) }
  }

  private func receiveProgress(_ value: ArchiveProgress) { operationProgress = value }

  private func run(_ body: @escaping @MainActor () async -> Void) {
    guard !isBusy, !isClosing else { return }
    isBusy = true
    operationProgress = nil
    actionTask = Task { [weak self] in
      await body()
      self?.operationProgress = nil
      self?.isBusy = false
      self?.actionTask = nil
      if self?.errorMessage == nil { self?.selectionChanged() }
      self?.drainIncomingRequests()
    }
  }

  private func drainIncomingRequests() {
    guard canAct, !incomingRequests.isEmpty else { return }
    let request = incomingRequests.removeFirst()
    switch request {
    case .open(let url, let suppliedPassword): open(url, password: suppliedPassword)
    case .files(let urls): receiveFinderFiles(urls)
    case .finder(let request): receiveFinderRequest(request)
    }
  }

  private func start(_ operation: Operation) {
    guard canAct else { return }
    run { await self.perform(operation) }
  }

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
        session = result
        loadState = .loaded
        if !pendingFinderFiles.isEmpty {
          let urls = pendingFinderFiles
          pendingFinderFiles = []
          if !result.canModify {
            errorMessage = "Этот формат доступен только для чтения."
          } else if confirmAdding() {
            await perform(.add(urls, ""))
            return
          }
        }
      case .create(let urls, let format):
        await settlePreviews()
        let selection = FinderSelection(urls: urls)
        guard let first = urls.first else { throw ArchiveError.invalidOperation }
        operationMessage = "Создаём архив…"
        let proposed = first.deletingLastPathComponent().appendingPathComponent(
          selection.archiveName + "." + format)
        let result = try await service.createArchive(
          from: urls, proposedURL: proposed, format: format, options: ArchivePreferences.options,
          progress: progressHandler)
        NSWorkspace.shared.activateFileViewerSelecting([result])
        operationMessage = "Создан архив: " + result.lastPathComponent
      case .extract(let urls):
        await settlePreviews()
        var results: [URL] = []
        defer { if !results.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(results) } }
        for (index, url) in urls.enumerated() {
          retryOperation = .extract(Array(urls[index...]))
          operationMessage = "Извлекаем \(index + 1) из \(urls.count): \(url.lastPathComponent)"
          results.append(
            try await service.extractArchive(url, password: password, progress: progressHandler))
          password = ""
        }
        operationMessage = "Извлечено архивов: \(results.count)"
      case .export(let paths, let directory):
        guard let session else { throw ArchiveError.sessionExpired }
        await settlePreviews()
        let roots = try ArchiveSelection.topLevelPaths(paths, entries: session.entries)
        var results: [URL] = []
        defer { if !results.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(results) } }
        for (index, path) in roots.enumerated() {
          retryOperation = .export(Array(roots[index...]), directory)
          operationMessage = "Извлекаем: " + path
          let destination = directory.appendingPathComponent(
            String(path.split(separator: "/").last!))
          results.append(
            try await service.exportItem(
              path, from: session, to: destination, password: password, chooseUniqueName: true,
              progress: progressHandler))
        }
        operationMessage = "Извлечено объектов: \(results.count)"
      case .preview:
        return
      case .external(let entry):
        guard let session else { return }
        let url = try await service.materialize(entry, in: session, password: password)
        try Task.checkCancellation()
        if selectedPath == entry.path { openInWorkspace(url) }
      case .edit(let entry):
        guard let session, session.canModify else { return }
        let edit = try await service.beginEditing(entry, in: session, password: password)
        if !activeEdits.contains(where: { $0.id == edit.id }) { activeEdits.append(edit) }
        try Task.checkCancellation()
        if selectedPath == entry.path { openInWorkspace(edit.fileURL) }
      case .add(let urls, let directory):
        guard let session, session.canModify else { return }
        await settlePreviews()
        apply(try await service.add(urls, to: session, directory: directory, password: password))
      case .delete(let paths):
        guard let session, session.canModify else { return }
        await settlePreviews()
        apply(try await service.delete(paths, from: session, password: password))
      case .save:
        guard let session, !activeEdits.isEmpty else { return }
        await settlePreviews()
        apply(try await service.save(activeEdits, in: session, password: password))
        activeEdits.removeAll()
      }
      failedOperation = nil
    } catch is CancellationError {
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
      operationProgress = nil
      failedOperation = retryOperation
      operationMessage = nil
      errorMessage = error.localizedDescription
      if session == nil { loadState = .failed }
    }
  }

  private func apply(_ refreshed: ArchiveSession) {
    session = refreshed
    let validPaths = Set(refreshed.entries.map(\.path)).union(allPaths(refreshed.roots))
    selectedPaths.formIntersection(validPaths)
    selectionChanged()
  }

  private func allPaths(_ nodes: [ArchiveNode]) -> Set<String> {
    nodes.reduce(into: Set<String>()) { result, node in
      result.insert(node.path)
      result.formUnion(allPaths(node.children ?? []))
    }
  }

  private func selectionChanged() {
    cancelPreview()
    guard showsPreview, !isBusy, !isClosing, !isPasswordPromptPresented, let entry = selectedEntry,
      !entry.isDirectory, !entry.isSymbolicLink
    else { return }
    startPreview(entry)
  }

  private func startPreview(_ entry: ArchiveEntry) {
    guard showsPreview, !isBusy, !isClosing, let current = session else { return }
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

  private func settlePreviews() async {
    cancelPreview()
    let tasks = retiredPreviewTasks
    retiredPreviewTasks.removeAll()
    for task in tasks { await task.value }
  }

  private func openInWorkspace(_ url: URL) {
    if !NSWorkspace.shared.open(url) {
      errorMessage = "Не удалось открыть файл во внешнем приложении."
    }
  }

  private func confirmWorkingCopies() async -> Bool {
    guard !activeEdits.isEmpty else { return true }
    let alert = NSAlert()
    alert.messageText = "Сохранить рабочие копии в архив?"
    alert.informativeText =
      "Сначала сохраните файлы во внешнем редакторе. Рабочих копий: \(activeEdits.count). При выборе «Не сохранять» они будут удалены."
    alert.addButton(withTitle: "Сохранить")
    alert.addButton(withTitle: "Не сохранять")
    alert.addButton(withTitle: "Отмена")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      await perform(.save)
      return activeEdits.isEmpty
    case .alertSecondButtonReturn:
      return true
    default:
      return false
    }
  }

  private func closeCurrentSession() async -> Bool {
    await settlePreviews()
    guard !Task.isCancelled, await confirmWorkingCopies() else { return false }
    await settlePreviews()
    do {
      if let session { try await service.close(session) }
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
    session = nil
    operationMessage = nil
    activeEdits.removeAll()
    selectedPaths = []
    searchText = ""
    pendingFinderFiles = []
    errorMessage = nil
    failedOperation = nil
    isPasswordPromptPresented = false
    loadState = .idle
    return true
  }

  private func shutdown(terminate: Bool) async -> Bool {
    guard !isClosing else { return false }
    isClosing = true
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
    await settlePreviews()
    guard await confirmWorkingCopies() else { return false }
    await settlePreviews()
    do {
      if let session { try await service.close(session) }
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
    session = nil
    operationMessage = nil
    activeEdits.removeAll()
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
  func makeNSView(context: Context) -> QLPreviewView {
    let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
    view.previewItem = url as NSURL
    return view
  }
  func updateNSView(_ nsView: QLPreviewView, context: Context) {
    nsView.previewItem = url as NSURL
  }
}
