/// Everything the UI needs to draw one app row.
public struct MixerRow: Sendable, Hashable, Identifiable {
  /// Stable key of the app.
  public var id: String { app.id }
  /// The app.
  public let app: AudioApp
  /// What the user chose for it.
  public let state: AppAudioState
  /// The output it plays on, if known.
  public let device: OutputDevice?
  /// True when it follows the system default output.
  public let usesSystemDefault: Bool
  /// True when it has a saved output that is not connected right now.
  public let savedDeviceMissing: Bool

  /// Creates a row.
  public init(
    app: AudioApp, state: AppAudioState, device: OutputDevice?, usesSystemDefault: Bool,
    savedDeviceMissing: Bool
  ) {
    self.app = app
    self.state = state
    self.device = device
    self.usesSystemDefault = usesSystemDefault
    self.savedDeviceMissing = savedDeviceMissing
  }
}
