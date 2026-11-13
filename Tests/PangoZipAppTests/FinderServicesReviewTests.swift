import AppKit
import PangoZipCore
import XCTest

@testable import PangoZipApp

final class FinderServicesReviewTests: XCTestCase, @unchecked Sendable {
  /// Стандартное открытие нескольких файлов сохраняет всё выделение в одном запросе для независимых окон.
  @MainActor
  func testMultipleFileURLsAreDeliveredTogetherIncludingRequestsBeforeConfiguration() throws {
    _ = NSApplication.shared
    let urls = [URL(fileURLWithPath: "/tmp/first.zip"), URL(fileURLWithPath: "/tmp/second.7z")]
    let services = FinderServices()
    services.deliverOpenURLs(urls)
    var single: [URL] = []
    var requests: [FinderRequest] = []
    services.configure(
      openArchive: { single.append($0) }, addFiles: { _ in }, finderRequest: { requests.append($0) }
    )
    XCTAssertTrue(single.isEmpty)
    XCTAssertEqual(requests, [try FinderRequest(action: .open, urls: urls)])
    services.deliverOpenURLs([urls[0]])
    XCTAssertEqual(single, [urls[0]])
  }

  /// Каждая служба доставляет запрос своего действия; операции над архивами берут только архивы.
  @MainActor
  func testServicesDeliverFinderRequestsForEachAction() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let archive = root.appendingPathComponent("a.zip")
    let text = root.appendingPathComponent("b.txt")
    for url in [archive, text] { try Data("x".utf8).write(to: url) }
    let services = FinderServices()
    var requests: [FinderRequest] = []
    services.configure(
      openArchive: { _ in }, addFiles: { _ in }, finderRequest: { requests.append($0) })
    let handlers:
      [(
        FinderAction, (NSPasteboard, String?, AutoreleasingUnsafeMutablePointer<NSString?>) -> Void
      )] = [
        (.extractHere, services.extractHereService),
        (.extract, services.extractToFoldersService),
        (.createZip, services.createZipService),
        (.create7z, services.create7zService),
        (.test, services.testArchiveService),
      ]
    for (action, handler) in handlers {
      let board = NSPasteboard(name: .init("app.pangozip.tests." + UUID().uuidString))
      defer { board.releaseGlobally() }
      board.clearContents()
      board.writeObjects([archive as NSURL, text as NSURL])
      var failure: NSString?
      handler(board, nil, &failure)
      XCTAssertNil(failure, action.rawValue)
    }
    XCTAssertEqual(requests.map(\.action), handlers.map(\.0))
    for request in requests {
      let readsArchives = [.extractHere, .extract, .test].contains(request.action)
      XCTAssertEqual(request.urls.count, readsArchives ? 1 : 2, request.action.rawValue)
    }
  }

  /// Без архива в выделении службы распаковки и проверки возвращают ошибку и ничего не запускают.
  @MainActor
  func testArchiveServicesRejectSelectionWithoutArchives() throws {
    _ = NSApplication.shared
    let services = FinderServices()
    var requests: [FinderRequest] = []
    services.configure(
      openArchive: { _ in }, addFiles: { _ in }, finderRequest: { requests.append($0) })
    let board = NSPasteboard(name: .init("app.pangozip.tests." + UUID().uuidString))
    defer { board.releaseGlobally() }
    board.clearContents()
    board.writeObjects([URL(fileURLWithPath: "/tmp/plain.txt") as NSURL])
    var failure: NSString?
    services.extractHereService(board, userData: nil, error: &failure)
    XCTAssertNotNil(failure)
    failure = nil
    services.testArchiveService(board, userData: nil, error: &failure)
    XCTAssertNotNil(failure)
    XCTAssertTrue(requests.isEmpty)
  }

  /// Объявленные в Info.plist службы совпадают с обработчиками и ограничены контекстом Finder.
  func testInfoPlistServicesMatchHandlers() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
    let info = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let services = try XCTUnwrap(info["NSServices"] as? [[String: Any]])
    XCTAssertEqual(
      services.compactMap { $0["NSMessage"] as? String },
      [
        "openArchiveService", "addToArchiveService", "extractHereService",
        "extractToFoldersService", "createZipService", "create7zService", "testArchiveService",
      ])
    let archiveOnly: Set = [
      "openArchiveService", "extractHereService", "extractToFoldersService", "testArchiveService",
    ]
    for service in services {
      let message = try XCTUnwrap(service["NSMessage"] as? String)
      XCTAssertEqual(
        (service["NSRequiredContext"] as? [String: String])?["NSApplicationIdentifier"],
        "com.apple.finder", message)
      XCTAssertEqual(
        service["NSSendTypes"] as? [String], ["public.file-url", "NSFilenamesPboardType"], message)
      let menu = try XCTUnwrap((service["NSMenuItem"] as? [String: String])?["default"])
      XCTAssertFalse(menu.isEmpty)
      // «Открыть архив» остаётся без фильтра типов, как и раньше.
      if archiveOnly.contains(message) && message != "openArchiveService" {
        XCTAssertEqual(service["NSSendFileTypes"] as? [String], ["public.archive"], message)
      } else {
        XCTAssertNil(service["NSSendFileTypes"], message)
      }
    }
  }

  /// Отмена ввода пароля убирает ошибку и недействующую кнопку повтора, освобождая основное окно.
  @MainActor
  func testCancellingPasswordPromptClearsRetryError() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let input = root.appendingPathComponent("File.txt")
    try Data("private test content".utf8).write(to: input)
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [input], proposedURL: root.appendingPathComponent("encrypted.7z"), format: "7z",
      password: "test-password")
    let model = ArchiveBrowserModel(service: service)
    model.open(archive)
    let deadline = Date().addingTimeInterval(5)
    while model.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(model.isPasswordPromptPresented)
    XCTAssertNotNil(model.errorMessage)
    model.cancelPasswordPrompt()
    XCTAssertFalse(model.isPasswordPromptPresented)
    XCTAssertNil(model.errorMessage)
    XCTAssertTrue(model.canAct)
    let terminated = await model.requestTermination()
    XCTAssertTrue(terminated)
  }
}
