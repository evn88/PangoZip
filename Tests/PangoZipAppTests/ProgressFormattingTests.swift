import PangoZipCore
import XCTest

@testable import PangoZipApp

final class ProgressFormattingTests: XCTestCase, @unchecked Sendable {
  /// Использует десятичные мегабайты и системный десятичный разделитель.
  func testDecimalMegabytesUseOneFractionalDigit() {
    let separator = Locale.current.decimalSeparator ?? "."
    let megabytes = L10n.tr("МБ")
    XCTAssertEqual(ProgressFormatting.bytes(1_500_000), "1\(separator)5 \(megabytes)")
    XCTAssertEqual(
      ProgressFormatting.processedBytes(128_400_000, total: 256_000_000, estimated: true),
      L10n.tr("%1$@ из %2$@", "≈ 128\(separator)4 \(megabytes)", "256\(separator)0 \(megabytes)"))
    XCTAssertEqual(
      ProgressFormatting.processedBytes(128_400_000, total: 256_000_000, estimated: false),
      L10n.tr("%1$@ из %2$@", "128\(separator)4 \(megabytes)", "256\(separator)0 \(megabytes)"))
    XCTAssertEqual(
      ProgressFormatting.speed(12_300_000), L10n.tr("≈ %1$@/с", "12\(separator)3 \(megabytes)"))
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
