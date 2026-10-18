import AppKit
import PangoZipCore
import XCTest

@testable import PangoZipApp

final class ArchiveColumnsTests: XCTestCase, @unchecked Sendable {
  @MainActor
  func testTechnicalColumnsDisplayOriginalMetadataAndMissingValues() async throws {
    _ = NSApplication.shared
    let entries = try ArchiveListing.parse(
      """
      Path = details
      Size = 5
      Accessed = 2026-10-11 10:20:30
      Attributes = A lrwxrwxrwx
      Host OS = Unix
      Version = 20
      Volume Index = 0
      Offset = 32
      Block = 0
      Symbolic Link = ../target
      Hard Link = docs/target
      Comment = note = value
      User ID = 501
      Group ID = 20
      Characteristics = UTF8
      Alternate Stream = -

      Path = missing
      Size = 0

      """)
    let model = ArchiveBrowserModel()
    await model.apply(
      ArchiveSession(
        url: URL(fileURLWithPath: "/tmp/technical-columns.zip"), entries: entries,
        roots: try ArchiveListing.tree(from: entries)))
    let view = ArchiveOutlineView(model: model)
    let coordinator = view.makeCoordinator()
    let outline = NSOutlineView()
    outline.dataSource = coordinator
    outline.delegate = coordinator
    coordinator.outline = outline
    coordinator.update(view)
    let details = coordinator.outlineView(outline, child: 0, ofItem: nil)
    let missing = coordinator.outlineView(outline, child: 1, ofItem: nil)
    let expected = [
      ("accessed", "2026-10-11 10:20:30"), ("attributes", "A lrwxrwxrwx"), ("hostOS", "Unix"),
      ("version", "20"), ("volumeIndex", "0"), ("offset", "32"), ("block", "0"),
      ("symbolicLink", "../target"), ("hardLink", "docs/target"), ("comment", "note = value"),
      ("userID", "501"), ("groupID", "20"),
      ("otherMetadata", "Alternate Stream=-; Characteristics=UTF8"),
    ]
    for (id, value) in expected {
      XCTAssertTrue(ArchiveColumn.allCases.contains { $0.rawValue == id }, id)
      let column = NSTableColumn(identifier: .init(id))
      for (item, expectedValue) in [(details, value), (missing, "—")] {
        let cell = try XCTUnwrap(
          coordinator.outlineView(outline, viewFor: column, item: item) as? NSTableCellView)
        XCTAssertEqual(cell.textField?.stringValue, expectedValue, id)
        if id == "otherMetadata" { XCTAssertEqual(cell.toolTip, expectedValue) }
      }
    }
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }

  @MainActor
  func testNativeColumnMenuTogglesMetadataAndKeepsChoicesAcrossArchiveRefreshes() async throws {
    _ = NSApplication.shared
    let suiteName = "ArchiveColumnsTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = ArchiveColumnSettings(defaults: defaults)
    let model = ArchiveBrowserModel()
    let view = ArchiveOutlineView(model: model, columnSettings: settings)
    let coordinator = view.makeCoordinator()
    let outline = NSOutlineView()
    coordinator.outline = outline
    coordinator.configureColumns(in: outline)
    coordinator.update(view)
    XCTAssertEqual(
      outline.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue),
      ["name", "size", "kind", "compression", "modified"])
    let header = try XCTUnwrap(outline.headerView)
    let menu = try XCTUnwrap(header.menu(for: NSEvent()))
    let owner = try XCTUnwrap(menu.items.first { $0.representedObject as? String == "owner" })
    XCTAssertEqual(owner.state, .off)
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(owner.action), to: owner.target, from: owner))
    XCTAssertFalse(try XCTUnwrap(outline.tableColumn(withIdentifier: .init("owner"))).isHidden)
    coordinator.update(view)
    XCTAssertTrue(ArchiveColumnSettings(defaults: defaults).isVisible(.owner))
    XCTAssertFalse(try XCTUnwrap(outline.tableColumn(withIdentifier: .init("owner"))).isHidden)
    let name = try XCTUnwrap(menu.items.first { $0.representedObject as? String == "name" })
    XCTAssertFalse(name.isEnabled)
    settings.setVisible(true, for: .packed)
    settings.setVisible(true, for: .method)
    let entries = [ArchiveEntry(path: "file-without-packed-metadata", size: 20)]
    await model.apply(
      ArchiveSession(
        url: URL(fileURLWithPath: "/tmp/refreshed-columns.zip"), entries: entries,
        roots: try ArchiveListing.tree(from: entries)))
    coordinator.update(view)
    XCTAssertFalse(try XCTUnwrap(outline.tableColumn(withIdentifier: .init("packed"))).isHidden)
    XCTAssertFalse(try XCTUnwrap(outline.tableColumn(withIdentifier: .init("method"))).isHidden)
    let reset = try XCTUnwrap(menu.items.last)
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(reset.action), to: reset.target, from: reset))
    XCTAssertEqual(settings.visibleColumns, [.name, .size, .kind, .compression, .modified])
    XCTAssertTrue(try XCTUnwrap(outline.tableColumn(withIdentifier: .init("owner"))).isHidden)
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }

  @MainActor
  func testOptionalCellsShowArchiveMetadataAndFullFolderCountsDuringSearch() async throws {
    _ = NSApplication.shared
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let entries = [
      ArchiveEntry(path: "folder", isDirectory: true),
      ArchiveEntry(
        path: "folder/a", size: 4, isSymbolicLink: true, createdAt: created,
        permissions: "-rw-r--r--", owner: "alice", group: "staff", isEncrypted: true,
        checksum: "1234ABCD", method: "LZMA2", packedSize: 2),
      ArchiveEntry(path: "folder/nested/b", size: 8, packedSize: 3),
      ArchiveEntry(path: "folder/empty", isDirectory: true),
    ]
    let model = ArchiveBrowserModel()
    await model.apply(
      ArchiveSession(
        url: URL(fileURLWithPath: "/tmp/columns.zip"), entries: entries,
        roots: try ArchiveListing.tree(from: entries)))
    let deadline = Date().addingTimeInterval(5)
    while model.areFolderDetailsLoading && Date() < deadline { await Task.yield() }
    model.searchText = "folder"
    let view = ArchiveOutlineView(model: model)
    let coordinator = view.makeCoordinator()
    let outline = ColumnRecordingOutlineView()
    for column in ArchiveColumn.allCases {
      outline.addTableColumn(NSTableColumn(identifier: .init(column.rawValue)))
    }
    outline.dataSource = coordinator
    outline.delegate = coordinator
    coordinator.outline = outline
    coordinator.update(view)
    let folder = coordinator.outlineView(outline, child: 0, ofItem: nil)
    let file = coordinator.outlineView(outline, child: 1, ofItem: nil)
    func value(_ column: ArchiveColumn, item: Any) throws -> String {
      let cell = try XCTUnwrap(
        coordinator.outlineView(
          outline, viewFor: outline.tableColumn(withIdentifier: .init(column.rawValue)),
          item: item) as? NSTableCellView)
      return try XCTUnwrap(cell.textField).stringValue
    }
    XCTAssertEqual(try value(.path, item: file), "folder/a")
    XCTAssertEqual(try value(.permissions, item: file), "-rw-r--r--")
    XCTAssertEqual(try value(.owner, item: file), "alice")
    XCTAssertEqual(try value(.group, item: file), "staff")
    XCTAssertEqual(try value(.checksum, item: file), "1234ABCD")
    XCTAssertEqual(try value(.encrypted, item: file), L10n.tr("Да"))
    XCTAssertEqual(try value(.specialFile, item: file), L10n.tr("Да"))
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    XCTAssertEqual(try value(.created, item: file), formatter.string(from: created))
    XCTAssertEqual(try value(.fileCount, item: folder), "2")
    XCTAssertEqual(try value(.folderCount, item: folder), "2")
    XCTAssertEqual(try value(.fileCount, item: file), "—")
    XCTAssertEqual(try value(.folderCount, item: file), "—")
    XCTAssertEqual(try value(.owner, item: folder), "—")
    XCTAssertEqual(try value(.encrypted, item: folder), L10n.tr("Нет"))
    XCTAssertEqual(try value(.specialFile, item: folder), L10n.tr("Нет"))
    XCTAssertEqual(try value(.created, item: folder), "—")
    let refreshed = try XCTUnwrap(outline.reloadedColumns)
    XCTAssertTrue(
      refreshed.contains(
        try XCTUnwrap(outline.tableColumns.firstIndex { $0.identifier.rawValue == "fileCount" })))
    XCTAssertTrue(
      refreshed.contains(
        try XCTUnwrap(outline.tableColumns.firstIndex { $0.identifier.rawValue == "folderCount" })))
    let closed = await model.requestTermination()
    XCTAssertTrue(closed)
  }

  @MainActor
  func testColumnsDefaultToRequestedSetAndPersistChoicesWithoutHidingName() throws {
    let suiteName = "ArchiveColumnsTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = ArchiveColumnSettings(defaults: defaults)
    XCTAssertEqual(settings.visibleColumns, [.name, .size, .kind, .compression, .modified])
    settings.setVisible(true, for: .owner)
    settings.setVisible(false, for: .kind)
    settings.setVisible(false, for: .name)
    let restored = ArchiveColumnSettings(defaults: defaults)
    XCTAssertTrue(restored.isVisible(.owner))
    XCTAssertFalse(restored.isVisible(.kind))
    XCTAssertTrue(restored.isVisible(.name))
    restored.reset()
    XCTAssertEqual(
      ArchiveColumnSettings(defaults: defaults).visibleColumns,
      [.name, .size, .kind, .compression, .modified])
  }
}

@MainActor
private final class ColumnRecordingOutlineView: NSOutlineView {
  var reloadedColumns: IndexSet?

  override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
    reloadedColumns = columnIndexes
    super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
  }
}
