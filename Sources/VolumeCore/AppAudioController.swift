/// Applies per-app audio (taps and aggregate devices) so that it matches a desired state.
public protocol AppAudioController: Sendable {
  /// Makes the real audio match `desired`: creates, updates and destroys taps as needed.
  /// Idempotent: calling it twice with the same list changes nothing. Apps that are not in the
  /// list must end up with their original, untouched audio.
  func reconcile(desired: [DesiredAppAudio]) async
  /// Destroys every tap immediately, even while a `reconcile` is still running (the call may
  /// overlap it and must win: no tap may be recreated by that older `reconcile`), returning all apps to the original system audio.
  func restoreAll() async
  /// Allows a new attempt for an app whose tap failed (SPEC 4.6: only by user action). Takes
  /// effect at the next `reconcile`.
  func retry(appID: String) async
  /// Allows a new attempt for every app that failed (for example after the permission was
  /// granted). Takes effect at the next `reconcile`.
  func retryAll() async
}
