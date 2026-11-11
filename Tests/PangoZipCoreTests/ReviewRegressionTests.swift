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

  /// Потоки без имени в списке 7zz открываются и распаковываются как обычный сжатый TAR.
  func testNamelessCompressedStreamsOpenAndExtract() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try runEngine(["a", "-ttar", "base.tar", "File.txt"], in: root)
    try runEngine(["a", "-txz", "base.tar.xz", "base.tar"], in: root)
    try FileManager.default.copyItem(
      at: root.appendingPathComponent("base.tar.xz"), to: root.appendingPathComponent("short.txz"))
    let service = ArchiveService(executableURL: engine)
    for name in ["base.tar.xz", "short.txz"] {
      let archive = root.appendingPathComponent(name)
      let session = try await service.open(archive)
      XCTAssertEqual(session.entries.map(\.path), [name == "short.txz" ? "short.tar" : "base.tar"])
      try await service.close(session)
      let output = try await service.extractArchive(archive)
      XCTAssertEqual(
        try Data(contentsOf: output.appendingPathComponent("File.txt")), Data("original".utf8))
    }
    await service.cleanup()
  }

  /// bzip2 и zstd не хранят исходный размер: архив всё равно открывается и распаковывается.
  func testStreamsWithoutStoredSizeOpenAndExtract() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try runEngine(["a", "-ttar", "base.tar", "File.txt"], in: root)
    try runEngine(["a", "-tbzip2", "base.tar.bz2", "base.tar"], in: root)
    try FileManager.default.copyItem(
      at: root.appendingPathComponent("base.tar.bz2"), to: root.appendingPathComponent("short.tbz2")
    )
    // 7zz не создаёт zstd, поэтому образец собирает системный bsdtar.
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.currentDirectoryURL = root
    tar.arguments = ["--zstd", "-cf", "base.tar.zst", "File.txt"]
    try tar.run()
    tar.waitUntilExit()
    XCTAssertEqual(tar.terminationStatus, 0)
    let tarSize = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("base.tar").path)[
        .size] as? NSNumber
    ).uint64Value
    let service = ArchiveService(executableURL: engine)
    for name in ["base.tar.bz2", "short.tbz2", "base.tar.zst"] {
      let archive = root.appendingPathComponent(name)
      let session = try await service.open(archive)
      XCTAssertEqual(session.entries.map(\.path), [name == "short.tbz2" ? "short.tar" : "base.tar"])
      if name != "base.tar.zst" { XCTAssertEqual(session.entries.first?.size, tarSize) }
      XCTAssertGreaterThan(session.entries.first?.size ?? 0, 0)
      try await service.close(session)
      let output = try await service.extractArchive(archive)
      XCTAssertEqual(
        try Data(contentsOf: output.appendingPathComponent("File.txt")), Data("original".utf8))
    }
    await service.cleanup()
  }

  /// Размер берётся из итоговой строки отчёта проверки, а не из заголовка архива.
  func testTestedStreamSizeParsing() {
    let report =
      "Testing archive: a.bz2\n--\nPath = a.bz2\n\nEverything is Ok\n\nSize:       6656\n"
    XCTAssertEqual(ArchiveService.testedStreamSize(report), 6656)
    XCTAssertNil(ArchiveService.testedStreamSize("Everything is Ok\n"))
    XCTAssertTrue(ArchiveService.hasUnknownStreamSize("Path = a\nSize = \n", format: "bzip2"))
    XCTAssertFalse(ArchiveService.hasUnknownStreamSize("Path = a\nSize = 5\n", format: "bzip2"))
    XCTAssertFalse(ArchiveService.hasUnknownStreamSize("Path = a\nSize = \n", format: "zip"))
  }

  /// Изменение архива из интернета не снимает с него quarantine.
  func testMutationPreservesQuarantineOfOriginal() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try runEngine(["a", "sample.zip", "File.txt"], in: root)
    let archive = root.appendingPathComponent("sample.zip")
    let quarantine = Data("0083;12345678;Test;".utf8)
    try quarantine.withUnsafeBytes {
      guard setxattr(archive.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) == 0
      else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    _ = try await service.add([root.appendingPathComponent("New.txt")], to: session)
    var buffer = [UInt8](repeating: 0, count: 64)
    let count = getxattr(archive.path, "com.apple.quarantine", &buffer, buffer.count, 0, 0)
    XCTAssertEqual(Data(buffer.prefix(max(count, 0))), quarantine)
    await service.cleanup()
  }

  /// Папка без права записи публикуется с исходными правами, а её черновик удаляется.
  func testReadOnlyDirectoriesArePublishedAndRemoved() throws {
    let root = try fixture()
    defer {
      chmod(root.appendingPathComponent("Published").path, 0o700)
      try? FileManager.default.removeItem(at: root)
    }
    for name in ["Locked", "Stale"] {
      let inner = root.appendingPathComponent(name + "/Inner")
      try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
      try Data("x".utf8).write(to: inner.appendingPathComponent("File.txt"))
      chmod(inner.path, 0o555)
      chmod(root.appendingPathComponent(name).path, 0o555)
    }
    let published = try ArchiveOutput.publish(
      root.appendingPathComponent("Locked"), proposed: root.appendingPathComponent("Published"),
      isDirectory: true)
    XCTAssertEqual(try FileFingerprint(published).type, .typeDirectory)
    var info = stat()
    XCTAssertEqual(lstat(published.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o555)
    try TemporaryWorkspace.removeTree(root.appendingPathComponent("Stale"))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Stale").path))
  }

  /// Новые рабочие папки носят имя PangoZip, а оставленные прежней версией Zipevra очищаются.
  func testWorkspaceUsesCurrentNameAndRecoversLegacyTransactions() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = "workspace-" + UUID().uuidString
    let legacy = FileManager.default.temporaryDirectory.appendingPathComponent(
      "app.zipevra.workspaces/" + id)
    let stale = root.appendingPathComponent(".zipevra-" + id + "-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: legacy.appendingPathComponent("transactions"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
    try Data().write(to: legacy.appendingPathComponent("owner.lock"))
    try JSONEncoder().encode(["path": stale.path]).write(
      to: legacy.appendingPathComponent("transactions/" + stale.lastPathComponent + ".json"))
    let workspace = TemporaryWorkspace()
    defer { workspace.cleanup() }
    let transaction = try workspace.transactionDirectory(
      nextTo: root.appendingPathComponent("a.zip"))
    XCTAssertTrue(transaction.lastPathComponent.hasPrefix(".pangozip-workspace-"))
    XCTAssertEqual(
      workspace.root.deletingLastPathComponent().lastPathComponent, "app.pangozip.workspaces")
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    try workspace.removeTransaction(transaction)
  }

  /// Слово password в имени повреждённого архива не превращает ошибку в запрос пароля.
  func testPasswordInArchiveNameIsNotPasswordRequest() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("my-passwords.zip")
    try Data("PK\u{3}\u{4} broken".utf8).write(to: archive)
    let service = ArchiveService(executableURL: engine)
    do {
      _ = try await service.open(archive)
      XCTFail("Повреждённый архив не должен открываться")
    } catch {
      XCTAssertEqual(error as? ArchiveError, .invalidArchive)
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
  /// Служебные имена распознаются на любом уровне, обычные файлы с похожими именами — нет.
  func testSystemFileNamesAndTreeFilter() throws {
    for name in ["__MACOSX", ".DS_Store", "._File.txt", "Thumbs.db", "desktop.ini", "Icon\r"] {
      XCTAssertTrue(SystemFiles.isSystemName(name), name)
    }
    for name in ["File.txt", "._", ".gitignore", "MACOSX", "Icon", "DS_Store"] {
      XCTAssertFalse(SystemFiles.isSystemName(name), name)
    }
    XCTAssertTrue(SystemFiles.isSystemPath("__MACOSX/Folder/File.txt"))
    XCTAssertFalse(SystemFiles.isSystemPath("Folder/File.txt"))
    let tree = try ArchiveListing.tree(from: [
      ArchiveEntry(path: "Folder/File.txt", size: 1),
      ArchiveEntry(path: "Folder/.DS_Store", size: 1),
      ArchiveEntry(path: "__MACOSX/Folder/._File.txt", size: 1),
    ])
    let filtered = SystemFiles.filter(tree)
    XCTAssertEqual(filtered.map(\.path), ["Folder"])
    XCTAssertEqual(filtered.first?.children?.map(\.path), ["Folder/File.txt"])
  }

  /// По умолчанию служебные файлы не попадают ни в новый архив, ни в существующий при добавлении.
  func testSystemFilesAreExcludedWhenArchiving() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Folder")
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
    for name in ["Keep.txt", ".DS_Store", "._Keep.txt", "__MACOSX/._Keep.txt"] {
      try Data("x".utf8).write(to: folder.appendingPathComponent(name))
    }
    try Data("x".utf8).write(to: root.appendingPathComponent(".DS_Store"))
    let service = ArchiveService(executableURL: engine)
    let clean = try await service.createArchive(
      from: [folder, root.appendingPathComponent(".DS_Store")],
      proposedURL: root.appendingPathComponent("clean.zip"), format: "zip")
    let session = try await service.open(clean)
    XCTAssertEqual(session.entries.map(\.path).sorted(), ["Folder", "Folder/Keep.txt"])
    let updated = try await service.add([folder], to: session, directory: "")
    XCTAssertFalse(updated.entries.contains { SystemFiles.isSystemPath($0.path) })
    try await service.close(updated)
    let full = try await service.createArchive(
      from: [folder], proposedURL: root.appendingPathComponent("full.zip"), format: "zip",
      options: CompressionOptions(excludesSystemFiles: false))
    let fullSession = try await service.open(full)
    XCTAssertTrue(fullSession.entries.contains { $0.path == "Folder/.DS_Store" })
    XCTAssertTrue(fullSession.entries.contains { $0.path == "Folder/__MACOSX" })
    try await service.close(fullSession)
    await service.cleanup()
  }

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
