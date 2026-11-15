import AppKit
import PangoZipCore
import SwiftUI

private struct AboutWindowDismissKey: FocusedValueKey {
  typealias Value = DismissAction
}

extension FocusedValues {
  var dismissAboutWindow: DismissAction? {
    get { self[AboutWindowDismissKey.self] }
    set { self[AboutWindowDismissKey.self] = newValue }
  }
}

struct AboutPangoZipView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

    VStack(spacing: 14) {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable().scaledToFit().frame(width: 80, height: 80)
        .accessibilityHidden(true)
      Text("PangoZip").font(.title).fontWeight(.semibold)
      Text(L10n.tr("Версия %1$@", "\(version) (\(build))"))
        .font(.callout).foregroundStyle(.secondary)
      Divider()
      Text(L10n.tr("Автор: %1$@", "Egor Vershkov"))
      Link("pangozip.app", destination: SupportConfiguration.websiteURL)
        .help(L10n.tr("Сайт PangoZip"))
      Link("github.com/evn88", destination: URL(string: "https://github.com/evn88")!)
      if let supportURL = SupportConfiguration.pageURL {
        Link(destination: supportURL) {
          Label("GitHub Sponsors", systemImage: "heart")
        }
        .buttonStyle(.borderedProminent)
        .help(L10n.tr("Открыть страницу поддержки в браузере"))
      }
      Divider()
      // Тихая заметка о тёзках приложения: без кнопки и без призыва к пожертвованию.
      VStack(spacing: 6) {
        Text(
          L10n.tr(
            "PangoZip назван в честь панголинов. Все восемь их видов находятся под угрозой исчезновения."
          )
        )
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.secondary)
        Link(destination: SupportConfiguration.pangolinFundURL) {
          Text(L10n.tr("Как им помочь: Pangolin Crisis Fund"))
        }
        .help(L10n.tr("Независимый фонд Wildlife Conservation Network. Откроется в браузере."))
      }
      .font(.caption)
    }
    .padding(28)
    .frame(width: 340)
    .focusedSceneValue(\.dismissAboutWindow, dismiss)
  }
}
