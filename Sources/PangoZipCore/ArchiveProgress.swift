import Foundation

public typealias ArchiveProgressHandler = @Sendable (ArchiveProgress) async -> Void

/// Codable: ход операции фонового процесса передаётся в значок основного приложения.
public struct ArchiveProgress: Sendable, Equatable, Codable {
  public enum Phase: String, Sendable, Equatable, Codable {
    case preparing, downloading, compressing, verifying, extracting, finalizing
  }

  public let phase: Phase
  public let fraction: Double?
  public let processedBytes: UInt64?
  public let totalBytes: UInt64?
  public let completedFiles: Int?
  public let totalFiles: Int?
  public let currentFile: String?
  public let outputBytes: UInt64?
  public let bytesPerSecond: Double?
  public let remainingSeconds: TimeInterval?
  public let elapsedSeconds: TimeInterval
  public let updatedAt: Date
  public let bytesAreEstimated: Bool
  /// Операция почти стоит, потому что процессор заняли другие программы.
  public let isYielding: Bool

  /// Ограничивает известную долю диапазоном 0…1; нечисловое значение означает неизвестный прогресс.
  public init(
    phase: Phase, fraction: Double? = nil, processedBytes: UInt64? = nil,
    totalBytes: UInt64? = nil, completedFiles: Int? = nil, totalFiles: Int? = nil,
    currentFile: String? = nil, outputBytes: UInt64? = nil, bytesPerSecond: Double? = nil,
    remainingSeconds: TimeInterval? = nil, elapsedSeconds: TimeInterval = 0,
    updatedAt: Date = Date(), bytesAreEstimated: Bool = false, isYielding: Bool = false
  ) {
    self.phase = phase
    self.fraction = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    self.totalBytes = totalBytes
    self.processedBytes = processedBytes.map { min($0, totalBytes ?? $0) }
    let safeTotalFiles = totalFiles.map { max(0, $0) }
    self.totalFiles = safeTotalFiles
    self.completedFiles = completedFiles.map { min(max(0, $0), safeTotalFiles ?? max(0, $0)) }
    self.currentFile = currentFile
    self.outputBytes = outputBytes
    self.bytesPerSecond = bytesPerSecond.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    self.remainingSeconds = remainingSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    self.elapsedSeconds = elapsedSeconds.isFinite ? max(0, elapsedSeconds) : 0
    self.updatedAt = updatedAt
    self.bytesAreEstimated = bytesAreEstimated
    self.isYielding = isYielding
  }
}

/// Одно обновление строки прогресса 7zz: доля, счётчик начатых файлов и текущее имя.
struct EngineProgressUpdate: Sendable, Equatable {
  var fraction: Double
  var files: Int?
  var file: String?
  /// Движок уступает процессор другим программам; выставляет запуск, а не разбор строки.
  var isYielding = false
}

// 7zz перерисовывает строку через backspace; запись может разрываться между чтениями.
// Формат записи: «<процент>% [<файлов>] [<команда>] [<имя>]», длинное имя сокращается движком.
struct EngineProgressParser {
  /// Байты текущей записи: до перерисовки (backspace, CR) или конца строки.
  private var record: [UInt8] = []
  private var lastPercent = -1
  private var lastDetails = ""
  /// Строки, не относящиеся к прогрессу: по ним определяется причина ошибки движка.
  private(set) var messages: [UInt8] = []

  private static let recordLimit = 1_024
  private static let messagesLimit = 65_536

  /// Сохраняет незавершённую запись между чтениями и пропускает повторные или убывающие значения.
  mutating func consume(_ data: Data) -> [EngineProgressUpdate] {
    var updates: [EngineProgressUpdate] = []
    for byte in data {
      if byte == 8 || byte == 13 || byte == 10 {
        close(newline: byte == 10, into: &updates)
      } else if record.count < Self.recordLimit {
        record.append(byte)
      }
    }
    // Движок пишет запись целиком, поэтому к концу чтения она обычно полна.
    if let update = pendingUpdate() { updates.append(update) }
    return updates
  }

  /// Учитывает последнюю строку без перевода строки после завершения процесса.
  mutating func finish() -> [EngineProgressUpdate] {
    var updates: [EngineProgressUpdate] = []
    close(newline: true, into: &updates)
    return updates
  }

  /// Завершает запись: прогресс публикуется, обычная строка уходит в сообщения, остальное стирается.
  private mutating func close(newline: Bool, into updates: inout [EngineProgressUpdate]) {
    defer { record.removeAll(keepingCapacity: true) }
    if Self.split(record) != nil {
      if let update = pendingUpdate() { updates.append(update) }
    } else if newline, record.contains(where: { $0 != 32 && $0 != 9 }) {
      messages.append(contentsOf: record)
      messages.append(10)
      if messages.count > Self.messagesLimit {
        messages.removeFirst(messages.count - Self.messagesLimit)
      }
    }
  }

  /// Возвращает обновление, если запись несёт новый процент или новые сведения при том же проценте.
  private mutating func pendingUpdate() -> EngineProgressUpdate? {
    guard let (percent, tail) = Self.split(record), percent >= lastPercent else { return nil }
    let details = String(decoding: tail, as: UTF8.self)
    guard percent > lastPercent || details != lastDetails else { return nil }
    lastPercent = percent
    lastDetails = details
    var update = EngineProgressUpdate(fraction: Double(percent) / 100)
    var rest = Substring(details)
    if rest.hasPrefix(" ") {
      let token = rest.dropFirst().prefix { $0 != " " }
      if !token.isEmpty, token.count <= 12, token.allSatisfy({ $0.isASCII && $0.isNumber }) {
        update.files = Int(token)
        rest = rest.dropFirst(token.count + 1)
      }
    }
    // Команда движка («+», «U», «T», «-») — один символ перед именем.
    if rest.hasPrefix(" "), rest.dropFirst().prefix(while: { $0 != " " }).count == 1 {
      rest = rest.dropFirst(2)
    }
    if rest.hasPrefix(" "), rest.count > 1 { update.file = String(rest.dropFirst()) }
    return update
  }

  /// Запись прогресса начинается с пробелов и не более чем трёх цифр перед знаком процента.
  private static func split(_ record: [UInt8]) -> (percent: Int, tail: ArraySlice<UInt8>)? {
    var index = record.startIndex
    while index < record.endIndex, record[index] == 32 || record[index] == 9 { index += 1 }
    var percent = 0
    var digits = 0
    while index < record.endIndex, (48...57).contains(record[index]), digits < 3 {
      percent = percent * 10 + Int(record[index] - 48)
      digits += 1
      index += 1
    }
    guard digits > 0, index < record.endIndex, record[index] == 37, percent <= 100 else {
      return nil
    }
    return (percent, record[(index + 1)...])
  }
}
