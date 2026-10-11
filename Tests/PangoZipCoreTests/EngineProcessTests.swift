import XCTest

@testable import PangoZipCore

final class EngineProcessTests: XCTestCase, @unchecked Sendable {
  func testCancellationStopsRunningEnginePromptly() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try makeScript("exec /bin/sleep 10", in: directory)
    let runner = EngineProcess(executableURL: script, timeout: 120)
    let started = Date()
    let task = Task {
      try await runner.run(
        arguments: [], outputURL: directory.appendingPathComponent("out"), limit: 100)
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
  }

  func testTimeoutStopsRunningEngine() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try makeScript("exec /bin/sleep 10", in: directory)
    let runner = EngineProcess(executableURL: script, timeout: 0.05)
    do {
      try await runner.run(
        arguments: [], outputURL: directory.appendingPathComponent("out"), limit: 100)
      XCTFail("Expected timeout")
    } catch { XCTAssertEqual(error as? ArchiveError, .timedOut) }
  }

  func testChecksOutputLimitEvenWhenEngineExitsImmediately() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try makeScript("printf 'too long'", in: directory)
    let runner = EngineProcess(executableURL: script, timeout: 2)
    do {
      try await runner.run(
        arguments: [], outputURL: directory.appendingPathComponent("out"), limit: 2)
      XCTFail("Expected output limit")
    } catch { XCTAssertEqual(error as? ArchiveError, .outputLimit) }
  }

  func testStreamsProgressBeforeProcessExitsWithoutMixingItIntoBinaryOutput() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try makeScript(
      "printf 'payload'; printf '  12%%' >&2; exec /bin/sleep 10", in: directory)
    let samples = EngineSamples()
    let runner = EngineProcess(executableURL: script, timeout: 15)
    let output = directory.appendingPathComponent("out")
    let task = Task {
      try await runner.run(
        arguments: [], outputURL: output, limit: 100,
        progress: { await samples.record($0) })
    }
    let deadline = Date().addingTimeInterval(3)
    while await samples.values.isEmpty, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let beforeCancellation = await samples.values
    task.cancel()
    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    XCTAssertEqual(beforeCancellation, [0.12])
    XCTAssertEqual(try Data(contentsOf: output), Data("payload".utf8))
    let finalValues = await samples.values
    XCTAssertFalse(finalValues.contains(1))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: output.appendingPathExtension("stderr").path))
  }

  func testFailureDoesNotReportCompletion() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try makeScript("printf '  35%%' >&2; exit 2", in: directory)
    let samples = EngineSamples()
    do {
      try await EngineProcess(executableURL: script, timeout: 2).run(
        arguments: [], outputURL: directory.appendingPathComponent("out"), limit: 100,
        progress: { await samples.record($0) })
      XCTFail("Expected error")
    } catch { XCTAssertEqual(error as? ArchiveError, .invalidArchive) }
    let values = await samples.values
    XCTAssertEqual(values, [0.35])
  }

  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeScript(_ body: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("fake-engine")
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }
}

private actor EngineSamples {
  private(set) var values: [Double] = []
  func record(_ value: Double) { values.append(value) }
}
