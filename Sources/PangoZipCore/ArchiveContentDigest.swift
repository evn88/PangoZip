import CryptoKit
import Foundation

/// SHA256 нужен только для новых версий и Undo: системное касание ctime не означает изменение данных.
enum ArchiveContentDigest {
  /// Читает вне actor; отмена передаётся потоковому чтению и дожидается закрытия файла.
  static func hash(_ url: URL) async throws -> Data {
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let before = try FileFingerprint(url)
      guard before.type == .typeRegular else { throw ArchiveError.invalidArchive }
      let input = try FileHandle(forReadingFrom: url)
      defer { try? input.close() }
      var hash = SHA256()
      while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty {
        try Task.checkCancellation()
        hash.update(data: data)
      }
      guard try before == FileFingerprint(url) else { throw ArchiveError.archiveChanged }
      return Data(hash.finalize())
    }
    return try await withTaskCancellationHandler {
      let digest = try await task.value
      try Task.checkCancellation()
      return digest
    } onCancel: {
      task.cancel()
    }
  }

  /// Только ctime разрешено перепроверить по данным; замена inode, размера или mtime остаётся конфликтом.
  static func validate(_ url: URL, fingerprint: FileFingerprint, digest: Data?) async throws
    -> FileFingerprint
  {
    let observed = try FileFingerprint(url)
    if observed == fingerprint { return observed }
    guard let digest, observed.inode == fingerprint.inode, observed.size == fingerprint.size,
      observed.modified == fingerprint.modified, observed.type == fingerprint.type
    else { throw ArchiveError.archiveChanged }
    guard try await hash(url) == digest, try observed == FileFingerprint(url) else {
      throw ArchiveError.archiveChanged
    }
    return observed
  }
}
