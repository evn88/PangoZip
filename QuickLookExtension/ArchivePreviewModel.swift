import Foundation
import Observation

#if SWIFT_PACKAGE
  import PangoZipCore
#endif

@MainActor
@Observable
final class ArchivePreviewModel {
  private let service: QuickLookArchiveService
  private var extraction: Task<[URL], Error>?
  private(set) var url: URL?
  private(set) var session: ArchiveSession?
  private(set) var isBusy = false
  private(set) var totalSize: UInt64 = 0
  private(set) var folderSizes: [String: UInt64] = [:]
  private(set) var hasEncryptedEntries = false
  var password = ""
  var message = ""

  init(service: QuickLookArchiveService = QuickLookArchiveService()) {
    self.service = service
  }

  func prepare(_ url: URL) async throws {
    guard !isBusy else { throw ArchiveError.operationInProgress }
    isBusy = true
    defer { isBusy = false }
    await close()
    if let previous = self.url, previous != url { password = "" }
    self.url = url
    let session = try await service.open(url, password: password)
    summarize(session.entries)
    self.session = session
    message = ""
  }

  /// Оставляет только верхние объекты выбора: вложенные извлекаются вместе с родительской папкой.
  nonisolated static func topLevelPaths(_ paths: [String]) -> [String] {
    let selected = Set(paths)
    return selected.filter { path in
      var parent = Substring(path)
      while let slash = parent.lastIndex(of: "/") {
        parent = parent[..<slash]
        if selected.contains(String(parent)) { return false }
      }
      return true
    }.sorted()
  }

  func extract(to directory: URL, path: String? = nil) async throws -> [URL] {
    try await run(directory, paths: [path])
  }

  func extract(to directory: URL, paths: [String]) async throws -> [URL] {
    try await run(directory, paths: Self.topLevelPaths(paths))
  }

  private func run(_ directory: URL, paths: [String?]) async throws -> [URL] {
    guard !isBusy else { throw ArchiveError.operationInProgress }
    guard let session else { throw ArchiveError.sessionExpired }
    isBusy = true
    let service = self.service
    let password = self.password
    let task = Task {
      defer {
        self.isBusy = false
        self.extraction = nil
      }
      var results: [URL] = []
      for path in paths {
        try Task.checkCancellation()
        results += try await service.extract(
          session, to: directory, path: path, password: password)
      }
      return results
    }
    extraction = task
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  func close() async {
    extraction?.cancel()
    _ = try? await extraction?.value
    if let session { try? await service.close(session) }
    session = nil
    summarize([])
  }

  /// Размеры папок считаются один раз при открытии, а не при каждой отрисовке таблицы.
  private func summarize(_ entries: [ArchiveEntry]) {
    var total: UInt64 = 0
    var folders: [String: UInt64] = [:]
    var encrypted = false
    for entry in entries where !entry.isDirectory {
      total &+= entry.size
      encrypted = encrypted || entry.isEncrypted
      var parent = Substring(entry.path)
      while let slash = parent.lastIndex(of: "/") {
        parent = parent[..<slash]
        folders[String(parent), default: 0] &+= entry.size
      }
    }
    totalSize = total
    folderSizes = folders
    hasEncryptedEntries = encrypted
  }
}
