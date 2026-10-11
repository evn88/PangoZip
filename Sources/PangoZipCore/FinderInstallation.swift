import Foundation

public enum FinderInstallation {
  /// Находит родительское приложение при стандартном размещении расширения в Contents/PlugIns.
  public static func applicationURL(for extensionURL: URL) -> URL {
    extensionURL.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  /// Разрешает установленное приложение на доступном для записи диске вне временных папок.
  public static func isInstalledLocation(
    _ applicationURL: URL,
    applicationDirectories: [URL] = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      (FileManager.default.homeDirectory(forUser: NSUserName())
        ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent(
          "Applications", isDirectory: true),
    ]
  ) -> Bool {
    guard applicationURL.isFileURL else { return false }
    let app = applicationURL.resolvingSymlinksInPath().standardizedFileURL
    let roots = applicationDirectories.filter(\.isFileURL).map {
      $0.resolvingSymlinksInPath().standardizedFileURL
    }
    let forbiddenNames = [".Trash", ".Trashes", "AppTranslocation"]
    // Явное имя пользователя не подменяет домашнюю папку контейнером расширения.
    let home =
      FileManager.default.homeDirectory(forUser: NSUserName())
      ?? FileManager.default.homeDirectoryForCurrentUser
    let downloads = [home.appendingPathComponent("Downloads", isDirectory: true)]
    guard app.pathExtension == "app",
      !app.pathComponents.contains(where: forbiddenNames.contains),
      !downloads.contains(where: { contains(app, in: $0.resolvingSymlinksInPath()) }),
      roots.contains(where: { root in
        guard contains(app, in: root) else { return false }
        return !app.pathComponents.dropFirst(root.pathComponents.count).dropLast()
          .contains(where: { $0.hasSuffix(".app") })
      }),
      let volume = try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey, .isDirectoryKey]),
      volume.isDirectory == true, volume.volumeIsReadOnly == false
    else { return false }
    return true
  }

  /// Проверяет принадлежность папке по компонентам пути, а не по строковому префиксу.
  private static func contains(_ item: URL, in directory: URL) -> Bool {
    let root = directory.standardizedFileURL.pathComponents
    let path = item.standardizedFileURL.pathComponents
    return path.count > root.count && path.starts(with: root)
  }

  /// Проверяет приложение вне корзины и наличие исполняемых файлов перед показом команд Finder.
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

  /// Читает идентификатор непосредственно из Info.plist; недоступный или неверный файл даёт nil.
  private static func identifier(at app: URL) -> String? {
    guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return nil }
    return info["CFBundleIdentifier"] as? String
  }

  /// Требует обычный файл с правом исполнения; сам запуск выполняет NSWorkspace.
  private static func executableExists(at url: URL) -> Bool {
    // Проверяем наличие исполняемого файла по метаданным; помощник запускается через NSWorkspace.
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let permissions = attributes[.posixPermissions] as? NSNumber
    else { return false }
    return permissions.intValue & 0o111 != 0
  }
}
