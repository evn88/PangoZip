import AppKit
import PangoZipCore
import UserNotifications

/// Что за операция выполняется; определяет заголовок уведомления.
enum OperationKind: Sendable {
  case create, extract, verify, modify, checksums

  var successTitle: String {
    switch self {
    case .create: L10n.tr("Архив создан")
    case .extract: L10n.tr("Извлечение завершено")
    case .verify: L10n.tr("Проверка архива завершена")
    case .modify: L10n.tr("Архив изменён")
    case .checksums: L10n.tr("Контрольные суммы вычислены")
    }
  }
}

enum OperationOutcome: Sendable, Equatable {
  case success
  case failure(String)
  /// Отмена пользователем и запрос пароля не считаются завершением работы.
  case cancelled
}

/// Состояние индикатора на иконке Dock.
enum DockProgress {
  enum State: Equatable {
    case hidden
    case indeterminate
    case determinate(Double)
  }

  /// Среднее известных долей активных операций; пока ни одна доля не известна — неопределённый.
  static func state(for fractions: [Double?]) -> State {
    guard !fractions.isEmpty else { return .hidden }
    let known = fractions.compactMap { $0 }.filter(\.isFinite)
    guard !known.isEmpty else { return .indeterminate }
    let mean = known.reduce(0, +) / Double(known.count)
    return .determinate(min(1, max(0, mean)))
  }

  /// Подготовка не имеет значимой доли; на остальных этапах берётся доля всей операции.
  static func fraction(of progress: ArchiveProgress?) -> Double? {
    guard let progress, progress.phase != .preparing else { return nil }
    return progress.fraction
  }
}

/// Решение о показе уведомления о завершении.
enum OperationNotificationPolicy {
  /// Порог длительности, после которого пользователь мог отвлечься от окна.
  static let threshold: TimeInterval = 10
  static let defaultsKey = "notifyLongOperations"

  /// Уведомляет только о долгих завершённых операциях, пока приложение неактивно.
  static func shouldNotify(
    duration: TimeInterval, isEnabled: Bool, isApplicationActive: Bool, outcome: OperationOutcome,
    threshold: TimeInterval = OperationNotificationPolicy.threshold
  ) -> Bool {
    guard isEnabled, !isApplicationActive, outcome != .cancelled else { return false }
    return duration.isFinite && duration >= threshold
  }

  /// UNUserNotificationCenter аварийно завершает процесс вне комплекта .app (тесты, CLI).
  static func isAvailable(bundleURL: URL, bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
    return bundleURL.pathExtension == "app"
  }

  /// Настройка включена по умолчанию; общий домен читают и приложение, и worker.
  static var isEnabled: Bool {
    let defaults = UserDefaults(suiteName: "app.pangozip.desktop") ?? .standard
    return defaults.object(forKey: defaultsKey) as? Bool ?? true
  }
}

/// Единая точка обратной связи по длительным операциям: прогресс в Dock и итоговое уведомление.
@MainActor
final class OperationFeedback {
  static let shared = OperationFeedback()

  private struct Entry {
    var fraction: Double?
    let kind: OperationKind
    let subject: String
    let started: TimeInterval
  }

  private var entries: [UUID: Entry] = [:]
  private let dock: DockTileProgress?
  private var shownDockState = DockProgress.State.hidden

  init() {
    // У фонового worker нет иконки в Dock.
    dock = ApplicationMode.isFinderWorker ? nil : DockTileProgress()
  }

  /// Регистрирует операцию; возвращаемый идентификатор нужен для обновлений и завершения.
  func begin(kind: OperationKind, subject: String) -> UUID {
    let id = UUID()
    entries[id] = Entry(
      fraction: nil, kind: kind, subject: subject, started: ProcessInfo.processInfo.systemUptime)
    refreshDock()
    return id
  }

  func update(_ id: UUID, fraction: Double?) {
    guard entries[id] != nil else { return }
    entries[id]?.fraction = fraction
    refreshDock()
  }

  /// Снимает операцию с Dock и при необходимости показывает уведомление. Возвращаемая задача
  /// завершается после постановки уведомления; процессу, который сразу закрывается, стоит её дождаться.
  @discardableResult
  func finish(_ id: UUID, outcome: OperationOutcome) -> Task<Void, Never>? {
    guard let entry = entries.removeValue(forKey: id) else { return nil }
    refreshDock()
    let duration = ProcessInfo.processInfo.systemUptime - entry.started
    guard
      OperationNotificationPolicy.shouldNotify(
        duration: duration, isEnabled: OperationNotificationPolicy.isEnabled,
        isApplicationActive: NSApp?.isActive ?? false, outcome: outcome)
    else { return nil }
    let title: String
    let body: String
    if case .failure(let reason) = outcome {
      title = L10n.tr("Операция не выполнена")
      body = L10n.tr("%1$@: %2$@", entry.subject, Self.shortened(reason))
    } else {
      title = entry.kind.successTitle
      body = entry.subject
    }
    return Task { await Self.post(title: title, body: body) }
  }

  /// Длинные сообщения об ошибках обрезаются, чтобы уведомление оставалось читаемым.
  nonisolated static func shortened(_ text: String, limit: Int = 140) -> String {
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
  }

  private func refreshDock() {
    let state = DockProgress.state(for: entries.values.map(\.fraction))
    // Перерисовка иконки нужна не чаще, чем меняется целый процент.
    let rounded: DockProgress.State
    if case .determinate(let value) = state {
      rounded = .determinate((value * 100).rounded(.down) / 100)
    } else {
      rounded = state
    }
    guard rounded != shownDockState else { return }
    shownDockState = rounded
    dock?.apply(rounded)
  }

  /// Разрешение запрашивается при первом показе; отказ молча отключает уведомления.
  private static func post(title: String, body: String) async {
    guard
      OperationNotificationPolicy.isAvailable(
        bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier)
    else { return }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .notDetermined:
      guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
        return
      }
    case .denied: return
    default: break
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    try? await center.add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }
}

/// Рисует иконку приложения с полосой прогресса в плитке Dock.
@MainActor
private final class DockTileProgress {
  private let indicator = NSProgressIndicator()
  private func makeContainer(for app: NSApplication) -> NSView {
    let size = app.dockTile.size
    let view = NSView(frame: NSRect(origin: .zero, size: size))
    let icon = NSImageView(frame: view.bounds)
    icon.image = app.applicationIconImage
    icon.imageScaling = .scaleProportionallyUpOrDown
    view.addSubview(icon)
    indicator.style = .bar
    indicator.minValue = 0
    indicator.maxValue = 1
    indicator.frame = NSRect(x: 10, y: 8, width: size.width - 20, height: 14)
    view.addSubview(indicator)
    return view
  }

  private var container: NSView?

  func apply(_ state: DockProgress.State) {
    // В тестах и утилитах NSApplication не создан, а иконки Dock нет.
    guard let app = NSApp else { return }
    let tile = app.dockTile
    let container = self.container ?? makeContainer(for: app)
    self.container = container
    switch state {
    case .hidden:
      indicator.stopAnimation(nil)
      tile.contentView = nil
    case .indeterminate:
      indicator.isIndeterminate = true
      indicator.startAnimation(nil)
      tile.contentView = container
    case .determinate(let value):
      indicator.stopAnimation(nil)
      indicator.isIndeterminate = false
      indicator.doubleValue = value
      tile.contentView = container
    }
    tile.display()
  }
}
