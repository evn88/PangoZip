import AppKit
import SwiftUI

@main
@MainActor
struct PangoZipApp: App {
  private let isFinderWorker = ApplicationMode.isFinderWorker
  @StateObject private var worker = FinderOperationModel()
  @StateObject private var model = ArchiveBrowserModel()
  @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate

  /// Переносит прежние настройки до создания интерфейса и запуска операций Finder.
  init() {
    ArchivePreferences.migrateLegacySettings()
  }

  var body: some Scene {
    Window("PangoZip", id: isFinderWorker ? "finder-operation" : "main") {
      if isFinderWorker {
        FinderOperationView(model: worker)
          .background(WindowLifecycleBridge(prepareClose: { await worker.prepareTermination() }))
          .onAppear {
            NSApp.setActivationPolicy(.accessory)
            appDelegate.prepareTermination = { await worker.prepareTermination() }
            appDelegate.services.configure(
              openArchive: { _ in }, addFiles: { _ in }, finderRequest: worker.start)
          }
      } else {
        ArchiveBrowserView(model: model)
          .frame(minWidth: 1100, minHeight: 620)
          .background(WindowLifecycleBridge(prepareClose: { await model.requestTermination() }))
          .onAppear {
            appDelegate.prepareTermination = { await model.requestTermination() }
            appDelegate.services.configure(
              openArchive: { model.open($0) }, addFiles: model.receiveFinderFiles,
              finderRequest: model.receiveFinderRequest)
            DispatchQueue.main.async { Self.adjustCloseShortcut(NSApp.mainMenu) }
          }
      }
    }
    .defaultSize(width: isFinderWorker ? 560 : 1480, height: isFinderWorker ? 330 : 820)
    .windowResizability(isFinderWorker ? .contentSize : .contentMinSize)
    .restorationBehavior(isFinderWorker ? .disabled : .automatic)
    .commands { ArchiveCommands(model: model) }
    Settings { ArchiveSettingsView() }
  }

  /// Освобождает ⌘W для закрытия архива, оставляя закрытие окна на ⌘⇧W.
  private static func adjustCloseShortcut(_ menu: NSMenu?) {
    for item in menu?.items ?? [] {
      if item.action == #selector(NSWindow.performClose(_:)), item.keyEquivalent == "w" {
        item.keyEquivalentModifierMask = [.command, .shift]
      }
      adjustCloseShortcut(item.submenu)
    }
  }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
  let services = FinderServices()
  var prepareTermination: (() async -> Bool)?
  private var terminationPending = false

  /// Регистрирует Services только у основного приложения, чтобы worker не перехватывал команды.
  func applicationDidFinishLaunching(_ notification: Notification) {
    if ApplicationMode.isFinderWorker {
      NSApp.setActivationPolicy(.accessory)
    } else {
      NSApp.servicesProvider = services
      NSUpdateDynamicServices()
    }
  }

  /// Позволяет доставлять URL до готовности SwiftUI: сервис сохраняет их в очереди.
  func application(_ application: NSApplication, open urls: [URL]) {
    services.deliverOpenURLs(urls)
  }

  /// Завершает приложение после последнего окна, чтобы освободить временные файлы сеанса.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  /// Откладывает системное завершение до асинхронной очистки и ответа о рабочих копиях.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if ApplicationMode.isFinderWorker && ApplicationMode.workerFinished { return .terminateNow }
    guard let prepareTermination else { return .terminateNow }
    if !terminationPending {
      terminationPending = true
      Task { @MainActor in
        let allowed = await prepareTermination()
        self.terminationPending = false
        NSApp.reply(toApplicationShouldTerminate: allowed)
      }
    }
    return .terminateLater
  }
}

struct WindowLifecycleBridge: NSViewRepresentable {
  let prepareClose: @MainActor () async -> Bool

  /// Создаёт невидимый мост, который подключит перехват закрытия к настоящему окну.
  func makeNSView(context: Context) -> HostView {
    let view = HostView()
    view.prepareClose = prepareClose
    return view
  }

  /// Передаёт актуальную функцию очистки уже установленному мосту окна.
  func updateNSView(_ nsView: HostView, context: Context) { nsView.prepareClose = prepareClose }

  @MainActor
  final class HostView: NSView {
    var prepareClose: (@MainActor () async -> Bool)?
    private var proxy: CloseDelegate?
    /// Устанавливает делегата один раз и сохраняет прежний делегат для событий SwiftUI.
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, proxy == nil else { return }
      let proxy = CloseDelegate(previous: window.delegate) { [weak self] in
        await self?.prepareClose?() ?? true
      }
      self.proxy = proxy
      window.delegate = proxy
      if !ApplicationMode.isFinderWorker,
        UserDefaults.standard.integer(forKey: "archiveTableLayoutVersion") < 2
      {
        let visible = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1520, height: 920)
        window.setContentSize(
          NSSize(width: min(1480, visible.width - 40), height: min(820, visible.height - 80)))
        window.center()
        UserDefaults.standard.set(2, forKey: "archiveTableLayoutVersion")
      }
    }
  }

  @MainActor
  final class CloseDelegate: NSObject, NSWindowDelegate {
    // Неизменяемая ссылка передаётся обратно Objective-C для штатного делегата SwiftUI.
    nonisolated(unsafe) private let previous: NSWindowDelegate?
    private let prepare: @MainActor () async -> Bool
    private var pending = false
    private var allowed = false

    /// Удерживает прежний делегат и асинхронную проверку закрытия до уничтожения окна.
    init(previous: NSWindowDelegate?, prepare: @escaping @MainActor () async -> Bool) {
      self.previous = previous
      self.prepare = prepare
    }

    /// Отклоняет первое закрытие; повторяет его только после успешной асинхронной подготовки.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
      if allowed { return true }
      guard !pending else { return false }
      pending = true
      Task { @MainActor in
        allowed = await prepare()
        pending = false
        if allowed { sender.performClose(nil) }
      }
      return false
    }

    /// Сохраняет объявленные прежним делегатом необязательные методы протокола Objective-C.
    override nonisolated func responds(to selector: Selector!) -> Bool {
      MainActor.assumeIsolated {
        super.responds(to: selector) || previous?.responds(to: selector) == true
      }
    }

    /// Передаёт неперехваченные события прежнему делегату SwiftUI.
    override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
      previous
    }
  }
}
