import Foundation

public enum FinderInstallation {
  /// Находит родительское приложение при стандартном размещении расширения в Contents/PlugIns.
  public static func applicationURL(for extensionURL: URL) -> URL {
    extensionURL.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  /// Настоящая домашняя папка учётной записи. В песочнице расширения Foundation отдаёт
  /// вместо неё контейнер, поэтому путь берётся из записи пользователя в системе.
  public static var userHomeDirectory: URL {
    var entry = passwd()
    var result: UnsafeMutablePointer<passwd>?
    var buffer = [CChar](repeating: 0, count: max(sysconf(_SC_GETPW_R_SIZE_MAX), 4096))
    // Строка pw_dir лежит внутри буфера, поэтому читается, пока указатель на него действителен.
    let path: String? = buffer.withUnsafeMutableBufferPointer { storage in
      guard getpwuid_r(getuid(), &entry, storage.baseAddress, storage.count, &result) == 0,
        result != nil, let directory = entry.pw_dir, directory.pointee != 0
      else { return nil }
      return String(cString: directory)
    }
    if let path { return URL(fileURLWithPath: path, isDirectory: true) }
    return FileManager.default.homeDirectory(forUser: NSUserName())
      ?? FileManager.default.homeDirectoryForCurrentUser
  }

  /// Папки, установка в которые считается постоянной: общая и личная «Программы».
  public static var applicationDirectories: [URL] {
    [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      userHomeDirectory.appendingPathComponent("Applications", isDirectory: true),
    ]
  }

  /// Разрешает установленное приложение на доступном для записи диске вне временных папок.
  public static func isInstalledLocation(
    _ applicationURL: URL,
    applicationDirectories: [URL] = FinderInstallation.applicationDirectories
  ) -> Bool {
    guard applicationURL.isFileURL else { return false }
    let app = applicationURL.resolvingSymlinksInPath().standardizedFileURL
    let roots = applicationDirectories.filter(\.isFileURL).map {
      $0.resolvingSymlinksInPath().standardizedFileURL
    }
    let forbiddenNames = [".Trash", ".Trashes", "AppTranslocation"]
    let downloads = [userHomeDirectory.appendingPathComponent("Downloads", isDirectory: true)]
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
      Self.isOwnExtensionIdentifier(Bundle.main.bundleIdentifier)
      && ownParent.path == app.path
    guard !app.pathComponents.contains(where: { [".Trash", ".Trashes"].contains($0) }),
      isOwnParent || identifier(at: app) == "app.pangozip.desktop"
    else { return false }
    return executableExists(at: app.appendingPathComponent("Contents/MacOS/PangoZip"))
      && executableExists(
        at: app.appendingPathComponent(
          "Contents/Helpers/PangoZipWorker.app/Contents/MacOS/PangoZip"))
  }

  /// Распознаёт расширения комплекта: Finder Sync и действия Quick Action.
  static func isOwnExtensionIdentifier(_ identifier: String?) -> Bool {
    guard let identifier else { return false }
    return identifier == "app.pangozip.desktop.finder"
      || identifier.hasPrefix(QuickAction.identifierPrefix)
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
