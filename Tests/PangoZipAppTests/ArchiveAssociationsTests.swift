import XCTest

@testable import PangoZipApp

final class ArchiveAssociationsTests: XCTestCase, @unchecked Sendable {
  @MainActor
  func testApplySelectionChangesOnlySelectedTypes() async {
    let zip = ArchiveAssociationType(identifier: "public.zip-archive", fileExtension: "zip")
    let sevenZip = ArchiveAssociationType(
      identifier: "org.7-zip.7-zip-archive", fileExtension: "7z")
    let currentApplication = URL(fileURLWithPath: "/Applications/PangoZip.app")
    let otherApplication = URL(fileURLWithPath: "/Applications/Other.app")
    let manager = FakeArchiveAssociationsManager(
      defaults: [
        zip.identifier: otherApplication,
        sevenZip.identifier: currentApplication,
      ], currentApplication: currentApplication)
    let model = ArchiveAssociationsModel(
      types: [zip, sevenZip], manager: manager, applicationURL: currentApplication,
      applicationName: "PangoZip")
    model.selectedTypeIdentifiers = [zip.identifier]

    await model.applySelection()

    XCTAssertEqual(manager.updatedTypes, [zip.identifier])
    XCTAssertEqual(model.rows.first { $0.id == zip.identifier }?.defaultApplicationName, "PangoZip")
    XCTAssertEqual(
      model.rows.first { $0.id == sevenZip.identifier }?.defaultApplicationName, "PangoZip")
    XCTAssertNil(model.errorMessage)
  }

  @MainActor
  func testApplySelectionReportsSystemFailure() async {
    let zip = ArchiveAssociationType(identifier: "public.zip-archive", fileExtension: "zip")
    let manager = FakeArchiveAssociationsManager(failingTypes: [zip.identifier])
    let model = ArchiveAssociationsModel(types: [zip], manager: manager)
    model.selectedTypeIdentifiers = [zip.identifier]

    await model.applySelection()

    XCTAssertEqual(manager.updatedTypes, [zip.identifier])
    XCTAssertTrue(model.errorMessage?.contains("ZIP") == true)
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
  let failingTypes: Set<String>
  let currentApplication: URL
  private(set) var updatedTypes: [String] = []

  init(
    defaults: [String: URL] = [:], failingTypes: Set<String> = [],
    currentApplication: URL = URL(fileURLWithPath: "/Applications/PangoZip.app")
  ) {
    self.defaults = defaults
    self.failingTypes = failingTypes
    self.currentApplication = currentApplication
  }

  func defaultApplication(for typeIdentifier: String) -> URL? {
    defaults[typeIdentifier]
  }

  func setCurrentApplicationAsDefault(for typeIdentifier: String) async throws {
    updatedTypes.append(typeIdentifier)
    if failingTypes.contains(typeIdentifier) {
      throw NSError(domain: "ArchiveAssociationsTests", code: 1)
    }
    defaults[typeIdentifier] = currentApplication
  }
}
