/// State of the system audio capture permission.
public enum AudioPermissionStatus: Sendable, Hashable {
  /// The user has not decided yet.
  case notDetermined
  /// Allowed.
  case granted
  /// Denied.
  case denied
}

/// Asks for and checks the system audio permission (SPEC 5).
public protocol PermissionService: Sendable {
  /// Triggers the system prompt (when it has not been decided) and returns the result of this
  /// check: `.notDetermined` when it could not conclude (nothing was playing).
  func request() async -> AudioPermissionStatus
  /// Opens System Settings at the audio capture privacy pane.
  func openPrivacySettings()
}
