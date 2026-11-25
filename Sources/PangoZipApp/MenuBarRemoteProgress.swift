import AppKit
import Combine
import PangoZipCore

/// Ход операций фонового процесса Finder в значке основного приложения.
/// Фоновый процесс шлёт снимки хода распределёнными уведомлениями, основное приложение
/// показывает их в своём значке и отвечает командами кнопок карточки.
enum RemoteProgressMessage {
  static let progress = Notification.Name("app.pangozip.menubar.progress")
  static let ack = Notification.Name("app.pangozip.menubar.ack")
  static let command = Notification.Name("app.pangozip.menubar.command")
  static let mainBundleID = "app.pangozip.desktop"

  enum Command: String {
    case pause, cancel, restore, reveal
  }

  /// Снимок карточки в виде, пригодном для распределённого уведомления.
  @MainActor
  static func snapshot(_ card: ProgressCardModel, id: String, removed: Bool) -> [String: Any] {
    var info: [String: Any] = [
      "id": id, "pid": Int(ProcessInfo.processInfo.processIdentifier), "removed": removed,
      "done": card.state == .done, "title": card.title, "stage": card.stage,
      "paused": card.isPaused, "canPause": card.togglePause != nil, "canReveal": card.canReveal,
    ]
    if let fraction = card.fraction { info["fraction"] = fraction }
    if let remaining = card.remaining { info["remaining"] = remaining }
    if let progress = card.progress, let data = try? JSONEncoder().encode(progress) {
      info["progress"] = data
    }
    return info
  }

  /// Переносит снимок в карточку-представителя основного приложения.
  @MainActor
  static func apply(_ info: [AnyHashable: Any], to card: ProgressCardModel) {
    card.update(\.state, to: info["done"] as? Bool == true ? .done : .working)
    card.update(\.title, to: info["title"] as? String ?? "")
    card.update(\.stage, to: info["stage"] as? String ?? "")
    card.update(\.fraction, to: info["fraction"] as? Double)
    card.update(\.remaining, to: info["remaining"] as? TimeInterval)
    card.update(\.isPaused, to: info["paused"] as? Bool == true)
    card.update(\.canReveal, to: info["canReveal"] as? Bool == true)
    let progress = (info["progress"] as? Data).flatMap {
      try? JSONDecoder().decode(ArchiveProgress.self, from: $0)
    }
    card.update(\.progress, to: progress)
  }

  static func post(_ name: Notification.Name, _ info: [String: Any]) {
    DistributedNotificationCenter.default().postNotificationName(
      name, object: nil, userInfo: info, deliverImmediately: true)
  }
}

/// Сторона фонового процесса: отдаёт ход значку основного приложения, а если оно не
/// запущено или не ответило, показывает собственный значок того же вида.
@MainActor
final class RemoteProgressLink {
  static let shared = RemoteProgressLink()

  private enum Mode { case pending, remote, local }

  @MainActor
  private final class Link {
    let card: ProgressCardModel
    let id = UUID().uuidString
    var mode = Mode.pending
    var subscription: AnyCancellable?
    var postScheduled = false
    init(card: ProgressCardModel) { self.card = card }
  }

  private var links: [Link] = []
  private var observers: [NSObjectProtocol] = []

  private init() {
    let distributed = DistributedNotificationCenter.default()
    observers.append(
      distributed.addObserver(forName: RemoteProgressMessage.ack, object: nil, queue: .main) {
        [weak self] note in
        let id = note.userInfo?["id"] as? String
        MainActor.assumeIsolated { self?.acknowledged(id) }
      })
    observers.append(
      distributed.addObserver(forName: RemoteProgressMessage.command, object: nil, queue: .main) {
        [weak self] note in
        let id = note.userInfo?["id"] as? String
        let command = (note.userInfo?["command"] as? String).flatMap(
          RemoteProgressMessage.Command.init(rawValue:))
        MainActor.assumeIsolated { self?.perform(command, id: id) }
      })
    // Основное приложение закрыли: ход возвращается в собственный значок.
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
      ) { [weak self] note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == RemoteProgressMessage.mainBundleID else { return }
        MainActor.assumeIsolated { self?.mainApplicationQuit() }
      })
  }

  func attach(_ card: ProgressCardModel) {
    guard !links.contains(where: { $0.card === card }) else { return }
    let link = Link(card: card)
    links.append(link)
    link.subscription = card.objectWillChange.sink { [weak self, weak link] _ in
      MainActor.assumeIsolated {
        guard let link, !link.postScheduled else { return }
        link.postScheduled = true
        Task { @MainActor in
          link.postScheduled = false
          self?.send(link)
        }
      }
    }
    let mainRunning = !NSRunningApplication.runningApplications(
      withBundleIdentifier: RemoteProgressMessage.mainBundleID
    ).isEmpty
    guard mainRunning else {
      becomeLocal(link)
      return
    }
    send(link)
    // Без ответа основного приложения значок показывает сам фоновый процесс.
    Task { [weak self, weak link] in
      try? await Task.sleep(for: .milliseconds(700))
      guard let link, link.mode == .pending else { return }
      self?.becomeLocal(link)
    }
  }

  func detach(_ card: ProgressCardModel) {
    guard let index = links.firstIndex(where: { $0.card === card }) else { return }
    let link = links.remove(at: index)
    link.subscription = nil
    switch link.mode {
    case .local: PangoZipStatusItem.shared.detach(card)
    case .pending, .remote:
      RemoteProgressMessage.post(
        RemoteProgressMessage.progress,
        RemoteProgressMessage.snapshot(card, id: link.id, removed: true))
    }
  }

  private func send(_ link: Link) {
    guard link.mode != .local, links.contains(where: { $0 === link }) else { return }
    RemoteProgressMessage.post(
      RemoteProgressMessage.progress,
      RemoteProgressMessage.snapshot(link.card, id: link.id, removed: false))
  }

  private func becomeLocal(_ link: Link) {
    guard link.mode != .local else { return }
    link.mode = .local
    PangoZipStatusItem.shared.attach(link.card)
  }

  private func acknowledged(_ id: String?) {
    guard let link = links.first(where: { $0.id == id }), link.mode == .pending else { return }
    link.mode = .remote
  }

  private func mainApplicationQuit() {
    for link in links where link.mode != .local { becomeLocal(link) }
  }

  private func perform(_ command: RemoteProgressMessage.Command?, id: String?) {
    guard let command, let link = links.first(where: { $0.id == id }) else { return }
    let card = link.card
    switch command {
    case .pause: card.togglePause?()
    case .cancel: card.cancel()
    case .restore: card.restore()
    case .reveal: card.reveal()
    }
  }
}

/// Сторона основного приложения: показывает ход фоновых процессов в своём значке.
@MainActor
final class RemoteProgressReceiver {
  static let shared = RemoteProgressReceiver()

  private var cards: [String: (card: ProgressCardModel, pid: pid_t)] = [:]
  private var observers: [NSObjectProtocol] = []

  func start() {
    guard observers.isEmpty else { return }
    observers.append(
      DistributedNotificationCenter.default().addObserver(
        forName: RemoteProgressMessage.progress, object: nil, queue: .main
      ) { [weak self] note in
        let info = note.userInfo ?? [:]
        nonisolated(unsafe) let payload = info
        MainActor.assumeIsolated { self?.receive(payload) }
      })
    // Фоновый процесс завершился, не убрав свой ход: убираем его сами.
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
      ) { [weak self] note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let pid = app?.processIdentifier
        MainActor.assumeIsolated { self?.processQuit(pid) }
      })
  }

  private func receive(_ info: [AnyHashable: Any]) {
    guard let id = info["id"] as? String else { return }
    if info["removed"] as? Bool == true {
      if let entry = cards.removeValue(forKey: id) {
        PangoZipStatusItem.shared.detach(entry.card)
      }
      return
    }
    let card: ProgressCardModel
    if let entry = cards[id] {
      card = entry.card
    } else {
      card = ProgressCardModel()
      let send = { (command: RemoteProgressMessage.Command) in
        RemoteProgressMessage.post(
          RemoteProgressMessage.command, ["id": id, "command": command.rawValue])
      }
      card.cancel = { send(.cancel) }
      card.restore = { send(.restore) }
      card.reveal = { send(.reveal) }
      cards[id] = (card, pid_t(info["pid"] as? Int ?? 0))
      RemoteProgressMessage.post(RemoteProgressMessage.ack, ["id": id])
      if info["canPause"] as? Bool == true { card.togglePause = { send(.pause) } }
    }
    RemoteProgressMessage.apply(info, to: card)
    PangoZipStatusItem.shared.attach(card)
  }

  private func processQuit(_ pid: pid_t?) {
    guard let pid else { return }
    for (id, entry) in cards where entry.pid == pid {
      cards[id] = nil
      PangoZipStatusItem.shared.detach(entry.card)
    }
  }
}
