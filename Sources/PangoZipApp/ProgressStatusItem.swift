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
  /// Полный ход операции для окна подробностей: объёмы, скорость, время.
  @Published var progress: ArchiveProgress?
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

  /// Короткая подпись для строки меню: только процент, чтобы значок не уходил за край
  /// тесной строки меню. Оставшееся время — в карточке и в окне подробностей.
  var menuBarTitle: String {
    guard state == .working, let fraction else { return "" }
    return "\(Int((fraction * 100).rounded(.down)))%"
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

/// Ход одной операции в строке меню. Сам значок общий на процесс — `PangoZipStatusItem`:
/// в основном приложении ход показывается в значке PangoZip, а фоновый процесс Finder
/// передаёт его туда же, если основное приложение запущено.
@MainActor
final class ProgressStatusItem {
  let card = ProgressCardModel()
  private(set) var isShown = false

  func show() {
    guard !isShown else { return }
    isShown = true
    MenuBarProgress.attach(card)
  }

  func hide() {
    guard isShown else { return }
    isShown = false
    MenuBarProgress.detach(card)
  }
}

/// Куда уходит ход операции: в значок своего процесса или в значок основного приложения.
@MainActor
enum MenuBarProgress {
  static func attach(_ card: ProgressCardModel) {
    if ApplicationMode.isFinderWorker {
      RemoteProgressLink.shared.attach(card)
    } else {
      PangoZipStatusItem.shared.attach(card)
    }
  }

  static func detach(_ card: ProgressCardModel) {
    if ApplicationMode.isFinderWorker {
      RemoteProgressLink.shared.detach(card)
    } else {
      PangoZipStatusItem.shared.detach(card)
    }
  }
}

/// Кольцо хода для строки меню, как на острове: золотая дуга на приглушённой дорожке.
/// Дорожка и пауза рисуются цветом текста строки меню, поэтому кольцо видно и на светлой,
/// и на тёмной строке; картинка рисуется заново при смене оформления.
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

  /// Значок PangoZip и рядом кольцо хода — одной картинкой, чтобы ход был в том же значке,
  /// что и программа. Панголин рисуется цветом текста строки меню, кольцо — золотом.
  @MainActor
  static func withPangolin(_ key: Key) -> NSImage {
    let glyph = PangolinGlyph.image
    let ringImage = make(key)
    return NSImage(size: NSSize(width: 34, height: 18), flipped: false) { rect in
      let glyphRect = NSRect(x: rect.minX, y: rect.minY + 1, width: 16, height: 16)
      glyph.draw(in: glyphRect)
      NSColor.labelColor.set()
      glyphRect.fill(using: .sourceAtop)
      ringImage.draw(in: NSRect(x: rect.maxX - 15, y: rect.minY + 1.5, width: 15, height: 15))
      return true
    }
  }

  static func make(_ key: Key) -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
      let ring = rect.insetBy(dx: 1.5, dy: 1.5)
      let center = NSPoint(x: ring.midX, y: ring.midY)
      let radius = ring.width / 2
      if key.isDone {
        Brand.goldNS.setFill()
        NSBezierPath(ovalIn: ring.insetBy(dx: -0.5, dy: -0.5)).fill()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: rect.minX + 4.5, y: rect.midY))
        check.line(to: NSPoint(x: rect.minX + 7, y: rect.midY - 2.5))
        check.line(to: NSPoint(x: rect.maxX - 4.5, y: rect.midY + 2.5))
        check.lineWidth = 1.8
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        Brand.onGoldNS.setStroke()
        check.stroke()
        return true
      }
      let track = NSBezierPath(ovalIn: ring)
      track.lineWidth = 2.2
      NSColor.labelColor.withAlphaComponent(0.28).setStroke()
      track.stroke()
      // Без известной доли видна четверть кольца: операция идёт, но сколько осталось, неясно.
      let fraction = key.percent.map { max(0.03, Double($0) / 100) } ?? 0.25
      let arc = NSBezierPath()
      arc.appendArc(
        withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction,
        clockwise: true)
      arc.lineWidth = 2.2
      arc.lineCapStyle = .round
      Brand.goldNS.setStroke()
      arc.stroke()
      if key.isPaused {
        NSColor.labelColor.setFill()
        for offset in [-1.75, 1.75] {
          let bar = NSRect(
            x: center.x + offset - 0.75, y: center.y - 2.5, width: 1.5, height: 5)
          NSBezierPath(roundedRect: bar, xRadius: 0.75, yRadius: 0.75).fill()
        }
      }
      return true
    }
    return image
  }
}

/// Силуэт панголина — тот же значок, что у кнопки PangoZip в панели Finder.
/// Шаблонная картинка: цвет задаёт система или SwiftUI.
@MainActor
enum PangolinGlyph {
  static let image: NSImage = {
    let image =
      Bundle.main.image(forResource: "ToolbarIcon")
      ?? NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil) ?? NSImage()
    image.isTemplate = true
    return image
  }()

  /// Копия нужного размера: строка меню берёт картинку как есть, без масштабирования.
  static func sized(_ side: CGFloat) -> NSImage {
    let copy = image.copy() as? NSImage ?? image
    copy.size = NSSize(width: side, height: side)
    copy.isTemplate = true
    copy.accessibilityDescription = "PangoZip"
    return copy
  }
}

/// Карточка под строкой меню. Фон — системное стекло Liquid Glass (NSGlassEffectView
/// в панели), поэтому текст и кнопки берут системные цвета, а не собственную палитру.
struct ProgressCardView: View {
  static let cornerRadius: CGFloat = 20
  @ObservedObject var model: ProgressCardModel
  let close: () -> Void
  /// Окно со всеми подробностями хода; то же открывает двойной щелчок по значку.
  let details: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        symbol
        VStack(alignment: .leading, spacing: 2) {
          Text(model.title).font(.headline).lineLimit(1).truncationMode(.middle)
          Text(model.state == .done ? L10n.tr("Готово") : model.stage)
            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 4)
        Button {
          close()
          details()
        } label: {
          Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless).controlSize(.large)
        .help(L10n.tr("Подробнее…")).accessibilityLabel(L10n.tr("Подробнее…"))
        if model.state == .working {
          Button {
            close()
            model.restore()
          } label: {
            Image(systemName: "menubar.arrow.down.rectangle")
          }
          .buttonStyle(.borderless).controlSize(.large)
          .help(L10n.tr("Показать остров")).accessibilityLabel(L10n.tr("Показать остров"))
        }
      }
      if model.state == .working {
        bar
        HStack(spacing: 8) {
          Text(model.timeLine).font(.subheadline).monospacedDigit()
            .foregroundStyle(.secondary).lineLimit(1)
          Spacer(minLength: 4)
          if let togglePause = model.togglePause {
            Button(action: togglePause) {
              Label(
                model.isPaused ? L10n.tr("Возобновить") : L10n.tr("Пауза"),
                systemImage: model.isPaused ? "play.fill" : "pause.fill")
            }
          }
          Button {
            close()
            model.cancel()
          } label: {
            Label(L10n.tr("Отмена"), systemImage: "xmark")
          }
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular)
      } else if model.canReveal {
        HStack {
          Spacer()
          Button {
            close()
            model.reveal()
          } label: {
            Text(L10n.tr("Показать в Finder")).foregroundStyle(Brand.onGold)
          }
          .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Brand.gold)
        }
      }
    }
    .padding(16)
    .frame(width: 320)
  }

  @ViewBuilder private var symbol: some View {
    Group {
      if model.state == .done {
        Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
          .foregroundStyle(Brand.onGold).frame(width: 32, height: 32)
          .background(Brand.gold, in: Circle())
      } else if model.isPaused {
        Image(systemName: "pause.fill").font(.system(size: 14))
          .foregroundStyle(Brand.goldInk).frame(width: 32, height: 32)
          .background(.quaternary, in: Circle())
      } else {
        Image(nsImage: PangolinGlyph.image).renderingMode(.template).resizable()
          .frame(width: 18, height: 18).foregroundStyle(Brand.goldInk)
          .frame(width: 32, height: 32).background(.quaternary, in: Circle())
      }
    }
    .accessibilityHidden(true)
  }

  /// Системная полоса хода золотого цвета. Без своей анимации: каждое обновление процента
  /// раньше заново запускало анимацию, и заливка дёргалась и «влетала» на место.
  private var bar: some View {
    GoldProgressBar(fraction: model.fraction, isPaused: model.isPaused)
      .accessibilityLabel(model.stage)
  }

}

/// Золотая полоса хода. Своя, а не системная: системная в неактивной панели строки меню
/// рисуется серой. Без неявной анимации: она заново запускалась на каждом проценте,
/// и заливка дёргалась и «влетала» на место.
struct GoldProgressBar: View {
  let fraction: Double?
  var isPaused = false

  var body: some View {
    if let fraction {
      Capsule().fill(.quaternary)
        .overlay(alignment: .leading) {
          GeometryReader { proxy in
            Capsule().fill(isPaused ? Color.secondary : Brand.gold)
              .frame(width: max(6, proxy.size.width * min(1, max(0, fraction))))
          }
        }
        .frame(height: 6)
        .transaction { $0.animation = nil }
        .accessibilityElement()
        .accessibilityValue("\(Int((fraction * 100).rounded(.down)))%")
    } else {
      ProgressView().progressViewStyle(.linear).tint(Brand.gold)
    }
  }
}

/// Хост острова, который принимает жест двумя пальцами: им остров смахивают в строку меню.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
  var onScroll: ((NSEvent) -> Bool)?

  override func scrollWheel(with event: NSEvent) {
    if onScroll?(event) != true { super.scrollWheel(with: event) }
  }
}
