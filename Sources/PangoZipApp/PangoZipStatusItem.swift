import AppKit
import Combine
import OSLog
import PangoZipCore
import SwiftUI

/// Единственный значок PangoZip в строке меню. Без операций это панголин с меню программы,
/// а во время операции рядом с панголином появляются кольцо хода, процент и оставшееся
/// время. Ход виден в том же значке, что и сама программа, а не отдельным значком где-то
/// сбоку. Нажатие открывает карточку с паузой и отменой, двойное нажатие — окно подробностей,
/// правая кнопка — меню программы.
@MainActor
final class PangoZipStatusItem: NSObject {
  static let shared = PangoZipStatusItem()

  /// Показывать значок без операций: остров или слежение за папками держат программу в фоне.
  var showsWhenIdle: () -> Bool = { false }
  /// Меню программы; nil — меню нет, как у фонового процесса Finder.
  var makeMenu: (() -> NSMenu)?

  private var item: NSStatusItem?
  private var cards: [ProgressCardModel] = []
  private var subscriptions: [ObjectIdentifier: AnyCancellable] = [:]
  private var panel: NSPanel?
  private var hosting: NSHostingView<ProgressCardStack>?
  private let logger = Logger(subsystem: "app.pangozip.desktop", category: "menubar")
  private var monitors: [Any] = []
  private var renderedKey: RingImage.Key?
  private var renderedTitle: String?
  private var renderScheduled = false
  /// Ширина значка за операцию только растёт: соседние значки не скачут, когда «5 мин»
  /// сменяется на «4 мин» или появляется оценка времени.
  private var settledWidth: CGFloat = 0
  fileprivate let details = OperationDetailsWindow()

  /// Операция, которую показывает значок: последняя из ушедших в строку меню.
  var current: ProgressCardModel? { cards.last }

  func attach(_ card: ProgressCardModel) {
    guard !cards.contains(where: { $0 === card }) else { return }
    cards.append(card)
    subscriptions[ObjectIdentifier(card)] = card.objectWillChange.sink { [weak self] _ in
      MainActor.assumeIsolated { self?.scheduleRender() }
    }
    cardChanged()
  }

  func detach(_ card: ProgressCardModel) {
    guard let index = cards.firstIndex(where: { $0 === card }) else { return }
    cards.remove(at: index)
    subscriptions[ObjectIdentifier(card)] = nil
    cardChanged()
  }

  /// Ставит или убирает значок по настройкам; вызывается и при их смене.
  func update() {
    let visible = !cards.isEmpty || showsWhenIdle()
    if visible, item == nil {
      logger.notice("Status item shown, operations: \(self.cards.count, privacy: .public)")
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      // Место значка, куда его перетащили с ⌘, запоминается между запусками.
      item.autosaveName = "PangoZip"
      item.button?.target = self
      item.button?.action = #selector(buttonPressed)
      item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
      item.button?.imagePosition = .imageLeading
      self.item = item
      renderedKey = nil
      renderedTitle = nil
    } else if !visible, let item {
      closeCard()
      NSStatusBar.system.removeStatusItem(item)
      self.item = nil
    }
    render()
  }

  private func cardChanged() {
    if cards.isEmpty {
      settledWidth = 0
      closeCard()
    } else {
      hosting?.rootView = cardStack()
      if panel?.isVisible == true { placeCard() }
    }
    update()
  }

  private func scheduleRender() {
    // objectWillChange приходит до записи, по разу на каждое поле: рисуем один раз после всех.
    guard !renderScheduled else { return }
    renderScheduled = true
    Task { @MainActor in
      self.renderScheduled = false
      self.render()
    }
  }

  private func render() {
    guard let item, let button = item.button else { return }
    guard let card = current else {
      if renderedKey != nil || button.image == nil {
        button.image = PangolinGlyph.sized(18)
        button.attributedTitle = NSAttributedString()
        renderedKey = nil
        renderedTitle = nil
        item.length = NSStatusItem.variableLength
      }
      button.toolTip = "PangoZip"
      button.setAccessibilityLabel("PangoZip")
      return
    }
    let key = RingImage.Key(card: card)
    if key != renderedKey {
      renderedKey = key
      button.image = RingImage.withPangolin(key)
    }
    let title = card.menuBarTitle
    if title != renderedTitle {
      renderedTitle = title
      let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
      button.attributedTitle = NSAttributedString(
        string: title.isEmpty ? "" : " " + title, attributes: [.font: font])
      if card.state == .done {
        settledWidth = 0
        item.length = NSStatusItem.variableLength
      } else {
        // Ширина считается по картинке и тексту: fittingSize кнопки не учитывал текст,
        // и процент со временем обрезались.
        let needed = ceil(
          (button.image?.size.width ?? 0) + button.attributedTitle.size().width + 12)
        settledWidth = max(settledWidth, needed)
        if item.length != settledWidth { item.length = settledWidth }
      }
    }
    if panel?.isVisible == true { placeCard() }
    button.toolTip = card.title
    button.setAccessibilityLabel(
      ["PangoZip", card.title, card.stage, card.state == .working ? card.timeLine : ""]
        .filter { !$0.isEmpty }.joined(separator: ", "))
  }

  // MARK: - Нажатия

  @objc private func buttonPressed() {
    let event = NSApp.currentEvent
    let wantsMenu =
      event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
    guard let card = current, !wantsMenu else {
      showMenu()
      return
    }
    if (event?.clickCount ?? 1) >= 2 {
      // Первое нажатие уже открыло карточку: двойное меняет её на окно подробностей.
      closeCard()
      details.show(card)
    } else if panel?.isVisible == true {
      closeCard()
    } else {
      openCard()
    }
  }

  private func showMenu() {
    guard let item, let menu = makeMenu?() else { return }
    closeCard()
    item.menu = menu
    item.button?.performClick(nil)
    item.menu = nil
  }

  // MARK: - Карточка

  /// Карточка — собственная неактивирующая панель, как и остров: нажатия на кнопки
  /// не выводят окна PangoZip поверх чужих программ.
  fileprivate func openCard() {
    guard current != nil else { return }
    let panel = self.panel ?? makePanel()
    self.panel = panel
    hosting?.rootView = cardStack()
    placeCard()
    panel.orderFrontRegardless()
    // Нажатие мимо карточки закрывает её, как меню; нажатие на сам значок обработает buttonPressed.
    if let global = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown],
      handler: { [weak self] _ in MainActor.assumeIsolated { self?.closeCard() } })
    {
      monitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown],
      handler: { [weak self] event in
        let number = event.windowNumber
        MainActor.assumeIsolated {
          guard let self else { return }
          let own = [self.panel?.windowNumber, self.item?.button?.window?.windowNumber]
          if !own.contains(number) { self.closeCard() }
        }
        return event
      })
    {
      monitors.append(local)
    }
  }

  /// Ставит карточку под значком. Размер берётся у SwiftUI-содержимого: у панели без
  /// размера системное стекло сжималось в маленькую «капельку».
  private func placeCard() {
    guard let panel, let hosting, let button = item?.button, let buttonWindow = button.window
    else { return }
    var size = hosting.intrinsicContentSize
    if size.width <= 1 || size.height <= 1 || size.width == NSView.noIntrinsicMetric {
      size = hosting.fittingSize
    }
    if size.width <= 1 || size.height <= 1 { size = NSSize(width: 320, height: 150) }
    let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
    let visible = screen.visibleFrame
    let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
    let frame = NSRect(
      x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height)
    if panel.frame != frame { panel.setFrame(frame, display: true) }
    hosting.frame = panel.contentView?.bounds ?? NSRect(origin: .zero, size: size)
  }

  private func closeCard() {
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors.removeAll()
    panel?.orderOut(nil)
  }

  /// Все операции в строке меню, новая сверху: одна не прячет другую.
  private func cardStack() -> ProgressCardStack {
    ProgressCardStack(
      cards: cards.reversed(), close: { [weak self] in self?.closeCard() },
      details: { [weak self] card in self?.details.show(card) })
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 150),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .popUpMenu
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    let hosting = NSHostingView(rootView: cardStack())
    hosting.sizingOptions = [.intrinsicContentSize]
    hosting.autoresizingMask = [.width, .height]
    self.hosting = hosting
    // Системное стекло Liquid Glass, как у меню и панелей macOS: прозрачность и цвет
    // подстраиваются под то, что лежит под карточкой, и под оформление системы.
    let glass = NSGlassEffectView(frame: panel.contentLayoutRect)
    glass.cornerRadius = ProgressCardView.cornerRadius
    glass.contentView = hosting
    panel.contentView = glass
    return panel
  }
}

/// Карточки всех операций в строке меню под одним стеклом.
struct ProgressCardStack: View {
  let cards: [ProgressCardModel]
  let close: () -> Void
  let details: (ProgressCardModel) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
        if index > 0 { Divider().padding(.horizontal, 16) }
        ProgressCardView(model: card, close: close, details: { details(card) })
      }
    }
  }
}

extension PangoZipStatusItem {
  /// Меню основного приложения: то, что раньше показывал значок MenuBarExtra.
  static func applicationMenu(openMainWindow: @escaping @MainActor () -> Void) -> NSMenu {
    let menu = NSMenu()
    menu.addItem(
      MenuAction.item(L10n.tr("Открыть PangoZip")) {
        openMainWindow()
        NSApp.activate()
      })
    menu.addItem(MenuAction.item(L10n.tr("Настройки…"), action: openSettings))
    menu.addItem(.separator())
    menu.addItem(MenuAction.item(L10n.tr("Завершить PangoZip")) { NSApp.terminate(nil) })
    return menu
  }

  /// Открывает настройки тем же пунктом меню программы, что и ⌘,: SwiftUI не даёт
  /// открыть сцену Settings из AppKit напрямую.
  static func openSettings() {
    NSApp.activate()
    guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
      let index = appMenu.items.firstIndex(where: {
        $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
      })
    else { return }
    appMenu.performActionForItem(at: index)
  }
}

/// Пункт меню с замыканием вместо селектора.
@MainActor
final class MenuAction: NSObject {
  private let handler: @MainActor () -> Void
  private init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }

  static func item(_ title: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
    let target = MenuAction(action)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.runHandler), keyEquivalent: "")
    item.target = target
    // NSMenuItem держит target слабо: храним его в representedObject.
    item.representedObject = target
    return item
  }

  @objc private func runHandler() { handler() }
}

#if DEBUG
  /// Отладочный показ хода в строке меню без настоящей операции: `--menubar-demo`
  /// открывает карточку, `--menubar-details` — окно подробностей. Только для проверки вида.
  @MainActor
  enum MenuBarDemo {
    private static let card = ProgressCardModel()
    private static var ticker: Task<Void, Never>?

    static func startIfRequested() {
      let arguments = ProcessInfo.processInfo.arguments
      guard arguments.contains("--menubar-demo") else { return }
      card.title = ApplicationMode.isFinderWorker ? "Dogs.zip" : "Cats.7z"
      card.togglePause = { card.isPaused.toggle() }
      card.cancel = { MenuBarProgress.detach(card) }
      MenuBarProgress.attach(card)
      var fraction = 0.38
      ticker = Task { @MainActor in
        while !Task.isCancelled {
          fraction = min(0.99, fraction + 0.01)
          let remaining = 240 * (1 - fraction)
          card.stage = L10n.tr("Сжимаем…") + " · \(Int((fraction * 100).rounded(.down)))%"
          card.fraction = fraction
          card.remaining = remaining
          card.progress = ArchiveProgress(
            phase: .compressing, fraction: fraction,
            processedBytes: UInt64(fraction * 1_000_000_000), totalBytes: 1_000_000_000,
            completedFiles: Int(fraction * 30), totalFiles: 30, currentFile: "cats/kitten.jpg",
            outputBytes: UInt64(fraction * 380_000_000), bytesPerSecond: 52_000_000,
            remainingSeconds: remaining, elapsedSeconds: fraction * 100)
          try? await Task.sleep(for: .seconds(1))
        }
      }
      // Снимок значка в файл: на тесной строке меню он может уйти за «<<», а проверить вид
      // всё равно нужно. Снимает тот процесс, у которого значок свой.
      Task { @MainActor in
        for pause in [3, 5] {
          try? await Task.sleep(for: .seconds(pause))
          PangoZipStatusItem.shared.snapshotForDemo()
        }
      }
      guard !ApplicationMode.isFinderWorker else { return }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.5))
        if arguments.contains("--menubar-details") {
          PangoZipStatusItem.shared.showDetailsForDemo()
        } else {
          PangoZipStatusItem.shared.openCardForDemo()
        }
      }
    }
  }

  extension PangoZipStatusItem {
    func openCardForDemo() { openCard() }

    /// Пишет вид кнопки значка в /tmp/pangozip-menubar-<pid>.png, а в журнал — её размер
    /// и видна ли она на экране.
    func snapshotForDemo() {
      guard let button = item?.button, !cards.isEmpty else { return }
      let pid = ProcessInfo.processInfo.processIdentifier
      let visible = button.window?.occlusionState.contains(.visible) == true
      let frame = button.window?.frame ?? .zero
      let size = "\(Int(button.bounds.width))x\(Int(button.bounds.height))"
      let window = button.window.map { "\(type(of: $0))" } ?? "none"
      let shown = item?.isVisible == true
      let place =
        "x \(Int(frame.minX)), y \(Int(frame.minY)), visible \(visible), "
        + "window \(window), shown \(shown)"
      logger.notice("Demo snapshot: button \(size, privacy: .public), \(place, privacy: .public)")
      guard let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return }
      button.cacheDisplay(in: button.bounds, to: rep)
      let stamp = Int(Date().timeIntervalSince1970)
      let url = URL(fileURLWithPath: "/tmp/pangozip-menubar-\(pid)-\(stamp).png")
      try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    func showDetailsForDemo() {
      if let current { details.show(current) }
    }
  }
#endif
