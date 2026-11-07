/// Kind of output device, used for the icon and the list.
public enum OutputDeviceKind: String, Sendable, Hashable, CaseIterable {
  /// Built-in speakers or headphone jack.
  case builtIn
  /// USB audio device.
  case usb
  /// Bluetooth device (AirPods and others).
  case bluetooth
  /// HDMI or DisplayPort.
  case display
  /// AirPlay receiver.
  case airPlay
  /// Virtual device.
  case virtual
  /// Anything else.
  case other
}

/// An audio output device. Apps are routed by `uid`, which survives reconnection; `id` does not.
public struct OutputDevice: Sendable, Hashable, Identifiable {
  /// Numeric Core Audio object ID (not stable across reconnections).
  public let id: UInt32
  /// Stable unique identifier (sanitized).
  public let uid: String
  /// Sanitized display name.
  public let name: String
  /// Kind of device.
  public let kind: OutputDeviceKind
  /// False for devices without software volume (some USB or HDMI outputs).
  public let hasVolumeControl: Bool

  /// Creates a device. `uid` and `name` come from the system and are sanitized.
  public init(
    id: UInt32, uid: String, name: String, kind: OutputDeviceKind = .other,
    hasVolumeControl: Bool = true
  ) {
    self.id = id
    self.uid = TextSanitizer.clean(uid)
    self.name = TextSanitizer.clean(name)
    self.kind = kind
    self.hasVolumeControl = hasVolumeControl
  }
}
