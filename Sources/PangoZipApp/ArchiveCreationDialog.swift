import AppKit
import PangoZipCore
import SwiftUI

/// Куда и с какими параметрами создать новый архив.
struct ArchiveCreationChoice {
  let destination: URL
  let options: CompressionOptions
  let password: String
}

/// Окно «Добавить в архив»: имя и место нового архива, формат, сжатие и пароль.
/// Одно и то же окно открывается из Finder и из главного окна программы.
@MainActor
final class ArchiveCreationDialog: ObservableObject {
  @Published var creationFormat = "zip" {
    didSet {
      updateCreationFormat()
      // Форматы без шифрования не принимают пароль; поля в окне отключены, значения сбрасываем.
      if !CompressionOptions.supportsPassword(creationFormat) {
        creationPassword = ""
        creationPasswordConfirmation = ""
      }
    }
  }
  @Published var creationProfile = CompressionProfile.customID
  @Published var creationEncryptsFileNames = true
  @Published var creationVolumeSizeMB = 0
  @Published var creationLevel = 5
  @Published var creationSolid = true
  @Published var creationThreads = 0
  @Published var creationPassword = ""
  @Published var creationPasswordConfirmation = ""
  private var panel: NSSavePanel?
  private var saveDelegate: NewArchiveSaveDelegate?

  /// Открыто ли окно прямо сейчас.
  var isPresented: Bool { panel != nil }

  /// Показывает окно с параметрами из настроек; nil означает отмену.
  /// С `window` окно открывается листом над ним, иначе — отдельной панелью.
  func present(
    message: String, directory: URL?, archiveName: String, window: NSWindow? = nil
  ) async -> ArchiveCreationChoice? {
    guard panel == nil else { return nil }
    let defaults = ArchivePreferences.options
    creationFormat = defaults.format
    creationLevel = defaults.level
    creationSolid = defaults.solid
    creationThreads = defaults.threads
    creationEncryptsFileNames = defaults.encryptsFileNames
    creationVolumeSizeMB = defaults.volumeSizeMB ?? 0
    creationProfile = ArchivePreferences.profileID
    creationPassword = ""
    creationPasswordConfirmation = ""
    let chooser = NSSavePanel()
    chooser.title = L10n.tr("Добавить в архив")
    chooser.prompt = L10n.tr("Сжать")
    chooser.message = message
    chooser.directoryURL = directory
    chooser.nameFieldStringValue = archiveName + "." + creationFormat
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
    let response = await withCheckedContinuation { continuation in
      if let window {
        chooser.beginSheetModal(for: window) { continuation.resume(returning: $0) }
      } else {
        chooser.begin { continuation.resume(returning: $0) }
      }
    }
    panel = nil
    saveDelegate = nil
    let password = creationPassword
    creationPassword = ""
    creationPasswordConfirmation = ""
    guard response == .OK, let destination = chooser.url else { return nil }
    let options = CompressionOptions(
      format: creationFormat, level: creationLevel, solid: creationSolid,
      threads: creationThreads,
      excludesSystemFiles: ArchivePreferences.excludesSystemFiles,
      volumeSizeMB: creationVolumeSizeMB, encryptsFileNames: creationEncryptsFileNames)
    return ArchiveCreationChoice(destination: destination, options: options, password: password)
  }

  /// Закрывает открытое окно так же, как кнопка «Отмена».
  func cancel() { panel?.cancel(nil) }

  /// Согласует расширение в поле имени с выбранным форматом.
  private func updateCreationFormat() {
    guard let panel else { return }
    panel.allowedContentTypes = [ArchiveFormatPresentation.contentType(for: creationFormat)]
    // Составное расширение (tar.gz) не должно превращаться в «.gz» из-за типа содержимого.
    panel.allowsOtherFileTypes = true
    panel.nameFieldStringValue = ArchiveFormatPresentation.renamed(
      panel.nameFieldStringValue, to: creationFormat)
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
      message = L10n.tr("Пароли не совпадают.")
    } else if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
      message = L10n.tr("Такое имя уже занято. Укажите имя нового архива.")
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
  @ObservedObject var model: ArchiveCreationDialog
  var body: some View {
    Form {
      CompressionSettingsFields(
        profile: $model.creationProfile, format: $model.creationFormat,
        level: $model.creationLevel, solid: $model.creationSolid,
        encryptsFileNames: $model.creationEncryptsFileNames,
        volumeSizeMB: $model.creationVolumeSizeMB)
      Picker(L10n.tr("Потоки"), selection: $model.creationThreads) {
        Text(L10n.tr("Автоматически")).tag(0)
        ForEach([1, 2, 4, 8, 16, 32, 64], id: \.self) { Text(String($0)).tag($0) }
      }
      let supportsPassword = CompressionOptions.supportsPassword(model.creationFormat)
      SecureField(L10n.tr("Пароль (необязательно)"), text: $model.creationPassword)
        .disabled(!supportsPassword)
      SecureField(L10n.tr("Повторите пароль"), text: $model.creationPasswordConfirmation)
        .disabled(!supportsPassword)
      if !supportsPassword {
        Text(L10n.tr("Этот формат не поддерживает пароль."))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped).frame(width: 440, height: 440)
  }
}
