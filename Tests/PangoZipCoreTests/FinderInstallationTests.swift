import XCTest

@testable import PangoZipCore

final class FinderInstallationTests: XCTestCase {
  func testMenuIsUnavailableAfterRemovalOrWhenWorkerIsMissing() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(in: root)
    XCTAssertTrue(FinderInstallation.isAvailable(at: app))
    try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Helpers"))
    XCTAssertFalse(FinderInstallation.isAvailable(at: app))
    try FileManager.default.removeItem(at: app)
    XCTAssertFalse(FinderInstallation.isAvailable(at: app))
  }

  func testMenuIsUnavailableInTrashIncludingSymlinkToTrash() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in [".Trash", ".Trashes/501"] {
      let app = try makeApp(in: root.appendingPathComponent(name))
      XCTAssertFalse(FinderInstallation.isAvailable(at: app))
      let link = root.appendingPathComponent(UUID().uuidString + ".app")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
      XCTAssertFalse(FinderInstallation.isAvailable(at: link))
    }
  }

  func testMenuRejectsUnrelatedBundleAndResolvesContainingApplication() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(in: root, identifier: "app.unrelated.desktop")
    XCTAssertFalse(FinderInstallation.isAvailable(at: app))
    let extensionURL = app.appendingPathComponent("Contents/PlugIns/PangoZipFinderSync.appex")
    XCTAssertEqual(FinderInstallation.applicationURL(for: extensionURL).path, app.path)
  }

  private func makeApp(in root: URL, identifier: String = "app.pangozip.desktop") throws -> URL {
    let manager = FileManager.default
    let app = root.appendingPathComponent("PangoZip.app")
    for path in [
      "Contents/MacOS/PangoZip", "Contents/Helpers/PangoZipWorker.app/Contents/MacOS/PangoZip",
    ] {
      let executable = app.appendingPathComponent(path)
      try manager.createDirectory(
        at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("fixture".utf8).write(to: executable)
      try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    let info = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"],
      format: .xml, options: 0)
    try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
    return app
  }
}
