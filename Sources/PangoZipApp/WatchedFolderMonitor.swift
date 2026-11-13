import Foundation
import OSLog
import PangoZipCore

/// Запись журнала слежения, видимая в настройках.
struct WatchedFolderEvent: Identifiable, Equatable {
  enum Kind: Equatable {
    case extracted(result: String)
    case needsPassword
    case failed(message: String)
    case trashFailed(message: String)
  }

  let id = UUID()
  let date: Date
  let archiveName: String
  let kind: Kind

  var text: String {
    switch kind {
    case .extracted(let result):
      L10n.tr("Извлечён: %1$@ → %2$@", String(describing: archiveName), String(describing: result))
    case .needsPassword:
      L10n.tr("Пропущен, нужен пароль: %1$@", String(describing: archiveName))
    case .failed(let message):
      L10n.tr(
        "Ошибка извлечения %1$@: %2$@", String(describing: archiveName),
        String(describing: message))
    case .trashFailed(let message):
      L10n.tr(
        "Не удалось переместить %1$@ в Корзину: %2$@", String(describing: archiveName),
        String(describing: message))
    }
  }
}

/// Следит за папками из настроек и автоматически извлекает новые архивы.
/// Работает в основном приложении, в том числе в фоновом режиме без окон.
@MainActor
final class WatchedFolderMonitor: ObservableObject {
  static let shared = WatchedFolderMonitor()

  @Published private(set) var events: [WatchedFolderEvent] = []
  @Published private(set) var isExtracting = false

  private let service = ArchiveService()
  private let logger = Logger(subsystem: "app.pangozip.desktop", category: "watched-folders")
  private var watches: [UUID: FolderWatch] = [:]
  private var queue: [WatchedFolderJob] = []
  private var worker: Task<Void, Never>?
  private var isTerminating = false

  var isBusy: Bool { isExtracting || !queue.isEmpty }

  /// Есть ли включённые правила: от этого зависит, остаётся ли приложение в фоне.
  static var isActive: Bool { isActive(rules: WatchedFolderStore.load()) }

  static func isActive(rules: [WatchedFolderRule]) -> Bool {
    rules.contains { $0.isEnabled }
  }

  /// Приводит набор наблюдателей в соответствие с настройками; вызывается при запуске и правках.
  func reload() {
    guard !isTerminating else { return }
    let rules = WatchedFolderStore.load().filter(\.isEnabled)
    for (id, watch) in watches where !rules.contains(where: { $0.id == id }) {
      watch.stop()
      watches[id] = nil
    }
    for rule in rules {
      if let existing = watches[rule.id] {
        if existing.rule == rule { continue }
        existing.stop()
      }
      // Новая или изменённая папка: файлы, которые лежат в ней сейчас, не трогаем.
      let watch = FolderWatch(rule: rule) { [weak self] jobs in self?.enqueue(jobs) }
      watches[rule.id] = watch
      watch.start()
    }
  }

  /// Останавливает слежение, отменяет работу и ждёт очистки временных файлов.
  func prepareTermination() async {
    isTerminating = true
    for watch in watches.values { watch.stop() }
    watches = [:]
    queue.removeAll()
    worker?.cancel()
    await worker?.value
    await service.cleanup()
  }

  private func enqueue(_ jobs: [WatchedFolderJob]) {
    guard !jobs.isEmpty, !isTerminating else { return }
    queue.append(contentsOf: jobs)
    guard worker == nil else { return }
    worker = Task { [weak self] in
      await self?.drain()
      self?.worker = nil
    }
  }

  /// Обрабатывает очередь по одному заданию; ошибка одного архива не останавливает остальные.
  private func drain() async {
    isExtracting = true
    defer { isExtracting = false }
    let preferences = ExtractionPreferences.load()
    while !queue.isEmpty, !Task.isCancelled {
      let job = queue.removeFirst()
      let name = job.archive.lastPathComponent
      do {
        let outcome = try await service.extractAndFinish(
          job.archive, directory: job.directory, createsSubfolder: true,
          smartExtraction: preferences.smartExtraction, trashesArchive: job.deletesArchive)
        logger.notice("Watched archive extracted")
        record(.extracted(result: outcome.url.lastPathComponent), name: name)
        if let failure = outcome.trashFailure { record(.trashFailed(message: failure), name: name) }
      } catch ArchiveError.passwordRequired {
        // Модальное окно в фоне неуместно: архив пропускается, запись остаётся в журнале.
        logger.notice("Watched archive skipped: password required")
        record(.needsPassword, name: name)
      } catch is CancellationError {
        break
      } catch {
        logger.error("Watched archive failed: \(error.localizedDescription, privacy: .public)")
        record(.failed(message: error.localizedDescription), name: name)
      }
    }
    await service.cleanup()
  }

  private func record(_ kind: WatchedFolderEvent.Kind, name: String) {
    events.insert(WatchedFolderEvent(date: Date(), archiveName: name, kind: kind), at: 0)
    if events.count > 20 { events.removeLast(events.count - 20) }
  }
}

/// Наблюдение за одной папкой: событие каталога запускает опрос, пока есть файлы в ожидании.
@MainActor
private final class FolderWatch {
  let rule: WatchedFolderRule
  private var tracker: WatchedFolderTracker
  private let deliver: ([WatchedFolderJob]) -> Void
  private var source: DispatchSourceFileSystemObject?
  private var timer: Timer?
  private var ticks = 0

  init(rule: WatchedFolderRule, deliver: @escaping ([WatchedFolderJob]) -> Void) {
    self.rule = rule
    self.deliver = deliver
    tracker = WatchedFolderTracker(rule: rule, existingNames: [])
  }

  func start() {
    let existing = Set(Self.scan(rule.folderURL).map { $0.url.lastPathComponent })
    tracker = WatchedFolderTracker(rule: rule, existingNames: existing)
    attachSource()
    // Страховочный опрос: каталог могли удалить и создать заново, события тогда теряются.
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    source?.cancel()
    source = nil
  }

  private func attachSource() {
    source?.cancel()
    source = nil
    let descriptor = open(rule.folderPath, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let watcher = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .link], queue: .main)
    watcher.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.scanNow() }
    }
    watcher.setCancelHandler { close(descriptor) }
    watcher.resume()
    source = watcher
  }

  private func tick() {
    ticks += 1
    if source == nil { attachSource() }
    if tracker.hasPending || ticks % 10 == 0 { scanNow() }
  }

  private func scanNow() {
    let jobs = tracker.update(
      files: Self.scan(rule.folderURL), now: Date(),
      isOwnOutput: { OwnOutputRegistry.shared.contains($0) })
    deliver(jobs)
  }

  /// Читает только обычные файлы верхнего уровня; папка может быть недоступна — тогда список пуст.
  private static func scan(_ folder: URL) -> [WatchedFileSnapshot] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    else { return [] }
    return urls.compactMap { url in
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
        values.isRegularFile == true
      else { return nil }
      return WatchedFileSnapshot(
        url: url, size: UInt64(values.fileSize ?? 0),
        modified: values.contentModificationDate ?? .distantPast)
    }
  }
}
