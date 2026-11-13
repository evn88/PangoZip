import AppKit
import PangoZipCore
import ServiceManagement
import SwiftUI

/// Остров перетаскивания: ярлычок, раскрытая площадка и строка с ходом операции.
struct DropIslandView: View {
  @ObservedObject var model: DropIslandModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Поля окна вокруг острова — место для тени и пружинящей анимации.
  static let margin: CGFloat = 28

  /// Цвета острова: тёмно-синее стекло бренда либо светлое стекло у края экрана.
  private struct Style {
    let tint: Color
    let ink: Color
    let secondary: Color
    let accent: Color
    let border: Color
    let scheme: ColorScheme

    init(_ placement: DropIslandPlacement) {
      let gold = Color(nsColor: NSColor(srgbHex: 0xE3A74C))
      switch placement {
      case .edge:
        tint = Color.white.opacity(0.66)
        ink = Color(nsColor: NSColor(srgbHex: 0x16181D))
        secondary = Color(nsColor: NSColor(srgbHex: 0x454A55))
        accent = Color(nsColor: NSColor(srgbHex: 0x8A5410))
        border = Color.white.opacity(0.9)
        scheme = .light
      case .top, .cursor:
        tint = Color(nsColor: NSColor(srgbHex: 0x101F4A)).opacity(0.84)
        ink = Color.white.opacity(0.96)
        secondary = Color.white.opacity(0.74)
        accent = gold
        border = placement == .cursor ? gold.opacity(0.6) : Color.white.opacity(0.18)
        scheme = .dark
      }
    }
  }

  var body: some View {
    let style = Style(model.placement)
    ZStack(alignment: alignment) {
      Color.clear
      if model.phase != .hidden {
        island(style).padding(Self.margin).transition(transition)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(
      reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.72),
      value: model.phase
    )
    .environment(\.colorScheme, style.scheme)
  }

  /// Остров растёт от своей точки привязки, поэтому смена размера окна его не сдвигает.
  private var alignment: Alignment {
    switch model.placement {
    case .top: .top
    case .edge: .trailing
    case .cursor: .center
    }
  }

  private var transition: AnyTransition {
    switch model.placement {
    case .top: .move(edge: .top).combined(with: .opacity)
    case .edge: .move(edge: .trailing).combined(with: .opacity)
    case .cursor: .scale(scale: 0.3).combined(with: .opacity)
    }
  }

  private func island(_ style: Style) -> some View {
    let size = model.size
    let shape = RoundedRectangle(cornerRadius: min(size.height / 2, 30), style: .continuous)
    return ZStack {
      switch model.phase {
      case .hidden, .label: label.transition(.opacity)
      case .open, .hot: zone(style).transition(.opacity)
      case .working, .done, .failed: status(style).transition(.opacity)
      }
    }
    .foregroundStyle(style.ink)
    .frame(width: size.width, height: size.height)
    .background {
      ZStack {
        shape.fill(.ultraThinMaterial)
        shape.fill(style.tint)
        shape.strokeBorder(style.border, lineWidth: 1)
      }
    }
    .clipShape(shape)
    .contentShape(shape)
    .shadow(color: .black.opacity(0.32), radius: 14, y: 8)
  }

  /// Зверёк без фона; вне собранного приложения ресурс недоступен, тогда берётся значок.
  private static let pangolin =
    Bundle.main.image(forResource: "Pangolin") ?? NSApplication.shared.applicationIconImage

  private func logo(_ side: CGFloat) -> some View {
    Image(nsImage: Self.pangolin ?? NSImage())
      .resizable().scaledToFit().frame(width: side, height: side).accessibilityHidden(true)
  }

  /// Ярлычок с логотипом: по нему видно, чей это остров, ещё до раскрытия.
  @ViewBuilder private var label: some View {
    let caption = Text(L10n.tr("В архив")).font(.system(size: 12.5, weight: .semibold))
    switch model.placement {
    case .top:
      HStack(spacing: 6) {
        logo(24)
        caption
      }
      .fixedSize()
    case .edge:
      VStack(spacing: 6) {
        logo(28)
        caption.fixedSize().rotationEffect(.degrees(90)).frame(width: 20, height: 62)
      }
      .fixedSize()
    case .cursor:
      logo(40)
    }
  }

  private func zone(_ style: Style) -> some View {
    let isHot = model.phase == .hot
    let shape = RoundedRectangle(cornerRadius: 21, style: .continuous)
    let open = model.placement.openSize
    return VStack(spacing: 4) {
      Image(systemName: model.isExtraction ? "tray.and.arrow.up" : "tray.and.arrow.down")
        .font(.system(size: 26, weight: .medium)).foregroundStyle(style.accent)
        .accessibilityHidden(true)
      Text(model.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
      Text(model.subtitle).font(.system(size: 12)).foregroundStyle(style.secondary)
        .lineLimit(1).truncationMode(.middle)
      if let hint = model.hint {
        Text(hint).font(.system(size: 11.5)).padding(.horizontal, 10).padding(.vertical, 3)
          .overlay { Capsule().strokeBorder(style.secondary.opacity(0.5), lineWidth: 1) }
          .padding(.top, 5)
      }
    }
    .padding(.horizontal, 14)
    .frame(width: open.width - 20, height: open.height - 20)
    .background { shape.fill(style.ink.opacity(isHot ? 0.12 : 0.04)) }
    .overlay {
      shape.strokeBorder(
        style.accent, style: StrokeStyle(lineWidth: 1.5, dash: isHot ? [] : [6, 5]))
    }
    .animation(.easeOut(duration: 0.15), value: isHot)
  }

  private func status(_ style: Style) -> some View {
    HStack(spacing: 12) {
      switch model.phase {
      case .done:
        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
          .foregroundStyle(Brand.onGold).frame(width: 30, height: 30)
          .background(Brand.gold, in: Circle()).accessibilityHidden(true)
      case .failed:
        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 20))
          .foregroundStyle(style.accent).frame(width: 30, height: 30).accessibilityHidden(true)
      default: ring(style)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(model.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
          .truncationMode(.middle)
        Text(model.subtitle).font(.system(size: 12)).foregroundStyle(style.secondary)
          .lineLimit(model.phase == .failed ? 2 : 1).help(model.subtitle)
      }
      Spacer(minLength: 4)
      switch model.phase {
      case .done:
        Button(L10n.tr("Показать в Finder"), action: model.reveal)
          .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Brand.onGold).padding(.horizontal, 11).frame(height: 28)
          .background(Brand.gold, in: Capsule())
      case .failed: roundButton(L10n.tr("Закрыть"), action: model.dismiss)
      default: roundButton(L10n.tr("Отмена"), action: model.cancel)
      }
    }
    .padding(.horizontal, 14)
    .frame(width: DropIslandPlacement.pillSize.width, height: DropIslandPlacement.pillSize.height)
  }

  /// Единственное кольцо острова показывает ход операции, как и в окне архива.
  @ViewBuilder
  private func ring(_ style: Style) -> some View {
    if let fraction = model.fraction {
      ZStack {
        Circle().stroke(style.secondary.opacity(0.35), lineWidth: 4)
        Circle().trim(from: 0, to: max(0.02, min(1, fraction)))
          .stroke(Brand.gold, style: StrokeStyle(lineWidth: 4, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(.easeOut(duration: 0.2), value: fraction)
      }
      .frame(width: 28, height: 28).padding(1).accessibilityHidden(true)
    } else {
      ProgressView().controlSize(.small).frame(width: 30, height: 30)
    }
  }

  private func roundButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
        .frame(width: 26, height: 26).background(.gray.opacity(0.3), in: Circle())
    }
    .buttonStyle(.plain).accessibilityLabel(title).help(title)
  }
}

/// Настройки острова: включение, положение, место сохранения и запуск при входе в систему.
struct DropIslandSettingsView: View {
  @AppStorage(DropIslandSettings.enabledKey) private var isEnabled = true
  @AppStorage(DropIslandSettings.placementKey) private var placement = DropIslandPlacement.top
    .rawValue
  @AppStorage(DropIslandSettings.usesDefaultFolderKey) private var usesDefaultFolder = false
  @AppStorage(DropIslandSettings.defaultFolderKey) private var defaultFolder = ""
  @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
  @State private var loginError: String?

  var body: some View {
    Form {
      Section(L10n.tr("Остров перетаскивания")) {
        Toggle(
          L10n.tr("Показывать остров при перетаскивании файлов из Finder"), isOn: $isEnabled
        )
        .onChange(of: isEnabled) { _, _ in DropIslandController.shared.applySettings() }
        Picker(L10n.tr("Положение острова"), selection: $placement) {
          ForEach(DropIslandPlacement.allCases) { item in Text(item.title).tag(item.rawValue) }
        }
        .pickerStyle(.segmented).disabled(!isEnabled)
        Toggle(L10n.tr("Запускать PangoZip при входе в систему"), isOn: $launchesAtLogin)
          .onChange(of: launchesAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
        if let loginError {
          Text(loginError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        Text(
          L10n.tr(
            "Пока остров включён, PangoZip продолжает работать после закрытия окон: значок остаётся в строке меню."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section(L10n.tr("Куда сохранять архив")) {
        Picker(L10n.tr("Куда сохранять архив"), selection: $usesDefaultFolder) {
          Text(L10n.tr("Рядом с исходными файлами")).tag(false)
          Text(L10n.tr("В папку по умолчанию")).tag(true)
        }
        .pickerStyle(.radioGroup).labelsHidden()
        if usesDefaultFolder {
          HStack {
            Text(
              defaultFolder.isEmpty
                ? L10n.tr("Папка не выбрана")
                : (defaultFolder as NSString).abbreviatingWithTildeInPath
            )
            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(L10n.tr("Выбрать папку…"), action: chooseFolder)
          }
        }
        Text(
          L10n.tr(
            "Если файлы взяты из разных папок, PangoZip спросит, куда сохранить. Удерживайте ⌥ при броске, чтобы выбрать место вручную. Архив, брошенный на остров, распаковывается рядом с собой; с ⌥ — сжимается заново."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func chooseFolder() {
    let chooser = NSOpenPanel()
    chooser.canChooseDirectories = true
    chooser.canChooseFiles = false
    chooser.canCreateDirectories = true
    if chooser.runModal() == .OK, let url = chooser.url { defaultFolder = url.path }
  }

  /// Регистрирует приложение как объект входа; при отказе системы возвращает переключатель.
  private func setLaunchAtLogin(_ enabled: Bool) {
    guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      loginError = nil
    } catch {
      loginError = error.localizedDescription
      launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
  }
}
