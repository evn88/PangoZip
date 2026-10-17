import Foundation
import XCTest

@testable import PangoZipCore

final class LocalizationTests: XCTestCase {
  /// Загружает настоящий ресурс английского языка стандартным механизмом Bundle.
  func testEnglishResourcesAreAvailable() throws {
    let url = try XCTUnwrap(L10n.bundle.url(forResource: "en", withExtension: "lproj"))
    let english = try XCTUnwrap(Bundle(url: url))
    XCTAssertEqual(english.localizedString(forKey: "Отмена", value: nil, table: nil), "Cancel")
    XCTAssertEqual(
      english.localizedString(forKey: "Сжатие", value: nil, table: nil),
      "Compression")
  }

  /// Подстановки не интерпретируют проценты и Unicode в пользовательском имени файла.
  func testFilenameInterpolationPreservesUserInput() {
    let filename = "100% %@ фото.zip"
    let result = L10n.tr("Создан архив: %1$@", filename)
    XCTAssertTrue(result.hasSuffix(filename))
    XCTAssertFalse(result.contains("%1$@"))
  }

  /// Каждый язык содержит полный каталог с совместимыми позиционными подстановками.
  func testAllLanguagesHaveCompleteCatalogs() throws {
    let languages = [
      "en", "ru", "sr-Latn", "de", "fr", "es", "it", "pt", "pl", "uk", "tr", "zh-Hans", "ja", "ko",
    ]
    XCTAssertEqual(Set(L10n.bundle.localizations), Set(languages))
    let english = try catalog("en")
    XCTAssertGreaterThan(english.count, 200)
    let expression = try NSRegularExpression(pattern: #"%\d+\$@"#)
    func placeholders(_ text: String) -> [String] {
      expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        .map { String(text[Range($0.range, in: text)!]) }.sorted()
    }
    for language in languages {
      let translated = try catalog(language)
      XCTAssertEqual(Set(translated.keys), Set(english.keys), language)
      for (key, value) in translated {
        XCTAssertFalse(value.isEmpty, "\(language): \(key)")
        XCTAssertEqual(placeholders(value), placeholders(key), "\(language): \(key)")
      }
      let serviceURL = try XCTUnwrap(
        L10n.bundle.url(
          forResource: "ServicesMenu", withExtension: "strings", subdirectory: nil,
          localization: language))
      let services =
        try PropertyListSerialization.propertyList(from: Data(contentsOf: serviceURL), format: nil)
        as? [String: String]
      XCTAssertEqual(services?.count, 2, language)
    }
  }

  private func catalog(_ language: String) throws -> [String: String] {
    let url = try XCTUnwrap(
      L10n.bundle.url(
        forResource: "Localizable", withExtension: "strings", subdirectory: nil,
        localization: language))
    return try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        as? [String: String])
  }
}
