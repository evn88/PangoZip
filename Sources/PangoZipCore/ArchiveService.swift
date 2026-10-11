import Foundation

public actor ArchiveService {
  private struct Descriptor: Sendable {
    let format: String
    let canModify: Bool
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

  private struct SessionState: Sendable {
    let url: URL
    var fingerprint: FileFingerprint
    var descriptor: Descriptor
    let encryption: EncryptionPolicy
    var entries: [String: ArchiveEntry]
    var cache: [String: URL] = [:]
    var edits: [UUID: ArchiveEdit] = [:]
  }

  private enum Mutation: Sendable {
    case add([URL], String)
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
    let state = try checkedState(session)
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
      let latest = try checkedState(session)
      guard latest.fingerprint == state.fingerprint else { throw ArchiveError.archiveChanged }
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
    let state = try checkedState(session)
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
      let latest = try checkedState(session)
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
    _ urls: [URL], to session: ArchiveSession, directory: String = "", password: String = ""
  ) async throws -> ArchiveSession {
    try await mutate(.add(urls, directory), session: session, password: password)
  }

  /// Удаляет выбранные записи вместе с потомками; затронутые активные правки блокируют операцию.
  public func delete(_ paths: [String], from session: ArchiveSession, password: String = "")
    async throws -> ArchiveSession
  {
    try await mutate(.delete(paths), session: session, password: password)
  }

  /// Сохраняет только зарегистрированные рабочие копии, которые не изменились за время транзакции.
  public func save(_ edits: [ArchiveEdit], in session: ArchiveSession, password: String = "")
    async throws -> ArchiveSession
  {
    try await mutate(.save(edits), session: session, password: password)
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
  private func mutate(_ mutation: Mutation, session: ArchiveSession, password: String) async throws
    -> ArchiveSession
  {
    let state = try checkedState(session)
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
    let copyTask = Task.detached { try FileManager.default.copyItem(at: state.url, to: working) }
    try await copyTask.value
    try Task.checkCancellation()
    _ = try checkedState(session)
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
    case .add(let urls, let destination):
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
        let name =
          destination.isEmpty ? url.lastPathComponent : destination + "/" + url.lastPathComponent
        try ArchiveListing.validatePath(name)
        guard
          !state.edits.values.contains(where: {
            $0.entry.path == name || $0.entry.path.hasPrefix(name + "/")
          })
        else { throw ArchiveError.activeEdits }
        try await StagedFiles.copy(url, to: inputs.appendingPathComponent(name))
        names.append(name)
      }
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
          state.entries[edit.entry.path] == edit.entry
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
    try Data((names.joined(separator: "\n") + "\n").utf8).write(to: list)
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
    for edit in savedEdits {
      guard try editFingerprints[edit.id] == FileFingerprint(edit.fileURL) else {
        throw ArchiveError.editedFileChanged
      }
    }
    try Task.checkCancellation()
    _ = try checkedState(session)
    var coordinationError: NSError?
    var replacementError: Error?
    NSFileCoordinator().coordinate(
      writingItemAt: state.url, options: .forReplacing, error: &coordinationError
    ) { url in
      do {
        guard try state.fingerprint == FileFingerprint(url) else {
          throw ArchiveError.archiveChanged
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: working)
      } catch { replacementError = error }
    }
    if let coordinationError { throw coordinationError }
    if let replacementError { throw replacementError }
    var updated = state
    updated.fingerprint = try FileFingerprint(state.url)
    updated.descriptor = descriptor
    updated.entries = newEntries
    updated.cache.removeAll()
    for edit in savedEdits {
      try? manager.removeItem(at: edit.fileURL.deletingLastPathComponent())
      updated.edits.removeValue(forKey: edit.id)
    }
    sessions[session.id] = updated
    return try snapshot(id: session.id, state: updated)
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
    let entries = try ArchiveListing.parse(body)
    _ = try ArchiveListing.tree(from: entries)
    return Descriptor(
      format: format, canModify: ["zip", "7z", "tar"].contains(format) && !multipart && !stub,
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
  private func checkedState(_ session: ArchiveSession) throws -> SessionState {
    guard let state = sessions[session.id], state.url == session.url else {
      throw ArchiveError.sessionExpired
    }
    guard try state.fingerprint == FileFingerprint(state.url) else {
      throw ArchiveError.archiveChanged
    }
    return state
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
    guard ["zip", "7z"].contains(format), !urls.isEmpty, proposedURL.isFileURL else {
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
      try ArchiveListing.validatePath(url.lastPathComponent)
      try await StagedFiles.copy(url, to: inputs.appendingPathComponent(url.lastPathComponent))
      names.append(url.lastPathComponent)
    }
    guard !names.isEmpty else { throw ArchiveError.invalidOperation }
    let workload = progress == nil ? nil : try await ArchiveWorkload.measure(inputs)
    let bytes = workload?.bytes ?? 0
    let files = workload?.files ?? 0
    let list = transaction.appendingPathComponent("items.list")
    try Data((names.joined(separator: "\n") + "\n").utf8).write(to: list)
    let working = transaction.appendingPathComponent("working." + format)
    let settings = CompressionOptions(
      format: format, level: compression.level, solid: compression.solid,
      threads: compression.threads)
    await reporter.report(
      phase: .compressing, fraction: 0, processedBytes: 0, totalBytes: bytes, totalFiles: files)
    try await runner().run(
      arguments: [
        "a", "-t" + format, "-spd", "-ssc", "-snl", "-scsUTF-8",
        progress == nil ? "-bsp0" : "-bsp2", "-i@" + list.path,
      ]
        + settings.arguments
        + (password.isEmpty ? [] : ["-p" + password, format == "7z" ? "-mhe=on" : "-mem=AES256"])
        + ["--", working.path],
      outputURL: transaction.appendingPathComponent("create.log"), limit: 32 * 1024 * 1024,
      workingDirectory: inputs,
      progress: reporter.engine(
        phase: .compressing, from: 0, to: 0.9, totalBytes: bytes, totalFiles: files,
        outputURL: working))
    await reporter.report(
      phase: .verifying, fraction: 0.9, processedBytes: 0, totalBytes: bytes,
      totalFiles: files, outputURL: working)
    try await verify(
      working, passwordArguments: password.isEmpty ? [] : ["-p" + password], in: transaction,
      progress: reporter.engine(
        phase: .verifying, from: 0.9, to: 0.99, totalBytes: bytes, totalFiles: files,
        outputURL: working))
    _ = try await readArchive(working, password: password, in: transaction)
    try Task.checkCancellation()
    guard initialGeneration == generation else { throw ArchiveError.sessionExpired }
    await reporter.report(
      phase: .finalizing, fraction: 0.99, processedBytes: bytes, totalBytes: bytes,
      completedFiles: files, totalFiles: files, outputURL: working)
    try Task.checkCancellation()
    guard initialGeneration == generation else { throw ArchiveError.sessionExpired }
    let result = try ArchiveOutput.publish(working, proposed: proposedURL, isDirectory: false)
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
    let state = try checkedState(session)
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
          completedFiles: 0, totalFiles: 1, currentFile: entry.path, outputURL: url))
      verificationStart = 0.1
      descriptor = try await readArchive(source, password: password, in: transaction)
      guard descriptor.format == "tar" else { throw ArchiveError.invalidArchive }
    }
    var total: UInt64 = 0
    var normalized: [String: String] = [:]
    for entry in descriptor.entries {
      guard !entry.isSymbolicLink else { throw ArchiveError.unsupportedExtraction }
      let sum = total.addingReportingOverflow(entry.size)
      guard !sum.overflow, sum.partialValue <= maximumBytes else { throw ArchiveError.outputLimit }
      total = sum.partialValue
      let parts = entry.path.split(separator: "/")
      for index in 1...parts.count {
        let path = parts.prefix(index).joined(separator: "/")
        let key = path.precomposedStringWithCanonicalMapping.lowercased()
        if let existing = normalized[key], existing != path { throw ArchiveError.duplicatePath }
        normalized[key] = path
      }
    }
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
    var completedWeight = 0.0
    var completedBytes: UInt64 = 0
    var completedFiles = 0
    let totalWeight = descriptor.entries.filter { !$0.isDirectory }.reduce(0.0) {
      $0 + max(1, Double($1.size))
    }
    await reporter.report(
      phase: .extracting, fraction: extractionStart, processedBytes: 0,
      totalBytes: workload.bytes, completedFiles: 0, totalFiles: workload.files, outputURL: url)
    for entry in descriptor.entries {
      try Task.checkCancellation()
      let target = output.appendingPathComponent(entry.path)
      try FileManager.default.createDirectory(
        at: entry.isDirectory ? target : target.deletingLastPathComponent(),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      if !entry.isDirectory {
        let weight = max(1, Double(entry.size))
        let start = completedWeight
        await reporter.report(
          phase: .extracting,
          fraction: extractionStart + start / totalWeight * (0.99 - extractionStart),
          processedBytes: completedBytes, totalBytes: workload.bytes,
          completedFiles: completedFiles, totalFiles: workload.files, currentFile: entry.path)
        try await extractFile(
          entry, from: source, to: target, password: password,
          progress: reporter.engine(
            phase: .extracting,
            from: extractionStart + start / totalWeight * (0.99 - extractionStart),
            to: extractionStart + (start + weight) / totalWeight * (0.99 - extractionStart),
            totalBytes: workload.bytes, baseBytes: completedBytes, itemBytes: entry.size,
            completedFiles: completedFiles, totalFiles: workload.files, currentFile: entry.path))
        completedWeight += weight
        completedBytes += entry.size
        completedFiles += 1
        try Quarantine.copy(from: url, to: target)
      }
    }
    await reporter.report(
      phase: .finalizing, fraction: 0.99, processedBytes: workload.bytes,
      totalBytes: workload.bytes, completedFiles: workload.files, totalFiles: workload.files)
    // Атрибуты папок устанавливаются после записи дочерних файлов.
    for entry in descriptor.entries.sorted(by: { $0.path.count > $1.path.count }) {
      var attributes: [FileAttributeKey: Any] = [:]
      if let modified = entry.modifiedAt { attributes[.modificationDate] = modified }
      if let created = entry.createdAt { attributes[.creationDate] = created }
      if let mode = entry.permissions, let permissions = Self.permissions(from: mode) {
        attributes[.posixPermissions] = permissions
      }
      try FileManager.default.setAttributes(
        attributes, ofItemAtPath: output.appendingPathComponent(entry.path).path)
    }
    _ = try checkedState(session)
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
    _ = try checkedState(session)
  }

  /// Извлекает ровно одну запись через stdout и требует совпадения фактического и заявленного размера.
  private func extractFile(
    _ entry: ArchiveEntry, from archive: URL, to output: URL, password: String,
    progress: (@Sendable (Double) async -> Void)? = nil
  ) async throws {
    try await runner().run(
      arguments: [
        "x", "-so", "-spd", "-ssc", "-y", "-bso0", progress == nil ? "-bsp0" : "-bsp2",
        "-p" + password, "--", archive.path,
        entry.path,
      ],
      outputURL: output, limit: entry.size, progress: progress)
    guard try FileFingerprint(output).size == entry.size else {
      throw ArchiveError.extractionMismatch
    }
  }
}

extension ArchiveService {
  /// Исключает вложенные выбранные пути и последовательно экспортирует корни под свободными именами.
  public func exportSelection(
    _ paths: [String], from session: ArchiveSession, to directory: URL, password: String = ""
  ) async throws -> [URL] {
    let roots = try ArchiveSelection.topLevelPaths(paths, entries: session.entries)
    var results: [URL] = []
    for path in roots {
      let proposed = directory.appendingPathComponent(String(path.split(separator: "/").last!))
      results.append(
        try await exportItem(
          path, from: session, to: proposed, password: password, chooseUniqueName: true))
    }
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
    let state = try checkedState(session)
    guard !busy.contains(session.id), destination.isFileURL else {
      throw ArchiveError.invalidOperation
    }
    let entries = try ArchiveSelection.entries(for: path, in: state.descriptor.entries)
    let isDirectory = state.entries[path]?.isDirectory == true || state.entries[path] == nil
    guard destination.standardizedFileURL != state.url.standardizedFileURL else {
      throw ArchiveError.invalidOperation
    }
    busy.insert(session.id)
    defer { busy.remove(session.id) }
    let transaction = try workspace.transactionDirectory(nextTo: destination)
    defer { try? workspace.removeTransaction(transaction) }
    let output = transaction.appendingPathComponent("export")
    var total: UInt64 = 0
    var normalized: [String: String] = [:]
    for entry in entries {
      guard !entry.isSymbolicLink else { throw ArchiveError.unsupportedExtraction }
      let sum = total.addingReportingOverflow(entry.size)
      guard !sum.overflow, sum.partialValue <= maximumBytes else { throw ArchiveError.outputLimit }
      total = sum.partialValue
      let parts = entry.path.split(separator: "/")
      for index in 1...parts.count {
        let name = parts.prefix(index).joined(separator: "/")
        let key = name.precomposedStringWithCanonicalMapping.lowercased()
        if let previous = normalized[key], previous != name { throw ArchiveError.duplicatePath }
        normalized[key] = name
      }
    }
    let workload = try ArchiveWorkload(entries: entries)
    let manager = FileManager.default
    if isDirectory {
      try manager.createDirectory(
        at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    var completedWeight = 0.0
    var completedBytes: UInt64 = 0
    var completedFiles = 0
    let totalWeight = entries.filter { !$0.isDirectory }.reduce(0.0) {
      $0 + max(1, Double($1.size))
    }
    await reporter.report(
      phase: .extracting, fraction: 0, processedBytes: 0, totalBytes: workload.bytes,
      completedFiles: 0, totalFiles: workload.files)
    for entry in entries {
      let relative = entry.path == path ? "" : String(entry.path.dropFirst(path.count + 1))
      let target = relative.isEmpty ? output : output.appendingPathComponent(relative)
      if entry.isDirectory {
        try manager.createDirectory(
          at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      } else {
        try manager.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        let weight = max(1, Double(entry.size))
        let start = completedWeight
        await reporter.report(
          phase: .extracting, fraction: start / totalWeight * 0.99,
          processedBytes: completedBytes, totalBytes: workload.bytes,
          completedFiles: completedFiles, totalFiles: workload.files, currentFile: entry.path)
        try await extractFile(
          entry, from: state.url, to: target, password: password,
          progress: reporter.engine(
            phase: .extracting, from: start / totalWeight * 0.99,
            to: (start + weight) / totalWeight * 0.99, totalBytes: workload.bytes,
            baseBytes: completedBytes, itemBytes: entry.size, completedFiles: completedFiles,
            totalFiles: workload.files, currentFile: entry.path))
        completedWeight += weight
        completedBytes += entry.size
        completedFiles += 1
        try Quarantine.copy(from: state.url, to: target)
      }
    }
    for entry in entries.sorted(by: { $0.path.count > $1.path.count }) {
      let relative = entry.path == path ? "" : String(entry.path.dropFirst(path.count + 1))
      let target = relative.isEmpty ? output : output.appendingPathComponent(relative)
      var attributes: [FileAttributeKey: Any] = [:]
      if let date = entry.modifiedAt { attributes[.modificationDate] = date }
      if let date = entry.createdAt { attributes[.creationDate] = date }
      if let mode = entry.permissions, let value = Self.permissions(from: mode) {
        attributes[.posixPermissions] = value
      }
      try manager.setAttributes(attributes, ofItemAtPath: target.path)
    }
    try Quarantine.copy(from: state.url, to: output)
    try Task.checkCancellation()
    _ = try checkedState(session)
    await reporter.report(
      phase: .finalizing, fraction: 0.99, processedBytes: workload.bytes,
      totalBytes: workload.bytes, completedFiles: workload.files, totalFiles: workload.files)
    try Task.checkCancellation()
    _ = try checkedState(session)
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
}
