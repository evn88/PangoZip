import XCTest

@testable import PangoZipCore

final class EnginePasswordTests: XCTestCase, @unchecked Sendable {
  /// Пароль 7z с краевыми пробелами, табуляцией и не-ASCII символами.
  private let unicodeSecret = "  Пароль\tс пробелами 密码 "
  /// 7zz принимает для ZIP только печатные ASCII-символы, поэтому проверяются краевые пробелы.
  private let asciiSecret = "  Pass word with spaces "

  private var engine: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Resources/Engine/7zz")
  }

  /// Проверяет, что непустой пароль не попадает в аргументы и уходит в stdin нужное число раз.
  func testBuildsArgumentsWithoutSecret() throws {
    let reading = try EnginePassword.reading("secret")
    XCTAssertEqual(reading.arguments, [])
    XCTAssertEqual(
      reading.input,
      Data(String(repeating: "secret\n", count: EnginePassword.repeatedLines).utf8))
    let writing = try EnginePassword.writing("secret")
    XCTAssertEqual(writing.arguments, ["-p"])
    XCTAssertEqual(writing.input, reading.input)
    // Пустой пароль при чтении явно задаётся `-p`, чтобы движок не ждал ввода.
    XCTAssertEqual(try EnginePassword.reading(""), EnginePassword(arguments: ["-p"], input: nil))
    XCTAssertEqual(try EnginePassword.writing(""), .none)
  }

  /// Отклоняет пароли, которые нельзя передать одной строкой или которые не помещаются в канал.
  func testRejectsMultilineAndOversizedPasswords() {
    for password in ["a\nb", "a\rb", "a\r\nb", String(repeating: "x", count: 8_192)] {
      XCTAssertThrowsError(try EnginePassword.reading(password))
      XCTAssertThrowsError(try EnginePassword.writing(password))
    }
  }

  /// Проверяет доставку stdin процессу и отсутствие сбоя, если процесс его не читает.
  func testEngineProcessDeliversInput() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let echo = try makeScript("exec /bin/cat", name: "echo", in: directory)
    let output = directory.appendingPathComponent("out")
    try await EngineProcess(executableURL: echo, timeout: 5).run(
      arguments: [], input: Data("pw\n".utf8), outputURL: output, limit: 100)
    XCTAssertEqual(try Data(contentsOf: output), Data("pw\n".utf8))
    let quiet = try makeScript("exit 0", name: "quiet", in: directory)
    try await EngineProcess(executableURL: quiet, timeout: 5).run(
      arguments: [], input: Data(repeating: 0x61, count: EnginePassword.maximumInputBytes),
      outputURL: directory.appendingPathComponent("quiet.out"), limit: 100)
  }

  /// Проходит полный цикл зашифрованного 7z и следит, что пароль ни разу не попал в argv.
  func testEncrypted7zLifecycleKeepsPasswordOutOfArguments() async throws {
    try await assertLifecycle(format: "7z", secret: unicodeSecret)
  }

  /// Тот же цикл для ZIP с AES-256.
  func testEncryptedZipLifecycleKeepsPasswordOutOfArguments() async throws {
    try await assertLifecycle(format: "zip", secret: asciiSecret)
  }

  private func assertLifecycle(format: String, secret: String) async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("arguments.log")
    let wrapper = try makeScript(
      "for argument in \"$@\"; do printf '%s\\n' \"$argument\" >> '\(log.path)'; done\n"
        + "exec '\(engine.path)' \"$@\"",
      name: "logging-7zz", in: directory)
    let source = directory.appendingPathComponent("Input")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("Привет".utf8).write(to: source.appendingPathComponent("note.txt"))
    let extra = directory.appendingPathComponent("extra.txt")
    try Data("extra".utf8).write(to: extra)
    let service = ArchiveService(executableURL: wrapper)

    let archive = try await service.createArchive(
      from: [source], proposedURL: directory.appendingPathComponent("secret." + format),
      format: format, password: secret)
    if format == "7z" {
      await expect(.passwordRequired) { _ = try await service.open(archive) }
    }
    await expect(.passwordRequired) {
      _ = try await service.open(archive, password: "wrong")
      try await service.testArchive(archive, password: "wrong")
    }
    var session = try await service.open(archive, password: secret)
    let note = try XCTUnwrap(session.entries.first { $0.path == "Input/note.txt" })
    let preview = try await service.materialize(note, in: session, password: secret)
    XCTAssertEqual(try String(contentsOf: preview, encoding: .utf8), "Привет")
    // Обновление зашифрованного архива запрашивает пароль у движка дважды.
    session = try await service.add([extra], to: session, password: secret)
    XCTAssertNotNil(session.entries.first { $0.path == "extra.txt" })
    session = try await service.delete(["extra.txt"], from: session, password: secret)
    XCTAssertNil(session.entries.first { $0.path == "extra.txt" })
    try await service.close(session)
    try await service.testArchive(archive, password: secret)
    let output = try await service.extractArchive(
      archive, password: secret, directory: directory)
    XCTAssertEqual(
      try String(contentsOf: output.appendingPathComponent("Input/note.txt"), encoding: .utf8),
      "Привет")
    // Повторное открытие с паролем из командной строки подтверждает совместимость шифрования.
    let check = try await ArchiveService(executableURL: engine).open(archive, password: secret)
    XCTAssertTrue(check.entries.contains { $0.path == "Input/note.txt" })
    await service.cleanup()

    let arguments = try String(contentsOf: log, encoding: .utf8)
    XCTAssertTrue(arguments.contains("\n-p\n"), "Запись должна запрашивать пароль через stdin")
    XCTAssertFalse(arguments.contains(secret), "Пароль не должен попадать в аргументы 7zz")
    XCTAssertFalse(arguments.contains(secret.trimmingCharacters(in: .whitespaces)))
    XCTAssertFalse(arguments.contains("wrong"))
  }

  private func expect(_ expected: ArchiveError, operation: () async throws -> Void) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)")
    } catch {
      XCTAssertEqual(error as? ArchiveError, expected)
    }
  }

  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Создаёт исполняемый shell-скрипт только для тестовой обёртки движка.
  private func makeScript(_ body: String, name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }
}
