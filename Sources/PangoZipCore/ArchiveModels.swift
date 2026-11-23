import Foundation

public struct ArchiveEntry: Identifiable, Hashable, Sendable {
  public var id: String { path }
  public let path: String
  public let size: UInt64
  public let isDirectory: Bool
  public let isSymbolicLink: Bool
  public let createdAt: Date?
  public let modifiedAt: Date?
  public let permissions: String?
  public let owner: String?
  public let group: String?
  public let isEncrypted: Bool
  public let checksum: String?
  public let method: String?
  public let packedSize: UInt64?
  /// Оценка для файла из общего solid-блока 7z: его доля упакованного блока по исходному размеру.
  /// Точного размера у такого файла нет, поэтому оценка хранится отдельно от `packedSize`.
  public internal(set) var estimatedPackedSize: UInt64?
  public let additionalMetadata: [String: String]

  /// Сохраняет метаданные записи; безопасность пути проверяет парсер перед использованием.
  public init(
    path: String, size: UInt64 = 0, isDirectory: Bool = false, isSymbolicLink: Bool = false,
    createdAt: Date? = nil, modifiedAt: Date? = nil, permissions: String? = nil,
    owner: String? = nil, group: String? = nil, isEncrypted: Bool = false, checksum: String? = nil,
    method: String? = nil, packedSize: UInt64? = nil, estimatedPackedSize: UInt64? = nil,
    additionalMetadata: [String: String] = [:]
  ) {
    self.path = path
    self.size = size
    self.isDirectory = isDirectory
    self.isSymbolicLink = isSymbolicLink
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.permissions = permissions
    self.owner = owner
    self.group = group
    self.isEncrypted = isEncrypted
    self.checksum = checksum
    self.method = method
    self.packedSize = packedSize
    self.estimatedPackedSize = estimatedPackedSize
    self.additionalMetadata = additionalMetadata
  }
}

public struct ArchiveNode: Identifiable, Hashable, Sendable {
  public var id: String { path }
  public let path: String
  public let name: String
  public let entry: ArchiveEntry?
  public let children: [ArchiveNode]?

  /// Допускает синтетическую папку без исходной записи; nil children обозначает файл.
  public init(path: String, name: String, entry: ArchiveEntry?, children: [ArchiveNode]?) {
    self.path = path
    self.name = name
    self.entry = entry
    self.children = children
  }
}

public struct ArchiveSession: Sendable {
  public let id: UUID
  public let url: URL
  public let entries: [ArchiveEntry]
  public let roots: [ArchiveNode]
  public let format: String
  public let canModify: Bool
  /// Кодировка, из которой перекодированы имена; nil — имена прочитаны как есть.
  public let nameEncoding: ArchiveNameEncoding?

  /// Создаёт снимок сеанса; право выполнять операции подтверждает состояние ArchiveService.
  public init(
    id: UUID = UUID(), url: URL, entries: [ArchiveEntry], roots: [ArchiveNode],
    format: String = "unknown", canModify: Bool = false, nameEncoding: ArchiveNameEncoding? = nil
  ) {
    self.nameEncoding = nameEncoding
    self.id = id
    self.url = url
    self.entries = entries
    self.roots = roots
    self.format = format
    self.canModify = canModify
  }
}

public struct ArchiveEdit: Identifiable, Hashable, Sendable {
  public let id: UUID
  public let sessionID: UUID
  public let entry: ArchiveEntry
  public let fileURL: URL

  /// Связывает рабочую копию с записью и сеансом; сервис проверяет её перед сохранением.
  public init(id: UUID = UUID(), sessionID: UUID, entry: ArchiveEntry, fileURL: URL) {
    self.id = id
    self.sessionID = sessionID
    self.entry = entry
    self.fileURL = fileURL
  }
}
