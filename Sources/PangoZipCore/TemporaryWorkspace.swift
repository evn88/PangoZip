import Darwin
import Foundation

// Прежние имена (Zipevra) только читаются: так очищаются данные, оставленные старой версией.
final class TemporaryWorkspace {
  let root: URL
  private let base: URL
  private var lockFD: Int32 = -1
  /// Блокировки внутри активных транзакций: по ним другой процесс отличает живую папку от брошенной.
  private var transactionLocks: [String: Int32] = [:]
  private static let transactionLockName = ".owner.lock"
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
    for fd in transactionLocks.values { Darwin.close(fd) }
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

  /// Извлечённые папки могут быть без права записи, а копии заблокированных в Finder архивов
  /// наследуют флаг uchg через copyfile; без снятия прав и флагов их нельзя удалить.
  static func removeTree(_ url: URL) throws {
    let manager = FileManager.default
    if (try? manager.removeItem(at: url)) != nil { return }
    unlock(url)
    let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: nil)
    // Обход идёт сверху вниз: права родителя исправляются до входа в него.
    while let item = enumerator?.nextObject() as? URL { unlock(item) }
    try manager.removeItem(at: url)
  }

  /// Снимает пользовательские флаги неизменяемости и открывает папку для записи, не следуя ссылкам.
  private static func unlock(_ url: URL) {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return }
    let userFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
    if info.st_flags & userFlags != 0 { lchflags(url.path, info.st_flags & ~userFlags) }
    if info.st_mode & S_IFMT == S_IFDIR { chmod(url.path, 0o700) }
  }

  /// Срок для папок прежних версий без файла блокировки: по mtime верхнего уровня нельзя понять,
  /// идёт ли в них работа, поэтому они удаляются только заметно позже любой реальной операции.
  static let orphanAge: TimeInterval = 24 * 60 * 60

  /// Удаляет рядом с архивом брошенные транзакции (процесс убит, журнал во временной папке утрачен).
  /// Приложение и песочница Quick Look не видят рабочие области друг друга, поэтому владелец
  /// определяется по flock на файле блокировки внутри самой транзакции: он снимается только
  /// с завершением процесса или транзакции.
  func removeOrphanTransactions(in directory: URL, now: Date = Date()) {
    let manager = FileManager.default
    let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names {
      guard
        let prefix = Self.transactionPrefixes.first(where: { name.hasPrefix($0 + "workspace-") })
      else { continue }
      // Имя: <префикс>workspace-<UUID области>-<UUID транзакции>.
      let suffix = name.dropFirst(prefix.count + "workspace-".count)
      guard suffix.count == 73, let owner = UUID(uuidString: String(suffix.prefix(36))),
        UUID(uuidString: String(suffix.suffix(36))) != nil
      else { continue }
      let workspaceName = "workspace-" + owner.uuidString
      let legacyBase = base.deletingLastPathComponent().appendingPathComponent(
        Self.legacyBaseName)
      // Живая или восстанавливаемая по журналу область обрабатывается своим механизмом.
      guard workspaceName != root.lastPathComponent,
        ![base, legacyBase].contains(where: {
          manager.fileExists(atPath: $0.appendingPathComponent(workspaceName).path)
        })
      else { continue }
      let candidate = directory.appendingPathComponent(name)
      var info = stat()
      guard lstat(candidate.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
      let fd = Darwin.open(
        candidate.appendingPathComponent(Self.transactionLockName).path,
        O_RDWR | O_NOFOLLOW | O_CLOEXEC)
      if fd >= 0 {
        // Занятая блокировка или том без поддержки flock: владелец может быть жив, не трогаем.
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { try? Self.removeTree(candidate) }
        Darwin.close(fd)
        continue
      }
      // Файл блокировки есть, но не открылся: права или ссылка, удалять небезопасно.
      guard errno == ENOENT,
        now.timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec) >= Self.orphanAge
      else { continue }
      try? Self.removeTree(candidate)
    }
  }

  /// Создаёт приватную папку транзакции на томе архива и записывает журнал до её создания.
  /// Сначала используется системная временная папка этого тома (itemReplacementDirectory):
  /// rename результата остаётся атомарным, а в папке пользователя ничего не появляется.
  /// Если система не выдала её на том же томе (exFAT, SMB), папка создаётся рядом с архивом.
  func transactionDirectory(nextTo archive: URL) throws -> URL {
    try ensure()
    let parent = archive.deletingLastPathComponent()
    // Остатки прежних версий и запасного режима рядом с архивом убираются в любом случае.
    removeOrphanTransactions(in: parent)
    let container = Self.replacementContainer(for: parent)
    let directory = (container ?? parent).appendingPathComponent(
      Self.transactionPrefixes[0] + root.lastPathComponent + "-" + UUID().uuidString)
    do {
      let journal = root.appendingPathComponent("transactions")
      try FileManager.default.createDirectory(
        at: journal, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      var record = ["path": directory.path]
      if let container { record["container"] = container.path }
      try JSONEncoder().encode(record).write(
        to: journal.appendingPathComponent(directory.lastPathComponent + ".json"),
        options: .atomic)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      lockTransaction(directory)
    } catch {
      if let container { rmdir(container.path) }
      throw error
    }
    return directory
  }

  /// Держит flock до removeTransaction. Если том не поддерживает блокировки, транзакция
  /// остаётся без неё: уборка такую папку не тронет, её удалит восстановление по журналу.
  private func lockTransaction(_ directory: URL) {
    let fd = Darwin.open(
      directory.appendingPathComponent(Self.transactionLockName).path,
      O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
      transactionLocks[directory.path] = fd
    } else {
      Darwin.close(fd)
    }
  }

  /// Возвращает выданную системой временную папку, только если она на томе назначения.
  private static func replacementContainer(for parent: URL) -> URL? {
    guard
      let container = try? FileManager.default.url(
        for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true)
    else { return nil }
    var parentInfo = stat()
    var containerInfo = stat()
    guard stat(parent.path, &parentInfo) == 0, stat(container.path, &containerInfo) == 0,
      parentInfo.st_dev == containerInfo.st_dev
    else {
      rmdir(container.path)
      return nil
    }
    return container
  }

  /// Удаляет рабочие данные до журнала, чтобы не потерять возможность повторной очистки.
  func removeTransaction(_ directory: URL) throws {
    let journal = root.appendingPathComponent("transactions").appendingPathComponent(
      directory.lastPathComponent + ".json")
    let container = Self.container(of: directory, journal: journal)
    // Блокировка снимается и при ошибке удаления: брошенную папку затем уберёт уборка.
    defer {
      if let fd = transactionLocks.removeValue(forKey: directory.path) { Darwin.close(fd) }
    }
    if FileManager.default.fileExists(atPath: directory.path) { try Self.removeTree(directory) }
    if let container { rmdir(container.path) }
    if FileManager.default.fileExists(atPath: journal.path) {
      try FileManager.default.removeItem(at: journal)
    }
  }

  /// Системная папка из журнала принимается, только если она непосредственный родитель транзакции.
  /// rmdir удаляет её лишь пустой, поэтому чужие данные в ней не пострадают.
  private static func container(of directory: URL, journal: URL) -> URL? {
    guard let data = try? Data(contentsOf: journal),
      let record = try? JSONDecoder().decode([String: String].self, from: data),
      let path = record["container"],
      URL(fileURLWithPath: path).standardizedFileURL
        == directory.deletingLastPathComponent().standardizedFileURL
    else { return nil }
    return URL(fileURLWithPath: path)
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
      if let container = container(of: directory, journal: journal) { rmdir(container.path) }
    }
    return success
  }

  /// Очищает известные транзакции и освобождает блокировку; вызывающий отвечает за текущие операции.
  func cleanup() {
    if Self.recoverTransactions(in: root) { try? FileManager.default.removeItem(at: root) }
    for fd in transactionLocks.values { Darwin.close(fd) }
    transactionLocks.removeAll()
    if lockFD >= 0 {
      Darwin.close(lockFD)
      lockFD = -1
    }
    if (try? FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty) == true {
      try? FileManager.default.removeItem(at: base)
    }
  }
}
