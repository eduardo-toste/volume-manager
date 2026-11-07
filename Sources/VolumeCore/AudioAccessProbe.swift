/// Checks whether the system lets the app create a process tap (the audio permission, SPEC 5).
///
/// macOS has no public call that only *reads* this permission, so the real implementation
/// creates the smallest possible tap and destroys it at once. It never starts I/O.
public protocol AudioAccessProbe: Sendable {
  /// Tries to create and immediately destroy a test tap. Returns `true` only if the tap was
  /// created (permission granted). Any failure returns `false` (fail open: nothing is left
  /// behind and no app is ever muted).
  func probe() -> Bool
}
