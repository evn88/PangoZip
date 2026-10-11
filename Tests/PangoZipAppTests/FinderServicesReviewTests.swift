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
