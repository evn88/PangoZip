import AppKit
import PangoZipCore
import ServiceManagement
import SwiftUI

/// Остров перетаскивания: ярлычок, раскрытая площадка и строка с ходом операции.
/// Во всех положениях это одно и то же системное стекло Liquid Glass; от места зависит только
/// привязка.
struct DropIslandView: View {
  @ObservedObject var model: DropIslandModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var glintTrigger = 0

  /// Поля окна вокруг острова: в них должны целиком угасать тень и золотое свечение,
  /// иначе край окна обрезает их прямоугольником.
  static let margin: CGFloat = 64

  private static let ink = Color.white.opacity(0.96)
  private static let secondary = Color.white.opacity(0.76)
  var body: some View {
    ZStack(alignment: alignment) {
      Color.clear
      if model.phase != .hidden {
        island.padding(Self.margin).transition(transition)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(
      reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.72),
      value: model.phase
    )
    .environment(\.colorScheme, .dark)
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

  private var island: some View {
    let size = model.size
    let isHot = model.phase == .hot
    let shape = RoundedRectangle(cornerRadius: min(size.height / 2, 30), style: .continuous)
    return ZStack {
      switch model.phase {
      case .hidden, .label: label.transition(.opacity)
      case .open, .hot: zone.transition(.opacity)
      case .working, .done, .failed: status.transition(.opacity)
      }
    }
    .foregroundStyle(Self.ink)
    .frame(width: size.width, height: size.height)
    .background { glass(size) }
    .clipShape(shape)
    .glassEffect(.regular, in: shape)
    .overlay {
      if isHot { shape.strokeBorder(Brand.gold, lineWidth: 1.5) }
    }
    .contentShape(shape)
    .gesture(swipeGesture, including: model.canSwipe ? .all : .subviews)
    .shadow(
      color: isHot ? Brand.gold.opacity(0.3) : .black.opacity(0.3), radius: isHot ? 16 : 12, y: 6
    )
    .scaleEffect(isHot && !reduceMotion ? 1.035 : 1)
    .offset(x: model.swipeDirection.dx * model.swipe, y: model.swipeDirection.dy * model.swipe)
    .opacity(1 - min(0.5, max(0, model.swipe) / 160))
    .onChange(of: model.phase) { old, new in
      guard !reduceMotion else { return }
      if new == .done || (new == .open && old == .label) { glintTrigger += 1 }
    }
  }

  /// Перетаскивание острова к краю экрана убирает операцию в строку меню.
  private var swipeGesture: some Gesture {
    DragGesture(minimumDistance: 4)
      .onChanged { value in model.moveSwipe(toward(value.translation)) }
      .onEnded { value in model.endSwipe(predicted: toward(value.predictedEndTranslation)) }
  }

  private func toward(_ translation: CGSize) -> CGFloat {
    let direction = model.swipeDirection
    return direction.dx * translation.width + direction.dy * translation.height
  }

  /// Поверх системного стекла: золотое свечение хода операции и блик.
  private func glass(_ size: CGSize) -> some View {
    ZStack {
      progressGlow(size)
      glint(size)
    }
    .accessibilityHidden(true)
  }

  /// Золотое свечение под стеклом растёт слева направо вместе с ходом операции.
  @ViewBuilder
  private func progressGlow(_ size: CGSize) -> some View {
    if model.phase == .working || model.phase == .done {
      let isDone = model.phase == .done
      let fraction = isDone ? 1 : max(0, min(1, model.fraction ?? 0))
      // Градиент растянут на весь остров, а ход операции открывает его маской с мягким краем:
      // на малых процентах не остаётся жёсткой полоски.
      LinearGradient(
        colors: [Brand.gold.opacity(0.05), Brand.gold.opacity(0.4)], startPoint: .leading,
        endPoint: .trailing
      )
      .mask {
        LinearGradient(
          stops: [
            .init(color: .white, location: 0),
            .init(color: .white, location: max(0, fraction - 0.12)),
            .init(color: .clear, location: fraction),
          ], startPoint: .leading, endPoint: .trailing)
      }
      .blendMode(.plusLighter)
      .opacity(isDone ? 0.5 : 1)
      .animation(.easeOut(duration: 0.25), value: fraction)
      .transition(.opacity)
    }
  }

  /// Блик проходит по стеклу один раз: при раскрытии площадки и при завершении операции.
  private func glint(_ size: CGSize) -> some View {
    LinearGradient(
      colors: [.clear, .white.opacity(0.34), .clear], startPoint: .leading, endPoint: .trailing
    )
    .frame(width: 60, height: size.height * 1.6).rotationEffect(.degrees(20))
    .keyframeAnimator(initialValue: CGFloat(-1), trigger: glintTrigger) { content, value in
      content.offset(x: value * (size.width / 2 + 80))
    } keyframes: { _ in
      KeyframeTrack { CubicKeyframe(1, duration: 0.9) }
    }
  }

  /// Зверёк без фона; вне собранного приложения ресурс недоступен, тогда берётся значок.
  private static let pangolin =
    Bundle.main.image(forResource: "Pangolin") ?? NSApplication.shared.applicationIconImage

  /// Ярлычок с логотипом: по нему видно, чей это остров, ещё до раскрытия.
  private var label: some View {
    HStack(spacing: 6) {
      Image(nsImage: Self.pangolin ?? NSImage())
        .resizable().scaledToFit().frame(width: 24, height: 24).accessibilityHidden(true)
      Text(L10n.tr("В архив")).font(.system(size: 12.5, weight: .semibold))
    }
    .fixedSize()
  }

  private var zone: some View {
    let isHot = model.phase == .hot
    let shape = RoundedRectangle(cornerRadius: 21, style: .continuous)
    let open = DropIslandPlacement.openSize
    return VStack(spacing: 4) {
      Image(systemName: model.isExtraction ? "tray.and.arrow.up" : "tray.and.arrow.down")
        .font(.system(size: 26, weight: .medium)).foregroundStyle(Brand.gold)
        .scaleEffect(isHot ? 1.15 : 1).symbolEffect(.bounce, value: isHot)
        .accessibilityHidden(true)
      Text(model.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
      Text(model.subtitle).font(.system(size: 12)).foregroundStyle(Self.secondary)
        .lineLimit(1).truncationMode(.middle)
      if let hint = model.hint {
        Text(hint).font(.system(size: 11.5)).padding(.horizontal, 10).padding(.vertical, 3)
          .overlay { Capsule().strokeBorder(Self.secondary.opacity(0.5), lineWidth: 1) }
          .padding(.top, 5)
      }
    }
    .padding(.horizontal, 14)
    .frame(width: open.width - 20, height: open.height - 20)
    .background { shape.fill(Self.ink.opacity(isHot ? 0.14 : 0.05)) }
    .overlay {
      shape.strokeBorder(
        Brand.gold.opacity(isHot ? 1 : 0.9),
        style: StrokeStyle(lineWidth: 1.5, dash: isHot ? [] : [6, 5]))
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHot)
  }

  private var status: some View {
    HStack(spacing: 12) {
      switch model.phase {
      case .done:
        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
          .foregroundStyle(Brand.onGold).frame(width: 30, height: 30)
          .background(Brand.gold, in: Circle()).accessibilityHidden(true)
          .transition(.scale(scale: 0.2).combined(with: .opacity))
      case .failed:
        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 20))
          .foregroundStyle(Brand.gold).frame(width: 30, height: 30).accessibilityHidden(true)
      default: ring
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(model.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
          .truncationMode(.middle)
        Text(model.subtitle).font(.system(size: 12)).foregroundStyle(Self.secondary)
          .lineLimit(model.phase == .failed ? 2 : 1).help(model.subtitle)
      }
      Spacer(minLength: 4)
      switch model.phase {
      case .done where !model.canReveal: EmptyView()
      case .done:
        Button(L10n.tr("Показать в Finder"), action: model.reveal)
          .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Brand.onGold).padding(.horizontal, 11).frame(height: 28)
          .background(Brand.gold, in: Capsule())
      case .failed: roundButton(L10n.tr("Закрыть"), action: model.dismiss)
      default:
        HStack(spacing: 6) {
          if let togglePause = model.togglePause {
            roundButton(
              model.isPaused ? L10n.tr("Возобновить") : L10n.tr("Пауза"),
              symbol: model.isPaused ? "play.fill" : "pause.fill", action: togglePause)
          }
          roundButton(L10n.tr("Отмена"), action: model.cancel)
        }
      }
    }
    .padding(.horizontal, 14)
    .help(model.canSwipe ? L10n.tr("Смахните, чтобы убрать в строку меню") : "")
    .accessibilityActions {
      if model.canSwipe, let minimize = model.minimize {
        Button(L10n.tr("Убрать в строку меню"), action: minimize)
      }
    }
    .frame(width: DropIslandPlacement.pillSize.width, height: DropIslandPlacement.pillSize.height)
  }

  /// Единственное кольцо острова показывает ход операции, как и в окне архива.
  @ViewBuilder private var ring: some View {
    if let fraction = model.fraction {
      ZStack {
        Circle().stroke(Self.secondary.opacity(0.35), lineWidth: 4)
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

  private func roundButton(
    _ title: String, symbol: String = "xmark", action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 10, weight: .bold))
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
  @AppStorage(DropIslandSettings.progressModeKey) private var progressMode =
    DropIslandProgressMode.keep.rawValue
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
        Picker(L10n.tr("Ход операции"), selection: $progressMode) {
          ForEach(DropIslandProgressMode.allCases) { item in Text(item.title).tag(item.rawValue) }
        }
        Text(
          L10n.tr(
            "Остров с идущей операцией можно в любой момент смахнуть вверх в строку меню. Нажмите значок в строке меню, чтобы поставить операцию на паузу, отменить её или вернуть остров."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
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
