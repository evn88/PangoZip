import XCTest

@testable import PangoZipCore

final class ArchiveEditingTests: XCTestCase, @unchecked Sendable {
  let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
      "Resources/Engine/7zz")

  /// Проверяет сохранение изменений и удаление только выбранного каталога.
  func testAddsNestedFileDeletesFolderAndSavesEditedContents() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("sample.zip")
    try run(["a", archive.path, "docs", "keep.txt"], in: root)
    let service = ArchiveService(executableURL: engine)
    var session = try await service.open(archive)
    XCTAssertEqual(session.format, "zip")
    XCTAssertTrue(session.canModify)
    let addition = root.appendingPathComponent("new*.txt")
    try Data("new content".utf8).write(to: addition)
    session = try await service.add([addition], to: session, directory: "docs")
    let added = try XCTUnwrap(session.entries.first { $0.path == "docs/new*.txt" })
    let edited = try await service.beginEditing(added, in: session)
    let preview = try await service.materialize(added, in: session)
    XCTAssertNotEqual(edited.fileURL, preview)
    try Data("edited content with old timestamp".utf8).write(to: edited.fileURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: edited.fileURL.path)
    session = try await service.save([edited], in: session)
    let saved = try XCTUnwrap(session.entries.first { $0.path == "docs/new*.txt" })
    let output = try await service.materialize(saved, in: session)
    XCTAssertEqual(
      try String(contentsOf: output, encoding: .utf8), "edited content with old timestamp")
    XCTAssertFalse(FileManager.default.fileExists(atPath: edited.fileURL.path))
    session = try await service.delete(["docs"], from: session)
    XCTAssertEqual(session.entries.map(\.path), ["keep.txt"])
    try await service.close(session)
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    await service.cleanup()
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
        $0.hasPrefix(".zipevra-") || $0.hasPrefix(".pangozip-")
      }, [])
  }

  /// Проверяет очистку временных копий при закрытии архива.
  func testClosingArchiveRemovesPreviewAndEditingCopies() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("sample.zip")
    try run(["a", archive.path, "keep.txt"], in: root)
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    let entry = try XCTUnwrap(session.entries.first)
    let file = try await service.materialize(entry, in: session)
    let edit = try await service.beginEditing(entry, in: session)
    try await service.close(session)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: edit.fileURL.path))
    await service.cleanup()
  }

  /// Проверяет изменение поддерживаемых форматов с сохранением остальных записей.
  func testMutates7zAndTarWithoutLosingUnrelatedFiles() async throws {
    for format in ["7z", "tar"] {
      let root = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let archive = root.appendingPathComponent("sample." + format)
      try run(["a", archive.path, "keep.txt"], in: root)
      let service = ArchiveService(executableURL: engine)
      var session = try await service.open(archive)
      XCTAssertTrue(session.canModify)
      XCTAssertEqual(session.format, format)
      session = try await service.add([root.appendingPathComponent("docs")], to: session)
      XCTAssertTrue(session.entries.contains { $0.path == "docs/original.txt" })
      let entry = try XCTUnwrap(session.entries.first { $0.path == "docs/original.txt" })
      let edit = try await service.beginEditing(entry, in: session)
      try Data("changed".utf8).write(to: edit.fileURL)
      session = try await service.save([edit], in: session)
      let result = try await service.materialize(
        XCTUnwrap(session.entries.first { $0.path == entry.path }), in: session)
      XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "changed")
      session = try await service.delete(["docs"], from: session)
      XCTAssertEqual(session.entries.map(\.path), ["keep.txt"])
      await service.cleanup()
    }
  }

  /// Проверяет сохранение шифрования при добавлении, сохранении и удалении.
  func testEncryptedZipAnd7zKeepEncryptionAcrossAddSaveAndDelete() async throws {
    for format in ["zip", "7z"] {
      let root = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let archive = root.appendingPathComponent("secret." + format)
      var args = ["a", "-psecret"]
      if format == "7z" { args.append("-mhe=on") }
      try run(args + [archive.path, "keep.txt"], in: root)
      let service = ArchiveService(executableURL: engine)
      var session = try await service.open(archive, password: "secret")
      let original = try Data(contentsOf: archive)
      await expect(.passwordRequired) {
        _ = try await service.add([root.appendingPathComponent("docs")], to: session)
      }
      await expect(.passwordRequired) {
        _ = try await service.add(
          [root.appendingPathComponent("docs")], to: session, password: "wrong")
      }
      XCTAssertEqual(try Data(contentsOf: archive), original)
      session = try await service.add(
        [root.appendingPathComponent("docs")], to: session, password: "secret")
      XCTAssertTrue(session.entries.filter { !$0.isDirectory }.allSatisfy(\.isEncrypted))
      let entry = try XCTUnwrap(session.entries.first { $0.path == "keep.txt" })
      let edit = try await service.beginEditing(entry, in: session, password: "secret")
      try Data("secret changed".utf8).write(to: edit.fileURL)
      session = try await service.save([edit], in: session, password: "secret")
      session = try await service.delete(["docs"], from: session, password: "secret")
      XCTAssertTrue(session.entries.filter { !$0.isDirectory }.allSatisfy(\.isEncrypted))
      let file = try await service.materialize(
        XCTUnwrap(session.entries.first), in: session, password: "secret")
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "secret changed")
      if format == "7z" { await expect(.passwordRequired) { _ = try await service.open(archive) } }
      await service.cleanup()
    }
  }

  /// Проверяет атомарность изменений при ошибке, отмене и конфликте исходного файла.
  func testFailureCancellationAndConflictDoNotChangeOriginalArchive() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("sample.zip")
    try run(["a", archive.path, "keep.txt"], in: root)
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    let original = try Data(contentsOf: archive)
    await expect(.duplicatePath) {
      _ = try await service.add(
        [root.appendingPathComponent("keep.txt"), root.appendingPathComponent("keep.txt")],
        to: session)
    }
    XCTAssertEqual(try Data(contentsOf: archive), original)
    let task = Task { try await service.add([root.appendingPathComponent("docs")], to: session) }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    XCTAssertEqual(try Data(contentsOf: archive), original)
    let stamp =
      try FileManager.default.attributesOfItem(atPath: archive.path)[.modificationDate] as! Date
    var external = original
    external[external.count - 1] ^= 1
    try external.write(to: archive)
    try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: archive.path)
    await expect(.archiveChanged) { _ = try await service.delete(["keep.txt"], from: session) }
    XCTAssertEqual(try Data(contentsOf: archive), external)
    await service.cleanup()
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
        $0.hasPrefix(".zipevra-") || $0.hasPrefix(".pangozip-")
      }.isEmpty)
  }

  /// Проверяет режим чтения неподдерживаемого формата и буквальное совпадение имени.
  func testUnsupportedFormatIsReadOnlyAndLiteralWildcardDeleteIsExact() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let compressed = root.appendingPathComponent("sample.gz")
    try run(["a", compressed.path, "keep.txt"], in: root)
    let service = ArchiveService(executableURL: engine)
    let readonly = try await service.open(compressed)
    XCTAssertFalse(readonly.canModify)
    await expect(.readOnlyArchive) {
      _ = try await service.add([root.appendingPathComponent("docs")], to: readonly)
    }
    try Data("star".utf8).write(to: root.appendingPathComponent("a*.txt"))
    try Data("other".utf8).write(to: root.appendingPathComponent("abc.txt"))
    let archive = root.appendingPathComponent("literal.zip")
    try run(["a", "-spd", archive.path, "a*.txt", "abc.txt"], in: root)
    var session = try await service.open(archive)
    session = try await service.delete(["a*.txt"], from: session)
    XCTAssertEqual(session.entries.map(\.path), ["abc.txt"])
    await service.cleanup()
  }

  /// Проверяет изоляцию временных данных сессий и защиту активного редактирования.
  func testClosingOneSessionDoesNotRemoveAnotherAndActiveEditsPreventDeletion() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("sample.zip")
    try run(["a", archive.path, "keep.txt"], in: root)
    let service = ArchiveService(executableURL: engine)
    let first = try await service.open(archive)
    let second = try await service.open(archive)
    let firstFile = try await service.materialize(XCTUnwrap(first.entries.first), in: first)
    let secondFile = try await service.materialize(XCTUnwrap(second.entries.first), in: second)
    _ = try await service.beginEditing(XCTUnwrap(first.entries.first), in: first)
    await expect(.activeEdits) { _ = try await service.delete(["keep.txt"], from: first) }
    try await service.close(first)
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path))
    await service.cleanup()
    XCTAssertFalse(FileManager.default.fileExists(atPath: secondFile.path))
  }

  /// Проверяет наследование политики шифрования пустого архива.
  func testEmptyEncryptedZipKeepsItsEncryptionPolicyWhenNewFilesAreAdded() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("secret.zip")
    try run(["a", "-psecret", "-mem=AES256", archive.path, "keep.txt"], in: root)
    let service = ArchiveService(executableURL: engine)
    var session = try await service.open(archive, password: "secret")
    session = try await service.delete(["keep.txt"], from: session, password: "secret")
    XCTAssertTrue(session.entries.isEmpty)
    session = try await service.add(
      [root.appendingPathComponent("docs")], to: session, password: "secret")
    let entry = try XCTUnwrap(session.entries.first { !$0.isDirectory })
    XCTAssertTrue(entry.isEncrypted)
    XCTAssertTrue(entry.method?.contains("AES-256") == true)
    await expect(.passwordRequired) { _ = try await service.materialize(entry, in: session) }
    let file = try await service.materialize(entry, in: session, password: "secret")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    await service.cleanup()
  }

  /// Проверяет ожидаемый отказ операции редактирования архива.
  private func expect(_ expected: ArchiveError, operation: () async throws -> Void) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)")
    } catch { XCTAssertEqual(error as? ArchiveError, expected) }
  }

  /// Создаёт временные исходники для транзакционных сценариев редактирования.
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try Data("original".utf8).write(to: root.appendingPathComponent("docs/original.txt"))
    try Data("keep".utf8).write(to: root.appendingPathComponent("keep.txt"))
    return root
  }

  /// Запускает 7zz для подготовки фикстуры и проверяет код завершения.
  private func run(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = engine
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }
}
