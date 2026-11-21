import AppKit
import PangoZipCore
import SwiftUI

/// Черновик нового архива: список файлов и папок, которые будут сжаты по кнопке «Создать архив…».
struct ArchiveDraftView: View {
  @ObservedObject var model: ArchiveBrowserModel

  var body: some View {
    let items = model.draft ?? []
    VStack(spacing: 0) {
      if items.isEmpty {
        emptyState
      } else {
        List(selection: $model.draftSelection) {
          ForEach(items, id: \.self) { url in
            ArchiveDraftRow(url: url)
              .contextMenu {
                Button(L10n.tr("Убрать из списка")) {
                  model.removeFromDraft(
                    model.draftSelection.contains(url) ? model.draftSelection : [url])
                }
              }
          }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: Brand.tableNS))
        .onDeleteCommand { model.removeFromDraft(model.draftSelection) }
        .accessibilityLabel(L10n.tr("Файлы нового архива"))
        Divider()
        actions
      }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 14) {
      Image(systemName: "plus.rectangle.on.folder")
        .font(.system(size: 24, weight: .medium)).foregroundStyle(Brand.gold)
        .frame(width: 52, height: 52)
        .background(Brand.header, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityHidden(true)
      Text(L10n.tr("Новый архив")).font(.largeTitle.weight(.bold)).padding(.top, 6)
      Text(L10n.tr("Перетащите в окно файлы и папки, которые нужно сжать."))
        .font(.body).foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Button(action: model.chooseFilesToAdd) {
          Text(L10n.tr("Добавить файлы и папки…")).fontWeight(.semibold)
            .foregroundStyle(Brand.onGold)
        }
        .buttonStyle(.borderedProminent).tint(Brand.gold)
        .disabled(!model.canEditDraft)
        Button(L10n.tr("Отмена"), action: model.discardDraft)
          .disabled(!model.canEditDraft)
      }
      .controlSize(.extraLarge).padding(.top, 10)
    }
    .padding(40).frame(maxWidth: 520, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 22)
        .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [7]))
    )
    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var actions: some View {
    HStack(spacing: 12) {
      Text(L10n.tr("Перетащите сюда ещё файлы или уберите лишние клавишей ⌫."))
        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
      Spacer(minLength: 8)
      Button(L10n.tr("Отмена"), action: model.discardDraft)
        .disabled(!model.canEditDraft)
      Button(action: model.createArchiveFromDraft) {
        Text(L10n.tr("Создать архив…")).fontWeight(.semibold).foregroundStyle(Brand.onGold)
      }
      .buttonStyle(.borderedProminent).tint(Brand.gold)
      .keyboardShortcut(.defaultAction)
      .disabled(!model.canCreateFromDraft)
    }
    .controlSize(.large)
    .padding(.horizontal, 16).padding(.vertical, 12)
    .background(Brand.surface)
  }
}

/// Строка черновика: значок и имя объекта на диске, рядом — папка, где он лежит.
private struct ArchiveDraftRow: View {
  let url: URL

  var body: some View {
    HStack(spacing: 8) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        .resizable().frame(width: 18, height: 18).accessibilityHidden(true)
      Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 12)
      Text(url.deletingLastPathComponent().path(percentEncoded: false))
        .font(.callout).foregroundStyle(.secondary)
        .lineLimit(1).truncationMode(.head)
        .help(url.path(percentEncoded: false))
    }
    .padding(.vertical, 2)
  }
}

/// Собирает URL нескольких перетащенных объектов: каждый загружается асинхронно,
/// а результат передаётся один раз в порядке перетаскивания.
@MainActor
final class DroppedFilesCollector {
  private var results: [URL?]
  private var remaining: Int
  private let completion: @MainActor ([URL]) -> Void

  private init(count: Int, completion: @escaping @MainActor ([URL]) -> Void) {
    results = Array(repeating: nil, count: count)
    remaining = count
    self.completion = completion
  }

  static func collect(
    _ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void
  ) {
    let collector = DroppedFilesCollector(count: providers.count, completion: completion)
    for (index, provider) in providers.enumerated() {
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        Task { @MainActor in collector.receive(url, at: index) }
      }
    }
  }

  private func receive(_ url: URL?, at index: Int) {
    results[index] = url
    remaining -= 1
    if remaining == 0 { completion(results.compactMap { $0 }) }
  }
}
