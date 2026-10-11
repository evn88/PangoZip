import Darwin
import Foundation

enum Quarantine {
  static func copy(from source: URL, to destination: URL) throws {
    let name = "com.apple.quarantine"
    let count = getxattr(source.path, name, nil, 0, 0, XATTR_NOFOLLOW)
    if count < 0 {
      guard errno == ENOATTR || errno == ENOTSUP else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      return
    }
    guard count <= 65_536 else { throw ArchiveError.outputLimit }
    var data = [UInt8](repeating: 0, count: count)
    let readCount = data.withUnsafeMutableBytes {
      getxattr(source.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
    }
    guard readCount == count else { throw ArchiveError.archiveChanged }
    let result = data.withUnsafeBytes {
      setxattr(destination.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }
}
