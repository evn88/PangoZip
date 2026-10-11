import Foundation

public enum FinderInstallation {
  public static func applicationURL(for extensionURL: URL) -> URL {
    extensionURL.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  public static func isAvailable(at applicationURL: URL) -> Bool {
    let app = applicationURL.resolvingSymlinksInPath().standardizedFileURL
    // Sandbox разрешает расширению читать метаданные родительского комплекта,
    // но не его Info.plist. Собственный родитель известен из URL подписанного расширения.
    let ownParent = self.applicationURL(for: Bundle.main.bundleURL).resolvingSymlinksInPath()
      .standardizedFileURL
    let isOwnParent =
      Bundle.main.bundleIdentifier == "app.pangozip.desktop.finder"
      && ownParent.path == app.path
    guard !app.pathComponents.contains(where: { [".Trash", ".Trashes"].contains($0) }),
      isOwnParent || identifier(at: app) == "app.pangozip.desktop"
    else { return false }
    return executableExists(at: app.appendingPathComponent("Contents/MacOS/PangoZip"))
      && executableExists(
        at: app.appendingPathComponent(
          "Contents/Helpers/PangoZipWorker.app/Contents/MacOS/PangoZip"))
  }

  private static func identifier(at app: URL) -> String? {
    guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return nil }
    return info["CFBundleIdentifier"] as? String
  }

  private static func executableExists(at url: URL) -> Bool {
    // Проверяем наличие исполняемого файла по метаданным; помощник запускается через NSWorkspace.
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let permissions = attributes[.posixPermissions] as? NSNumber
    else { return false }
    return permissions.intValue & 0o111 != 0
  }
}
