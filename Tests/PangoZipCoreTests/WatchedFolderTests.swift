import XCTest

@testable import PangoZipCore

final class WatchedFolderTests: XCTestCase {
  private let folder = "/tmp/watch"
  private let start = Date(timeIntervalSince1970: 1_000_000)

  private func rule(
    enabled: Bool = true, destination: WatchedDestination = WatchedDestination()
  ) -> WatchedFolderRule {
    WatchedFolderRule(folderPath: folder, isEnabled: enabled, destinations: [destination])
  }

  private func file(_ name: String, size: UInt64 = 100, modified: TimeInterval = 0)
    -> WatchedFileSnapshot
  {
    WatchedFileSnapshot(
      url: URL(fileURLWithPath: folder + "/" + name), size: size,
      modified: Date(timeIntervalSince1970: modified))
  }

  /// Правила переживают кодирование и декодирование вместе с назначениями.
  func testRulesRoundTrip() {
    let rules = [
      rule(destination: WatchedDestination(directoryPath: "/tmp/out", deletesArchive: true)),
      WatchedFolderRule(folderPath: "/tmp/other", isEnabled: false),
    ]
    XCTAssertEqual(WatchedFolderStore.decode(WatchedFolderStore.encode(rules)), rules)
  }

  /// Пустые и повреждённые данные дают пустой список, а не падение.
  func testDecodingGarbageGivesEmptyList() {
    XCTAssertEqual(WatchedFolderStore.decode(nil), [])
    XCTAssertEqual(WatchedFolderStore.decode(Data()), [])
    XCTAssertEqual(WatchedFolderStore.decode(Data("not json".utf8)), [])
  }

  /// Правила сохраняются в UserDefaults и читаются оттуда же.
  func testStorePersistsToUserDefaults() throws {
    let suite = "pangozip-watch-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(WatchedFolderStore.load(from: defaults), [])
    let rules = [rule()]
    WatchedFolderStore.save(rules, to: defaults)
    XCTAssertEqual(WatchedFolderStore.load(from: defaults), rules)
  }

  /// Назначение по умолчанию ведёт в ту же папку, заданное — в выбранную.
  func testDestinationDirectory() {
    let same = rule()
    XCTAssertEqual(same.directory(for: same.destinations[0]).path, folder)
    let other = rule(destination: WatchedDestination(directoryPath: "/tmp/out"))
    XCTAssertEqual(other.directory(for: other.destinations[0]).path, "/tmp/out")
  }

  /// Скрытые, временные и незавершённые загрузки отбрасываются.
  func testFilterIgnoresTemporaryAndHiddenNames() {
    for name in [
      ".hidden.zip", "a.zip.download", "a.zip.crdownload", "a.zip.part", "a.zip.tmp",
      "~$a.zip", "a.zip~", "A.ZIP.PARTIAL",
    ] {
      XCTAssertTrue(WatchedFileFilter.isIgnored(name: name), name)
    }
    for name in ["a.zip", "a.part1.rar", "a.7z.001"] {
      XCTAssertFalse(WatchedFileFilter.isIgnored(name: name), name)
    }
  }

  /// Архив, который уже лежал в папке при старте, не обрабатывается никогда.
  func testPreexistingArchivesAreIgnored() {
    var tracker = WatchedFolderTracker(rule: rule(), existingNames: ["old.zip"])
    for second in 0..<10 {
      let jobs = tracker.update(
        files: [file("old.zip")], now: start.addingTimeInterval(Double(second)))
      XCTAssertTrue(jobs.isEmpty)
    }
  }

  /// Новый архив ждёт стабильного размера, затем выдаётся ровно один раз.
  func testNewArchiveWaitsForStableSizeAndIsEmittedOnce() {
    var tracker = WatchedFolderTracker(rule: rule(), existingNames: [])
    XCTAssertTrue(tracker.update(files: [file("new.zip")], now: start).isEmpty)
    XCTAssertTrue(tracker.hasPending)
    XCTAssertTrue(
      tracker.update(files: [file("new.zip")], now: start.addingTimeInterval(1)).isEmpty)
    let jobs = tracker.update(files: [file("new.zip")], now: start.addingTimeInterval(2))
    XCTAssertEqual(jobs.map(\.archive.lastPathComponent), ["new.zip"])
    XCTAssertEqual(jobs.first?.directory.path, folder)
    XCTAssertFalse(jobs[0].deletesArchive)
    XCTAssertFalse(tracker.hasPending)
    for second in 3..<8 {
      XCTAssertTrue(
        tracker.update(files: [file("new.zip")], now: start.addingTimeInterval(Double(second)))
          .isEmpty)
    }
  }

  /// Рост размера перезапускает ожидание; пустой файл не обрабатывается.
  func testGrowingAndEmptyFilesKeepWaiting() {
    var tracker = WatchedFolderTracker(rule: rule(), existingNames: [])
    _ = tracker.update(files: [file("a.zip", size: 10)], now: start)
    XCTAssertTrue(
      tracker.update(files: [file("a.zip", size: 20)], now: start.addingTimeInterval(2)).isEmpty)
    XCTAssertTrue(
      tracker.update(files: [file("a.zip", size: 20)], now: start.addingTimeInterval(3)).isEmpty)
    XCTAssertEqual(
      tracker.update(files: [file("a.zip", size: 20)], now: start.addingTimeInterval(4)).count, 1)
    var empty = WatchedFolderTracker(rule: rule(), existingNames: [])
    _ = empty.update(files: [file("e.zip", size: 0)], now: start)
    XCTAssertTrue(
      empty.update(files: [file("e.zip", size: 0)], now: start.addingTimeInterval(10)).isEmpty)
  }

  /// Файл, исчезнувший до готовности, забывается; вернувшийся под тем же именем ждёт заново.
  func testVanishedFileIsForgotten() {
    var tracker = WatchedFolderTracker(rule: rule(), existingNames: [])
    _ = tracker.update(files: [file("a.zip")], now: start)
    _ = tracker.update(files: [], now: start.addingTimeInterval(1))
    XCTAssertFalse(tracker.hasPending)
    XCTAssertTrue(
      tracker.update(files: [file("a.zip")], now: start.addingTimeInterval(5)).isEmpty)
  }

  /// Незавершённые загрузки и обычные файлы игнорируются; готовый архив после переименования берётся.
  func testTemporaryAndNonArchiveFilesAreIgnoredUntilRenamed() {
    var tracker = WatchedFolderTracker(rule: rule(), existingNames: [])
    let temporary = [file("a.zip.download"), file("notes.txt"), file(".hidden.zip")]
    _ = tracker.update(files: temporary, now: start)
    XCTAssertFalse(tracker.hasPending)
    XCTAssertTrue(tracker.update(files: temporary, now: start.addingTimeInterval(10)).isEmpty)
    _ = tracker.update(files: [file("a.zip")], now: start.addingTimeInterval(11))
    XCTAssertEqual(
      tracker.update(files: [file("a.zip")], now: start.addingTimeInterval(13)).count, 1)
  }

  /// Многотомные архивы запускаются только по первому тому.
  func testOnlyFirstVolumeStartsExtraction() {
    var tracker = WatchedFolderTracker(rule: rule(), existingNames: [])
    let files = [
      file("set.7z.001"), file("set.7z.002"), file("set.7z.003"),
      file("book.part1.rar"), file("book.part2.rar"), file("old.r00"),
    ]
    _ = tracker.update(files: files, now: start)
    let jobs = tracker.update(files: files, now: start.addingTimeInterval(2))
    XCTAssertEqual(jobs.map(\.archive.lastPathComponent), ["book.part1.rar", "set.7z.001"])
  }

  /// Архивы, созданные самим PangoZip, пропускаются и не запускаются позже.
  func testOwnOutputIsSkipped() {
    var tracker = WatchedFolderTracker(rule: rule(), existingNames: [])
    let own = { (url: URL) in url.lastPathComponent == "mine.zip" }
    for second in 0..<5 {
      XCTAssertTrue(
        tracker.update(
          files: [file("mine.zip")], now: start.addingTimeInterval(Double(second)),
          isOwnOutput: own
        ).isEmpty)
    }
    XCTAssertFalse(tracker.hasPending)
  }

  /// Отключённое правило ничего не запускает.
  func testDisabledRuleProducesNoJobs() {
    var tracker = WatchedFolderTracker(rule: rule(enabled: false), existingNames: [])
    _ = tracker.update(files: [file("a.zip")], now: start)
    XCTAssertTrue(tracker.update(files: [file("a.zip")], now: start.addingTimeInterval(5)).isEmpty)
  }

  /// Задание несёт папку назначения и флажок удаления из назначения.
  func testJobCarriesDestinationAndTrashFlag() {
    let custom = rule(
      destination: WatchedDestination(directoryPath: "/tmp/out", deletesArchive: true))
    var tracker = WatchedFolderTracker(rule: custom, existingNames: [])
    _ = tracker.update(files: [file("a.zip")], now: start)
    let jobs = tracker.update(files: [file("a.zip")], now: start.addingTimeInterval(2))
    XCTAssertEqual(jobs.first?.directory.path, "/tmp/out")
    XCTAssertEqual(jobs.first?.deletesArchive, true)
  }

  /// Всё, что PangoZip публикует на диск, попадает в реестр собственных результатов.
  func testPublishedOutputIsRegistered() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pangozip-own-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.zip")
    try Data("x".utf8).write(to: source)
    let target = try ArchiveOutput.publish(
      source, proposed: root.appendingPathComponent("result.zip"), isDirectory: false)
    XCTAssertTrue(OwnOutputRegistry.shared.contains(target))
    XCTAssertFalse(OwnOutputRegistry.shared.contains(root.appendingPathComponent("other.zip")))
  }

  /// Записи реестра устаревают.
  func testRegistryExpiresEntries() {
    let registry = OwnOutputRegistry()
    let url = URL(fileURLWithPath: "/tmp/x.zip")
    registry.register(url, now: start)
    XCTAssertTrue(registry.contains(url, now: start.addingTimeInterval(60)))
    XCTAssertFalse(registry.contains(url, now: start.addingTimeInterval(7200)))
  }
}
