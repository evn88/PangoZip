import FinderSync
import PangoZipCore
import SwiftUI

@MainActor
enum ArchivePreferences {
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
  @AppStorage("compressionFormat") private var format = "zip"
  @AppStorage("compressionLevel") private var level = 5
  @AppStorage("compressionSolid") private var solid = true
  @AppStorage("compressionThreads") private var threads = 0

  private var uninstallerURL: URL {
    Bundle.main.bundleURL.appendingPathComponent(
      "Contents/SharedSupport/Uninstall PangoZip.command")
  }

  var body: some View {
    Form {
      Section("Архивация из Finder") {
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
          .help("Улучшает сжатие похожих файлов в 7z, но замедляет извлечение отдельных файлов.")
        Picker("Потоки", selection: $threads) {
          Text("Автоматически").tag(0)
          ForEach([1, 2, 4, 8, 16, 32, 64], id: \.self) { Text(String($0)).tag($0) }
        }
        Text(
          "Это начальные параметры окна «Добавить в архив…». Быстрые команды создания ZIP и 7z используют эти настройки, меняя только формат. Готовый архив создаётся рядом с выделенными файлами; совпадающие имена получают числовой суффикс."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Finder") {
        Button("Показать программу удаления…") {
          NSWorkspace.shared.activateFileViewerSelecting([uninstallerURL])
        }
        .disabled(!FileManager.default.fileExists(atPath: uninstallerURL.path))
        .help("Перед запуском программы удаления закройте PangoZip и дождитесь фоновых операций.")
        Button("Настроить расширение Finder…") {
          FIFinderSyncController.showExtensionManagementInterface()
        }
        Text(
          "PangoZip нужно включить в расширениях Finder. Архивация и извлечение показывают только небольшое окно прогресса."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped).frame(width: 490, height: 480)
  }
}
