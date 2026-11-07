/// Looks up information about apps and processes (`NSWorkspace`, `proc_pidpath` in production).
/// Results are untrusted text; callers sanitize them.
public protocol AppInfoProvider: Sendable {
  /// Executable path of a running process, or `nil` if it is gone or unreadable.
  func executablePath(forPID pid: Int32) -> String?
  /// Display name of the `.app` at `appPath`, or `nil`.
  func appName(atAppPath appPath: String) -> String?
  /// Bundle identifier of the `.app` at `appPath`, or `nil`.
  func bundleID(atAppPath appPath: String) -> String?
}
