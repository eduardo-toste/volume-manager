/// The outcome of a signal-based permission check (SPEC 4.6).
public enum AudioAccessVerdict: Sendable, Hashable {
  /// A test tap received real (non-zero) audio: the permission is granted.
  case granted
  /// A process was playing but the test tap received only digital silence: denied.
  case denied
  /// Nothing was playing, so nothing can be concluded. No tap is created until a later check
  /// says `.granted` (SPEC 4.6).
  case indeterminate
}

/// Checks whether the system lets the app create a process tap (the audio permission, SPEC 5).
///
/// macOS has no public call that only *reads* this permission, and without it the system
/// creates taps without any error and delivers only zeros. So the real implementation listens
/// to an unmuted test tap on a process that is playing. It never mutes anything.
public protocol AudioAccessProbe: Sendable {
  /// Tries to create and immediately destroy a test tap. Returns `true` only if the tap was
  /// created. This does NOT prove the permission (see `verify()`); it is what shows the system
  /// prompt. Any failure returns `false` (fail open: nothing is left behind and no app is ever
  /// muted).
  func probe() -> Bool

  /// Confirms the permission by signal: listens for about 500 ms to an unmuted test tap on a
  /// process that reports output. Only zeros while that process is still playing means denied.
  /// When nothing is playing, `idleTargetAllowed` (only for an action of the user) lets it listen
  /// to any other audio process, which is what makes the system show its prompt; otherwise it only
  /// creates and destroys a bare tap. The default implementation trusts `probe()`.
  func verify(idleTargetAllowed: Bool) async -> AudioAccessVerdict
}

extension AudioAccessProbe {
  /// See `AudioAccessProbe.verify(idleTargetAllowed:)`.
  public func verify(idleTargetAllowed: Bool) async -> AudioAccessVerdict {
    probe() ? .granted : .denied
  }
}
