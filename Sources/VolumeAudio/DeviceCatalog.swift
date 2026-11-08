import CoreAudio
import Foundation
import VolumeCore

/// An output device as the tap engine needs it: object, stable UID and stream format.
struct DeviceSignature: Sendable, Hashable {
  let id: AudioObjectID
  let uid: String
  let layout: StreamLayout
}

extension OutputDeviceKind {
  /// Kind of device for a Core Audio transport type.
  init(transportType: UInt32) {
    switch transportType {
    case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
    case kAudioDeviceTransportTypeUSB: self = .usb
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
      self = .bluetooth
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: self = .display
    case kAudioDeviceTransportTypeAirPlay: self = .airPlay
    case kAudioDeviceTransportTypeVirtual: self = .virtual
    default: self = .other
    }
  }
}

/// Reads and changes output devices.
enum DeviceCatalog {
  /// Prefix of the UID of every aggregate device this app creates, so they never show up as
  /// outputs for the user.
  static let aggregateUIDPrefix = "com.volumemanager.agg."

  static func allDeviceIDs() -> [AudioObjectID] {
    let address = AudioProperty.address(kAudioHardwarePropertyDevices)
    return (try? AudioProperty.array(AudioProperty.system, address, initial: AudioObjectID(0)))
      ?? []
  }

  static func hasOutput(_ id: AudioObjectID) -> Bool {
    let address = AudioProperty.address(
      kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
    return ((try? AudioProperty.array(id, address, initial: AudioObjectID(0))) ?? []).isEmpty
      == false
  }

  static func rawUID(of id: AudioObjectID) -> String? {
    try? AudioProperty.string(id, AudioProperty.address(kAudioDevicePropertyDeviceUID))
  }

  /// Output devices (without this app's own aggregate devices).
  static func outputDevices() -> [OutputDevice] {
    allDeviceIDs().compactMap { id in
      guard hasOutput(id), let uid = rawUID(of: id), !uid.hasPrefix(aggregateUIDPrefix) else {
        return nil
      }
      let name =
        (try? AudioProperty.string(id, AudioProperty.address(kAudioObjectPropertyName))) ?? ""
      let transport =
        (try? AudioProperty.get(
          id, AudioProperty.address(kAudioDevicePropertyTransportType), initial: UInt32(0))) ?? 0
      return OutputDevice(
        id: id, uid: uid, name: name.isEmpty ? "Output" : name,
        kind: OutputDeviceKind(transportType: transport),
        hasVolumeControl: hasVolumeControl(id))
    }
  }

  static func hasVolumeControl(_ id: AudioObjectID) -> Bool {
    AudioProperty.has(id, volumeAddress)
      || AudioProperty.has(id, channelVolumeAddress(element: 1))
  }

  static func deviceID(forUID uid: String) -> AudioObjectID? {
    allDeviceIDs().first { id in
      guard hasOutput(id), let raw = rawUID(of: id) else { return false }
      return raw == uid || TextSanitizer.clean(raw) == uid
    }
  }

  static func defaultOutputID() -> AudioObjectID? {
    let address = AudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
    guard
      let id = try? AudioProperty.get(AudioProperty.system, address, initial: AudioObjectID(0)),
      id != AudioProperty.unknown
    else { return nil }
    return id
  }

  static func defaultOutputUID() -> String? {
    defaultOutputID().flatMap { rawUID(of: $0) }.map { TextSanitizer.clean($0) }
  }

  static func setDefaultOutput(_ id: AudioObjectID) throws(AudioError) {
    try AudioProperty.set(
      AudioProperty.system, AudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice),
      value: id)
  }

  /// Stream format of the first output stream, with the device it belongs to.
  static func signature(forUID uid: String) -> DeviceSignature? {
    guard let id = deviceID(forUID: uid) else { return nil }
    let address = AudioProperty.address(
      kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeOutput)
    guard
      let format = try? AudioProperty.get(id, address, initial: AudioStreamBasicDescription())
    else { return nil }
    return DeviceSignature(id: id, uid: uid, layout: StreamLayout(format))
  }

  // MARK: Master volume and mute

  private static let volumeAddress = AudioProperty.address(
    AudioProperty.virtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
  private static let muteAddress = AudioProperty.address(
    kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)

  private static func channelVolumeAddress(element: UInt32) -> AudioObjectPropertyAddress {
    AudioProperty.address(
      kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: element)
  }

  /// Volume and mute of `id`, or `nil` if the device exposes neither.
  static func master(of id: AudioObjectID) -> MasterOutputState? {
    var volume: Float32?
    if AudioProperty.has(id, volumeAddress) {
      volume = try? AudioProperty.get(id, volumeAddress, initial: Float32(0))
    } else if AudioProperty.has(id, channelVolumeAddress(element: 1)) {
      volume = try? AudioProperty.get(id, channelVolumeAddress(element: 1), initial: Float32(0))
    }
    var muted: UInt32?
    if AudioProperty.has(id, muteAddress) {
      muted = try? AudioProperty.get(id, muteAddress, initial: UInt32(0))
    }
    guard volume != nil || muted != nil else { return nil }
    return MasterOutputState(volume: Double(volume ?? 1), isMuted: (muted ?? 0) != 0)
  }

  static func setMasterVolume(_ id: AudioObjectID, volume: Double) throws(AudioError) {
    let value = Float32(VolumeCurve.clampedVolume(volume))
    if AudioProperty.has(id, volumeAddress), AudioProperty.isSettable(id, volumeAddress) {
      try AudioProperty.set(id, volumeAddress, value: value)
      return
    }
    var wrote = false
    for element in UInt32(1)...2 {
      let address = channelVolumeAddress(element: element)
      guard AudioProperty.has(id, address), AudioProperty.isSettable(id, address) else {
        continue
      }
      try AudioProperty.set(id, address, value: value)
      wrote = true
    }
    if !wrote { throw AudioError.unsupported("device has no settable volume") }
  }

  static func setMasterMuted(_ id: AudioObjectID, muted: Bool) throws(AudioError) {
    guard AudioProperty.has(id, muteAddress), AudioProperty.isSettable(id, muteAddress) else {
      throw AudioError.unsupported("device has no settable mute")
    }
    try AudioProperty.set(id, muteAddress, value: UInt32(muted ? 1 : 0))
  }
}

/// Read-only diagnostics for `vmctl` and the hardware tests.
public enum AudioDiagnostics {
  /// Number of audio devices Core Audio lists (all kinds). Used to prove that creating and
  /// destroying taps leaves nothing behind.
  public static func deviceCount() -> Int { DeviceCatalog.allDeviceIDs().count }

  /// UIDs of every audio device Core Audio lists, to see exactly what appeared or vanished.
  public static func deviceUIDs() -> [String] {
    DeviceCatalog.allDeviceIDs().compactMap { DeviceCatalog.rawUID(of: $0) }
  }

  /// Output stream format of the device with this UID, as text.
  public static func outputFormat(ofDeviceUID uid: String) -> String? {
    DeviceCatalog.signature(forUID: uid)?.layout.summary
  }
}
