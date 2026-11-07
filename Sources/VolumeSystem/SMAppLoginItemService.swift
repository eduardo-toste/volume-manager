import Foundation
import ServiceManagement
import VolumeCore
import os

/// Status of the main-app login item as the system reports it, before mapping to the domain.
enum AppServiceState: Sendable, Hashable {
  case enabled
  case notRegistered
  case requiresApproval
  case notFound
}

/// The small slice of `SMAppService` the service needs, so tests can use a fake.
protocol AppServiceControlling: Sendable {
  func state() -> AppServiceState
  func register() throws
  func unregister() throws
  func openSettings()
}

/// The real `SMAppService.mainApp`. Registers nothing by itself: only explicit calls do.
struct MainAppServiceController: AppServiceControlling {
  func state() -> AppServiceState {
    switch SMAppService.mainApp.status {
    case .enabled: return .enabled
    case .notRegistered: return .notRegistered
    case .requiresApproval: return .requiresApproval
    case .notFound: return .notFound
    @unknown default: return .notFound
    }
  }

  func register() throws { try SMAppService.mainApp.register() }

  func unregister() throws { try SMAppService.mainApp.unregister() }

  func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Why changing the login item failed.
public enum LoginItemError: Error, Sendable, Hashable {
  /// The system refused to register the app (code is the `NSError` code, for diagnostics).
  case registrationFailed(code: Int)
  /// The system refused to unregister the app.
  case unregistrationFailed(code: Int)
}

/// `LoginItemService` over `SMAppService.mainApp` (SPEC 3.3, 3.4).
public struct SMAppLoginItemService: LoginItemService {
  private let controller: any AppServiceControlling

  /// Creates the service for the running app. Nothing is registered until `setEnabled(true)`.
  public init() {
    self.init(controller: MainAppServiceController())
  }

  init(controller: any AppServiceControlling) {
    self.controller = controller
  }

  /// The real state, as the system reports it.
  public func status() -> LoginItemStatus {
    Self.map(controller.state())
  }

  /// Registers or unregisters the login item. Does nothing when it is already in that state.
  public func setEnabled(_ enabled: Bool) throws {
    let state = controller.state()
    if enabled {
      guard state != .enabled, state != .requiresApproval else { return }
      do { try controller.register() } catch {
        throw LoginItemError.registrationFailed(code: (error as NSError).code)
      }
    } else {
      guard state == .enabled || state == .requiresApproval else { return }
      do { try controller.unregister() } catch {
        throw LoginItemError.unregistrationFailed(code: (error as NSError).code)
      }
    }
  }

  /// Opens System Settings at the login items list.
  public func openLoginItemsSettings() {
    controller.openSettings()
  }

  static func map(_ state: AppServiceState) -> LoginItemStatus {
    switch state {
    case .enabled: return .enabled
    case .notRegistered: return .disabled
    case .requiresApproval: return .requiresApproval
    case .notFound: return .notFound
    }
  }
}
