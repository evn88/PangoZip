import Darwin
import Foundation

enum ArchiveOutput {
  static func publishExact(_ source: URL, to destination: URL) throws {
    try Task.checkCancellation()
    var coordinationError: NSError?
    var writeError: Error?
    NSFileCoordinator().coordinate(
      writingItemAt: destination, options: .forReplacing, error: &coordinationError
    ) { url in
      if renamex_np(source.path, url.path, UInt32(RENAME_EXCL)) != 0 {
        writeError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
    if let coordinationError { throw coordinationError }
    if let writeError { throw writeError }
  }

  // RENAME_EXCL не позволяет перезаписать объект, появившийся после проверки имени.
  static func publish(_ source: URL, proposed: URL, isDirectory: Bool) throws -> URL {
    let parent = proposed.deletingLastPathComponent()
    let ext = isDirectory ? "" : proposed.pathExtension
    let stem =
      isDirectory || ext.isEmpty
      ? proposed.lastPathComponent : proposed.deletingPathExtension().lastPathComponent
    for number in 1...10_000 {
      try Task.checkCancellation()
      let name = stem + (number == 1 ? "" : " (\(number))") + (ext.isEmpty ? "" : "." + ext)
      let target = parent.appendingPathComponent(name)
      if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
      guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    throw ArchiveError.duplicatePath
  }
}
