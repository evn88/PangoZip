import Foundation
import Security

/// Хранилище паролей архивов; в тестах подменяется, чтобы не трогать Связку ключей.
@MainActor
protocol ArchivePasswordStoring {
  func password(for archive: URL) -> String?
  func save(_ password: String, for archive: URL)
  func removeAll()
}

/// Пароли лежат в Связке ключей macOS: запись на архив, ключ — полный путь к файлу.
@MainActor
struct KeychainArchivePasswords: ArchivePasswordStoring {
  static let enabledKey = "rememberArchivePasswords"
  private static let service = "app.pangozip.desktop.archive-password"

  /// Сохранение включает пользователь: без этого PangoZip ничего не пишет в Связку ключей.
  static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

  private func query(_ archive: URL?) -> [CFString: Any] {
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service,
    ]
    if let archive { query[kSecAttrAccount] = archive.standardizedFileURL.path }
    return query
  }

  func password(for archive: URL) -> String? {
    var query = query(archive)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func save(_ password: String, for archive: URL) {
    let data = Data(password.utf8)
    let status = SecItemUpdate(
      query(archive) as CFDictionary, [kSecValueData: data] as CFDictionary)
    guard status == errSecItemNotFound else { return }
    var item = query(archive)
    item[kSecValueData] = data
    item[kSecAttrLabel] = "PangoZip: " + archive.lastPathComponent
    SecItemAdd(item as CFDictionary, nil)
  }

  func removeAll() { SecItemDelete(query(nil) as CFDictionary) }
}
