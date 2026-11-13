import Darwin
import Foundation

/// Состояние элемента файловой системы с точки зрения облачных провайдеров (iCloud, File Provider).
enum CloudItemState: Equatable, Sendable {
  case file(dataless: Bool)
  case directory(dataless: Bool)
  case other

  /// Только обычный файл без локальных данных требует загрузки; папки лишь обходятся.
  var needsDownload: Bool {
    if case .file(let dataless) = self { return dataless }
    return false
  }
}

/// Источник сведений и загрузчик; подменяется в тестах, так как настоящего облака там нет.
protocol CloudItemProvider: Sendable {
  /// Не следует по ссылкам; для старой заглушки `.Имя.icloud` возвращает состояние несуществующего `Имя`.
  func state(of url: URL) throws -> CloudItemState
  /// Содержимое папки; старые заглушки `.Имя.icloud` отображаются под настоящим именем.
  func children(of directory: URL) throws -> [URL]
  /// Запускает загрузку. Может вернуться сразу (iCloud) или после полной загрузки (чтение файла).
  func startDownload(of url: URL) async throws
  /// Занятое на диске место: его рост считается признаком живой загрузки.
  func allocatedBytes(of url: URL) -> UInt64
}

/// Параметры ожидания; в тестах заменяются короткими значениями.
struct CloudTiming: Sendable {
  var pollInterval: Duration = .milliseconds(500)
  /// Максимальное время без завершённых файлов и без роста данных на диске.
  var stallTimeout: Duration = .seconds(120)
  var concurrency = 4
}

public enum CloudFiles {
  /// Загружает все локально отсутствующие файлы (рекурсивно) и ждёт завершения. Загруженное не трогает.
  public static func materialize(_ urls: [URL], progress: ArchiveProgressHandler? = nil)
    async throws
  {
    try await materialize(
      urls, provider: SystemCloudProvider(), timing: CloudTiming(), progress: progress)
  }

  /// Загружает архив и его тома (`.001`, `.z01`, `.r01`), лежащие рядом.
  public static func materializeArchive(_ url: URL, progress: ArchiveProgressHandler? = nil)
    async throws
  {
    try await materializeArchive(
      url, provider: SystemCloudProvider(), timing: CloudTiming(), progress: progress)
  }

  static func materializeArchive(
    _ url: URL, provider: CloudItemProvider, timing: CloudTiming,
    progress: ArchiveProgressHandler?
  ) async throws {
    guard url.isFileURL else { return }
    let siblings =
      (try? provider.children(of: url.deletingLastPathComponent()))?
      .filter { isVolume(of: url.lastPathComponent, candidate: $0.lastPathComponent) } ?? []
    try await materialize(
      [url] + siblings, provider: provider, timing: timing, progress: progress)
  }

  /// Определяет по имени, что кандидат — другой том того же многотомного архива.
  static func isVolume(of name: String, candidate: String) -> Bool {
    guard candidate != name else { return false }
    let url = URL(fileURLWithPath: name)
    let ext = url.pathExtension.lowercased()
    let stem = url.deletingPathExtension().lastPathComponent
    let other = URL(fileURLWithPath: candidate)
    let otherExt = other.pathExtension.lowercased()
    let otherStem = other.deletingPathExtension().lastPathComponent
    func numbered(_ value: String) -> Bool {
      !value.isEmpty && value.count <= 8 && value.allSatisfy { $0.isASCII && $0.isNumber }
    }
    func letterVolume(_ value: String) -> Bool {
      guard let first = value.first, "zr".contains(first) else { return false }
      return numbered(String(value.dropFirst()))
    }
    // Разделённые архивы: name.7z.001, name.7z.002.
    if numbered(ext) { return otherStem == stem && numbered(otherExt) }
    // Тома ZIP/RAR: name.zip + name.z01, name.rar + name.r00.
    if ["zip", "rar"].contains(ext) || letterVolume(ext) {
      return otherStem == stem && (letterVolume(otherExt) || ["zip", "rar"].contains(otherExt))
    }
    return false
  }

  static func materialize(
    _ urls: [URL], provider: CloudItemProvider, timing: CloudTiming,
    progress: ArchiveProgressHandler?
  ) async throws {
    let pending = try await collect(urls, provider: provider)
    guard !pending.isEmpty else { return }
    let reporter = ArchiveProgressReporter(progress)
    let tracker = DownloadTracker(provider: provider)
    await reporter.report(
      phase: .downloading, fraction: 0, completedFiles: 0, totalFiles: pending.count)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await watch(tracker, timing: timing) }
      group.addTask {
        try await downloadAll(
          pending, provider: provider, timing: timing, tracker: tracker, reporter: reporter)
      }
      // Первым завершается либо загрузка (успех), либо наблюдатель (тайм-аут).
      try await group.next()
      group.cancelAll()
    }
    try Task.checkCancellation()
  }

  /// Обходит дерево вне исполнителя; каждый путь учитывается один раз, ссылки не раскрываются.
  private static func collect(_ urls: [URL], provider: CloudItemProvider) async throws -> [URL] {
    let task = Task.detached(priority: .userInitiated) { () throws -> [URL] in
      var stack = Array(urls.reversed())
      var seen: Set<String> = []
      var result: [URL] = []
      while let url = stack.popLast() {
        try Task.checkCancellation()
        guard url.isFileURL, seen.insert(url.standardizedFileURL.path).inserted else { continue }
        let state: CloudItemState
        do { state = try provider.state(of: url) } catch { throw map(error) }
        switch state {
        case .file(let dataless): if dataless { result.append(url) }
        case .directory:
          let children: [URL]
          do { children = try provider.children(of: url) } catch { throw map(error) }
          stack.append(contentsOf: children.reversed())
        case .other: continue
        }
      }
      return result
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func downloadAll(
    _ items: [URL], provider: CloudItemProvider, timing: CloudTiming, tracker: DownloadTracker,
    reporter: ArchiveProgressReporter
  ) async throws {
    try await withThrowingTaskGroup(of: URL.self) { group in
      var next = 0
      var done = 0
      func launch() {
        let item = items[next]
        next += 1
        group.addTask {
          await tracker.started(item)
          try await download(item, provider: provider, timing: timing)
          await tracker.finished(item)
          return item
        }
      }
      while next < items.count, next < max(1, timing.concurrency) { launch() }
      while let finished = try await group.next() {
        done += 1
        await reporter.report(
          phase: .downloading, fraction: Double(done) / Double(items.count),
          completedFiles: done, totalFiles: items.count, currentFile: finished.lastPathComponent)
        if next < items.count { launch() }
      }
    }
  }

  /// Запрашивает загрузку и опрашивает состояние, пока данные не появятся локально.
  private static func download(_ url: URL, provider: CloudItemProvider, timing: CloudTiming)
    async throws
  {
    do {
      try await provider.startDownload(of: url)
      while try provider.state(of: url).needsDownload {
        try Task.checkCancellation()
        try await Task.sleep(for: timing.pollInterval)
      }
    } catch {
      throw map(error)
    }
  }

  /// Срабатывает, если ни один файл не завершился и объём данных на диске не растёт.
  private static func watch(_ tracker: DownloadTracker, timing: CloudTiming) async throws {
    while !Task.isCancelled {
      do { try await Task.sleep(for: timing.pollInterval) } catch { return }
      await tracker.sample()
      if await tracker.idle() > timing.stallTimeout { throw ArchiveError.cloudDownloadTimedOut }
    }
  }

  /// Отмена остаётся отменой; сетевые сбои получают отдельное сообщение.
  static func map(_ error: Error) -> Error {
    if error is CancellationError || error is ArchiveError { return error }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain,
      [
        NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorDataNotAllowed,
      ].contains(nsError.code)
    {
      return ArchiveError.cloudOffline
    }
    if nsError.domain == NSPOSIXErrorDomain,
      [Int(ENETDOWN), Int(ENETUNREACH), Int(ETIMEDOUT), Int(EHOSTUNREACH)].contains(nsError.code)
    {
      return ArchiveError.cloudOffline
    }
    return ArchiveError.cloudDownloadFailed
  }
}

/// Учитывает завершения и рост занятого места, чтобы отличить медленную загрузку от зависшей.
private actor DownloadTracker {
  private let provider: CloudItemProvider
  private var inFlight: Set<URL> = []
  private var lastBytes: UInt64 = 0
  private var lastProgress = ContinuousClock.now

  init(provider: CloudItemProvider) { self.provider = provider }

  func started(_ url: URL) { inFlight.insert(url) }

  func finished(_ url: URL) {
    inFlight.remove(url)
    lastProgress = .now
  }

  func sample() {
    var total: UInt64 = 0
    for url in inFlight { total &+= provider.allocatedBytes(of: url) }
    if total != lastBytes {
      lastBytes = total
      lastProgress = .now
    }
  }

  func idle() -> Duration { .now - lastProgress }
}

/// Системная реализация: флаг SF_DATALESS (APFS, File Provider) и заглушки `.icloud` старого формата.
struct SystemCloudProvider: CloudItemProvider {
  /// Значение SF_DATALESS из sys/stat.h: данные файла хранятся у провайдера.
  private static let datalessFlag: UInt32 = 0x4000_0000

  func state(of url: URL) throws -> CloudItemState {
    var status = stat()
    if lstat(url.path, &status) != 0 {
      let code = errno
      var stub = stat()
      if code == ENOENT, lstat(Self.stubURL(for: url).path, &stub) == 0 {
        return .file(dataless: true)
      }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    let dataless = status.st_flags & Self.datalessFlag != 0
    switch status.st_mode & S_IFMT {
    case S_IFREG:
      if dataless,
        let failure = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey]))?
          .ubiquitousItemDownloadingError
      {
        throw failure
      }
      return .file(dataless: dataless)
    case S_IFDIR: return .directory(dataless: dataless)
    default: return .other
    }
  }

  func children(of directory: URL) throws -> [URL] {
    var status = stat()
    if lstat(directory.path, &status) == 0, status.st_flags & Self.datalessFlag != 0,
      (try? directory.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    {
      try? FileManager.default.startDownloadingUbiquitousItem(at: directory)
    }
    var seen: Set<String> = []
    var result: [URL] = []
    for child in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    {
      let name = child.lastPathComponent
      let real =
        name.hasPrefix(".") && name.hasSuffix(".icloud") && name.count > 8
        ? directory.appendingPathComponent(String(name.dropFirst().dropLast(7))) : child
      if seen.insert(real.lastPathComponent).inserted { result.append(real) }
    }
    return result
  }

  func startDownload(of url: URL) async throws {
    var status = stat()
    let isStub = lstat(url.path, &status) != 0
    let ubiquitous = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem
    if isStub || ubiquitous == true {
      // Для iCloud вызов лишь ставит загрузку в очередь; готовность проверяет опрос состояния.
      do {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        return
      } catch {
        if isStub { throw error }
      }
    }
    try await Self.readFirstByte(of: url)
  }

  func allocatedBytes(of url: URL) -> UInt64 {
    var status = stat()
    guard lstat(url.path, &status) == 0 else { return 0 }
    return UInt64(max(0, status.st_blocks)) * 512
  }

  private static func stubURL(for url: URL) -> URL {
    url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
  }

  /// Скоординированное чтение первого байта заставляет любой File Provider выгрузить файл целиком.
  /// Блокирующее чтение нельзя прервать: при отмене ожидание завершается сразу, а поток доработает сам.
  private static func readFirstByte(of url: URL) async throws {
    let once = OnceResult()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        once.install(continuation)
        DispatchQueue.global(qos: .userInitiated).async {
          once.finish(Result { try blockingRead(url) })
        }
      }
    } onCancel: {
      once.finish(.failure(CancellationError()))
    }
  }

  private static func blockingRead(_ url: URL) throws {
    var coordinationError: NSError?
    var readError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
      readingItemAt: url, options: [.withoutChanges], error: &coordinationError
    ) { readURL in
      do {
        let handle = try FileHandle(forReadingFrom: readURL)
        defer { try? handle.close() }
        _ = try handle.read(upToCount: 1)
      } catch {
        readError = error
      }
    }
    if let coordinationError { throw coordinationError }
    if let readError { throw readError }
  }
}

/// Возобновляет продолжение ровно один раз: по завершению чтения либо по отмене.
private final class OnceResult: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var result: Result<Void, Error>?

  func install(_ continuation: CheckedContinuation<Void, Error>) {
    lock.lock()
    if let result {
      lock.unlock()
      continuation.resume(with: result)
    } else {
      self.continuation = continuation
      lock.unlock()
    }
  }

  func finish(_ value: Result<Void, Error>) {
    lock.lock()
    guard result == nil else {
      lock.unlock()
      return
    }
    result = value
    let waiting = continuation
    continuation = nil
    lock.unlock()
    waiting?.resume(with: value)
  }
}
