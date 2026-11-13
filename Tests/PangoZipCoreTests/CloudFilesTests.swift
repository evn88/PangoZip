import XCTest

@testable import PangoZipCore

final class CloudFilesTests: XCTestCase {
  private let timing = CloudTiming(
    pollInterval: .milliseconds(5), stallTimeout: .milliseconds(150), concurrency: 2)

  func testLocalFilesAreNotTouched() async throws {
    let provider = FakeCloudProvider(
      items: ["/a": .directory(dataless: false), "/a/x": .file(dataless: false)],
      children: ["/a": ["/a/x"]])
    try await CloudFiles.materialize(
      [URL(fileURLWithPath: "/a")], provider: provider, timing: timing, progress: nil)
    XCTAssertTrue(provider.downloads.isEmpty)
  }

  func testDatalessFilesAreRequestedOnceEach() async throws {
    let provider = FakeCloudProvider(
      items: [
        "/a": .directory(dataless: true), "/a/x": .file(dataless: true),
        "/a/sub": .directory(dataless: false), "/a/sub/y": .file(dataless: true),
        "/a/z": .file(dataless: false),
      ],
      children: ["/a": ["/a/x", "/a/sub", "/a/z"], "/a/sub": ["/a/sub/y"]])
    let recorder = ProgressRecorder()
    // Папка и вложенный файл переданы повторно: запрос всё равно один.
    try await CloudFiles.materialize(
      [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/a/x")], provider: provider,
      timing: timing, progress: { await recorder.add($0) })
    XCTAssertEqual(provider.downloads.sorted(), ["/a/sub/y", "/a/x"])
    let values = await recorder.values
    XCTAssertTrue(values.allSatisfy { $0.phase == .downloading })
    XCTAssertEqual(values.last?.completedFiles, 2)
    XCTAssertEqual(values.last?.fraction, 1)
  }

  func testDownloadFailureIsMapped() async {
    let provider = FakeCloudProvider(
      items: ["/x": .file(dataless: true)], children: [:], failure: CocoaError(.fileReadUnknown))
    do {
      try await CloudFiles.materialize(
        [URL(fileURLWithPath: "/x")], provider: provider, timing: timing, progress: nil)
      XCTFail("Ожидалась ошибка")
    } catch {
      XCTAssertEqual(error as? ArchiveError, .cloudDownloadFailed)
    }
  }

  func testNetworkFailureMapsToOffline() async {
    let provider = FakeCloudProvider(
      items: ["/x": .file(dataless: true)], children: [:],
      failure: URLError(.notConnectedToInternet))
    do {
      try await CloudFiles.materialize(
        [URL(fileURLWithPath: "/x")], provider: provider, timing: timing, progress: nil)
      XCTFail("Ожидалась ошибка")
    } catch {
      XCTAssertEqual(error as? ArchiveError, .cloudOffline)
    }
  }

  func testStalledDownloadTimesOut() async {
    let provider = FakeCloudProvider(
      items: ["/x": .file(dataless: true)], children: [:], neverCompletes: true)
    do {
      try await CloudFiles.materialize(
        [URL(fileURLWithPath: "/x")], provider: provider, timing: timing, progress: nil)
      XCTFail("Ожидалась ошибка")
    } catch {
      XCTAssertEqual(error as? ArchiveError, .cloudDownloadTimedOut)
    }
  }

  func testGrowingDataKeepsDownloadAlive() async throws {
    let provider = FakeCloudProvider(
      items: ["/x": .file(dataless: true)], children: [:], completesAfterPolls: 60,
      growing: true)
    try await CloudFiles.materialize(
      [URL(fileURLWithPath: "/x")], provider: provider, timing: timing, progress: nil)
    XCTAssertEqual(provider.downloads, ["/x"])
  }

  func testCancellationPropagates() async {
    let provider = FakeCloudProvider(
      items: ["/x": .file(dataless: true)], children: [:], neverCompletes: true)
    let long = CloudTiming(
      pollInterval: .milliseconds(5), stallTimeout: .seconds(30), concurrency: 1)
    let task = Task {
      try await CloudFiles.materialize(
        [URL(fileURLWithPath: "/x")], provider: provider, timing: long, progress: nil)
    }
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    do {
      try await task.value
      XCTFail("Ожидалась отмена")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
  }

  func testVolumeNameDetection() {
    XCTAssertTrue(CloudFiles.isVolume(of: "a.7z.001", candidate: "a.7z.002"))
    XCTAssertFalse(CloudFiles.isVolume(of: "a.7z.001", candidate: "b.7z.002"))
    XCTAssertTrue(CloudFiles.isVolume(of: "a.zip", candidate: "a.z01"))
    XCTAssertTrue(CloudFiles.isVolume(of: "a.rar", candidate: "a.r00"))
    XCTAssertFalse(CloudFiles.isVolume(of: "a.zip", candidate: "a.txt"))
    XCTAssertFalse(CloudFiles.isVolume(of: "a.tar", candidate: "a.tar.gz"))
    XCTAssertFalse(CloudFiles.isVolume(of: "a.zip", candidate: "a.zip"))
  }

  func testArchiveVolumesAreMaterialized() async throws {
    let provider = FakeCloudProvider(
      items: [
        "/d": .directory(dataless: false), "/d/a.7z.001": .file(dataless: true),
        "/d/a.7z.002": .file(dataless: true), "/d/other.txt": .file(dataless: true),
      ],
      children: ["/d": ["/d/a.7z.001", "/d/a.7z.002", "/d/other.txt"]])
    try await CloudFiles.materializeArchive(
      URL(fileURLWithPath: "/d/a.7z.001"), provider: provider, timing: timing, progress: nil)
    XCTAssertEqual(provider.downloads.sorted(), ["/d/a.7z.001", "/d/a.7z.002"])
  }

  /// Реальная файловая система: обычный локальный файл не считается «dataless».
  func testSystemProviderTreatsLocalFileAsLocal() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("f.txt")
    try Data("x".utf8).write(to: file)
    let provider = SystemCloudProvider()
    XCTAssertEqual(try provider.state(of: file), .file(dataless: false))
    XCTAssertEqual(try provider.state(of: directory), .directory(dataless: false))
    XCTAssertEqual(try provider.children(of: directory).map(\.lastPathComponent), ["f.txt"])
  }

  func testSystemProviderMapsLegacyICloudStub() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data().write(to: directory.appendingPathComponent(".Report.pdf.icloud"))
    let provider = SystemCloudProvider()
    let children = try provider.children(of: directory)
    XCTAssertEqual(children.map(\.lastPathComponent), ["Report.pdf"])
    XCTAssertEqual(try provider.state(of: children[0]), .file(dataless: true))
  }
}

private actor ProgressRecorder {
  var values: [ArchiveProgress] = []
  func add(_ value: ArchiveProgress) { values.append(value) }
}

/// Подставное «облако»: загрузка снимает признак dataless через заданное число опросов.
private final class FakeCloudProvider: CloudItemProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: CloudItemState]
  private let childrenByPath: [String: [String]]
  private let failure: Error?
  private let neverCompletes: Bool
  private let completesAfterPolls: Int
  private let growing: Bool
  private var polls: [String: Int] = [:]
  private var requested: [String] = []
  private var size: UInt64 = 0

  init(
    items: [String: CloudItemState], children: [String: [String]], failure: Error? = nil,
    neverCompletes: Bool = false, completesAfterPolls: Int = 0, growing: Bool = false
  ) {
    self.items = items
    childrenByPath = children
    self.failure = failure
    self.neverCompletes = neverCompletes
    self.completesAfterPolls = completesAfterPolls
    self.growing = growing
  }

  var downloads: [String] {
    lock.lock()
    defer { lock.unlock() }
    return requested
  }

  func state(of url: URL) throws -> CloudItemState {
    lock.lock()
    defer { lock.unlock() }
    guard let state = items[url.path] else { throw POSIXError(.ENOENT) }
    guard case .file(true) = state, requested.contains(url.path), !neverCompletes else {
      return state
    }
    polls[url.path, default: 0] += 1
    if polls[url.path]! > completesAfterPolls { items[url.path] = .file(dataless: false) }
    return items[url.path]!
  }

  func children(of directory: URL) throws -> [URL] {
    (childrenByPath[directory.path] ?? []).map { URL(fileURLWithPath: $0) }
  }

  func startDownload(of url: URL) async throws {
    record(url)
    if let failure { throw failure }
  }

  private func record(_ url: URL) {
    lock.lock()
    requested.append(url.path)
    lock.unlock()
  }

  func allocatedBytes(of url: URL) -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    if growing { size += 1 }
    return size
  }
}
