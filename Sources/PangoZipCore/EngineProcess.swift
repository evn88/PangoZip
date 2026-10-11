import Darwin
import Foundation

struct EngineProcess: Sendable {
  let executableURL: URL
  let timeout: TimeInterval

  /// Передаёт прогресс асинхронно; отмена дожидается завершения процесса перед возвратом ошибки.
  func run(
    arguments: [String], outputURL: URL, limit: UInt64, workingDirectory: URL? = nil,
    progress: (@Sendable (Double) async -> Void)? = nil
  ) async throws {
    let (updates, continuation) = AsyncStream<Double>.makeStream(
      bufferingPolicy: .bufferingNewest(8))
    let relay: (@Sendable (Double) -> Void)?
    if progress != nil {
      relay = { @Sendable value in _ = continuation.yield(value) }
    } else {
      relay = nil
    }
    let job = Task.detached(priority: .userInitiated) {
      defer { continuation.finish() }
      try self.runBlocking(
        arguments: arguments, outputURL: outputURL, limit: limit,
        workingDirectory: workingDirectory, progress: relay)
    }
    try await withTaskCancellationHandler {
      for await value in updates {
        if !Task.isCancelled { await progress?(value) }
      }
      // Отмена ожидает остановки процесса и закрытия файлов перед очисткой сеанса.
      try await job.value
      try Task.checkCancellation()
    } onCancel: {
      job.cancel()
    }
  }

  /// Запускает движок без оболочки и ограничивает время, stdout и stderr на одном потоке.
  private func runBlocking(
    arguments: [String], outputURL: URL, limit: UInt64, workingDirectory: URL?,
    progress: (@Sendable (Double) -> Void)?
  ) throws {
    try Task.checkCancellation()
    let manager = FileManager.default
    let errorsURL = outputURL.appendingPathExtension("stderr")
    _ = manager.createFile(
      atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    _ = manager.createFile(
      atPath: errorsURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let output = try FileHandle(forWritingTo: outputURL)
    let errors = try FileHandle(forWritingTo: errorsURL)
    defer {
      try? output.close()
      try? errors.close()
      try? manager.removeItem(at: errorsURL)
    }
    let progressReader = try FileHandle(forReadingFrom: errorsURL)
    defer { try? progressReader.close() }
    var parser = EngineProgressParser()
    // Process и waitUntilExit используют один поток/run loop; здесь нет async-приостановок.
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    var environment = ProcessInfo.processInfo.environment
    environment["LANG"] = "en_US.UTF-8"
    environment["LC_ALL"] = "en_US.UTF-8"
    process.environment = environment
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    do {
      while process.isRunning {
        try Task.checkCancellation()
        guard Date() < deadline else { throw ArchiveError.timedOut }
        guard try fileSize(outputURL) <= limit, try fileSize(errorsURL) <= 1_048_576 else {
          throw ArchiveError.outputLimit
        }
        if let progress {
          let data = try progressReader.read(upToCount: 65_536) ?? Data()
          for fraction in parser.consume(data) { progress(fraction) }
        }
        Thread.sleep(forTimeInterval: 0.02)
      }
      process.waitUntilExit()
      if let progress {
        while let data = try progressReader.read(upToCount: 65_536), !data.isEmpty {
          for fraction in parser.consume(data) { progress(fraction) }
        }
      }
      try Task.checkCancellation()
      guard try fileSize(outputURL) <= limit, try fileSize(errorsURL) <= 1_048_576 else {
        throw ArchiveError.outputLimit
      }
    } catch {
      stop(process)
      throw error
    }
    guard process.terminationStatus == 0 else {
      let errorData = try Data(contentsOf: errorsURL)
      let handle = try FileHandle(forReadingFrom: outputURL)
      defer { try? handle.close() }
      let outputData = try handle.read(upToCount: 65_536) ?? Data()
      let message = String(decoding: errorData + outputData, as: UTF8.self).lowercased()
      if message.contains("password") || message.contains("encrypted archive") {
        throw ArchiveError.passwordRequired
      }
      throw ArchiveError.invalidArchive
    }
    if let progress { progress(1) }
  }

  /// Читает размер файла для контроля объёма вывода; отсутствующий размер считает нулевым.
  private func fileSize(_ url: URL) throws -> UInt64 {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
      ?? 0
  }

  /// Даёт процессу завершиться после SIGTERM, затем принудительно останавливает и ожидает выход.
  private func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(0.5)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
}
