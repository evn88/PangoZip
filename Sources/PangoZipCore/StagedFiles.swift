import Darwin
import Foundation

struct FileFingerprint: Equatable, Sendable {
  let size: UInt64
  let modified: Date
  let inode: UInt64
  let type: FileAttributeType
  let changedSeconds: Int
  let changedNanoseconds: Int

  init(_ url: URL) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0 else { throw CocoaError(.fileReadUnknown) }
    changedSeconds = status.st_ctimespec.tv_sec
    changedNanoseconds = status.st_ctimespec.tv_nsec
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    modified = attributes[.modificationDate] as? Date ?? .distantPast
    inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    type = attributes[.type] as? FileAttributeType ?? .typeUnknown
  }
}

enum StagedFiles {
  static func copy(_ source: URL, to destination: URL) async throws {
    let task = Task.detached(priority: .userInitiated) { try copyBlocking(source, to: destination) }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func copyBlocking(_ source: URL, to destination: URL) throws {
    try Task.checkCancellation()
    let manager = FileManager.default
    let attributes = try manager.attributesOfItem(atPath: source.path)
    let type = attributes[.type] as? FileAttributeType
    guard [.typeRegular, .typeDirectory, .typeSymbolicLink].contains(type) else {
      throw ArchiveError.unsupportedEntry
    }
    guard (try? manager.attributesOfItem(atPath: destination.path)) == nil else {
      throw ArchiveError.duplicatePath
    }
    try manager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if type == .typeSymbolicLink {
      try manager.createSymbolicLink(
        atPath: destination.path,
        withDestinationPath: manager.destinationOfSymbolicLink(atPath: source.path))
    } else if type == .typeDirectory {
      try manager.createDirectory(
        at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      for child in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
        try ArchiveListing.validatePath(child.lastPathComponent)
        try copyBlocking(child, to: destination.appendingPathComponent(child.lastPathComponent))
      }
    } else {
      let before = try FileFingerprint(source)
      _ = manager.createFile(
        atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
      let input = try FileHandle(forReadingFrom: source)
      let output = try FileHandle(forWritingTo: destination)
      defer {
        try? input.close()
        try? output.close()
      }
      while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty {
        try Task.checkCancellation()
        try output.write(contentsOf: data)
      }
      guard try before == FileFingerprint(source) else { throw ArchiveError.editedFileChanged }
      try Quarantine.copy(from: source, to: destination)
    }
    var preserved: [FileAttributeKey: Any] = [:]
    for key in [FileAttributeKey.posixPermissions, .modificationDate, .creationDate] {
      if let value = attributes[key] { preserved[key] = value }
    }
    if type != .typeSymbolicLink {
      try manager.setAttributes(preserved, ofItemAtPath: destination.path)
    }
  }
}
