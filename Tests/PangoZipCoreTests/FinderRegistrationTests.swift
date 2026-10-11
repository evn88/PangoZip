import Synchronization
import XCTest

@testable import PangoZipCore

final class FinderRegistrationTests: XCTestCase {
  /// Проверяет вложенную установку и точные пути встроенных компонентов.
  func testInstalledApplicationAndNestedDirectory() throws {
    try withFixture { root in
      let app = try makeApp(in: root.appendingPathComponent("Utilities"))
      let plan = try FinderRegistrationPlan.make(
        applicationURL: app, applicationDirectories: [root])
      XCTAssertEqual(plan.applicationURL, app.resolvingSymlinksInPath())
      XCTAssertEqual(plan.workerURL, plan.applicationURL.appendingPathComponent(workerPath))
      XCTAssertEqual(plan.extensionURL, plan.applicationURL.appendingPathComponent(extensionPath))
    }
  }

  /// Проверяет каждый обязательный bundle и его исполняемый файл.
  func testMissingOrInvalidComponentsAreRejected() throws {
    for path in ["", workerPath, extensionPath] {
      for failure in ["missing", "identifier", "executable", "permissions"] {
        try withFixture { root in
          let app = try makeApp(in: root)
          let bundle = path.isEmpty ? app : app.appendingPathComponent(path)
          let binaryName = path == extensionPath ? "PangoZipFinderSync" : "PangoZip"
          let binary = bundle.appendingPathComponent("Contents/MacOS/\(binaryName)")
          if failure == "missing" {
            try FileManager.default.removeItem(at: binary)
          } else if failure == "permissions" {
            try FileManager.default.setAttributes(
              [.posixPermissions: 0o600], ofItemAtPath: binary.path)
          } else {
            let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
            let data = try Data(contentsOf: infoURL)
            var info = try XCTUnwrap(
              PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            info[failure == "identifier" ? "CFBundleIdentifier" : "CFBundleExecutable"] = "wrong"
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
              .write(to: infoURL)
          }
          XCTAssertThrowsError(
            try FinderRegistrationPlan.make(applicationURL: app, applicationDirectories: [root])
          ) {
            XCTAssertEqual(
              $0 as? FinderRegistrationError, .invalidBundle(bundle.resolvingSymlinksInPath()))
          }
        }
      }
    }
  }

  /// Запрещает чужую папку, похожий префикс, корзину и App Translocation.
  func testUninstalledTrashAndTranslocatedLocationsAreRejected() throws {
    try withFixture { root in
      let accepted = root.appendingPathComponent("Applications")
      for path in [
        "Downloads", "Applications-other", "Applications/.Trash", "Applications/.Trashes/501",
        "Applications/AppTranslocation/UUID/d",
      ] {
        let app = try makeApp(in: root.appendingPathComponent(path))
        XCTAssertThrowsError(
          try FinderRegistrationPlan.make(applicationURL: app, applicationDirectories: [accepted])
        ) {
          XCTAssertEqual($0 as? FinderRegistrationError, .notInstalled)
        }
      }
      let downloaded = try makeApp(in: root.appendingPathComponent("Downloads"))
      let link = accepted.appendingPathComponent("PangoZip.app")
      try FileManager.default.createDirectory(at: accepted, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: downloaded)
      XCTAssertThrowsError(
        try FinderRegistrationPlan.make(applicationURL: link, applicationDirectories: [accepted]))
    }
  }

  /// Разрешение символической ссылки не должно скрывать размещение в корзине.
  func testSymlinkToTrashIsRejected() throws {
    try withFixture { root in
      let app = try makeApp(in: root.appendingPathComponent(".Trash"))
      let link = root.appendingPathComponent("PangoZip.app")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
      XCTAssertThrowsError(
        try FinderRegistrationPlan.make(applicationURL: link, applicationDirectories: [root])
      ) {
        XCTAssertEqual($0 as? FinderRegistrationError, .notInstalled)
      }
    }
  }

  /// Не допускает вынесенные наружу компоненты под видом вложенного bundle.
  func testEmbeddedBundleSymlinkCannotEscapeApplication() throws {
    try withFixture { root in
      let app = try makeApp(in: root)
      let worker = app.appendingPathComponent(workerPath)
      let outside = root.appendingPathComponent("Worker.app")
      try FileManager.default.moveItem(at: worker, to: outside)
      try FileManager.default.createSymbolicLink(at: worker, withDestinationURL: outside)
      XCTAssertThrowsError(
        try FinderRegistrationPlan.make(applicationURL: app, applicationDirectories: [root]))
    }
  }

  /// Проверяет порядок регистрации, принудительное обновление и передачу OSStatus без системных вызовов.
  func testRegistrationExecutorAndFailureStatus() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(in: root)
    let plan = try FinderRegistrationPlan.make(applicationURL: app, applicationDirectories: [root])
    let calls = Mutex<[URL]>([])
    try await FinderRegistration.register(plan) { url, force in
      XCTAssertTrue(force)
      calls.withLock { $0.append(url) }
      return 0
    }
    XCTAssertEqual(calls.withLock { $0 }, [plan.applicationURL, plan.workerURL])
    do {
      try await FinderRegistration.register(plan) { url, _ in
        url == plan.workerURL ? -10811 : 0
      }
      XCTFail("Ожидалась ошибка регистрации worker")
    } catch {
      XCTAssertEqual(error as? FinderRegistrationError, .registrationFailed(plan.workerURL, -10811))
    }
  }

  /// При отмене дожидается активного вызова и не регистрирует следующий компонент.
  func testCancellationWaitsForInFlightRegistration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(in: root)
    let plan = try FinderRegistrationPlan.make(applicationURL: app, applicationDirectories: [root])
    let started = expectation(description: "Регистрация начата")
    let returned = expectation(description: "Регистрация ещё выполняется")
    returned.isInverted = true
    let release = DispatchSemaphore(value: 0)
    let calls = Mutex<[URL]>([])
    let task = Task {
      defer { returned.fulfill() }
      try await FinderRegistration.register(plan) { url, _ in
        calls.withLock { $0.append(url) }
        started.fulfill()
        release.wait()
        return 0
      }
    }
    await fulfillment(of: [started], timeout: 2)
    task.cancel()
    await fulfillment(of: [returned], timeout: 0.05)
    release.signal()
    do {
      try await task.value
      XCTFail("Ожидалась отмена регистрации")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(calls.withLock { $0 }, [plan.applicationURL])
  }

  private let workerPath = "Contents/Helpers/PangoZipWorker.app"
  private let extensionPath = "Contents/PlugIns/PangoZipFinderSync.appex"

  /// Удаляет временные данные независимо от исхода проверки.
  private func withFixture(_ operation: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try operation(root)
  }

  /// Создаёт минимальный полный комплект с ожидаемыми метаданными и исполняемыми файлами.
  private func makeApp(in root: URL) throws -> URL {
    let app = root.appendingPathComponent("PangoZip.app")
    for (path, identifier, executable, type) in [
      ("", "app.pangozip.desktop", "PangoZip", "APPL"),
      (workerPath, "app.pangozip.desktop.worker", "PangoZip", "APPL"),
      (extensionPath, "app.pangozip.desktop.finder", "PangoZipFinderSync", "XPC!"),
    ] {
      let bundle = path.isEmpty ? app : app.appendingPathComponent(path)
      let binary = bundle.appendingPathComponent("Contents/MacOS/\(executable)")
      try FileManager.default.createDirectory(
        at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("fixture".utf8).write(to: binary)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
      var info: [String: Any] = [
        "CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
        "CFBundlePackageType": type,
      ]
      if path == extensionPath {
        info["NSExtension"] = ["NSExtensionPointIdentifier": "com.apple.FinderSync"]
      }
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }
    return app
  }
}
