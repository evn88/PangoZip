import Foundation

/// Распознаёт тома многотомных архивов по именам файлов.
public enum ArchiveVolumes {
  public enum Role: Sendable, Equatable {
    /// Обычный архив или головной файл набора (например, `.rar` рядом с `.r00`).
    case standalone
    /// Первый том нумерованного набора: `.7z.001`, `.part1.rar`.
    case first
    /// Продолжение набора; самостоятельно открываться не должно.
    case later
  }

  /// Определяет роль файла только по имени.
  public static func role(ofName name: String) -> Role {
    let lower = name.lowercased()
    if let match = lower.firstMatch(of: /^(.+)\.part0*([0-9]+)\.rar$/) {
      return Int(match.2) == 1 ? .first : .later
    }
    if lower.firstMatch(of: /^.+\.[rz][0-9]{2}$/) != nil { return .later }
    if let match = lower.firstMatch(of: /^(.+)\.([0-9]{3,})$/),
      FinderSelection.archiveExtensions.contains((String(match.1) as NSString).pathExtension)
    {
      return Int(match.2) == 1 ? .first : .later
    }
    return .standalone
  }

  /// Можно ли открывать файл как архив: имя архива или первый нумерованный том вида `.7z.001`.
  public static func isArchiveName(_ name: String) -> Bool {
    FinderSelection.isArchiveName(name) || role(ofName: name) == .first
  }

  /// Все существующие тома набора, включая сам файл; для обычного архива — только он.
  public static func volumes(of url: URL) -> [URL] {
    let directory = url.deletingLastPathComponent()
    let name = url.lastPathComponent
    let lower = name.lowercased()
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return [url] }
    var matched: [String] = []
    if let match = lower.firstMatch(of: /^(.+)\.part0*[0-9]+\.rar$/) {
      let prefix = String(match.1)
      matched = names.filter {
        $0.lowercased().firstMatch(of: /^(.+)\.part0*[0-9]+\.rar$/).map { String($0.1) } == prefix
      }
    } else if let match = lower.firstMatch(of: /^(.+)\.([0-9]{3,})$/),
      role(ofName: name) != .standalone
    {
      let prefix = String(match.1)
      matched = names.filter {
        $0.lowercased().firstMatch(of: /^(.+)\.[0-9]{3,}$/).map { String($0.1) } == prefix
      }
    } else if lower.hasSuffix(".rar") || lower.hasSuffix(".zip") {
      // Старая схема: `name.rar` + `name.r00`, `name.zip` + `name.z01`.
      let stem = String((name as NSString).deletingPathExtension).lowercased()
      let letter = lower.hasSuffix(".rar") ? "r" : "z"
      matched = names.filter {
        let candidate = $0.lowercased()
        return candidate.count == stem.count + 4 && candidate.hasPrefix(stem + "." + letter)
          && candidate.dropFirst(stem.count + 2).allSatisfy(\.isNumber)
      }
    }
    var result = [url]
    for other in matched.sorted() where other != name {
      result.append(directory.appendingPathComponent(other))
    }
    return result
  }
}
