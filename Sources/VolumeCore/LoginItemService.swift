/// State of the "open at login" registration.
public enum LoginItemStatus: Sendable, Hashable {
  /// Registered and approved.
  case enabled
  /// Not registered.
  case disabled
  /// Registered, but the user must approve it in System Settings.
  case requiresApproval
  /// The system cannot find the app to register.
  case notFound
}

/// Registers the app to open when the user logs in (`SMAppService` in production).
public protocol LoginItemService: Sendable {
  /// The real state, as the system reports it.
  func status() -> LoginItemStatus
  /// Registers or unregisters the login item.
  func setEnabled(_ enabled: Bool) throws
  /// Opens System Settings at the login items list.
  func openLoginItemsSettings()
}
