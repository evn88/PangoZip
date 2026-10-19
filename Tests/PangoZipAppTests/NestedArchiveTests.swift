import AppKit
import Foundation
import PangoZipCore
import XCTest

@testable import PangoZipApp

final class NestedArchiveTests: XCTestCase, @unchecked Sendable {
  @MainActor
  func testNestedArchivesRetainParentsAndRestoreSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let file = root.appendingPathComponent("note.txt")
    try Data("nested payload".utf8).write(to: file)
    let zip = try await service.createArchive(
      from: [file], proposedURL: root.appendingPathComponent("inner.zip"), format: "zip")
    let tar = root.appendingPathComponent("middle.tar")
    try makeArchive(engine: engine, arguments: ["a", "-ttar", tar.path, zip.path])
    let outer = try await service.createArchive(
      from: [tar], proposedURL: root.appendingPathComponent("outer.zip"), format: "zip")
    let original = try Data(contentsOf: outer)
    let model = ArchiveBrowserModel(service: service)
    model.togglePreview()
    model.open(outer)
    try await waitUntil { !model.isBusy }
    let parent = try XCTUnwrap(model.session)
    model.selectedPaths = ["middle.tar"]
    model.searchText = "middle"
    model.openSelectedExternally()
    XCTAssertFalse(model.canQueueOperations)
    model.enqueueExtraction(paths: ["middle.tar"], to: root)
    XCTAssertTrue(model.queuedOperations.isEmpty)
    try await waitUntil { !model.isBusy }
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.session?.format, "tar")
    XCTAssertFalse(model.canModify)
    XCTAssertTrue(model.canNavigateBack)
    let tarURL = try XCTUnwrap(model.session?.url)
    XCTAssertTrue(FileManager.default.fileExists(atPath: tarURL.path))
    model.selectedPaths = ["inner.zip"]
    model.openSelectedExternally()
    try await waitUntil { !model.isBusy }
    XCTAssertEqual(model.session?.entries.map(\.path), ["note.txt"])
    let nested = try XCTUnwrap(model.session)
    let materialized = try await service.materialize(
      try XCTUnwrap(nested.entries.first), in: nested)
    XCTAssertEqual(try Data(contentsOf: materialized), Data("nested payload".utf8))
    model.navigateBack()
    try await waitUntil { !model.isBusy }
    XCTAssertEqual(model.selectedPaths, ["inner.zip"])
    model.navigateBack()
    try await waitUntil { !model.isBusy }
    XCTAssertEqual(model.session?.id, parent.id)
    XCTAssertEqual(model.selectedPaths, ["middle.tar"])
    XCTAssertEqual(model.searchText, "middle")
    XCTAssertFalse(model.canNavigateBack)
    XCTAssertTrue(model.canModify)
    XCTAssertEqual(try Data(contentsOf: outer), original)
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: tarURL.path))
  }

  @MainActor
  func testGzipTarNavigationAndClosingFromInside() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("note.txt")
    try Data("gzip payload".utf8).write(to: file)
    let tar = root.appendingPathComponent("files.tar")
    let gzip = root.appendingPathComponent("files.tar.gz")
    try makeArchive(engine: engine, arguments: ["a", "-ttar", tar.path, file.path])
    try makeArchive(engine: engine, arguments: ["a", "-tgzip", gzip.path, tar.path])
    let model = ArchiveBrowserModel(service: ArchiveService(executableURL: engine))
    model.togglePreview()
    model.open(gzip)
    try await waitUntil { !model.isBusy }
    XCTAssertEqual(model.session?.format, "gzip")
    model.selectedPaths = ["files.tar"]
    model.openSelectedExternally()
    try await waitUntil { !model.isBusy }
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.session?.entries.map(\.path), ["note.txt"])
    let temporary = try XCTUnwrap(model.session?.url)
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
    XCTAssertNil(model.session)
    XCTAssertFalse(model.isNestedArchive)
    XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
  }

  @MainActor
  func testInvalidNestedArchivePreservesParentAndPassword() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let invalid = root.appendingPathComponent("invalid.zip")
    try Data("not an archive".utf8).write(to: invalid)
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [invalid], proposedURL: root.appendingPathComponent("parent.zip"), format: "zip")
    let model = ArchiveBrowserModel(service: service)
    model.togglePreview()
    model.open(archive, password: "parent-password")
    try await waitUntil { !model.isBusy }
    let parentID = model.session?.id
    model.selectedPaths = ["invalid.zip"]
    model.openSelectedExternally()
    try await waitUntil { !model.isBusy }
    XCTAssertNotNil(model.errorMessage)
    XCTAssertEqual(model.session?.id, parentID)
    XCTAssertEqual(model.selectedPaths, ["invalid.zip"])
    XCTAssertEqual(model.password, "parent-password")
    XCTAssertFalse(model.isNestedArchive)
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }

  @MainActor
  func testProvidedTarGzipSample() async throws {
    let sample = engine.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("build/files.tar.gz")
    guard FileManager.default.fileExists(atPath: sample.path) else {
      throw XCTSkip("Локальный архив пользователя отсутствует")
    }
    let model = ArchiveBrowserModel(service: ArchiveService(executableURL: engine))
    model.open(sample)
    try await waitUntil { !model.isBusy }
    let parentID = model.session?.id
    let entry = try XCTUnwrap(model.session?.entries.first)
    model.selectedPaths = [entry.path]
    model.openSelectedExternally()
    try await waitUntil { !model.isBusy }
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.session?.format, "tar")
    XCTAssertFalse(try XCTUnwrap(model.session).entries.isEmpty)
    model.navigateBack()
    try await waitUntil { !model.isBusy }
    XCTAssertEqual(model.session?.id, parentID)
    try await waitUntil { !model.isMaterializing && model.previewURL != nil }
    XCTAssertNil(model.errorMessage)
    XCTAssertTrue(FinderSelection.isArchive(try XCTUnwrap(model.previewURL)))
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }

  @MainActor
  func testEncryptedChildKeepsParentPasswordAndWorkingCopies() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("note.txt")
    try Data("original".utf8).write(to: file)
    let child = root.appendingPathComponent("child.7z")
    try makeArchive(
      engine: engine,
      arguments: ["a", "-t7z", "-pchild-password", "-mhe=on", child.path, file.path])
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [file, child], proposedURL: root.appendingPathComponent("parent.zip"), format: "zip")
    let model = ArchiveBrowserModel(service: service)
    model.togglePreview()
    model.open(archive, password: "parent-password")
    try await waitUntil { !model.isBusy }
    let parent = try XCTUnwrap(model.session)
    let entry = try XCTUnwrap(parent.entries.first { $0.path == "note.txt" })
    let edit = try await service.beginEditing(entry, in: parent)
    try model.watchWorkingCopy(edit)
    model.selectedPaths = ["child.7z"]
    model.openSelectedExternally()
    try await waitUntil { !model.isBusy }
    XCTAssertTrue(model.isPasswordPromptPresented)
    XCTAssertEqual(model.session?.id, parent.id)
    model.cancelPasswordPrompt()
    XCTAssertEqual(model.password, "parent-password")
    model.openSelectedExternally()
    try await waitUntil { !model.isBusy }
    model.password = "child-password"
    model.retryWithPassword()
    try await waitUntil { !model.isBusy }
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.session?.format, "7z")
    XCTAssertTrue(model.activeEdits.isEmpty)
    model.navigateBack()
    try await waitUntil { !model.isBusy }
    XCTAssertEqual(model.password, "parent-password")
    XCTAssertEqual(model.activeEdits.map(\.id), [edit.id])
    try Data("updated".utf8).write(to: edit.fileURL)
    await model.autosaveChangedCopies()
    await model.autosaveChangedCopies()
    try await waitUntil { !model.isBusy }
    XCTAssertNil(model.errorMessage)
    let updated = try XCTUnwrap(model.session)
    let updatedEntry = try XCTUnwrap(updated.entries.first { $0.path == "note.txt" })
    let extracted = try await service.materialize(updatedEntry, in: updated)
    XCTAssertEqual(try Data(contentsOf: extracted), Data("updated".utf8))
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }

  @MainActor
  func testCancelledClosingAndReplacementKeepNestedSessionWithDirtyParent() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("note.txt")
    try Data("original".utf8).write(to: file)
    let service = ArchiveService(executableURL: engine)
    let childArchive = try await service.createArchive(
      from: [file], proposedURL: root.appendingPathComponent("child.zip"), format: "zip")
    let archive = try await service.createArchive(
      from: [file, childArchive], proposedURL: root.appendingPathComponent("parent.zip"),
      format: "zip")
    let original = try Data(contentsOf: archive)
    let model = ArchiveBrowserModel(service: service)
    model.togglePreview()
    model.open(archive, password: "parent-password")
    try await waitUntil { !model.isBusy }
    let parent = try XCTUnwrap(model.session)
    let edit = try await service.beginEditing(
      try XCTUnwrap(parent.entries.first { $0.path == "note.txt" }), in: parent)
    try model.watchWorkingCopy(edit)
    model.selectedPaths = ["child.zip"]
    model.openSelectedExternally()
    try await waitUntil { !model.isBusy }
    let child = try XCTUnwrap(model.session)
    model.selectedPaths = ["note.txt"]
    model.searchText = "note"
    model.password = "child-password"
    try Data("unsaved".utf8).write(to: edit.fileURL)

    for replacingArchive in [false, true] {
      let dismiss = dismissNextAlert(with: .alertThirdButtonReturn)
      if replacingArchive {
        model.open(archive)
        try await waitUntil { !model.isBusy }
      } else {
        let closed = await model.requestTermination()
        XCTAssertFalse(closed)
      }
      dismiss.invalidate()
      XCTAssertEqual(model.session?.id, child.id)
      XCTAssertTrue(model.isNestedArchive)
      XCTAssertTrue(model.canNavigateBack)
      XCTAssertEqual(model.selectedPaths, ["note.txt"])
      XCTAssertEqual(model.searchText, "note")
      XCTAssertEqual(model.password, "child-password")
      XCTAssertEqual(try Data(contentsOf: archive), original)
      XCTAssertEqual(try Data(contentsOf: edit.fileURL), Data("unsaved".utf8))
      do {
        let entry = try XCTUnwrap(child.entries.first)
        let url = try await service.materialize(entry, in: child)
        XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8))
      } catch {
        XCTFail("Отмена не должна закрывать вложенный сеанс: \(error)")
      }
    }

    let save = dismissNextAlert(with: .alertFirstButtonReturn)
    let closed = await model.requestTermination()
    save.invalidate()
    XCTAssertTrue(closed)
    XCTAssertNil(model.session)
    XCTAssertFalse(model.isNestedArchive)
    let verification = ArchiveService(executableURL: engine)
    let saved = try await verification.open(archive)
    let savedEntry = try XCTUnwrap(saved.entries.first { $0.path == "note.txt" })
    let savedFile = try await verification.materialize(savedEntry, in: saved)
    XCTAssertEqual(try Data(contentsOf: savedFile), Data("unsaved".utf8))
    await verification.cleanup()
  }

  @MainActor
  private func dismissNextAlert(with response: NSApplication.ModalResponse) -> Timer {
    let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
      MainActor.assumeIsolated {
        if NSApplication.shared.modalWindow != nil {
          NSApplication.shared.stopModal(withCode: response)
        }
      }
    }
    RunLoop.main.add(timer, forMode: .modalPanel)
    return timer
  }

  private var engine: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Engine/7zz")
  }

  private func makeArchive(engine: URL, arguments: [String]) throws {
    let process = Process()
    process.executableURL = engine
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }

  @MainActor
  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "Операция должна завершиться за отведённое время")
  }
}
