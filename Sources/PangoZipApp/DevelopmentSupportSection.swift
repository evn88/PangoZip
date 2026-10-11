import AppKit
import SwiftUI

enum SupportConfiguration {
  static var pageURL: URL? {
    pageURL(infoDictionary: Bundle.main.infoDictionary)
  }

  /// Скрывает поддержку без настроенной HTTPS-страницы и отклоняет адреса с учётными данными.
  static func pageURL(infoDictionary: [String: Any]?) -> URL? {
    guard let value = infoDictionary?["PangoZipSupportURL"] as? String,
      let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
      components.scheme?.lowercased() == "https",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil
    else { return nil }
    return components.url
  }
}

struct DevelopmentSupportSection: View {
  let pageURL: URL
  @State private var showingOpenError = false

  var body: some View {
    Section("Поддержать PangoZip") {
      Text("Если PangoZip вам полезен, вы можете поддержать его разработку добровольным донатом.")
        .font(.callout)
      Button {
        showingOpenError = !NSWorkspace.shared.open(pageURL)
      } label: {
        Label("Поддержать разработку…", systemImage: "heart")
      }
      .help("Открыть страницу поддержки в браузере")
      Text("Страница поддержки откроется в браузере.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .alert("Не удалось открыть страницу поддержки", isPresented: $showingOpenError) {
      Button("ОК", role: .cancel) {}
    } message: {
      Text("Проверьте, что в macOS выбран браузер по умолчанию, и попробуйте ещё раз.")
    }
  }
}
