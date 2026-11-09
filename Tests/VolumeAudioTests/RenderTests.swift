import CoreAudio
import Testing

@testable import VolumeAudio

/// Owns the memory behind hand-built `AudioBufferList`s so the real `render` can be tested.
final class BufferListFixture {
  private let raw: UnsafeMutableRawPointer
  private var blocks: [UnsafeMutablePointer<Float>] = []
  let list: UnsafeMutablePointer<AudioBufferList>

  /// `buffers`: (channels, samples stored, capacity in samples).
  init(buffers: [(channels: Int, samples: [Float], capacity: Int)]) {
    let size =
      MemoryLayout<AudioBufferList>.size
      + max(0, buffers.count - 1) * MemoryLayout<AudioBuffer>.stride
    raw = .allocate(byteCount: size, alignment: 16)
    list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    list.pointee.mNumberBuffers = UInt32(buffers.count)
    let pointer = UnsafeMutableAudioBufferListPointer(list)
    for (index, buffer) in buffers.enumerated() {
      let block = UnsafeMutablePointer<Float>.allocate(capacity: buffer.capacity + 4)
      block.initialize(repeating: -9, count: buffer.capacity + 4)
      for (offset, sample) in buffer.samples.enumerated() { block[offset] = sample }
      blocks.append(block)
      pointer[index] = AudioBuffer(
        mNumberChannels: UInt32(buffer.channels),
        mDataByteSize: UInt32(buffer.capacity * 4), mData: block)
    }
  }

  /// The first `count` samples of buffer `index`, plus the 4 guard samples after its capacity.
  func samples(_ index: Int, count: Int) -> [Float] {
    (0..<count).map { blocks[index][$0] }
  }

  func guardSamples(_ index: Int, capacity: Int) -> [Float] {
    (capacity..<capacity + 4).map { blocks[index][$0] }
  }

  deinit {
    for block in blocks { block.deallocate() }
    raw.deallocate()
  }
}

@Suite("RealtimeTapState.render (real IOProc body)", .timeLimit(.minutes(1)))
struct RenderTests {
  @Test func interleavedStereoAppliesGainAndCounts() {
    let state = RealtimeTapState(initialGain: 0.5, target: 0.5, step: 0.001)
    let source = TestSignal.noise(count: 64)
    let input = BufferListFixture(buffers: [(2, source, 64)])
    let output = BufferListFixture(buffers: [(2, [], 64)])
    state.render(input: input.list, output: output.list)
    #expect(output.samples(0, count: 64) == source.map { $0 * 0.5 })
    #expect(state.framesProcessed == 32)
    #expect(state.hasEverSeenSignal)
    #expect(state.consumeSignalFlag())
    #expect(state.consumeSignalFlag() == false)
    #expect(state.hasFault == false)
  }

  @Test func unityIsBitExactThroughRender() {
    let state = RealtimeTapState(initialGain: 1, target: 1, step: 0.001)
    let source = TestSignal.sine(frames: 512, channels: 2)
    let input = BufferListFixture(buffers: [(2, source, 1024)])
    let output = BufferListFixture(buffers: [(2, [], 1024)])
    state.render(input: input.list, output: output.list)
    #expect(output.samples(0, count: 1024).map(\.bitPattern) == source.map(\.bitPattern))
  }

  @Test func silenceIsNotSignal() {
    let state = RealtimeTapState(initialGain: 1, target: 1, step: 0.001)
    let input = BufferListFixture(buffers: [(2, [Float](repeating: 0, count: 64), 64)])
    let output = BufferListFixture(buffers: [(2, [], 64)])
    state.render(input: input.list, output: output.list)
    #expect(state.framesProcessed == 32)
    #expect(state.hasEverSeenSignal == false)
    #expect(state.consumeSignalFlag() == false)
  }

  @Test func inputOffsetSkipsSubDeviceInputs() {
    let state = RealtimeTapState(initialGain: 1, target: 1, step: 0.001)
    state.setInputOffset(1)
    let input = BufferListFixture(buffers: [
      (1, [Float](repeating: 0.9, count: 16), 16), (2, [1, 2, 3, 4], 4),
    ])
    let output = BufferListFixture(buffers: [(2, [], 4)])
    state.render(input: input.list, output: output.list)
    #expect(output.samples(0, count: 4) == [1, 2, 3, 4])
    #expect(state.hasFault == false)
  }

  @Test func nonInterleavedBuffersShareOneRamp() {
    let state = RealtimeTapState(initialGain: 1, target: 0, step: 0.25)
    let ones = [Float](repeating: 1, count: 8)
    let input = BufferListFixture(buffers: [(1, ones, 8), (1, ones, 8)])
    let output = BufferListFixture(buffers: [(1, [], 8), (1, [], 8)])
    state.render(input: input.list, output: output.list)
    #expect(output.samples(0, count: 8) == [0.75, 0.5, 0.25, 0, 0, 0, 0, 0])
    #expect(output.samples(1, count: 8) == output.samples(0, count: 8))
    #expect(state.currentGain == 0)
    #expect(state.framesProcessed == 8)
  }

  @Test func neverWritesBeyondTheOutputCapacity() {
    let state = RealtimeTapState(initialGain: 1, target: 1, step: 0.001)
    let input = BufferListFixture(buffers: [(2, [Float](repeating: 0.5, count: 100), 100)])
    let output = BufferListFixture(buffers: [(2, [], 40)])
    state.render(input: input.list, output: output.list)
    #expect(output.samples(0, count: 40) == [Float](repeating: 0.5, count: 40))
    #expect(output.guardSamples(0, capacity: 40) == [-9, -9, -9, -9])
    #expect(state.framesProcessed == 20)
  }

  @Test func shorterInputLeavesTheRestSilent() {
    let state = RealtimeTapState(initialGain: 1, target: 1, step: 0.001)
    let input = BufferListFixture(buffers: [(2, [Float](repeating: 0.5, count: 10), 10)])
    let output = BufferListFixture(buffers: [(2, [], 20)])
    state.render(input: input.list, output: output.list)
    #expect(output.samples(0, count: 10) == [Float](repeating: 0.5, count: 10))
    #expect(output.samples(0, count: 20).suffix(10).allSatisfy { $0 == 0 })
    #expect(output.guardSamples(0, capacity: 20) == [-9, -9, -9, -9])
    #expect(state.hasFault == false)
  }

  @Test func mismatchedChannelsCopyUnchangedAndRaiseTheKillSwitch() {
    let state = RealtimeTapState(initialGain: 0.2, target: 0.2, step: 0.001)
    let source = [Float](repeating: 0.5, count: 16)
    let input = BufferListFixture(buffers: [(1, source, 16)])
    let output = BufferListFixture(buffers: [(2, [], 16)])
    state.render(input: input.list, output: output.list)
    #expect(state.hasFault)
    // Doubt in the callback: the sound is passed through, never silenced.
    #expect(output.samples(0, count: 16) == source)
  }

  @Test func missingInputBufferRaisesTheKillSwitch() {
    let state = RealtimeTapState(initialGain: 1, target: 1, step: 0.001)
    let input = BufferListFixture(buffers: [(2, [1, 2], 2)])
    let output = BufferListFixture(buffers: [(2, [], 2), (2, [], 2)])
    state.render(input: input.list, output: output.list)
    #expect(state.hasFault)
    #expect(output.samples(0, count: 2) == [1, 2])
  }

  @Test func targetUpdatesAreSanitized() {
    let state = RealtimeTapState(initialGain: 1, target: 1, step: 0.001)
    state.setTarget(.nan)
    #expect(state.target == 1)
    state.setTarget(5)
    #expect(state.target == 1)
    state.setTarget(-3)
    #expect(state.target == 0)
    state.setTarget(0.4)
    #expect(state.target == 0.4)
  }
}
