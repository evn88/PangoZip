import PangoZipCore
import SwiftUI

struct OperationProgressView: View {
  let progress: ArchiveProgress?

  var body: some View {
    if let progress {
      TimelineView(.periodic(from: progress.updatedAt, by: 1)) { context in
        content(progress, date: context.date)
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        ProgressView().progressViewStyle(.linear)
        Text(L10n.tr("Подготовка файлов…"))
          .font(.caption).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    }
  }

  /// Обновляет прошедшее время между событиями, сохраняя последний полученный объём и оценку.
  private func content(_ value: ArchiveProgress, date: Date) -> some View {
    let finished = value.phase == .finalizing && value.fraction == 1
    let shownElapsed =
      value.elapsedSeconds
      + (finished ? 0 : max(0, date.timeIntervalSince(value.updatedAt)))
    let determinate = value.phase != .preparing
    return VStack(alignment: .leading, spacing: 9) {
      if determinate, let fraction = value.fraction {
        ProgressView(value: fraction, total: 1).progressViewStyle(.linear)
      } else {
        ProgressView().progressViewStyle(.linear)
      }

      HStack(spacing: 8) {
        Text(ProgressFormatting.phaseTitle(value.phase))
          .lineLimit(1)
        Spacer(minLength: 4)
        if let fraction = value.fraction, value.phase != .preparing {
          Text("\(Int((fraction * 100).rounded(.down)))%")
            .monospacedDigit()
        } else {
          Text("—").monospacedDigit()
        }
      }
      .font(.caption).foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)

      if value.phase != .preparing {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
          GridRow {
            metric(
              L10n.tr("Обработано"),
              ProgressFormatting.processedBytes(
                value.processedBytes, total: value.totalBytes, estimated: value.bytesAreEstimated))
            metric(L10n.tr("Средняя скорость"), ProgressFormatting.speed(value.bytesPerSecond))
          }
          GridRow {
            metric(
              L10n.tr("Файлы"),
              ProgressFormatting.files(
                completed: value.completedFiles, total: value.totalFiles))
            metric(L10n.tr("Прошло"), ProgressFormatting.time(shownElapsed))
          }
          GridRow {
            metric(L10n.tr("Размер архива"), ProgressFormatting.bytes(value.outputBytes))
            metric(
              L10n.tr("Осталось на этапе"),
              ProgressFormatting.eta(
                value.remainingSeconds, phase: value.phase))
          }
        }
        .font(.caption)
      } else {
        Text(L10n.tr("Прошло  %1$@", String(describing: ProgressFormatting.time(shownElapsed))))
          .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }

      if value.phase != .preparing, let file = value.currentFile, !file.isEmpty {
        Text(file)
          .font(.caption2).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
          .help(file)
          .accessibilityLabel(L10n.tr("Текущий файл: %1$@", String(describing: file)))
      }
    }
    .accessibilityElement(children: .contain)
  }

  /// Объединяет подпись и значение для чтения VoiceOver без потери выравнивания чисел.
  private func metric(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).foregroundStyle(.secondary)
      Text(value).foregroundStyle(.primary).monospacedDigit().lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

enum ProgressFormatting {
  /// Создаёт локализованное десятичное число с одной цифрой после запятой.
  private static func numberString(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale.current
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 1
    formatter.maximumFractionDigits = 1
    return formatter.string(from: NSNumber(value: value)) ?? "—"
  }

  /// Форматирует байты в десятичных единицах с одной цифрой после запятой.
  static func bytes(_ value: UInt64?) -> String {
    guard let value else { return "—" }
    return byteQuantity(Double(value))
  }

  /// Форматирует скорость в десятичных единицах без потери дробной части.
  private static func byteQuantity(_ value: Double) -> String {
    let units = [
      L10n.tr("Б"), L10n.tr("кБ"), L10n.tr("МБ"), L10n.tr("ГБ"), L10n.tr("ТБ"), L10n.tr("ПБ"),
    ]
    var amount = value
    var unit = 0
    while amount >= 1_000, unit < units.count - 1 {
      amount /= 1_000
      unit += 1
    }
    return "\(numberString(amount)) \(units[unit])"
  }

  /// Добавляет знак оценки только для оценочных счётчиков байтов.
  static func estimatedBytes(_ value: UInt64?, estimated: Bool) -> String {
    guard let value else { return "—" }
    return (estimated ? "≈ " : "") + bytes(value)
  }

  /// Форматирует обработанные байты и общий объём, сохраняя неизвестные значения.
  static func processedBytes(_ processed: UInt64?, total: UInt64?, estimated: Bool) -> String {
    guard let processed, let total else { return "—" }
    return L10n.tr(
      "%1$@ из %2$@", String(describing: estimatedBytes(processed, estimated: estimated)),
      String(describing: bytes(total)))
  }

  /// Форматирует скорость и не подменяет неизвестное значение нулём.
  static func speed(_ value: Double?) -> String {
    guard let value, value.isFinite, value > 0, value < Double(Int.max) else { return "—" }
    return L10n.tr("≈ %1$@/с", String(describing: byteQuantity(value)))
  }

  /// Форматирует целое время как часы, минуты и секунды; ноль остаётся явным значением.
  static func time(_ value: TimeInterval?) -> String {
    guard let value, value.isFinite, value >= 0, value < Double(Int.max) else { return "—" }
    let seconds = Int(value.rounded(.down))
    return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
  }

  /// Показывает ETA только при конечной известной оценке, кроме этапа завершения.
  static func eta(_ value: TimeInterval?, phase: ArchiveProgress.Phase) -> String {
    guard phase != .finalizing else { return "—" }
    guard let formatted = value.flatMap({ $0.isFinite && $0 >= 0 ? time($0) : nil }) else {
      return "—"
    }
    return "≈ \(formatted)"
  }

  /// Показывает счётчик завершённых файлов либо только известный общий объём.
  static func files(completed: Int?, total: Int?) -> String {
    guard let total, total >= 0 else { return completed.map { "\($0)/—" } ?? "—" }
    if let completed, completed >= 0 { return "\(completed)/\(total)" }
    return String(total)
  }

  /// Возвращает локализованное название текущего этапа.
  static func phaseTitle(_ phase: ArchiveProgress.Phase) -> String {
    switch phase {
    case .preparing: L10n.tr("Подготовка файлов…")
    case .compressing: L10n.tr("Сжатие…")
    case .verifying: L10n.tr("Проверка архива…")
    case .extracting: L10n.tr("Извлечение…")
    case .finalizing: L10n.tr("Завершение…")
    }
  }
}
