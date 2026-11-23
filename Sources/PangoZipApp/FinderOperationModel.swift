import AppKit
import OSLog
import PangoZipCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum ApplicationMode {
  static var workerFinished = false
  /// Ход операции показывает остров, поэтому окно фонового процесса скрыто.
  static var workerShowsIsland = false
  static var isFinderWorker: Bool {
    Bundle.main.bundleIdentifier == "app.pangozip.desktop.worker"
      || ProcessInfo.processInfo.arguments.contains("--finder-worker")
  }
}

@MainActor
final class FinderOperationModel: ObservableObject {
  @Published private(set) var progress: ArchiveProgress?
  @Published private(set) var message = L10n.tr("Подготавливаем операцию…")
  @Published private(set) var errorMessage: String?
  @Published private(set) var needsPassword = false
  @Published var password = ""
  private let service = ArchiveService()
  private let logger = Logger(subsystem: "app.pangozip.desktop.worker", category: "operations")
  private var task: Task<Void, Never>?
  private var passwordReply: CheckedContinuation<String?, Never>?
  /// Окно создания архива общее с главным окном программы.
  private let creation = ArchiveCreationDialog()
  private var panel: NSSavePanel?
  private var started = false
  private var feedbackID: UUID?
  private var feedbackKind: OperationKind = .extract
  private var feedbackSubject = ""
  private let island = OperationIsland()
  private var islandTitle = ""
  private var resultURL: URL?
  private var donePause: Task<Void, Never>?
  /// Значок в строке меню, куда смахнули остров.
  private let statusItem = ProgressStatusItem()
  private var minimized = false

  private var progressHandler: ArchiveProgressHandler {
    { [weak self] value in await self?.receiveProgress(value) }
  }

  /// Публикует прогресс на главном акторе, где SwiftUI наблюдает модель.
  private func receiveProgress(_ value: ArchiveProgress) {
    progress = value
    beginFeedbackIfNeeded()
    if ApplicationMode.workerShowsIsland { updateIsland() }
  }

  /// Переносит ход операции из окна на остров, как после броска файлов на него.
  private func showIsland(title: String) {
    islandTitle = title
    ApplicationMode.workerShowsIsland = true
    for window in NSApp.windows where !(window is NSPanel) { window.orderOut(nil) }
    updateIsland()
  }

  /// Строка под именем: этап и процент, пока доля выполнения известна.
  private func updateIsland() {
    var stage: String
    switch feedbackKind {
    case _ where service.pause.isPaused: stage = L10n.tr("На паузе")
    case .create: stage = L10n.tr("Сжимаем…")
    case .verify: stage = ProgressFormatting.phaseTitle(.verifying)
    default: stage = L10n.tr("Распаковываем…")
    }
    var fraction: Double?
    if let progress, progress.phase != .preparing, let value = progress.fraction {
      fraction = value
      stage += " · \(Int((value * 100).rounded(.down)))%"
    }
    island.model.update(\.isPaused, to: service.pause.isPaused)
    guard minimized else {
      island.show(.working, title: islandTitle, subtitle: stage, fraction: fraction)
      return
    }
    let card = statusItem.card
    card.update(\.state, to: .working)
    card.update(\.title, to: islandTitle)
    card.update(\.stage, to: stage)
    card.update(\.fraction, to: fraction)
    card.update(\.remaining, to: progress?.remainingSeconds)
    card.update(\.isPaused, to: service.pause.isPaused)
  }

  /// Смахнутый остров уходит в строку меню; ход операции продолжает показывать значок.
  private func minimize() {
    guard ApplicationMode.workerShowsIsland, !minimized else { return }
    minimized = true
    island.hide()
    statusItem.show()
    updateIsland()
  }

  /// Возвращает операцию из строки меню на остров.
  private func restoreIsland() {
    guard minimized else { return }
    minimized = false
    statusItem.hide()
    if ApplicationMode.workerShowsIsland { updateIsland() }
  }

  private func togglePause() {
    if service.pause.isPaused { service.pause.resume() } else { service.pause.pause() }
    updateIsland()
  }

  /// Возвращает обычное окно для пароля и ошибок: на острове для них нет места.
  private func showWindow() {
    ApplicationMode.workerShowsIsland = false
    minimized = false
    statusItem.hide()
    island.hide()
    NSApp.windows.first { !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
  }

  /// Недолго показывает итог на острове; кнопка Finder или выход завершают показ раньше.
  private func showResultOnIsland() async {
    guard ApplicationMode.workerShowsIsland else { return }
    let pause = Task { _ = try? await Task.sleep(for: .seconds(4)) }
    donePause = pause
    let url = resultURL
    let reveal = {
      if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      pause.cancel()
    }
    let title = url?.lastPathComponent ?? islandTitle
    if minimized {
      let card = statusItem.card
      card.canReveal = url != nil
      card.reveal = reveal
      card.title = title
      card.state = .done
    } else {
      island.model.canReveal = url != nil
      island.model.reveal = reveal
      island.show(.done, title: title, subtitle: L10n.tr("Готово"), fraction: 1)
    }
    await pause.value
    donePause = nil
    island.hide()
    statusItem.hide()
  }

  /// Отсчёт для уведомления идёт с первого прогресса, а не с ожидания панелей и пароля.
  private func beginFeedbackIfNeeded() {
    guard feedbackID == nil else { return }
    feedbackID = OperationFeedback.shared.begin(kind: feedbackKind, subject: feedbackSubject)
  }

  /// Завершает учёт операции и ждёт постановки уведомления до закрытия процесса.
  private func finishFeedback(_ outcome: OperationOutcome) async {
    guard let id = feedbackID else { return }
    feedbackID = nil
    await OperationFeedback.shared.finish(id, outcome: outcome)?.value
  }

  /// Принимает один запрос на процесс worker и очищает сервис перед автоматическим завершением.
  func start(_ request: FinderRequest) {
    guard !started else { return }
    started = true
    logger.notice("Background operation started: \(request.action.rawValue, privacy: .public)")
    switch request.action {
    case .create, .add, .createZip, .create7z: feedbackKind = .create
    case .test: feedbackKind = .verify
    default: feedbackKind = .extract
    }
    feedbackSubject = request.urls.first?.lastPathComponent ?? ""
    island.model.cancel = { [weak self] in self?.cancel() }
    island.model.minimize = { [weak self] in self?.minimize() }
    island.model.togglePause = { [weak self] in self?.togglePause() }
    let card = statusItem.card
    card.cancel = island.model.cancel
    card.togglePause = island.model.togglePause
    card.restore = { [weak self] in self?.restoreIsland() }
    task = Task {
      do {
        try await execute(request)
        logger.notice("Background operation completed")
        await finishFeedback(.success)
        await service.cleanup()
        await showResultOnIsland()
        task = nil
        ApplicationMode.workerFinished = true
        NSApp.terminate(nil)
      } catch is CancellationError {
        logger.notice("Background operation cancelled")
        await finishFeedback(.cancelled)
        await service.cleanup()
        task = nil
        ApplicationMode.workerFinished = true
        NSApp.terminate(nil)
      } catch {
        await finishFeedback(.failure(error.localizedDescription))
        await service.cleanup()
        progress = nil
        errorMessage = error.localizedDescription
        showWindow()
        task = nil
        NSApp.activate(ignoringOtherApps: true)
      }
    }
  }

  /// Возобновляет единственный ожидающий запрос пароля и сразу очищает поле ввода.
  func submitPassword() {
    let reply = passwordReply
    passwordReply = nil
    needsPassword = false
    reply?.resume(returning: password)
    password = ""
  }

  /// Без активной задачи закрывает окно ошибки; иначе завершение выполнит отменяемая задача.
  func cancel() {
    cancelTask()
    if task == nil { NSApp.terminate(nil) }
  }

  /// Освобождает панель и ожидание пароля, чтобы отменённая задача могла завершиться.
  private func cancelTask() {
    task?.cancel()
    donePause?.cancel()
    panel?.cancel(nil)
    creation.cancel()
    let reply = passwordReply
    passwordReply = nil
    needsPassword = false
    reply?.resume(returning: nil)
  }

  /// Дожидается задачи до удаления временных файлов и разрешения системного завершения.
  func prepareTermination() async -> Bool {
    cancelTask()
    await task?.value
    await service.cleanup()
    return true
  }

  /// Запоминает результат для острова; неудача с Корзиной показывается после готового архива.
  private func finishCreation(_ outcome: ArchiveCreationOutcome) throws {
    resultURL = outcome.urls.last
    if let failure = outcome.trashFailure { throw SourceTrashFailure(message: failure) }
  }

  /// Проверяет отмену до и после ожидания ввода, не сохраняя пароль между архивами.
  private func askPassword(for url: URL) async throws -> String {
    try Task.checkCancellation()
    progress = nil
    message = L10n.tr("Введите пароль: %1$@", String(describing: url.lastPathComponent))
    password = ""
    needsPassword = true
    showWindow()
    NSApp.activate(ignoringOtherApps: true)
    let answer = await withCheckedContinuation { passwordReply = $0 }
    guard let answer else { throw CancellationError() }
    try Task.checkCancellation()
    return answer
  }

  /// Разделяет создание и извлечение; пароль повторно запрашивается для каждого архива.
  private func execute(_ request: FinderRequest) async throws {
    switch request.action {
    case .create, .add:
      let selection = FinderSelection(urls: request.urls)
      message = L10n.tr("Добавить в архив")
      NSApp.activate(ignoringOtherApps: true)
      guard
        let choice = await creation.present(
          message: L10n.tr("Создать новый архив из выделенных файлов и папок."),
          directory: selection.urls.first?.deletingLastPathComponent(),
          archiveName: selection.archiveName)
      else { throw CancellationError() }
      let destination = choice.destination
      message = L10n.tr("Создаём %1$@…", String(describing: destination.lastPathComponent))
      showIsland(title: destination.lastPathComponent)
      // Имя архива выбрано в диалоге, поэтому он один; исходники убираются по общей настройке.
      try await finishCreation(
        service.createArchives(
          from: selection.urls, proposedURL: destination, format: choice.options.format,
          options: choice.options, password: choice.password, separately: false,
          trashesSources: ArchivePreferences.trashesSources, progress: progressHandler))
    case .createZip, .create7z:
      let selection = FinderSelection(urls: request.urls)
      guard let first = selection.urls.first else { throw ArchiveError.invalidOperation }
      let options = ArchivePreferences.options
      let format = request.action == .createZip ? "zip" : "7z"
      message = L10n.tr(
        "Создаём %1$@.%2$@…", String(describing: selection.archiveName), String(describing: format))
      let proposed = first.deletingLastPathComponent().appendingPathComponent(
        selection.archiveName + "." + format)
      showIsland(title: proposed.lastPathComponent)
      try await finishCreation(
        service.createArchives(
          from: selection.urls, proposedURL: proposed, format: format, options: options,
          separately: ArchivePreferences.separatesArchives,
          trashesSources: ArchivePreferences.trashesSources, progress: progressHandler))
    case .extract, .extractHere, .extractFiles, .test:
      var destination: URL?
      if request.action == .extractFiles {
        message = L10n.tr("Выберите папку распаковки")
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.canCreateDirectories = true
        chooser.prompt = L10n.tr("Распаковать")
        chooser.directoryURL = request.urls.first?.deletingLastPathComponent()
        chooser.message = L10n.tr("Выберите папку для содержимого выделенных архивов.")
        panel = chooser
        NSApp.activate(ignoringOtherApps: true)
        let response = await withCheckedContinuation { continuation in
          chooser.begin { continuation.resume(returning: $0) }
        }
        panel = nil
        guard response == .OK, let selected = chooser.url else { throw CancellationError() }
        destination = selected
      }
      let preferences = ExtractionPreferences.load()
      var revealed: [URL] = []
      var trashFailure: String?
      for (index, url) in request.urls.enumerated() {
        var suppliedPassword = ""
        while true {
          try Task.checkCancellation()
          progress = nil
          showIsland(title: url.lastPathComponent)
          message =
            request.action == .test
            ? L10n.tr(
              "Тестируем %1$@ из %2$@: %3$@", String(describing: index + 1),
              String(describing: request.urls.count), String(describing: url.lastPathComponent))
            : L10n.tr(
              "Распаковываем %1$@ из %2$@: %3$@", String(describing: index + 1),
              String(describing: request.urls.count), String(describing: url.lastPathComponent))
          do {
            if request.action == .test {
              progress = ArchiveProgress(phase: .verifying)
              beginFeedbackIfNeeded()
              try await service.testArchive(url, password: suppliedPassword)
            } else {
              let outcome = try await service.extractAndFinish(
                url, password: suppliedPassword, directory: destination,
                createsSubfolder: request.action == .extract,
                smartExtraction: preferences.smartExtraction,
                trashesArchive: preferences.trashesArchive, progress: progressHandler)
              revealed.append(outcome.url)
              resultURL = outcome.url
              trashFailure = trashFailure ?? outcome.trashFailure
            }
            break
          } catch ArchiveError.passwordRequired {
            suppliedPassword = try await askPassword(for: url)
          }
        }
      }
      if request.action != .test, preferences.revealsResult, !revealed.isEmpty {
        if request.action == .extract {
          NSWorkspace.shared.activateFileViewerSelecting(revealed)
        } else {
          // Без подпапки результат лежит в самой папке назначения: открываем её.
          NSWorkspace.shared.open(destination ?? revealed[0])
        }
      }
      if let trashFailure { throw TrashFailure(message: trashFailure) }
    case .open: throw ArchiveError.invalidOperation
    }
  }
}

/// Извлечение удалось, но архив не удалось переместить в Корзину: окно worker остаётся с пояснением.
private struct TrashFailure: LocalizedError {
  let message: String
  var errorDescription: String? {
    L10n.tr("Не удалось переместить архив в Корзину: %1$@", String(describing: message))
  }
}

struct FinderOperationView: View {
  @ObservedObject var model: FinderOperationModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 14) {
        Image(systemName: model.errorMessage == nil ? "archivebox" : "exclamationmark.triangle")
          .font(.title2).foregroundStyle(model.errorMessage == nil ? Color.accentColor : .orange)
        Text(model.errorMessage ?? model.message).font(.headline)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      if model.errorMessage == nil && !model.needsPassword {
        OperationProgressView(progress: model.progress)
      }
      if model.needsPassword {
        SecureField(L10n.tr("Пароль архива"), text: $model.password)
          .textFieldStyle(.roundedBorder).onSubmit(model.submitPassword)
          .accessibilityLabel(L10n.tr("Пароль архива"))
      }
      HStack {
        Spacer()
        Button(
          model.errorMessage == nil ? L10n.tr("Отмена") : L10n.tr("Закрыть"), action: model.cancel
        )
        .keyboardShortcut(.cancelAction)
        if model.needsPassword {
          Button(L10n.tr("Продолжить"), action: model.submitPassword).keyboardShortcut(
            .defaultAction)
        }
      }
    }
    .padding(22).frame(width: 520)
  }
}
