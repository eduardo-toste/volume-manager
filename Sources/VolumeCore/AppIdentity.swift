/// Fixed identity constants shared by every module.
public enum AppIdentity {
  /// Bundle identifier of the app (SPEC section 2).
  public static let bundleIdentifier = "com.volumemanager.app"

  /// Subsystem used by every `os.Logger` in the project (SPEC 12.3).
  public static let logSubsystem = bundleIdentifier

  /// Name shown to the user.
  public static let displayName = "Volume Manager"
}
