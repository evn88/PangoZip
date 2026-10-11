import AppKit
import PangoZipCore
import UniformTypeIdentifiers

final class PromiseCompletion: @unchecked Sendable {
  private let handler: (Error?) -> Void
  init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
  func finish(_ error: Error?) { handler(error) }
}

@MainActor
final class ArchiveFilePromise: NSObject, NSFilePromiseProviderDelegate {
  let path: String
  let session: ArchiveSession
  let dragID: UUID
  let model: ArchiveBrowserModel
  private let queue = OperationQueue()

  init(path: String, session: ArchiveSession, dragID: UUID, model: ArchiveBrowserModel) {
    self.path = path
    self.session = session
    self.dragID = dragID
    self.model = model
    super.init()
    queue.name = "app.pangozip.file-promises"
  }

  func provider(isDirectory: Bool) -> NSFilePromiseProvider {
    let type =
      isDirectory
      ? UTType.folder : UTType(filenameExtension: (path as NSString).pathExtension) ?? .data
    let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
    // AppKit держит delegate слабо, а userInfo сохраняет снимок до выполнения promise.
    provider.userInfo = self
    return provider
  }

  func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String
  ) -> String {
    String(path.split(separator: "/").last!)
  }

  nonisolated func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let completion = PromiseCompletion(completionHandler)
    Task { @MainActor in
      model.fulfillPromise(
        path: path, session: session, to: url, dragID: dragID, completion: completion)
    }
  }

  func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}
