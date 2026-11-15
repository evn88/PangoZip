import Foundation

/// Итог пакетного создания: готовые архивы и причина, по которой исходники остались на месте.
public struct ArchiveCreationOutcome: Sendable, Equatable {
  public let urls: [URL]
  public let trashFailure: String?
}

/// Архивы созданы, но исходные файлы не удалось переместить в Корзину.
public struct SourceTrashFailure: LocalizedError, Equatable {
  public let message: String

  public init(message: String) { self.message = message }

  public var errorDescription: String? {
    L10n.tr("Не удалось переместить исходные файлы в Корзину: %1$@", String(describing: message))
  }
}

extension ArchiveService {
  /// Создаёт общий архив либо отдельный на каждый объект в папке `proposedURL`.
  /// Исходники уходят в Корзину только после того, как их архив создан и проверен.
  public func createArchives(
    from urls: [URL], proposedURL: URL, format: String, options: CompressionOptions? = nil,
    password: String = "", separately: Bool, trashesSources: Bool,
    progress: ArchiveProgressHandler? = nil,
    trash: @Sendable (URL) throws -> Void = {
      try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }
  ) async throws -> ArchiveCreationOutcome {
    let sources = FinderSelection(urls: urls).urls
    let directory = proposedURL.deletingLastPathComponent()
    let batches: [(sources: [URL], proposed: URL)] =
      separately && sources.count > 1
      ? sources.map {
        (
          [$0],
          directory.appendingPathComponent(
            FinderSelection(urls: [$0]).archiveName + "." + format)
        )
      } : [(sources, proposedURL)]
    var results: [URL] = []
    var trashFailure: String?
    for batch in batches {
      try Task.checkCancellation()
      results.append(
        try await createArchive(
          from: batch.sources, proposedURL: batch.proposed, format: format, options: options,
          password: password, progress: progress))
      guard trashesSources else { continue }
      for source in batch.sources {
        do {
          try trash(source)
        } catch {
          trashFailure = trashFailure ?? error.localizedDescription
        }
      }
    }
    return ArchiveCreationOutcome(urls: results, trashFailure: trashFailure)
  }
}
