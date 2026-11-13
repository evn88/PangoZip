import Foundation
import Synchronization

/// Запоминает объекты, которые PangoZip сам опубликовал на диске, чтобы слежение за папками
/// не принимало собственные архивы и извлечённые файлы за новые.
public final class OwnOutputRegistry: Sendable {
  public static let shared = OwnOutputRegistry()
  private let state = Mutex<[String: Date]>([:])
  private static let lifetime: TimeInterval = 3600

  public init() {}

  /// Записывает путь опубликованного объекта; устаревшие записи удаляются при каждой записи.
  public func register(_ url: URL, now: Date = Date()) {
    let key = Self.key(url)
    state.withLock { items in
      items = items.filter { now.timeIntervalSince($0.value) < Self.lifetime }
      items[key] = now
    }
  }

  /// Истина, если объект опубликован самим PangoZip за последний час.
  public func contains(_ url: URL, now: Date = Date()) -> Bool {
    let key = Self.key(url)
    return state.withLock { items in
      guard let date = items[key] else { return false }
      return now.timeIntervalSince(date) < Self.lifetime
    }
  }

  private static func key(_ url: URL) -> String { url.standardizedFileURL.path }
}
