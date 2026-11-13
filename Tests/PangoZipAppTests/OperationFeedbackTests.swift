import PangoZipCore
import XCTest

@testable import PangoZipApp

final class OperationFeedbackTests: XCTestCase, @unchecked Sendable {
  private func decide(
    duration: TimeInterval = 30, enabled: Bool = true, active: Bool = false,
    outcome: OperationOutcome = .success
  ) -> Bool {
    OperationNotificationPolicy.shouldNotify(
      duration: duration, isEnabled: enabled, isApplicationActive: active, outcome: outcome)
  }

  /// Уведомление нужно только для долгой операции в неактивном приложении при включённой настройке.
  func testNotificationRequiresLongInactiveEnabledOperation() {
    XCTAssertTrue(decide())
    XCTAssertTrue(decide(outcome: .failure("Ошибка")))
    XCTAssertTrue(decide(duration: OperationNotificationPolicy.threshold))
    XCTAssertFalse(decide(duration: 9.9))
    XCTAssertFalse(decide(duration: .nan))
    XCTAssertFalse(decide(enabled: false))
    XCTAssertFalse(decide(active: true))
    XCTAssertFalse(decide(outcome: .cancelled))
  }

  /// Порог можно задать явно.
  func testCustomThreshold() {
    XCTAssertTrue(
      OperationNotificationPolicy.shouldNotify(
        duration: 3, isEnabled: true, isApplicationActive: false, outcome: .success,
        threshold: 2))
    XCTAssertFalse(
      OperationNotificationPolicy.shouldNotify(
        duration: 1, isEnabled: true, isApplicationActive: false, outcome: .success,
        threshold: 2))
  }

  /// Вне комплекта .app или без идентификатора центр уведомлений недоступен и не вызывается.
  func testNotificationCenterIsUnavailableOutsideAppBundle() {
    let app = URL(fileURLWithPath: "/Applications/PangoZip.app")
    XCTAssertTrue(OperationNotificationPolicy.isAvailable(bundleURL: app, bundleIdentifier: "x.y"))
    XCTAssertFalse(OperationNotificationPolicy.isAvailable(bundleURL: app, bundleIdentifier: nil))
    XCTAssertFalse(OperationNotificationPolicy.isAvailable(bundleURL: app, bundleIdentifier: ""))
    XCTAssertFalse(
      OperationNotificationPolicy.isAvailable(
        bundleURL: URL(fileURLWithPath: "/usr/bin/xctest"), bundleIdentifier: "com.apple.xctest"))
    // В тестовом процессе проверка текущего комплекта не должна разрешать вызов центра.
    XCTAssertFalse(
      OperationNotificationPolicy.isAvailable(
        bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier))
  }

  /// Состояние Dock: нет операций, неизвестная доля, среднее по известным долям.
  func testDockStateAggregatesFractions() {
    XCTAssertEqual(DockProgress.state(for: []), .hidden)
    XCTAssertEqual(DockProgress.state(for: [nil]), .indeterminate)
    XCTAssertEqual(DockProgress.state(for: [nil, .nan]), .indeterminate)
    XCTAssertEqual(DockProgress.state(for: [0.25]), .determinate(0.25))
    XCTAssertEqual(DockProgress.state(for: [0.2, 0.6, nil]), .determinate(0.4))
    XCTAssertEqual(DockProgress.state(for: [1.5]), .determinate(1))
    XCTAssertEqual(DockProgress.state(for: [-1]), .determinate(0))
  }

  /// Подготовка не даёт доли; остальные этапы передают долю операции без изменений.
  func testDockFractionFromArchiveProgress() {
    XCTAssertNil(DockProgress.fraction(of: nil))
    XCTAssertNil(DockProgress.fraction(of: ArchiveProgress(phase: .preparing, fraction: 0.5)))
    XCTAssertNil(DockProgress.fraction(of: ArchiveProgress(phase: .compressing)))
    XCTAssertEqual(
      DockProgress.fraction(of: ArchiveProgress(phase: .extracting, fraction: 0.4)), 0.4)
    XCTAssertEqual(
      DockProgress.fraction(of: ArchiveProgress(phase: .verifying, fraction: 7)), 1)
    XCTAssertNil(
      DockProgress.fraction(of: ArchiveProgress(phase: .compressing, fraction: .infinity)))
  }

  /// Текст ошибки в уведомлении укладывается в одну строку ограниченной длины.
  func testFailureReasonIsShortenedToOneLine() {
    XCTAssertEqual(OperationFeedback.shortened("первая\nвторая"), "первая вторая")
    let long = String(repeating: "я", count: 400)
    let short = OperationFeedback.shortened(long, limit: 50)
    XCTAssertEqual(short.count, 50)
    XCTAssertTrue(short.hasSuffix("…"))
  }

  /// Без разрешения и вне комплекта приложение и ошибка не приводят к падению при завершении.
  @MainActor
  func testFinishingOperationDoesNotCrashOutsideAppBundle() async {
    let feedback = OperationFeedback.shared
    let id = feedback.begin(kind: .verify, subject: "test.zip")
    feedback.update(id, fraction: 0.5)
    let task = feedback.finish(id, outcome: .success)
    await task?.value
    XCTAssertNil(feedback.finish(id, outcome: .success))
  }
}
