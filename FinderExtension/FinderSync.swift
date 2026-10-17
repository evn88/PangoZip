import AppKit
import FinderSync
import OSLog

@objc(FinderSync)
final class FinderSync: FIFinderSync {
  private let applicationURL = FinderInstallation.applicationURL(for: Bundle.main.bundleURL)
  private lazy var menuIcon = Self.loadMenuIcon()
  private var requests: [Int: FinderRequest] = [:]
  private var nextTag = 1
  private let logger = Logger(subsystem: "app.pangozip.desktop.finder", category: "requests")
  /// Наблюдает локальные тома для контекстного меню без обхода файлов и установки значков.
  override init() {
    super.init()
    // Меню для локальных томов; значки и обход файловой системы не нужны.
    FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    logger.notice("Finder menu provider initialized")
  }

  /// Создаёт меню из снимка выделения только при наличии основного приложения и помощника.
  override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    let selectedURLs = FIFinderSyncController.default().selectedItemURLs() ?? []
    logger.notice(
      "Finder menu requested: kind=\(menuKind.rawValue) selection=\(selectedURLs.count)")
    guard FinderInstallation.isInstalledLocation(applicationURL),
      FinderInstallation.isAvailable(at: applicationURL),
      menuKind == .contextualMenuForItems || menuKind == .contextualMenuForSidebar
    else {
      return nil
    }
    let selection = FinderSelection(urls: selectedURLs)
    guard !selection.actions.isEmpty else { return nil }
    let menu = NSMenu()
    let root = NSMenuItem(title: "PangoZip", action: nil, keyEquivalent: "")
    root.image = menuIcon
    let submenu = NSMenu(title: "PangoZip")
    for action in selection.actions {
      if action == .create && !selection.archives.isEmpty { submenu.addItem(.separator()) }
      let item = NSMenuItem(
        title: selection.title(for: action), action: #selector(deliver(_:)), keyEquivalent: "")
      item.target = self
      // Снимок выделения принадлежит конкретному меню, а не следующему событию Finder.
      item.tag = nextTag
      nextTag += 1
      requests[item.tag] = try? selection.request(for: action)
      if requests.count > 256, let oldest = requests.keys.min() {
        requests.removeValue(forKey: oldest)
      }
      submenu.addItem(item)
    }
    root.submenu = submenu
    menu.addItem(root)
    return menu
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
    guard let request = requests.removeValue(forKey: sender.tag),
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
