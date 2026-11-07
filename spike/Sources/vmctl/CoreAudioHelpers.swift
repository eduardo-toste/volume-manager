import CoreAudio
import Foundation

/// Core Audio failure with context (SPEC 12.9.4: every OSStatus is checked).
struct CAError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String
    var description: String { "\(context) failed: OSStatus \(status) (\(fourCC(status)))" }
}

func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> UInt32($0)) & 0xFF) }
    let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    return printable ? String(decoding: bytes, as: UTF8.self) : "n/a"
}

func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    guard status == noErr else { throw CAError(status: status, context: context()) }
}

func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func hasProperty(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
    var a = addr
    return AudioObjectHasProperty(object, &a)
}

func getValue<T: BitwiseCopyable>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, zero: T) throws -> T {
    var a = addr
    var value = zero
    var size = UInt32(MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value), "get property \(fourCC(Int32(bitPattern: addr.mSelector))) on \(object)")
    guard size == UInt32(MemoryLayout<T>.size) else {
        throw CAError(status: kAudioHardwareBadPropertySizeError, context: "unexpected size \(size) for property on \(object)")
    }
    return value
}

func setValue<T: BitwiseCopyable>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) throws {
    var a = addr
    var v = value
    try check(
        AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v),
        "set property \(fourCC(Int32(bitPattern: addr.mSelector))) on \(object)")
}

func getArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, zero: T) throws -> [T] {
    var a = addr
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "get size of property on \(object)")
    let count = Int(size) / MemoryLayout<T>.stride
    guard count > 0 else { return [] }
    var result = [T](repeating: zero, count: count)
    var actual = UInt32(count * MemoryLayout<T>.stride)
    try check(
        result.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareIllegalOperationError }
            return AudioObjectGetPropertyData(object, &a, 0, nil, &actual, base)
        },
        "get array property on \(object)")
    return Array(result.prefix(Int(actual) / MemoryLayout<T>.stride))
}

func getString(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) throws -> String {
    var a = addr
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &ref), "get string property on \(object)")
    guard let ref else { return "" }
    return ref.takeRetainedValue() as String
}
