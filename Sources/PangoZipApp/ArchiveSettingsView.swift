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
      threads: defaults.integer(forKey: "compressionThreads"))
  }
}

struct ArchiveSettingsView: View {
  @ObservedObject var integration: FinderIntegrationModel
  @AppStorage("compressionFormat") private var format = "zip"
  @AppStorage("compressionLevel") private var level = 5
  @AppStorage("compressionSolid") private var solid = true
  @AppStorage("compressionThreads") private var threads = 0

  var body: some View {
    TabView {
      compressionSettings
        .tabItem { Label("Архивация", systemImage: "archivebox") }
      finderSettings
        .tabItem { Label("Finder", systemImage: "folder") }
      applicationSettings
        .tabItem { Label("Приложение", systemImage: "app.badge") }
    }
    .frame(width: 560, height: 480)
  }

  private var compressionSettings: some View {
    Form {
      Section("Параметры по умолчанию") {
        Picker("Формат по умолчанию", selection: $format) {
          Text("ZIP").tag("zip")
          Text("7z").tag("7z")
        }
        Picker("Степень сжатия", selection: $level) {
          Text("Без сжатия").tag(0)
          Text("Быстрая").tag(1)
          Text("Обычная").tag(5)
          Text("Максимальная").tag(7)
          Text("Ультра").tag(9)
        }
        Toggle("Сплошное сжатие 7z", isOn: $solid)
          .disabled(format != "7z")
          .help("Улучшает сжатие похожих файлов в 7z, но замедляет извлечение отдельных файлов.")
        Picker("Потоки процессора", selection: $threads) {
          Text("Автоматически").tag(0)
          ForEach([1, 2, 4, 8, 16, 32, 64], id: \.self) { Text(String($0)).tag($0) }
        }
        Text(
          "Это начальные параметры окна «Добавить в архив…». Быстрые команды создания ZIP и 7z используют эти настройки, меняя только формат. Готовый архив создаётся рядом с выделенными файлами; совпадающие имена получают числовой суффикс."
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
        Button("Настроить расширение Finder…", action: integration.openExtensionSettings)
        Button("Повторить подготовку меню") { Task { await integration.prepare() } }
          .disabled(integration.state == .preparing)
        Text(
          "Расширение и фоновый помощник находятся внутри приложения. Отдельная установка не требуется."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var applicationSettings: some View {
    Form {
      if let supportURL = SupportConfiguration.pageURL {
        DevelopmentSupportSection(pageURL: supportURL)
      }
      Section("Удаление") {
        Button("Показать PangoZip в Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        Text(
          "Закройте PangoZip и дождитесь фоновых операций, затем переместите приложение в Корзину. Встроенные компоненты удаляются вместе с ним."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}
