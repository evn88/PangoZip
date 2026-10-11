import PangoZipCore
import XCTest

@testable import PangoZipApp

final class FinderIntegrationModelTests: XCTestCase, @unchecked Sendable {
  /// Выключенное расширение требует системного согласия, регистрация не подменяет его включением.
  @MainActor
  func testRegistrationShowsConsentAndRefreshesAfterSystemSettings() async {
    let consent = ExtensionConsent()
    let model = FinderIntegrationModel(register: {}, extensionEnabled: { consent.enabled })
    await model.prepare()
    XCTAssertEqual(model.state, .needsApproval)
    consent.enabled = true
    model.refreshEnabledState()
    XCTAssertEqual(model.state, .enabled)
    consent.enabled = false
    model.refreshEnabledState()
    XCTAssertEqual(model.state, .needsApproval)
  }

  /// Запуск с образа показывает инструкцию установки даже при наличии другой включённой копии.
  @MainActor
  func testUninstalledCopyCannotClaimThatFinderIsReady() async {
    let model = FinderIntegrationModel(
      register: { throw FinderRegistrationError.notInstalled }, extensionEnabled: { true })
    await model.prepare()
    XCTAssertEqual(model.state, .requiresInstallation)
    model.refreshEnabledState()
    XCTAssertEqual(model.state, .requiresInstallation)
  }

  /// Ошибка регистрации остаётся видимой, а отмена не изображается успешной подготовкой.
  @MainActor
  func testFailureAndCancellationRemainRecoverable() async {
    let failed = FinderIntegrationModel(
      register: { throw CocoaError(.fileReadNoPermission) }, extensionEnabled: { true })
    await failed.prepare()
    guard case .failed = failed.state else { return XCTFail("Expected registration failure") }
    failed.refreshEnabledState()
    guard case .failed = failed.state else { return XCTFail("Failure must remain visible") }
    let cancelled = FinderIntegrationModel(
      register: { throw CancellationError() }, extensionEnabled: { true })
    await cancelled.prepare()
    XCTAssertEqual(cancelled.state, .idle)
  }
}

@MainActor
private final class ExtensionConsent {
  var enabled = false
}
