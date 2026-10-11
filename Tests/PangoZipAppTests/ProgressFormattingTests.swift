import XCTest

@testable import PangoZipApp

final class ProgressFormattingTests: XCTestCase, @unchecked Sendable {
  /// Использует десятичные мегабайты и русскую десятичную запятую.
  func testDecimalMegabytesUseOneFractionalDigit() {
    XCTAssertEqual(ProgressFormatting.bytes(1_500_000), "1,5 МБ")
    XCTAssertEqual(
      ProgressFormatting.processedBytes(128_400_000, total: 256_000_000, estimated: true),
      "≈ 128,4 МБ из 256,0 МБ")
    XCTAssertEqual(
      ProgressFormatting.processedBytes(128_400_000, total: 256_000_000, estimated: false),
      "128,4 МБ из 256,0 МБ")
    XCTAssertEqual(ProgressFormatting.speed(12_300_000), "≈ 12,3 МБ/с")
  }

  /// Явно отображает ноль, часы и большие конечные длительности.
  func testTimeIncludesHoursAndZero() {
    XCTAssertEqual(ProgressFormatting.time(0), "00:00:00")
    XCTAssertEqual(ProgressFormatting.time(3_723), "01:02:03")
    XCTAssertEqual(ProgressFormatting.time(90_061), "25:01:01")
  }

  /// Неизвестные значения и отсутствующая оценка остаются прочерком.
  func testUnknownAndInvalidValuesStayUnknown() {
    XCTAssertEqual(ProgressFormatting.bytes(nil), "—")
    XCTAssertEqual(ProgressFormatting.processedBytes(5, total: nil, estimated: false), "—")
    XCTAssertEqual(ProgressFormatting.speed(nil), "—")
    XCTAssertEqual(ProgressFormatting.speed(0), "—")
    XCTAssertEqual(ProgressFormatting.speed(.infinity), "—")
    XCTAssertEqual(ProgressFormatting.time(nil), "—")
    XCTAssertEqual(ProgressFormatting.time(-1), "—")
    XCTAssertEqual(ProgressFormatting.eta(nil, phase: .compressing), "—")
    XCTAssertEqual(ProgressFormatting.eta(0, phase: .finalizing), "—")
    XCTAssertEqual(ProgressFormatting.files(completed: nil, total: nil), "—")
  }
}
