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
  /// `userAction` is true only when the user asked for it (the "Permitir…" button, adjusting
  /// an app): then it may listen to an idle process to show the prompt.
  func request(userAction: Bool) async -> AudioPermissionStatus
  /// Opens System Settings at the audio capture privacy pane.
  func openPrivacySettings()
}

extension PermissionService {
  /// An automatic check, not asked for by the user.
  public func request() async -> AudioPermissionStatus {
    await request(userAction: false)
  }
}
