import AppKit
import SwiftUI

/// Остров для операций из контекстного меню Finder: та же строка с ходом, что и после броска.
@MainActor
final class OperationIsland {
  let model = DropIslandModel()
  private var panel: NSPanel?
  private var frame: NSRect?
  private var hideTask: Task<Void, Never>?

  var isVisible: Bool { model.phase != .hidden }

  /// Показывает или обновляет строку операции; место выбирается один раз при первом показе.
  func show(_ phase: DropIslandModel.Phase, title: String, subtitle: String, fraction: Double?) {
    hideTask?.cancel()
    model.title = title
    model.subtitle = subtitle
    model.fraction = fraction
    guard model.phase != phase else { return }
    let panel = self.panel ?? makePanel()
    self.panel = panel
    let frame = self.frame ?? placeIsland()
    self.frame = frame
    panel.setFrame(
      frame.insetBy(dx: -DropIslandView.margin, dy: -DropIslandView.margin), display: true)
    panel.orderFrontRegardless()
    model.phase = phase
  }

  /// Убирает остров; окно закрывается после анимации исчезновения.
  func hide() {
    guard isVisible else { return }
    model.phase = .hidden
    hideTask?.cancel()
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      self?.panel?.orderOut(nil)
    }
  }

  /// Место острова берётся из настроек основного приложения: у фонового процесса свой домен.
  private func placeIsland() -> NSRect {
    let defaults = UserDefaults(suiteName: "app.pangozip.desktop") ?? .standard
    let placement =
      DropIslandPlacement(rawValue: defaults.string(forKey: DropIslandSettings.placementKey) ?? "")
      ?? .top
    model.placement = placement
    let mouse = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    let visible = screen.visibleFrame
    let size = DropIslandPlacement.pillSize
    switch placement {
    case .top:
      return NSRect(
        x: visible.midX - size.width / 2, y: visible.maxY - 6 - size.height, width: size.width,
        height: size.height)
    case .edge:
      return NSRect(
        x: visible.maxX - 8 - size.width, y: visible.midY - size.height / 2, width: size.width,
        height: size.height)
    case .cursor:
      // Строка встаёт над курсором, где только что было меню, но целиком в пределах экрана.
      let x = min(
        max(mouse.x, visible.minX + size.width / 2 + 12), visible.maxX - size.width / 2 - 12)
      let y = min(
        max(mouse.y + 70, visible.minY + size.height / 2 + 12),
        visible.maxY - size.height / 2 - 12)
      return NSRect(
        x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height)
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .statusBar
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    let hosting = NSHostingView(rootView: DropIslandView(model: model))
    hosting.sizingOptions = []
    panel.contentView = hosting
    return panel
  }
}
