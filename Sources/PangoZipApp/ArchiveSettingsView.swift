import FinderSync
import PangoZipCore
import SwiftUI

@MainActor
enum ArchivePreferences {
  /// Переносит только отсутствующие параметры и отмечает миграцию в общем домене настроек.
  static func migrateLegacySettings() {
    guard let defaults = UserDefaults(suiteName: "app.pangozip.desktop"),
      !defaults.bool(forKey: "legacySettingsMigrated")
    else { return }
    let legacy = UserDefaults(suiteName: "app.zipevra.desktop")
    for key in ["compressionFormat", "compressionLevel", "compressionSolid", "compressionThreads"] {
      if defaults.object(forKey: key) == nil, let value = legacy?.object(forKey: key) {
        defaults.set(value, forKey: key)
      }
    }
    defaults.set(true, forKey: "legacySettingsMigrated")
  }

  static var options: CompressionOptions {
    migrateLegacySettings()
    let defaults = UserDefaults(suiteName: "app.pangozip.desktop") ?? .standard
    return CompressionOptions(
      format: defaults.string(forKey: "compressionFormat") ?? "zip",
      level: defaults.object(forKey: "compressionLevel") as? Int ?? 5,
      solid: defaults.object(forKey: "compressionSolid") as? Bool ?? true,
      threads: defaults.integer(forKey: "compressionThreads"),
      excludesSystemFiles: excludesSystemFiles,
      volumeSizeMB: defaults.integer(forKey: "compressionVolumeSize"),
      encryptsFileNames: defaults.object(forKey: "compressionEncryptNames") as? Bool ?? true)
  }

  /// Профиль по умолчанию: сохранённый встроенный либо совпавший с текущими значениями, иначе «Свой».
  static var profileID: String {
    let defaults = UserDefaults(suiteName: "app.pangozip.desktop") ?? .standard
    if let stored = defaults.string(forKey: "compressionProfile"),
      CompressionProfile.builtIn(id: stored) != nil
    {
      return stored
    }
    let current = options
    return CompressionProfile.matching(
      format: current.format, level: current.level, solid: current.solid,
      encryptsFileNames: current.encryptsFileNames, volumeSizeMB: current.volumeSizeMB)?.id
      ?? CompressionProfile.customID
  }

  /// Служебные файлы систем по умолчанию не попадают в создаваемые архивы.
  static var excludesSystemFiles: Bool {
    let defaults = UserDefaults(suiteName: "app.pangozip.desktop") ?? .standard
    return defaults.object(forKey: "excludeSystemFiles") as? Bool ?? true
  }
}

struct ArchiveSettingsView: View {
  @ObservedObject var integration: FinderIntegrationModel
  var updater: ApplicationUpdater? = nil
  @AppStorage("compressionFormat") private var format = "zip"
  @AppStorage("compressionLevel") private var level = 5
  @AppStorage("compressionSolid") private var solid = true
  @AppStorage("compressionThreads") private var threads = 0
  @AppStorage("compressionProfile") private var profile = CompressionProfile.customID
  @AppStorage("compressionEncryptNames") private var encryptsFileNames = true
  @AppStorage("compressionVolumeSize") private var volumeSizeMB = 0
  @AppStorage("excludeSystemFiles") private var excludesSystemFiles = true
  @AppStorage("hideSystemFiles") private var hidesSystemFiles = true
  @AppStorage(AppearanceMode.storageKey) private var appearanceMode = AppearanceMode.system.rawValue

  var body: some View {
    TabView {
      if let updater {
        ApplicationUpdatesView(updater: updater)
          .tabItem { Label(L10n.tr("Обновления"), systemImage: "arrow.down.circle") }
      }

      compressionSettings
        .tabItem { Label(L10n.tr("Архивация"), systemImage: "archivebox") }
      ArchiveAssociationsView()
        .tabItem { Label(L10n.tr("Типы архивов"), systemImage: "square.and.arrow.down") }
      finderSettings
        .tabItem { Label("Finder", systemImage: "folder") }
      ExtractionSettingsView()
        .tabItem { Label(L10n.tr("Извлечение"), systemImage: "tray.and.arrow.up") }
      DropIslandSettingsView()
        .tabItem { Label(L10n.tr("Остров"), systemImage: "rectangle.topthird.inset.filled") }
      applicationSettings
        .tabItem { Label(L10n.tr("Приложение"), systemImage: "app.badge") }
    }
    .frame(width: 560, height: 480)
  }

  private var compressionSettings: some View {
    Form {
      Section(L10n.tr("Параметры по умолчанию")) {
        CompressionSettingsFields(
          profile: $profile, format: $format, level: $level, solid: $solid,
          encryptsFileNames: $encryptsFileNames, volumeSizeMB: $volumeSizeMB,
          formatTitle: L10n.tr("Формат по умолчанию"), levelTitle: L10n.tr("Степень сжатия"),
          solidTitle: L10n.tr("Сплошное сжатие 7z"))
        Picker(L10n.tr("Потоки процессора"), selection: $threads) {
          Text(L10n.tr("Автоматически")).tag(0)
          ForEach([1, 2, 4, 8, 16, 32, 64], id: \.self) { Text(String($0)).tag($0) }
        }
        Toggle(L10n.tr("Не добавлять служебные файлы систем"), isOn: $excludesSystemFiles)
          .help(L10n.tr("Пропускает .DS_Store, __MACOSX, ._*, Thumbs.db и подобные файлы."))
        Text(
          L10n.tr(
            "Это начальные параметры окна «Добавить в архив…». Быстрые команды создания ZIP и 7z используют эти настройки, меняя только формат. Готовый архив создаётся рядом с выделенными файлами; совпадающие имена получают числовой суффикс."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var finderSettings: some View {
    Form {
      Section("Finder") {
        Text(integration.statusText).font(.callout)
        Button(L10n.tr("Настроить расширение Finder…"), action: integration.openExtensionSettings)
        Button(L10n.tr("Повторить подготовку меню")) { Task { await integration.prepare() } }
          .disabled(integration.state == .preparing)
        Text(
          L10n.tr(
            "Расширение и фоновый помощник находятся внутри приложения. Отдельная установка не требуется."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var applicationSettings: some View {
    Form {
      Section(L10n.tr("Оформление")) {
        Picker(L10n.tr("Оформление"), selection: $appearanceMode) {
          ForEach(AppearanceMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .onChange(of: appearanceMode) { _, mode in AppearanceMode.apply(mode) }
      }
      Section(L10n.tr("Просмотр архивов")) {
        Toggle(L10n.tr("Скрывать служебные файлы систем"), isOn: $hidesSystemFiles)
        Text(
          L10n.tr(
            "Скрывает в списке __MACOSX, .DS_Store, ._*, Thumbs.db и подобные файлы. При распаковке всего архива они всё равно извлекаются."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      if let supportURL = SupportConfiguration.pageURL {
        DevelopmentSupportSection(pageURL: supportURL)
      }
      Section(L10n.tr("Удаление")) {
        Button(L10n.tr("Показать PangoZip в Finder")) {
          NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        Text(
          L10n.tr(
            "Закройте PangoZip и дождитесь фоновых операций, затем переместите приложение в Корзину. Встроенные компоненты удаляются вместе с ним."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}
