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

  // Размеры одинаковы во всех положениях: от места зависит только точка привязки острова.
  /// Размер ярлычка, который виден, пока курсор далеко.
  static let labelSize = CGSize(width: 138, height: 32)
  /// Размер раскрытой площадки для броска.
  static let openSize = CGSize(width: 340, height: 168)
  static let pillSize = CGSize(width: 370, height: 64)
}

/// Что делает остров с идущей операцией: остаётся на экране или сам уходит в строку меню.
enum DropIslandProgressMode: String, CaseIterable, Identifiable {
  case keep, menuBar

  var id: String { rawValue }

  var title: String {
    switch self {
    case .keep: L10n.tr("Оставлять остров на экране")
    case .menuBar: L10n.tr("Через несколько секунд убирать в строку меню")
    }
  }

  /// Сколько остров виден до ухода в строку меню: хватает, чтобы увидеть, что операция началась.
  static let menuBarDelay: Duration = .seconds(6)
}

@MainActor
enum DropIslandSettings {
  static let enabledKey = "dropIslandEnabled"
  static let progressModeKey = "dropIslandProgressMode"
  static let placementKey = "dropIslandPlacement"
  static let usesDefaultFolderKey = "dropIslandUsesDefaultFolder"
  static let defaultFolderKey = "dropIslandDefaultFolder"

  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
  }

  /// Читает настройку из домена основного приложения: у фонового процесса Finder свой домен.
  static var progressMode: DropIslandProgressMode {
    let defaults = UserDefaults(suiteName: "app.pangozip.desktop") ?? .standard
    return DropIslandProgressMode(rawValue: defaults.string(forKey: progressModeKey) ?? "")
      ?? .keep
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

  @Published var phase = Phase.hidden {
    // Смахнутый остров возвращается на своё место, а не туда, где его отпустили.
    didSet { if oldValue == .hidden, swipe != 0 { swipe = 0 } }
  }
  @Published var placement = DropIslandPlacement.top
  @Published var isExtraction = false
  @Published var title = ""
  @Published var subtitle = ""
  @Published var hint: String?
  @Published var fraction: Double?
  /// Есть ли результат, который можно показать в Finder после завершения.
  @Published var canReveal = true
  @Published var isPaused = false
  /// Насколько остров сдвинут к краю экрана жестом смахивания, в точках.
  @Published var swipe: CGFloat = 0
  var cancel: () -> Void = {}
  /// Убирает идущую операцию в строку меню; nil — смахивать нельзя.
  var minimize: (() -> Void)?
  /// Ставит операцию на паузу и снимает с неё; nil — операция паузу не поддерживает.
  var togglePause: (() -> Void)?
  private var scrollTravel: CGFloat = 0
  var reveal: () -> Void = {}
  var dismiss: () -> Void = {}

  var size: CGSize { size(for: phase) }

  /// Присваивает только новое значение: `@Published` оповещает подписчиков при любой записи,
  /// даже если значение не изменилось.
  func update<Value: Equatable>(
    _ keyPath: ReferenceWritableKeyPath<DropIslandModel, Value>, to value: Value
  ) {
    if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
  }

  /// Куда уходит смахнутый остров: к краю экрана, у которого он стоит (координаты SwiftUI).
  var swipeDirection: CGVector {
    placement == .edge ? CGVector(dx: 1, dy: 0) : CGVector(dx: 0, dy: -1)
  }

  var canSwipe: Bool { phase == .working && minimize != nil }

  /// Остров идёт за пальцами к краю и лишь слегка подаётся в обратную сторону.
  func moveSwipe(_ travel: CGFloat) {
    guard canSwipe else { return }
    swipe = travel >= 0 ? travel : max(-12, travel / 4)
  }

  /// Достаточно сдвинутый или резко брошенный остров уходит в строку меню, иначе возвращается.
  func endSwipe(predicted: CGFloat) {
    guard canSwipe else { return }
    if swipe > 36 || predicted > 110 {
      minimize?()
    } else {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { swipe = 0 }
    }
  }

  /// Жест двумя пальцами по трекпаду над островом. Инерция после жеста не учитывается,
  /// а колесо мыши без точных значений остров не сдвигает.
  func scroll(_ event: NSEvent) -> Bool {
    guard canSwipe, event.hasPreciseScrollingDeltas else { return false }
    guard event.momentumPhase.isEmpty else { return true }
    // При «естественной» прокрутке значения уже совпадают с движением пальцев.
    let inverted = event.isDirectionInvertedFromDevice
    let right = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
    let up = inverted ? -event.scrollingDeltaY : event.scrollingDeltaY
    switch event.phase {
    case .began:
      scrollTravel = 0
    case .changed:
      scrollTravel += placement == .edge ? right : up
      moveSwipe(scrollTravel)
    case .ended, .cancelled:
      endSwipe(predicted: swipe)
      scrollTravel = 0
    default:
      break
    }
    return true
  }

  func size(for phase: Phase) -> CGSize {
    switch phase {
    case .hidden, .label: DropIslandPlacement.labelSize
    case .open, .hot: DropIslandPlacement.openSize
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

  /// Всё, что нужно подписи площадки, для одного набора файлов; описания — по состоянию Option.
  private struct PlanCache {
    struct Description {
      let isExtraction: Bool
      let subtitle: String
      let hint: String?
    }

    let urls: [URL]
    let defaultFolder: URL?
    let format: String
    var descriptions: [Bool: Description] = [:]
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
  /// Счётчик drag-pasteboard, с которого прочитаны `draggedURLs`: пока он не изменился,
  /// повторно читать pasteboard незачем.
  private var draggedChangeCount: Int?
  /// План броска на время перетаскивания: опрос идёт 20 раз в секунду, а сборка плана
  /// обращается к файловой системе и настройкам.
  private var planCache: PlanCache?
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
  private var feedbackID: UUID?
  /// Значок в строке меню, куда смахнули остров с идущей операцией.
  private let statusItem = ProgressStatusItem()
  private var minimized = false
  private var remaining: TimeInterval?
  /// Отложенный уход острова в строку меню, если так выбрано в настройках.
  private var autoMinimizeTask: Task<Void, Never>?

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
    model.minimize = { [weak self] in self?.minimize() }
    model.togglePause = { [weak self] in self?.togglePause() }
    let card = statusItem.card
    card.cancel = model.cancel
    card.reveal = model.reveal
    card.togglePause = model.togglePause
    card.restore = { [weak self] in self?.restore() }
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
      let urls = draggedFileURLs(board)
      guard !urls.isEmpty else { return }
      beginSession(urls)
    }
    guard session == .label || session == .open else { return }
    // Остров раскрывается только вплотную к ярлычку, чтобы не мешать перетаскиванию мимо него.
    let isOpen = DropIslandProximity.isOpen(
      wasOpen: session == .open, mouse: NSEvent.mouseLocation,
      label: islandRect(for: DropIslandPlacement.labelSize),
      open: islandRect(for: DropIslandPlacement.openSize))
    session = isOpen ? .open : .label
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
    forgetDrag()
    refresh()
  }

  private func forgetDrag() {
    draggedURLs = []
    draggedChangeCount = nil
    planCache = nil
  }

  /// Файлы перетаскивания; pasteboard читается заново, только когда его содержимое сменилось.
  private func draggedFileURLs(_ board: NSPasteboard) -> [URL] {
    if board.changeCount == draggedChangeCount, !draggedURLs.isEmpty { return draggedURLs }
    let urls = Self.fileURLs(board)
    if !urls.isEmpty {
      draggedURLs = urls
      draggedChangeCount = board.changeCount
    }
    return urls
  }

  private static func fileURLs(_ board: NSPasteboard) -> [URL] {
    guard board.types?.contains(.fileURL) == true else { return [] }
    return board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      as? [URL] ?? []
  }

  // MARK: - Состояние и окно

  /// Сводит состояние перетаскивания и операций в одну фазу и обновляет подписи.
  private func refresh() {
    defer { syncCard() }
    let phase: DropIslandModel.Phase
    // Смахнутая операция живёт в строке меню; остров при этом свободен для нового броска.
    switch (session, minimized ? Work.idle : work) {
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
      model.update(\.title, to: workTitle)
      model.update(\.subtitle, to: workSubtitle)
      model.update(\.hint, to: nil)
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
    guard let description = dropDescription(optionPressed: option) else { return }
    let isExtraction = description.isExtraction
    let title =
      !isHot
      ? L10n.tr("Перетащите сюда")
      : isExtraction ? L10n.tr("Отпустите — распакуем") : L10n.tr("Отпустите — сожмём")
    // Опрос повторяет одни и те же значения: присваиваем только изменения, иначе остров
    // со всеми слоями стекла перерисовывается на каждом тике.
    model.update(\.isExtraction, to: isExtraction)
    model.update(\.title, to: title)
    model.update(\.subtitle, to: description.subtitle)
    model.update(\.hint, to: description.hint)
  }

  /// Подпись места и подсказка Option для текущего набора файлов; пересчитываются,
  /// только когда меняется набор или состояние Option.
  private func dropDescription(optionPressed option: Bool) -> PlanCache.Description? {
    if let planCache, planCache.urls == draggedURLs {
      if let cached = planCache.descriptions[option] { return cached }
    } else {
      planCache = PlanCache(
        urls: draggedURLs, defaultFolder: DropIslandSettings.defaultFolder,
        format: ArchivePreferences.options.format)
    }
    guard var cache = planCache,
      let plan = DropIslandPlan(
        urls: cache.urls, optionPressed: option, defaultFolder: cache.defaultFolder)
    else { return nil }
    let isExtraction = plan.action == .extract
    let name = plan.resultName(format: cache.format)
    let subtitle: String
    if isExtraction {
      if let name {
        let parent = plan.urls[0].deletingLastPathComponent().lastPathComponent
        subtitle = parent + " / " + name + " /"
      } else {
        subtitle = L10n.tr(
          "Архивов: %1$@ — каждый в свою папку", String(describing: plan.urls.count))
      }
    } else if case .directory(let directory) = plan.destination, let name {
      subtitle = directory.lastPathComponent + " / " + name
    } else {
      subtitle = L10n.tr("Место сохранения выберете сами")
    }
    let hint: String? =
      option
      ? nil
      : plan.containsOnlyArchives
        ? L10n.tr("⌥ — сжать в новый архив") : L10n.tr("⌥ — выбрать место")
    let description = PlanCache.Description(
      isExtraction: isExtraction, subtitle: subtitle, hint: hint)
    cache.descriptions[option] = description
    planCache = cache
    return description
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
      let open = DropIslandPlacement.openSize
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
    let hosting = IslandHostingView(rootView: DropIslandView(model: model))
    hosting.sizingOptions = []
    hosting.onScroll = { [weak model] event in model?.scroll(event) ?? false }
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
    let urls = draggedFileURLs(sender.draggingPasteboard)
    guard !urls.isEmpty else { return [] }
    // Окно шире острова на поля для тени и анимации: бросок принимает только сам остров.
    let mouse = NSEvent.mouseLocation
    let island = islandRect(for: model.size)
    guard island.contains(mouse) else {
      if session == .hot {
        session = .open
        refresh()
      }
      return []
    }
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
    forgetDrag()
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
    chooser.allowedContentTypes = [ArchiveFormatPresentation.contentType(for: format)]
    chooser.allowsOtherFileTypes = true
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
    remaining = nil
    service.pause.resume()
    model.isPaused = false
    work = .working
    updateStage()
    scheduleAutoMinimize()
    let task = Task { try await self.perform(job) }
    jobTask = task
    let feedbackID = OperationFeedback.shared.begin(
      kind: isExtraction ? .extract : .create, subject: workTitle)
    self.feedbackID = feedbackID
    var outcome = OperationOutcome.success
    do {
      let result = try await task.value
      resultURL = result
      workTitle = result.lastPathComponent
      workSubtitle = L10n.tr("Готово")
      work = .done
    } catch is CancellationError {
      outcome = .cancelled
      work = .idle
    } catch {
      outcome = .failure(error.localizedDescription)
      workSubtitle = error.localizedDescription
      work = .failed
    }
    jobTask = nil
    autoMinimizeTask?.cancel()
    service.pause.resume()
    model.isPaused = false
    self.feedbackID = nil
    OperationFeedback.shared.finish(feedbackID, outcome: outcome)
    // Ошибку показывает остров: в строке меню её легко не заметить.
    if work == .failed { restore() }
    refresh()
    guard work != .idle else {
      if jobs.isEmpty { restore() }
      return
    }
    // Результат остаётся на виду, но следующая операция в очереди ждёт недолго.
    let delay: Duration =
      !jobs.isEmpty ? .seconds(1.5) : work == .failed ? .seconds(20) : .seconds(6)
    let pause = Task { _ = try? await Task.sleep(for: delay) }
    pauseTask = pause
    await pause.value
    pauseTask = nil
    work = .idle
    // Значок уходит из строки меню вместе с последней операцией очереди.
    if jobs.isEmpty, minimized {
      minimized = false
      statusItem.hide()
    }
    refresh()
  }

  private func perform(_ job: Job) async throws -> URL {
    let handler: ArchiveProgressHandler = { [weak self] value in await self?.receive(value) }
    if job.plan.action == .compress, let proposed = job.proposedURL {
      let outcome = try await service.createArchives(
        from: job.plan.urls, proposedURL: proposed, format: job.options.format,
        options: job.options, separately: ArchivePreferences.separatesArchives,
        trashesSources: ArchivePreferences.trashesSources, progress: handler)
      if let failure = outcome.trashFailure { throw SourceTrashFailure(message: failure) }
      return outcome.urls.last ?? proposed
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
    if let feedbackID {
      OperationFeedback.shared.update(feedbackID, fraction: DockProgress.fraction(of: progress))
    }
    model.update(\.fraction, to: progress.fraction)
    remaining = progress.remainingSeconds
    updateStage()
  }

  /// Строка под именем: этап, процент и число ожидающих операций.
  private func updateStage() {
    var parts = [model.isPaused ? L10n.tr("На паузе") : stageTitle]
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

  // MARK: - Строка меню и пауза

  /// Убирает остров с идущей операцией в строку меню.
  private func minimize() {
    guard work == .working, !minimized else { return }
    minimized = true
    statusItem.show()
    refresh()
  }

  /// По настройке остров уходит в строку меню сам, если его не трогают и не бросают на него файлы.
  private func scheduleAutoMinimize() {
    autoMinimizeTask?.cancel()
    guard !minimized, DropIslandSettings.progressMode == .menuBar else { return }
    autoMinimizeTask = Task { [weak self] in
      try? await Task.sleep(for: DropIslandProgressMode.menuBarDelay)
      guard let self, !Task.isCancelled, self.session == .none else { return }
      self.minimize()
    }
  }

  /// Возвращает операцию на остров.
  private func restore() {
    autoMinimizeTask?.cancel()
    guard minimized else { return }
    minimized = false
    statusItem.hide()
    refresh()
  }

  private func togglePause() {
    guard work == .working else { return }
    if service.pause.isPaused { service.pause.resume() } else { service.pause.pause() }
    model.isPaused = service.pause.isPaused
    updateStage()
  }

  /// Переносит подписи острова в карточку строки меню.
  private func syncCard() {
    guard minimized else { return }
    let card = statusItem.card
    card.update(\.title, to: workTitle)
    card.update(\.stage, to: workSubtitle)
    card.update(\.fraction, to: model.fraction)
    card.update(\.remaining, to: remaining)
    card.update(\.isPaused, to: model.isPaused)
    card.update(\.state, to: work == .done ? .done : .working)
    card.update(\.canReveal, to: resultURL != nil)
  }
}
