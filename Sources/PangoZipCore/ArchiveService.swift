import Darwin
import Foundation

public actor ArchiveService {
  private struct Descriptor: Sendable {
    let format: String
    let canModify: Bool
    let isMultipart: Bool
    let volumeCount: Int
    let entries: [ArchiveEntry]
  }

  private struct EncryptionPolicy: Sendable {
    let enabled: Bool
    let zipMethod: String
    /// Сохраняет признак шифрования и метод ZIP, чтобы изменение не ослабляло защиту архива.
    init(format: String, entries: [ArchiveEntry], password: String) {
      enabled = entries.contains(where: \.isEncrypted) || (format == "7z" && !password.isEmpty)
      let methods = entries.filter(\.isEncrypted).compactMap(\.method).joined(separator: " ")
      zipMethod =
        methods.contains("AES-256")
        ? "AES256"
        : methods.contains("AES-192")
          ? "AES192" : methods.contains("AES-128") ? "AES128" : "ZipCrypto"
    }
  }

  private struct UndoState: Sendable {
    let url: URL
    let fingerprint: FileFingerprint
    let digest: Data
    let descriptor: Descriptor
  }

  private struct SessionState: Sendable {
    let url: URL
    var fingerprint: FileFingerprint
    var digest: Data?
    var descriptor: Descriptor
    let encryption: EncryptionPolicy
    var entries: [String: ArchiveEntry]
    var cache: [String: URL] = [:]
    var edits: [UUID: ArchiveEdit] = [:]
    var undo: UndoState?
  }

  private enum Mutation: Sendable {
    case add([URL], String, Bool)
    case delete([String])
    case save([ArchiveEdit])
  }

  private let executableURL: URL?
  private let workspace = TemporaryWorkspace()
  private var sessions: [UUID: SessionState] = [:]
  private var busy: Set<UUID> = []
  private let previewLimit: UInt64
  private let timeout: TimeInterval
  private var generation = 0

  /// Задаёт движок и пределы предпросмотра; рабочая область создаётся при первой операции.
  public init(
    executableURL: URL? = nil, previewLimit: UInt64 = 200 * 1024 * 1024, timeout: TimeInterval = 120
  ) {
    self.executableURL = executableURL ?? Self.resolveEngine()
    self.previewLimit = previewLimit
    self.timeout = timeout
  }

  /// Создаёт сеанс только для обычного файла, неизменившегося за время чтения списка.
  public func open(_ url: URL, password: String = "") async throws -> ArchiveSession {
    guard url.isFileURL else { throw ArchiveError.invalidArchive }
    let fingerprint = try FileFingerprint(url)
    guard fingerprint.type == .typeRegular else { throw ArchiveError.invalidArchive }
    let id = UUID()
    let initialGeneration = generation
    let directory = try workspace.sessionDirectory(id)
    do {
      let descriptor = try await readArchive(url, password: password, in: directory)
      try Task.checkCancellation()
      guard initialGeneration == generation else { throw ArchiveError.sessionExpired }
      guard try fingerprint == FileFingerprint(url) else { throw ArchiveError.archiveChanged }
      let state = SessionState(
        url: url, fingerprint: fingerprint, descriptor: descriptor,
        encryption: EncryptionPolicy(
          format: descriptor.format, entries: descriptor.entries, password: password),
        entries: Dictionary(uniqueKeysWithValues: descriptor.entries.map { ($0.path, $0) }))
      sessions[id] = state
      return try snapshot(id: id, state: state)
    } catch {
      try? workspace.removeSession(id)
      throw error
    }
  }

  /// Извлекает только выбранный обычный файл в приватную папку, проверяя размер и quarantine.
  public func materialize(_ entry: ArchiveEntry, in session: ArchiveSession, password: String = "")
    async throws -> URL
  {
    let state = try await checkedState(session)
    guard !busy.contains(session.id) else { throw ArchiveError.operationInProgress }
    guard state.entries[entry.path] == entry else { throw ArchiveError.sessionExpired }
    guard !entry.isDirectory, !entry.isSymbolicLink else { throw ArchiveError.unsupportedEntry }
    guard entry.size <= previewLimit else { throw ArchiveError.fileTooLarge }
    if let cached = state.cache[entry.path], FileManager.default.fileExists(atPath: cached.path) {
      try Quarantine.copy(from: state.url, to: cached)
      return cached
    }
    try ArchiveListing.validatePath(entry.path)
    let directory = try workspace.sessionDirectory(session.id).appendingPathComponent(
      "preview-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let output = directory.appendingPathComponent(String(entry.path.split(separator: "/").last!))
    do {
      try await runner().run(
        arguments: [
          "x", "-so", "-spd", "-ssc", "-y", "-bso0", "-bsp0", "-p" + password, "--", state.url.path,
          entry.path,
        ],
        outputURL: output, limit: previewLimit)
      try Task.checkCancellation()
      let latest = try await checkedState(session)
      guard latest.digest == state.digest else { throw ArchiveError.archiveChanged }
      let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
      guard (attributes[.size] as? NSNumber)?.uint64Value == entry.size else {
        throw ArchiveError.extractionMismatch
      }
      try Quarantine.copy(from: state.url, to: output)
      sessions[session.id]?.cache[entry.path] = output
      return output
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  /// Возвращает существующую правку или создаёт отдельную рабочую копию для внешнего редактора.
  public func beginEditing(_ entry: ArchiveEntry, in session: ArchiveSession, password: String = "")
    async throws -> ArchiveEdit
  {
    let state = try await checkedState(session)
    guard state.descriptor.canModify else { throw ArchiveError.readOnlyArchive }
    if let existing = state.edits.values.first(where: { $0.entry.path == entry.path }) {
      return existing
    }
    let source = try await materialize(entry, in: session, password: password)
    let directory = try workspace.sessionDirectory(session.id).appendingPathComponent(
      "edit-" + UUID().uuidString)
    let destination = directory.appendingPathComponent(
      String(entry.path.split(separator: "/").last!))
    do {
      try await StagedFiles.copy(source, to: destination)
      let latest = try await checkedState(session)
      // mutate сохраняет снимок состояния; новую правку нельзя регистрировать до его завершения.
      guard !busy.contains(session.id) else { throw ArchiveError.operationInProgress }
      guard latest.entries[entry.path] == entry else { throw ArchiveError.archiveChanged }
      if let existing = latest.edits.values.first(where: { $0.entry.path == entry.path }) {
        try? FileManager.default.removeItem(at: directory)
        return existing
      }
      let edit = ArchiveEdit(sessionID: session.id, entry: entry, fileURL: destination)
      sessions[session.id]?.edits[edit.id] = edit
      return edit
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  /// Добавляет подготовленные копии в выбранную папку через проверяемую транзакцию.
  public func add(
    _ urls: [URL], to session: ArchiveSession, directory: String = "", password: String = "",
    excludingSystemFiles: Bool = true
  ) async throws -> ArchiveSession {
    try await mutate(
      .add(urls, directory, excludingSystemFiles), session: session, password: password)
  }

  /// Удаляет выбранные записи вместе с потомками; затронутые активные правки блокируют операцию.
  public func delete(_ paths: [String], from session: ArchiveSession, password: String = "")
    async throws -> ArchiveSession
  {
    try await mutate(.delete(paths), session: session, password: password)
  }

  /// Сохраняет только зарегистрированные рабочие копии, которые не изменились за время транзакции.
  public func save(
    _ edits: [ArchiveEdit], in session: ArchiveSession, password: String = "",
    retainingWorkingCopies: Bool = false
  )
    async throws -> ArchiveSession
  {
    try await mutate(
      .save(edits), session: session, password: password,
      retainingWorkingCopies: retainingWorkingCopies)
  }

  /// История доступна один раз, когда внешние редакторы больше не могут сохранить старую копию.
  public func canUndo(_ session: ArchiveSession) async throws -> Bool {
    let state = try await checkedState(session)
    return state.undo != nil && state.edits.isEmpty && !busy.contains(session.id)
  }

  /// Восстанавливает последний снимок только поверх неизменившегося архива и проверяет целостность.
  public func undoLastChange(in session: ArchiveSession, password: String = "") async throws
    -> ArchiveSession
  {
    let state = try await checkedState(session)
    guard !busy.contains(session.id) else { throw ArchiveError.operationInProgress }
    guard state.edits.isEmpty else { throw ArchiveError.activeEdits }
    guard let undo = state.undo else { throw ArchiveError.invalidOperation }
    // Флаг занятости ставится до первой приостановки, иначе параллельная мутация успеет начаться.
    busy.insert(session.id)
    defer { busy.remove(session.id) }
    _ = try await ArchiveContentDigest.validate(
      undo.url, fingerprint: undo.fingerprint, digest: undo.digest)
    let transaction = try workspace.transactionDirectory(nextTo: state.url)
    defer { try? workspace.removeTransaction(transaction) }
    let working = transaction.appendingPathComponent("restore." + undo.descriptor.format)
    try await Self.copyArchive(undo.url, to: working)
    try await verify(working, passwordArguments: ["-p" + password], in: transaction)
    let descriptor = try await readArchive(working, password: password, in: transaction)
    guard descriptor.entries == undo.descriptor.entries else {
      throw ArchiveError.extractionMismatch
    }
    try Task.checkCancellation()
    let validated = try await checkedState(session)
    try replaceOriginal(validated, with: working)
    var updated = state
    updated.fingerprint = try FileFingerprint(state.url)
    updated.digest = undo.digest
    updated.descriptor = undo.descriptor
    updated.entries = Dictionary(
      uniqueKeysWithValues: undo.descriptor.entries.map { ($0.path, $0) })
    updated.cache.removeAll()
    updated.undo = nil
    sessions[session.id] = updated
    try? FileManager.default.removeItem(at: undo.url)
    return try snapshot(id: session.id, state: updated)
  }

  /// Удаляет данные сеанса, если для него не зарегистрирована блокирующая операция.
  public func close(_ session: ArchiveSession) throws {
    guard !busy.contains(session.id) else { throw ArchiveError.operationInProgress }
    try workspace.removeSession(session.id)
    sessions.removeValue(forKey: session.id)
  }

  /// Завершает все сеансы и меняет поколение, чтобы незавершённое открытие не восстановило их.
  public func cleanup() {
    generation += 1
    sessions.removeAll()
    workspace.cleanup()
  }

  /// Меняет копию на том же томе и проверяет результат перед согласованной заменой оригинала.
  private func mutate(
    _ mutation: Mutation, session: ArchiveSession, password: String,
    retainingWorkingCopies: Bool = false
  ) async throws
    -> ArchiveSession
  {
    let state = try await checkedState(session)
    guard state.descriptor.canModify else { throw ArchiveError.readOnlyArchive }
    guard !busy.contains(session.id) else { throw ArchiveError.operationInProgress }
    let encrypted = state.encryption.enabled
    guard !encrypted || !password.isEmpty else { throw ArchiveError.passwordRequired }
    busy.insert(session.id)
    defer { busy.remove(session.id) }
    let manager = FileManager.default
    let transaction = try workspace.transactionDirectory(nextTo: state.url)
    defer { try? workspace.removeTransaction(transaction) }
    let working = transaction.appendingPathComponent("working." + state.descriptor.format)
    let inputs = transaction.appendingPathComponent("inputs")
    try manager.createDirectory(
      at: inputs, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    // Копия архива сохраняет системные атрибуты; оригинал до commit не изменяется.
    try await Self.copyArchive(state.url, to: working)
    try Task.checkCancellation()
    _ = try await checkedState(session)
    let passwordArguments =
      (encrypted || (state.descriptor.format == "7z" && !password.isEmpty)) ? ["-p" + password] : []
    if encrypted {
      try await verify(working, passwordArguments: passwordArguments, in: transaction)
    }
    var names: [String] = []
    var removed: Set<String> = []
    var savedEdits: [ArchiveEdit] = []
    var editFingerprints: [UUID: FileFingerprint] = [:]
    var command = "a"
    switch mutation {
    case .add(let urls, let destination, let skipsSystemFiles):
      guard !urls.isEmpty else { throw ArchiveError.invalidOperation }
      if !destination.isEmpty {
        try ArchiveListing.validatePath(destination)
        guard
          state.entries[destination]?.isDirectory == true
            || state.entries.keys.contains(where: { $0.hasPrefix(destination + "/") })
        else { throw ArchiveError.invalidOperation }
      }
      for url in urls {
        guard url.isFileURL else { throw ArchiveError.invalidOperation }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let archivePath = state.url.resolvingSymlinksInPath().standardizedFileURL.path
        let type = try FileFingerprint(url).type
        guard path != archivePath, !(type == .typeDirectory && archivePath.hasPrefix(path + "/"))
        else { throw ArchiveError.invalidOperation }
        if skipsSystemFiles, SystemFiles.isSystemName(url.lastPathComponent) { continue }
        let name =
          destination.isEmpty ? url.lastPathComponent : destination + "/" + url.lastPathComponent
        try ArchiveListing.validatePath(name)
        guard
          !state.edits.values.contains(where: {
            $0.entry.path == name || $0.entry.path.hasPrefix(name + "/")
          })
        else { throw ArchiveError.activeEdits }
        try await StagedFiles.copy(
          url, to: inputs.appendingPathComponent(name), skippingSystemFiles: skipsSystemFiles)
        names.append(name)
      }
      guard !names.isEmpty else { throw ArchiveError.invalidOperation }
    case .delete(let paths):
      guard !paths.isEmpty else { throw ArchiveError.invalidOperation }
      for path in paths {
        try ArchiveListing.validatePath(path)
        let targets = state.entries.keys.filter { $0 == path || $0.hasPrefix(path + "/") }
        guard !targets.isEmpty else { throw ArchiveError.invalidOperation }
        removed.formUnion(targets)
      }
      guard !state.edits.values.contains(where: { removed.contains($0.entry.path) }) else {
        throw ArchiveError.activeEdits
      }
      names = removed.sorted()
      command = "d"
    case .save(let edits):
      guard !edits.isEmpty, Set(edits.map(\.id)).count == edits.count else {
        throw ArchiveError.invalidOperation
      }
      for edit in edits {
        guard edit.sessionID == session.id, state.edits[edit.id] == edit,
          state.entries[edit.entry.path] != nil
        else { throw ArchiveError.archiveChanged }
        let signature = try FileFingerprint(edit.fileURL)
        guard signature.type == .typeRegular else { throw ArchiveError.unsupportedEntry }
        editFingerprints[edit.id] = signature
        let target = inputs.appendingPathComponent(edit.entry.path)
        try await StagedFiles.copy(edit.fileURL, to: target)
        if let mode = edit.entry.permissions, let permissions = Self.permissions(from: mode) {
          try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
        names.append(edit.entry.path)
      }
      savedEdits = edits
    }
    let list = transaction.appendingPathComponent("items.list")
    try Self.writeNameList(names, to: list)
    var arguments =
      [
        command, "-t" + state.descriptor.format, "-spd", "-ssc", "-snl", "-y", "-scsUTF-8", "-bsp0",
        "-i@" + list.path,
      ] + passwordArguments
    if encrypted && state.descriptor.format == "7z" { arguments.append("-mhe=on") }
    if encrypted && state.descriptor.format == "zip" {
      arguments.append("-mem=" + state.encryption.zipMethod)
    }
    arguments += ["--", working.path]
    try await runner().run(
      arguments: arguments, outputURL: transaction.appendingPathComponent("mutation.log"),
      limit: 32 * 1024 * 1024, workingDirectory: inputs)
    try await verify(working, passwordArguments: passwordArguments, in: transaction)
    let descriptor = try await readArchive(working, password: password, in: transaction)
    let newEntries = Dictionary(uniqueKeysWithValues: descriptor.entries.map { ($0.path, $0) })
    guard descriptor.format == state.descriptor.format,
      removed.allSatisfy({ newEntries[$0] == nil })
    else { throw ArchiveError.extractionMismatch }
    if command == "a" {
      guard names.allSatisfy({ newEntries[$0] != nil }) else {
        throw ArchiveError.extractionMismatch
      }
    }
    for (path, entry) in state.entries where !entry.isDirectory && !removed.contains(path) {
      let intentionallyChanged = names.contains { path == $0 || path.hasPrefix($0 + "/") }
      if !intentionallyChanged {
        guard let current = newEntries[path], current.size == entry.size,
          current.checksum == entry.checksum, current.isEncrypted == entry.isEncrypted
        else { throw ArchiveError.extractionMismatch }
      }
    }
    try Task.checkCancellation()
    _ = try await checkedState(session)
    let undoURL = try workspace.sessionDirectory(session.id).appendingPathComponent(
      "undo-" + UUID().uuidString + "." + state.descriptor.format)
    var retainedUndo = false
    defer { if !retainedUndo { try? manager.removeItem(at: undoURL) } }
    try await Self.copyArchive(state.url, to: undoURL)
    let undoDigest: Data
    if let digest = state.digest {
      undoDigest = digest
    } else {
      undoDigest = try await ArchiveContentDigest.hash(undoURL)
    }
    let undo = UndoState(
      url: undoURL, fingerprint: try FileFingerprint(undoURL), digest: undoDigest,
      descriptor: state.descriptor)
    let digest = try await ArchiveContentDigest.hash(working)
    try Task.checkCancellation()
    let validated = try await checkedState(session)
    try replaceOriginal(validated, with: working, editFingerprints: editFingerprints)
    var updated = state
    updated.fingerprint = try FileFingerprint(state.url)
    updated.digest = digest
    updated.descriptor = descriptor
    updated.entries = newEntries
    updated.cache.removeAll()
    updated.undo = undo
    for edit in savedEdits where !retainingWorkingCopies {
      try? manager.removeItem(at: edit.fileURL.deletingLastPathComponent())
      updated.edits.removeValue(forKey: edit.id)
    }
    sessions[session.id] = updated
    retainedUndo = true
    if let previous = state.undo { try? manager.removeItem(at: previous.url) }
    return try snapshot(id: session.id, state: updated)
  }

  /// 7zz обрезает пробелы по краям строк list-файла, поэтому каждое имя берётся в кавычки:
  /// движок снимает только внешнюю пару, сохраняя пробелы и внутренние кавычки имени.
  static func writeNameList(_ names: [String], to url: URL) throws {
    try Data((names.map { "\"" + $0 + "\"" }.joined(separator: "\n") + "\n").utf8).write(to: url)
  }

  /// Согласованная замена сравнивает fingerprint непосредственно перед атомарной публикацией.
  private func replaceOriginal(
    _ state: SessionState, with working: URL, editFingerprints: [UUID: FileFingerprint] = [:]
  ) throws {
    var coordinationError: NSError?
    var replacementError: Error?
    NSFileCoordinator().coordinate(
      writingItemAt: state.url, options: .forReplacing, error: &coordinationError
    ) { url in
      do {
        guard try state.fingerprint == FileFingerprint(url) else {
          throw ArchiveError.archiveChanged
        }
        for (id, fingerprint) in editFingerprints {
          guard let edit = state.edits[id], try fingerprint == FileFingerprint(edit.fileURL) else {
            throw ArchiveError.editedFileChanged
          }
        }
        // 7zz пересоздаёт рабочую копию без расширенных атрибутов оригинала.
        try Quarantine.copy(from: url, to: working)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: working)
      } catch { replacementError = error }
    }
    if let coordinationError { throw coordinationError }
    if let replacementError { throw replacementError }
  }

  /// Независимые данные исключают касание ctime оригинала при удалении APFS-клона снимка.
  private static func copyArchive(_ source: URL, to destination: URL) async throws {
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let before = try FileFingerprint(source)
      guard before.type == .typeRegular else { throw ArchiveError.invalidArchive }
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let inputFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard inputFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      defer { Darwin.close(inputFD) }
      let outputFD = Darwin.open(
        destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard outputFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      defer { Darwin.close(outputFD) }
      let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: false)
      let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: false)
      while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty {
        try Task.checkCancellation()
        try output.write(contentsOf: data)
      }
      // COPYFILE_METADATA сохраняет quarantine, остальные xattr и ACL, не клонируя данные.
      guard fcopyfile(inputFD, outputFD, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try Task.checkCancellation()
      guard try before == FileFingerprint(source),
        try FileFingerprint(destination).type == .typeRegular
      else { throw ArchiveError.archiveChanged }
    }
    try await withTaskCancellationHandler {
      try await task.value
      try Task.checkCancellation()
    } onCancel: {
      task.cancel()
    }
  }

  /// Проверяет целостность движком и удаляет временный журнал независимо от результата.
  private func verify(
    _ url: URL, passwordArguments: [String], in directory: URL,
    progress: (@Sendable (Double) async -> Void)? = nil
  ) async throws {
    let output = directory.appendingPathComponent(UUID().uuidString + ".verify")
    defer { try? FileManager.default.removeItem(at: output) }
    try await runner().run(
      arguments: ["t", progress == nil ? "-bsp0" : "-bsp2"] + passwordArguments + ["--", url.path],
      outputURL: output,
      limit: 32 * 1024 * 1024, progress: progress)
  }

  /// Отделяет заголовок 7zz от записей и разрешает изменение только поддерживаемых простых архивов.
  /// xz, bzip2, zstd и lzma не хранят имя файла: 7zz выводит его из имени архива, список — нет.
  static func namedStreamListing(_ body: String, format: String, url: URL) -> String {
    guard ["xz", "bzip2", "zstd", "lzma"].contains(format),
      !body.hasPrefix("Path = "), !body.contains("\nPath = ")
    else { return body }
    let stem = url.deletingPathExtension().lastPathComponent
    let isShortTar = ["txz", "tbz", "tbz2", "tzst", "tlz"].contains(url.pathExtension.lowercased())
    let name = stem.isEmpty ? url.lastPathComponent : stem + (isShortTar ? ".tar" : "")
    return "Path = " + name + "\n" + body
  }

  /// Однофайловый поток без поля размера нельзя проверить при извлечении, пока размер не известен.
  static func hasUnknownStreamSize(_ body: String, format: String) -> Bool {
    ["xz", "bzip2", "zstd", "lzma"].contains(format)
      && (body.hasPrefix("Size = \n") || body.contains("\nSize = \n"))
  }

  /// Берёт итоговый распакованный размер из отчёта `7zz t` (строка «Size: N» после проверки).
  static func testedStreamSize(_ report: String) -> UInt64? {
    report.components(separatedBy: "\n").last { $0.hasPrefix("Size:") }
      .flatMap { UInt64($0.dropFirst(5).trimmingCharacters(in: .whitespaces)) }
  }

  private func readArchive(_ url: URL, password: String, in directory: URL) async throws
    -> Descriptor
  {
    let listing = directory.appendingPathComponent(UUID().uuidString + ".listing")
    defer { try? FileManager.default.removeItem(at: listing) }
    try await runner().run(
      arguments: ["l", "-slt", "-sccUTF-8", "-p" + password, "--", url.path], outputURL: listing,
      limit: 32 * 1024 * 1024)
    guard let text = String(data: try Data(contentsOf: listing), encoding: .utf8),
      let boundary = text.range(of: "\n----------\n")
    else { throw ArchiveError.malformedListing }
    let header = String(text[..<boundary.lowerBound])
    let body = String(text[boundary.upperBound...])
    let lines = header.components(separatedBy: "\n")
    let format =
      lines.first(where: { $0.hasPrefix("Type = ") }).map { String($0.dropFirst(7)).lowercased() }
      ?? "unknown"
    let multipart = lines.contains {
      $0 == "Multivolume = +" || $0 == "Is Volume = +"
        || ($0.hasPrefix("Volumes = ") && $0 != "Volumes = 1")
    }
    let stub = lines.contains { $0.hasPrefix("Offset = ") && $0 != "Offset = 0" }
    var named = Self.namedStreamListing(body, format: format, url: url)
    if Self.hasUnknownStreamSize(named, format: format) {
      // bzip2 и zstd часто не хранят исходный размер: 7zz узнаёт его только полной проверкой потока.
      let test = directory.appendingPathComponent(UUID().uuidString + ".test")
      defer { try? FileManager.default.removeItem(at: test) }
      try await runner().run(
        arguments: ["t", "-bsp0", "-bso1", "-sccUTF-8", "-p" + password, "--", url.path],
        outputURL: test, limit: 1024 * 1024)
      guard let report = String(data: try Data(contentsOf: test), encoding: .utf8),
        let size = Self.testedStreamSize(report)
      else { throw ArchiveError.malformedListing }
      named = named.components(separatedBy: "\n").map { $0 == "Size = " ? "Size = \(size)" : $0 }
        .joined(separator: "\n")
    }
    let entries = try ArchiveListing.parse(named)
    _ = try ArchiveListing.tree(from: entries)
    return Descriptor(
      format: format, canModify: ["zip", "7z", "tar"].contains(format) && !multipart && !stub,
      isMultipart: multipart,
      volumeCount: lines.first(where: { $0.hasPrefix("Volumes = ") })
        .flatMap { Int($0.dropFirst(10)) } ?? 1,
      entries: entries)
  }

  /// Строит независимый снимок интерфейса из текущего списка записей.
  private func snapshot(id: UUID, state: SessionState) throws -> ArchiveSession {
    ArchiveSession(
      id: id, url: state.url, entries: state.descriptor.entries,
      roots: try ArchiveListing.tree(from: state.descriptor.entries),
      format: state.descriptor.format, canModify: state.descriptor.canModify)
  }

  /// Подтверждает принадлежность сеанса и неизменность исходного файла перед продолжением операции.
  private func checkedState(_ session: ArchiveSession) async throws -> SessionState {
    guard let state = sessions[session.id], state.url == session.url else {
      throw ArchiveError.sessionExpired
    }
    let validated = try await ArchiveContentDigest.validate(
      state.url, fingerprint: state.fingerprint, digest: state.digest)
    guard var latest = sessions[session.id], latest.url == session.url else {
      throw ArchiveError.sessionExpired
    }
    guard latest.digest == state.digest,
      latest.fingerprint == state.fingerprint || latest.fingerprint == validated,
      try validated == FileFingerprint(state.url)
    else { throw ArchiveError.archiveChanged }
    latest.fingerprint = validated
    sessions[session.id] = latest
    return latest
  }

  /// Проверяет доступность движка перед каждым запуском, сохраняя заданный предел времени.
  private func runner() throws -> EngineProcess {
    guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw ArchiveError.engineUnavailable
    }
    return EngineProcess(executableURL: executableURL, timeout: timeout)
  }

  /// Переводит обычные Unix-права из текстового режима, не восстанавливая специальные биты.
  private static func permissions(from mode: String) -> Int? {
    guard mode.count >= 10 else { return nil }
    var value = 0
    for (index, char) in mode.dropFirst().prefix(9).enumerated() {
      let readable = index % 3 == 0 && char == "r"
      let writable = index % 3 == 1 && char == "w"
      let executable = index % 3 == 2 && ["x", "s", "t"].contains(char)
      if readable || writable || executable { value |= 1 << (8 - index) }
    }
    return value
  }

  /// Предпочитает движок комплекта приложения, затем ищет локальную разработческую установку.
  private static func resolveEngine() -> URL? {
    let candidates = [
      Bundle.main.resourceURL?.appendingPathComponent("Engine/7zz"),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
        "Resources/Engine/7zz"),
      URL(fileURLWithPath: "/opt/homebrew/bin/7zz"), URL(fileURLWithPath: "/usr/local/bin/7zz"),
    ]
    return candidates.compactMap { $0 }.first {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
  }
}

extension ArchiveService {
  /// Копирует выбранные объекты, проверяет созданный архив и публикует его под свободным именем.
  public func createArchive(
    from urls: [URL], proposedURL: URL, format: String, options: CompressionOptions? = nil,
    password: String = "", progress: ArchiveProgressHandler? = nil
  ) async throws -> URL {
    let reporter = ArchiveProgressReporter(progress)
    await reporter.report(phase: .preparing)
    guard CompressionOptions.supportedFormats.contains(format), !urls.isEmpty,
      proposedURL.isFileURL
    else { throw ArchiveError.invalidOperation }
    // tar, tar.gz, tar.xz и wim не шифруют: молча создать открытый архив вместо защищённого нельзя.
    guard password.isEmpty || CompressionOptions.supportsPassword(format) else {
      throw ArchiveError.invalidOperation
    }
    let compression = options ?? CompressionOptions(format: format)
    let initialGeneration = generation
    let transaction = try workspace.transactionDirectory(nextTo: proposedURL)
    defer { try? workspace.removeTransaction(transaction) }
    let inputs = transaction.appendingPathComponent("inputs")
    try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: false)
    var names: [String] = []
    var seen: Set<URL> = []
    for url in urls {
      guard url.isFileURL else { throw ArchiveError.invalidOperation }
      let path = url.standardizedFileURL
      guard seen.insert(path).inserted else { continue }
      // Если выбрана и папка, и её содержимое, сохраняем содержимое только внутри папки.
      if urls.contains(where: { other in
        other != url && path.path.hasPrefix(other.standardizedFileURL.path + "/")
          && (try? FileFingerprint(other).type) == .typeDirectory
      }) {
        continue
      }
      let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
      guard !transaction.resolvingSymlinksInPath().path.hasPrefix(resolved + "/") else {
        throw ArchiveError.invalidOperation
      }
      if compression.excludesSystemFiles, SystemFiles.isSystemName(url.lastPathComponent) {
        continue
      }
      try ArchiveListing.validatePath(url.lastPathComponent)
      try await StagedFiles.copy(
        url, to: inputs.appendingPathComponent(url.lastPathComponent),
        skippingSystemFiles: compression.excludesSystemFiles)
      names.append(url.lastPathComponent)
    }
    guard !names.isEmpty else { throw ArchiveError.invalidOperation }
    let workload = progress == nil ? nil : try await ArchiveWorkload.measure(inputs)
    let bytes = workload?.bytes ?? 0
    let files = workload?.files ?? 0
    let list = transaction.appendingPathComponent("items.list")
    try Self.writeNameList(names, to: list)
    let settings = CompressionOptions(
      format: format, level: compression.level, solid: compression.solid,
      threads: compression.threads, volumeSizeMB: compression.volumeSizeMB,
      encryptsFileNames: compression.encryptsFileNames)
    let isCompressedTar = format == "tar.gz" || format == "tar.xz"
    // Первый шаг tar.gz и tar.xz — обычный TAR; имя внутри потока берётся из будущего имени архива.
    let engineFormat = isCompressedTar ? "tar" : format
    let innerName =
      isCompressedTar
      ? ArchiveOutput.stem(of: proposedURL, removing: "." + format) + ".tar" : nil
    let working = transaction.appendingPathComponent("working." + format)
    let tarStep = innerName.map { transaction.appendingPathComponent($0) } ?? working
    // Многотомный результат: 7zz добавляет к имени .001, .002 и так далее.
    let firstVolume = URL(fileURLWithPath: working.path + ".001")
    let measured = settings.volumeSizeMB == nil ? working : firstVolume
    await reporter.report(
      phase: .compressing, fraction: 0, processedBytes: 0, totalBytes: bytes, totalFiles: files)
    let tarShare = isCompressedTar ? 0.45 : 0.9
    let tarBytes = isCompressedTar ? bytes / 2 : bytes
    try await runner().run(
      arguments: [
        "a", "-t" + engineFormat, "-spd", "-ssc", "-snl", "-scsUTF-8",
        progress == nil ? "-bsp0" : "-bsp2", "-i@" + list.path,
      ]
        + (isCompressedTar ? [] : settings.arguments + settings.volumeArguments)
        + (password.isEmpty
          ? []
          : [
            "-p" + password,
            format == "7z" ? (settings.encryptsFileNames ? "-mhe=on" : "-mhe=off") : "-mem=AES256",
          ])
        + ["--", tarStep.path],
      outputURL: transaction.appendingPathComponent("create.log"), limit: 32 * 1024 * 1024,
      workingDirectory: inputs,
      progress: reporter.engine(
        phase: .compressing, from: 0, to: tarShare, totalBytes: bytes, itemBytes: tarBytes,
        totalFiles: files, outputURL: measured))
    if isCompressedTar {
      try await runner().run(
        arguments: [
          "a", "-t" + (format == "tar.gz" ? "gzip" : "xz"), "-spd", "-ssc", "-scsUTF-8",
          progress == nil ? "-bsp0" : "-bsp2",
        ] + settings.arguments + ["--", working.path, tarStep.path],
        outputURL: transaction.appendingPathComponent("compress.log"), limit: 32 * 1024 * 1024,
        progress: reporter.engine(
          phase: .compressing, from: tarShare, to: 0.9, totalBytes: bytes,
          baseBytes: tarBytes, itemBytes: bytes - tarBytes, totalFiles: files,
          outputURL: working))
      try? FileManager.default.removeItem(at: tarStep)
    }
    // Тома находятся по числовому суффиксу; верификация и чтение идут по первому тому.
    var volumes: [URL] = []
    if settings.volumeSizeMB != nil {
      let prefix = working.lastPathComponent + "."
      volumes = try FileManager.default.contentsOfDirectory(
        at: transaction, includingPropertiesForKeys: nil
      ).filter {
        let tail = $0.lastPathComponent.dropFirst(prefix.count)
        return $0.lastPathComponent.hasPrefix(prefix) && !tail.isEmpty
          && tail.allSatisfy { $0.isASCII && $0.isNumber }
      }.sorted { $0.lastPathComponent < $1.lastPathComponent }
      guard volumes.first?.lastPathComponent == firstVolume.lastPathComponent else {
        throw ArchiveError.invalidArchive
      }
    }
    let primary = volumes.first ?? working
    await reporter.report(
      phase: .verifying, fraction: 0.9, processedBytes: 0, totalBytes: bytes,
      totalFiles: files, outputURL: primary)
    try await verify(
      primary, passwordArguments: password.isEmpty ? [] : ["-p" + password], in: transaction,
      progress: reporter.engine(
        phase: .verifying, from: 0.9, to: 0.99, totalBytes: bytes, totalFiles: files,
        outputURL: primary))
    _ = try await readArchive(primary, password: password, in: transaction)
    try Task.checkCancellation()
    guard initialGeneration == generation else { throw ArchiveError.sessionExpired }
    await reporter.report(
      phase: .finalizing, fraction: 0.99, processedBytes: bytes, totalBytes: bytes,
      completedFiles: files, totalFiles: files, outputURL: primary)
    try Task.checkCancellation()
    guard initialGeneration == generation else { throw ArchiveError.sessionExpired }
    let result: URL
    if !volumes.isEmpty || isCompressedTar {
      // Составные расширения и наборы томов публикуются под общим свободным именем.
      let stem = ArchiveOutput.stem(of: proposedURL, removing: "." + format)
      let prefix = "working"
      let items =
        volumes.isEmpty
        ? [(source: working, suffix: "." + format)]
        : volumes.map { (source: $0, suffix: String($0.lastPathComponent.dropFirst(prefix.count))) }
      result = try ArchiveOutput.publishSet(
        items, parent: proposedURL.deletingLastPathComponent(), stem: stem)[0]
    } else {
      result = try ArchiveOutput.publish(working, proposed: proposedURL, isDirectory: false)
    }
    await reporter.report(
      phase: .finalizing, fraction: 1, processedBytes: bytes, totalBytes: bytes,
      completedFiles: files, totalFiles: files, outputURL: result)
    return result
  }

  /// Проверяет пути, ссылки и суммарный размер; готовые объекты публикует без перезаписи.
  public func extractArchive(
    _ url: URL, password: String = "", maximumBytes: UInt64 = 100 * 1024 * 1024 * 1024,
    directory: URL? = nil, createsSubfolder: Bool = true, progress: ArchiveProgressHandler? = nil
  ) async throws -> URL {
    let reporter = ArchiveProgressReporter(progress)
    await reporter.report(phase: .preparing)
    let session = try await open(url, password: password)
    defer {
      sessions.removeValue(forKey: session.id)
      try? workspace.removeSession(session.id)
    }
    let state = try await checkedState(session)
    let parent = directory ?? url.deletingLastPathComponent()
    guard parent.isFileURL else { throw ArchiveError.invalidOperation }
    let destination = parent.appendingPathComponent(FinderSelection.extractionName(for: url))
    let transaction = try workspace.transactionDirectory(nextTo: destination)
    defer { try? workspace.removeTransaction(transaction) }
    let output = transaction.appendingPathComponent("contents")
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var source = url
    var descriptor = state.descriptor
    var verificationStart = 0.0
    // В tar.gz/tgz и аналогах сначала снимаем слой сжатия, затем извлекаем TAR.
    if ["gzip", "bzip2", "xz", "zstd", "lzma"].contains(descriptor.format),
      descriptor.entries.count == 1,
      descriptor.entries[0].path.lowercased().hasSuffix(".tar")
        || ["tgz", "tbz", "tbz2", "txz", "tzst"].contains(url.pathExtension.lowercased())
    {
      guard let entry = descriptor.entries.first, !entry.isSymbolicLink, entry.size <= maximumBytes
      else {
        throw ArchiveError.outputLimit
      }
      source = transaction.appendingPathComponent("inner.tar")
      await reporter.report(
        phase: .extracting, fraction: 0, processedBytes: 0, totalBytes: entry.size,
        completedFiles: 0, totalFiles: 1, currentFile: entry.path, outputURL: url)
      try await extractFile(
        entry, from: url, to: source, password: password,
        progress: reporter.engine(
          phase: .extracting, from: 0, to: 0.1, totalBytes: entry.size, itemBytes: entry.size,
          completedFiles: 0, totalFiles: 1, currentFile: entry.path, outputURL: url),
        // gzip хранит размер по модулю 4 ГиБ; целостность потока подтверждает его CRC.
        sizeLimit: descriptor.format == "gzip" ? maximumBytes : nil)
      verificationStart = 0.1
      descriptor = try await readArchive(source, password: password, in: transaction)
      guard descriptor.format == "tar" else { throw ArchiveError.invalidArchive }
    }
    _ = try ArchiveExtractionManifest(entries: descriptor.entries, maximumBytes: maximumBytes)
    let workload = try ArchiveWorkload(entries: descriptor.entries)
    let extractionStart = verificationStart + 0.1
    let verificationBase = verificationStart
    await reporter.report(
      phase: .verifying, fraction: verificationBase, processedBytes: 0,
      totalBytes: workload.bytes, totalFiles: workload.files, outputURL: url)
    try await verify(
      source, passwordArguments: ["-p" + password], in: transaction,
      progress: reporter.engine(
        phase: .verifying, from: verificationBase, to: extractionStart,
        totalBytes: workload.bytes, totalFiles: workload.files, outputURL: url))
    try await extractEntries(
      descriptor.entries, from: source, archiveDescriptor: descriptor, to: output,
      in: transaction, password: password, quarantineSource: url, maximumBytes: maximumBytes,
      reporter: reporter, start: extractionStart)
    await reporter.report(
      phase: .finalizing, fraction: 0.99, processedBytes: workload.bytes,
      totalBytes: workload.bytes, completedFiles: workload.files, totalFiles: workload.files)
    _ = try await checkedState(session)
    try Task.checkCancellation()
    if createsSubfolder {
      let result = try ArchiveOutput.publish(output, proposed: destination, isDirectory: true)
      await reporter.report(
        phase: .finalizing, fraction: 1, processedBytes: workload.bytes,
        totalBytes: workload.bytes, completedFiles: workload.files, totalFiles: workload.files)
      return result
    }
    for child in try FileManager.default.contentsOfDirectory(
      at: output, includingPropertiesForKeys: nil)
    {
      _ = try ArchiveOutput.publish(
        child, proposed: parent.appendingPathComponent(child.lastPathComponent),
        isDirectory: try FileFingerprint(child).type == .typeDirectory)
    }
    await reporter.report(
      phase: .finalizing, fraction: 1, processedBytes: workload.bytes,
      totalBytes: workload.bytes, completedFiles: workload.files, totalFiles: workload.files)
    return parent
  }

  /// Создаёт временный сеанс для проверки целостности и подтверждает неизменность архива после неё.
  public func testArchive(_ url: URL, password: String = "") async throws {
    let session = try await open(url, password: password)
    defer {
      sessions.removeValue(forKey: session.id)
      try? workspace.removeSession(session.id)
    }
    let directory = try workspace.sessionDirectory(session.id)
    try await verify(url, passwordArguments: ["-p" + password], in: directory)
    _ = try await checkedState(session)
  }

  /// Извлекает ровно одну запись через stdout и требует совпадения фактического и заявленного размера.
  private func extractFile(
    _ entry: ArchiveEntry, from archive: URL, to output: URL, password: String,
    progress: (@Sendable (Double) async -> Void)? = nil, sizeLimit: UInt64? = nil
  ) async throws {
    try await runner().run(
      arguments: [
        "x", "-so", "-spd", "-ssc", "-y", "-bso0", progress == nil ? "-bsp0" : "-bsp2",
        "-p" + password, "--", archive.path,
        entry.path,
      ],
      outputURL: output, limit: sizeLimit ?? entry.size, progress: progress)
    guard try sizeLimit != nil || FileFingerprint(output).size == entry.size else {
      throw ArchiveError.extractionMismatch
    }
  }
}

extension ArchiveService {
  /// Извлекает всю выборку одним запуском и публикует только проверенные корни.
  public func exportSelection(
    _ paths: [String], from session: ArchiveSession, to directory: URL, password: String = "",
    maximumBytes: UInt64 = 100 * 1024 * 1024 * 1024,
    progress: ArchiveProgressHandler? = nil
  ) async throws -> [URL] {
    let reporter = ArchiveProgressReporter(progress)
    await reporter.report(phase: .preparing)
    let state = try await checkedState(session)
    guard directory.isFileURL else { throw ArchiveError.invalidOperation }
    guard !busy.contains(session.id) else { throw ArchiveError.operationInProgress }
    let roots = try ArchiveSelection.topLevelPaths(paths, entries: state.descriptor.entries)
    let entries = state.descriptor.entries.filter { entry in
      roots.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
    }
    _ = try ArchiveExtractionManifest(entries: entries, maximumBytes: maximumBytes)
    busy.insert(session.id)
    defer { busy.remove(session.id) }
    let transaction = try workspace.transactionDirectory(
      nextTo: directory.appendingPathComponent("selection"))
    defer { try? workspace.removeTransaction(transaction) }
    let output = transaction.appendingPathComponent("contents")
    try await extractEntries(
      entries, from: state.url, archiveDescriptor: state.descriptor, to: output,
      in: transaction, password: password, quarantineSource: state.url,
      maximumBytes: maximumBytes, reporter: reporter, start: 0)
    let workload = try ArchiveWorkload(entries: entries)
    await reporter.report(
      phase: .finalizing, fraction: 0.99, processedBytes: workload.bytes,
      totalBytes: workload.bytes, completedFiles: workload.files, totalFiles: workload.files)
    try Task.checkCancellation()
    _ = try await checkedState(session)
    var results: [URL] = []
    for path in roots {
      let proposed = directory.appendingPathComponent(String(path.split(separator: "/").last!))
      guard proposed.standardizedFileURL != state.url.standardizedFileURL else {
        throw ArchiveError.invalidOperation
      }
      results.append(
        try ArchiveOutput.publish(
          output.appendingPathComponent(path), proposed: proposed,
          isDirectory: state.entries[path]?.isDirectory != false))
    }
    await reporter.report(
      phase: .finalizing, fraction: 1, processedBytes: workload.bytes,
      totalBytes: workload.bytes, completedFiles: workload.files, totalFiles: workload.files)
    return results
  }

  /// Готовит выбранную запись или дерево рядом с целью и публикует после проверки исходного архива.
  public func exportItem(
    _ path: String, from session: ArchiveSession, to destination: URL, password: String = "",
    chooseUniqueName: Bool = false, maximumBytes: UInt64 = 100 * 1024 * 1024 * 1024,
    progress: ArchiveProgressHandler? = nil
  ) async throws -> URL {
    let reporter = ArchiveProgressReporter(progress)
    await reporter.report(phase: .preparing)
    let state = try await checkedState(session)
    guard !busy.contains(session.id), destination.isFileURL else {
      throw ArchiveError.invalidOperation
    }
    let entries = try ArchiveSelection.entries(for: path, in: state.descriptor.entries)
    let isDirectory = state.entries[path]?.isDirectory != false
    guard destination.standardizedFileURL != state.url.standardizedFileURL else {
      throw ArchiveError.invalidOperation
    }
    busy.insert(session.id)
    defer { busy.remove(session.id) }
    let transaction = try workspace.transactionDirectory(nextTo: destination)
    defer { try? workspace.removeTransaction(transaction) }
    let contents = transaction.appendingPathComponent("contents")
    try await extractEntries(
      entries, from: state.url, archiveDescriptor: state.descriptor, to: contents,
      in: transaction, password: password, quarantineSource: state.url,
      maximumBytes: maximumBytes, reporter: reporter, start: 0)
    let output = contents.appendingPathComponent(path)
    let workload = try ArchiveWorkload(entries: entries)
    await reporter.report(
      phase: .finalizing, fraction: 0.99, processedBytes: workload.bytes,
      totalBytes: workload.bytes, completedFiles: workload.files, totalFiles: workload.files)
    try Task.checkCancellation()
    _ = try await checkedState(session)
    let result: URL
    if chooseUniqueName {
      result = try ArchiveOutput.publish(output, proposed: destination, isDirectory: isDirectory)
    } else {
      try ArchiveOutput.publishExact(output, to: destination)
      result = destination
    }
    await reporter.report(
      phase: .finalizing, fraction: 1, processedBytes: workload.bytes,
      totalBytes: workload.bytes, completedFiles: workload.files, totalFiles: workload.files)
    return result
  }

  /// Числовые части имеют однозначные имена; остальные схемы остаются на потоковом извлечении.
  private func snapshotVolumes(for archive: URL, descriptor: Descriptor) throws -> [URL]? {
    guard descriptor.isMultipart else { return [archive] }
    let suffix = archive.pathExtension
    guard descriptor.format == "split", !suffix.isEmpty, suffix.count <= 8,
      suffix.allSatisfy({ $0.isASCII && $0.isNumber }), Int(suffix) == 1
    else { return nil }
    guard descriptor.volumeCount > 1, descriptor.volumeCount <= 10_000 else {
      throw ArchiveError.outputLimit
    }
    let stem = archive.deletingPathExtension()
    return (1...descriptor.volumeCount).map { index in
      let value = String(index)
      let padding = String(repeating: "0", count: max(0, suffix.count - value.count))
      return stem.appendingPathExtension(padding + value)
    }
  }

  /// Стабильная копия исключает замену архива между проверкой путей и записью движком в staging.
  private func extractEntries(
    _ entries: [ArchiveEntry], from archive: URL, archiveDescriptor: Descriptor, to output: URL,
    in transaction: URL, password: String, quarantineSource: URL, maximumBytes: UInt64,
    reporter: ArchiveProgressReporter, start: Double
  ) async throws {
    let manifest = try ArchiveExtractionManifest(entries: entries, maximumBytes: maximumBytes)
    let manager = FileManager.default
    try manager.createDirectory(
      at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let workload = try ArchiveWorkload(entries: entries)
    if !entries.isEmpty {
      await reporter.report(
        phase: .extracting, fraction: start, processedBytes: 0, totalBytes: workload.bytes,
        completedFiles: 0, totalFiles: workload.files,
        currentFile: (entries.first(where: { !$0.isDirectory && $0.size > 0 })
          ?? entries.first(where: { !$0.isDirectory }))?.path)
      if let volumes = try snapshotVolumes(for: archive, descriptor: archiveDescriptor) {
        let snapshotDirectory = transaction.appendingPathComponent("source-" + UUID().uuidString)
        let source = snapshotDirectory.appendingPathComponent(archive.lastPathComponent)
        for volume in volumes {
          try await Self.copyArchive(
            volume, to: snapshotDirectory.appendingPathComponent(volume.lastPathComponent))
        }
        let descriptor = try await readArchive(source, password: password, in: transaction)
        guard descriptor.entries == archiveDescriptor.entries else {
          throw ArchiveError.archiveChanged
        }
        let list = transaction.appendingPathComponent("extract.list")
        try Self.writeNameList(entries.map(\.path), to: list)
        try await runner().run(
          arguments: [
            "x", "-spd", "-ssc", "-r-", "-y", "-bso0", "-scsUTF-8", "-p" + password,
            "-bsp2", "-i@" + list.path, "-o" + output.path, "--", source.path,
          ], outputURL: transaction.appendingPathComponent("extract.log"), limit: 32 * 1024 * 1024,
          progress: reporter.engine(
            phase: .extracting, from: start, to: 0.98, totalBytes: workload.bytes,
            totalFiles: workload.files),
          validateOutput: { try manifest.validate(output, complete: false) })
      } else {
        // shortcut: неизвестные схемы multipart читаются через stdout; batch требует точного списка томов.
        var completedBytes: UInt64 = 0
        var completedFiles = 0
        for entry in entries {
          try Task.checkCancellation()
          let target = output.appendingPathComponent(entry.path)
          try manager.createDirectory(
            at: entry.isDirectory ? target : target.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
          if !entry.isDirectory {
            let lower = start + Double(completedFiles) / Double(workload.files) * (0.98 - start)
            let upper = start + Double(completedFiles + 1) / Double(workload.files) * (0.98 - start)
            try await extractFile(
              entry, from: archive, to: target, password: password,
              progress: reporter.engine(
                phase: .extracting, from: lower, to: upper, totalBytes: workload.bytes,
                baseBytes: completedBytes, itemBytes: entry.size, completedFiles: completedFiles,
                totalFiles: workload.files, currentFile: entry.path))
            completedBytes += entry.size
            completedFiles += 1
          }
        }
      }
    }
    let extracted = try manifest.validate(output, complete: true)
    for path in extracted {
      try Task.checkCancellation()
      try Quarantine.copy(from: quarantineSource, to: output.appendingPathComponent(path))
    }
    for entry in entries.sorted(by: { $0.path.count > $1.path.count })
    where extracted.contains(entry.path) {
      try Task.checkCancellation()
      let target = output.appendingPathComponent(entry.path)
      var attributes: [FileAttributeKey: Any] = [:]
      if let date = entry.modifiedAt { attributes[.modificationDate] = date }
      if let date = entry.createdAt { attributes[.creationDate] = date }
      if let mode = entry.permissions, let value = Self.permissions(from: mode) {
        attributes[.posixPermissions] = value
      }
      try manager.setAttributes(attributes, ofItemAtPath: target.path)
    }
    try Quarantine.copy(from: quarantineSource, to: output)
  }
}
