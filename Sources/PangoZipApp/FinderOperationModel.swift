import AppKit
import OSLog
import PangoZipCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum ApplicationMode {
  static var workerFinished = false
  static var isFinderWorker: Bool {
    Bundle.main.bundleIdentifier == "app.pangozip.desktop.worker"
      || ProcessInfo.processInfo.arguments.contains("--finder-worker")
  }
}

@MainActor
final class FinderOperationModel: ObservableObject {
  @Published private(set) var progress: ArchiveProgress?
  @Published private(set) var message = "Подготавливаем операцию…"
  @Published private(set) var errorMessage: String?
  @Published private(set) var needsPassword = false
  @Published var password = ""
  private let service = ArchiveService()
  private let logger = Logger(subsystem: "app.pangozip.desktop.worker", category: "operations")
  private var task: Task<Void, Never>?
  private var passwordReply: CheckedContinuation<String?, Never>?
  @Published var creationFormat = "zip" { didSet { updateCreationFormat() } }
  @Published var creationLevel = 5
  @Published var creationSolid = true
  @Published var creationThreads = 0
  @Published var creationPassword = ""
  @Published var creationPasswordConfirmation = ""
  private var panel: NSSavePanel?
  private var saveDelegate: NewArchiveSaveDelegate?
  private var started = false

  private var progressHandler: ArchiveProgressHandler {
    { [weak self] value in await self?.receiveProgress(value) }
  }

  /// Публикует прогресс на главном акторе, где SwiftUI наблюдает модель.
  private func receiveProgress(_ value: ArchiveProgress) { progress = value }

  /// Принимает один запрос на процесс worker и очищает сервис перед автоматическим завершением.
  func start(_ request: FinderRequest) {
    guard !started else { return }
    started = true
    logger.notice("Background operation started: \(request.action.rawValue, privacy: .public)")
    task = Task {
      do {
        try await execute(request)
        logger.notice("Background operation completed")
        await service.cleanup()
        task = nil
        ApplicationMode.workerFinished = true
        NSApp.terminate(nil)
      } catch is CancellationError {
        logger.notice("Background operation cancelled")
        await service.cleanup()
        task = nil
        ApplicationMode.workerFinished = true
        NSApp.terminate(nil)
      } catch {
        await service.cleanup()
        progress = nil
        errorMessage = error.localizedDescription
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
    panel?.cancel(nil)
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

  /// Проверяет отмену до и после ожидания ввода, не сохраняя пароль между архивами.
  private func askPassword(for url: URL) async throws -> String {
    try Task.checkCancellation()
    progress = nil
    message = "Введите пароль: " + url.lastPathComponent
    password = ""
    needsPassword = true
    NSApp.activate(ignoringOtherApps: true)
    let answer = await withCheckedContinuation { passwordReply = $0 }
    guard let answer else { throw CancellationError() }
    try Task.checkCancellation()
    return answer
  }

  /// Не меняет панель выбора папки; у панели создания согласует расширение с форматом.
  private func updateCreationFormat() {
    guard let panel, !(panel is NSOpenPanel) else { return }
    panel.allowedContentTypes = [UTType(filenameExtension: creationFormat) ?? .data]
    let name = panel.nameFieldStringValue as NSString
    if ["zip", "7z"].contains(name.pathExtension.lowercased()) {
      panel.nameFieldStringValue = name.deletingPathExtension + "." + creationFormat
    }
  }

  /// Разделяет создание и извлечение; пароль повторно запрашивается для каждого архива.
  private func execute(_ request: FinderRequest) async throws {
    switch request.action {
    case .create, .add:
      let selection = FinderSelection(urls: request.urls)
      let defaults = ArchivePreferences.options
      creationFormat = defaults.format
      creationLevel = defaults.level
      creationSolid = defaults.solid
      creationThreads = defaults.threads
      creationPassword = ""
      creationPasswordConfirmation = ""
      message = "Добавить в архив"
      let chooser = NSSavePanel()
      chooser.title = "Добавить в архив"
      chooser.prompt = "Сжать"
      chooser.message = "Создать новый архив из выделенных файлов и папок."
      chooser.directoryURL = selection.urls.first?.deletingLastPathComponent()
      chooser.nameFieldStringValue = selection.archiveName + "." + creationFormat
      chooser.canCreateDirectories = true
      let delegate = NewArchiveSaveDelegate { [weak self] in
        guard let self else { return false }
        return self.creationPassword == self.creationPasswordConfirmation
      }
      saveDelegate = delegate
      chooser.delegate = delegate
      chooser.accessoryView = NSHostingView(rootView: ArchiveCreationOptionsView(model: self))
      panel = chooser
      updateCreationFormat()
      NSApp.activate(ignoringOtherApps: true)
      let response = await withCheckedContinuation { continuation in
        chooser.begin { continuation.resume(returning: $0) }
      }
      panel = nil
      saveDelegate = nil
      guard response == .OK, let destination = chooser.url else { throw CancellationError() }
      let options = CompressionOptions(
        format: creationFormat, level: creationLevel, solid: creationSolid, threads: creationThreads
      )
      message = "Создаём " + destination.lastPathComponent + "…"
      defer {
        creationPassword = ""
        creationPasswordConfirmation = ""
      }
      _ = try await service.createArchive(
        from: selection.urls, proposedURL: destination, format: options.format, options: options,
        password: creationPassword, progress: progressHandler)
    case .createZip, .create7z:
      let selection = FinderSelection(urls: request.urls)
      guard let first = selection.urls.first else { throw ArchiveError.invalidOperation }
      let options = ArchivePreferences.options
      let format = request.action == .createZip ? "zip" : "7z"
      message = "Создаём \(selection.archiveName).\(format)…"
      let proposed = first.deletingLastPathComponent().appendingPathComponent(
        selection.archiveName + "." + format)
      _ = try await service.createArchive(
        from: selection.urls, proposedURL: proposed, format: format, options: options,
        progress: progressHandler)
    case .extract, .extractHere, .extractFiles, .test:
      var destination: URL?
      if request.action == .extractFiles {
        message = "Выберите папку распаковки"
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.canCreateDirectories = true
        chooser.prompt = "Распаковать"
        chooser.directoryURL = request.urls.first?.deletingLastPathComponent()
        chooser.message = "Выберите папку для содержимого выделенных архивов."
        panel = chooser
        NSApp.activate(ignoringOtherApps: true)
        let response = await withCheckedContinuation { continuation in
          chooser.begin { continuation.resume(returning: $0) }
        }
        panel = nil
        guard response == .OK, let selected = chooser.url else { throw CancellationError() }
        destination = selected
      }
      for (index, url) in request.urls.enumerated() {
        var suppliedPassword = ""
        while true {
          try Task.checkCancellation()
          message =
            (request.action == .test ? "Тестируем " : "Распаковываем ")
            + "\(index + 1) из \(request.urls.count): \(url.lastPathComponent)"
          do {
            if request.action == .test {
              progress = ArchiveProgress(phase: .verifying)
              try await service.testArchive(url, password: suppliedPassword)
            } else {
              _ = try await service.extractArchive(
                url, password: suppliedPassword, directory: destination,
                createsSubfolder: request.action == .extract, progress: progressHandler)
            }
            break
          } catch ArchiveError.passwordRequired {
            suppliedPassword = try await askPassword(for: url)
          }
        }
      }
    case .open: throw ArchiveError.invalidOperation
    }
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
        SecureField("Пароль архива", text: $model.password)
          .textFieldStyle(.roundedBorder).onSubmit(model.submitPassword)
          .accessibilityLabel("Пароль архива")
      }
      HStack {
        Spacer()
        Button(model.errorMessage == nil ? "Отмена" : "Закрыть", action: model.cancel)
          .keyboardShortcut(.cancelAction)
        if model.needsPassword {
          Button("Продолжить", action: model.submitPassword).keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(22).frame(width: 520)
  }
}

@MainActor
private final class NewArchiveSaveDelegate: NSObject, NSOpenSavePanelDelegate {
  let passwordsMatch: () -> Bool
  /// Принимает проверку актуальных полей, чтобы панель учитывала последующие изменения пароля.
  init(passwordsMatch: @escaping () -> Bool) { self.passwordsMatch = passwordsMatch }
  /// Не разрешает существующий путь и несовпадающие пароли до закрытия панели создания.
  func panel(_ sender: Any, validate url: URL) throws {
    let message: String?
    if !passwordsMatch() {
      message = "Пароли не совпадают."
    } else if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
      message = "Такое имя уже занято. Укажите имя нового архива."
    } else {
      message = nil
    }
    if let message {
      throw NSError(
        domain: "app.pangozip.creation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
}

private struct ArchiveCreationOptionsView: View {
  @ObservedObject var model: FinderOperationModel
  var body: some View {
    Form {
      Picker("Формат архива", selection: $model.creationFormat) {
        Text("7z").tag("7z")
        Text("ZIP").tag("zip")
      }
      Picker("Уровень сжатия", selection: $model.creationLevel) {
        Text("Без сжатия").tag(0)
        Text("Быстрая").tag(1)
        Text("Обычная").tag(5)
        Text("Максимальная").tag(7)
        Text("Ультра").tag(9)
      }
      Toggle("Сплошное сжатие", isOn: $model.creationSolid).disabled(model.creationFormat != "7z")
      Picker("Потоки", selection: $model.creationThreads) {
        Text("Автоматически").tag(0)
        ForEach([1, 2, 4, 8, 16, 32, 64], id: \.self) { Text(String($0)).tag($0) }
      }
      SecureField("Пароль (необязательно)", text: $model.creationPassword)
      SecureField("Повторите пароль", text: $model.creationPasswordConfirmation)
    }
    .formStyle(.grouped).frame(width: 440, height: 290)
  }
}
