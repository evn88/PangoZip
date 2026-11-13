import Foundation
import XCTest

@testable import PangoZipCore

final class ArchiveCreationFormatsTests: XCTestCase, @unchecked Sendable {
  private let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Engine/7zz")

  /// Каждый новый формат создаётся, открывается и извлекается с тем же содержимым.
  func testNewFormatsCreateOpenAndExtract() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    for format in ["tar", "tar.gz", "tar.xz", "wim"] {
      let proposed = root.appendingPathComponent("Sample." + format)
      let archive = try await service.createArchive(
        from: [root.appendingPathComponent("docs"), root.appendingPathComponent("a.txt")],
        proposedURL: proposed, format: format, options: CompressionOptions(format: format))
      XCTAssertEqual(archive, proposed)
      XCTAssertTrue(FinderSelection.isArchive(archive))
      XCTAssertEqual(FinderSelection.extractionName(for: archive), "Sample")
      let session = try await service.open(archive)
      XCTAssertFalse(session.entries.isEmpty)
      try await service.close(session)
      let output = try await service.extractArchive(archive)
      XCTAssertEqual(
        try String(contentsOf: output.appendingPathComponent("docs/text.txt"), encoding: .utf8),
        "документ")
      XCTAssertEqual(
        try String(contentsOf: output.appendingPathComponent("a.txt"), encoding: .utf8), "alpha")
      // Повторное создание не перезаписывает готовый архив и не ломает составное расширение.
      let second = try await service.createArchive(
        from: [root.appendingPathComponent("a.txt")], proposedURL: proposed, format: format)
      XCTAssertEqual(second.lastPathComponent, "Sample (2)." + format)
      XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }
    await service.cleanup()
  }

  /// Форматы без шифрования отклоняют пароль до создания каких-либо файлов.
  func testPasswordIsRejectedForUnencryptedFormats() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    for format in ["tar", "tar.gz", "tar.xz", "wim"] {
      let proposed = root.appendingPathComponent("Secret." + format)
      do {
        _ = try await service.createArchive(
          from: [root.appendingPathComponent("a.txt")], proposedURL: proposed, format: format,
          password: "secret")
        XCTFail("Пароль для \(format) должен быть отклонён")
      } catch {
        XCTAssertEqual(error as? ArchiveError, .invalidOperation)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: proposed.path))
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
      ["a.txt", "docs"])
  }

  /// Отключение шифрования имён оставляет список файлов читаемым без пароля.
  func testFileNameEncryptionIsOptional() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let hidden = try await service.createArchive(
      from: [root.appendingPathComponent("a.txt")],
      proposedURL: root.appendingPathComponent("hidden.7z"), format: "7z", password: "pw")
    let visible = try await service.createArchive(
      from: [root.appendingPathComponent("a.txt")],
      proposedURL: root.appendingPathComponent("visible.7z"), format: "7z",
      options: CompressionOptions(format: "7z", encryptsFileNames: false), password: "pw")
    do {
      _ = try await service.open(hidden)
      XCTFail("Имена должны быть зашифрованы")
    } catch {
      XCTAssertEqual(error as? ArchiveError, .passwordRequired)
    }
    let session = try await service.open(visible)
    XCTAssertEqual(session.entries.map(\.path), ["a.txt"])
    try await service.close(session)
    await service.cleanup()
  }

  /// Тома создаются целым набором, открываются с первого тома и не перезаписывают друг друга.
  func testVolumesAreCreatedVerifiedAndNeverOverwritten() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var random = SystemRandomNumberGenerator()
    let payload = Data((0..<2_500_000).map { _ in UInt8.random(in: 0...255, using: &random) })
    try payload.write(to: root.appendingPathComponent("big.bin"))
    let service = ArchiveService(executableURL: engine)
    for format in ["7z", "zip"] {
      let proposed = root.appendingPathComponent("Parts." + format)
      let options = CompressionOptions(format: format, volumeSizeMB: 1)
      let first = try await service.createArchive(
        from: [root.appendingPathComponent("big.bin")], proposedURL: proposed, format: format,
        options: options)
      XCTAssertEqual(first.lastPathComponent, "Parts.\(format).001")
      let volumes = try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.hasPrefix("Parts.\(format).") }.sorted()
      XCTAssertEqual(volumes, (1...3).map { "Parts.\(format).00\($0)" })
      XCTAssertTrue(FinderSelection.isArchive(first))
      XCTAssertEqual(FinderSelection.extractionName(for: first), "Parts")
      let before = try volumes.map { try Data(contentsOf: root.appendingPathComponent($0)) }
      let output = try await service.extractArchive(first)
      XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("big.bin")), payload)
      // Если имя набора занято, весь новый набор получает общее свободное имя.
      let second = try await service.createArchive(
        from: [root.appendingPathComponent("big.bin")], proposedURL: proposed, format: format,
        options: options)
      XCTAssertEqual(second.lastPathComponent, "Parts (2).\(format).001")
      XCTAssertEqual(
        try volumes.map { try Data(contentsOf: root.appendingPathComponent($0)) }, before)
      let session = try await service.open(second)
      XCTAssertEqual(session.entries.filter { !$0.isDirectory }.map(\.path), ["big.bin"])
      try await service.close(session)
    }
    await service.cleanup()
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
      .filter { $0.hasPrefix(".") }
    XCTAssertTrue(leftovers.isEmpty, "Остались временные каталоги: \(leftovers)")
  }

  /// Занятый средний том не позволяет опубликовать часть набора под тем же именем.
  func testPublishSetPicksCommonNameAndLeavesNothingBehind() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = root.appendingPathComponent("staging")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    var items: [(source: URL, suffix: String)] = []
    for index in 1...3 {
      let source = staging.appendingPathComponent("working.7z.00\(index)")
      try Data([UInt8(index)]).write(to: source)
      items.append((source, ".7z.00\(index)"))
    }
    try Data("busy".utf8).write(to: root.appendingPathComponent("Set.7z.002"))
    let urls = try ArchiveOutput.publishSet(items, parent: root, stem: "Set")
    XCTAssertEqual(urls.map(\.lastPathComponent), (1...3).map { "Set (2).7z.00\($0)" })
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Set.7z.001").path))
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("Set.7z.002"), encoding: .utf8), "busy")
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
  }

  /// Параметры нормализуются по возможностям формата и передаются движку без лишних ключей.
  func testOptionsRespectFormatCapabilities() {
    XCTAssertEqual(CompressionOptions(format: "tar", level: 9).arguments, [])
    XCTAssertEqual(CompressionOptions(format: "wim", level: 9).arguments, [])
    XCTAssertEqual(
      CompressionOptions(format: "tar.gz", level: 6, solid: false).arguments, ["-mx=6", "-mmt=on"])
    XCTAssertNil(CompressionOptions(format: "tar.xz", volumeSizeMB: 10).volumeSizeMB)
    XCTAssertEqual(CompressionOptions(format: "7z", volumeSizeMB: 25).volumeArguments, ["-v25m"])
    XCTAssertNil(CompressionOptions(format: "zip", volumeSizeMB: 0).volumeSizeMB)
    XCTAssertEqual(
      CompressionOptions(format: "zip", volumeSizeMB: Int.max).volumeSizeMB,
      CompressionOptions.maximumVolumeSizeMB)
    XCTAssertEqual(CompressionOptions(format: "rar").format, "zip")
  }

  /// Прогресс сжатия tar.gz не откатывается назад между двумя шагами.
  func testCompressedTarProgressIsMonotonic() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService(executableURL: engine)
    let recorder = FractionRecorder()
    _ = try await service.createArchive(
      from: [root.appendingPathComponent("docs")],
      proposedURL: root.appendingPathComponent("p.tar.gz"), format: "tar.gz",
      progress: { await recorder.add($0.fraction) })
    let values = await recorder.values
    XCTAssertFalse(values.isEmpty)
    XCTAssertEqual(values, values.sorted())
    XCTAssertEqual(values.last, 1)
  }

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try "документ".write(
      to: root.appendingPathComponent("docs/text.txt"), atomically: true, encoding: .utf8)
    try "alpha".write(
      to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    return root
  }
}

private actor FractionRecorder {
  private(set) var values: [Double] = []
  func add(_ value: Double?) { if let value { values.append(value) } }
}
