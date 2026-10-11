import PangoZipCore
import SwiftUI

struct OperationProgressView: View {
  let progress: ArchiveProgress?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let fraction = progress?.fraction {
        ProgressView(value: fraction, total: 1).progressViewStyle(.linear)
      } else {
        ProgressView().progressViewStyle(.linear)
      }
      HStack {
        Text(phaseTitle).lineLimit(1)
        Spacer()
        if let fraction = progress?.fraction {
          Text("\(Int((fraction * 100).rounded(.down)))%")
            .monospacedDigit()
        }
      }
      .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var phaseTitle: String {
    switch progress?.phase {
    case .preparing, nil: "Подготовка файлов…"
    case .compressing: "Сжатие…"
    case .verifying: "Проверка архива…"
    case .extracting: "Извлечение…"
    case .finalizing: "Завершение…"
    }
  }
}
