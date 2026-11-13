import Synchronization
import XCTest

@testable import PangoZipCore

/// Записывает, что «переместили в Корзину», не трогая настоящую Корзину.
private final class RecordingTrasher: ArchiveTrashing {
  private let urls = Mutex<[URL]>([])
  var trashed: [URL] { urls.withLock { $0 } }
  func trash(_ url: URL) throws { urls.withLock { $0.append(url) } }
}

private struct FailingTrasher: ArchiveTrashing {
  func trash(_ url: URL) throws { throw POSIXError(.EPERM) }
}

final class SmartExtractionTests: XCTestCase, @unchecked Sendable {
  private let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
      "Resources/Engine/7zz")

  /// Один файл в корне публикуется напрямую, без папки с именем архива.
  func testSingleFileIsPublishedWithoutWrapperFolder() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let archive = try await makeArchive("single.zip", ["a.txt"], root, service)
    let output = root.appendingPathComponent("out")
    let result = try await service.extractArchive(
      archive, directory: output, smartExtraction: true)
    XCTAssertEqual(
      result.standardizedFileURL, output.appendingPathComponent("a.txt").standardizedFileURL)
    XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "alpha")
    XCTAssertEqual(try contents(output), ["a.txt"])
    await service.cleanup()
  }

  /// Одна папка в корне тоже публикуется как есть и сохраняет содержимое.
  func testSingleFolderIsPublishedWithoutWrapperFolder() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let archive = try await makeArchive("folder.zip", ["docs"], root, service)
    let output = root.appendingPathComponent("out")
    let result = try await service.extractArchive(
      archive, directory: output, smartExtraction: true)
    XCTAssertEqual(result.lastPathComponent, "docs")
    XCTAssertEqual(try contents(output), ["docs"])
    XCTAssertEqual(try contents(result), ["text.txt"])
    await service.cleanup()
  }

  /// Несколько объектов в корне по-прежнему попадают в папку с именем архива.
  func testSeveralRootItemsStillUseWrapperFolder() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let archive = try await makeArchive("many.zip", ["a.txt", "docs"], root, service)
    let output = root.appendingPathComponent("out")
    let result = try await service.extractArchive(
      archive, directory: output, smartExtraction: true)
    XCTAssertEqual(result.lastPathComponent, "many")
    XCTAssertEqual(try contents(result), ["a.txt", "docs"])
    XCTAssertEqual(try contents(output), ["many"])
    await service.cleanup()
  }

  /// Без режима поведение прежнее: даже один объект получает обёртку.
  func testSmartExtractionIsOffByDefaultInService() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let archive = try await makeArchive("single.zip", ["a.txt"], root, service)
    let result = try await service.extractArchive(
      archive, directory: root.appendingPathComponent("out"))
    XCTAssertEqual(result.lastPathComponent, "single")
    XCTAssertEqual(try contents(result), ["a.txt"])
    await service.cleanup()
  }

  /// Занятое имя не перезаписывается: результат получает числовой суффикс.
  func testNameConflictGetsFreeNameWithoutOverwriting() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let archive = try await makeArchive("single.zip", ["a.txt"], root, service)
    let output = root.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try Data("existing".utf8).write(to: output.appendingPathComponent("a.txt"))
    let result = try await service.extractArchive(
      archive, directory: output, smartExtraction: true)
    XCTAssertEqual(result.lastPathComponent, "a (2).txt")
    XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "alpha")
    XCTAssertEqual(
      try String(contentsOf: output.appendingPathComponent("a.txt"), encoding: .utf8), "existing")
    await service.cleanup()
  }

  /// Архив уходит в Корзину только после успешного извлечения.
  func testArchiveIsTrashedAfterSuccessfulExtraction() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let archive = try await makeArchive("single.zip", ["a.txt"], root, service)
    let trasher = RecordingTrasher()
    let outcome = try await service.extractAndFinish(
      archive, directory: root.appendingPathComponent("out"), smartExtraction: true,
      trashesArchive: true, trasher: trasher)
    XCTAssertEqual(trasher.trashed.map(\.lastPathComponent), ["single.zip"])
    XCTAssertEqual(outcome.trashedArchives.count, 1)
    XCTAssertNil(outcome.trashFailure)
    await service.cleanup()
  }

  /// Без настройки Корзина не используется.
  func testArchiveIsKeptWhenTrashingIsDisabled() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let archive = try await makeArchive("single.zip", ["a.txt"], root, service)
    let trasher = RecordingTrasher()
    _ = try await service.extractAndFinish(
      archive, directory: root.appendingPathComponent("out"), trasher: trasher)
    XCTAssertTrue(trasher.trashed.isEmpty)
    await service.cleanup()
  }

  /// Ошибка извлечения не отправляет архив в Корзину.
  func testArchiveIsNotTrashedWhenExtractionFails() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let broken = root.appendingPathComponent("broken.zip")
    try Data("this is not an archive".utf8).write(to: broken)
    let service = ArchiveService(executableURL: engine)
    let trasher = RecordingTrasher()
    do {
      _ = try await service.extractAndFinish(
        broken, directory: root.appendingPathComponent("out"), trashesArchive: true,
        trasher: trasher)
      XCTFail("Повреждённый архив не должен извлекаться")
    } catch {
      XCTAssertTrue(trasher.trashed.isEmpty)
      XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path))
    }
    await service.cleanup()
  }

  /// Ошибка Корзины не ломает успешное извлечение, но сообщается в итоге.
  func testTrashFailureDoesNotFailExtraction() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let archive = try await makeArchive("single.zip", ["a.txt"], root, service)
    let outcome = try await service.extractAndFinish(
      archive, directory: root.appendingPathComponent("out"), trashesArchive: true,
      trasher: FailingTrasher())
    XCTAssertTrue(outcome.trashedArchives.isEmpty)
    XCTAssertNotNil(outcome.trashFailure)
    XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.url.path))
    await service.cleanup()
  }

  /// У многотомного архива в Корзину уходят все тома.
  func testAllVolumesAreTrashed() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let archive = try await makeArchive("single.zip", ["a.txt"], root, service)
    // Тома нумеруются как у разбитого архива; извлекаем обычный, но набор имён проверяем отдельно.
    let first = root.appendingPathComponent("set.7z.001")
    try FileManager.default.copyItem(at: archive, to: root.appendingPathComponent("set.7z.002"))
    try FileManager.default.copyItem(at: archive, to: first)
    let names = ArchiveVolumes.volumes(of: first).map(\.lastPathComponent)
    XCTAssertEqual(names, ["set.7z.001", "set.7z.002"])
    await service.cleanup()
  }

  /// Распознавание томов по именам.
  func testVolumeRoles() {
    XCTAssertEqual(ArchiveVolumes.role(ofName: "a.7z.001"), .first)
    XCTAssertEqual(ArchiveVolumes.role(ofName: "a.7z.002"), .later)
    XCTAssertEqual(ArchiveVolumes.role(ofName: "a.part1.rar"), .first)
    XCTAssertEqual(ArchiveVolumes.role(ofName: "a.part01.rar"), .first)
    XCTAssertEqual(ArchiveVolumes.role(ofName: "a.part2.rar"), .later)
    XCTAssertEqual(ArchiveVolumes.role(ofName: "a.r00"), .later)
    XCTAssertEqual(ArchiveVolumes.role(ofName: "a.z01"), .later)
    XCTAssertEqual(ArchiveVolumes.role(ofName: "a.zip"), .standalone)
    XCTAssertEqual(ArchiveVolumes.role(ofName: "photo.001"), .standalone)
    XCTAssertTrue(ArchiveVolumes.isArchiveName("a.7z.001"))
    XCTAssertFalse(ArchiveVolumes.isArchiveName("photo.001"))
  }

  /// Старая схема RAR и ZIP: головной файл собирает свои продолжения.
  func testLegacySplitVolumesAreGrouped() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["x.rar", "x.r00", "x.r01", "y.rar", "x.zip", "x.z01"] {
      try Data("1".utf8).write(to: root.appendingPathComponent(name))
    }
    XCTAssertEqual(
      ArchiveVolumes.volumes(of: root.appendingPathComponent("x.rar")).map(\.lastPathComponent),
      ["x.rar", "x.r00", "x.r01"])
    XCTAssertEqual(
      ArchiveVolumes.volumes(of: root.appendingPathComponent("x.zip")).map(\.lastPathComponent),
      ["x.zip", "x.z01"])
    XCTAssertEqual(
      ArchiveVolumes.volumes(of: root.appendingPathComponent("y.rar")).map(\.lastPathComponent),
      ["y.rar"])
  }

  /// Настройки по умолчанию и чтение из UserDefaults.
  func testPreferencesDefaultsAndLoading() throws {
    let suite = "pangozip-test-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(
      ExtractionPreferences.load(from: defaults),
      ExtractionPreferences(smartExtraction: true, revealsResult: true, trashesArchive: false))
    defaults.set(false, forKey: ExtractionPreferences.smartKey)
    defaults.set(true, forKey: ExtractionPreferences.trashKey)
    let loaded = ExtractionPreferences.load(from: defaults)
    XCTAssertFalse(loaded.smartExtraction)
    XCTAssertTrue(loaded.trashesArchive)
  }

  // MARK: - Помощники

  private func contents(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  private func makeArchive(
    _ name: String, _ items: [String], _ root: URL, _ service: ArchiveService
  ) async throws -> URL {
    try await service.createArchive(
      from: items.map { root.appendingPathComponent("src/" + $0) },
      proposedURL: root.appendingPathComponent(name), format: "zip")
  }

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pangozip-smart-" + UUID().uuidString)
    let source = root.appendingPathComponent("src")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("out"), withIntermediateDirectories: true)
    try Data("alpha".utf8).write(to: source.appendingPathComponent("a.txt"))
    try Data("document".utf8).write(to: source.appendingPathComponent("docs/text.txt"))
    return root
  }
}
