import Foundation

/// Пользовательские настройки извлечения целых архивов.
public struct ExtractionPreferences: Sendable, Equatable {
  public static let smartKey = "smartExtraction"
  public static let revealKey = "revealAfterExtraction"
  public static let trashKey = "trashArchiveAfterExtraction"
  /// Домен основного приложения: worker и расширения читают настройки оттуда же.
  public static let domain = "app.pangozip.desktop"

  /// Не создавать папку с именем архива, если в корне ровно один объект.
  public var smartExtraction = true
  /// Показывать результат в Finder.
  public var revealsResult = true
  /// Переместить архив (все тома) в Корзину после успешного извлечения.
  public var trashesArchive = false

  public init(
    smartExtraction: Bool = true, revealsResult: Bool = true, trashesArchive: Bool = false
  ) {
    self.smartExtraction = smartExtraction
    self.revealsResult = revealsResult
    self.trashesArchive = trashesArchive
  }

  /// Читает настройки; отсутствующие значения заменяются значениями по умолчанию.
  public static func load(from defaults: UserDefaults? = nil) -> ExtractionPreferences {
    let defaults = defaults ?? UserDefaults(suiteName: domain) ?? .standard
    return ExtractionPreferences(
      smartExtraction: defaults.object(forKey: smartKey) as? Bool ?? true,
      revealsResult: defaults.object(forKey: revealKey) as? Bool ?? true,
      trashesArchive: defaults.object(forKey: trashKey) as? Bool ?? false)
  }
}

/// Перемещение файлов в Корзину; внедряется, чтобы тесты не трогали настоящую Корзину.
public protocol ArchiveTrashing: Sendable {
  func trash(_ url: URL) throws
}

/// Штатная Корзина: объект можно вернуть, безвозвратного удаления нет.
public struct SystemArchiveTrasher: ArchiveTrashing {
  public init() {}

  public func trash(_ url: URL) throws {
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
  }
}

/// Итог извлечения одного архива вместе с последующим перемещением в Корзину.
public struct ExtractionOutcome: Sendable, Equatable {
  /// Фактически опубликованный объект (или папка назначения для режима без подпапки).
  public let url: URL
  /// Тома архива, перемещённые в Корзину.
  public let trashedArchives: [URL]
  /// Описание первой ошибки Корзины: извлечение при этом остаётся успешным.
  public let trashFailure: String?
}

extension ArchiveService {
  /// Извлекает архив и только после полного успеха переносит в Корзину все его тома.
  /// Ошибка извлечения или отмена оставляют архив на месте; ошибка Корзины не отменяет результат.
  public func extractAndFinish(
    _ url: URL, password: String = "", directory: URL? = nil, createsSubfolder: Bool = true,
    smartExtraction: Bool = false, trashesArchive: Bool = false,
    trasher: any ArchiveTrashing = SystemArchiveTrasher(),
    progress: ArchiveProgressHandler? = nil
  ) async throws -> ExtractionOutcome {
    let result = try await extractArchive(
      url, password: password, directory: directory, createsSubfolder: createsSubfolder,
      smartExtraction: smartExtraction, progress: progress)
    guard trashesArchive, !Task.isCancelled else {
      return ExtractionOutcome(url: result, trashedArchives: [], trashFailure: nil)
    }
    var trashed: [URL] = []
    var failure: String?
    for volume in ArchiveVolumes.volumes(of: url) {
      do {
        try trasher.trash(volume)
        trashed.append(volume)
      } catch {
        failure = failure ?? error.localizedDescription
      }
    }
    return ExtractionOutcome(url: result, trashedArchives: trashed, trashFailure: failure)
  }
}
