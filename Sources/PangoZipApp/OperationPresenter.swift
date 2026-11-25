import AppKit
import PangoZipCore

/// Ход операции вне окна: остров, а после смахивания — значок в строке меню с карточкой.
/// Один и тот же путь для операций из меню Finder и из окна программы, поэтому
/// пользователь видит одинаковое поведение независимо от того, где начал работу.
@MainActor
final class OperationPresenter {
  private let island = OperationIsland()
  private let statusItem = ProgressStatusItem()
  private(set) var isShown = false
  private var minimized = false
  /// Отложенный уход острова в строку меню, если так выбрано в настройках; запускается один раз.
  private var autoMinimizeTask: Task<Void, Never>?
  private var donePause: Task<Void, Never>?
  private var title = ""
  private var stage = ""
  private var fraction: Double?
  private var remaining: TimeInterval?
  private var isPaused = false

  /// `togglePause` nil — операция не умеет вставать на паузу, кнопки паузы нет.
  init(cancel: @escaping () -> Void, togglePause: (() -> Void)?) {
    island.model.cancel = cancel
    island.model.minimize = { [weak self] in self?.minimize() }
    island.model.togglePause = togglePause
    let card = statusItem.card
    card.cancel = cancel
    card.togglePause = togglePause
    card.restore = { [weak self] in self?.restore() }
  }

  /// Показывает ход операции; повторный вызов только меняет название.
  func show(title: String) {
    self.title = title
    // Итог прошлой операции из очереди уступает место следующей.
    donePause?.cancel()
    donePause = nil
    let wasShown = isShown
    isShown = true
    render()
    guard !wasShown, autoMinimizeTask == nil, DropIslandSettings.progressMode == .menuBar else {
      return
    }
    autoMinimizeTask = Task { [weak self] in
      try? await Task.sleep(for: DropIslandProgressMode.menuBarDelay)
      guard !Task.isCancelled else { return }
      self?.minimize()
    }
  }

  /// Этап с процентом, доля и оставшееся время; лишние перерисовки отсекают модели острова и карточки.
  func update(stage: String, fraction: Double?, remaining: TimeInterval?, isPaused: Bool) {
    self.stage = stage
    self.fraction = fraction
    self.remaining = remaining
    self.isPaused = isPaused
    if isShown { render() }
  }

  /// Убирает и остров, и значок: окно снова на экране или операция закончилась.
  func hide() {
    autoMinimizeTask?.cancel()
    autoMinimizeTask = nil
    donePause?.cancel()
    donePause = nil
    isShown = false
    minimized = false
    island.hide()
    statusItem.hide()
  }

  /// Недолго показывает итог там же, где шёл ход; кнопка Finder завершает показ раньше.
  func showResult(title: String, url: URL?) async {
    await presentResult(title: title, url: url)?.value
  }

  /// Показывает итог сразу, без ожидания: следующая операция из очереди, начатая после
  /// этого вызова, отменит показ и не будет скрыта его таймером. Возвращает конец показа.
  @discardableResult
  func presentResult(title: String, url: URL?) -> Task<Void, Never>? {
    autoMinimizeTask?.cancel()
    autoMinimizeTask = nil
    guard isShown else { return nil }
    let pause = Task { _ = try? await Task.sleep(for: .seconds(4)) }
    donePause = pause
    let reveal = {
      if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      pause.cancel()
    }
    if minimized {
      let card = statusItem.card
      card.canReveal = url != nil
      card.reveal = reveal
      card.title = title
      card.state = .done
    } else {
      island.model.canReveal = url != nil
      island.model.reveal = reveal
      island.show(.done, title: title, subtitle: L10n.tr("Готово"), fraction: 1)
    }
    return Task { [weak self] in
      await pause.value
      guard let self, self.donePause == pause else { return }
      self.donePause = nil
      self.hide()
    }
  }

  /// Смахнутый остров уходит в строку меню; ход операции продолжает показывать значок.
  private func minimize() {
    guard isShown, !minimized else { return }
    minimized = true
    island.hide()
    statusItem.show()
    render()
  }

  /// Возвращает операцию из строки меню на остров.
  private func restore() {
    autoMinimizeTask?.cancel()
    guard minimized else { return }
    minimized = false
    statusItem.hide()
    if isShown { render() }
  }

  private func render() {
    island.model.update(\.isPaused, to: isPaused)
    guard minimized else {
      island.show(.working, title: title, subtitle: stage, fraction: fraction)
      return
    }
    let card = statusItem.card
    card.update(\.state, to: .working)
    card.update(\.title, to: title)
    card.update(\.stage, to: stage)
    card.update(\.fraction, to: fraction)
    card.update(\.remaining, to: remaining)
    card.update(\.isPaused, to: isPaused)
  }
}

extension OperationPresenter {
  /// Подпись под именем, как на острове: этап, а пока доля известна — и процент.
  static func stage(
    kind: OperationKind, progress: ArchiveProgress?, isPaused: Bool
  ) -> (title: String, fraction: Double?) {
    var stage: String
    switch kind {
    case _ where isPaused: stage = L10n.tr("На паузе")
    case .create: stage = L10n.tr("Сжимаем…")
    case .verify: stage = ProgressFormatting.phaseTitle(.verifying)
    case .extract: stage = L10n.tr("Распаковываем…")
    case .modify, .checksums: stage = ProgressFormatting.phaseTitle(progress?.phase ?? .preparing)
    }
    var fraction: Double?
    if let progress, progress.phase != .preparing, let value = progress.fraction {
      fraction = value
      stage += " · \(Int((value * 100).rounded(.down)))%"
    }
    return (stage, fraction)
  }
}
