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
  var updater: ApplicationUpdater? = nil
  @AppStorage("compressionFormat") private var format = "zip"
  @AppStorage("compressionLevel") private var level = 5
  @AppStorage("compressionSolid") private var solid = true
  @AppStorage("compressionThreads") private var threads = 0

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
      applicationSettings
        .tabItem { Label(L10n.tr("Приложение"), systemImage: "app.badge") }
    }
    .frame(width: 560, height: 480)
  }

  private var compressionSettings: some View {
    Form {
      Section(L10n.tr("Параметры по умолчанию")) {
        Picker(L10n.tr("Формат по умолчанию"), selection: $format) {
          Text("ZIP").tag("zip")
          Text("7z").tag("7z")
        }
        Picker(L10n.tr("Степень сжатия"), selection: $level) {
          Text(L10n.tr("Без сжатия")).tag(0)
          Text(L10n.tr("Быстрая")).tag(1)
          Text(L10n.tr("Обычная")).tag(5)
          Text(L10n.tr("Максимальная")).tag(7)
          Text(L10n.tr("Ультра")).tag(9)
        }
        Toggle(isOn: $solid) {
          HStack(spacing: 6) {
            Text(L10n.tr("Сплошное сжатие 7z"))
            Image(systemName: "questionmark.circle")
              .foregroundStyle(.secondary)
              .help(
                L10n.tr(
                  "Сжимает файлы вместе: архив обычно меньше, но извлечение одного файла может занять больше времени."
                )
              )
              .accessibilityHidden(true)
          }
        }
        .accessibilityLabel(L10n.tr("Сплошное сжатие 7z"))
        .accessibilityHint(
          L10n.tr(
            "Сжимает файлы вместе: архив обычно меньше, но извлечение одного файла может занять больше времени."
          )
        )
        .disabled(format != "7z")
        Picker(L10n.tr("Потоки процессора"), selection: $threads) {
          Text(L10n.tr("Автоматически")).tag(0)
          ForEach([1, 2, 4, 8, 16, 32, 64], id: \.self) { Text(String($0)).tag($0) }
        }
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
