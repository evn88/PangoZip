import AppKit
import PangoZipCore
import SwiftUI

/// Палитра бренда: тёмно-синий и золото логотипа, тёплый фон сайта pangozip.app.
enum Brand {
  /// Шапка окна под стеклянной панелью инструментов.
  static let headerNS = dynamic(light: 0x101F4A, dark: 0x0C1532)
  /// Синее свечение, которое вместе с золотом даёт шапке глубину матового стекла.
  static let headerGlowNS = dynamic(light: 0x2B4388, dark: 0x22397A)
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
  static let headerGlow = Color(nsColor: headerGlowNS)
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

/// Матовая тёмно-синяя шапка: размытые пятна света с небольшой долей золота, без резких кромок.
struct BrandHeaderBackground: View {
  /// Положение по ширине, размер относительно высоты шапки, цвет и плотность каждого пятна.
  private static let spots:
    [(x: CGFloat, y: CGFloat, width: CGFloat, color: Color, opacity: Double)] =
      [
        (0.10, 0.95, 5.0, Brand.headerGlow, 0.55),
        (0.24, 0.05, 2.4, Brand.gold, 0.36),
        (0.47, 1.05, 3.4, Brand.gold, 0.28),
        (0.66, 0.00, 4.5, Brand.headerGlow, 0.45),
        (0.84, 0.90, 2.8, Brand.gold, 0.38),
      ]

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Brand.header
        ForEach(Array(Self.spots.enumerated()), id: \.offset) { _, spot in
          Ellipse().fill(spot.color).opacity(spot.opacity)
            .frame(width: proxy.size.height * spot.width, height: proxy.size.height * 1.1)
            .position(x: proxy.size.width * spot.x, y: proxy.size.height * spot.y)
        }
      }
      .blur(radius: 22)
      .background(Brand.header)
    }
    .clipped()
    .accessibilityHidden(true)
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
