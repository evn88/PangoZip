import XCTest

@testable import PangoZipCore

final class TemporaryWorkspaceTests: XCTestCase {
  func testRecoveryRemovesOrphanedSessionAndTransactionButPreservesActiveWorkspace() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let active = TemporaryWorkspace(base: base)
    try active.ensure()
    var orphan: TemporaryWorkspace? = TemporaryWorkspace(base: base)
    try orphan!.ensure()
    let orphanRoot = orphan!.root
    _ = try orphan!.sessionDirectory(UUID())
    let transaction = try orphan!.transactionDirectory(
      nextTo: base.appendingPathComponent("sample.zip"))
    orphan = nil
    let next = TemporaryWorkspace(base: base)
    try next.ensure()
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphanRoot.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: active.root.path))
    active.cleanup()
    next.cleanup()
    XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
  }
}
