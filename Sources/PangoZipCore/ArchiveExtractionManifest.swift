import Darwin
import Foundation

/// Сопоставляет вывод движка с заранее проверенными записями и их синтетическими папками.
struct ArchiveExtractionManifest: Sendable {
  let paths: [String: ArchiveEntry]

  /// Отклоняет ссылки, неоднозначные имена и превышение общего лимита до запуска движка.
  init(entries: [ArchiveEntry], maximumBytes: UInt64) throws {
    var paths: [String: ArchiveEntry] = [:]
    var normalized: [String: String] = [:]
    var total: UInt64 = 0
    for entry in entries {
      try ArchiveListing.validatePath(entry.path)
      guard !entry.isSymbolicLink else { throw ArchiveError.unsupportedExtraction }
      let sum = total.addingReportingOverflow(entry.isDirectory ? 0 : entry.size)
      guard !sum.overflow, sum.partialValue <= maximumBytes else { throw ArchiveError.outputLimit }
      total = sum.partialValue
      let parts = entry.path.split(separator: "/")
      for index in 1...parts.count {
        let path = parts.prefix(index).joined(separator: "/")
        let key = path.precomposedStringWithCanonicalMapping.lowercased()
        if let previous = normalized[key], previous != path { throw ArchiveError.duplicatePath }
        normalized[key] = path
        let record = index == parts.count ? entry : ArchiveEntry(path: path, isDirectory: true)
        if let existing = paths[path], existing.isDirectory != record.isDirectory {
          throw ArchiveError.duplicatePath
        }
        if paths[path] == nil || index == parts.count { paths[path] = record }
      }
    }
    self.paths = paths
  }

  /// lstat и ручной обход не следуют ссылкам; незаявленные файлы нельзя опубликовать.
  func validate(_ directory: URL, complete: Bool) throws {
    var seen: Set<String> = []
    func visit(_ parent: URL, prefix: String) throws {
      try Task.checkCancellation()
      for child in try FileManager.default.contentsOfDirectory(
        at: parent, includingPropertiesForKeys: nil)
      {
        let path = prefix.isEmpty ? child.lastPathComponent : prefix + "/" + child.lastPathComponent
        guard let entry = paths[path] else { throw ArchiveError.extractionMismatch }
        var status = stat()
        guard lstat(child.path, &status) == 0 else { throw CocoaError(.fileReadUnknown) }
        let type = status.st_mode & S_IFMT
        guard type == (entry.isDirectory ? S_IFDIR : S_IFREG),
          entry.isDirectory || status.st_nlink == 1
        else { throw ArchiveError.unsupportedExtraction }
        // Права архива применяются после quarantine; до этого staging должен оставаться доступным.
        let permissions: mode_t = entry.isDirectory ? 0o700 : 0o600
        if status.st_mode & 0o7777 != permissions,
          fchmodat(AT_FDCWD, child.path, permissions, AT_SYMLINK_NOFOLLOW) != 0
        {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if !entry.isDirectory {
          guard status.st_size >= 0, UInt64(status.st_size) <= entry.size else {
            throw ArchiveError.outputLimit
          }
          if complete, UInt64(status.st_size) != entry.size {
            throw ArchiveError.extractionMismatch
          }
        }
        seen.insert(path)
        if entry.isDirectory { try visit(child, prefix: path) }
      }
    }
    try visit(directory, prefix: "")
    if complete, seen != Set(paths.keys) { throw ArchiveError.extractionMismatch }
  }
}
