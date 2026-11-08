import CoreAudio
import Synchronization

/// Records only whether any sample was not an absolute zero. Nothing else is kept.
final class SignalProbeState: Sendable {
  private let signal = Atomic<Bool>(false)

  var sawSignal: Bool { signal.load(ordering: .relaxed) }

  /// Real-time safe.
  func scan(_ input: UnsafePointer<AudioBufferList>) {
    let list = UnsafeMutablePointer(mutating: input)
    var bits: UInt32 = 0
    for index in 0..<Int(list.pointee.mNumberBuffers) {
      let buffer = RealtimeTapState.buffer(list, index)
      guard let data = buffer.mData else { continue }
      let count = Int(buffer.mDataByteSize) / MemoryLayout<UInt32>.size
      let words = data.assumingMemoryBound(to: UInt32.self)
      for index in 0..<count { bits |= words[index] & 0x7FFF_FFFF }
    }
    if bits != 0 { signal.store(true, ordering: .relaxed) }
  }
}

/// IOProc of the access check: reads, never writes.
let signalProbeIOProc: AudioDeviceIOProc = { _, _, input, _, _, _, client in
  guard let client else { return noErr }
  Unmanaged<SignalProbeState>.fromOpaque(client)._withUnsafeGuaranteedRef { $0.scan(input) }
  return noErr
}
