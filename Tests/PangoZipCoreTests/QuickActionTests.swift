import XCTest

@testable import PangoZipCore

final class QuickActionTests: XCTestCase {
  /// Идентификаторы и пути соответствуют plist-файлам расширений и не пересекаются.
  func testBundleMetadataMatchesExtensionPlists() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    for (action, file, mode) in [
      (QuickAction.extractHere, "Info-Extract.plist", "extractHere"),
      (QuickAction.createZip, "Info-Zip.plist", "createZip"),
    ] {
      let data = try Data(contentsOf: root.appendingPathComponent("QuickActionExtension/\(file)"))
      let info = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
      XCTAssertEqual(info["CFBundleIdentifier"] as? String, action.bundleIdentifier)
      XCTAssertEqual(info["CFBundleExecutable"] as? String, QuickAction.executableName)
      XCTAssertEqual(info[QuickAction.infoKey] as? String, mode)
      XCTAssertEqual(action.rawValue, mode)
      XCTAssertTrue(action.bundlePath.contains(String(info["CFBundleName"] as? String ?? "?")))
      let extensionInfo = try XCTUnwrap(info["NSExtension"] as? [String: Any])
      XCTAssertEqual(
        extensionInfo["NSExtensionPointIdentifier"] as? String, QuickAction.extensionPoint)
      let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
      XCTAssertEqual(attributes["NSExtensionServiceAllowsFinderPreviewItem"] as? Bool, true)
      XCTAssertNotNil(attributes["NSExtensionServiceRoleType"])
      XCTAssertNotNil(attributes["NSExtensionActivationRule"])
    }
    XCTAssertEqual(Set(QuickAction.allCases.map(\.bundleIdentifier)).count, 2)
  }

  /// Распаковка берёт только архивы из смешанного выделения, упаковка — всё выделение.
  func testRequestsReuseFinderSelectionRules() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let archive = root.appendingPathComponent("a.zip")
    let text = root.appendingPathComponent("b.txt")
    for url in [archive, text] { try Data("x".utf8).write(to: url) }
    let extract = try QuickAction.extractHere.request(for: [archive, text])
    XCTAssertEqual(extract.action, .extractHere)
    XCTAssertEqual(extract.urls, [archive.standardizedFileURL])
    let zip = try QuickAction.createZip.request(for: [archive, text])
    XCTAssertEqual(zip.action, .createZip)
    XCTAssertEqual(zip.urls.count, 2)
    XCTAssertThrowsError(try QuickAction.extractHere.request(for: [text]))
    XCTAssertThrowsError(try QuickAction.createZip.request(for: []))
  }

  /// Элемент NSItemProvider может прийти как URL, NSURL или данные; нелокальные адреса отклоняются.
  func testFileURLExtraction() {
    let file = URL(fileURLWithPath: "/tmp/a.zip")
    XCTAssertEqual(QuickAction.fileURL(from: file), file)
    XCTAssertEqual(QuickAction.fileURL(from: file as NSURL), file)
    XCTAssertEqual(QuickAction.fileURL(from: file.dataRepresentation), file)
    XCTAssertNil(QuickAction.fileURL(from: URL(string: "https://example.com/a.zip")))
    XCTAssertNil(QuickAction.fileURL(from: "text"))
    XCTAssertNil(QuickAction.fileURL(from: nil))
  }

  /// Расширения комплекта распознаются по идентификатору, чужие — нет.
  func testOwnExtensionIdentifiers() {
    XCTAssertTrue(FinderInstallation.isOwnExtensionIdentifier("app.pangozip.desktop.finder"))
    for action in QuickAction.allCases {
      XCTAssertTrue(FinderInstallation.isOwnExtensionIdentifier(action.bundleIdentifier))
    }
    XCTAssertFalse(FinderInstallation.isOwnExtensionIdentifier("app.other.quickaction.zip"))
    XCTAssertFalse(FinderInstallation.isOwnExtensionIdentifier(nil))
  }
}
