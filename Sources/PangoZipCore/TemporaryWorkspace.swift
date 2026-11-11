import Darwin
import Foundation

// Прежние имена (Zipevra) только читаются: так очищаются данные, оставленные старой версией.
final class TemporaryWorkspace {
  let root: URL
  private let base: URL
  private var lockFD: Int32 = -1
  private static let baseName = "app.pangozip.workspaces"
  private static let legacyBaseName = "app.zipevra.workspaces"
  private static let transactionPrefixes = [".pangozip-", ".zipevra-"]

  /// Выбирает уникальный корень; создание папок и блокировки откладывается до первой операции.
  init(
    base: URL = FileManager.default.temporaryDirectory.appendingPathComponent(baseName)
  ) {
    self.base = base
    root = base.appendingPathComponent("workspace-" + UUID().uuidString)
  }

  /// Освобождает блокировку владельца, оставляя данные для восстановления при следующем запуске.
  deinit {
    if lockFD >= 0 { Darwin.close(lockFD) }
  }

  /// Удаляет доступные осиротевшие рабочие папки и удерживает блокировку текущего владельца.
  func ensure() throws {
    guard lockFD < 0 else { return }
    let manager = FileManager.default
    try manager.createDirectory(
      at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    Self.recoverWorkspaces(in: base)
    if base.lastPathComponent == Self.baseName {
      let legacy = base.deletingLastPathComponent().appendingPathComponent(Self.legacyBaseName)
      Self.recoverWorkspaces(in: legacy)
      if (try? manager.contentsOfDirectory(atPath: legacy.path).isEmpty) == true {
        try? manager.removeItem(at: legacy)
      }
    }
    try manager.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    lockFD = Darwin.open(
      root.appendingPathComponent("owner.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
      0o600)
    guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  /// Очищает рабочие области завершившихся процессов; занятые чужой блокировкой не трогает.
  private static func recoverWorkspaces(in base: URL) {
    let manager = FileManager.default
    for candidate in (try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil))
      ?? []
    {
      guard candidate.lastPathComponent.hasPrefix("workspace-"),
        (try? manager.attributesOfItem(atPath: candidate.path)[.type] as? FileAttributeType)
          == .typeDirectory
      else { continue }
      let fd = Darwin.open(
        candidate.appendingPathComponent("owner.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { continue }
      if flock(fd, LOCK_EX | LOCK_NB) == 0, recoverTransactions(in: candidate) {
        try? manager.removeItem(at: candidate)
      }
      Darwin.close(fd)
    }
  }

  /// Создаёт приватную папку сеанса внутри принадлежащей этому сервису рабочей области.
  func sessionDirectory(_ id: UUID) throws -> URL {
    try ensure()
    let directory = root.appendingPathComponent(id.uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory
  }

  /// Удаляет данные одного сеанса; повторный вызов после удаления безопасен.
  func removeSession(_ id: UUID) throws {
    let url = root.appendingPathComponent(id.uuidString)
    if FileManager.default.fileExists(atPath: url.path) { try Self.removeTree(url) }
  }

  /// Извлечённые папки могут быть без права записи; иначе их содержимое нельзя удалить.
  static func removeTree(_ url: URL) throws {
    let manager = FileManager.default
    if (try? manager.removeItem(at: url)) != nil { return }
    var info = stat()
    if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { chmod(url.path, 0o700) }
    let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey])
    // Обход идёт сверху вниз: права родителя исправляются до входа в него.
    while let item = enumerator?.nextObject() as? URL {
      if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        chmod(item.path, 0o700)
      }
    }
    try manager.removeItem(at: url)
  }

  /// Создаёт приватную папку рядом с архивом для замены на том же томе и записывает журнал.
  func transactionDirectory(nextTo archive: URL) throws -> URL {
    try ensure()
    let id = UUID().uuidString
    let directory = archive.deletingLastPathComponent().appendingPathComponent(
      Self.transactionPrefixes[0] + root.lastPathComponent + "-" + id)
    let journal = root.appendingPathComponent("transactions")
    try FileManager.default.createDirectory(
      at: journal, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let data = try JSONEncoder().encode(["path": directory.path])
    try data.write(
      to: journal.appendingPathComponent(directory.lastPathComponent + ".json"), options: .atomic)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
  }

  /// Удаляет рабочие данные до журнала, чтобы не потерять возможность повторной очистки.
  func removeTransaction(_ directory: URL) throws {
    if FileManager.default.fileExists(atPath: directory.path) { try Self.removeTree(directory) }
    let journal = root.appendingPathComponent("transactions").appendingPathComponent(
      directory.lastPathComponent + ".json")
    if FileManager.default.fileExists(atPath: journal.path) {
      try FileManager.default.removeItem(at: journal)
    }
  }

  /// Удаляет папки из согласованных журналов; ошибка удаления сохраняет область для повторной попытки.
  private static func recoverTransactions(in root: URL) -> Bool {
    let manager = FileManager.default
    let journals =
      (try? manager.contentsOfDirectory(
        at: root.appendingPathComponent("transactions"), includingPropertiesForKeys: nil)) ?? []
    var success = true
    for journal in journals {
      guard let data = try? Data(contentsOf: journal),
        let record = try? JSONDecoder().decode([String: String].self, from: data),
        let path = record["path"]
      else { continue }
      let directory = URL(fileURLWithPath: path)
      guard
        transactionPrefixes.contains(where: {
          directory.lastPathComponent.hasPrefix($0 + root.lastPathComponent + "-")
        }),
        journal.lastPathComponent == directory.lastPathComponent + ".json"
      else { continue }
      if let attributes = try? manager.attributesOfItem(atPath: path) {
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
        do { try removeTree(directory) } catch { success = false }
      }
    }
    return success
  }

  /// Очищает известные транзакции и освобождает блокировку; вызывающий отвечает за текущие операции.
  func cleanup() {
    if Self.recoverTransactions(in: root) { try? FileManager.default.removeItem(at: root) }
    if lockFD >= 0 {
      Darwin.close(lockFD)
      lockFD = -1
    }
    if (try? FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty) == true {
      try? FileManager.default.removeItem(at: base)
    }
  }
}
