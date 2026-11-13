import Foundation

/// Решение острова перетаскивания: что сделать с брошенными объектами и куда положить результат.
public struct DropIslandPlan: Sendable, Equatable {
  public enum Action: Sendable, Equatable {
    case compress, extract
  }

  public enum Destination: Sendable, Equatable {
    /// Папка известна заранее, запрос не нужен.
    case directory(URL)
    /// Место выбирает пользователь в диалоге сохранения.
    case ask
  }

  public let action: Action
  public let urls: [URL]
  /// Для распаковки не используется: содержимое всегда ложится рядом с архивом.
  public let destination: Destination
  /// Набор состоит только из архивов; Option в этом случае переключает распаковку на сжатие.
  public let containsOnlyArchives: Bool
  private let archiveName: String

  /// Возвращает nil для пустого набора. Option у архивов означает «сжать», у остальных — «выбрать место».
  public init?(urls: [URL], optionPressed: Bool, defaultFolder: URL?) {
    let selection = FinderSelection(urls: urls)
    guard !selection.urls.isEmpty else { return nil }
    self.urls = selection.urls
    archiveName = selection.archiveName
    containsOnlyArchives = selection.archives.count == selection.urls.count
    if containsOnlyArchives && !optionPressed {
      action = .extract
      destination = .directory(selection.urls[0].deletingLastPathComponent())
      return
    }
    action = .compress
    let parents = Set(selection.urls.map { $0.deletingLastPathComponent() })
    if optionPressed && !containsOnlyArchives {
      destination = .ask
    } else if let defaultFolder {
      destination = .directory(defaultFolder)
    } else if parents.count == 1, let parent = parents.first {
      destination = .directory(parent)
    } else {
      destination = .ask
    }
  }

  /// Имя будущего архива или папки; для нескольких архивов общего имени нет.
  public func resultName(format: String) -> String? {
    switch action {
    case .compress: archiveName + "." + format
    case .extract: urls.count == 1 ? FinderSelection.extractionName(for: urls[0]) : nil
    }
  }
}
