import Darwin
import Foundation

// Сохраняем имена рабочих папок для восстановления и очистки данных прежней версии.
final class TemporaryWorkspace {
  let root: URL
  private let base: URL
  private var lockFD: Int32 = -1

  init(
    base: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "app.zipevra.workspaces")
  ) {
    self.base = base
    root = base.appendingPathComponent("workspace-" + UUID().uuidString)
  }

  deinit {
    if lockFD >= 0 { Darwin.close(lockFD) }
  }

  func ensure() throws {
    guard lockFD < 0 else { return }
    let manager = FileManager.default
    try manager.createDirectory(
      at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for candidate in try manager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
      guard candidate.lastPathComponent.hasPrefix("workspace-"),
        (try? manager.attributesOfItem(atPath: candidate.path)[.type] as? FileAttributeType)
          == .typeDirectory
      else { continue }
      let fd = Darwin.open(
        candidate.appendingPathComponent("owner.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { continue }
      if flock(fd, LOCK_EX | LOCK_NB) == 0, Self.recoverTransactions(in: candidate) {
        try? manager.removeItem(at: candidate)
      }
      Darwin.close(fd)
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

  func sessionDirectory(_ id: UUID) throws -> URL {
    try ensure()
    let directory = root.appendingPathComponent(id.uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory
  }

  func removeSession(_ id: UUID) throws {
    let url = root.appendingPathComponent(id.uuidString)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  func transactionDirectory(nextTo archive: URL) throws -> URL {
    try ensure()
    let id = UUID().uuidString
    let directory = archive.deletingLastPathComponent().appendingPathComponent(
      ".zipevra-" + root.lastPathComponent + "-" + id)
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

  func removeTransaction(_ directory: URL) throws {
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    let journal = root.appendingPathComponent("transactions").appendingPathComponent(
      directory.lastPathComponent + ".json")
    if FileManager.default.fileExists(atPath: journal.path) {
      try FileManager.default.removeItem(at: journal)
    }
  }

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
      guard directory.lastPathComponent.hasPrefix(".zipevra-" + root.lastPathComponent + "-"),
        journal.lastPathComponent == directory.lastPathComponent + ".json"
      else { continue }
      if let attributes = try? manager.attributesOfItem(atPath: path) {
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
        do { try manager.removeItem(at: directory) } catch { success = false }
      }
    }
    return success
  }

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
