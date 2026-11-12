import CoreAudio
import Testing

@testable import VolumeAudio

// Security M7.5: channel counts no real device reports (up to UInt32.max). `render` computes
// `bytes / (4 × channels)` and `frames × channels`; these must neither overflow nor leave the
// declared buffers, and the output is never louder than the input. Run also under
// `swift test --sanitize=address --filter SecurityM75`.

/// One input and one output buffer whose data blocks have exactly the declared size.
private final class Pair {
  let input: UnsafeMutablePointer<AudioBufferList>
  let output: UnsafeMutablePointer<AudioBufferList>
  let inData: UnsafeMutablePointer<Float>
  let outData: UnsafeMutablePointer<Float>
  let floats: Int

  init(inChannels: UInt32, outChannels: UInt32, floats: Int) {
    self.floats = floats
    input = .allocate(capacity: 1)
    output = .allocate(capacity: 1)
    inData = .allocate(capacity: floats)
    outData = .allocate(capacity: floats)
    for index in 0..<floats { inData[index] = index.isMultiple(of: 2) ? 0.75 : -0.5 }
    outData.initialize(repeating: 9, count: floats)
    let bytes = UInt32(floats * MemoryLayout<Float>.size)
    input.initialize(
      to: AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(mNumberChannels: inChannels, mDataByteSize: bytes, mData: inData)))
    output.initialize(
      to: AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(mNumberChannels: outChannels, mDataByteSize: bytes, mData: outData))
    )
  }

  deinit {
    input.deallocate()
    output.deallocate()
    inData.deallocate()
    outData.deallocate()
  }
}

@Suite("Security M7.5: hostile channel counts in render", .timeLimit(.minutes(1)))
struct SecurityM75RenderTests {
  static let hostile: [UInt32] = [
    0, 1, 2, 3, 7, 255, 4096, 1 << 30, 1 << 31, UInt32.max - 1, UInt32.max,
  ]

  @Test(arguments: hostile)
  func sameHugeChannelCountOnBothSidesStaysInBoundsAndNeverAmplifies(channels: UInt32) {
    let pair = Pair(inChannels: channels, outChannels: channels, floats: 16)
    let state = RealtimeTapState(initialGain: 0.5, target: 0.5, step: 0.01)
    state.render(input: UnsafePointer(pair.input), output: pair.output)
    for index in 0..<pair.floats {
      let out = pair.outData[index]
      #expect(out.isFinite, "channels \(channels)")
      #expect(abs(out) <= abs(pair.inData[index]), "channels \(channels) index \(index)")
    }
    #expect(state.currentGain >= 0 && state.currentGain <= 1)
  }

  @Test(arguments: hostile)
  func mismatchedHugeCountsCopyUnchangedAndRaiseTheKillSwitch(channels: UInt32) {
    let other: UInt32 = channels == 2 ? 1 : 2
    let pair = Pair(inChannels: channels, outChannels: other, floats: 8)
    let state = RealtimeTapState(initialGain: 0.25, target: 0.25, step: 0.01)
    state.render(input: UnsafePointer(pair.input), output: pair.output)
    #expect(state.hasFault)
    for index in 0..<pair.floats { #expect(pair.outData[index] == pair.inData[index]) }
  }
}
