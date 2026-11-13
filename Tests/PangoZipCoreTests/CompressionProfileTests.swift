import XCTest

@testable import PangoZipCore

final class CompressionProfileTests: XCTestCase {
  /// Встроенные профили имеют уникальные идентификаторы и допустимые параметры.
  func testBuiltInProfilesAreValid() {
    let profiles = CompressionProfile.builtIn
    XCTAssertEqual(profiles.map(\.id), ["fast", "normal", "maximum", "email"])
    XCTAssertEqual(Set(profiles.map(\.id)).count, profiles.count)
    for profile in profiles {
      XCTAssertTrue(CompressionOptions.supportedFormats.contains(profile.format))
      XCTAssertFalse(profile.title.isEmpty)
      XCTAssertNotEqual(profile.id, CompressionProfile.customID)
    }
    XCTAssertEqual(CompressionProfile.email.volumeSizeMB, 25)
    XCTAssertEqual(CompressionProfile.email.format, "7z")
    XCTAssertEqual(CompressionProfile.maximum.level, 9)
    XCTAssertEqual(CompressionProfile.fast.level, 1)
  }

  /// Профиль превращается в параметры сжатия вместе с потоками и служебными файлами вызывающего.
  func testProfileProducesOptions() {
    let options = CompressionProfile.email.options(threads: 4, excludesSystemFiles: false)
    XCTAssertEqual(options.format, "7z")
    XCTAssertEqual(options.volumeSizeMB, 25)
    XCTAssertEqual(options.threads, 4)
    XCTAssertFalse(options.excludesSystemFiles)
    XCTAssertTrue(options.encryptsFileNames)
    XCTAssertEqual(options.volumeArguments, ["-v25m"])
  }

  /// Профиль нормализует невозможные сочетания: тома у tar не бывает.
  func testProfileNormalizesUnsupportedCombinations() {
    let profile = CompressionProfile(id: "x", format: "tar", level: 99, volumeSizeMB: 10)
    XCTAssertNil(profile.volumeSizeMB)
    XCTAssertEqual(profile.level, 9)
    XCTAssertEqual(CompressionProfile(id: "y", format: "bad", level: 1).format, "zip")
  }

  /// Codable сохраняет все поля без потерь.
  func testProfileRoundTripsThroughJSON() throws {
    let data = try JSONEncoder().encode(CompressionProfile.email)
    XCTAssertEqual(try JSONDecoder().decode(CompressionProfile.self, from: data), .email)
  }

  /// Поиск по значениям находит профиль и игнорирует параметры, не влияющие на формат.
  func testMatchingFindsProfileByValues() {
    XCTAssertEqual(
      CompressionProfile.matching(
        format: "7z", level: 9, solid: true, encryptsFileNames: true, volumeSizeMB: nil)?.id,
      "maximum")
    XCTAssertEqual(
      CompressionProfile.matching(
        format: "zip", level: 5, solid: true, encryptsFileNames: false, volumeSizeMB: nil)?.id,
      "normal")
    XCTAssertNil(
      CompressionProfile.matching(
        format: "7z", level: 9, solid: false, encryptsFileNames: true, volumeSizeMB: nil))
    XCTAssertNil(
      CompressionProfile.matching(
        format: "7z", level: 5, solid: true, encryptsFileNames: true, volumeSizeMB: 100))
    XCTAssertNil(CompressionProfile.builtIn(id: CompressionProfile.customID))
  }
}
