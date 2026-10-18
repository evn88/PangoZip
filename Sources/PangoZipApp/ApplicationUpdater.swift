import AppKit
import Observation
import PangoZipCore
import Sparkle

@MainActor
@Observable
final class ApplicationUpdater: NSObject, SPUUpdaterDelegate {
  private(set) var canCheckForUpdates = false
  private(set) var isInstalling = false
  private(set) var isUpdatePending = false
  private(set) var lastError: String?

  var automaticallyChecksForUpdates = true {
    didSet {
      if started {
        controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
      }
    }
  }

  @ObservationIgnored private var installationTask: Task<Void, Never>?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var installationCanceled = false
  @ObservationIgnored private var observations: [NSKeyValueObservation] = []
  @ObservationIgnored private var isBusy: @MainActor () -> Bool = { false }
  @ObservationIgnored private var prepareForInstallation: @MainActor () async -> Bool = { true }
  @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(
    startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

  @ObservationIgnored private let blockingProcesses: @MainActor () -> Bool

  init(
    hasBlockingProcesses: @escaping @MainActor () -> Bool = {
      ApplicationUpdater.hasBlockingProcesses
    }
  ) {
    blockingProcesses = hasBlockingProcesses
    super.init()
  }

  func updater(
    _ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck
  ) throws {
    guard !blockingProcesses() else {
      throw NSError(
        domain: "app.pangozip.updater", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: L10n.tr(
            "Перед обновлением завершите операции Finder и закройте другие окна PangoZip.")
        ])
    }
  }

  func start(
    isBusy: @escaping @MainActor () -> Bool,
    prepareForInstallation: @escaping @MainActor () async -> Bool
  ) {
    guard !started else { return }
    self.isBusy = isBusy
    self.prepareForInstallation = prepareForInstallation
    guard UpdateConfiguration.isConfigured(infoDictionary: Bundle.main.infoDictionary) else {
      return
    }
    do {
      try controller.updater.start()
      started = true
      automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
      canCheckForUpdates = controller.updater.canCheckForUpdates
      observations = [
        controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
          Task { @MainActor in
            guard let self else { return }
            self.canCheckForUpdates = self.controller.updater.canCheckForUpdates
          }
        }
      ]
    } catch {
      lastError = error.localizedDescription
    }
  }

  func checkForUpdates() {
    guard canCheckForUpdates, !isInstalling else { return }
    lastError = nil
    controller.checkForUpdates(nil)
  }

  func updater(
    _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool {
    isUpdatePending = true
    installationTask?.cancel()
    installationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let prepared = await self.prepareInstallation()
      guard !Task.isCancelled else { return }
      self.installationCanceled = !prepared
      installHandler()
    }
    return true
  }

  /// Проверка повторяется Sparkle после отложенного callback и позволяет отменить установку.
  func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
    !installationCanceled && !blockingProcesses()
  }

  func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
    isUpdatePending = true
  }

  func updater(
    _ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
    forUpdate item: SUAppcastItem, state: SPUUserUpdateState
  ) {
    if choice == .skip { isUpdatePending = false }
  }

  /// Новые действия блокируются только при подготовке, чтобы очередь архива успела завершиться.
  func prepareInstallation() async -> Bool {
    while isBusy() || blockingProcesses() {
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
    }
    guard !Task.isCancelled else { return false }
    isInstalling = true
    let accepted = await prepareForInstallation()
    if !accepted { isInstalling = false }
    return accepted
  }

  static var hasBlockingProcesses: Bool {
    hasRunningWorkers
      || NSRunningApplication.runningApplications(withBundleIdentifier: "app.pangozip.desktop")
        .contains {
          !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
  }

  static var hasRunningWorkers: Bool {
    NSRunningApplication.runningApplications(withBundleIdentifier: "app.pangozip.desktop.worker")
      .contains { !$0.isTerminated }
  }

  func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?
  ) {
    installationTask?.cancel()
    installationTask = nil
    isInstalling = false
    installationCanceled = false
    if error != nil { isUpdatePending = false }
  }
}

enum UpdateConfiguration {
  static let feedURL = "https://github.com/evn88/PangoZip/releases/latest/download/appcast.xml"

  static func isConfigured(infoDictionary: [String: Any]?) -> Bool {
    guard let info = infoDictionary,
      info["CFBundleIdentifier"] as? String == "app.pangozip.desktop",
      info["SUFeedURL"] as? String == feedURL,
      let key = info["SUPublicEDKey"] as? String,
      Data(base64Encoded: key)?.count == 32,
      info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
      info["SURequireSignedFeed"] as? Bool == true
    else { return false }
    return true
  }
}
