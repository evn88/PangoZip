import Foundation
import PangoZipCore
import XCTest

@testable import PangoZipApp

final class ArchivePasswordStoreTests: XCTestCase, @unchecked Sendable {
  @MainActor
  private final class FakePasswords: ArchivePasswordStoring {
    var stored: [String: String] = [:]

    func password(for archive: URL) -> String? { stored[archive.standardizedFileURL.path] }

    func save(_ password: String, for archive: URL) {
      stored[archive.standardizedFileURL.path] = password
    }

    func removeAll() { stored.removeAll() }
  }

  @MainActor
  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "Операция должна завершиться за отведённое время")
  }

  @MainActor
  func testTypedPasswordIsSavedAndUsedOnNextOpen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService()
    let file = root.appendingPathComponent("secret.txt")
    try Data("payload".utf8).write(to: file)
    let archive = try await service.createArchive(
      from: [file], proposedURL: root.appendingPathComponent("secret.7z"), format: "7z",
      password: "correct horse")
    let passwords = FakePasswords()

    // Без сохранённого пароля архив просит его, и после ввода пароль запоминается.
    let first = ArchiveBrowserModel(
      service: service, passwords: passwords, remembersPasswords: { true })
    first.open(archive)
    try await waitUntil { !first.isBusy }
    XCTAssertTrue(first.isPasswordPromptPresented)
    XCTAssertTrue(passwords.stored.isEmpty)
    first.password = "correct horse"
    first.retryWithPassword()
    try await waitUntil { !first.isBusy && first.session != nil }
    XCTAssertEqual(passwords.stored.values.map { $0 }, ["correct horse"])
    await first.cleanup()

    // Следующее открытие обходится без запроса.
    let second = ArchiveBrowserModel(
      service: service, passwords: passwords, remembersPasswords: { false })
    second.open(archive)
    try await waitUntil { !second.isBusy }
    XCTAssertFalse(second.isPasswordPromptPresented)
    XCTAssertEqual(second.session?.entries.map(\.path), ["secret.txt"])
    await second.cleanup()

    // Устаревший сохранённый пароль не мешает: появляется обычный запрос с пустым полем.
    passwords.save("stale", for: archive)
    let third = ArchiveBrowserModel(
      service: service, passwords: passwords, remembersPasswords: { false })
    third.open(archive)
    try await waitUntil { !third.isBusy }
    XCTAssertTrue(third.isPasswordPromptPresented)
    XCTAssertEqual(third.password, "")
    XCTAssertNil(third.session)
    await third.cleanup()
  }
}
