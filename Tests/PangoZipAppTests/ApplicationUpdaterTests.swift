import Sparkle
import XCTest

@testable import PangoZipApp

final class ApplicationUpdaterTests: XCTestCase {
  func testOnlySignedFeedForPangoZipEnablesUpdater() {
    let configuration: [String: Any] = [
      "CFBundleIdentifier": "app.pangozip.desktop",
      "SUFeedURL": UpdateConfiguration.feedURL,
      "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
      "SUVerifyUpdateBeforeExtraction": true,
      "SURequireSignedFeed": true,
    ]
    XCTAssertTrue(UpdateConfiguration.isConfigured(infoDictionary: configuration))
    for (key, value): (String, Any) in [
      ("CFBundleIdentifier", "app.pangozip.worker"),
      ("SUFeedURL", "http://github.com/evn88/PangoZip/releases/latest/download/appcast.xml"),
      ("SUPublicEDKey", ""),
      ("SUPublicEDKey", Data(repeating: 7, count: 31).base64EncodedString()),
      ("SUVerifyUpdateBeforeExtraction", false),
      ("SURequireSignedFeed", false),
    ] {
      var invalid = configuration
      invalid[key] = value
      XCTAssertFalse(UpdateConfiguration.isConfigured(infoDictionary: invalid), key)
    }
    XCTAssertFalse(UpdateConfiguration.isConfigured(infoDictionary: nil))
  }

  @MainActor
  func testOtherInstancesPreventUpdateBeforeInstallerStarts() {
    let updater = ApplicationUpdater(hasBlockingProcesses: { true })
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    XCTAssertThrowsError(
      try updater.updater(
        controller.updater, shouldProceedWithUpdate: .empty(), updateCheck: .updates))
    XCTAssertFalse(updater.updaterShouldRelaunchApplication(controller.updater))
    XCTAssertTrue(
      updater.responds(
        to: NSSelectorFromString("updater:shouldProceedWithUpdate:updateCheck:error:")))
  }

  @MainActor
  func testInstallationWaitsForArchiveOperationsAndPreparation() async {
    let updater = ApplicationUpdater(hasBlockingProcesses: { false })
    let state = InstallationState()
    updater.start(
      isBusy: { state.busy },
      prepareForInstallation: {
        state.prepared = true
        return true
      })
    let installation = Task { await updater.prepareInstallation() }
    await Task.yield()
    XCTAssertFalse(updater.isInstalling)
    XCTAssertFalse(state.prepared)
    state.busy = false
    let accepted = await installation.value
    XCTAssertTrue(accepted)
    XCTAssertTrue(state.prepared)
    XCTAssertTrue(updater.isInstalling)
  }
  @MainActor
  func testCanceledPreparationRestoresApplicationActions() async {
    let updater = ApplicationUpdater(hasBlockingProcesses: { false })
    updater.start(isBusy: { false }, prepareForInstallation: { false })
    let accepted = await updater.prepareInstallation()
    XCTAssertFalse(accepted)
    XCTAssertFalse(updater.isInstalling)
  }

  @MainActor
  func testSparkleCallbacksHaveCorrectObjectiveCSelectors() {
    let updater = ApplicationUpdater(hasBlockingProcesses: { false })
    for selector in [
      "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
      "updaterShouldRelaunchApplication:",
      "updater:didFinishUpdateCycleForUpdateCheck:error:",
      "updater:willExtractUpdate:",
      "updater:userDidMakeChoice:forUpdate:state:",
    ] {
      XCTAssertTrue(updater.responds(to: NSSelectorFromString(selector)), selector)
    }
  }

  @MainActor
  func testCanceledPreparationVetoesSparkleContinuation() async {
    let updater = ApplicationUpdater(hasBlockingProcesses: { false })
    updater.start(isBusy: { false }, prepareForInstallation: { false })
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    let allowed = await withCheckedContinuation { continuation in
      let postponed = updater.updater(
        controller.updater, shouldPostponeRelaunchForUpdate: .empty(),
        untilInvokingBlock: {
          continuation.resume(
            returning: updater.updaterShouldRelaunchApplication(controller.updater))
        })
      XCTAssertTrue(postponed)
    }
    XCTAssertFalse(allowed)
    XCTAssertFalse(updater.isInstalling)
  }

  @MainActor
  func testAbortedCycleDoesNotResumeDeferredInstaller() async throws {
    let updater = ApplicationUpdater(hasBlockingProcesses: { false })
    let state = InstallationState()
    updater.start(isBusy: { state.busy }, prepareForInstallation: { true })
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    _ = updater.updater(
      controller.updater, shouldPostponeRelaunchForUpdate: .empty(),
      untilInvokingBlock: { state.prepared = true })
    await Task.yield()
    updater.updater(
      controller.updater, didFinishUpdateCycleFor: .updates,
      error: NSError(domain: "PangoZipUpdateTest", code: 2))
    state.busy = false
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertFalse(state.prepared)
    XCTAssertFalse(updater.isInstalling)
  }

  @MainActor
  func testImmediateAbortDoesNotStartInstallationPreparation() async {
    let updater = ApplicationUpdater(hasBlockingProcesses: { false })
    let state = InstallationState()
    updater.start(
      isBusy: { false },
      prepareForInstallation: {
        state.prepared = true
        return true
      })
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    _ = updater.updater(
      controller.updater, shouldPostponeRelaunchForUpdate: .empty(), untilInvokingBlock: {})
    updater.updater(
      controller.updater, didFinishUpdateCycleFor: .updates,
      error: NSError(domain: "PangoZipUpdateTest", code: 1))
    await Task.yield()
    XCTAssertFalse(state.prepared)
    XCTAssertFalse(updater.isInstalling)
  }

  @MainActor
  func testPreparedUpdateRemainsPendingAfterDismissalUntilFailure() {
    let updater = ApplicationUpdater(hasBlockingProcesses: { false })
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    XCTAssertFalse(updater.isUpdatePending)
    updater.updater(controller.updater, willExtractUpdate: .empty())
    XCTAssertTrue(updater.isUpdatePending)
    updater.updater(controller.updater, didFinishUpdateCycleFor: .updates, error: nil)
    XCTAssertTrue(updater.isUpdatePending)
    updater.updater(
      controller.updater, didFinishUpdateCycleFor: .updates,
      error: NSError(domain: "PangoZipUpdateTest", code: 1))
    XCTAssertFalse(updater.isUpdatePending)
  }
}

@MainActor
private final class InstallationState {
  var busy = true
  var prepared = false
}
