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

  func configure(
    openArchive: @escaping (URL) -> Void, addFiles: @escaping ([URL]) -> Void,
    finderRequest: @escaping (FinderRequest) -> Void
  ) {
    self.openArchive = openArchive
    self.addFiles = addFiles
    self.finderRequest = finderRequest
    drainPendingRequests()
  }

  func deliverOpenURLs(_ urls: [URL]) {
    for url in urls {
      if url.isFileURL {
        deliver(.open(url))
        continue
      }
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

  @objc(openArchiveService:userData:error:)
  func openArchiveService(
    _ pasteboard: NSPasteboard, userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    guard let url = fileURLs(from: pasteboard).first else {
      error.pointee =
        NSLocalizedString("Выберите локальный файл или папку.", comment: "Ошибка Finder Services")
        as NSString
      return
    }
    deliver(.open(url))
    bringApplicationForward()
  }

  @objc(addToArchiveService:userData:error:)
  func addToArchiveService(
    _ pasteboard: NSPasteboard, userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    let urls = fileURLs(from: pasteboard)
    guard !urls.isEmpty else {
      error.pointee =
        NSLocalizedString(
          "Не удалось получить выбранные локальные файлы или папки.",
          comment: "Ошибка Finder Services") as NSString
      return
    }
    if let request = try? FinderRequest(action: .create, urls: urls) { deliver(.finder(request)) }
    bringApplicationForward()
  }

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

  private func deliver(_ request: Request) {
    guard openArchive != nil, addFiles != nil, finderRequest != nil else {
      pending.append(request)
      return
    }
    perform(request)
  }

  private func drainPendingRequests() {
    let requests = pending
    pending.removeAll()
    for request in requests { perform(request) }
  }

  private func perform(_ request: Request) {
    switch request {
    case .open(let url): openArchive?(url)
    case .add(let urls): addFiles?(urls)
    case .finder(let request): finderRequest?(request)
    }
  }

  private func bringApplicationForward() {
    if ApplicationMode.isFinderWorker {
      NSApp.windows.first?.orderFront(nil)
    } else {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
  }
}
