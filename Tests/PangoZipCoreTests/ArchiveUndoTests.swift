import Darwin
import XCTest

@testable import PangoZipCore

final class ArchiveUndoTests: XCTestCase, @unchecked Sendable {
  private let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Engine/7zz")

  /// Последняя из двух транзакций отменяется побайтно; более ранняя история не сохраняется.
  func testUndoRestoresExactlyPreviousMutationAndCanOnlyBeUsedOnce() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("sample.zip")
    let service = ArchiveService(executableURL: engine)
    var session = try await service.open(archive)
    let initialAvailability = try await service.canUndo(session)
    XCTAssertFalse(initialAvailability)
    session = try await service.add([root.appendingPathComponent("added.txt")], to: session)
    let previous = try Data(contentsOf: archive)
    session = try await service.delete(["original.txt"], from: session)
    let availability = try await service.canUndo(session)
    XCTAssertTrue(availability)
    session = try await service.undoLastChange(in: session)
    XCTAssertEqual(try Data(contentsOf: archive), previous)
    XCTAssertEqual(Set(session.entries.map(\.path)), ["original.txt", "added.txt"])
    let output = try await service.materialize(
      XCTUnwrap(session.entries.first { $0.path == "original.txt" }), in: session)
    XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "original")
    let finalAvailability = try await service.canUndo(session)
    XCTAssertFalse(finalAvailability)
    do {
      _ = try await service.undoLastChange(in: session)
      XCTFail("Expected no undo history")
    } catch { XCTAssertEqual(error as? ArchiveError, .invalidOperation) }
    session = try await service.add([root.appendingPathComponent("later.txt")], to: session)
    XCTAssertTrue(session.entries.contains { $0.path == "later.txt" })
    try await service.close(session)
  }

  /// Внешнее изменение даже с прежним mtime не перезаписывается резервной копией Undo.
  func testUndoRefusesExternalModificationAndCancellationKeepsHistory() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("sample.zip")
    let service = ArchiveService(executableURL: engine)
    var session = try await service.open(archive)
    session = try await service.add([root.appendingPathComponent("added.txt")], to: session)
    let current = try Data(contentsOf: archive)
    let currentSession = session
    let task = Task { try await service.undoLastChange(in: currentSession) }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    XCTAssertEqual(try Data(contentsOf: archive), current)
    let available = try await service.canUndo(session)
    XCTAssertTrue(available)
    let modified = try FileFingerprint(archive).modified
    var external = current
    external[external.count - 1] ^= 1
    try external.write(to: archive)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: archive.path)
    do {
      _ = try await service.undoLastChange(in: session)
      XCTFail("Expected external change")
    } catch { XCTAssertEqual(error as? ArchiveError, .archiveChanged) }
    XCTAssertEqual(try Data(contentsOf: archive), external)
    await service.cleanup()
  }

  /// Активная рабочая копия блокирует Undo, чтобы следующий autosave не затёр восстановленный архив.
  func testUndoBlocksActiveEditorsAndWorksAfterManualSave() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("sample.zip")
    let service = ArchiveService(executableURL: engine)
    var session = try await service.open(archive)
    let original = try Data(contentsOf: archive)
    let edit = try await service.beginEditing(XCTUnwrap(session.entries.first), in: session)
    try Data("changed".utf8).write(to: edit.fileURL)
    session = try await service.save([edit], in: session, retainingWorkingCopies: true)
    let current = try Data(contentsOf: archive)
    let available = try await service.canUndo(session)
    XCTAssertFalse(available)
    do {
      _ = try await service.undoLastChange(in: session)
      XCTFail("Expected active edit conflict")
    } catch { XCTAssertEqual(error as? ArchiveError, .activeEdits) }
    XCTAssertEqual(try Data(contentsOf: archive), current)
    try Data("changed again".utf8).write(to: edit.fileURL)
    session = try await service.save([edit], in: session)
    let latest = try await service.materialize(XCTUnwrap(session.entries.first), in: session)
    XCTAssertEqual(try String(contentsOf: latest, encoding: .utf8), "changed again")
    session = try await service.undoLastChange(in: session)
    XCTAssertEqual(try Data(contentsOf: archive), current)
    let output = try await service.materialize(XCTUnwrap(session.entries.first), in: session)
    XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "changed")
    XCTAssertNotEqual(try Data(contentsOf: archive), original)
    try await service.close(session)
    XCTAssertFalse(FileManager.default.fileExists(atPath: edit.fileURL.path))
  }

  /// Ошибка следующей мутации не уничтожает предыдущую историю отмены.
  func testFailedMutationPreservesUndoAndCloseRemovesHistoryFiles() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("sample.zip")
    let original = try Data(contentsOf: archive)
    let service = ArchiveService(executableURL: engine)
    var session = try await service.open(archive)
    let preview = try await service.materialize(XCTUnwrap(session.entries.first), in: session)
    let sessionDirectory = preview.deletingLastPathComponent().deletingLastPathComponent()
    session = try await service.add([root.appendingPathComponent("added.txt")], to: session)
    do {
      _ = try await service.delete(["missing"], from: session)
      XCTFail("Expected invalid operation")
    } catch { XCTAssertEqual(error as? ArchiveError, .invalidOperation) }
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: sessionDirectory.path).contains {
        $0.hasPrefix("undo-")
      })
    session = try await service.undoLastChange(in: session)
    XCTAssertEqual(try Data(contentsOf: archive), original)
    session = try await service.add([root.appendingPathComponent("added.txt")], to: session)
    try await service.close(session)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
        $0.hasPrefix(".zipevra-")
      })
  }

  /// Ошибочный пароль сохраняет Undo; успешное восстановление сохраняет исходное шифрование.
  func testEncryptedUndoKeepsHistoryAfterWrongPassword() async throws {
    for format in ["zip", "7z"] {
      let root = try fixture(format: format, password: "secret")
      defer { try? FileManager.default.removeItem(at: root) }
      let archive = root.appendingPathComponent("sample." + format)
      let original = try Data(contentsOf: archive)
      let service = ArchiveService(executableURL: engine)
      var session = try await service.open(archive, password: "secret")
      session = try await service.add(
        [root.appendingPathComponent("added.txt")], to: session, password: "secret")
      let current = try Data(contentsOf: archive)
      do {
        _ = try await service.undoLastChange(in: session, password: "wrong")
        XCTFail("Expected password failure")
      } catch { XCTAssertEqual(error as? ArchiveError, .passwordRequired) }
      XCTAssertEqual(try Data(contentsOf: archive), current)
      let available = try await service.canUndo(session)
      XCTAssertTrue(available)
      session = try await service.undoLastChange(in: session, password: "secret")
      XCTAssertEqual(try Data(contentsOf: archive), original)
      XCTAssertTrue(session.entries.filter { !$0.isDirectory }.allSatisfy(\.isEncrypted))
      session = try await service.add(
        [root.appendingPathComponent("later.txt")], to: session, password: "secret")
      XCTAssertTrue(session.entries.filter { !$0.isDirectory }.allSatisfy(\.isEncrypted))
      try await service.close(session)
    }
  }

  /// Изменение редактором во время согласования commit сохраняет новую рабочую копию и исходный архив.
  func testSaveRefusesEditorChangeWhileCommitWaitsForFilePresenter() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("sample.zip")
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    let original = try Data(contentsOf: archive)
    let edit = try await service.beginEditing(XCTUnwrap(session.entries.first), in: session)
    try Data("staged value".utf8).write(to: edit.fileURL)
    let relinquished = expectation(description: "Editor writes before coordinated replacement")
    let presenter = CommitEditingPresenter(archive: archive) {
      do {
        try Data("newer editor value".utf8).write(to: edit.fileURL, options: .atomic)
      } catch { XCTFail("Presenter could not edit working copy: \(error)") }
      relinquished.fulfill()
    }
    NSFileCoordinator.addFilePresenter(presenter)
    defer { NSFileCoordinator.removeFilePresenter(presenter) }
    do {
      _ = try await service.save([edit], in: session)
      XCTFail("Expected working-copy conflict at commit")
    } catch { XCTAssertEqual(error as? ArchiveError, .editedFileChanged) }
    await fulfillment(of: [relinquished], timeout: 2)
    XCTAssertEqual(try Data(contentsOf: archive), original)
    XCTAssertEqual(try String(contentsOf: edit.fileURL, encoding: .utf8), "newer editor value")
    let available = try await service.canUndo(session)
    XCTAssertFalse(available)
    NSFileCoordinator.removeFilePresenter(presenter)
    let saved = try await service.save([edit], in: session)
    let output = try await service.materialize(XCTUnwrap(saved.entries.first), in: saved)
    XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "newer editor value")
    try await service.close(saved)
  }

  /// Неизменившиеся данные переживают системное обновление ctime архива и приватного снимка Undo.
  func testUndoAcceptsMetadataTouchWithoutAcceptingChangedArchiveBytes() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("sample.zip")
    let original = try Data(contentsOf: archive)
    let service = ArchiveService(executableURL: engine)
    var session = try await service.open(archive)
    session = try await service.add([root.appendingPathComponent("added.txt")], to: session)
    try touchMetadata(archive)
    let available = try await service.canUndo(session)
    XCTAssertTrue(available)
    let preview = try await service.materialize(XCTUnwrap(session.entries.first), in: session)
    let directory = preview.deletingLastPathComponent().deletingLastPathComponent()
    let backup = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix("undo-") })
    try touchMetadata(backup)
    session = try await service.undoLastChange(in: session)
    XCTAssertEqual(try Data(contentsOf: archive), original)
    session = try await service.add([root.appendingPathComponent("added.txt")], to: session)
    let modified = try FileFingerprint(archive).modified
    var changed = try Data(contentsOf: archive)
    changed[changed.count - 1] ^= 1
    try changed.write(to: archive)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: archive.path)
    do {
      _ = try await service.undoLastChange(in: session)
      XCTFail("Expected changed data conflict")
    } catch { XCTAssertEqual(error as? ArchiveError, .archiveChanged) }
    XCTAssertEqual(try Data(contentsOf: archive), changed)
    await service.cleanup()
  }

  /// Подмена снимка Undo с прежними размером и mtime не может перезаписать текущий архив.
  func testUndoRejectsChangedBackupBytesWithRestoredTimestamp() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("sample.zip")
    let service = ArchiveService(executableURL: engine)
    var session = try await service.open(archive)
    session = try await service.add([root.appendingPathComponent("added.txt")], to: session)
    let current = try Data(contentsOf: archive)
    let preview = try await service.materialize(XCTUnwrap(session.entries.first), in: session)
    let directory = preview.deletingLastPathComponent().deletingLastPathComponent()
    let backup = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix("undo-") })
    let modified = try FileFingerprint(backup).modified
    var changed = try Data(contentsOf: backup)
    changed[changed.count - 1] ^= 1
    try changed.write(to: backup)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: backup.path)
    do {
      _ = try await service.undoLastChange(in: session)
      XCTFail("Expected changed backup conflict")
    } catch { XCTAssertEqual(error as? ArchiveError, .archiveChanged) }
    XCTAssertEqual(try Data(contentsOf: archive), current)
    await service.cleanup()
  }

  /// Повторное применение прежних прав меняет только ctime, как отложенное системное касание копии.
  private func touchMetadata(_ url: URL) throws {
    let before = try FileFingerprint(url)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
      as! NSNumber
    guard chmod(url.path, mode_t(permissions.uint16Value)) == 0 else { throw POSIXError(.EIO) }
    let after = try FileFingerprint(url)
    XCTAssertEqual(before.inode, after.inode)
    XCTAssertEqual(before.size, after.size)
    XCTAssertEqual(before.modified, after.modified)
    XCTAssertNotEqual(before, after)
  }

  /// Создаёт архив с одним файлом и исходники двух независимых добавлений.
  private func fixture(format: String = "zip", password: String = "") throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (name, value) in [
      ("original.txt", "original"), ("added.txt", "added"), ("later.txt", "later"),
    ] {
      try Data(value.utf8).write(to: root.appendingPathComponent(name))
    }
    let process = Process()
    process.executableURL = engine
    process.currentDirectoryURL = root
    process.arguments =
      ["a"]
      + (password.isEmpty ? [] : ["-p" + password, format == "7z" ? "-mhe=on" : "-mem=AES256"])
      + ["sample." + format, "original.txt"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return root
  }
}

/// Имитирует внешнего редактора в точной точке согласования, без задержек и больших архивов.
private final class CommitEditingPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue = OperationQueue()
  private let onWrite: @Sendable () -> Void

  /// Наблюдение за архивом не мешает подготовке его приватных копий.
  init(archive: URL, onWrite: @escaping @Sendable () -> Void) {
    presentedItemURL = archive
    self.onWrite = onWrite
    super.init()
    presentedItemOperationQueue.maxConcurrentOperationCount = 1
  }

  /// Записывает новую версию до разрешения coordinated accessor продолжить commit.
  func relinquishPresentedItem(
    toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void
  ) {
    onWrite()
    writer(nil)
  }
}
