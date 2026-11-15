import Foundation

/// Снимок программ, назначенных системой для типов архивов.
struct ArchiveAssociationSnapshot: Codable, Identifiable, Equatable {
  /// Программа запоминается по пути и идентификатору: путь мог измениться после обновления.
  struct Handler: Codable, Equatable {
    let path: String
    let bundleIdentifier: String?
  }

  let id: UUID
  let createdAt: Date
  /// Исходный снимок сделан при первом запуске и никогда не вытесняется.
  let isInitial: Bool
  /// Тип без назначенной программы в словарь не попадает.
  let handlers: [String: Handler]
}

/// Хранит исходный снимок и десять последних пользовательских между запусками приложения.
@MainActor
final class ArchiveAssociationSnapshotStore {
  static let key = "archiveAssociationSnapshots"
  static let limit = 10

  private let defaults: UserDefaults

  init(defaults: UserDefaults = UserDefaults(suiteName: "app.pangozip.desktop") ?? .standard) {
    self.defaults = defaults
  }

  /// Исходный снимок первым, за ним пользовательские от нового к старому.
  var snapshots: [ArchiveAssociationSnapshot] {
    guard let data = defaults.data(forKey: Self.key),
      let stored = try? JSONDecoder().decode([ArchiveAssociationSnapshot].self, from: data)
    else { return [] }
    return stored
  }

  var initial: ArchiveAssociationSnapshot? { snapshots.first(where: \.isInitial) }

  /// Запоминает состояние до любых изменений; повторные вызовы исходный снимок не трогают.
  func captureInitialIfNeeded(
    _ handlers: [String: ArchiveAssociationSnapshot.Handler], now: Date = Date()
  ) {
    guard initial == nil else { return }
    save(
      [ArchiveAssociationSnapshot(id: UUID(), createdAt: now, isInitial: true, handlers: handlers)]
        + snapshots)
  }

  /// Добавляет пользовательский снимок и вытесняет самые старые сверх предела.
  @discardableResult
  func add(_ handlers: [String: ArchiveAssociationSnapshot.Handler], now: Date = Date())
    -> ArchiveAssociationSnapshot
  {
    let snapshot = ArchiveAssociationSnapshot(
      id: UUID(), createdAt: now, isInitial: false, handlers: handlers)
    let all = snapshots
    let recent = ([snapshot] + all.filter { !$0.isInitial }).prefix(Self.limit)
    save(all.filter(\.isInitial) + recent)
    return snapshot
  }

  private func save(_ snapshots: [ArchiveAssociationSnapshot]) {
    guard let data = try? JSONEncoder().encode(snapshots) else { return }
    defaults.set(data, forKey: Self.key)
  }
}
