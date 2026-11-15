import CoreFoundation
import Foundation

/// Кодировка имён файлов в старых ZIP: архивы из Windows хранят их без признака UTF-8.
public struct ArchiveNameEncoding: Sendable, Equatable, Identifiable {
  private enum Script: Sendable {
    case cyrillic, latin, japanese, chinese, korean
  }

  /// Номер кодовой страницы Windows, по которому кодировку выбирает пользователь.
  public let codePage: Int
  private let encoding: String.Encoding
  private let script: Script
  /// Языки интерфейса, при которых эта кодировка наиболее вероятна.
  private let languages: [String]

  public var id: Int { codePage }

  /// Локализованное системой название с номером страницы: «Кириллица (DOS) — CP866».
  public var title: String { String.localizedName(of: encoding) + " — CP\(codePage)" }

  private init(
    _ codePage: Int, _ encoding: String.Encoding, _ script: Script, _ languages: [String]
  ) {
    self.codePage = codePage
    self.encoding = encoding
    self.script = script
    self.languages = languages
  }

  /// Страницы DOS есть только среди кодировок CoreFoundation.
  private static func dos(_ encoding: CFStringEncodings) -> String.Encoding {
    String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
  }

  /// Кодировки, которые встречаются в архивах из DOS и Windows, от частых к редким.
  public static let all: [ArchiveNameEncoding] = [
    .init(866, dos(.dosRussian), .cyrillic, ["ru", "uk", "be", "bg", "kk"]),
    .init(1251, .windowsCP1251, .cyrillic, ["ru", "uk", "be", "bg", "sr", "kk"]),
    .init(437, dos(.dosLatinUS), .latin, ["en"]),
    .init(850, dos(.dosLatin1), .latin, ["de", "fr", "es", "it", "pt"]),
    .init(1252, .windowsCP1252, .latin, ["de", "fr", "es", "it", "pt", "en"]),
    .init(852, dos(.dosLatin2), .latin, ["pl", "cs", "hu", "sr", "hr", "sk"]),
    .init(1250, .windowsCP1250, .latin, ["pl", "cs", "hu", "sr", "hr", "sk"]),
    .init(857, dos(.dosTurkish), .latin, ["tr"]),
    .init(1254, .windowsCP1254, .latin, ["tr"]),
    .init(932, dos(.dosJapanese), .japanese, ["ja"]),
    .init(936, dos(.dosChineseSimplif), .chinese, ["zh"]),
    .init(950, dos(.dosChineseTrad), .chinese, ["zh"]),
    .init(949, dos(.dosKorean), .korean, ["ko"]),
  ]

  public static func named(_ codePage: Int) -> ArchiveNameEncoding? {
    all.first { $0.codePage == codePage }
  }

  /// Строго декодирует имя; nil означает, что байты не принадлежат этой кодировке.
  public func decode(_ name: Data) -> String? { String(data: name, encoding: encoding) }

  /// Подбирает кодировку, в которой имена состоят из букв ожидаемой письменности.
  /// При равном счёте выигрывает кодировка языка пользователя, затем более частая.
  public static func detect(
    _ names: [Data], preferredLanguages: [String] = Locale.preferredLanguages
  ) -> ArchiveNameEncoding? {
    let languages = preferredLanguages.map { String($0.prefix(2)).lowercased() }
    var best: (encoding: ArchiveNameEncoding, score: Int, rank: Int)?
    for (index, candidate) in all.enumerated() {
      guard let score = candidate.score(names) else { continue }
      let language = languages.firstIndex { candidate.languages.contains($0) } ?? languages.count
      let rank = language * all.count + index
      if best.map({ score > $0.score || (score == $0.score && rank < $0.rank) }) ?? true {
        best = (candidate, score, rank)
      }
    }
    return best?.encoding
  }

  /// Буква ожидаемой письменности даёт очко, любой другой не-ASCII символ его отнимает:
  /// неверная однобайтовая кодировка превращает буквы в псевдографику и редкие знаки.
  private func score(_ names: [Data]) -> Int? {
    var total = 0
    var expected = 0
    var asciiLetters = 0
    for name in names {
      guard let text = decode(name) else { return nil }
      for scalar in text.unicodeScalars {
        if scalar.isASCII {
          if scalar.properties.isAlphabetic { asciiLetters += 1 }
        } else if expects(scalar) {
          expected += 1
          total += 1
        } else {
          total -= 1
        }
      }
    }
    // В латинице буквы с диакритикой редки. Если их больше, чем обычных, это кириллица
    // или иероглифы, прочитанные как западная кодировка: там любой байт выглядит буквой.
    if script == .latin, expected > asciiLetters { return -expected }
    return total
  }

  private func expects(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    switch script {
    case .cyrillic:
      // Русский алфавит и буквы украинского и белорусского; прочая кириллица — признак ошибки.
      return (0x0410...0x044F).contains(value)
        || [0x0401, 0x0451, 0x0404, 0x0454, 0x0406, 0x0456, 0x0407, 0x0457, 0x0490, 0x0491]
          .contains(value)
    case .latin: return (0x00C0...0x024F).contains(value) && scalar.properties.isAlphabetic
    case .japanese:
      return (0x3040...0x30FF).contains(value) || (0x4E00...0x9FFF).contains(value)
        || (0xFF66...0xFF9F).contains(value)
    case .chinese: return (0x4E00...0x9FFF).contains(value)
    case .korean: return (0xAC00...0xD7A3).contains(value)
    }
  }
}

/// Переписывает имена в ZIP в UTF-8: встроенный 7zz на macOS не перекодирует старые страницы.
/// Исходный архив не меняется — исправленная копия пишется в указанный файл.
public enum ZipNameRepair {
  private struct Entry {
    /// Запись центрального каталога целиком.
    let record: Data
    let flags: UInt16
    let name: Data
    let localOffset: Int
    /// Имя без признака UTF-8, с не-ASCII байтами и без юникодного дубля в дополнительном поле.
    let isLegacy: Bool
  }

  private struct Layout {
    let entries: [Entry]
    let directoryOffset: Int
    /// Конец центрального каталога: запись EOCD и комментарий архива.
    let trailer: Data
  }

  private static let maximumDirectoryBytes = 64 * 1024 * 1024

  /// Возвращает имена, которым нужна перекодировка. nil — архив не ZIP, устроен сложнее
  /// (ZIP64, несколько томов), либо все имена уже читаются как UTF-8.
  public static func legacyNames(in url: URL) -> [Data]? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let layout = try? read(handle) else { return nil }
    let names = layout.entries.filter(\.isLegacy).map(\.name)
    guard !names.isEmpty, names.contains(where: { String(data: $0, encoding: .utf8) == nil })
    else { return nil }
    return names
  }

  /// Пишет копию архива с именами в UTF-8. Сжатые данные копируются без изменений.
  public static func rewrite(_ url: URL, to output: URL, using encoding: ArchiveNameEncoding)
    throws
  {
    let source = try FileHandle(forReadingFrom: url)
    defer { try? source.close() }
    let layout = try read(source)
    guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
      throw ArchiveError.invalidOperation
    }
    let target = try FileHandle(forWritingTo: output)
    defer { try? target.close() }
    let order = layout.entries.indices.sorted {
      layout.entries[$0].localOffset < layout.entries[$1].localOffset
    }
    var written = 0
    var newOffsets = [Int](repeating: 0, count: layout.entries.count)
    var newNames = [Data](repeating: Data(), count: layout.entries.count)
    // Всё до первой записи (например, заглушка самораспаковки) переносится как есть.
    try copy(
      from: source, range: 0..<(order.first.map { layout.entries[$0].localOffset } ?? 0),
      to: target, written: &written)
    for (position, index) in order.enumerated() {
      let entry = layout.entries[index]
      let end =
        position + 1 < order.count
        ? layout.entries[order[position + 1]].localOffset : layout.directoryOffset
      try source.seek(toOffset: UInt64(entry.localOffset))
      guard var header = try source.read(upToCount: 30), header.count == 30,
        header.uint32(0) == 0x0403_4B50
      else { throw ArchiveError.invalidArchive }
      let nameLength = Int(header.uint16(26))
      guard let localName = try source.read(upToCount: nameLength), localName == entry.name,
        entry.localOffset + 30 + nameLength <= end
      else { throw ArchiveError.invalidArchive }
      var name = entry.name
      if entry.isLegacy {
        guard let text = encoding.decode(entry.name), let utf8 = text.data(using: .utf8),
          utf8.count <= Int(UInt16.max)
        else { throw ArchiveError.invalidArchive }
        name = utf8
        header.setUInt16(header.uint16(6) | 0x0800, at: 6)
        header.setUInt16(UInt16(name.count), at: 26)
      }
      newOffsets[index] = written
      newNames[index] = name
      try target.write(contentsOf: header + name)
      written += 30 + name.count
      try copy(
        from: source, range: (entry.localOffset + 30 + nameLength)..<end, to: target,
        written: &written)
    }
    let directoryOffset = written
    for (index, entry) in layout.entries.enumerated() {
      var record = entry.record
      let tail = record.subdata(in: (46 + entry.name.count)..<record.count)
      record = record.subdata(in: 0..<46)
      if entry.isLegacy { record.setUInt16(entry.flags | 0x0800, at: 8) }
      record.setUInt16(UInt16(newNames[index].count), at: 28)
      guard newOffsets[index] < Int(UInt32.max) else { throw ArchiveError.outputLimit }
      record.setUInt32(UInt32(newOffsets[index]), at: 42)
      try target.write(contentsOf: record + newNames[index] + tail)
      written += record.count + newNames[index].count + tail.count
    }
    guard directoryOffset < Int(UInt32.max), written - directoryOffset < Int(UInt32.max) else {
      throw ArchiveError.outputLimit
    }
    var trailer = layout.trailer
    trailer.setUInt32(UInt32(written - directoryOffset), at: 12)
    trailer.setUInt32(UInt32(directoryOffset), at: 16)
    try target.write(contentsOf: trailer)
  }

  /// Разбирает центральный каталог обычного однотомного ZIP без расширения ZIP64.
  private static func read(_ handle: FileHandle) throws -> Layout {
    let size = Int(try handle.seekToEnd())
    let tailLength = min(size, 22 + Int(UInt16.max))
    try handle.seek(toOffset: UInt64(size - tailLength))
    guard let tail = try handle.read(upToCount: tailLength), tail.count >= 22 else {
      throw ArchiveError.invalidArchive
    }
    // Запись конца каталога ищется с хвоста: после неё может идти только комментарий.
    guard
      let start = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
        tail.uint32($0) == 0x0605_4B50 && $0 + 22 + Int(tail.uint16($0 + 20)) == tail.count
      })
    else { throw ArchiveError.invalidArchive }
    let trailer = tail.subdata(in: start..<tail.count)
    let count = Int(trailer.uint16(10))
    let directorySize = Int(trailer.uint32(12))
    let directoryOffset = Int(trailer.uint32(16))
    guard trailer.uint16(4) == 0, trailer.uint16(6) == 0, trailer.uint16(8) == trailer.uint16(10),
      count < Int(UInt16.max), trailer.uint32(12) != UInt32.max, trailer.uint32(16) != UInt32.max,
      directorySize <= maximumDirectoryBytes,
      directoryOffset + directorySize == size - trailer.count
    else { throw ArchiveError.invalidArchive }
    try handle.seek(toOffset: UInt64(directoryOffset))
    guard let directory = try handle.read(upToCount: directorySize),
      directory.count == directorySize
    else { throw ArchiveError.invalidArchive }
    var entries: [Entry] = []
    var cursor = 0
    for _ in 0..<count {
      guard cursor + 46 <= directory.count, directory.uint32(cursor) == 0x0201_4B50 else {
        throw ArchiveError.invalidArchive
      }
      let nameLength = Int(directory.uint16(cursor + 28))
      let extraLength = Int(directory.uint16(cursor + 30))
      let length = 46 + nameLength + extraLength + Int(directory.uint16(cursor + 32))
      let localOffset = directory.uint32(cursor + 42)
      guard cursor + length <= directory.count, localOffset != UInt32.max,
        Int(localOffset) + 30 <= directoryOffset
      else { throw ArchiveError.invalidArchive }
      let record = directory.subdata(in: cursor..<(cursor + length))
      let name = record.subdata(in: 46..<(46 + nameLength))
      let extra = record.subdata(in: (46 + nameLength)..<(46 + nameLength + extraLength))
      let flags = record.uint16(8)
      entries.append(
        Entry(
          record: record, flags: flags, name: name, localOffset: Int(localOffset),
          isLegacy: flags & 0x0800 == 0 && name.contains { $0 >= 0x80 }
            && !hasUnicodePath(extra)))
      cursor += length
    }
    guard cursor == directory.count, Set(entries.map(\.localOffset)).count == entries.count else {
      throw ArchiveError.invalidArchive
    }
    return Layout(entries: entries, directoryOffset: directoryOffset, trailer: trailer)
  }

  /// Поле Info-ZIP 0x7075 уже хранит имя в UTF-8, и движок берёт его сам.
  private static func hasUnicodePath(_ extra: Data) -> Bool {
    var cursor = 0
    while cursor + 4 <= extra.count {
      if extra.uint16(cursor) == 0x7075 { return true }
      cursor += 4 + Int(extra.uint16(cursor + 2))
    }
    return false
  }

  private static func copy(
    from source: FileHandle, range: Range<Int>, to target: FileHandle, written: inout Int
  ) throws {
    try source.seek(toOffset: UInt64(range.lowerBound))
    var remaining = range.count
    while remaining > 0 {
      try Task.checkCancellation()
      guard let chunk = try source.read(upToCount: min(remaining, 4 * 1024 * 1024)),
        !chunk.isEmpty
      else { throw ArchiveError.invalidArchive }
      try target.write(contentsOf: chunk)
      remaining -= chunk.count
      written += chunk.count
    }
  }
}

extension Data {
  /// Поля ZIP хранятся в порядке little-endian; смещение считается от начала этих данных.
  fileprivate func uint16(_ offset: Int) -> UInt16 {
    UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
  }

  fileprivate func uint32(_ offset: Int) -> UInt32 {
    UInt32(uint16(offset)) | UInt32(uint16(offset + 2)) << 16
  }

  fileprivate mutating func setUInt16(_ value: UInt16, at offset: Int) {
    self[startIndex + offset] = UInt8(value & 0xFF)
    self[startIndex + offset + 1] = UInt8(value >> 8)
  }

  fileprivate mutating func setUInt32(_ value: UInt32, at offset: Int) {
    setUInt16(UInt16(value & 0xFFFF), at: offset)
    setUInt16(UInt16(value >> 16), at: offset + 2)
  }
}
