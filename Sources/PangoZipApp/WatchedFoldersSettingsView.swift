import AppKit
import PangoZipCore
import SwiftUI

/// Вкладка «Извлечение»: действия после извлечения и отслеживаемые папки.
struct ExtractionSettingsView: View {
  @AppStorage(ExtractionPreferences.smartKey) private var smartExtraction = true
  @AppStorage(ExtractionPreferences.revealKey) private var revealsResult = true
  @AppStorage(ExtractionPreferences.trashKey) private var trashesArchive = false

  var body: some View {
    Form {
      Section(L10n.tr("После извлечения")) {
        Toggle(
          L10n.tr("Не создавать лишнюю папку, если в архиве один объект"), isOn: $smartExtraction)
        Toggle(L10n.tr("Показать результат в Finder"), isOn: $revealsResult)
        Toggle(
          L10n.tr("Переместить архив в Корзину после успешного извлечения"), isOn: $trashesArchive)
        Text(
          L10n.tr(
            "В Корзину попадают все тома многотомного архива, и только после полностью успешного извлечения. Безвозвратно ничего не удаляется."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      WatchedFoldersSection()
    }
    .formStyle(.grouped)
  }
}

/// Список отслеживаемых папок с настройкой назначения и удаления архива для каждой.
struct WatchedFoldersSection: View {
  @State private var rules = WatchedFolderStore.load()
  @ObservedObject private var monitor = WatchedFolderMonitor.shared

  var body: some View {
    Section(L10n.tr("Отслеживаемые папки")) {
      if rules.isEmpty {
        Text(
          L10n.tr(
            "Новые архивы в добавленных папках извлекаются автоматически. Архивы, которые уже лежат в папке, не затрагиваются."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      ForEach($rules) { $rule in
        WatchedFolderRuleRow(rule: $rule) { remove(rule.id) }
      }
      Button(L10n.tr("Добавить папку…"), action: addFolder)
      if !rules.isEmpty {
        Text(
          L10n.tr(
            "Пока включено отслеживание, PangoZip продолжает работать после закрытия окон: значок остаётся в строке меню."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .onChange(of: rules) { _, newValue in
      WatchedFolderStore.save(newValue)
      WatchedFolderMonitor.shared.reload()
    }
    if !monitor.events.isEmpty {
      Section(L10n.tr("Последние события")) {
        ForEach(monitor.events.prefix(5)) { event in
          Text(event.text).font(.caption).lineLimit(2).textSelection(.enabled)
        }
      }
    }
  }

  private func addFolder() {
    let chooser = NSOpenPanel()
    chooser.canChooseDirectories = true
    chooser.canChooseFiles = false
    chooser.canCreateDirectories = true
    chooser.message = L10n.tr("Выберите папку, за которой должен следить PangoZip.")
    guard chooser.runModal() == .OK, let url = chooser.url else { return }
    let path = url.standardizedFileURL.path
    guard !rules.contains(where: { $0.folderPath == path }) else { return }
    rules.append(WatchedFolderRule(folderPath: path))
  }

  private func remove(_ id: UUID) {
    rules.removeAll { $0.id == id }
  }
}

private struct WatchedFolderRuleRow: View {
  @Binding var rule: WatchedFolderRule
  let onRemove: () -> Void

  /// Пока у правила одно безусловное назначение; интерфейс редактирует именно его.
  private var destination: Binding<WatchedDestination> {
    Binding(
      get: { rule.destinations.first ?? WatchedDestination() },
      set: {
        if rule.destinations.isEmpty {
          rule.destinations = [$0]
        } else {
          rule.destinations[0] = $0
        }
      })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Toggle(L10n.tr("Отслеживание включено"), isOn: $rule.isEnabled).labelsHidden()
        Text((rule.folderPath as NSString).abbreviatingWithTildeInPath)
          .lineLimit(1).truncationMode(.middle)
        Spacer()
        Button(L10n.tr("Удалить"), role: .destructive, action: onRemove)
      }
      Picker(
        L10n.tr("Куда извлекать"),
        selection: Binding(
          get: { destination.wrappedValue.directoryPath != nil },
          set: { custom in
            if custom {
              chooseDestination()
            } else {
              destination.wrappedValue.directoryPath = nil
            }
          })
      ) {
        Text(L10n.tr("В ту же папку")).tag(false)
        Text(L10n.tr("В другую папку")).tag(true)
      }
      .pickerStyle(.segmented)
      if let path = destination.wrappedValue.directoryPath {
        HStack {
          Text((path as NSString).abbreviatingWithTildeInPath)
            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          Spacer()
          Button(L10n.tr("Выбрать папку…"), action: { chooseDestination() })
        }
      }
      Toggle(
        L10n.tr("Удалять архив после извлечения (в Корзину)"),
        isOn: destination.deletesArchive)
    }
    .padding(.vertical, 2)
  }

  private func chooseDestination() {
    let chooser = NSOpenPanel()
    chooser.canChooseDirectories = true
    chooser.canChooseFiles = false
    chooser.canCreateDirectories = true
    if chooser.runModal() == .OK, let url = chooser.url {
      destination.wrappedValue.directoryPath = url.standardizedFileURL.path
    }
  }
}
