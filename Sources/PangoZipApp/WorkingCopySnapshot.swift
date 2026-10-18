import Foundation

struct WorkingCopySnapshot: Equatable, Sendable {
  let size: UInt64
  let modified: Date
  let created: Date
  let inode: UInt64

  init(_ url: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    modified = attributes[.modificationDate] as? Date ?? .distantPast
    created = attributes[.creationDate] as? Date ?? .distantPast
    inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
  }
}
