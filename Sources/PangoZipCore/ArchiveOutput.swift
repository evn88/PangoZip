import Darwin
import Foundation

enum ArchiveOutput {
  /// Получатель File Promise уже согласовал запись; повторная координация создаёт взаимное ожидание.
  static func publishExact(_ source: URL, to destination: URL) throws {
    try Task.checkCancellation()
    let mode = unlockDirectory(source)
    if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
      let code = errno
      if let mode { chmod(source.path, mode) }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    if let mode { chmod(destination.path, mode) }
  }

  /// macOS не переносит папку без права записи владельца в другого родителя; права возвращаются после.
  private static func unlockDirectory(_ source: URL) -> mode_t? {
    var info = stat()
    guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_mode & S_IWUSR == 0
    else { return nil }
    let mode = info.st_mode & 0o7777
    return chmod(source.path, mode | S_IWUSR) == 0 ? mode : nil
  }

  // RENAME_EXCL не позволяет перезаписать объект, появившийся после проверки имени.
  /// Подбирает свободное имя атомарным переименованием; источник должен находиться на том же томе.
  static func publish(_ source: URL, proposed: URL, isDirectory: Bool) throws -> URL {
    let parent = proposed.deletingLastPathComponent()
    let ext = isDirectory ? "" : proposed.pathExtension
    let stem =
      isDirectory || ext.isEmpty
      ? proposed.lastPathComponent : proposed.deletingPathExtension().lastPathComponent
    let mode = unlockDirectory(source)
    defer { if let mode { chmod(source.path, mode) } }
    for number in 1...10_000 {
      try Task.checkCancellation()
      let name = stem + (number == 1 ? "" : " (\(number))") + (ext.isEmpty ? "" : "." + ext)
      let target = parent.appendingPathComponent(name)
      if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 {
        if let mode { chmod(target.path, mode) }
        return target
      }
      guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    throw ArchiveError.duplicatePath
  }
}
