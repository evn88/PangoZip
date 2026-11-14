import AppKit
import PangoZipCore
import UniformTypeIdentifiers

struct ArchiveAssociationType: Identifiable, Equatable {
  let identifier: String
  let fileExtension: String

  var id: String { identifier }
  var title: String { fileExtension.uppercased() }
}

@MainActor
protocol ArchiveAssociationsManaging {
  func defaultApplication(for typeIdentifier: String) -> URL?
  func setDefaultApplication(at applicationURL: URL, for typeIdentifier: String) async throws
  func bundleIdentifier(at applicationURL: URL) -> String?
  /// Находит программу из снимка: по прежнему пути, а если её переместили — по идентификатору.
  func resolveApplication(_ handler: ArchiveAssociationSnapshot.Handler) -> URL?
}

@MainActor
struct SystemArchiveAssociationsManager: ArchiveAssociationsManaging {
  private let workspace = NSWorkspace.shared

  func defaultApplication(for typeIdentifier: String) -> URL? {
    guard let type = UTType(typeIdentifier) else { return nil }
    return workspace.urlForApplication(toOpen: type)
  }

  func setDefaultApplication(at applicationURL: URL, for typeIdentifier: String) async throws {
    guard let type = UTType(typeIdentifier) else {
      throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: typeIdentifier])
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      workspace.setDefaultApplication(at: applicationURL, toOpen: type) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func bundleIdentifier(at applicationURL: URL) -> String? {
    Bundle(url: applicationURL)?.bundleIdentifier
  }

  func resolveApplication(_ handler: ArchiveAssociationSnapshot.Handler) -> URL? {
    if FileManager.default.fileExists(atPath: handler.path) {
      return URL(fileURLWithPath: handler.path)
    }
    return handler.bundleIdentifier.flatMap(workspace.urlForApplication(withBundleIdentifier:))
  }
}

@MainActor
final class ArchiveAssociationsModel: ObservableObject {
  struct Row: Identifiable {
    let type: ArchiveAssociationType
    let defaultApplicationName: String
    /// Тип открывается в PangoZip — в этой копии или в другой с тем же идентификатором.
    let isPangoZipDefault: Bool

    var id: String { type.id }
  }

  @Published private(set) var rows: [Row] = []
  @Published private(set) var snapshots: [ArchiveAssociationSnapshot] = []
  @Published private(set) var isApplying = false
  @Published private(set) var errorMessage: String?

  private let types: [ArchiveAssociationType]
  private let manager: any ArchiveAssociationsManaging
  private let store: ArchiveAssociationSnapshotStore
  private let applicationURL: URL
  private let applicationIdentifier: String?
  private let applicationName: String

  init(
    types: [ArchiveAssociationType]? = nil,
    manager: (any ArchiveAssociationsManaging)? = nil,
    store: ArchiveAssociationSnapshotStore? = nil,
    applicationURL: URL = Bundle.main.bundleURL,
    applicationIdentifier: String? = Bundle.main.bundleIdentifier,
    applicationName: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")
      as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "PangoZip"
  ) {
    self.types = types ?? Self.archiveTypes(from: Bundle.main.infoDictionary ?? [:])
    self.applicationURL = applicationURL
    self.applicationIdentifier = applicationIdentifier
    self.applicationName = applicationName
    self.manager = manager ?? SystemArchiveAssociationsManager()
    self.store = store ?? ArchiveAssociationSnapshotStore()
    refresh()
  }

  var isRunningFromApplications: Bool {
    let path = applicationURL.standardizedFileURL.path
    let applications = ["/Applications", NSHomeDirectory() + "/Applications"]
    return applications.contains { path == $0 || path.hasPrefix($0 + "/") }
  }

  var areAllAssigned: Bool { !rows.isEmpty && rows.allSatisfy(\.isPangoZipDefault) }

  /// Запоминает программы для архивов при первом запуске, до любых изменений из PangoZip.
  func captureInitialSnapshotIfNeeded() {
    guard !types.isEmpty else { return }
    store.captureInitialIfNeeded(currentHandlers())
    snapshots = store.snapshots
  }

  func refresh() {
    rows = types.map { type in
      let handlerURL = manager.defaultApplication(for: type.identifier)
      let isPangoZipDefault = handlerURL.map(isPangoZip) ?? false
      let handlerName =
        handlerURL.flatMap { Bundle(url: $0) }
        .flatMap { $0.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
        ?? handlerURL?.deletingPathExtension().lastPathComponent
        ?? L10n.tr("Не назначено")
      return Row(
        type: type, defaultApplicationName: isPangoZipDefault ? applicationName : handlerName,
        isPangoZipDefault: isPangoZipDefault)
    }
    snapshots = store.snapshots
  }

  /// Другая копия PangoZip (установленная или из папки сборки) тоже считается PangoZip.
  private func isPangoZip(_ url: URL) -> Bool {
    if url.standardizedFileURL == applicationURL.standardizedFileURL { return true }
    guard let applicationIdentifier else { return false }
    return manager.bundleIdentifier(at: url) == applicationIdentifier
  }

  private func currentHandlers() -> [String: ArchiveAssociationSnapshot.Handler] {
    var handlers: [String: ArchiveAssociationSnapshot.Handler] = [:]
    for type in types {
      guard let url = manager.defaultApplication(for: type.identifier) else { continue }
      handlers[type.identifier] = .init(
        path: url.standardizedFileURL.path, bundleIdentifier: manager.bundleIdentifier(at: url))
    }
    return handlers
  }

  /// Включение назначает PangoZip; выключение возвращает программу из исходного снимка.
  func setPangoZipDefault(_ isEnabled: Bool, for type: ArchiveAssociationType) async {
    if isEnabled {
      await apply([(type, applicationURL)])
    } else if let previous = store.initial?.handlers[type.identifier]
      .flatMap(manager.resolveApplication), !isPangoZip(previous)
    {
      await apply([(type, previous)])
    } else {
      errorMessage = L10n.tr(
        "Прежняя программа для %1$@ неизвестна. Выберите её в Finder: «Свойства» → «Открывать в программе».",
        type.title)
    }
  }

  func assignAll() async {
    await apply(rows.filter { !$0.isPangoZipDefault }.map { ($0.type, applicationURL) })
  }

  /// Сохраняет текущие назначения, чтобы к ним можно было вернуться позже.
  func saveSnapshot() {
    store.add(currentHandlers())
    snapshots = store.snapshots
  }

  /// Возвращает программы из снимка; типы без записи и удалённые программы пропускаются.
  func restore(_ snapshot: ArchiveAssociationSnapshot) async {
    let changes = types.compactMap { type -> (ArchiveAssociationType, URL)? in
      guard let url = snapshot.handlers[type.identifier].flatMap(manager.resolveApplication),
        url.standardizedFileURL
          != manager.defaultApplication(for: type.identifier)?.standardizedFileURL
      else { return nil }
      return (type, url)
    }
    await apply(changes)
  }

  private func apply(_ changes: [(type: ArchiveAssociationType, url: URL)]) async {
    guard !isApplying else { return }
    isApplying = true
    errorMessage = nil
    var failures: [String] = []
    for change in changes {
      do {
        try await manager.setDefaultApplication(at: change.url, for: change.type.identifier)
      } catch {
        failures.append(
          isPangoZip(change.url)
            ? L10n.tr(
              "Не удалось назначить PangoZip для %1$@: %2$@", change.type.title,
              error.localizedDescription)
            : L10n.tr(
              "Не удалось вернуть программу для %1$@: %2$@", change.type.title,
              error.localizedDescription))
      }
    }
    refresh()
    errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    isApplying = false
  }

  static func archiveTypes(from info: [String: Any]) -> [ArchiveAssociationType] {
    let documentTypes = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
    var seen = Set<String>()
    return documentTypes.flatMap { documentType -> [ArchiveAssociationType] in
      let extensions = documentType["CFBundleTypeExtensions"] as? [String] ?? []
      let identifiers = documentType["CFBundleTypeUTIs"] as? [String] ?? []
      return extensions.enumerated().compactMap { index, fileExtension in
        let identifier =
          identifiers.indices.contains(index)
          ? identifiers[index] : UTType(filenameExtension: fileExtension)?.identifier
        guard let identifier, seen.insert(identifier).inserted else { return nil }
        return ArchiveAssociationType(identifier: identifier, fileExtension: fileExtension)
      }
    }
  }
}
