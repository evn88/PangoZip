import AppKit
import FinderSync
import OSLog

@objc(FinderSync)
final class FinderSync: FIFinderSync {
  private let applicationURL = FinderInstallation.applicationURL(for: Bundle.main.bundleURL)
  private lazy var menuIcon = Self.loadMenuIcon()
  private var requests: [Int: PendingRequest] = [:]
  private var nextTag = 1
  private let logger = Logger(subsystem: "app.pangozip.desktop.finder", category: "requests")
  /// Наблюдает локальные тома для контекстного меню без обхода файлов и установки значков.
  override init() {
    super.init()
    // Меню для локальных томов; значки и обход файловой системы не нужны.
    FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    logger.notice("Finder menu provider initialized")
  }

  /// Кнопка в панели инструментов Finder. В папках File Provider (iCloud Drive и т. п.) Finder
  /// не запрашивает у расширения контекстное меню файлов, а меню этой кнопки запрашивает.
  override var toolbarItemName: String { "PangoZip" }

  override var toolbarItemToolTip: String { L10n.tr("Действия PangoZip с выделенными объектами") }

  /// Плоская контурная версия иконки приложения: Finder сам красит шаблон под тему и состояние.
  override var toolbarItemImage: NSImage {
    let image =
      Bundle.main.url(forResource: "ToolbarIcon", withExtension: "pdf").flatMap {
        NSImage(contentsOf: $0)
      }
      ?? NSImage(systemSymbolName: "archivebox", accessibilityDescription: "PangoZip")
      ?? NSImage()
    image.size = NSSize(width: 18, height: 18)
    image.isTemplate = true
    return image
  }

  /// Создаёт меню из снимка выделения только при наличии основного приложения и помощника.
  override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    let selectedURLs = FIFinderSyncController.default().selectedItemURLs() ?? []
    logger.notice(
      "Finder menu requested: kind=\(menuKind.rawValue) selection=\(selectedURLs.count)")
    guard FinderInstallation.isInstalledLocation(applicationURL),
      FinderInstallation.isAvailable(at: applicationURL)
    else {
      return nil
    }
    let selection = FinderSelection(urls: selectedURLs)
    switch menuKind {
    case .contextualMenuForItems, .contextualMenuForSidebar:
      guard !selection.actions.isEmpty else { return nil }
      let menu = NSMenu()
      let root = NSMenuItem(title: "PangoZip", action: nil, keyEquivalent: "")
      root.image = menuIcon
      let submenu = NSMenu(title: "PangoZip")
      addItems(for: selection, to: submenu)
      root.submenu = submenu
      menu.addItem(root)
      return menu
    case .toolbarItemMenu:
      let menu = NSMenu(title: "PangoZip")
      if selection.actions.isEmpty {
        // В iCloud Drive выделение в момент построения меню пустое: файлы читаются при нажатии.
        addDeferredItems(to: menu)
      } else {
        addItems(for: selection, to: menu)
      }
      return menu
    default:
      return nil
    }
  }

  /// Добавляет пункты со снимком текущего выделения и именами результатов.
  private func addItems(for selection: FinderSelection, to menu: NSMenu) {
    for action in selection.actions {
      if action == .create && !selection.archives.isEmpty { menu.addItem(.separator()) }
      let item = makeItem(title: selection.title(for: action))
      // Снимок выделения принадлежит конкретному меню, а не следующему событию Finder.
      remember(.snapshot((try? selection.request(for: action))), for: item.tag)
      menu.addItem(item)
    }
  }

  /// Добавляет постоянный набор пунктов; выделение будет прочитано в момент нажатия.
  private func addDeferredItems(to menu: NSMenu) {
    for action in FinderSelection.deferredActions {
      if action == .create { menu.addItem(.separator()) }
      let item = makeItem(title: action.title)
      remember(.deferred(action), for: item.tag)
      menu.addItem(item)
    }
  }

  private func makeItem(title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(deliver(_:)), keyEquivalent: "")
    item.target = self
    item.tag = nextTag
    nextTag += 1
    return item
  }

  private func remember(_ pending: PendingRequest, for tag: Int) {
    requests[tag] = pending
    if requests.count > 256, let oldest = requests.keys.min() {
      requests.removeValue(forKey: oldest)
    }
  }

  /// Загружает цветную иконку из собственного комплекта, доступного песочнице расширения.
  private static func loadMenuIcon() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
      let image = NSImage(contentsOf: url)
    else { return NSImage(systemSymbolName: "archivebox", accessibilityDescription: "PangoZip") }
    image.size = NSSize(width: 16, height: 16)
    image.isTemplate = false
    return image
  }

  /// Передаёт ограниченный запрос через отдельный pasteboard, не меняя общий буфер обмена.
  @objc private func deliver(_ sender: NSMenuItem) {
    guard FinderInstallation.isInstalledLocation(applicationURL),
      FinderInstallation.isAvailable(at: applicationURL)
    else {
      requests.removeAll()
      // Разовый отказ метаданных при обновлении приложения не должен отключать меню навсегда.
      // Следующий запрос Finder повторит проверку, удалённое приложение по-прежнему не допускается.
      logger.notice("Finder action skipped: containing application is unavailable")
      return
    }
    let request: FinderRequest?
    switch requests.removeValue(forKey: sender.tag) {
    case .snapshot(let snapshot): request = snapshot
    case .deferred(let action):
      // Пункт кнопки панели инструментов: Finder отдаёт выделение только сейчас.
      let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
      request = try? FinderSelection(urls: urls).request(for: action)
      if request == nil {
        logger.notice(
          "Finder toolbar action skipped: \(action.rawValue, privacy: .public) selection=\(urls.count)"
        )
      }
    case nil: request = nil
    }
    guard let request,
      let data = try? JSONEncoder().encode(request), data.count <= FinderRequest.maximumBytes
    else {
      logger.error("Missing or invalid Finder menu request")
      NSSound.beep()
      return
    }
    let token = UUID().uuidString
    let board = NSPasteboard(name: .init(FinderRequest.boardPrefix + token))
    board.clearContents()
    guard board.setData(data, forType: .init(FinderRequest.pasteboardType)),
      let url = URL(
        string: (request.action == .open ? "pangozip" : "pangozip-worker") + "://finder?request="
          + token)
    else {
      board.releaseGlobally()
      NSSound.beep()
      return
    }
    var app = applicationURL
    let configuration = NSWorkspace.OpenConfiguration()
    if request.action != .open {
      configuration.createsNewApplicationInstance = true
      app = app.appendingPathComponent("Contents/Helpers/PangoZipWorker.app")
      configuration.activates = false
    }
    logger.notice("Launching Finder action: \(request.action.rawValue, privacy: .public)")
    let logger = self.logger
    NSWorkspace.shared.open(
      [url], withApplicationAt: app, configuration: configuration
    ) { _, error in
      if let error {
        let failure = error as NSError
        logger.error("Finder launch failed: \(failure.domain, privacy: .public) \(failure.code)")
        DispatchQueue.main.async {
          NSPasteboard(name: .init(FinderRequest.boardPrefix + token)).releaseGlobally()
        }
      }
    }
    // Канал не меняет общий буфер обмена и не оставляет файлов на диске.
    DispatchQueue.main.asyncAfter(deadline: .now() + 120) { board.releaseGlobally() }
  }
}

/// Запрос пункта меню: готовый снимок выделения или действие, выделение для которого
/// читается при нажатии (меню кнопки панели инструментов в папках File Provider).
private enum PendingRequest {
  case snapshot(FinderRequest?)
  case deferred(FinderAction)
}
