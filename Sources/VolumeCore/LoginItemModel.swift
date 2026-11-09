import Observation

/// The "open at login" setting as the user sees it (SPEC 3.3): always the state the system
/// reports, read again whenever the window opens or the app comes back to the front, because
/// the user may change it in System Settings > Login Items.
@MainActor
@Observable
public final class LoginItemModel {
  /// The real state, as the system reports it.
  public private(set) var status: LoginItemStatus
  /// True when the last change was refused by the system.
  public private(set) var lastChangeFailed = false

  @ObservationIgnored private let service: any LoginItemService

  /// Reads the current state. Nothing is registered or unregistered.
  public init(service: any LoginItemService) {
    self.service = service
    status = service.status()
  }

  /// True when the toggle shows "on": registered, even if the user still has to approve it.
  public var isOn: Bool { status == .enabled || status == .requiresApproval }

  /// True when the system waits for the user to approve the item in System Settings.
  public var needsApproval: Bool { status == .requiresApproval }

  /// Reads the real state again.
  public func refresh() {
    status = service.status()
  }

  /// Registers or unregisters the login item, then shows what the system says.
  public func setEnabled(_ enabled: Bool) {
    do {
      try service.setEnabled(enabled)
      lastChangeFailed = false
    } catch {
      lastChangeFailed = true
    }
    refresh()
  }

  /// Opens System Settings at the login items list.
  public func openSettings() {
    service.openLoginItemsSettings()
  }
}
