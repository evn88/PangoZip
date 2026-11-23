import AppKit
import Combine
import PangoZipCore
import SwiftUI

/// Состояние карточки операции в строке меню: туда уходит смахнутый остров.
@MainActor
final class ProgressCardModel: ObservableObject {
  enum State: Equatable {
    case working, done
  }

  @Published var state = State.working
  @Published var title = ""
  /// Этап и процент, как в подписи острова.
  @Published var stage = ""
  @Published var fraction: Double?
  @Published var remaining: TimeInterval?
  @Published var isPaused = false
  @Published var canReveal = false
  /// nil — операция не умеет вставать на паузу, кнопка не показывается.
  var togglePause: (() -> Void)?
  var cancel: () -> Void = {}
  var restore: () -> Void = {}
  var reveal: () -> Void = {}

  /// Присваивает только новое значение, чтобы строка меню не перерисовывалась впустую.
  func update<Value: Equatable>(
    _ keyPath: ReferenceWritableKeyPath<ProgressCardModel, Value>, to value: Value
  ) {
    if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
  }

  /// Короткая подпись для строки меню: процент и оставшееся время.
  var menuBarTitle: String {
    guard state == .working, let fraction else { return "" }
    var parts = ["\(Int((fraction * 100).rounded(.down)))%"]
    if !isPaused, let remaining { parts.append(ShortDuration.string(remaining)) }
    return parts.joined(separator: " · ")
  }

  /// Строка под полосой: сколько осталось, оценка ещё не готова или операция стоит.
  var timeLine: String {
    if isPaused { return L10n.tr("На паузе") }
    guard let remaining else { return L10n.tr("Оцениваем время…") }
    return L10n.tr("Осталось %1$@", String(describing: ShortDuration.string(remaining)))
  }
}

/// Оставшееся время одной-двумя единицами: точность до секунды в строке меню только мельтешит.
enum ShortDuration {
  static func string(_ seconds: TimeInterval) -> String {
    // Дольше 100 часов оценка всё равно неточна; предел защищает от переполнения Int.
    let value = seconds.isFinite ? min(max(0, seconds), 360_000) : 0
    let duration: Duration
    let units: Set<Duration.UnitsFormatStyle.Unit>
    let minutes = Int((value / 60).rounded(.up))
    if value < 60 {
      // Секунды идут шагом в пять, чтобы число не прыгало на каждом обновлении.
      duration = .seconds(max(5, Int((value / 5).rounded(.up)) * 5))
      units = [.seconds]
    } else {
      duration = .seconds(minutes * 60)
      units = minutes < 60 ? [.minutes] : [.hours, .minutes]
    }
    return duration.formatted(
      .units(allowed: units, width: .abbreviated, zeroValueUnits: .hide).locale(L10n.locale))
  }
}

/// Значок операции в строке меню: кольцо хода, процент и время; по нажатию — карточка
/// с паузой и отменой. Живёт, пока остров смахнут.
@MainActor
final class ProgressStatusItem: NSObject {
  let card = ProgressCardModel()
  private var item: NSStatusItem?
  private var panel: NSPanel?
  private var subscription: AnyCancellable?
  private var monitors: [Any] = []
  private var renderedImage: RingImage.Key?

  var isShown: Bool { item != nil }

  func show() {
    guard item == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.target = self
    item.button?.action = #selector(toggleCard)
    item.button?.imagePosition = .imageLeading
    self.item = item
    subscription = card.objectWillChange.sink { [weak self] _ in
      // objectWillChange приходит до записи: рисуем уже новое состояние.
      Task { @MainActor in self?.render() }
    }
    render()
  }

  func hide() {
    closeCard()
    subscription = nil
    renderedImage = nil
    if let item { NSStatusBar.system.removeStatusItem(item) }
    item = nil
  }

  private func render() {
    guard let button = item?.button else { return }
    let key = RingImage.Key(card: card)
    if key != renderedImage {
      renderedImage = key
      button.image = RingImage.make(key)
    }
    let title = card.menuBarTitle
    let font = NSFont.monospacedDigitSystemFont(
      ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    button.attributedTitle = NSAttributedString(
      string: title.isEmpty ? "" : " " + title, attributes: [.font: font])
    if panel?.isVisible == true { placeCard() }
    button.toolTip = card.title
    button.setAccessibilityLabel(
      [card.title, card.stage, card.state == .working ? card.timeLine : ""]
        .filter { !$0.isEmpty }.joined(separator: ", "))
  }

  // MARK: - Карточка

  @objc private func toggleCard() {
    if panel?.isVisible == true { closeCard() } else { openCard() }
  }

  /// Карточка — собственная неактивирующая панель, как и остров: нажатия на кнопки
  /// не выводят окна PangoZip поверх чужих программ.
  private func openCard() {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    placeCard()
    panel.orderFrontRegardless()
    // Нажатие мимо карточки закрывает её, как меню; нажатие на сам значок обработает toggleCard.
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

  /// Ставит карточку под значком; высота следует за содержимым, например после завершения.
  private func placeCard() {
    guard let panel, let button = item?.button, let buttonWindow = button.window else { return }
    let size = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 150)
    let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
    let visible = screen.visibleFrame
    let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
    let frame = NSRect(
      x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height)
    if panel.frame != frame { panel.setFrame(frame, display: true) }
  }

  private func closeCard() {
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors.removeAll()
    panel?.orderOut(nil)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .popUpMenu
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    // Кнопки карточки закрывают её сами: после отмены или возврата острова она не нужна.
    let close: () -> Void = { [weak self] in self?.closeCard() }
    let hosting = NSHostingView(rootView: ProgressCardView(model: card, close: close))
    hosting.sizingOptions = [.preferredContentSize]
    panel.contentView = hosting
    return panel
  }
}

/// Кольцо хода для строки меню. Шаблонное изображение: система сама подбирает цвет
/// под светлую и тёмную строку меню, а прозрачность дорожки сохраняется.
enum RingImage {
  struct Key: Equatable {
    var percent: Int?
    var isPaused: Bool
    var isDone: Bool

    @MainActor init(card: ProgressCardModel) {
      percent = card.fraction.map { Int(($0 * 100).rounded(.down)) }
      isPaused = card.isPaused
      isDone = card.state == .done
    }
  }

  static func make(_ key: Key) -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
      let ring = rect.insetBy(dx: 1.5, dy: 1.5)
      let center = NSPoint(x: ring.midX, y: ring.midY)
      let radius = ring.width / 2
      if key.isDone {
        NSColor.black.setFill()
        NSBezierPath(ovalIn: ring.insetBy(dx: -0.5, dy: -0.5)).fill()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: rect.minX + 4.5, y: rect.midY))
        check.line(to: NSPoint(x: rect.minX + 7, y: rect.midY - 2.5))
        check.line(to: NSPoint(x: rect.maxX - 4.5, y: rect.midY + 2.5))
        check.lineWidth = 1.8
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        check.stroke()
        return true
      }
      let track = NSBezierPath(ovalIn: ring)
      track.lineWidth = 2
      NSColor.black.withAlphaComponent(0.3).setStroke()
      track.stroke()
      // Без известной доли видна четверть кольца: операция идёт, но сколько осталось, неясно.
      let fraction = key.percent.map { max(0.03, Double($0) / 100) } ?? 0.25
      let arc = NSBezierPath()
      arc.appendArc(
        withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction,
        clockwise: true)
      arc.lineWidth = 2
      arc.lineCapStyle = .round
      NSColor.black.setStroke()
      arc.stroke()
      if key.isPaused {
        NSColor.black.setFill()
        for offset in [-1.75, 1.75] {
          let bar = NSRect(
            x: center.x + offset - 0.75, y: center.y - 2.5, width: 1.5, height: 5)
          NSBezierPath(roundedRect: bar, xRadius: 0.75, yRadius: 0.75).fill()
        }
      }
      return true
    }
    image.isTemplate = true
    return image
  }
}

/// Карточка под строкой меню в том же тёмно-синем стекле, что и остров.
struct ProgressCardView: View {
  @ObservedObject var model: ProgressCardModel
  let close: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let tint = Color(nsColor: NSColor(srgbHex: 0x101F4A)).opacity(0.55)
  private static let secondary = Color.white.opacity(0.76)

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        symbol
        VStack(alignment: .leading, spacing: 2) {
          Text(model.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            .truncationMode(.middle)
          Text(model.state == .done ? L10n.tr("Готово") : model.stage)
            .font(.system(size: 12)).foregroundStyle(Self.secondary).lineLimit(1)
        }
        Spacer(minLength: 4)
        if model.state == .working {
          iconButton(L10n.tr("Показать остров"), symbol: "menubar.arrow.down.rectangle") {
            close()
            model.restore()
          }
        }
      }
      if model.state == .working {
        bar
        HStack(spacing: 8) {
          Text(model.timeLine).font(.system(size: 12)).monospacedDigit()
            .foregroundStyle(Self.secondary).lineLimit(1)
          Spacer(minLength: 4)
          if let togglePause = model.togglePause {
            pill(
              model.isPaused ? L10n.tr("Возобновить") : L10n.tr("Пауза"),
              symbol: model.isPaused ? "play.fill" : "pause.fill", action: togglePause)
          }
          pill(L10n.tr("Отмена"), symbol: "xmark") {
            close()
            model.cancel()
          }
        }
      } else if model.canReveal {
        HStack {
          Spacer()
          Button {
            close()
            model.reveal()
          } label: {
            Text(L10n.tr("Показать в Finder")).font(.system(size: 12, weight: .semibold))
              .foregroundStyle(Brand.onGold).padding(.horizontal, 12).frame(height: 28)
              .background(Brand.gold, in: Capsule())
          }
          .buttonStyle(.plain)
        }
      }
    }
    .foregroundStyle(Color.white.opacity(0.96))
    .padding(16)
    .frame(width: 320)
    .background {
      ZStack {
        shape.fill(.ultraThinMaterial)
        shape.fill(Self.tint)
        LinearGradient(
          colors: [.white.opacity(0.18), .white.opacity(0.02), .clear], startPoint: .top,
          endPoint: .bottom
        )
        .clipShape(shape)
      }
    }
    .overlay { shape.strokeBorder(Color.white.opacity(0.3), lineWidth: 1) }
    .clipShape(shape)
    .environment(\.colorScheme, .dark)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.state)
  }

  @ViewBuilder private var symbol: some View {
    if model.state == .done {
      Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
        .foregroundStyle(Brand.onGold).frame(width: 30, height: 30)
        .background(Brand.gold, in: Circle()).accessibilityHidden(true)
    } else {
      Image(systemName: model.isPaused ? "pause.fill" : "archivebox.fill")
        .font(.system(size: 15)).foregroundStyle(Brand.gold).frame(width: 30, height: 30)
        .background(Color.white.opacity(0.1), in: Circle()).accessibilityHidden(true)
    }
  }

  /// Золотая полоса хода; пока доля неизвестна — бегущая полоса системы.
  @ViewBuilder private var bar: some View {
    if let fraction = model.fraction {
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.16))
          Capsule().fill(model.isPaused ? Self.secondary : Brand.gold)
            .frame(width: max(6, proxy.size.width * min(1, max(0, fraction))))
            .animation(.easeOut(duration: 0.25), value: fraction)
        }
      }
      .frame(height: 6)
      .accessibilityElement()
      .accessibilityLabel(model.stage)
      .accessibilityValue("\(Int((fraction * 100).rounded(.down)))%")
    } else {
      ProgressView().progressViewStyle(.linear).tint(Brand.gold)
    }
  }

  private func pill(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 11).frame(height: 26)
        .background(Color.white.opacity(0.14), in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
        .frame(width: 26, height: 26).background(Color.white.opacity(0.14), in: Circle())
    }
    .buttonStyle(.plain).accessibilityLabel(title).help(title)
  }
}

/// Хост острова, который принимает жест двумя пальцами: им остров смахивают в строку меню.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
  var onScroll: ((NSEvent) -> Bool)?

  override func scrollWheel(with event: NSEvent) {
    if onScroll?(event) != true { super.scrollWheel(with: event) }
  }
}
