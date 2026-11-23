import Foundation
import Synchronization

/// Пауза операций одного архивного сервиса. Движок останавливается сигналом SIGSTOP
/// и продолжает с того же места после SIGCONT; время на паузе не входит в оценку скорости.
public final class EnginePause: Sendable {
  private struct State {
    var pausedAt: TimeInterval?
    var accumulated: TimeInterval = 0
  }

  private let state = Mutex(State())

  public init() {}

  public var isPaused: Bool { state.withLock { $0.pausedAt != nil } }

  public func pause() {
    let now = Self.uptime
    state.withLock { if $0.pausedAt == nil { $0.pausedAt = now } }
  }

  public func resume() {
    let now = Self.uptime
    state.withLock {
      guard let pausedAt = $0.pausedAt else { return }
      $0.accumulated += max(0, now - pausedAt)
      $0.pausedAt = nil
    }
  }

  /// Держит операцию между запусками движка, пока пауза не снята или задача не отменена:
  /// подготовка файлов и публикация результата тоже не идут на паузе.
  func waitWhilePaused() async {
    while isPaused, !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  /// Суммарное время на паузе к моменту `uptime`, включая ещё не закончившуюся паузу.
  func pausedTime(at uptime: TimeInterval) -> TimeInterval {
    state.withLock { $0.accumulated + ($0.pausedAt.map { max(0, uptime - $0) } ?? 0) }
  }

  static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
