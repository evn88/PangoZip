import AppKit
import PangoZipCore
import SwiftUI

/// Состояние листа контрольных сумм: файл архива и выбранные элементы.
@MainActor
final class ChecksumsModel: ObservableObject, Identifiable {
  struct Row: Identifiable {
    let record: ChecksumRecord
    let isArchive: Bool
    var id: String { (isArchive ? "archive:" : "entry:") + record.id }
  }

  nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

  @Published private(set) var rows: [Row] = []
  @Published private(set) var isRunning = false
  @Published private(set) var fraction: Double?
  @Published private(set) var currentFile: String?
  @Published private(set) var errorMessage: String?
  @Published var comparison = ""

  private let service: ArchiveService
  private let session: ArchiveSession
  private let paths: [String]
  private let password: String
  private var task: Task<Void, Never>?
  private var feedbackID: UUID?

  init(service: ArchiveService, session: ArchiveSession, paths: [String], password: String) {
    self.service = service
    self.session = session
    self.paths = paths
    self.password = password
  }

  /// Результат сравнения введённого значения со всеми вычисленными суммами.
  var comparisonResult: ChecksumComparison.Result {
    let result = ChecksumComparison.result(
      for: comparison, candidates: rows.flatMap { [$0.record.crc32, $0.record.sha256] })
    // Пока суммы ещё считаются, отсутствие совпадения не означает расхождения.
    return isRunning && result == .mismatch ? .empty : result
  }

  /// Считает сначала файл архива, затем выбранные элементы; повторный запуск игнорируется.
  func start() {
    guard task == nil else { return }
    isRunning = true
    errorMessage = nil
    let hasEntries = !paths.isEmpty
    let feedback = OperationFeedback.shared
    let id = feedback.begin(kind: .checksums, subject: session.url.lastPathComponent)
    feedbackID = id
    let share = hasEntries ? 0.5 : 1.0
    let archiveProgress: @Sendable (UInt64, UInt64) async -> Void = {
      [weak self] processed, total in
      let part = total == 0 ? 1 : Double(processed) / Double(total)
      await self?.receive(fraction: part * share, file: nil)
    }
    let entryProgress: ArchiveProgressHandler = { [weak self] value in
      await self?.receive(fraction: 0.5 + 0.5 * (value.fraction ?? 0), file: value.currentFile)
    }
    task = Task { [weak self, session, paths, password, service] in
      var outcome = OperationOutcome.success
      var failure: String?
      var archive: ChecksumRecord?
      var records: [ChecksumRecord] = []
      do {
        archive = try await ArchiveChecksums.compute(
          fileAt: session.url, id: session.url.path, name: session.url.lastPathComponent,
          progress: archiveProgress)
        if hasEntries {
          records = try await service.checksums(
            of: paths, in: session, password: password, progress: entryProgress)
        }
      } catch is CancellationError {
        outcome = .cancelled
      } catch {
        failure = error.localizedDescription
        outcome = .failure(error.localizedDescription)
        if case ArchiveError.passwordRequired = error { outcome = .cancelled }
      }
      self?.finish(outcome, archive: archive, entries: records, failure: failure)
    }
  }

  func cancel() { task?.cancel() }

  private func receive(fraction: Double, file: String?) {
    self.fraction = fraction
    currentFile = file
    if let feedbackID { OperationFeedback.shared.update(feedbackID, fraction: fraction) }
  }

  private func finish(
    _ outcome: OperationOutcome, archive: ChecksumRecord?, entries: [ChecksumRecord],
    failure: String?
  ) {
    if let archive { rows.append(Row(record: archive, isArchive: true)) }
    rows.append(contentsOf: entries.map { Row(record: $0, isArchive: false) })
    errorMessage = failure
    isRunning = false
    fraction = nil
    currentFile = nil
    task = nil
    if let id = feedbackID {
      feedbackID = nil
      OperationFeedback.shared.finish(id, outcome: outcome)
    }
  }
}

struct ChecksumsView: View {
  @ObservedObject var model: ChecksumsModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(L10n.tr("Контрольные суммы"), systemImage: "number")
        .font(.title3.weight(.semibold))
      table
      if model.isRunning {
        VStack(alignment: .leading, spacing: 4) {
          if let fraction = model.fraction {
            ProgressView(value: fraction, total: 1).progressViewStyle(.linear)
          } else {
            ProgressView().progressViewStyle(.linear)
          }
          Text(model.currentFile ?? L10n.tr("Вычисляем контрольные суммы…"))
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
        }
      }
      if let message = model.errorMessage {
        Label(message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange).textSelection(.enabled)
      }
      comparisonField
      HStack {
        Spacer()
        Button(model.isRunning ? L10n.tr("Отмена") : L10n.tr("Закрыть")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(22).frame(width: 920, height: 470)
    .onDisappear { model.cancel() }
  }

  private var table: some View {
    Table(model.rows) {
      TableColumn(L10n.tr("Имя")) { row in
        VStack(alignment: .leading, spacing: 2) {
          Text(row.record.name).lineLimit(1).truncationMode(.middle).help(row.record.name)
          if row.isArchive {
            Text(L10n.tr("Файл архива")).font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
      .width(min: 140, ideal: 220)
      TableColumn("CRC32") { row in valueCell(row.record.crc32) }
        .width(min: 120, ideal: 130, max: 150)
      TableColumn("SHA-256") { row in valueCell(row.record.sha256) }
        .width(min: 460, ideal: 500)
    }
  }

  /// Значение выделяется для копирования вручную и зелёным цветом при совпадении с полем сравнения.
  private func valueCell(_ value: String) -> some View {
    let isMatch = ChecksumComparison.matches(model.comparison, value)
    return HStack(spacing: 6) {
      Text(value)
        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(
          isMatch ? Color.green.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 4))
      Button(L10n.tr("Копировать"), systemImage: "doc.on.doc") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
      }
      .labelStyle(.iconOnly).buttonStyle(.borderless).help(L10n.tr("Копировать"))
    }
  }

  private var comparisonField: some View {
    let result = model.comparisonResult
    return HStack(spacing: 10) {
      Text(L10n.tr("Сравнить с:"))
      TextField(L10n.tr("Вставьте CRC32 или SHA-256"), text: $model.comparison)
        .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
        .overlay(
          RoundedRectangle(cornerRadius: 6).stroke(
            result == .match ? Color.green : result == .mismatch ? Color.red : .clear,
            lineWidth: 2)
        )
        .accessibilityLabel(L10n.tr("Сравнить с:"))
      switch result {
      case .empty: EmptyView()
      case .match:
        Label(L10n.tr("Совпадает"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      case .mismatch:
        Label(L10n.tr("Не совпадает"), systemImage: "xmark.circle.fill").foregroundStyle(.red)
      }
    }
  }
}
