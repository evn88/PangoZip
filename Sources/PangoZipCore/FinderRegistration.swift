import CoreServices
import Foundation

public struct FinderRegistrationPlan: Sendable, Equatable {
  public let applicationURL: URL
  public let workerURL: URL
  public let extensionURL: URL

  /// Проверяет установленное приложение и встроенные компоненты до регистрации в macOS.
  public static func make(
    applicationURL: URL,
    applicationDirectories: [URL] = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      (FileManager.default.homeDirectory(forUser: NSUserName())
        ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent(
          "Applications", isDirectory: true),
    ]
  ) throws -> Self {
    guard
      FinderInstallation.isInstalledLocation(
        applicationURL, applicationDirectories: applicationDirectories)
    else { throw FinderRegistrationError.notInstalled }
    let app = applicationURL.resolvingSymlinksInPath().standardizedFileURL

    let worker = app.appendingPathComponent("Contents/Helpers/PangoZipWorker.app")
    let finder = app.appendingPathComponent("Contents/PlugIns/PangoZipFinderSync.appex")
    try validateBundle(
      app, identifier: "app.pangozip.desktop", executable: "PangoZip", type: "APPL")
    try validateBundle(
      worker, identifier: "app.pangozip.desktop.worker", executable: "PangoZip", type: "APPL")
    try validateBundle(
      finder, identifier: "app.pangozip.desktop.finder", executable: "PangoZipFinderSync",
      type: "XPC!",
      extensionPoint: "com.apple.FinderSync")
    guard contains(worker.resolvingSymlinksInPath(), in: app),
      contains(finder.resolvingSymlinksInPath(), in: app)
    else { throw FinderRegistrationError.invalidBundle(app) }
    return Self(applicationURL: app, workerURL: worker, extensionURL: finder)
  }

  /// Сравнивает компоненты путей, исключая совпадение только по строковому префиксу.
  private static func contains(_ item: URL, in directory: URL) -> Bool {
    let root = directory.standardizedFileURL.pathComponents
    let path = item.standardizedFileURL.pathComponents
    return path.count > root.count && path.starts(with: root)
  }

  /// Проверяет идентификатор, тип bundle и обычный исполняемый файл внутри комплекта.
  private static func validateBundle(
    _ bundle: URL, identifier: String, executable: String, type: String,
    extensionPoint: String? = nil
  ) throws {
    let binary = bundle.appendingPathComponent("Contents/MacOS/\(executable)")
    guard
      let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      info["CFBundleIdentifier"] as? String == identifier,
      info["CFBundleExecutable"] as? String == executable,
      info["CFBundlePackageType"] as? String == type,
      let attributes = try? FileManager.default.attributesOfItem(atPath: binary.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let permissions = attributes[.posixPermissions] as? NSNumber,
      permissions.intValue & 0o111 != 0,
      contains(binary.resolvingSymlinksInPath(), in: bundle.resolvingSymlinksInPath())
    else { throw FinderRegistrationError.invalidBundle(bundle) }
    if let extensionPoint,
      (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String
        != extensionPoint
    {
      throw FinderRegistrationError.invalidBundle(bundle)
    }
  }
}

public enum FinderRegistrationError: LocalizedError, Sendable, Equatable {
  case notInstalled
  case invalidBundle(URL)
  case registrationFailed(URL, Int32)

  public var errorDescription: String? {
    switch self {
    case .notInstalled:
      L10n.tr("Переместите PangoZip в папку «Программы» и откройте приложение оттуда.")
    case .invalidBundle(let url):
      L10n.tr(
        "Компонент %1$@ отсутствует или повреждён. Установите PangoZip заново.",
        String(describing: url.lastPathComponent))
    case .registrationFailed(let url, let status):
      L10n.tr(
        "Не удалось зарегистрировать %1$@ в macOS (код %2$@).",
        String(describing: url.lastPathComponent), String(describing: status))
    }
  }
}

public enum FinderRegistration {
  /// Обновляет записи приложения и worker; встроенное расширение обнаруживает сама macOS.
  public static func register(_ plan: FinderRegistrationPlan) async throws {
    try await register(plan) { url, update in
      LSRegisterURL(url as CFURL, update)
    }
  }

  /// Выполняет синхронный API вне главного потока и дожидается завершения при отмене.
  static func register(
    _ plan: FinderRegistrationPlan,
    executor: @escaping @Sendable (URL, Bool) -> Int32
  ) async throws {
    try Task.checkCancellation()
    let task = Task.detached(priority: .utility) {
      for url in [plan.applicationURL, plan.workerURL] {
        try Task.checkCancellation()
        let status = executor(url, true)
        guard status == noErr else {
          throw FinderRegistrationError.registrationFailed(url, status)
        }
      }
      try Task.checkCancellation()
    }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
