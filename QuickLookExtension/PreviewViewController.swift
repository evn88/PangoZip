import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

#if SWIFT_PACKAGE
  import PangoZipCore
#endif

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
  let model = ArchivePreviewModel()
  private var preparation: Task<Void, Error>?
  private var requestID = UUID()

  override func loadView() {
    view = NSHostingView(
      rootView: ArchivePreviewView(
        model: model, previewWindow: { [weak self] in self?.view.window }
      ) { [weak self] in
        guard let self, let url = model.url else { return }
        try await preparePreviewOfFile(at: url)
      })
    preferredContentSize = NSSize(width: 900, height: 600)
  }

  func preparePreviewOfFile(at url: URL) async throws {
    _ = view
    let id = UUID()
    requestID = id
    let previous = preparation
    previous?.cancel()
    let task = Task { @MainActor in
      _ = try? await previous?.value
      try Task.checkCancellation()
      await model.close()
      try Task.checkCancellation()
      try await model.prepare(url)
    }
    preparation = task
    do {
      try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    } catch {
      if error is CancellationError { throw error }
      if requestID == id { model.message = error.localizedDescription }
    }
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
    preparation?.cancel()
    let pending = preparation
    let id = requestID
    Task { @MainActor in
      _ = try? await pending?.value
      if requestID == id { await model.close() }
    }
  }
}

private struct ArchivePreviewView: View {
  @Bindable var model: ArchivePreviewModel
  let previewWindow: @MainActor () -> NSWindow?
  let reloadPreview: @MainActor () async throws -> Void
  @State private var selection: Set<String> = []
  @State private var query = ""
  @State private var extracted: [URL] = []
  @State private var passwordRequested = false
  @State private var panel: NSOpenPanel?
  @State private var operation: Task<Void, Never>?

  private var isLocked: Bool { model.isBusy || panel != nil }

  var body: some View {
    VStack(spacing: 10) {
      if let session = model.session {
        header(session)
        table(session)
        footer
      } else if model.isBusy {
        ProgressView(L10n.tr("Читаем содержимое архива…"))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        unavailable
      }
    }
    .padding()
    .frame(minWidth: 650, minHeight: 350)
    .onChange(of: model.session?.id) {
      selection = []
      query = ""
      extracted = []
      passwordRequested = false
      panel?.cancel(nil)
    }
    .onDisappear {
      panel?.cancel(nil)
      operation?.cancel()
      let pending = operation
      Task {
        await pending?.value
        await model.close()
      }
    }
  }

  // Имя архива уже показано в заголовке Quick Look, поэтому здесь только сводка и действия.
  private func header(_ session: ArchiveSession) -> some View {
    HStack(spacing: 8) {
      Text(
        [
          L10n.tr("Объектов: %1$@", session.entries.count.formatted()),
          Self.size(model.totalSize), session.format,
        ].joined(separator: " · ")
      )
      .font(.callout).foregroundStyle(.secondary).lineLimit(1)
      .layoutPriority(-1)
      Spacer()
      HStack(spacing: 4) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(L10n.tr("Имя или путь в архиве"), text: $query).textFieldStyle(.plain)
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).foregroundStyle(.secondary)
          .accessibilityLabel(L10n.tr("Отмена"))
        }
      }
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(.quaternary, in: .rect(cornerRadius: 6))
      .frame(width: 220)
      Button(L10n.tr("Извлечь выбранное…")) { chooseDestination(paths: Array(selection)) }
        .disabled(selection.isEmpty || isLocked)
      Button(L10n.tr("Распаковать всё…")) { chooseDestination(paths: nil) }
        .help(L10n.tr("Распаковать в «%1$@/»", FinderSelection.extractionName(for: session.url)))
        .disabled(isLocked)
    }
  }

  private func table(_ session: ArchiveSession) -> some View {
    let nodes = rows(session)
    return Table(nodes, children: \.children, selection: $selection) {
      TableColumn(L10n.tr("Имя")) { node in
        HStack(spacing: 6) {
          Image(nsImage: Self.icon(node)).resizable().frame(width: 16, height: 16)
            .accessibilityHidden(true)
          Text(node.name).lineLimit(1).truncationMode(.middle)
          if node.entry?.isEncrypted == true {
            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
              .accessibilityLabel(L10n.tr("Шифрование"))
          }
          if !query.isEmpty, let slash = node.path.lastIndex(of: "/") {
            Text(node.path[..<slash]).font(.caption).foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.head)
          }
        }
      }
      .width(min: 250, ideal: 420)
      TableColumn(L10n.tr("Тип")) { node in
        Text(Self.kind(node)).foregroundStyle(.secondary).lineLimit(1)
      }
      .width(min: 80, ideal: 150)
      TableColumn(L10n.tr("Размер")) { node in
        if let size = Self.isFolder(node) ? model.folderSizes[node.path] : node.entry?.size {
          Text(Self.size(size)).monospacedDigit()
            .foregroundStyle(Self.isFolder(node) ? .secondary : .primary)
        }
      }
      .width(90)
      TableColumn(L10n.tr("Изменён")) { node in
        if let date = node.entry?.modifiedAt {
          Text(date, format: .dateTime.year().month().day().hour().minute())
        }
      }
      .width(150)
    }
    .contextMenu(forSelectionType: String.self) { paths in
      if !paths.isEmpty {
        Button(L10n.tr("Извлечь…")) { chooseDestination(paths: Array(paths)) }
          .disabled(isLocked)
        Button(L10n.tr("Копировать путь в архиве")) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(paths.sorted().joined(separator: "\n"), forType: .string)
        }
      }
    }
    .overlay {
      if nodes.isEmpty {
        Text(query.isEmpty ? L10n.tr("Архив пуст") : L10n.tr("Ничего не найдено"))
          .foregroundStyle(.secondary)
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      if model.isBusy { ProgressView().controlSize(.small) }
      Text(
        model.message.isEmpty && !selection.isEmpty
          ? L10n.tr("Выбрано: %1$@", selection.count.formatted()) : model.message
      )
      .font(.callout).lineLimit(2).textSelection(.enabled)
      if !extracted.isEmpty, !model.isBusy {
        Button(L10n.tr("Показать в Finder")) {
          NSWorkspace.shared.activateFileViewerSelecting(extracted)
        }
        .buttonStyle(.link)
      }
      Spacer()
      // Поле нужно только зашифрованным архивам; остальным оно лишь занимает место.
      if model.hasEncryptedEntries || passwordRequested || !model.password.isEmpty {
        SecureField(L10n.tr("Пароль"), text: $model.password)
          .frame(width: 200)
          .disabled(isLocked)
          .onSubmit { reload() }
      }
    }
    .frame(minHeight: 22)
  }

  private var unavailable: some View {
    VStack(spacing: 12) {
      Image(systemName: "archivebox").font(.system(size: 44)).foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(model.message).multilineTextAlignment(.center).textSelection(.enabled)
      SecureField(L10n.tr("Пароль (необязательно)"), text: $model.password)
        .frame(width: 240)
        .onSubmit { reload() }
      Button(L10n.tr("Открыть архив")) { reload() }.keyboardShortcut(.defaultAction)
    }
    .disabled(isLocked)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// При поиске дерево заменяется плоским списком совпадений по полному пути.
  private func rows(_ session: ArchiveSession) -> [ArchiveNode] {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return session.roots }
    return session.entries.filter { $0.path.localizedCaseInsensitiveContains(text) }.map {
      ArchiveNode(
        path: $0.path, name: String($0.path.split(separator: "/").last ?? ""), entry: $0,
        children: nil)
    }
  }

  private static func isFolder(_ node: ArchiveNode) -> Bool {
    node.children != nil || node.entry?.isDirectory == true
  }

  private static func type(_ node: ArchiveNode) -> UTType? {
    if isFolder(node) { return .folder }
    let ext = (node.name as NSString).pathExtension
    return ext.isEmpty ? nil : UTType(filenameExtension: ext)
  }

  private static func icon(_ node: ArchiveNode) -> NSImage {
    NSWorkspace.shared.icon(for: type(node) ?? .data)
  }

  private static func kind(_ node: ArchiveNode) -> String {
    if isFolder(node) { return L10n.tr("Папка") }
    return type(node)?.localizedDescription ?? L10n.tr("Файл")
  }

  private static func size(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
  }

  private func reload() {
    operation = Task { @MainActor in
      do { try await reloadPreview() } catch { model.message = error.localizedDescription }
    }
  }

  /// nil означает весь архив; иначе извлекаются выбранные объекты без вложенных дублей.
  private func chooseDestination(paths: [String]?) {
    guard let session = model.session, let window = previewWindow() else { return }
    let sessionID = session.id
    let panel = NSOpenPanel()
    self.panel = panel
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = L10n.tr("Извлечь")
    panel.message = L10n.tr("Выберите папку распаковки")
    panel.directoryURL = session.url.deletingLastPathComponent()
    panel.beginSheetModal(for: window) { response in
      self.panel = nil
      guard response == .OK, model.session?.id == sessionID, let directory = panel.url else {
        return
      }
      operation = Task { @MainActor in
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        extracted = []
        model.message = L10n.tr(
          "Извлекаем: %1$@",
          paths.map { ArchivePreviewModel.topLevelPaths($0).joined(separator: ", ") }
            ?? session.url.lastPathComponent)
        do {
          let results =
            if let paths {
              try await model.extract(to: directory, paths: paths)
            } else {
              try await model.extract(to: directory)
            }
          extracted = results
          model.message = L10n.tr(
            "Извлечено: %1$@", results.map(\.lastPathComponent).joined(separator: ", "))
        } catch {
          if case ArchiveError.passwordRequired = error { passwordRequested = true }
          model.message = error.localizedDescription
        }
      }
    }
  }
}
