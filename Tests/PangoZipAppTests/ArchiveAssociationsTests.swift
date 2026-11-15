import XCTest

@testable import PangoZipApp

final class ArchiveAssociationsTests: XCTestCase, @unchecked Sendable {
  private let zip = ArchiveAssociationType(identifier: "public.zip-archive", fileExtension: "zip")
  private let sevenZip = ArchiveAssociationType(
    identifier: "org.7-zip.7-zip-archive", fileExtension: "7z")
  private let pangoZip = URL(fileURLWithPath: "/Applications/PangoZip.app")
  private let other = URL(fileURLWithPath: "/Applications/Other.app")

  /// Отдельный домен настроек на каждый тест, чтобы снимки не пересекались.
  @MainActor
  private func makeStore() -> ArchiveAssociationSnapshotStore {
    let name = "ArchiveAssociationsTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    addTeardownBlock { defaults.removePersistentDomain(forName: name) }
    return ArchiveAssociationSnapshotStore(defaults: defaults)
  }

  @MainActor
  private func makeModel(
    _ manager: FakeArchiveAssociationsManager, store: ArchiveAssociationSnapshotStore? = nil
  ) -> ArchiveAssociationsModel {
    ArchiveAssociationsModel(
      types: [zip, sevenZip], manager: manager, store: store ?? makeStore(),
      applicationURL: pangoZip, applicationIdentifier: "app.pangozip.desktop",
      applicationName: "PangoZip")
  }

  @MainActor
  func testRowsReflectSystemHandlerIncludingAnotherPangoZipCopy() {
    let buildCopy = URL(fileURLWithPath: "/Users/me/build/PangoZip.app")
    let manager = FakeArchiveAssociationsManager(
      defaults: [zip.identifier: other, sevenZip.identifier: buildCopy],
      identifiers: [buildCopy: "app.pangozip.desktop"])
    let model = makeModel(manager)

    XCTAssertEqual(model.rows.map(\.isPangoZipDefault), [false, true])
    XCTAssertEqual(model.rows.map(\.defaultApplicationName), ["Other", "PangoZip"])
    XCTAssertFalse(model.areAllAssigned)
  }

  @MainActor
  func testEnablingTypeAssignsPangoZipAndDisablingRestoresInitialHandler() async {
    let manager = FakeArchiveAssociationsManager(
      defaults: [zip.identifier: other, sevenZip.identifier: other])
    let model = makeModel(manager)
    model.captureInitialSnapshotIfNeeded()

    await model.setPangoZipDefault(true, for: zip)
    XCTAssertEqual(manager.defaults[zip.identifier], pangoZip)
    XCTAssertEqual(manager.defaults[sevenZip.identifier], other)

    await model.setPangoZipDefault(false, for: zip)
    XCTAssertEqual(manager.defaults[zip.identifier], other)
    XCTAssertNil(model.errorMessage)
  }

  @MainActor
  func testDisablingWithoutKnownPreviousHandlerExplainsWhatToDo() async {
    let manager = FakeArchiveAssociationsManager(defaults: [zip.identifier: pangoZip])
    let model = makeModel(manager)
    model.captureInitialSnapshotIfNeeded()

    await model.setPangoZipDefault(false, for: zip)

    XCTAssertTrue(manager.updatedTypes.isEmpty)
    XCTAssertTrue(model.errorMessage?.contains("ZIP") == true)
  }

  @MainActor
  func testAssignAllSkipsTypesAlreadyOpenedByPangoZipAndReportsFailures() async {
    let manager = FakeArchiveAssociationsManager(
      defaults: [zip.identifier: pangoZip, sevenZip.identifier: other],
      failingTypes: [sevenZip.identifier])
    let model = makeModel(manager)

    await model.assignAll()

    XCTAssertEqual(manager.updatedTypes, [sevenZip.identifier])
    XCTAssertTrue(model.errorMessage?.contains("7Z") == true)
  }

  @MainActor
  func testInitialSnapshotSurvivesNewModelAndRestoresOriginalHandlers() async {
    let store = makeStore()
    let manager = FakeArchiveAssociationsManager(
      defaults: [zip.identifier: other, sevenZip.identifier: other])
    let first = makeModel(manager, store: store)
    first.captureInitialSnapshotIfNeeded()
    await first.assignAll()
    XCTAssertTrue(first.areAllAssigned)

    // Новая модель имитирует повторный запуск: исходный снимок прежний, а не «всё на PangoZip».
    let second = makeModel(manager, store: store)
    second.captureInitialSnapshotIfNeeded()
    let initial = try? XCTUnwrap(second.snapshots.first)
    XCTAssertEqual(initial?.isInitial, true)
    XCTAssertEqual(second.snapshots.count, 1)
    if let initial { await second.restore(initial) }

    XCTAssertEqual(manager.defaults, [zip.identifier: other, sevenZip.identifier: other])
    XCTAssertFalse(second.rows.contains(where: \.isPangoZipDefault))
  }

  @MainActor
  func testStoreKeepsInitialAndTenNewestSnapshots() {
    let store = makeStore()
    let handler = ArchiveAssociationSnapshot.Handler(path: other.path, bundleIdentifier: nil)
    store.captureInitialIfNeeded([zip.identifier: handler], now: Date(timeIntervalSince1970: 0))
    store.captureInitialIfNeeded([:], now: Date(timeIntervalSince1970: 1))
    for index in 1...12 {
      store.add([:], now: Date(timeIntervalSince1970: Double(index * 100)))
    }

    let snapshots = store.snapshots
    XCTAssertEqual(snapshots.count, 11)
    XCTAssertEqual(snapshots.first?.isInitial, true)
    XCTAssertEqual(snapshots.first?.handlers, [zip.identifier: handler])
    XCTAssertEqual(
      snapshots.dropFirst().map { Int($0.createdAt.timeIntervalSince1970) / 100 },
      Array((3...12).reversed()))
  }

  @MainActor
  func testArchiveTypesComeFromDocumentTypesAndAreDeduplicated() {
    let types = ArchiveAssociationsModel.archiveTypes(from: [
      "CFBundleDocumentTypes": [
        ["CFBundleTypeExtensions": ["zip", "7z"]],
        ["CFBundleTypeExtensions": ["zip"]],
      ]
    ])

    XCTAssertEqual(types.map(\.fileExtension), ["zip", "7z"])
    XCTAssertEqual(types.map(\.identifier).count, Set(types.map(\.identifier)).count)
  }
}

@MainActor
private final class FakeArchiveAssociationsManager: ArchiveAssociationsManaging {
  var defaults: [String: URL]
  let identifiers: [URL: String]
  let failingTypes: Set<String>
  private(set) var updatedTypes: [String] = []

  init(
    defaults: [String: URL] = [:], identifiers: [URL: String] = [:], failingTypes: Set<String> = []
  ) {
    self.defaults = defaults
    self.identifiers = identifiers
    self.failingTypes = failingTypes
  }

  func defaultApplication(for typeIdentifier: String) -> URL? {
    defaults[typeIdentifier]
  }

  func setDefaultApplication(at applicationURL: URL, for typeIdentifier: String) async throws {
    updatedTypes.append(typeIdentifier)
    if failingTypes.contains(typeIdentifier) {
      throw NSError(domain: "ArchiveAssociationsTests", code: 1)
    }
    defaults[typeIdentifier] = applicationURL
  }

  func bundleIdentifier(at applicationURL: URL) -> String? { identifiers[applicationURL] }

  func resolveApplication(_ handler: ArchiveAssociationSnapshot.Handler) -> URL? {
    URL(fileURLWithPath: handler.path)
  }
}
