import CoreAudio
import Darwin
import Foundation
import CAtomics
import SpikeCore

/// State shared with the real-time IOProc. Only atomics are touched across threads;
/// `currentGain`/`rampStep` are owned by the audio thread once started.
final class RTState: @unchecked Sendable {
    private let targetBits = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    private let framesCounter = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    private let peakBits = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    var currentGain: Float = 1
    var rampStep: Float = 0.001

    init() {
        targetBits.initialize(to: Float(1).bitPattern)
        framesCounter.initialize(to: 0)
        peakBits.initialize(to: 0)
    }

    deinit {
        targetBits.deallocate()
        framesCounter.deallocate()
        peakBits.deallocate()
    }

    /// DIAGNOSTIC (spike only): largest absolute input sample seen since start.
    var inputPeak: Float { Float(bitPattern: vm_load_u32(peakBits)) }
    func notePeak(_ v: Float) { if v > inputPeak { vm_store_u32(peakBits, v.bitPattern) } }

    /// Frames processed so far (atomic read; any thread).
    var frames: UInt64 { vm_load_u64(framesCounter) }
    /// Gain target as float bits (atomic read; audio thread).
    var targetGain: Float { Float(bitPattern: vm_load_u32(targetBits)) }
    func addFrames(_ n: UInt64) { vm_add_u64(framesCounter, n) }

    func setTarget(volume: Float, muted: Bool) {
        let g = muted ? 0 : Gain.perceptual(volume)
        vm_store_u32(targetBits, g.bitPattern)
    }
}

/// Real-time callback: copies tap input to the output multiplying by a ramped gain.
/// No allocation, locks, logging or Swift dynamic dispatch. Buffer sizes are checked before copying.
private let tapIOProc: AudioDeviceIOProc = { _, _, inData, _, outData, _, client in
    guard let client else { return noErr }
    let state = Unmanaged<RTState>.fromOpaque(client).takeUnretainedValue()
    let target = state.targetGain
    let start = state.currentGain
    let step = state.rampStep
    var end = start
    var counted = false
    let outList = UnsafeMutableAudioBufferListPointer(outData)
    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    for i in 0..<outList.count {
        let outBuf = outList[i]
        guard let dst = outBuf.mData else { continue }
        let capacity = Int(outBuf.mDataByteSize)
        guard i < inList.count, let src = inList[i].mData,
            inList[i].mNumberChannels == outBuf.mNumberChannels, outBuf.mNumberChannels > 0
        else {
            memset(dst, 0, capacity)
            continue
        }
        let samples = min(capacity, Int(inList[i].mDataByteSize)) / MemoryLayout<Float>.size
        let ch = Int(outBuf.mNumberChannels)
        let frameCount = samples / ch
        let s = src.assumingMemoryBound(to: Float.self)
        let d = dst.assumingMemoryBound(to: Float.self)
        var g = start
        var peak: Float = 0
        for k in 0..<(frameCount * ch) { let a = abs(s[k]); if a > peak { peak = a } }
        state.notePeak(peak)
        for f in 0..<frameCount {
            g = Gain.next(current: g, target: target, step: step)
            let base = f * ch
            for c in 0..<ch { d[base + c] = s[base + c] * g }
        }
        let written = frameCount * ch * MemoryLayout<Float>.size
        if written < capacity { memset(dst + written, 0, capacity - written) }
        end = g
        if !counted {
            state.addFrames(UInt64(frameCount))
            counted = true
        }
    }
    state.currentGain = end
    return noErr
}

/// One tap + private aggregate device + IOProc. `stop()` destroys everything in order and is idempotent.
final class TapSession {
    let state = RTState()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var started = false
    private(set) var tapFormatDescription = "?"
    private(set) var outputFormatDescription = "?"

    private static func describe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> String {
        guard let f = try? getValue(object, address(selector, scope: scope), zero: AudioStreamBasicDescription()) else { return "unavailable" }
        let isFloat = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return "\(Int(f.mSampleRate)) Hz, \(f.mChannelsPerFrame) ch, \(f.mBitsPerChannel)-bit \(isFloat ? "float" : "int"), \(interleaved ? "interleaved" : "non-interleaved"), id=\(fourCC(Int32(bitPattern: f.mFormatID)))"
    }

    func start(processObjectIDs: [AudioObjectID], output: OutputDevice, volume: Float, muted: Bool, startIO: Bool = true) throws {
        do {
            let desc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
            desc.name = "vmctl-spike-tap"
            desc.isPrivate = true
            desc.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(desc, &tapID), "AudioHardwareCreateProcessTap")

            let dict: [String: Any] = [
                kAudioAggregateDeviceNameKey: "vmctl-spike-aggregate",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
                ],
            ]
            try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID), "AudioHardwareCreateAggregateDevice")

            tapFormatDescription = Self.describe(tapID, kAudioTapPropertyFormat, scope: kAudioObjectPropertyScopeGlobal)
            outputFormatDescription = Self.describe(output.id, kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeOutput)
            state.rampStep = Gain.rampStep(sampleRate: output.sampleRate)
            state.setTarget(volume: volume, muted: muted)
            guard startIO else { return }
            let client = Unmanaged.passUnretained(state).toOpaque()
            try check(AudioDeviceCreateIOProcID(aggregateID, tapIOProc, client, &procID), "AudioDeviceCreateIOProcID")
            try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
            started = true
        } catch {
            stop()
            throw error
        }
    }

    func update(volume: Float, muted: Bool) { state.setTarget(volume: volume, muted: muted) }

    /// Order: stop IOProc, destroy IOProc, destroy aggregate, destroy tap. Errors are reported, never thrown.
    func stop() {
        func report(_ s: OSStatus, _ what: String) {
            if s != noErr { FileHandle.standardError.write(Data("warning: \(CAError(status: s, context: what))\n".utf8)) }
        }
        if started, let p = procID { report(AudioDeviceStop(aggregateID, p), "AudioDeviceStop") }
        started = false
        if let p = procID {
            report(AudioDeviceDestroyIOProcID(aggregateID, p), "AudioDeviceDestroyIOProcID")
            procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            report(AudioHardwareDestroyAggregateDevice(aggregateID), "AudioHardwareDestroyAggregateDevice")
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            report(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
