import PangoZipCore
import XCTest

final class DropIslandPlanTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Other"), withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  /// Создаёт настоящий файл: признак архива проверяется по объекту на диске.
  private func file(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try Data("x".utf8).write(to: url)
    return url.standardizedFileURL
  }

  func testFilesFromOneFolderAreCompressedNextToThem() throws {
    let urls = [try file("A.txt"), try file("B.txt")]
    let plan = try XCTUnwrap(DropIslandPlan(urls: urls, optionPressed: false, defaultFolder: nil))
    XCTAssertEqual(plan.action, .compress)
    XCTAssertEqual(plan.destination, .directory(root.standardizedFileURL))
    XCTAssertEqual(plan.resultName(format: "zip"), root.lastPathComponent + ".zip")
  }

  func testFilesFromDifferentFoldersAskForLocation() throws {
    let urls = [try file("A.txt"), try file("Other/B.txt")]
    let plan = try XCTUnwrap(DropIslandPlan(urls: urls, optionPressed: false, defaultFolder: nil))
    XCTAssertEqual(plan.destination, .ask)
  }

  func testDefaultFolderReplacesQuestionUnlessOptionIsPressed() throws {
    let urls = [try file("A.txt"), try file("Other/B.txt")]
    let folder = URL(fileURLWithPath: "/tmp/Archives")
    let plain = try XCTUnwrap(
      DropIslandPlan(urls: urls, optionPressed: false, defaultFolder: folder))
    XCTAssertEqual(plain.destination, .directory(folder))
    let option = try XCTUnwrap(
      DropIslandPlan(urls: urls, optionPressed: true, defaultFolder: folder))
    XCTAssertEqual(option.destination, .ask)
  }

  func testArchiveIsExtractedAndOptionCompressesItAgain() throws {
    let archive = try file("Report.zip")
    let extract = try XCTUnwrap(
      DropIslandPlan(urls: [archive], optionPressed: false, defaultFolder: nil))
    XCTAssertEqual(extract.action, .extract)
    XCTAssertEqual(extract.resultName(format: "zip"), "Report")
    let compress = try XCTUnwrap(
      DropIslandPlan(urls: [archive], optionPressed: true, defaultFolder: nil))
    XCTAssertEqual(compress.action, .compress)
    XCTAssertEqual(compress.destination, .directory(root.standardizedFileURL))
    XCTAssertEqual(compress.resultName(format: "zip"), "Report_2.zip")
  }

  func testArchiveMixedWithFilesIsCompressed() throws {
    let urls = [try file("Report.zip"), try file("A.txt")]
    let plan = try XCTUnwrap(DropIslandPlan(urls: urls, optionPressed: false, defaultFolder: nil))
    XCTAssertEqual(plan.action, .compress)
    XCTAssertFalse(plan.containsOnlyArchives)
  }

  func testEmptySelectionHasNoPlan() {
    XCTAssertNil(DropIslandPlan(urls: [], optionPressed: false, defaultFolder: nil))
  }
}
