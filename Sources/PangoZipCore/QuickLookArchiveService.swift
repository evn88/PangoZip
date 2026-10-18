import CLibArchive
import Darwin
import Foundation

/// Quick Look читает системную библиотеку внутри процесса: его sandbox запрещает запуск 7zz.
public actor QuickLookArchiveService {
  private struct State: Sendable {
    let session: ArchiveSession
    let fingerprint: FileFingerprint
  }

  private var sessions: [UUID: State] = [:]
  private var busy: Set<UUID> = []
  private let workspace = TemporaryWorkspace()

  public init() {}

  public func open(_ url: URL, password: String = "") async throws -> ArchiveSession {
    guard url.isFileURL else { throw ArchiveError.invalidArchive }
    let fingerprint = try FileFingerprint(url)
    guard fingerprint.type == .typeRegular else { throw ArchiveError.invalidArchive }
    let task = Task.detached(priority: .userInitiated) {
      try QuickLookReader(url: url, password: password).scan()
    }
    let listing = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    try Task.checkCancellation()
    guard try fingerprint == FileFingerprint(url) else { throw ArchiveError.archiveChanged }
    let session = ArchiveSession(
      id: UUID(), url: url, entries: listing.entries,
      roots: try ArchiveListing.tree(from: listing.entries), format: listing.format,
      canModify: false)
    sessions[session.id] = State(session: session, fingerprint: fingerprint)
    return session
  }

  public func close(_ session: ArchiveSession) throws {
    guard !busy.contains(session.id) else { throw ArchiveError.operationInProgress }
    sessions.removeValue(forKey: session.id)
    if sessions.isEmpty { workspace.cleanup() }
  }

  public func extract(
    _ session: ArchiveSession, to directory: URL, path: String? = nil, password: String = ""
  ) async throws -> [URL] {
    guard let state = sessions[session.id], state.session.url == session.url else {
      throw ArchiveError.sessionExpired
    }
    guard !busy.contains(session.id), directory.isFileURL else {
      throw ArchiveError.invalidOperation
    }
    guard try state.fingerprint == FileFingerprint(session.url) else {
      throw ArchiveError.archiveChanged
    }
    if let path { _ = try ArchiveSelection.entries(for: path, in: state.session.entries) }
    let name =
      path.map { String($0.split(separator: "/").last!) }
      ?? FinderSelection.extractionName(for: session.url)
    let destination = directory.appendingPathComponent(name)
    let isDirectory =
      path == nil
      || state.session.entries.first(where: { $0.path == path })?.isDirectory != false
    busy.insert(session.id)
    defer { busy.remove(session.id) }
    let transaction = try workspace.transactionDirectory(nextTo: destination)
    defer { try? workspace.removeTransaction(transaction) }
    let output = transaction.appendingPathComponent("contents")
    let task = Task.detached(priority: .userInitiated) {
      let listing = try QuickLookReader(url: session.url, password: password).scan(
        output: output, selectedPath: path, isDirectory: isDirectory)
      guard listing.entries == state.session.entries else { throw ArchiveError.archiveChanged }
    }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    try Task.checkCancellation()
    guard try state.fingerprint == FileFingerprint(session.url) else {
      throw ArchiveError.archiveChanged
    }
    let result = try ArchiveOutput.publish(output, proposed: destination, isDirectory: isDirectory)
    return [result]
  }
}

private struct QuickLookListing: Sendable {
  let entries: [ArchiveEntry]
  let format: String
}

private final class QuickLookInput {
  let descriptor: Int32
  let buffer = UnsafeMutableRawPointer.allocate(byteCount: 65_536, alignment: 16)
  let deadline = Date().addingTimeInterval(120)
  var error: Error?

  init(_ url: URL) throws {
    descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  deinit {
    Darwin.close(descriptor)
    buffer.deallocate()
  }

  func check() throws {
    try Task.checkCancellation()
    guard Date() < deadline else { throw ArchiveError.timedOut }
  }

  // Проверки внутри C-callback ограничивают также декомпрессию пропускаемых записей.
  func perform(_ operation: () throws -> Int64) -> Int64 {
    do {
      try check()
      return try operation()
    } catch {
      self.error = error
      return -1
    }
  }
}

private final class QuickLookReader {
  private let archive: OpaquePointer
  private let input: QuickLookInput
  private let url: URL
  private let maximumBytes: UInt64 = 100 * 1024 * 1024 * 1024

  init(url: URL, password: String) throws {
    self.url = url
    input = try QuickLookInput(url)
    guard let archive = archive_read_new() else { throw ArchiveError.invalidArchive }
    self.archive = archive
    // Только встроенные фильтры: fallback на внешнюю программу недопустим в Quick Look.
    for result in [
      archive_read_support_filter_gzip(archive), archive_read_support_filter_bzip2(archive),
      archive_read_support_filter_xz(archive), archive_read_support_filter_lzma(archive),
      archive_read_support_format_zip(archive), archive_read_support_format_7zip(archive),
      archive_read_support_format_tar(archive), archive_read_support_format_rar(archive),
      archive_read_support_format_rar5(archive),
    ] { try check(result) }
    if !password.isEmpty { try check(archive_read_add_passphrase(archive, password)) }
    try check(
      archive_read_set_seek_callback(archive) { _, context, offset, whence in
        guard let context else { return -1 }
        let input = Unmanaged<QuickLookInput>.fromOpaque(context).takeUnretainedValue()
        return input.perform {
          let result = lseek(input.descriptor, offset, whence)
          guard result >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
          return result
        }
      })
    try check(
      archive_read_open2(
        archive, Unmanaged.passUnretained(input).toOpaque(), nil,
        { _, context, output in
          guard let context else { return -1 }
          let input = Unmanaged<QuickLookInput>.fromOpaque(context).takeUnretainedValue()
          let count = input.perform {
            let result = Darwin.read(input.descriptor, input.buffer, 65_536)
            guard result >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return Int64(result)
          }
          output?.pointee = UnsafeRawPointer(input.buffer)
          return Int(count)
        },
        { _, context, offset in
          guard let context else { return -1 }
          let input = Unmanaged<QuickLookInput>.fromOpaque(context).takeUnretainedValue()
          return input.perform {
            let before = lseek(input.descriptor, 0, SEEK_CUR)
            let after = lseek(input.descriptor, offset, SEEK_CUR)
            guard before >= 0, after >= before else {
              throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return after - before
          }
        }, nil))
  }

  deinit { archive_read_free(archive) }

  private func check(_ result: Int32) throws {
    try input.check()
    if let error = input.error { throw error }
    guard result == 0 else {
      let message = archive_error_string(archive).map { String(cString: $0).lowercased() } ?? ""
      if message.contains("not supported") || message.contains("unsupported") {
        throw ArchiveError.unsupportedExtraction
      }
      if message.contains("passphrase") || message.contains("password")
        || message.contains("encrypted")
      {
        throw ArchiveError.passwordRequired
      }
      throw ArchiveError.invalidArchive
    }
  }

  func scan(output: URL? = nil, selectedPath: String? = nil, isDirectory: Bool = true) throws
    -> QuickLookListing
  {
    let manager = FileManager.default
    if let output, isDirectory {
      try manager.createDirectory(
        at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    var entries: [ArchiveEntry] = []
    var seen: Set<String> = []
    var normalized: [String: String] = [:]
    var total: UInt64 = 0
    var pathBytes = 0
    var metadata: [(URL, ArchiveEntry, Int)] = []
    while true {
      try input.check()
      var pointer: OpaquePointer?
      let status = archive_read_next_header(archive, &pointer)
      if status == 1 { break }
      try check(status)
      guard let pointer else { throw ArchiveError.malformedListing }
      let type = archive_entry_filetype(pointer)
      let unsupported =
        (type != S_IFREG && type != S_IFDIR)
        || archive_entry_symlink(pointer) != nil || archive_entry_hardlink(pointer) != nil
      guard let name = archive_entry_pathname_utf8(pointer),
        let raw = String(validatingCString: name)
      else { throw ArchiveError.malformedListing }
      let path = type == S_IFDIR && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
      try ArchiveListing.validatePath(path)
      pathBytes += path.utf8.count
      guard path.utf8.count <= 4096, pathBytes <= 32 * 1024 * 1024, entries.count < 100_000 else {
        throw ArchiveError.outputLimit
      }
      guard seen.insert(path).inserted else { throw ArchiveError.duplicatePath }
      let parts = path.split(separator: "/")
      for index in 1...parts.count {
        let component = parts.prefix(index).joined(separator: "/")
        let key = component.precomposedStringWithCanonicalMapping.lowercased()
        if let previous = normalized[key] {
          guard previous.utf8.elementsEqual(component.utf8) else {
            throw ArchiveError.duplicatePath
          }
        } else {
          pathBytes += component.utf8.count
          guard pathBytes <= 32 * 1024 * 1024, normalized.count < 100_000 else {
            throw ArchiveError.outputLimit
          }
          normalized[key] = component
        }
      }
      let rawSize = archive_entry_size(pointer)
      guard type == S_IFDIR || unsupported || archive_entry_size_is_set(pointer) != 0,
        rawSize >= 0
      else {
        throw ArchiveError.malformedListing
      }
      let size = type == S_IFDIR ? 0 : UInt64(rawSize)
      let sum = total.addingReportingOverflow(size)
      guard !sum.overflow, sum.partialValue <= maximumBytes else { throw ArchiveError.outputLimit }
      total = sum.partialValue
      let modified =
        archive_entry_mtime_is_set(pointer) != 0
        ? Date(
          timeIntervalSince1970: Double(archive_entry_mtime(pointer))
            + Double(archive_entry_mtime_nsec(pointer)) / 1_000_000_000) : nil
      let created =
        archive_entry_birthtime_is_set(pointer) != 0
        ? Date(
          timeIntervalSince1970: Double(archive_entry_birthtime(pointer))
            + Double(archive_entry_birthtime_nsec(pointer)) / 1_000_000_000) : nil
      let entry = ArchiveEntry(
        path: path, size: size, isDirectory: type == S_IFDIR, isSymbolicLink: unsupported,
        createdAt: created,
        modifiedAt: modified, isEncrypted: archive_entry_is_encrypted(pointer) > 0)
      entries.append(entry)
      let selected = selectedPath.map { path == $0 || path.hasPrefix($0 + "/") } ?? true
      if let output, selected {
        guard !unsupported else { throw ArchiveError.unsupportedExtraction }
        let relative =
          selectedPath.map { path == $0 ? "" : String(path.dropFirst($0.count + 1)) } ?? path
        let target = relative.isEmpty ? output : output.appendingPathComponent(relative)
        try manager.createDirectory(
          at: entry.isDirectory ? target : target.deletingLastPathComponent(),
          withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !entry.isDirectory { try write(entry, to: target) }
        try Quarantine.copy(from: url, to: target)
        metadata.append((target, entry, Int(archive_entry_perm(pointer)) & 0o777))
      } else {
        try check(archive_read_data_skip(archive))
      }
    }
    _ = try ArchiveListing.tree(from: entries)
    for (target, entry, permissions) in metadata.sorted(by: { $0.0.path.count > $1.0.path.count }) {
      try input.check()
      var attributes: [FileAttributeKey: Any] = [.posixPermissions: permissions]
      if let date = entry.modifiedAt { attributes[.modificationDate] = date }
      if let date = entry.createdAt { attributes[.creationDate] = date }
      try manager.setAttributes(attributes, ofItemAtPath: target.path)
    }
    if let output { try Quarantine.copy(from: url, to: output) }
    return QuickLookListing(
      entries: entries,
      format: archive_format_name(archive).map { String(cString: $0) } ?? "unknown")
  }

  private func write(_ entry: ArchiveEntry, to target: URL) throws {
    let fd = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    var size: UInt64 = 0
    while true {
      try input.check()
      let count = buffer.withUnsafeMutableBytes {
        archive_read_data(archive, $0.baseAddress, $0.count)
      }
      guard count >= 0 else {
        try check(Int32(count))
        throw ArchiveError.invalidArchive
      }
      if count == 0 { break }
      let sum = size.addingReportingOverflow(UInt64(count))
      guard !sum.overflow, sum.partialValue <= entry.size else {
        throw ArchiveError.extractionMismatch
      }
      size = sum.partialValue
      try handle.write(contentsOf: Data(buffer.prefix(count)))
    }
    guard size == entry.size else { throw ArchiveError.extractionMismatch }
  }
}
