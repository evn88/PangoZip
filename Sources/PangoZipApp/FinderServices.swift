import AppKit
import PangoZipCore
import UniformTypeIdentifiers

@MainActor
final class FinderServices: NSObject {
  private enum Request {
    case open(URL)
    case add([URL])
    case finder(FinderRequest)
  }

  private var openArchive: ((URL) -> Void)?
  private var addFiles: (([URL]) -> Void)?
  private var finderRequest: ((FinderRequest) -> Void)?
  private var pending: [Request] = []

  /// Сохраняет обработчики до выгрузки запросов, полученных раньше появления окна.
  func configure(
    openArchive: @escaping (URL) -> Void, addFiles: @escaping ([URL]) -> Void,
    finderRequest: @escaping (FinderRequest) -> Void
  ) {
    self.openArchive = openArchive
    self.addFiles = addFiles
    self.finderRequest = finderRequest
    drainPendingRequests()
  }

  /// Принимает локальные URL или проверенный одноразовый запрос через именованный pasteboard.
  func deliverOpenURLs(_ urls: [URL]) {
    deliverFiles(urls.filter(\.isFileURL))
    for url in urls where !url.isFileURL {
      guard let name = FinderRequest.boardName(from: url) else { continue }
      let board = NSPasteboard(name: .init(name))
      defer { board.releaseGlobally() }
      guard let data = board.data(forType: .init(FinderRequest.pasteboardType)),
        let request = try? FinderRequest.decode(data)
      else { continue }
      deliver(.finder(request))
    }
    bringApplicationForward()
  }

  /// Объединяет несколько архивов в один запрос, чтобы модель открыла независимые окна.
  private func deliverFiles(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    if urls.count > 1, let request = try? FinderRequest(action: .open, urls: urls) {
      deliver(.finder(request))
    } else {
      for url in urls { deliver(.open(url)) }
    }
  }

  /// Возвращает ошибку Services при пустом выделении, не открывая панель выбора.
  @objc(openArchiveService:userData:error:)
  func openArchiveService(
    _ pasteboard: NSPasteboard, userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    let urls = fileURLs(from: pasteboard)
    guard !urls.isEmpty else {
      error.pointee =
        L10n.tr("Выберите локальный файл или папку.")
        as NSString
      return
    }
    deliverFiles(urls)
    bringApplicationForward()
  }

  /// Создаёт запрос worker из выделения Finder; ошибки пустого выделения возвращает системе.
  @objc(addToArchiveService:userData:error:)
  func addToArchiveService(
    _ pasteboard: NSPasteboard, userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    let urls = fileURLs(from: pasteboard)
    guard !urls.isEmpty else {
      error.pointee =
        L10n.tr("Не удалось получить выбранные локальные файлы или папки.") as NSString
      return
    }
    if let request = try? FinderRequest(action: .create, urls: urls) { deliver(.finder(request)) }
    bringApplicationForward()
  }

  /// Передаёт ограниченный запрос через pasteboard отдельному экземпляру worker и освобождает его позже.
  static func launchWorker(_ request: FinderRequest) {
    guard let data = try? JSONEncoder().encode(request), data.count <= FinderRequest.maximumBytes
    else { return }
    let token = UUID().uuidString
    let board = NSPasteboard(name: .init(FinderRequest.boardPrefix + token))
    board.clearContents()
    board.setData(data, forType: .init(FinderRequest.pasteboardType))
    guard let url = URL(string: "pangozip-worker://finder?request=" + token) else {
      board.releaseGlobally()
      return
    }
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PangoZipWorker.app")
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = false
    NSWorkspace.shared.open([url], withApplicationAt: helper, configuration: configuration) {
      _, error in
      if error != nil {
        DispatchQueue.main.async {
          NSPasteboard(name: .init(FinderRequest.boardPrefix + token)).releaseGlobally()
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 120) { board.releaseGlobally() }
  }

  /// Сначала читает современные файловые URL, затем поддерживает старый формат Finder Services.
  private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
    let modernURLs =
      (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        as? [URL]) ?? []
    if !modernURLs.isEmpty { return modernURLs.filter(\.isFileURL) }

    let legacyPaths =
      pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
      as? [String] ?? []
    return legacyPaths.map { URL(fileURLWithPath: $0) }
  }

  /// Сохраняет запрос до регистрации всех обработчиков, чтобы запуск приложения не терял события.
  private func deliver(_ request: Request) {
    guard openArchive != nil, addFiles != nil, finderRequest != nil else {
      pending.append(request)
      return
    }
    perform(request)
  }

  /// Очищает очередь до вызова обработчиков, исключая повторную доставку при их побочных действиях.
  private func drainPendingRequests() {
    let requests = pending
    pending.removeAll()
    for request in requests { perform(request) }
  }

  /// Направляет запрос уже зарегистрированному обработчику соответствующего действия.
  private func perform(_ request: Request) {
    switch request {
    case .open(let url): openArchive?(url)
    case .add(let urls): addFiles?(urls)
    case .finder(let request): finderRequest?(request)
    }
  }

  /// Показывает окно worker без смены политики активации основного приложения.
  private func bringApplicationForward() {
    if ApplicationMode.isFinderWorker {
      NSApp.windows.first?.orderFront(nil)
    } else {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
  }
}
