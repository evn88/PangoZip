import AppKit
import FinderSync
import PangoZipCore
import SwiftUI

@MainActor
final class FinderIntegrationModel: ObservableObject {
  enum State: Equatable {
    case idle, preparing, enabled, needsApproval, requiresInstallation
    case failed(String)
  }

  @Published private(set) var state: State = .idle
  private let register: @Sendable () async throws -> Void
  private let extensionEnabled: @MainActor () -> Bool

  /// Подменяемые операции позволяют проверять первый запуск без записи в системный реестр.
  init(
    register: @escaping @Sendable () async throws -> Void = {
      let plan = try FinderRegistrationPlan.make(applicationURL: Bundle.main.bundleURL)
      try await FinderRegistration.register(plan)
    },
    extensionEnabled: @escaping @MainActor () -> Bool = {
      FIFinderSyncController.isExtensionEnabled
    }
  ) {
    self.register = register
    self.extensionEnabled = extensionEnabled
  }

  /// Регистрирует вложенные компоненты только после запуска установленного приложения.
  func prepare() async {
    guard state != .preparing else { return }
    state = .preparing
    do {
      try await register()
      try Task.checkCancellation()
      state = extensionEnabled() ? .enabled : .needsApproval
    } catch is CancellationError {
      state = .idle
    } catch FinderRegistrationError.notInstalled {
      state = .requiresInstallation
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  /// Повторно читает согласие системы при возвращении из настроек, не меняя выбор пользователя.
  func refreshEnabledState() {
    guard state == .enabled || state == .needsApproval else { return }
    state = extensionEnabled() ? .enabled : .needsApproval
  }

  /// Открывает штатную панель включения расширения; приложение не включает его скрытой командой.
  func openExtensionSettings() { FIFinderSyncController.showExtensionManagementInterface() }

  /// Показывает папку установки, не копируя приложение с образа от имени пользователя.
  func showApplications() { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications")) }

  var statusText: String {
    switch state {
    case .idle: "Меню Finder ещё не подготовлено."
    case .preparing: "Подготавливаем меню Finder…"
    case .enabled: "Расширение PangoZip для Finder включено."
    case .needsApproval:
      "Включите PangoZip в расширениях Finder, чтобы использовать контекстное меню."
    case .requiresInstallation:
      "Перетащите PangoZip в Applications, извлеките образ и запустите установленное приложение."
    case .failed(let message): "Не удалось подготовить меню Finder: " + message
    }
  }
}

struct FinderIntegrationBanner: View {
  @ObservedObject var model: FinderIntegrationModel

  var body: some View {
    if model.state != .idle && model.state != .enabled {
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          if model.state == .preparing {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
          }
          Text(model.statusText).font(.callout).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          switch model.state {
          case .needsApproval:
            Button("Включить меню Finder…", action: model.openExtensionSettings)
          case .requiresInstallation:
            Button("Показать Applications", action: model.showApplications)
          case .failed:
            Button("Повторить") { Task { await model.prepare() } }
          default: EmptyView()
          }
        }
        .padding(12).background(.bar)
        Divider()
      }
    }
  }
}
