import Foundation
import UniformTypeIdentifiers

public enum FinderAction: String, Codable, Sendable, CaseIterable {
  case open, extractFiles, extractHere, extract, test, create, createZip, create7z, add

  public var title: String {
    switch self {
    case .open: L10n.tr("Открыть архивы")
    case .extractFiles: L10n.tr("Распаковать…")
    case .extractHere: L10n.tr("Распаковать здесь")
    case .extract: L10n.tr("Распаковать в отдельные папки")
    case .test: L10n.tr("Тестировать архив")
    case .create: L10n.tr("Добавить в архив…")
    case .createZip: L10n.tr("Заархивировать в ZIP")
    case .create7z: L10n.tr("Заархивировать в 7z")
    case .add: L10n.tr("Добавить в архив…")
    }
  }
}

public struct FinderRequest: Codable, Sendable, Equatable {
  public let action: FinderAction
  public let urls: [URL]
  public static let pasteboardType = "app.pangozip.finder-request"
  public static let boardPrefix = "app.pangozip.finder."
  public static let maximumBytes = 8 * 1024 * 1024

  /// Принимает ограниченный список локальных URL и убирает повторы после нормализации.
  public init(action: FinderAction, urls: [URL]) throws {
    guard !urls.isEmpty, urls.count <= 10_000,
      urls.allSatisfy({
        $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost")
      })
    else { throw FinderRequestError.invalidSelection }
    self.action = action
    var seen: Set<URL> = []
    self.urls = urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
  }

  /// Ограничивает размер JSON и повторно проверяет URL, поскольку Codable обходит проверяющий init.
  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw FinderRequestError.invalidSelection }
    let decoded = try JSONDecoder().decode(Self.self, from: data)
    return try Self(action: decoded.action, urls: decoded.urls)
  }

  /// Принимает только адрес команды Finder с единственным UUID и возвращает имя pasteboard.
  public static func boardName(from url: URL) -> String? {
    guard ["pangozip", "pangozip-worker"].contains(url.scheme ?? ""), url.host == "finder",
      url.path.isEmpty,
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let items = parts.queryItems, items.count == 1, items[0].name == "request",
      let token = items[0].value, UUID(uuidString: token) != nil
    else { return nil }
    return boardPrefix + token
  }
}

public enum FinderRequestError: LocalizedError {
  case invalidSelection
  public var errorDescription: String? {
    L10n.tr("Не удалось получить выделенные файлы из Finder.")
  }
}

public struct FinderSelection: Sendable {
  public let urls: [URL]
  public let archives: [URL]

  /// Нормализует файловое выделение и отдельно определяет архивы для доступных действий.
  public init(urls: [URL]) {
    var seen: Set<URL> = []
    self.urls = urls.filter(\.isFileURL).map(\.standardizedFileURL).filter {
      seen.insert($0).inserted
    }
    archives = self.urls.filter(Self.isArchive)
  }

  public var actions: [FinderAction] {
    guard !urls.isEmpty else { return [] }
    return (archives.isEmpty ? [] : [.open, .extractFiles, .extractHere, .extract, .test]) + [
      .create, .create7z, .createZip,
    ]
  }

  /// Уточняет подпись команды по текущему выделению и предлагаемому имени результата.
  public func title(for action: FinderAction) -> String {
    switch action {
    case .open: return archives.count == 1 ? L10n.tr("Открыть архив") : L10n.tr("Открыть архивы")
    case .extract:
      return archives.count == 1
        ? L10n.tr(
          "Распаковать в «%1$@/»", String(describing: Self.extractionName(for: archives[0])))
        : L10n.tr("Распаковать в отдельные папки")
    case .create7z: return L10n.tr("Добавить в «%1$@.7z»", String(describing: archiveName))
    case .createZip: return L10n.tr("Добавить в «%1$@.zip»", String(describing: archiveName))
    default: return action.title
    }
  }

  /// Для операций чтения передаёт только архивы, для создания передаёт всё выделение.
  public func request(for action: FinderAction) throws -> FinderRequest {
    try FinderRequest(
      action: action,
      urls: [.open, .extractFiles, .extractHere, .extract, .test].contains(action) ? archives : urls
    )
  }

  /// Отклоняет папки и ссылки; расширение или UTType служат предварительным признаком архива.
  public static func isArchive(_ url: URL) -> Bool {
    guard url.isFileURL,
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
      values.isDirectory != true, values.isSymbolicLink != true
    else { return false }
    let ext = url.pathExtension.lowercased()
    if [
      "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "tgz", "tbz", "tbz2", "txz", "zst",
      "tzst", "lzma", "lz", "cab", "iso", "wim", "arj", "cpio", "deb", "rpm", "cbz", "cbr",
    ].contains(ext) {
      return true
    }
    return UTType(filenameExtension: ext)?.conforms(to: .archive) == true
  }

  /// Убирает составное расширение сжатого TAR и выбирает имя будущей папки.
  public static func extractionName(for url: URL) -> String {
    let name = url.lastPathComponent
    for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lzma"] {
      if name.lowercased().hasSuffix(suffix) {
        let stem = String(name.dropLast(suffix.count))
        return stem.isEmpty || stem == "." || stem == ".." ? "Archive" : stem
      }
    }
    let stem = url.deletingPathExtension().lastPathComponent
    return stem.isEmpty || stem == "." || stem == ".." ? "Archive" : stem
  }

  public var archiveName: String {
    let base: String
    if urls.count == 1 {
      let url = urls[0]
      let name = url.lastPathComponent
      let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      if !isDirectory, let dot = name.firstIndex(of: "."), dot != name.startIndex,
        name[name.index(after: dot)...].firstIndex(of: ".") == nil
      {
        base = String(name[..<dot])
      } else {
        base = name
      }
    } else {
      let parent = urls.first?.deletingLastPathComponent().lastPathComponent ?? "Archive"
      base = parent.isEmpty ? "Archive" : parent
    }
    let selectedNames = Set(urls.map { $0.lastPathComponent.lowercased() })
    let extensions = ["zip", "7z", "tar", "wim"]
    /// Проверяет, совпадёт ли имя результата с одним из выбранных архивов без учёта регистра.
    func conflicts(_ name: String) -> Bool {
      extensions.contains { selectedNames.contains((name + "." + $0).lowercased()) }
    }
    guard conflicts(base) else { return base }
    var number = 2
    while conflicts(base + "_" + String(number)) { number += 1 }
    return base + "_" + String(number)
  }
}
