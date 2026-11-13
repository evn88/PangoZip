import CryptoKit
import Foundation
import zlib

/// Контрольные суммы одного файла: размер, CRC32 и SHA-256 в виде шестнадцатеричных строк.
public struct ChecksumRecord: Sendable, Equatable, Identifiable {
  public let id: String
  /// Путь внутри архива либо имя файла самого архива.
  public let name: String
  public let size: UInt64
  /// Восемь символов в верхнем регистре, как в выводе 7-Zip.
  public let crc32: String
  /// Шестьдесят четыре символа в нижнем регистре, как у `shasum -a 256`.
  public let sha256: String

  public init(id: String, name: String, size: UInt64, crc32: String, sha256: String) {
    self.id = id
    self.name = name
    self.size = size
    self.crc32 = crc32
    self.sha256 = sha256
  }
}

/// Накапливает CRC32 и SHA-256 по частям, не удерживая данные файла в памяти.
public struct ChecksumAccumulator: Sendable {
  private var sha = SHA256()
  private var crc: UInt = crc32(0, nil, 0)
  public private(set) var byteCount: UInt64 = 0

  public init() {}

  /// Добавляет очередной блок данных к обеим суммам.
  public mutating func update(_ data: Data) {
    guard !data.isEmpty else { return }
    sha.update(data: data)
    data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: Bytef.self)
      var offset = 0
      // zlib принимает длину как UInt32, поэтому очень большой блок режется на части.
      while offset < bytes.count {
        let length = min(bytes.count - offset, Int(UInt32.max))
        crc = crc32(crc, bytes.baseAddress.map { $0 + offset }, uInt(length))
        offset += length
      }
    }
    byteCount += UInt64(data.count)
  }

  /// Возвращает итоговые значения; накопитель после этого остаётся пригодным для чтения.
  public func finish() -> (crc32: String, sha256: String) {
    (
      String(format: "%08X", UInt32(truncatingIfNeeded: crc)),
      sha.finalize().map { String(format: "%02x", $0) }.joined()
    )
  }
}

public enum ArchiveChecksums {
  static let chunkSize = 1 << 20

  /// Хеширует обычный файл потоком по 1 МиБ; отмена проверяется между блоками.
  public static func compute(
    fileAt url: URL, id: String? = nil, name: String? = nil,
    progress: (@Sendable (UInt64, UInt64) async -> Void)? = nil
  ) async throws -> ChecksumRecord {
    guard url.isFileURL else { throw ArchiveError.invalidOperation }
    let fingerprint = try FileFingerprint(url)
    guard fingerprint.type == .typeRegular else { throw ArchiveError.invalidOperation }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var accumulator = ChecksumAccumulator()
    var blocks = 0
    while true {
      try Task.checkCancellation()
      guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { break }
      accumulator.update(data)
      blocks += 1
      // Периодическая уступка потока не даёт чтению большого файла занять пул надолго.
      if blocks % 8 == 0 {
        await progress?(accumulator.byteCount, fingerprint.size)
        await Task.yield()
      }
    }
    try Task.checkCancellation()
    await progress?(accumulator.byteCount, fingerprint.size)
    let sums = accumulator.finish()
    return ChecksumRecord(
      id: id ?? url.path, name: name ?? url.lastPathComponent, size: accumulator.byteCount,
      crc32: sums.crc32, sha256: sums.sha256)
  }
}

/// Сравнение введённого пользователем значения с вычисленными суммами.
public enum ChecksumComparison {
  public enum Result: Sendable, Equatable { case empty, match, mismatch }

  /// Убирает любые пробельные символы и приводит значение к нижнему регистру.
  public static func normalize(_ value: String) -> String {
    String(value.unicodeScalars.filter { !$0.properties.isWhitespace }).lowercased()
  }

  /// Значения совпадают, если после нормализации они непусты и равны.
  public static func matches(_ input: String, _ value: String) -> Bool {
    let left = normalize(input)
    return !left.isEmpty && left == normalize(value)
  }

  /// Пустой ввод не оценивается; иначе нужно совпадение хотя бы с одним значением.
  public static func result(for input: String, candidates: [String]) -> Result {
    guard !normalize(input).isEmpty else { return .empty }
    return candidates.contains { matches(input, $0) } ? .match : .mismatch
  }
}
