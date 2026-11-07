import CoreAudio
import Foundation
import SpikeCore

struct OutputDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
    let isDefault: Bool
    let hasSoftwareVolume: Bool
    let sampleRate: Double
}

/// Four-char code 'vmvc' = kAudioHardwareServiceDeviceProperty_VirtualMainVolume (the AudioHardwareService
/// header is deprecated, the property itself is the documented way to read the master volume).
let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

func allDeviceIDs() throws -> [AudioObjectID] {
    try getArray(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices), zero: AudioObjectID(0))
}

func defaultOutputID() throws -> AudioObjectID {
    try getValue(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), zero: AudioObjectID(0))
}

func hasOutputStreams(_ id: AudioObjectID) -> Bool {
    let addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
    guard let streams = try? getArray(id, addr, zero: AudioObjectID(0)) else { return false }
    return !streams.isEmpty
}

func outputDevices() throws -> [OutputDevice] {
    let def = try defaultOutputID()
    var result: [OutputDevice] = []
    for id in try allDeviceIDs() where hasOutputStreams(id) {
        let uid = (try? getString(id, address(kAudioDevicePropertyDeviceUID))) ?? ""
        let name = (try? getString(id, address(kAudioObjectPropertyName))) ?? "?"
        let volAddr = address(virtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        let rate = (try? getValue(id, address(kAudioDevicePropertyNominalSampleRate), zero: Float64(0))) ?? 48_000
        result.append(
            OutputDevice(
                id: id, uid: Sanitize.text(uid), name: Sanitize.text(name), isDefault: id == def,
                hasSoftwareVolume: hasProperty(id, volAddr), sampleRate: rate))
    }
    return result
}

func deviceID(forUID uid: String) throws -> AudioObjectID {
    guard let dev = try outputDevices().first(where: { $0.uid == uid }) else {
        throw CAError(status: kAudioHardwareBadDeviceError, context: "no output device with UID \(Sanitize.text(uid))")
    }
    return dev.id
}

func masterVolume(_ id: AudioObjectID) throws -> Float {
    try getValue(id, address(virtualMainVolume, scope: kAudioObjectPropertyScopeOutput), zero: Float32(0))
}

func setMasterVolume(_ id: AudioObjectID, _ value: Float) throws {
    let v = min(max(value.isNaN ? 0 : value, 0), 1)
    try setValue(id, address(virtualMainVolume, scope: kAudioObjectPropertyScopeOutput), Float32(v))
}
