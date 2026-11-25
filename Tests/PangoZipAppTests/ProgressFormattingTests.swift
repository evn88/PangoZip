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

  /// Время в строке меню округляется вверх крупным шагом, чтобы не мельтешить.
  func testShortDurationRoundsUpToCoarseSteps() {
    XCTAssertEqual(ShortDuration.string(26), ShortDuration.string(30))
    XCTAssertNotEqual(ShortDuration.string(30), ShortDuration.string(31))
    XCTAssertEqual(ShortDuration.string(61), ShortDuration.string(120))
    XCTAssertEqual(ShortDuration.string(3_541), ShortDuration.string(3_600))
    XCTAssertEqual(ShortDuration.string(0), ShortDuration.string(5))
    XCTAssertEqual(ShortDuration.string(.infinity), ShortDuration.string(5))
  }

  /// Подпись значка в строке меню: только процент, время остаётся в карточке.
  @MainActor
  func testMenuBarTitleShowsOnlyPercent() {
    let card = ProgressCardModel()
    XCTAssertEqual(card.menuBarTitle, "")
    card.fraction = 0.426
    XCTAssertEqual(card.menuBarTitle, "42%")
    card.remaining = 90
    XCTAssertEqual(card.menuBarTitle, "42%")
    card.isPaused = true
    XCTAssertEqual(card.menuBarTitle, "42%")
    XCTAssertEqual(card.timeLine, L10n.tr("На паузе"))
    card.state = .done
    XCTAssertEqual(card.menuBarTitle, "")
  }

  /// Остров и строка меню подписывают ход одинаково для операций из Finder и из окна.
  @MainActor
  func testOutsideWindowStageShowsPercentOnlyWhenKnown() {
    let preparing = OperationPresenter.stage(
      kind: .create, progress: ArchiveProgress(phase: .preparing, fraction: 0.5),
      isPaused: false)
    XCTAssertEqual(preparing.title, L10n.tr("Сжимаем…"))
    XCTAssertNil(preparing.fraction)
    let running = OperationPresenter.stage(
      kind: .extract, progress: ArchiveProgress(phase: .extracting, fraction: 0.426),
      isPaused: false)
    XCTAssertEqual(running.title, L10n.tr("Распаковываем…") + " · 42%")
    XCTAssertEqual(running.fraction, 0.426)
    let paused = OperationPresenter.stage(
      kind: .modify, progress: ArchiveProgress(phase: .compressing, fraction: 0.1),
      isPaused: true)
    XCTAssertEqual(paused.title, L10n.tr("На паузе") + " · 10%")
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
