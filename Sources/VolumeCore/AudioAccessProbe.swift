/// The outcome of a signal-based permission check (SPEC 4.6).
public enum AudioAccessVerdict: Sendable, Hashable {
  /// A test tap received real (non-zero) audio: the permission is granted.
  case granted
  /// A process was playing but the test tap received only digital silence: denied.
  case denied
  /// Nothing was playing, so nothing can be concluded. This does not block anything: the
  /// silence guard of each tap (SPEC 4.6) covers the case.
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
  /// The default implementation trusts `probe()`.
  func verify() async -> AudioAccessVerdict
}

extension AudioAccessProbe {
  /// See `AudioAccessProbe.verify()`.
  public func verify() async -> AudioAccessVerdict {
    probe() ? .granted : .denied
  }
}
