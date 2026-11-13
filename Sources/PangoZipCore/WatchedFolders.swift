import Foundation

/// Куда и как извлекать архив из отслеживаемой папки. Правило содержит список назначений:
/// позже у назначения появятся условия (расширение, маска имени), сейчас оно одно и безусловное.
public struct WatchedDestination: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  /// Путь папки назначения; nil означает «в ту же папку».
  public var directoryPath: String?
  /// Переместить архив (все тома) в Корзину после успешного извлечения.
  public var deletesArchive: Bool

  public init(id: UUID = UUID(), directoryPath: String? = nil, deletesArchive: Bool = false) {
    self.id = id
    self.directoryPath = directoryPath
    self.deletesArchive = deletesArchive
  }
}

/// Правило слежения: папка и список назначений.
public struct WatchedFolderRule: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  public var folderPath: String
  public var isEnabled: Bool
  public var destinations: [WatchedDestination]

  public init(
    id: UUID = UUID(), folderPath: String, isEnabled: Bool = true,
    destinations: [WatchedDestination] = [WatchedDestination()]
  ) {
    self.id = id
    self.folderPath = folderPath
    self.isEnabled = isEnabled
    self.destinations = destinations
  }

  public var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }

  /// Папка назначения для конкретного назначения.
  public func directory(for destination: WatchedDestination) -> URL {
    destination.directoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? folderURL
  }
}

/// Задание на извлечение, которое выдаёт логика слежения.
public struct WatchedFolderJob: Sendable, Equatable {
  public let ruleID: UUID
  public let archive: URL
  public let directory: URL
  public let deletesArchive: Bool
}

/// Сериализация правил в UserDefaults: JSON с номером версии для будущих миграций.
public enum WatchedFolderStore {
  public static let key = "watchedFolderRules"
  private static let version = 1

  private struct Envelope: Codable {
    var version: Int
    var rules: [WatchedFolderRule]
  }

  public static func encode(_ rules: [WatchedFolderRule]) -> Data {
    (try? JSONEncoder().encode(Envelope(version: version, rules: rules))) ?? Data()
  }

  /// Повреждённые или пустые данные дают пустой список, а не ошибку.
  public static func decode(_ data: Data?) -> [WatchedFolderRule] {
    guard let data, !data.isEmpty,
      let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
    else { return [] }
    return envelope.rules
  }

  public static func load(from defaults: UserDefaults = .standard) -> [WatchedFolderRule] {
    decode(defaults.data(forKey: key))
  }

  public static func save(_ rules: [WatchedFolderRule], to defaults: UserDefaults = .standard) {
    defaults.set(encode(rules), forKey: key)
  }
}

/// Отбор имён, которые нельзя трогать: скрытые, временные и незавершённые загрузки.
public enum WatchedFileFilter {
  private static let temporarySuffixes = [
    ".download", ".crdownload", ".part", ".partial", ".tmp", ".temp", ".opdownload",
    ".filepart", ".aria2", ".!ut", ".swp", ".lock",
  ]

  public static func isIgnored(name: String) -> Bool {
    let lower = name.lowercased()
    if lower.hasPrefix(".") || lower.hasPrefix("~") || lower.hasSuffix("~") { return true }
    return temporarySuffixes.contains { lower.hasSuffix($0) }
  }
}

/// Размер и время изменения файла в момент опроса папки.
public struct WatchedFileSnapshot: Sendable, Equatable {
  public let url: URL
  public let size: UInt64
  public let modified: Date

  public init(url: URL, size: UInt64, modified: Date) {
    self.url = url
    self.size = size
    self.modified = modified
  }
}

/// Чистая логика «что делать с новым файлом»: без файловой системы, часов и наблюдения.
/// Обрабатываются только файлы, которых не было при старте; файл ждёт стабильного размера
/// и выдаётся в работу один раз.
public struct WatchedFolderTracker: Sendable {
  public static let stabilityInterval: TimeInterval = 2

  private struct Pending {
    var size: UInt64
    var modified: Date
    var since: Date
  }

  public let rule: WatchedFolderRule
  private var baseline: Set<String>
  private var pending: [String: Pending] = [:]
  private var handled: Set<String> = []

  /// `existingNames` — имена файлов, уже лежавших в папке к началу наблюдения.
  public init(rule: WatchedFolderRule, existingNames: Set<String>) {
    self.rule = rule
    baseline = existingNames
  }

  /// Есть файлы, которые ещё ждут окончания записи: опрос нужно продолжать.
  public var hasPending: Bool { !pending.isEmpty }

  /// Принимает текущий список обычных файлов папки и возвращает задания для готовых архивов.
  public mutating func update(
    files: [WatchedFileSnapshot], now: Date,
    isOwnOutput: (URL) -> Bool = { _ in false }
  ) -> [WatchedFolderJob] {
    let present = Set(files.map { $0.url.lastPathComponent })
    // Исчезнувший файл забывается: новый файл с тем же именем снова считается новым.
    baseline.formIntersection(present)
    handled.formIntersection(present)
    pending = pending.filter { present.contains($0.key) }
    guard rule.isEnabled else { return [] }

    var jobs: [WatchedFolderJob] = []
    for file in files.sorted(by: { $0.url.lastPathComponent < $1.url.lastPathComponent }) {
      let name = file.url.lastPathComponent
      guard !baseline.contains(name), !handled.contains(name),
        !WatchedFileFilter.isIgnored(name: name),
        ArchiveVolumes.isArchiveName(name),
        ArchiveVolumes.role(ofName: name) != .later
      else { continue }
      if isOwnOutput(file.url) {
        handled.insert(name)
        pending[name] = nil
        continue
      }
      guard var state = pending[name] else {
        pending[name] = Pending(size: file.size, modified: file.modified, since: now)
        continue
      }
      if state.size != file.size || state.modified != file.modified {
        state = Pending(size: file.size, modified: file.modified, since: now)
        pending[name] = state
        continue
      }
      guard file.size > 0, now.timeIntervalSince(state.since) >= Self.stabilityInterval else {
        continue
      }
      pending[name] = nil
      handled.insert(name)
      // Сейчас у правила одно безусловное назначение; при появлении условий здесь выбираются подходящие.
      if let destination = rule.destinations.first {
        jobs.append(
          WatchedFolderJob(
            ruleID: rule.id, archive: file.url, directory: rule.directory(for: destination),
            deletesArchive: destination.deletesArchive))
      }
    }
    return jobs
  }
}
