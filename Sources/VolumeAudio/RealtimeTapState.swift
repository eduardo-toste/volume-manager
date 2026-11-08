import CoreAudio
import Synchronization

/// State shared between the real-time IOProc and the rest of the app. Everything is an atomic
/// (SPEC 12.2): the IOProc never locks, allocates or retains.
///
/// - The control side writes `targetBits` (and the setup values before IO starts).
/// - The audio thread writes the ramp position, the counters and the flags.
final class RealtimeTapState: Sendable {
  private let targetBits: Atomic<UInt32>
  private let currentBits: Atomic<UInt32>
  private let stepBits: Atomic<UInt32>
  private let inputOffset: Atomic<Int>
  private let frames = Atomic<UInt64>(0)
  private let signalSinceCheck = Atomic<Bool>(false)
  private let signalEver = Atomic<Bool>(false)
  private let faultFlag = Atomic<Bool>(false)

  /// Creates the state. `initialGain` is where the ramp starts (the target for a tap that
  /// replaces the original sound, so its first sample is not louder than needed after the
  /// unavoidable cut from the native sound; 0 for one that fades in next to another); `target` is where it goes.
  init(initialGain: Float, target: Float, step: Float) {
    targetBits = Atomic(Self.sanitized(target).bitPattern)
    currentBits = Atomic(Self.sanitized(initialGain).bitPattern)
    stepBits = Atomic(step.bitPattern)
    inputOffset = Atomic(0)
  }

  private static func sanitized(_ gain: Float) -> Float {
    gain.isNaN ? 1 : min(max(gain, 0), 1)
  }

  // MARK: Control side

  /// Sets the gain the ramp moves towards (already includes mute). NaN means 1, never silence.
  func setTarget(_ gain: Float) {
    targetBits.store(Self.sanitized(gain).bitPattern, ordering: .relaxed)
  }

  /// Sets the index of the first input buffer that carries the tap. Call before IO starts.
  func setInputOffset(_ offset: Int) { inputOffset.store(offset, ordering: .relaxed) }

  /// Sets the ramp step. Call before IO starts.
  func setStep(_ step: Float) { stepBits.store(step.bitPattern, ordering: .relaxed) }

  /// Frames processed since the start.
  var framesProcessed: UInt64 { frames.load(ordering: .relaxed) }

  /// True if a non-zero sample arrived since the previous call; clears the flag.
  func consumeSignalFlag() -> Bool { signalSinceCheck.exchange(false, ordering: .relaxed) }

  /// True if a non-zero sample ever arrived.
  var hasEverSeenSignal: Bool { signalEver.load(ordering: .relaxed) }

  /// True if the audio thread found buffers it could not process safely (kill switch).
  var hasFault: Bool { faultFlag.load(ordering: .relaxed) }

  /// The gain the ramp is heading to.
  var target: Float { Float(bitPattern: targetBits.load(ordering: .relaxed)) }

  /// The gain applied to the last sample.
  var currentGain: Float { Float(bitPattern: currentBits.load(ordering: .relaxed)) }

  // MARK: Audio thread

  /// Buffer `index` of `list`, by pointer arithmetic (no call into the CoreAudio overlay).
  @inline(__always)
  static func buffer(_ list: UnsafeMutablePointer<AudioBufferList>, _ index: Int) -> AudioBuffer {
    let header = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.stride
    let first = (UnsafeMutableRawPointer(list) + header).assumingMemoryBound(to: AudioBuffer.self)
    return first[index]
  }

  /// One IO cycle: copies the tap buffers to the output buffers with the gain.
  ///
  /// Real-time safe. Buffer sizes are checked before copying (SPEC 12.9.4). If the layout is
  /// not what was validated, the samples are copied unchanged and the kill switch is raised so
  /// the tap is destroyed; the output is never silenced as a way of reporting an error.
  func render(
    input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>
  ) {
    let outputCount = Int(output.pointee.mNumberBuffers)
    let inputCount = Int(input.pointee.mNumberBuffers)
    let target = Float(bitPattern: targetBits.load(ordering: .relaxed))
    let start = GainRamp(
      current: Float(bitPattern: currentBits.load(ordering: .relaxed)),
      step: Float(bitPattern: stepBits.load(ordering: .relaxed)))
    let offset = inputOffset.load(ordering: .relaxed)
    var end = start
    var frameCount = 0
    var signal = false
    var fault = false
    for index in 0..<outputCount {
      let out = Self.buffer(UnsafeMutablePointer(mutating: output), index)
      guard let destination = out.mData else { continue }
      let capacity = Int(out.mDataByteSize)
      let inputIndex = index &+ offset
      var inBuffer = AudioBuffer()
      if inputIndex >= 0 && inputIndex < inputCount {
        inBuffer = Self.buffer(UnsafeMutablePointer(mutating: input), inputIndex)
      }
      guard let source = inBuffer.mData else {
        fault = true
        destination.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        continue
      }
      let available = Int(inBuffer.mDataByteSize)
      let channels = Int(out.mNumberChannels)
      guard channels > 0, inBuffer.mNumberChannels == out.mNumberChannels else {
        fault = true
        let bytes = min(capacity, available)
        destination.copyMemory(from: source, byteCount: bytes)
        if bytes < capacity {
          (destination + bytes).initializeMemory(
            as: UInt8.self, repeating: 0, count: capacity - bytes)
        }
        continue
      }
      let count = min(capacity, available) / (MemoryLayout<Float>.size &* channels)
      var ramp = start
      let seen = GainKernel.process(
        input: source.assumingMemoryBound(to: Float.self),
        output: destination.assumingMemoryBound(to: Float.self),
        frames: count, channels: channels, target: target, ramp: &ramp)
      let written = count &* channels &* MemoryLayout<Float>.size
      if written < capacity {
        (destination + written).initializeMemory(
          as: UInt8.self, repeating: 0, count: capacity - written)
      }
      signal = signal || seen
      end = ramp
      if frameCount == 0 { frameCount = count }
    }
    currentBits.store(end.current.bitPattern, ordering: .relaxed)
    if frameCount > 0 { frames.add(UInt64(frameCount), ordering: .relaxed) }
    if signal {
      signalSinceCheck.store(true, ordering: .relaxed)
      signalEver.store(true, ordering: .relaxed)
    }
    if fault { faultFlag.store(true, ordering: .relaxed) }
  }
}
