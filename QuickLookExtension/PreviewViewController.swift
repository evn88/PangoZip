import AppKit
import Quartz
import SwiftUI

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
  @State private var selection: String?
  @State private var panel: NSOpenPanel?
  @State private var operation: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 12) {
      if let session = model.session {
        HStack {
          Text(session.url.lastPathComponent).font(.headline).lineLimit(1)
          Spacer()
          Button(L10n.tr("Извлечь выбранное…")) { chooseDestination(path: selection) }
            .disabled(selection == nil || model.isBusy || panel != nil)
          Button(L10n.tr("Распаковать в «%1$@/»", FinderSelection.extractionName(for: session.url)))
          {
            chooseDestination(path: nil)
          }
          .disabled(model.isBusy || panel != nil)
        }
        Table(session.roots, children: \.children, selection: $selection) {
          TableColumn(L10n.tr("Имя")) { node in
            Label(node.name, systemImage: node.children == nil ? "doc" : "folder")
          }
          .width(min: 250)
          TableColumn(L10n.tr("Размер")) { node in
            if let entry = node.entry, !entry.isDirectory {
              Text(
                ByteCountFormatter.string(
                  fromByteCount: Int64(clamping: entry.size), countStyle: .file))
            }
          }
          .width(100)
          TableColumn(L10n.tr("Изменён")) { node in
            if let date = node.entry?.modifiedAt {
              Text(date, format: .dateTime.year().month().day().hour().minute())
            }
          }
          .width(160)
        }
      }
      HStack {
        if model.isBusy { ProgressView().controlSize(.small) }
        Text(model.message).font(.callout).textSelection(.enabled)
        Spacer()
        SecureField(L10n.tr("Пароль (необязательно)"), text: $model.password)
          .frame(width: 200)
          .disabled(model.isBusy || panel != nil)
          .onSubmit { reload() }
        if model.session == nil {
          Button(L10n.tr("Открыть архив")) { reload() }.disabled(model.isBusy || panel != nil)
        }
      }
    }
    .padding()
    .frame(minWidth: 650, minHeight: 350)
    .onChange(of: model.session?.id) {
      selection = nil
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

  private func reload() {
    operation = Task { @MainActor in
      do { try await reloadPreview() } catch { model.message = error.localizedDescription }
    }
  }

  private func chooseDestination(path: String?) {
    guard let sessionID = model.session?.id, let window = previewWindow() else { return }
    let panel = NSOpenPanel()
    self.panel = panel
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = L10n.tr("Извлечь")
    panel.message = L10n.tr("Выберите папку распаковки")
    panel.directoryURL = model.session?.url.deletingLastPathComponent()
    panel.beginSheetModal(for: window) { response in
      self.panel = nil
      guard response == .OK, model.session?.id == sessionID, let directory = panel.url else {
        return
      }
      operation = Task { @MainActor in
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        do {
          let results = try await model.extract(to: directory, path: path)
          model.message = results.map(\.path).joined(separator: "\n")
        } catch {
          model.message = error.localizedDescription
        }
      }
    }
  }
}
