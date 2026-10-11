import Foundation

public enum ArchiveSelection {
  public static func topLevelPaths(_ paths: [String], entries: [ArchiveEntry]) throws -> [String] {
    guard !paths.isEmpty else { throw ArchiveError.invalidOperation }
    let unique = Set(paths)
    let explicit = Set(entries.map(\.path))
    for path in unique {
      try ArchiveListing.validatePath(path)
      guard explicit.contains(path) || entries.contains(where: { $0.path.hasPrefix(path + "/") })
      else {
        throw ArchiveError.invalidOperation
      }
    }
    return unique.filter { path in
      let parts = path.split(separator: "/")
      return !(1..<parts.count).contains {
        unique.contains(parts.prefix($0).joined(separator: "/"))
      }
    }.sorted()
  }

  public static func entries(for path: String, in entries: [ArchiveEntry]) throws -> [ArchiveEntry]
  {
    try ArchiveListing.validatePath(path)
    let selected = entries.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
    guard !selected.isEmpty else { throw ArchiveError.invalidOperation }
    return selected
  }
}
