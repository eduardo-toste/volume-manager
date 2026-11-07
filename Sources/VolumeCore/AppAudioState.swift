/// What the user chose for one app. The default means "leave the app alone".
public struct AppAudioState: Sendable, Hashable {
  /// Slider position in `0...1`.
  public var volume: Double
  /// True when the app is muted. The slider keeps its value.
  public var muted: Bool
  /// UID of the preferred output, or `nil` for the system default.
  public var preferredOutputUID: String?

  /// 100%, not muted, system default output.
  public static let `default` = AppAudioState()

  /// Creates a state. The volume is clamped to `0...1`.
  public init(volume: Double = 1, muted: Bool = false, preferredOutputUID: String? = nil) {
    self.volume = VolumeCurve.clampedVolume(volume)
    self.muted = muted
    self.preferredOutputUID = preferredOutputUID
  }
}

/// The part of an app that matters for audio control: nothing volatile such as "is playing".
public struct ControlledApp: Sendable, Hashable {
  /// Stable key of the app.
  public let id: String
  /// Valid bundle ID, if any.
  public let bundleID: String?
  /// PIDs of every process the tap must cover, sorted.
  public let pids: [Int32]

  /// Creates the description.
  public init(id: String, bundleID: String?, pids: [Int32]) {
    self.id = id
    self.bundleID = bundleID
    self.pids = pids
  }

  /// The audio-relevant part of `app`.
  public init(_ app: AudioApp) {
    self.init(id: app.id, bundleID: app.bundleID, pids: app.pids)
  }
}

/// What the audio controller must apply for one app (SPEC 12.1, declarative reconciliation).
public struct DesiredAppAudio: Sendable, Hashable {
  /// The app, with every process the tap must cover.
  public let app: ControlledApp
  /// Gain from the volume curve, `0...1`. Applies only when not muted.
  public let gain: Float
  /// True when the app must be silent.
  public let muted: Bool
  /// UID of the output device the app plays on.
  public let targetDeviceUID: String

  /// Creates a desired state.
  public init(app: ControlledApp, gain: Float, muted: Bool, targetDeviceUID: String) {
    self.app = app
    self.gain = gain
    self.muted = muted
    self.targetDeviceUID = targetDeviceUID
  }
}
