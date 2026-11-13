import Foundation

/// Передаёт пароль 7zz через stdin, чтобы секрет не попадал в аргументы процесса.
///
/// Аргументы процесса видны другим программам того же пользователя (`ps`, Activity Monitor),
/// поэтому непустой пароль никогда не добавляется к ключу `-p`. 7zz читает пароль из stdin,
/// когда запрашивает его сам: при чтении — если ключ `-p` отсутствует, при записи — по `-p`
/// без значения. Обновление зашифрованного архива спрашивает пароль дважды (открытие и новые
/// данные), поэтому строка повторяется; лишние строки движок не читает.
struct EnginePassword: Sendable, Equatable {
  /// Аргументы движка без секрета.
  let arguments: [String]
  /// Данные для stdin или nil, если пароль не нужен.
  let input: Data?

  /// Запас строк для повторных запросов пароля в одном запуске движка.
  static let repeatedLines = 4

  /// Без пароля и без ключа `-p`.
  static let none = EnginePassword(arguments: [], input: nil)

  /// Пароль для команд чтения (`l`, `t`, `x`).
  static func reading(_ password: String) throws -> EnginePassword {
    // `-p` без значения при чтении — пустой пароль: 7zz сразу сообщает об ошибке, не ожидая ввода.
    guard !password.isEmpty else { return EnginePassword(arguments: ["-p"], input: nil) }
    return EnginePassword(arguments: [], input: try lines(password))
  }

  /// Пароль для команд записи (`a`, `d`): `-p` без значения просит 7zz прочитать его из stdin.
  static func writing(_ password: String) throws -> EnginePassword {
    guard !password.isEmpty else { return .none }
    return EnginePassword(arguments: ["-p"], input: try lines(password))
  }

  /// Предел stdin: данные пишутся в канал до запуска процесса и должны поместиться в его буфер.
  static let maximumInputBytes = 16_384

  /// Пароль читается построчно: перевод строки внутри него передать нельзя.
  private static func lines(_ password: String) throws -> Data {
    guard !password.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
      throw ArchiveError.passwordRequired
    }
    let data = Data(String(repeating: password + "\n", count: repeatedLines).utf8)
    guard data.count <= maximumInputBytes else { throw ArchiveError.passwordRequired }
    return data
  }
}
