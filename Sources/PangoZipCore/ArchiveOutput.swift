import Darwin
import Foundation

enum ArchiveOutput {
  /// Получатель File Promise уже согласовал запись; повторная координация создаёт взаимное ожидание.
  static func publishExact(_ source: URL, to destination: URL) throws {
    try Task.checkCancellation()
    if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  // RENAME_EXCL не позволяет перезаписать объект, появившийся после проверки имени.
  /// Подбирает свободное имя атомарным переименованием; источник должен находиться на том же томе.
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
