/// Volume and mute of the default output device.
public struct MasterOutputState: Sendable, Hashable {
  /// Volume in `0...1`.
  public let volume: Double
  /// True when the device is muted.
  public let isMuted: Bool

  /// Creates a state. The volume is clamped to `0...1`.
  public init(volume: Double, isMuted: Bool) {
    self.volume = VolumeCurve.clampedVolume(volume)
    self.isMuted = isMuted
  }
}

/// A change in the audio system. Every event carries the complete new value, so events that
/// arrive late or out of order cannot leave the domain inconsistent.
public enum AudioSystemEvent: Sendable, Hashable {
  /// The list of audio processes, or their `isRunningOutput` flags, changed.
  case processes([AudioProcessInfo])
  /// The list of output devices changed.
  case devices([OutputDevice])
  /// The default output changed (`nil` when there is none).
  case defaultOutput(uid: String?)
  /// The volume or mute of the default output changed (for example, by the keyboard keys).
  case master(MasterOutputState)
}

/// Everything the domain needs to start.
public struct AudioSystemSnapshot: Sendable, Hashable {
  /// Audio processes.
  public let processes: [AudioProcessInfo]
  /// Output devices.
  public let devices: [OutputDevice]
  /// UID of the default output.
  public let defaultOutputUID: String?
  /// Volume and mute of the default output, if readable.
  public let master: MasterOutputState?

  /// Creates a snapshot.
  public init(
    processes: [AudioProcessInfo] = [], devices: [OutputDevice] = [],
    defaultOutputUID: String? = nil, master: MasterOutputState? = nil
  ) {
    self.processes = processes
    self.devices = devices
    self.defaultOutputUID = defaultOutputUID
    self.master = master
  }
}

/// The system-wide side of Core Audio: what exists, what changed, and system-level controls.
public protocol AudioSystem: Sendable {
  /// A stream of changes. Each call returns an independent stream.
  func events() -> AsyncStream<AudioSystemEvent>
  /// The current state of the system.
  func currentState() async -> AudioSystemSnapshot
  /// Sets the volume of the default output device.
  func setMasterVolume(_ volume: Double) async
  /// Mutes or unmutes the default output device.
  func setMasterMuted(_ muted: Bool) async
  /// Makes the device with this UID the system default output.
  func setDefaultOutput(uid: String) async
}
