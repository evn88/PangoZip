import Foundation

/// Служебные файлы и папки, которые macOS и Windows создают сами и которые не нужны получателю.
public enum SystemFiles {
  /// Точные имена; сравниваются без учёта регистра, потому что их создают разные системы.
  private static let names: Set<String> = [
    "__macosx", ".ds_store", ".appledouble", ".lsoverride", ".spotlight-v100", ".trashes",
    ".fseventsd", ".temporaryitems", ".documentrevisions-v100", ".apdisk",
    ".com.apple.timemachine.donotpresent", "icon\r", "thumbs.db", "ehthumbs.db",
    "ehthumbs_vista.db", "desktop.ini", "$recycle.bin",
  ]

  /// AppleDouble «._Имя» хранит атрибуты соседнего файла и без него бесполезен.
  public static func isSystemName(_ name: String) -> Bool {
    names.contains(name.lowercased()) || (name.hasPrefix("._") && name.count > 2)
  }

  /// Путь служебный, если служебен любой его компонент: всё внутри __MACOSX тоже скрывается.
  public static func isSystemPath(_ path: String) -> Bool {
    path.split(separator: "/").contains { isSystemName(String($0)) }
  }

  /// Убирает служебные узлы из дерева архива, не трогая сами записи.
  public static func filter(_ nodes: [ArchiveNode]) -> [ArchiveNode] {
    nodes.compactMap { node in
      guard !isSystemName(node.name) else { return nil }
      return ArchiveNode(
        path: node.path, name: node.name, entry: node.entry, children: node.children.map(filter))
    }
  }
}
