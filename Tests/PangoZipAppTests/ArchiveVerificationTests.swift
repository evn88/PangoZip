import Foundation
import PangoZipCore
import XCTest

@testable import PangoZipApp

final class ArchiveVerificationTests: XCTestCase, @unchecked Sendable {
  private var engine: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Resources/Engine/7zz")
  }

  /// Команда проверки проходит через очередь операций и сообщает об успехе.
  @MainActor
  func testVerifyCommandReportsSuccessAndFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 66, count: 300_000).write(to: root.appendingPathComponent("a.bin"))
    let archive = root.appendingPathComponent("sample.7z")
    try run(["a", "-mx=0", archive.path, "a.bin"], in: root)
    let service = ArchiveService(executableURL: engine)
    let model = ArchiveBrowserModel(service: service)
    model.togglePreview()
    model.open(archive)
    try await waitUntil { !model.isBusy && model.session != nil }
    model.verifyArchive()
    XCTAssertEqual(model.queuedOperations.count, 0)
    try await waitUntil { !model.isBusy }
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.operationMessage, L10n.tr("Архив проверен: ошибок нет"))
    // Повреждение данных после открытия обнаруживает проверка, а не чтение списка.
    var bytes = try Data(contentsOf: archive)
    bytes[40] ^= 0xFF
    try bytes.write(to: archive)
    model.verifyArchive()
    try await waitUntil { !model.isBusy }
    XCTAssertNotNil(model.errorMessage)
    await model.cleanup()
  }

  /// Лист сумм считает файл архива и выбранный элемент; прогресс завершается и сбрасывается.
  @MainActor
  func testChecksumsModelCalculatesArchiveAndEntry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("abc".utf8).write(to: root.appendingPathComponent("abc.txt"))
    let archive = root.appendingPathComponent("sample.zip")
    try run(["a", "-tzip", archive.path, "abc.txt"], in: root)
    let service = ArchiveService(executableURL: engine)
    let session = try await service.open(archive)
    let model = ChecksumsModel(
      service: service, session: session, paths: ["abc.txt"], password: "")
    model.start()
    try await waitUntil { !model.isRunning }
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.rows.map(\.isArchive), [true, false])
    XCTAssertEqual(model.rows[1].record.crc32, "352441C2")
    model.comparison = " 352441c2 "
    XCTAssertEqual(model.comparisonResult, .match)
    model.comparison = "00000000"
    XCTAssertEqual(model.comparisonResult, .mismatch)
    model.comparison = ""
    XCTAssertEqual(model.comparisonResult, .empty)
    await service.cleanup()
  }

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

  @MainActor
  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "Операция должна завершиться за отведённое время")
  }
}
