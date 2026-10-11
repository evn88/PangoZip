import Darwin
import Foundation

struct EngineProcess: Sendable {
  let executableURL: URL
  let timeout: TimeInterval

  func run(arguments: [String], outputURL: URL, limit: UInt64, workingDirectory: URL? = nil)
    async throws
  {
    let job = Task.detached(priority: .userInitiated) {
      try self.runBlocking(
        arguments: arguments, outputURL: outputURL, limit: limit, workingDirectory: workingDirectory
      )
    }
    try await withTaskCancellationHandler {
      try await job.value
      try Task.checkCancellation()
    } onCancel: {
      job.cancel()
    }
  }

  private func runBlocking(
    arguments: [String], outputURL: URL, limit: UInt64, workingDirectory: URL?
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
        Thread.sleep(forTimeInterval: 0.02)
      }
      process.waitUntilExit()
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
  }

  private func fileSize(_ url: URL) throws -> UInt64 {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
      ?? 0
  }

  private func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(0.5)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
}
