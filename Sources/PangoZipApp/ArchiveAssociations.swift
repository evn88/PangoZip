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
  func setCurrentApplicationAsDefault(for typeIdentifier: String) async throws
}

@MainActor
struct SystemArchiveAssociationsManager: ArchiveAssociationsManaging {
  let applicationURL: URL
  private let workspace = NSWorkspace.shared

  func defaultApplication(for typeIdentifier: String) -> URL? {
    guard let type = UTType(typeIdentifier) else { return nil }
    return workspace.urlForApplication(toOpen: type)
  }

  func setCurrentApplicationAsDefault(for typeIdentifier: String) async throws {
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
}

@MainActor
final class ArchiveAssociationsModel: ObservableObject {
  struct Row: Identifiable {
    let type: ArchiveAssociationType
    let defaultApplicationName: String

    var id: String { type.id }
  }

  @Published private(set) var rows: [Row] = []
  @Published var selectedTypeIdentifiers = Set<String>()
  @Published private(set) var isApplying = false
  @Published private(set) var errorMessage: String?

  private let types: [ArchiveAssociationType]
  private let manager: any ArchiveAssociationsManaging
  private let applicationURL: URL
  private let applicationName: String

  init(
    types: [ArchiveAssociationType]? = nil,
    manager: (any ArchiveAssociationsManaging)? = nil,
    applicationURL: URL = Bundle.main.bundleURL,
    applicationName: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")
      as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "PangoZip"
  ) {
    self.types = types ?? Self.archiveTypes(from: Bundle.main.infoDictionary ?? [:])
    self.applicationURL = applicationURL
    self.applicationName = applicationName
    self.manager = manager ?? SystemArchiveAssociationsManager(applicationURL: applicationURL)
    refresh()
  }

  var isRunningFromApplications: Bool {
    let path = applicationURL.standardizedFileURL.path
    let applications = ["/Applications", NSHomeDirectory() + "/Applications"]
    return applications.contains { path == $0 || path.hasPrefix($0 + "/") }
  }

  func refresh() {
    rows = types.map { type in
      let applicationURL = manager.defaultApplication(for: type.identifier)
      let isPangoZipDefault =
        applicationURL?.standardizedFileURL == self.applicationURL.standardizedFileURL
      let applicationName =
        applicationURL.flatMap { Bundle(url: $0) }
        .flatMap { $0.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
        ?? applicationURL?.deletingPathExtension().lastPathComponent
        ?? L10n.tr("Не назначено")
      return Row(
        type: type,
        defaultApplicationName: isPangoZipDefault ? self.applicationName : applicationName)
    }
  }

  func applySelection() async {
    guard !isApplying else { return }
    let selected = types.filter { selectedTypeIdentifiers.contains($0.identifier) }
    guard !selected.isEmpty else {
      errorMessage = L10n.tr("Не выбрано ни одного типа архивов.")
      return
    }

    isApplying = true
    errorMessage = nil
    var failures: [String] = []
    for type in selected {
      do {
        try await manager.setCurrentApplicationAsDefault(for: type.identifier)
      } catch {
        failures.append(
          L10n.tr(
            "Не удалось назначить PangoZip для %1$@: %2$@", type.title, error.localizedDescription))
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
