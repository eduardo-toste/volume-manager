import Observation

/// State of the welcome window (SPEC 3.4).
@MainActor
@Observable
public final class WelcomeModel {
  /// What the "Acesso ao áudio do sistema" row shows.
  public enum Access: Sendable, Hashable {
    /// Not asked yet: the "Permitir…" button.
    case notAsked
    /// Granted: "Permitido".
    case allowed
    /// The check could not conclude (nothing was playing): the user may try again.
    case inconclusive
    /// Denied: the button now opens System Settings.
    case denied
  }

  /// The "Abrir ao iniciar sessão" toggle. Starts on; the login item is registered only by
  /// `start()`.
  public var launchAtLogin = true
  /// The state of the permission row.
  public private(set) var access: Access
  /// True while the permission check runs.
  public private(set) var isAsking = false

  @ObservationIgnored private let settings: SettingsModel
  @ObservationIgnored private let loginItem: LoginItemModel
  @ObservationIgnored private let store: MixerStore
  @ObservationIgnored private let permission: PermissionMonitor

  /// Creates the model. The row starts as "Permitido" only when this session already
  /// verified the permission.
  public init(
    settings: SettingsModel, loginItem: LoginItemModel, store: MixerStore,
    permission: PermissionMonitor
  ) {
    self.settings = settings
    self.loginItem = loginItem
    self.store = store
    self.permission = permission
    access = permission.status == .granted ? .allowed : .notAsked
  }

  /// "Permitir…": checks the permission through the same path as the first tap, which shows
  /// the system prompt when the user has not decided yet. When it was denied, opens System
  /// Settings instead (the same as the popover's "Permitir…": checked again when something plays).
  public func allow() async {
    if access == .denied {
      store.allowAccess()
      return
    }
    guard !isAsking else { return }
    isAsking = true
    defer { isAsking = false }
    switch await store.requestAccess() {
    case .granted: access = .allowed
    case .denied: access = .denied
    case .notDetermined: access = .inconclusive
    case nil:
      // Another check was already running: show what it concluded, if it did.
      refreshAccess()
      if access != .allowed, access != .denied { access = .inconclusive }
    }
  }

  /// Shows the permission as the monitor knows it now, without checking anything. Called when
  /// the window or the app becomes active again: a permission granted in System Settings, or
  /// found by another check, leaves the "denied" state.
  public func refreshAccess() {
    switch permission.status {
    case .granted: access = .allowed
    case .denied: break
    case .notDetermined: if access == .denied { access = .notAsked }
    }
  }

  /// "Começar": registers the login item only when the toggle is on, and marks the first run as
  /// done so the window never comes back. Closing the window any other way changes nothing.
  public func start() {
    loginItem.setEnabled(launchAtLogin)
    settings.onboardingCompleted = true
    settings.flush()
  }
}
