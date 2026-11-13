import AppKit
import PangoZipCore
import SwiftUI
import UniformTypeIdentifiers

/// Где появляется остров: под строкой меню, у правого края экрана или рядом с курсором.
enum DropIslandPlacement: String, CaseIterable, Identifiable {
  case top, edge, cursor

  var id: String { rawValue }

  var title: String {
    switch self {
    case .top: L10n.tr("Сверху")
    case .edge: L10n.tr("Справа")
    case .cursor: L10n.tr("У курсора")
    }
  }

  /// Размер ярлычка, который виден, пока курсор далеко.
  var labelSize: CGSize {
    switch self {
    case .top: CGSize(width: 138, height: 32)
    case .edge: CGSize(width: 40, height: 124)
    case .cursor: CGSize(width: 52, height: 52)
    }
  }

  /// Размер раскрытой площадки для броска.
  var openSize: CGSize {
    switch self {
    case .top: CGSize(width: 440, height: 176)
    case .edge: CGSize(width: 300, height: 236)
    case .cursor: CGSize(width: 330, height: 200)
    }
  }

  static let pillSize = CGSize(width: 370, height: 64)
}

@MainActor
enum DropIslandSettings {
  static let enabledKey = "dropIslandEnabled"
  static let placementKey = "dropIslandPlacement"
  static let usesDefaultFolderKey = "dropIslandUsesDefaultFolder"
  static let defaultFolderKey = "dropIslandDefaultFolder"

  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
  }

  static var placement: DropIslandPlacement {
    DropIslandPlacement(rawValue: UserDefaults.standard.string(forKey: placementKey) ?? "") ?? .top
  }

  /// Папка по умолчанию действует, только если опция включена и папка существует.
  static var defaultFolder: URL? {
    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: usesDefaultFolderKey),
      let path = defaults.string(forKey: defaultFolderKey), !path.isEmpty
    else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }
}

@MainActor
final class DropIslandModel: ObservableObject {
  enum Phase: Equatable {
    case hidden, label, open, hot, working, done, failed
  }

  @Published var phase = Phase.hidden
  @Published var placement = DropIslandPlacement.top
  @Published var isExtraction = false
  @Published var title = ""
  @Published var subtitle = ""
  @Published var hint: String?
  @Published var fraction: Double?
  var cancel: () -> Void = {}
  var reveal: () -> Void = {}
  var dismiss: () -> Void = {}

  var size: CGSize { size(for: phase) }

  func size(for phase: Phase) -> CGSize {
    switch phase {
    case .hidden, .label: placement.labelSize
    case .open, .hot: placement.openSize
    case .working, .done, .failed: DropIslandPlacement.pillSize
    }
  }
}

/// Следит за перетаскиванием файлов из других программ и выполняет брошенные на остров операции.
@MainActor
final class DropIslandController: NSObject, NSWindowDelegate, NSDraggingDestination {
  static let shared = DropIslandController()

  private enum Session {
    case none, label, open, hot
  }

  private enum Work {
    case idle, working, done, failed
  }

  private struct Job {
    let plan: DropIslandPlan
    let proposedURL: URL?
    let options: CompressionOptions
  }

  let model = DropIslandModel()
  private let service = ArchiveService()
  private var session = Session.none
  private var work = Work.idle
  private var workTitle = ""
  private var workSubtitle = ""
  private var stageTitle = ""
  private var resultURL: URL?
  private var monitor: Any?
  private var panel: NSPanel?
  private var dragChangeAtMouseDown = 0
  private var draggedURLs: [URL] = []
  /// Option в момент последнего опроса: клавишу часто отпускают одновременно с кнопкой мыши.
  private var optionWhileHovering = false
  private var visibleFrame = NSRect.zero
  private var anchorGeneration = 0
  private var panelGeneration = -1
  private var dragOrigin = NSPoint.zero
  private var jobs: [Job] = []
  private var trackTask: Task<Void, Never>?
  private var runner: Task<Void, Never>?
  private var jobTask: Task<URL, any Error>?
  private var pauseTask: Task<Void, Never>?
  private var shrinkTask: Task<Void, Never>?

  var isBusy: Bool { work == .working || !jobs.isEmpty }

  override private init() {
    super.init()
    model.cancel = { [weak self] in self?.jobTask?.cancel() }
    model.dismiss = { [weak self] in self?.dismissResult() }
    model.reveal = { [weak self] in
      guard let self, let url = self.resultURL else { return }
      NSWorkspace.shared.activateFileViewerSelecting([url])
      self.dismissResult()
    }
  }

  /// Включает или выключает слежение согласно настройке; вызывается при запуске и её смене.
  func applySettings() {
    if DropIslandSettings.isEnabled {
      guard monitor == nil else { return }
      // Нажатие в чужой программе запускает короткий опрос: само перетаскивание событий не шлёт.
      monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
        MainActor.assumeIsolated { self?.mouseWentDown() }
      }
    } else {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      trackTask?.cancel()
      session = .none
      refresh()
    }
  }

  /// Отменяет операции и ждёт очистки временных файлов перед завершением приложения.
  func prepareTermination() async {
    jobs.removeAll()
    jobTask?.cancel()
    pauseTask?.cancel()
    await runner?.value
    await service.cleanup()
  }

  // MARK: - Слежение за перетаскиванием

  private func mouseWentDown() {
    dragChangeAtMouseDown = NSPasteboard(name: .drag).changeCount
    guard trackTask == nil else { return }
    trackTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(50))
        guard let self, NSEvent.pressedMouseButtons & 1 == 1 else { break }
        self.trackDrag()
      }
      guard let self else { return }
      self.trackTask = nil
      // Бросок на остров приходит отдельным вызовом; даём ему опередить скрытие.
      try? await Task.sleep(for: .milliseconds(250))
      if NSEvent.pressedMouseButtons & 1 == 0 { self.endSession() }
    }
  }

  /// Новое содержимое drag-pasteboard с файлами означает начало перетаскивания.
  private func trackDrag() {
    if session == .none {
      let board = NSPasteboard(name: .drag)
      guard board.changeCount != dragChangeAtMouseDown else { return }
      let urls = Self.fileURLs(board)
      guard !urls.isEmpty else { return }
      beginSession(urls)
    }
    guard session == .label || session == .open else { return }
    let mouse = NSEvent.mouseLocation
    let label = islandRect(for: model.placement.labelSize)
    let distance = hypot(mouse.x - label.midX, mouse.y - label.midY)
    // У курсора ярлычок появляется близко, поэтому и раскрывается только вплотную.
    let near: CGFloat = model.placement == .cursor ? 130 : 260
    if session == .label, distance < near {
      session = .open
    } else if session == .open, distance > near + 70 {
      session = .label
    }
    refresh()
  }

  private func beginSession(_ urls: [URL]) {
    draggedURLs = urls
    // Пока на экране строка операции, остров остаётся на прежнем месте.
    if work == .idle {
      dragOrigin = NSEvent.mouseLocation
      let screen =
        NSScreen.screens.first { $0.frame.contains(dragOrigin) } ?? NSScreen.main
        ?? NSScreen.screens[0]
      visibleFrame = screen.visibleFrame
      model.placement = DropIslandSettings.placement
      anchorGeneration += 1
    }
    session = .label
    refresh()
  }

  private func endSession() {
    guard session != .none else { return }
    session = .none
    draggedURLs = []
    refresh()
  }

  private static func fileURLs(_ board: NSPasteboard) -> [URL] {
    guard board.types?.contains(.fileURL) == true else { return [] }
    return board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      as? [URL] ?? []
  }

  // MARK: - Состояние и окно

  /// Сводит состояние перетаскивания и операций в одну фазу и обновляет подписи.
  private func refresh() {
    let phase: DropIslandModel.Phase
    switch (session, work) {
    case (.hot, _): phase = .hot
    case (_, .working): phase = .working
    case (_, .done): phase = .done
    case (_, .failed): phase = .failed
    case (.open, _): phase = .open
    case (.label, _): phase = .label
    default: phase = .hidden
    }
    switch phase {
    case .label, .open, .hot: describeDrop(isHot: phase == .hot)
    case .working, .done, .failed:
      model.title = workTitle
      model.subtitle = workSubtitle
      model.hint = nil
    case .hidden: break
    }
    guard phase != model.phase else { return }
    if phase != .hidden { showPanel(for: phase) }
    model.phase = phase
    scheduleShrink()
  }

  /// Подписи площадки: что произойдёт при броске и что изменит клавиша Option.
  private func describeDrop(isHot: Bool) {
    let option = NSEvent.modifierFlags.contains(.option)
    guard
      let plan = DropIslandPlan(
        urls: draggedURLs, optionPressed: option, defaultFolder: DropIslandSettings.defaultFolder)
    else { return }
    let isExtraction = plan.action == .extract
    let name = plan.resultName(format: ArchivePreferences.options.format)
    model.isExtraction = isExtraction
    if !isHot {
      model.title = L10n.tr("Перетащите сюда")
    } else {
      model.title =
        isExtraction ? L10n.tr("Отпустите — распакуем") : L10n.tr("Отпустите — сожмём")
    }
    if isExtraction {
      if let name {
        let parent = plan.urls[0].deletingLastPathComponent().lastPathComponent
        model.subtitle = parent + " / " + name + " /"
      } else {
        model.subtitle = L10n.tr(
          "Архивов: %1$@ — каждый в свою папку", String(describing: plan.urls.count))
      }
    } else if case .directory(let directory) = plan.destination, let name {
      model.subtitle = directory.lastPathComponent + " / " + name
    } else {
      model.subtitle = L10n.tr("Место сохранения выберете сами")
    }
    if option {
      model.hint = nil
    } else {
      model.hint =
        plan.containsOnlyArchives
        ? L10n.tr("⌥ — сжать в новый архив") : L10n.tr("⌥ — выбрать место")
    }
  }

  /// Прямоугольник острова на экране для заданного размера.
  private func islandRect(for size: CGSize) -> NSRect {
    let frame = visibleFrame
    switch model.placement {
    case .top:
      return NSRect(
        x: frame.midX - size.width / 2, y: frame.maxY - 6 - size.height, width: size.width,
        height: size.height)
    case .edge:
      return NSRect(
        x: frame.maxX - 8 - size.width, y: frame.midY - size.height / 2, width: size.width,
        height: size.height)
    case .cursor:
      // Площадка рядом с местом захвата, но целиком в пределах экрана.
      let open = model.placement.openSize
      let x = min(
        max(dragOrigin.x + 190, frame.minX + open.width / 2 + 12),
        frame.maxX - open.width / 2 - 12)
      let y = min(
        max(dragOrigin.y + 120, frame.minY + open.height / 2 + 12),
        frame.maxY - open.height / 2 - 12)
      return NSRect(
        x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height)
    }
  }

  /// Окно растёт сразу, чтобы анимация не обрезалась; лишнее место убирается позже.
  private func showPanel(for phase: DropIslandModel.Phase) {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    var target = islandRect(for: model.size(for: phase))
    // Объединять можно только с окном того же места привязки, иначе остров съедет.
    if panel.isVisible, panelGeneration == anchorGeneration {
      let current = panel.frame.insetBy(dx: DropIslandView.margin, dy: DropIslandView.margin)
      target = target.union(current)
    }
    panel.setFrame(
      target.insetBy(dx: -DropIslandView.margin, dy: -DropIslandView.margin), display: true)
    panelGeneration = anchorGeneration
    panel.orderFrontRegardless()
  }

  /// После анимации окно сжимается до острова, чтобы не перекрывать соседние окна.
  private func scheduleShrink() {
    shrinkTask?.cancel()
    shrinkTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(600))
      guard let self, !Task.isCancelled, let panel = self.panel else { return }
      if self.model.phase == .hidden {
        panel.orderOut(nil)
      } else {
        panel.setFrame(
          self.islandRect(for: self.model.size)
            .insetBy(dx: -DropIslandView.margin, dy: -DropIslandView.margin), display: true)
      }
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .statusBar
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    let hosting = NSHostingView(rootView: DropIslandView(model: model))
    hosting.sizingOptions = []
    panel.contentView = hosting
    panel.registerForDraggedTypes([.fileURL])
    panel.delegate = self
    return panel
  }

  // MARK: - Приём броска

  func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { hover(sender) }

  func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { hover(sender) }

  func draggingExited(_ sender: (any NSDraggingInfo)?) {
    guard session == .hot else { return }
    session = .open
    refresh()
  }

  /// Вызывается периодически, поэтому нажатие Option отражается в подписи без движения мыши.
  private func hover(_ sender: any NSDraggingInfo) -> NSDragOperation {
    let urls = Self.fileURLs(sender.draggingPasteboard)
    guard !urls.isEmpty else { return [] }
    draggedURLs = urls
    optionWhileHovering = NSEvent.modifierFlags.contains(.option)
    session = .hot
    refresh()
    return .copy
  }

  func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let urls = Self.fileURLs(sender.draggingPasteboard)
    guard
      let plan = DropIslandPlan(
        urls: urls,
        optionPressed: optionWhileHovering || NSEvent.modifierFlags.contains(.option),
        defaultFolder: DropIslandSettings.defaultFolder)
    else { return false }
    optionWhileHovering = false
    session = .none
    draggedURLs = []
    refresh()
    Task { await accept(plan) }
    return true
  }

  // MARK: - Операции

  /// Уточняет место сохранения и ставит операцию в очередь острова.
  private func accept(_ plan: DropIslandPlan) async {
    let options = ArchivePreferences.options
    var proposed: URL?
    if plan.action == .compress {
      let name = plan.resultName(format: options.format) ?? "Archive." + options.format
      if case .directory(let directory) = plan.destination,
        FileManager.default.isWritableFile(atPath: directory.path)
      {
        proposed = directory.appendingPathComponent(name)
      } else {
        guard let chosen = await askLocation(name: name, near: plan.urls[0], format: options.format)
        else { return }
        proposed = chosen
      }
    }
    jobs.append(Job(plan: plan, proposedURL: proposed, options: options))
    pauseTask?.cancel()
    guard runner == nil else { return }
    runner = Task { [weak self] in
      while let self, !self.jobs.isEmpty {
        await self.run(self.jobs.removeFirst())
      }
      self?.runner = nil
    }
  }

  private func askLocation(name: String, near url: URL, format: String) async -> URL? {
    let chooser = NSSavePanel()
    chooser.title = L10n.tr("Добавить в архив")
    chooser.prompt = L10n.tr("Сжать")
    chooser.directoryURL = url.deletingLastPathComponent()
    chooser.nameFieldStringValue = name
    chooser.allowedContentTypes = [UTType(filenameExtension: format) ?? .data]
    chooser.canCreateDirectories = true
    NSApp.activate(ignoringOtherApps: true)
    let response = await withCheckedContinuation { continuation in
      chooser.begin { continuation.resume(returning: $0) }
    }
    return response == .OK ? chooser.url : nil
  }

  private func askPassword(for url: URL) -> String? {
    let alert = NSAlert()
    alert.messageText = L10n.tr("Введите пароль: %1$@", String(describing: url.lastPathComponent))
    alert.addButton(withTitle: L10n.tr("Продолжить"))
    alert.addButton(withTitle: L10n.tr("Отмена"))
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.placeholderString = L10n.tr("Пароль архива")
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
  }

  private func run(_ job: Job) async {
    let isExtraction = job.plan.action == .extract
    stageTitle = isExtraction ? L10n.tr("Распаковываем…") : L10n.tr("Сжимаем…")
    workTitle = job.proposedURL?.lastPathComponent ?? job.plan.urls[0].lastPathComponent
    model.fraction = nil
    resultURL = nil
    work = .working
    updateStage()
    let task = Task { try await self.perform(job) }
    jobTask = task
    do {
      let result = try await task.value
      resultURL = result
      workTitle = result.lastPathComponent
      workSubtitle = L10n.tr("Готово")
      work = .done
    } catch is CancellationError {
      work = .idle
    } catch {
      workSubtitle = error.localizedDescription
      work = .failed
    }
    jobTask = nil
    refresh()
    guard work != .idle else { return }
    // Результат остаётся на виду, но следующая операция в очереди ждёт недолго.
    let delay: Duration =
      !jobs.isEmpty ? .seconds(1.5) : work == .failed ? .seconds(20) : .seconds(6)
    let pause = Task { _ = try? await Task.sleep(for: delay) }
    pauseTask = pause
    await pause.value
    pauseTask = nil
    work = .idle
    refresh()
  }

  private func perform(_ job: Job) async throws -> URL {
    let handler: ArchiveProgressHandler = { [weak self] value in await self?.receive(value) }
    if job.plan.action == .compress, let proposed = job.proposedURL {
      return try await service.createArchive(
        from: job.plan.urls, proposedURL: proposed, format: job.options.format,
        options: job.options, progress: handler)
    }
    var result = job.plan.urls[0]
    let preferences = ExtractionPreferences.load()
    for url in job.plan.urls {
      workTitle = url.lastPathComponent
      model.fraction = nil
      updateStage()
      var password = ""
      while true {
        try Task.checkCancellation()
        do {
          result = try await service.extractAndFinish(
            url, password: password, smartExtraction: preferences.smartExtraction,
            trashesArchive: preferences.trashesArchive, progress: handler
          ).url
          break
        } catch ArchiveError.passwordRequired {
          guard let answer = askPassword(for: url) else { throw CancellationError() }
          password = answer
        }
      }
    }
    return result
  }

  private func receive(_ progress: ArchiveProgress) {
    model.fraction = progress.fraction
    updateStage()
  }

  /// Строка под именем: этап, процент и число ожидающих операций.
  private func updateStage() {
    var parts = [stageTitle]
    if let fraction = model.fraction { parts.append("\(Int((fraction * 100).rounded()))%") }
    if !jobs.isEmpty {
      parts.append(L10n.tr("Ещё в очереди: %1$@", String(describing: jobs.count)))
    }
    workSubtitle = parts.joined(separator: " · ")
    refresh()
  }

  private func dismissResult() {
    guard work == .done || work == .failed else { return }
    pauseTask?.cancel()
  }
}
