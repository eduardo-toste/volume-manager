import CoreAudio
import Foundation

/// Typed access to Core Audio properties. Every call checks its `OSStatus`.
enum AudioProperty {
  /// Largest array accepted from the system, so a misbehaving driver cannot make us allocate
  /// without bound (SPEC 12.9.4).
  static let maxArrayCount = 4096

  /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` ('vmvc'). The constant lives in a
  /// deprecated header; the property itself is the documented way to read the overall volume.
  static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

  static let system = AudioObjectID(kAudioObjectSystemObject)
  static let unknown = AudioObjectID(kAudioObjectUnknown)

  static func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
  }

  static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
    var copy = address
    return AudioObjectHasProperty(object, &copy)
  }

  static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
    var copy = address
    var settable: DarwinBoolean = false
    guard AudioObjectIsPropertySettable(object, &copy, &settable) == noErr else { return false }
    return settable.boolValue
  }

  static func get<T: BitwiseCopyable>(
    _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T
  ) throws(AudioError) -> T {
    var copy = address
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try AudioError.check(
      AudioObjectGetPropertyData(object, &copy, 0, nil, &size, &value),
      "get \(describe(address)) of object \(object)")
    guard size == UInt32(MemoryLayout<T>.size) else {
      throw AudioError(
        status: kAudioHardwareBadPropertySizeError,
        context: "unexpected size \(size) for \(describe(address))")
    }
    return value
  }

  static func set<T: BitwiseCopyable>(
    _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, value: T
  ) throws(AudioError) {
    var copy = address
    var newValue = value
    try AudioError.check(
      AudioObjectSetPropertyData(
        object, &copy, 0, nil, UInt32(MemoryLayout<T>.size), &newValue),
      "set \(describe(address)) of object \(object)")
  }

  static func array<T: BitwiseCopyable>(
    _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T
  ) throws(AudioError) -> [T] {
    var copy = address
    var size: UInt32 = 0
    try AudioError.check(
      AudioObjectGetPropertyDataSize(object, &copy, 0, nil, &size),
      "get size of \(describe(address)) of object \(object)")
    let count = min(Int(size) / MemoryLayout<T>.stride, maxArrayCount)
    guard count > 0 else { return [] }
    var result = [T](repeating: initial, count: count)
    var actual = UInt32(count * MemoryLayout<T>.stride)
    let status = result.withUnsafeMutableBytes { buffer -> OSStatus in
      guard let base = buffer.baseAddress else { return kAudioHardwareIllegalOperationError }
      return AudioObjectGetPropertyData(object, &copy, 0, nil, &actual, base)
    }
    try AudioError.check(status, "get \(describe(address)) of object \(object)")
    return Array(result.prefix(Int(actual) / MemoryLayout<T>.stride))
  }

  /// A string property. Very long values are cut (they are untrusted text).
  static func string(
    _ object: AudioObjectID, _ address: AudioObjectPropertyAddress
  ) throws(AudioError) -> String {
    var copy = address
    var reference: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try AudioError.check(
      AudioObjectGetPropertyData(object, &copy, 0, nil, &size, &reference),
      "get \(describe(address)) of object \(object)")
    guard let reference else { return "" }
    let text = reference.takeRetainedValue() as String
    return String(text.prefix(1024))
  }

  /// Channels of each buffer of a `kAudioDevicePropertyStreamConfiguration` property.
  static func bufferShape(
    _ object: AudioObjectID, scope: AudioObjectPropertyScope
  ) throws(AudioError) -> [UInt32] {
    var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
    var size: UInt32 = 0
    try AudioError.check(
      AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size),
      "get size of stream configuration of object \(object)")
    guard size >= UInt32(MemoryLayout<AudioBufferList>.size), size <= 64 * 1024 else {
      return []
    }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    var actual = size
    try AudioError.check(
      AudioObjectGetPropertyData(object, &address, 0, nil, &actual, raw),
      "get stream configuration of object \(object)")
    let list = UnsafeMutableAudioBufferListPointer(
      raw.assumingMemoryBound(to: AudioBufferList.self))
    // The list header is the size of AudioBufferList minus its one inline AudioBuffer.
    let header = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.stride
    let maxBuffers = (Int(actual) - header) / MemoryLayout<AudioBuffer>.stride
    return list.prefix(max(0, min(list.count, maxBuffers))).map(\.mNumberChannels)
  }

  /// Four-character name of a selector, for error messages.
  static func describe(_ address: AudioObjectPropertyAddress) -> String {
    let value = address.mSelector
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "property \(value)" }
    return "property '\(String(decoding: bytes, as: UTF8.self))'"
  }
}
