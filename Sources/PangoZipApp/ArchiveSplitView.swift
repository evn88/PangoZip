import AppKit
import SwiftUI

struct ArchiveSplitView<Content: View, Preview: View>: NSViewControllerRepresentable {
  let showsPreview: Bool
  let reduceMotion: Bool
  let content: Content
  let preview: Preview

  func makeCoordinator() -> Coordinator { Coordinator(content: content, preview: preview) }

  func makeNSViewController(context: Context) -> NSSplitViewController {
    let controller = NSSplitViewController()
    controller.splitView.isVertical = true
    controller.splitView.dividerStyle = .thin
    controller.splitView.autosaveName = "ArchivePreviewSplit"
    let main = NSSplitViewItem(viewController: context.coordinator.content)
    main.minimumThickness = 760
    // Режим inspector добавляет подложку titlebar поверх содержимого на macOS 27.
    let inspector = NSSplitViewItem(viewController: context.coordinator.preview)
    inspector.minimumThickness = 320
    inspector.maximumThickness = 460
    inspector.preferredThicknessFraction = 0.25
    inspector.automaticMaximumThickness = 360
    inspector.holdingPriority = .defaultHigh
    inspector.canCollapse = false
    inspector.canCollapseFromWindowResize = false
    inspector.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
    inspector.isCollapsed = !showsPreview
    controller.addSplitViewItem(main)
    controller.addSplitViewItem(inspector)
    return controller
  }

  func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
    context.coordinator.content.rootView = content
    context.coordinator.preview.rootView = preview
    let inspector = controller.splitViewItems[1]
    guard inspector.isCollapsed == showsPreview else { return }
    if reduceMotion {
      inspector.isCollapsed = !showsPreview
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        inspector.animator().isCollapsed = !showsPreview
      }
    }
  }

  @MainActor
  final class Coordinator {
    let content: NSHostingController<Content>
    let preview: NSHostingController<Preview>

    init(content: Content, preview: Preview) {
      self.content = NSHostingController(rootView: content)
      self.preview = NSHostingController(rootView: preview)
      // Размеры задаёт NSSplitView, иначе hosting-контроллеры запускают обратный пересчёт окна.
      self.content.sizingOptions = []
      self.preview.sizingOptions = []
      // Внешний SwiftUI-контейнер уже исключил toolbar из рабочей области.
      self.content.safeAreaRegions = []
      self.preview.safeAreaRegions = []
    }
  }
}
