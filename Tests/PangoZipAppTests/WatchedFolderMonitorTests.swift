import PangoZipCore
import XCTest

@testable import PangoZipApp

final class WatchedFolderMonitorTests: XCTestCase, @unchecked Sendable {
  /// Фоновый режим нужен только при наличии включённых правил.
  @MainActor
  func testBackgroundModeDependsOnEnabledRules() {
    XCTAssertFalse(WatchedFolderMonitor.isActive(rules: []))
    XCTAssertFalse(
      WatchedFolderMonitor.isActive(rules: [WatchedFolderRule(folderPath: "/a", isEnabled: false)]))
    XCTAssertTrue(
      WatchedFolderMonitor.isActive(rules: [
        WatchedFolderRule(folderPath: "/a", isEnabled: false),
        WatchedFolderRule(folderPath: "/b"),
      ]))
  }

  /// Запись журнала подставляет имя архива в локализованный текст.
  func testEventTextContainsArchiveName() {
    let event = WatchedFolderEvent(date: Date(), archiveName: "data.zip", kind: .needsPassword)
    XCTAssertTrue(event.text.contains("data.zip"))
  }
}
