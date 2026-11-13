import AppKit
import OSLog
import UniformTypeIdentifiers

/// Обработчик Quick Action без собственного интерфейса: берёт файлы Finder, формирует запрос
/// и передаёт его worker так же, как это делает Finder Sync, после чего сразу завершает запрос.
@objc(QuickActionHandler)
final class QuickActionHandler: NSObject, NSExtensionRequestHandling {
  private let logger = Logger(subsystem: "app.pangozip.desktop.quickaction", category: "requests")

  /// Точка входа системы; действие определяется ключом Info.plist конкретного appex.
  func beginRequest(with context: NSExtensionContext) {
    let completion = Completion(context: context)
    guard
      let name = Bundle.main.object(forInfoDictionaryKey: QuickAction.infoKey) as? String,
      let action = QuickAction(rawValue: name)
    else {
      completion.cancel()
      return
    }
    let providers = context.inputItems.compactMap { ($0 as? NSExtensionItem)?.attachments }
      .flatMap { $0 }
      .filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    guard !providers.isEmpty else {
      completion.cancel()
      return
    }
    let collector = URLCollector()
    let group = DispatchGroup()
    for provider in providers {
      group.enter()
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
        if let url = QuickAction.fileURL(from: item) { collector.append(url) }
        group.leave()
      }
    }
    let logger = logger
    group.notify(queue: .main) {
      guard let request = try? action.request(for: collector.urls) else {
        // Например, «Распаковать здесь» на файле, который не является архивом.
        logger.notice("Quick action skipped: no suitable items")
        NSSound.beep()
        completion.cancel()
        return
      }
      Self.deliver(request, logger: logger, completion: completion)
    }
  }

  /// Передаёт ограниченный запрос через отдельный pasteboard, не меняя общий буфер обмена.
  private static func deliver(_ request: FinderRequest, logger: Logger, completion: Completion) {
    let applicationURL = FinderInstallation.applicationURL(for: Bundle.main.bundleURL)
    guard FinderInstallation.isInstalledLocation(applicationURL),
      FinderInstallation.isAvailable(at: applicationURL),
      let data = try? JSONEncoder().encode(request), data.count <= FinderRequest.maximumBytes
    else {
      logger.error("Quick action skipped: application unavailable or request invalid")
      NSSound.beep()
      completion.cancel()
      return
    }
    let token = UUID().uuidString
    let board = NSPasteboard(name: .init(FinderRequest.boardPrefix + token))
    board.clearContents()
    guard board.setData(data, forType: .init(FinderRequest.pasteboardType)),
      let url = URL(string: "pangozip-worker://finder?request=" + token)
    else {
      board.releaseGlobally()
      NSSound.beep()
      completion.cancel()
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = false
    let worker = applicationURL.appendingPathComponent("Contents/Helpers/PangoZipWorker.app")
    logger.notice("Launching quick action: \(request.action.rawValue, privacy: .public)")
    NSWorkspace.shared.open([url], withApplicationAt: worker, configuration: configuration) {
      _, error in
      DispatchQueue.main.async {
        if let error {
          let failure = error as NSError
          logger.error(
            "Quick action launch failed: \(failure.domain, privacy: .public) \(failure.code)")
          NSPasteboard(name: .init(FinderRequest.boardPrefix + token)).releaseGlobally()
          completion.cancel()
        } else {
          // Канал освобождает worker после чтения; процесс расширения после завершения не живёт.
          completion.finish()
        }
      }
    }
  }
}

/// NSExtensionContext не Sendable; завершение запроса всегда выполняется на главной очереди.
private final class Completion: @unchecked Sendable {
  private let context: NSExtensionContext
  init(context: NSExtensionContext) { self.context = context }

  func finish() { context.completeRequest(returningItems: nil, completionHandler: nil) }

  func cancel() {
    context.cancelRequest(
      withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
  }
}

/// Собирает URL из параллельных обработчиков загрузки; порядок не важен, повторы убирает запрос.
private final class URLCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var collected: [URL] = []

  func append(_ url: URL) {
    lock.lock()
    collected.append(url)
    lock.unlock()
  }

  var urls: [URL] {
    lock.lock()
    defer { lock.unlock() }
    return collected
  }
}
