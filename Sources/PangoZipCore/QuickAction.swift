import Foundation

/// Действия расширений Quick Action (панель просмотра и подменю «Быстрые действия» Finder).
/// Одно расширение macOS даёт ровно один пункт, поэтому каждому действию соответствует свой appex.
public enum QuickAction: String, Sendable, CaseIterable {
  case extractHere, createZip

  public static let identifierPrefix = "app.pangozip.desktop.quickaction."
  public static let executableName = "PangoZipQuickAction"
  public static let extensionPoint = "com.apple.services"
  /// Ключ Info.plist расширения, по которому единый исполняемый файл узнаёт своё действие.
  public static let infoKey = "PangoZipQuickAction"

  public var bundleIdentifier: String {
    Self.identifierPrefix + (self == .extractHere ? "extract" : "zip")
  }

  /// Путь appex внутри основного приложения.
  public var bundlePath: String {
    "Contents/PlugIns/" + (self == .extractHere ? "PangoZipQuickExtract" : "PangoZipQuickZip")
      + ".appex"
  }

  public var finderAction: FinderAction { self == .extractHere ? .extractHere : .createZip }

  /// Строит запрос тем же `FinderSelection`, что и меню Finder Sync: распаковка берёт только архивы.
  /// Без подходящих объектов бросает `invalidSelection`, и расширение завершает запрос без действий.
  public func request(for urls: [URL]) throws -> FinderRequest {
    try FinderSelection(urls: urls).request(for: finderAction)
  }

  /// Извлекает локальный URL из элемента NSItemProvider: URL, NSURL или данные представления URL.
  public static func fileURL(from item: Any?) -> URL? {
    let url: URL?
    switch item {
    case let value as URL: url = value
    case let value as NSURL: url = value as URL
    case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
    default: url = nil
    }
    guard let url, url.isFileURL else { return nil }
    return url
  }
}
