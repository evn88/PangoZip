import Foundation

public enum L10n {
  /// SwiftPM использует отдельный комплект ресурсов; готовое приложение — свой основной комплект.
  static let bundle: Bundle = {
    #if PANGOZIP_UNINSTALL
      let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      return Bundle(url: app) ?? .main
    #elseif SWIFT_PACKAGE
      if Bundle.main.url(
        forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en")
        != nil
      {
        return .main
      }
      return .module
    #else
      return .main
    #endif
  }()

  /// Строковые позиционные подстановки позволяют переводчику менять порядок аргументов.
  public static func tr(_ key: String, _ values: String...) -> String {
    let format = bundle.localizedString(forKey: key, value: nil, table: nil)
    guard !values.isEmpty else { return format }
    return String(format: format, locale: Locale.current, arguments: values.map { $0 as CVarArg })
  }
}
