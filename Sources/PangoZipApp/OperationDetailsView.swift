import AppKit
import PangoZipCore
import SwiftUI

/// Окно со всеми подробностями операции из строки меню: объёмы, сжатие, скорость и время.
/// Открывается двойным нажатием на значок или кнопкой в карточке.
@MainActor
final class OperationDetailsWindow {
  private var window: NSWindow?
  private var hosting: NSHostingView<OperationDetailsView>?

  func show(_ card: ProgressCardModel) {
    let view = OperationDetailsView(model: card)
    if let window, let hosting {
      hosting.rootView = view
      window.makeKeyAndOrderFront(nil)
    } else {
      let hosting = NSHostingView(rootView: view)
      hosting.sizingOptions = [.preferredContentSize]
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      window.title = L10n.tr("Ход операции")
      window.titlebarAppearsTransparent = true
      window.isReleasedWhenClosed = false
      window.contentView = hosting
      window.center()
      self.window = window
      self.hosting = hosting
      window.makeKeyAndOrderFront(nil)
    }
    NSApp.activate()
  }
}

/// Подробности хода: те же величины, что в окне программы, но крупно и по строкам.
struct OperationDetailsView: View {
  @ObservedObject var model: ProgressCardModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      content(now: context.date)
    }
    .padding(20)
    .frame(width: 440)
  }

  private func content(now: Date) -> some View {
    let progress = model.progress
    return VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Image(nsImage: PangolinGlyph.image).renderingMode(.template).resizable()
          .frame(width: 26, height: 26).foregroundStyle(Brand.goldInk)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(model.title).font(.title3.weight(.semibold)).lineLimit(1)
            .truncationMode(.middle).textSelection(.enabled)
          Text(model.state == .done ? L10n.tr("Готово") : model.stage)
            .foregroundStyle(.secondary).monospacedDigit()
        }
      }
      if model.state == .working {
        GoldProgressBar(fraction: model.fraction, isPaused: model.isPaused)
      }
      let rows = OperationDetailRows.rows(progress, now: now, isPaused: model.isPaused)
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
        ForEach(rows, id: \.title) { row in
          GridRow {
            Text(row.title).foregroundStyle(.secondary)
            Text(row.value).monospacedDigit().textSelection(.enabled)
              .lineLimit(1).truncationMode(.middle)
          }
        }
      }
      if model.state == .working {
        HStack {
          Spacer()
          if let togglePause = model.togglePause {
            Button(
              model.isPaused ? L10n.tr("Возобновить") : L10n.tr("Пауза"),
              systemImage: model.isPaused ? "play.fill" : "pause.fill", action: togglePause)
          }
          Button(L10n.tr("Отмена"), systemImage: "xmark", action: model.cancel)
        }
        .buttonBorderShape(.capsule)
      }
    }
  }
}

/// Строки окна подробностей; неизвестные величины не показываются вовсе.
enum OperationDetailRows {
  struct Row {
    let title: String
    let value: String
  }

  static func rows(_ progress: ArchiveProgress?, now: Date, isPaused: Bool) -> [Row] {
    guard let progress else { return [] }
    var rows = [Row(title: L10n.tr("Этап"), value: ProgressFormatting.phaseTitle(progress.phase))]
    if let total = progress.totalBytes, total > 0 {
      rows.append(
        Row(
          title: L10n.tr("Обработано"),
          value: ProgressFormatting.processedBytes(
            progress.processedBytes, total: total, estimated: progress.bytesAreEstimated)))
    }
    if let output = progress.outputBytes, output > 0 {
      rows.append(Row(title: L10n.tr("Размер архива"), value: ProgressFormatting.bytes(output)))
      if let processed = progress.processedBytes, processed > 0 {
        let savings = max(0, 1 - Double(output) / Double(processed))
        rows.append(
          Row(
            title: L10n.tr("Сжатие"),
            value: savings.formatted(.percent.precision(.fractionLength(0...1)))))
      }
    }
    if let total = progress.totalFiles, total > 0 {
      rows.append(
        Row(
          title: L10n.tr("Файлы"),
          value: ProgressFormatting.files(completed: progress.completedFiles, total: total)))
    }
    if let speed = progress.bytesPerSecond, speed > 0, progress.phase != .finalizing {
      rows.append(Row(title: L10n.tr("Средняя скорость"), value: ProgressFormatting.speed(speed)))
    }
    // Между событиями прошедшее время идёт само; на паузе и на завершении оно стоит.
    let running = !isPaused && progress.phase != .finalizing
    let elapsed =
      progress.elapsedSeconds + (running ? max(0, now.timeIntervalSince(progress.updatedAt)) : 0)
    rows.append(Row(title: L10n.tr("Прошло"), value: ProgressFormatting.time(elapsed)))
    if progress.remainingSeconds != nil, progress.phase != .finalizing {
      rows.append(
        Row(
          title: L10n.tr("Осталось на этапе"),
          value: ProgressFormatting.eta(progress.remainingSeconds, phase: progress.phase)))
    }
    if let file = progress.currentFile, !file.isEmpty {
      rows.append(Row(title: L10n.tr("Текущий файл"), value: file))
    }
    return rows
  }
}
