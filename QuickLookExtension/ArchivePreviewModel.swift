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
    session = try await service.open(url, password: password)
    message = ""
  }

  func extract(to directory: URL, path: String? = nil) async throws -> [URL] {
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
      return try await service.extract(session, to: directory, path: path, password: password)
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
  }
}
