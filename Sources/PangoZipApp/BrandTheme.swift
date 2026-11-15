import AppKit
import PangoZipCore
import SwiftUI

/// Палитра бренда: тёмно-синий и золото логотипа, тёплый фон сайта pangozip.app.
enum Brand {
  /// Тонировка стеклянной шапки окна.
  static let headerNS = dynamic(light: 0x101F4A, dark: 0x0C1532)
  /// Выделение строк таблицы в активном окне.
  static let selectionNS = dynamic(light: 0x101F4A, dark: 0x22397A)
  /// Заливка главной кнопки и значков папок.
  static let goldNS = dynamic(light: 0xE3A74C, dark: 0xE6AD52)
  /// Золото для тонких линий и текста на светлом фоне.
  static let goldInkNS = dynamic(light: 0xB5701A, dark: 0xE6B462)
  static let onGoldNS = NSColor(srgbHex: 0x1F1404)
  /// Вспомогательные поверхности: предпросмотр и строка состояния.
  static let surfaceNS = dynamic(light: 0xF4F3F0, dark: 0x0E1427)
  static let tableNS = dynamic(light: 0xFFFFFF, dark: 0x0A0F1F)
  static let stripeNS = dynamic(light: 0xF8F7F5, dark: 0x0E1427)
  static let trackNS = dynamic(light: 0xE7E5E0, dark: 0x263050)
  static let barNS = dynamic(light: 0x101F4A, dark: 0xE6AD52)

  static let header = Color(nsColor: headerNS)
  static let gold = Color(nsColor: goldNS)
  static let goldInk = Color(nsColor: goldInkNS)
  static let onGold = Color(nsColor: onGoldNS)
  static let surface = Color(nsColor: surfaceNS)
  static let track = Color(nsColor: trackNS)

  /// Создаёт цвет, который AppKit пересчитывает при смене светлой и тёмной темы.
  private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      return NSColor(srgbHex: isDark ? dark : light)
    }
  }
}

/// Оформление приложения: как в системе либо принудительно светлое или тёмное.
enum AppearanceMode: String, CaseIterable, Identifiable {
  case system, light, dark

  static let storageKey = "appearanceMode"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: L10n.tr("Системное")
    case .light: L10n.tr("Светлое")
    case .dark: L10n.tr("Тёмное")
    }
  }

  /// Применяет сохранённый выбор ко всем окнам; неизвестное значение означает системное.
  @MainActor
  static func apply(_ rawValue: String? = UserDefaults.standard.string(forKey: storageKey)) {
    switch AppearanceMode(rawValue: rawValue ?? "") ?? .system {
    case .system: NSApp.appearance = nil
    case .light: NSApp.appearance = NSAppearance(named: .aqua)
    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
    }
  }
}

extension NSColor {
  /// Разбирает цвет вида 0xRRGGBB в пространстве sRGB.
  convenience init(srgbHex hex: UInt32) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }
}

/// Прототип для сравнения вживую: самодельное стекло, системное стекло с тонировкой бренда
/// или полностью системная шапка. Подписи не переводятся, пока вариант не выбран.
enum GlassStyle: String, CaseIterable, Identifiable {
  case legacy, tinted, system

  static let storageKey = "prototypeGlassStyle"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .legacy: "Текущее"
    case .tinted: "Синее стекло"
    case .system: "Системное"
    }
  }
}

/// Шапка из системного Liquid Glass с синей тонировкой бренда; блики рисует сама система.
struct SystemGlassHeaderBackground: View {
  var body: some View {
    Color.clear
      .glassEffect(.regular.tint(Brand.header), in: .rect)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// Шапка окна из матового стекла: сквозь синюю тонировку видно то, что лежит под окном.
struct GlassHeaderBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> GlassHeaderView { GlassHeaderView() }

  func updateNSView(_ nsView: GlassHeaderView, context: Context) {}
}

/// Размытие фона за окном, тонировка бренда и блик, который следует за курсором.
@MainActor
final class GlassHeaderView: NSView {
  /// Плотность синей тонировки поверх размытого фона.
  private static let tintOpacity: CGFloat = 0.45
  private static let spotlightSize = CGSize(width: 380, height: 190)

  private let effect = NSVisualEffectView()
  private let overlay = NSView()
  private let tint = CALayer()
  private let sheen = CAGradientLayer()
  private let hairline = CALayer()
  private let spotlight = CAGradientLayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    effect.material = .hudWindow
    effect.blendingMode = .behindWindow
    // Стекло остаётся прозрачным и в неактивном окне.
    effect.state = .active
    effect.appearance = NSAppearance(named: .darkAqua)
    overlay.wantsLayer = true
    for view in [effect, overlay] {
      view.frame = bounds
      view.autoresizingMask = [.width, .height]
      addSubview(view)
    }
    sheen.colors = [NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.clear.cgColor]
    sheen.startPoint = CGPoint(x: 0.5, y: 1)
    sheen.endPoint = CGPoint(x: 0.5, y: 0.3)
    hairline.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
    spotlight.type = .radial
    spotlight.colors = [NSColor.white.withAlphaComponent(0.3).cgColor, NSColor.clear.cgColor]
    spotlight.startPoint = CGPoint(x: 0.5, y: 0.5)
    spotlight.endPoint = CGPoint(x: 1, y: 1)
    spotlight.bounds = CGRect(origin: .zero, size: Self.spotlightSize)
    spotlight.opacity = 0
    for layer in [tint, sheen, spotlight, hairline] { overlay.layer?.addSublayer(layer) }
    overlay.layer?.masksToBounds = true
    setAccessibilityElement(false)
    updateTint()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// Шапка лежит под панелью инструментов и не должна перехватывать её нажатия.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    tint.frame = bounds
    sheen.frame = bounds
    hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
    CATransaction.commit()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateTint()
  }

  private func updateTint() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      tint.backgroundColor = Brand.headerNS.withAlphaComponent(Self.tintOpacity).cgColor
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }

  override func mouseEntered(with event: NSEvent) { moveSpotlight(event, isVisible: true) }

  override func mouseMoved(with event: NSEvent) { moveSpotlight(event, isVisible: true) }

  override func mouseExited(with event: NSEvent) { moveSpotlight(event, isVisible: false) }

  /// Блик следует за курсором без анимации положения; плавно меняется только его яркость.
  private func moveSpotlight(_ event: NSEvent, isVisible: Bool) {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    let x = convert(event.locationInWindow, from: nil).x
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    spotlight.position = CGPoint(x: x, y: bounds.maxY)
    CATransaction.commit()
    spotlight.opacity = isVisible ? 1 : 0
  }
}

/// Кольцо показывает только ход операции; для степени сжатия кольца не используются.
struct OperationProgressRing: View {
  let fraction: Double

  var body: some View {
    ZStack {
      Circle().stroke(.primary.opacity(0.22), lineWidth: 3)
      Circle().trim(from: 0, to: max(0.02, min(1, fraction)))
        .stroke(Brand.gold, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .frame(width: 16, height: 16)
    .accessibilityHidden(true)
  }
}
