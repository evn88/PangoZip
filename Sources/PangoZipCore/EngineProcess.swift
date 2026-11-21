import Darwin
import Foundation

/// Приоритет процесса движка. Долгие операции с полосой прогресса идут классом utility:
/// система отдаёт процессор и диск интерфейсу и активным программам в первую очередь.
enum EnginePriority: Sendable {
  /// Короткие запросы, которых пользователь ждёт прямо сейчас: список архива, предпросмотр.
  case interactive
  /// Сжатие, проверка и извлечение: могут занимать минуты и часы.
  case background

  var qualityOfService: QualityOfService { self == .interactive ? .userInitiated : .utility }
  var taskPriority: TaskPriority { self == .interactive ? .userInitiated : .utility }
}

/// Один процесс конвейера; stdout каждого этапа, кроме последнего, передаётся следующему в stdin.
struct EngineStage: Sendable {
  var arguments: [String]
  /// Пароль для stdin; допустим только у первого этапа.
  var input: Data?
  var workingDirectory: URL?
}

struct EngineProcess: Sendable {
  let executableURL: URL
  /// nil — без предела: длительность операции определяет объём данных, а не часы.
  let timeout: TimeInterval?
  var priority: EnginePriority = .interactive

  /// Передаёт прогресс асинхронно; отмена дожидается завершения процесса перед возвратом ошибки.
  func run(
    arguments: [String], input: Data? = nil, outputURL: URL, limit: UInt64,
    workingDirectory: URL? = nil, progress: (@Sendable (EngineProgressUpdate) async -> Void)? = nil,
    validateOutput: (@Sendable () throws -> Void)? = nil
  ) async throws {
    try await run(
      stages: [
        EngineStage(arguments: arguments, input: input, workingDirectory: workingDirectory)
      ], outputURL: outputURL, limit: limit, progress: progress, validateOutput: validateOutput)
  }

  /// Запускает конвейер; прогресс читается из stderr первого этапа, которому известен полный объём.
  func run(
    stages: [EngineStage], outputURL: URL, limit: UInt64,
    progress: (@Sendable (EngineProgressUpdate) async -> Void)? = nil,
    validateOutput: (@Sendable () throws -> Void)? = nil
  ) async throws {
    let (updates, continuation) = AsyncStream<EngineProgressUpdate>.makeStream(
      bufferingPolicy: .bufferingNewest(8))
    let relay: (@Sendable (EngineProgressUpdate) -> Void)?
    if progress != nil {
      relay = { @Sendable value in _ = continuation.yield(value) }
    } else {
      relay = nil
    }
    let job = Task.detached(priority: priority.taskPriority) {
      defer { continuation.finish() }
      try self.runBlocking(
        stages: stages, outputURL: outputURL, limit: limit, progress: relay,
        validateOutput: validateOutput)
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

  /// Запущенный этап и неблокирующий канал его stderr.
  private struct Running {
    let process: Process
    let errors: FileHandle
    var parser = EngineProgressParser()
    var drained = false
  }

  /// Запускает движок без оболочки и следит за отменой, объёмом вывода и прогрессом на одном потоке.
  private func runBlocking(
    stages: [EngineStage], outputURL: URL, limit: UInt64,
    progress: (@Sendable (EngineProgressUpdate) -> Void)?,
    validateOutput: (@Sendable () throws -> Void)?
  ) throws {
    try Task.checkCancellation()
    guard !stages.isEmpty, stages.dropFirst().allSatisfy({ $0.input == nil }) else {
      throw ArchiveError.invalidOperation
    }
    _ = FileManager.default.createFile(
      atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    var environment = ProcessInfo.processInfo.environment
    environment["LANG"] = "en_US.UTF-8"
    environment["LC_ALL"] = "en_US.UTF-8"
    var running: [Running] = []
    defer { for item in running { try? item.errors.close() } }
    do {
      // Process и waitUntilExit используют один поток/run loop; здесь нет async-приостановок.
      var upstream: Pipe?
      for (index, stage) in stages.enumerated() {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = stage.arguments
        process.currentDirectoryURL = stage.workingDirectory
        process.environment = environment
        process.qualityOfService = priority.qualityOfService
        if let upstream {
          process.standardInput = upstream
        } else if let input = stage.input {
          // Данные пишутся и канал закрывается до запуска: запись не блокируется и не получает
          // SIGPIPE, даже если движок завершится, не прочитав stdin.
          guard input.count <= EnginePassword.maximumInputBytes else {
            throw ArchiveError.invalidOperation
          }
          let pipe = Pipe()
          try pipe.fileHandleForWriting.write(contentsOf: input)
          try pipe.fileHandleForWriting.close()
          process.standardInput = pipe
        } else {
          process.standardInput = FileHandle.nullDevice
        }
        let downstream = index < stages.count - 1 ? Pipe() : nil
        process.standardOutput = downstream ?? output
        // stderr читается из канала по мере работы: строка прогресса за часы даёт мегабайты,
        // и файл с жёстким пределом обрывал бы длинные операции.
        let errors = Pipe()
        process.standardError = errors
        let consumed = upstream
        upstream = downstream
        defer {
          // Копии концов канала в этом процессе закрываются, иначе читатель не увидит конец данных.
          try? errors.fileHandleForWriting.close()
          try? consumed?.fileHandleForReading.close()
          try? downstream?.fileHandleForWriting.close()
        }
        try process.run()
        let descriptor = errors.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        running.append(Running(process: process, errors: errors.fileHandleForReading))
      }
      let deadline = timeout.map { Date().addingTimeInterval($0) }
      var nextValidation = Date.distantPast
      while running.contains(where: { $0.process.isRunning }) {
        try Task.checkCancellation()
        if let deadline, Date() >= deadline { throw ArchiveError.timedOut }
        guard try fileSize(outputURL) <= limit else { throw ArchiveError.outputLimit }
        if let validateOutput, Date() >= nextValidation {
          let started = Date()
          try validateOutput()
          // Обход большого дерева не должен отнимать у движка заметную долю времени.
          nextValidation = Date().addingTimeInterval(
            max(0.1, 20 * Date().timeIntervalSince(started)))
        }
        drain(&running, progress: progress)
        Thread.sleep(forTimeInterval: 0.03)
      }
      for item in running { item.process.waitUntilExit() }
      drain(&running, progress: progress, finishing: true)
      try Task.checkCancellation()
      try validateOutput?()
      guard try fileSize(outputURL) <= limit else { throw ArchiveError.outputLimit }
    } catch {
      for item in running { stop(item.process) }
      throw error
    }
    guard running.allSatisfy({ $0.process.terminationStatus == 0 }) else {
      let handle = try FileHandle(forReadingFrom: outputURL)
      defer { try? handle.close() }
      let outputData = try handle.read(upToCount: 65_536) ?? Data()
      let errorData = running.reduce(into: Data()) { $0.append(contentsOf: $1.parser.messages) }
      var message = String(decoding: errorData + outputData, as: UTF8.self).lowercased()
      // При вводе через stdin приглашение печатается всегда; ошибку пароля выдают другие строки.
      if stages[0].input != nil {
        message = message.replacingOccurrences(of: "enter password:", with: "")
      }
      // Слово password в пути или имени файла не должно превращать повреждение в запрос пароля.
      if ["wrong password", "enter password", "encrypted archive"].contains(where: message.contains)
      {
        throw ArchiveError.passwordRequired
      }
      if ["no space left on device", "not enough space on the disk"].contains(
        where: message.contains)
      {
        throw ArchiveError.diskFull
      }
      throw ArchiveError.invalidArchive
    }
    if let progress { progress(EngineProgressUpdate(fraction: 1)) }
  }

  /// Вычитывает накопившийся stderr всех этапов; прогресс публикует только первый.
  private func drain(
    _ running: inout [Running], progress: (@Sendable (EngineProgressUpdate) -> Void)?,
    finishing: Bool = false
  ) {
    var buffer = [UInt8](repeating: 0, count: 65_536)
    for index in running.indices where !running[index].drained {
      let descriptor = running[index].errors.fileDescriptor
      var updates: [EngineProgressUpdate] = []
      while true {
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
          updates += running[index].parser.consume(Data(buffer[0..<count]))
        } else if count == 0 {
          running[index].drained = true
          break
        } else if errno != EINTR {
          // EAGAIN: данных пока нет. После выхода процесса ждать их уже не от кого.
          break
        }
      }
      if finishing || running[index].drained { updates += running[index].parser.finish() }
      if index == 0, let progress { for update in updates { progress(update) } }
    }
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
