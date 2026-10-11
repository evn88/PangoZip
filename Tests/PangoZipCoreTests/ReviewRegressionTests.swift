import XCTest

@testable import PangoZipCore

final class ReviewRegressionTests: XCTestCase, @unchecked Sendable {
  private let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
      "Resources/Engine/7zz")

  /// Особые имена сжатого TAR не должны превращать папку назначения в текущий или родительский каталог.
  func testCompressedTarDotNamesStayInsideChosenDirectory() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lzma"] {
      for stem in ["", ".", ".."] {
        XCTAssertEqual(
          FinderSelection.extractionName(for: root.appendingPathComponent(stem + suffix)), "Archive"
        )
      }
    }
    try runEngine(["a", "-ttar", "base.tar", "File.txt"], in: root)
    try runEngine(["a", "-tgzip", "base.tar.gz", "base.tar"], in: root)
    let chosen = root.appendingPathComponent("chosen")
    try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
    let service = ArchiveService(executableURL: engine)
    for name in [".tar.gz", "..tar.gz", "...tar.gz"] {
      let archive = root.appendingPathComponent(name)
      try FileManager.default.copyItem(at: root.appendingPathComponent("base.tar.gz"), to: archive)
      let output = try await service.extractArchive(archive, directory: chosen)
      XCTAssertEqual(
        output.deletingLastPathComponent().standardizedFileURL, chosen.standardizedFileURL)
      XCTAssertEqual(
        try Data(contentsOf: output.appendingPathComponent("File.txt")), Data("original".utf8))
    }
    await service.cleanup()
  }

  /// Новая правка не должна регистрироваться между снимком и завершением другой транзакции.
  func testEditingCannotRegisterWhileMutationIsUsingSessionSnapshot() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try runEngine(["a", "sample.zip", "File.txt"], in: root)
    let wrapper = try gatedEngine(in: root)
    let service = ArchiveService(executableURL: wrapper, timeout: 10)
    var session = try await service.open(root.appendingPathComponent("sample.zip"))
    let entry = try XCTUnwrap(session.entries.first { $0.path == "File.txt" })
    let originalSession = session
    let edit = Task { try await service.beginEditing(entry, in: originalSession) }
    defer {
      try? Data().write(to: root.appendingPathComponent("release-x"))
      try? Data().write(to: root.appendingPathComponent("release-a"))
      edit.cancel()
    }
    try await waitForFile(root.appendingPathComponent("ready-x"))
    let mutation = Task {
      try await service.add([root.appendingPathComponent("New.txt")], to: originalSession)
    }
    defer { mutation.cancel() }
    try await waitForFile(root.appendingPathComponent("ready-a"))
    try Data().write(to: root.appendingPathComponent("release-x"))
    do {
      _ = try await edit.value
      XCTFail("Editing must not register into the snapshot of a running mutation")
    } catch { XCTAssertEqual(error as? ArchiveError, .operationInProgress) }
    try Data().write(to: root.appendingPathComponent("release-a"))
    session = try await mutation.value
    let workingCopy = try await service.beginEditing(entry, in: session)
    try Data("edited".utf8).write(to: workingCopy.fileURL)
    session = try await service.save([workingCopy], in: session)
    let updated = try XCTUnwrap(session.entries.first { $0.path == "File.txt" })
    let output = try await service.materialize(updated, in: session)
    XCTAssertEqual(try Data(contentsOf: output), Data("edited".utf8))
    await service.cleanup()
  }

  /// Создаёт только собственные входные файлы, чтобы транзакции не затрагивали пользовательские архивы.
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: root.appendingPathComponent("File.txt"))
    try Data("new".utf8).write(to: root.appendingPathComponent("New.txt"))
    return root
  }

  /// Вызывает настоящий 7zz с массивом аргументов для подготовки воспроизводимого архива.
  private func runEngine(_ arguments: [String], in root: URL) throws {
    let process = Process()
    process.executableURL = engine
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }

  /// Приостанавливает два процесса в точных точках, чтобы тест не зависел от скорости копирования.
  private func gatedEngine(in root: URL) throws -> URL {
    let executable = root.appendingPathComponent("gated-engine")
    let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let script = """
      #!/bin/sh
      engine=\(quote(engine.path))
      gate=\(quote(root.path))
      if [ "$1" = x ]; then
        "$engine" "$@"
        result=$?
        touch "$gate/ready-x"
        until [ -f "$gate/release-x" ]; do sleep 0.01; done
        exit "$result"
      fi
      if [ "$1" = a ]; then
        touch "$gate/ready-a"
        until [ -f "$gate/release-a" ]; do sleep 0.01; done
      fi
      exec "$engine" "$@"
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
  }

  /// Ограничивает ожидание сигнала процесса, чтобы ошибка фикстуры не повесила тестовый запуск.
  private func waitForFile(_ url: URL) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw NSError(
        domain: "ReviewRegressionTests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Engine gate did not open"])
    }
  }
}
