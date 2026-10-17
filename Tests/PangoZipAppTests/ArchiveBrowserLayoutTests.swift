import AppKit
import PangoZipCore
import Quartz
import SwiftUI
import XCTest

@testable import PangoZipApp

final class ArchiveBrowserLayoutTests: XCTestCase, @unchecked Sendable {
  @MainActor
  func testTableHeaderAndFirstRowStayInsideWindowWithInspector() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("Sample.txt")
    try Data("Preview sample".utf8).write(to: input)
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Engine/7zz")
    let service = ArchiveService(executableURL: engine)
    let archive = try await service.createArchive(
      from: [input], proposedURL: root.appendingPathComponent("Sample.zip"), format: "zip")
    let model = ArchiveBrowserModel(service: service)
    model.open(archive)
    let deadline = Date().addingTimeInterval(5)
    while model.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertNotNil(model.session)
    let host = NSHostingView(
      rootView: ArchiveBrowserView(model: model, integration: FinderIntegrationModel()))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1400, height: 740),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.toolbar = NSToolbar(identifier: "LayoutTest")
    window.toolbarStyle = .unified
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    let outline = try XCTUnwrap(descendant(NSOutlineView.self, in: host))
    XCTAssertEqual(
      outline.tableColumns.filter { !$0.isHidden }.map(\.title),
      ["Имя", "Размер", "В архиве", "Тип", "Изменён", "Метод"])
    let header = try XCTUnwrap(outline.headerView)
    let headerRect = header.convert(header.bounds, to: host)
    let rowRect = outline.convert(outline.rect(ofRow: 0), to: host)
    XCTAssertTrue(host.bounds.contains(headerRect), "Заголовок должен оставаться внутри окна")
    XCTAssertTrue(host.bounds.intersects(rowRect), "Первая строка должна быть видна")
    XCTAssertLessThanOrEqual(
      header.convert(header.bounds, to: nil).maxY, window.contentLayoutRect.maxY,
      "Панель инструментов не должна перекрывать заголовок таблицы")
    model.selectedPaths = ["Sample.txt"]
    let previewDeadline = Date().addingTimeInterval(5)
    while model.previewURL == nil && Date() < previewDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(200))
    let quickLook = try XCTUnwrap(descendant(QLPreviewView.self, in: host))
    for _ in 0..<2 {
      model.togglePreview()
      for _ in 0..<30 {
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertGreaterThanOrEqual(
          quickLook.frame.width, 319, "Quick Look не должен сжиматься до нулевой ширины")
      }
    }
    XCTAssertTrue(
      quickLook === descendant(QLPreviewView.self, in: host),
      "Скрытие и раскрытие должно сохранять тот же Quick Look view")
    let otherInput = root.appendingPathComponent("Other.txt")
    try Data("Another preview sample".utf8).write(to: otherInput)
    let blockArchive = try await service.createArchive(
      from: [input, otherInput], proposedURL: root.appendingPathComponent("Sample.7z"), format: "7z"
    )
    model.open(blockArchive)
    let refreshDeadline = Date().addingTimeInterval(5)
    while model.isBusy && Date() < refreshDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(model.session?.format, "7z")
    XCTAssertTrue(outline.tableColumn(withIdentifier: .init("packed"))?.isHidden == true)
    _ = await model.requestTermination()
  }

  @MainActor
  func testReducedMotionCollapseRestoresContentWidth() async throws {
    _ = NSApplication.shared
    func workspace(_ visible: Bool) -> some View {
      ArchiveSplitView(
        showsPreview: visible, reduceMotion: true, content: Color.clear, preview: Color.clear)
    }
    let host = NSHostingView(rootView: workspace(true))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1400, height: 740),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    let split = try XCTUnwrap(descendant(NSSplitView.self, in: host))
    let content = try XCTUnwrap(split.arrangedSubviews.first)
    let expandedWidth = content.frame.width
    host.rootView = workspace(false)
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(content.frame.width, expandedWidth + 200)
    host.rootView = workspace(true)
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(content.frame.width, expandedWidth, accuracy: 2)
  }

  @MainActor
  func testPreviewToggleAnimatesThroughIntermediateWidths() async throws {
    _ = NSApplication.shared
    func workspace(_ visible: Bool) -> some View {
      ArchiveSplitView(
        showsPreview: visible, reduceMotion: false, content: Color.clear, preview: Color.clear)
    }
    let host = NSHostingView(rootView: workspace(true))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1400, height: 740),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    let split = try XCTUnwrap(descendant(NSSplitView.self, in: host))
    let content = try XCTUnwrap(split.arrangedSubviews.first)
    let expandedWidth = content.frame.width
    let collapsedWidth = split.bounds.width
    for visible in [false, true] {
      host.rootView = workspace(visible)
      var widths: [CGFloat] = []
      for _ in 0..<40 {
        try await Task.sleep(for: .milliseconds(10))
        widths.append(content.frame.width)
      }
      XCTAssertTrue(
        widths.contains { $0 > expandedWidth + 2 && $0 < collapsedWidth - 2 },
        "Переключение должно проходить через промежуточные размеры: \(widths)")
      XCTAssertEqual(
        content.frame.width, visible ? expandedWidth : collapsedWidth, accuracy: 2)
    }
  }

  @MainActor
  private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
  }
}
