import CryptoKit
import Darwin
import Foundation

/// Выбранный объект и его имя в корне будущего архива.
struct ArchiveSource: Sendable, Equatable {
  let url: URL
  let name: String
}

/// Обход исходных файлов перед сжатием: объём для прогресса, исключения и отпечаток состояния.
/// Движок читает файлы прямо с их места, без промежуточной копии, поэтому обход только смотрит
/// метаданные и занимает секунды даже на десятках гигабайт.
struct ArchiveSourceScan: Sendable, Equatable {
  /// Логический объём файлов и ссылок, которые попадут в архив.
  let bytes: UInt64
  let files: Int
  /// Пути служебных файлов относительно корня архива; передаются движку как точные исключения.
  let excluded: [String]
  /// Отпечаток имён, размеров и времени изменения: по нему видно, что файлы меняли во время сжатия.
  let signature: Data

  /// Обходит вне исполнителя actor; `progress` получает число уже найденных объектов.
  static func scan(
    _ sources: [ArchiveSource], skippingSystemFiles: Bool,
    progress: (@Sendable (Int) async -> Void)? = nil
  ) async throws -> Self {
    let (counts, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let report: (@Sendable (Int) -> Void)? =
      progress == nil ? nil : { @Sendable value in _ = continuation.yield(value) }
    let task = Task.detached(priority: .userInitiated) {
      defer { continuation.finish() }
      var walker = Walker(skipsSystemFiles: skippingSystemFiles, report: report)
      for source in sources {
        try walker.visit(
          path: source.url.standardizedFileURL.path, name: source.name, isVolatile: false)
      }
      return Self(
        bytes: walker.bytes, files: walker.files, excluded: walker.excluded,
        signature: Data(walker.hash.finalize()))
    }
    return try await withTaskCancellationHandler {
      for await count in counts { await progress?(count) }
      return try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private struct Walker {
    let skipsSystemFiles: Bool
    let report: (@Sendable (Int) -> Void)?
    var bytes: UInt64 = 0
    var files = 0
    var excluded: [String] = []
    var hash = SHA256()
    private var visited = 0
    private var lastReport = ProcessInfo.processInfo.systemUptime

    init(skipsSystemFiles: Bool, report: (@Sendable (Int) -> Void)?) {
      self.skipsSystemFiles = skipsSystemFiles
      self.report = report
    }

    /// Не следует ссылкам. Служебные файлы (`isVolatile`) система переписывает сама, например
    /// .DS_Store при открытии папки в Finder, поэтому в отпечаток они не входят.
    mutating func visit(path: String, name: String, isVolatile: Bool) throws {
      visited += 1
      if visited & 0x3F == 0 {
        try Task.checkCancellation()
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReport >= 0.1 {
          lastReport = now
          report?(visited)
        }
      }
      var info = stat()
      guard lstat(path, &info) == 0 else {
        throw CocoaError(
          errno == ENOENT ? .fileReadNoSuchFile : .fileReadUnknown,
          userInfo: [NSFilePathErrorKey: path])
      }
      let type = info.st_mode & S_IFMT
      let size = UInt64(max(0, info.st_size))
      switch type {
      case S_IFDIR:
        if !isVolatile { mix(name, kind: 1, values: []) }
        for child in try Self.entries(of: path).sorted() {
          let childName = name + "/" + child
          let isSystem = SystemFiles.isSystemName(child)
          if isSystem, skipsSystemFiles {
            excluded.append(childName)
            continue
          }
          try ArchiveListing.validatePath(child)
          try visit(
            path: path + "/" + child, name: childName, isVolatile: isVolatile || isSystem)
        }
      case S_IFREG:
        // Недоступный файл движок пропустил бы с предупреждением уже после долгого сжатия.
        guard access(path, R_OK) == 0 else {
          throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        try count(size)
        if !isVolatile {
          mix(
            name, kind: 2,
            values: [
              size, UInt64(bitPattern: Int64(info.st_mtimespec.tv_sec)),
              UInt64(bitPattern: Int64(info.st_mtimespec.tv_nsec)),
            ])
        }
      case S_IFLNK:
        try count(size)
        if !isVolatile {
          // Длина пути не меняется при замене цели на другую той же длины, поэтому в отпечаток
          // входит сама цель ссылки.
          let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
          mix(name, kind: 3, values: [size])
          mix(target, kind: 4, values: [])
        }
      default:
        throw ArchiveError.unsupportedEntry
      }
    }

    /// Читает каталог через readdir: FileManager в macOS скрывает AppleDouble «._Имя», а движок
    /// видит их и без точного исключения положил бы в архив.
    private static func entries(of path: String) throws -> [String] {
      guard let directory = opendir(path) else {
        throw CocoaError(
          errno == ENOENT ? .fileReadNoSuchFile : .fileReadUnknown,
          userInfo: [NSFilePathErrorKey: path])
      }
      defer { closedir(directory) }
      var names: [String] = []
      while let entry = readdir(directory) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
          String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
        }
        if name != ".", name != ".." { names.append(name) }
      }
      return names
    }

    private mutating func count(_ size: UInt64) throws {
      let sum = bytes.addingReportingOverflow(size)
      guard !sum.overflow else { throw ArchiveError.outputLimit }
      bytes = sum.partialValue
      files += 1
    }

    /// Имя завершается нулевым байтом, поэтому границы полей однозначны.
    private mutating func mix(_ name: String, kind: UInt8, values: [UInt64]) {
      hash.update(data: Data(name.utf8))
      hash.update(data: Data([0, kind]))
      for value in values {
        withUnsafeBytes(of: value.littleEndian) { hash.update(bufferPointer: $0) }
      }
    }
  }
}
