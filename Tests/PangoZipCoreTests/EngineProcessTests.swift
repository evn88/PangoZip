import XCTest

@testable import PangoZipCore

final class EngineProcessTests: XCTestCase, @unchecked Sendable {
  /// Проверяет остановку процесса движка после отмены задачи.
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

  /// Проверяет завершение процесса, превысившего заданный таймаут.
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

  /// Проверяет лимит вывода даже для процесса, завершившегося сразу.
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

  /// Проверяет раздельную передачу прогресса и двоичного вывода процесса.
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
        progress: { await samples.record($0.fraction) })
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

  /// Проверяет, что ошибка процесса не выдаётся за успешное завершение.
  func testFailureDoesNotReportCompletion() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try makeScript("printf '  35%%' >&2; exit 2", in: directory)
    let samples = EngineSamples()
    do {
      try await EngineProcess(executableURL: script, timeout: 2).run(
        arguments: [], outputURL: directory.appendingPathComponent("out"), limit: 100,
        progress: { await samples.record($0.fraction) })
      XCTFail("Expected error")
    } catch { XCTAssertEqual(error as? ArchiveError, .invalidArchive) }
    let values = await samples.values
    XCTAssertEqual(values, [0.35])
  }

  /// Превышение размера на диске останавливает batch до выхода процесса и публикации данных.
  func testExtractionManifestStopsOversizedDiskOutputWhileEngineIsRunning() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let contents = directory.appendingPathComponent("contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
    let script = try makeScript(
      "printf 'too long' > contents/file; exec /bin/sleep 10", in: directory)
    let manifest = try ArchiveExtractionManifest(
      entries: [ArchiveEntry(path: "file", size: 1)], maximumBytes: 1)
    let started = Date()
    do {
      try await EngineProcess(executableURL: script, timeout: 15).run(
        arguments: [], outputURL: directory.appendingPathComponent("out"), limit: 100,
        workingDirectory: directory,
        validateOutput: { try manifest.validate(contents, complete: false) })
      XCTFail("Expected disk output limit")
    } catch { XCTAssertEqual(error as? ArchiveError, .outputLimit) }
    XCTAssertLessThan(Date().timeIntervalSince(started), 3)
  }

  /// Без заданного предела процесс работает сколько нужно, а длинный журнал прогресса
  /// (мегабайты за часы работы) не считается превышением объёма вывода.
  func testLongProgressOutputIsNotLimitedAndThereIsNoDefaultTimeout() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // 40 000 перерисовок по 64 байта — больше прежнего предела в 1 МБ.
    let script = try makeScript(
      """
      i=0
      line='  7% 12 + some/long/file/name/that/pads/the/progress/record.bin'
      while [ $i -lt 40000 ]; do printf '%s\\b\\b' "$line" >&2; i=$((i+1)); done
      printf ' 99%% 13 + last.bin' >&2
      """, in: directory)
    let samples = EngineUpdates()
    try await EngineProcess(executableURL: script, timeout: nil).run(
      arguments: [], outputURL: directory.appendingPathComponent("out"), limit: 100,
      progress: { await samples.record($0) })
    let values = await samples.values
    XCTAssertEqual(
      values.first,
      EngineProgressUpdate(
        fraction: 0.07, files: 12, file: "some/long/file/name/that/pads/the/progress/record.bin"))
    XCTAssertTrue(
      values.contains(EngineProgressUpdate(fraction: 0.99, files: 13, file: "last.bin")))
    XCTAssertEqual(values.last, EngineProgressUpdate(fraction: 1))
  }

  /// Конвейер передаёт stdout первого этапа второму, а прогресс берёт у первого.
  func testPipelineStreamsFirstStageIntoSecondAndReportsFirstStageProgress() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try makeScript(
      """
      if [ "$1" = produce ]; then
        printf ' 50%% 1 + a.txt' >&2
        printf 'stream payload'
      else
        printf ' 80%%' >&2
        /bin/cat > "$2"
        printf 'log'
      fi
      """, in: directory)
    let samples = EngineUpdates()
    let received = directory.appendingPathComponent("received")
    let log = directory.appendingPathComponent("out")
    try await EngineProcess(executableURL: script, timeout: 15).run(
      stages: [
        EngineStage(arguments: ["produce"]),
        EngineStage(arguments: ["consume", received.path]),
      ], outputURL: log, limit: 100, progress: { await samples.record($0) })
    XCTAssertEqual(try Data(contentsOf: received), Data("stream payload".utf8))
    XCTAssertEqual(try Data(contentsOf: log), Data("log".utf8))
    let values = await samples.values
    XCTAssertEqual(values.map(\.fraction), [0.5, 1])
  }

  /// Сбой любого этапа конвейера — ошибка всей операции, даже если последний этап завершился успешно.
  func testPipelineFailsWhenFirstStageFails() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try makeScript(
      "if [ \"$1\" = produce ]; then exit 2; else /bin/cat > /dev/null; fi", in: directory)
    do {
      try await EngineProcess(executableURL: script, timeout: 15).run(
        stages: [EngineStage(arguments: ["produce"]), EngineStage(arguments: ["consume"])],
        outputURL: directory.appendingPathComponent("out"), limit: 100)
      XCTFail("Expected error")
    } catch { XCTAssertEqual(error as? ArchiveError, .invalidArchive) }
  }

  /// Нехватка места на диске отличается от повреждённого архива.
  func testDiskFullIsReportedSeparately() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try makeScript(
      "printf ' 10%% 1 + a\\b\\b\\nERROR: errno=28 : No space left on device\\n' >&2; exit 2",
      in: directory)
    do {
      try await EngineProcess(executableURL: script, timeout: 15).run(
        arguments: [], outputURL: directory.appendingPathComponent("out"), limit: 100)
      XCTFail("Expected error")
    } catch { XCTAssertEqual(error as? ArchiveError, .diskFull) }
  }

  /// Движок на паузе стоит, пока паузу не снимут, и затем завершается штатно.
  func testPauseStopsEngineUntilResumed() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try makeScript("/bin/sleep 0.1; printf 'done'", in: directory)
    let pause = EnginePause()
    pause.pause()
    var runner = EngineProcess(executableURL: script, timeout: 30)
    runner.pause = pause
    let output = directory.appendingPathComponent("out")
    let started = Date()
    let task = Task { try await runner.run(arguments: [], outputURL: output, limit: 100) }
    try await Task.sleep(for: .milliseconds(700))
    pause.resume()
    try await task.value
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.7)
    XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "done")
    XCTAssertGreaterThanOrEqual(pause.pausedTime(at: EnginePause.uptime), 0.6)
  }

  /// Отмена останавливает и движок, замерший на паузе.
  func testCancellationStopsPausedEngine() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try makeScript("exec /bin/sleep 10", in: directory)
    let pause = EnginePause()
    var runner = EngineProcess(executableURL: script, timeout: 120)
    runner.pause = pause
    let started = Date()
    let task = Task {
      try await runner.run(
        arguments: [], outputURL: directory.appendingPathComponent("out"), limit: 100)
    }
    try await Task.sleep(for: .milliseconds(100))
    pause.pause()
    try await Task.sleep(for: .milliseconds(200))
    task.cancel()
    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
  }

  /// Выделяет временный каталог для изолированного процесса движка.
  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Создаёт исполняемый скрипт, имитирующий заданный сценарий процесса.
  private func makeScript(_ body: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("fake-engine")
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }
}

private actor EngineUpdates {
  private(set) var values: [EngineProgressUpdate] = []
  /// Сохраняет обновление вместе со счётчиком файлов и именем.
  func record(_ value: EngineProgressUpdate) { values.append(value) }
}

private actor EngineSamples {
  private(set) var values: [Double] = []
  /// Сохраняет событие прогресса для проверки последовательности вызовов.
  func record(_ value: Double) { values.append(value) }
}
