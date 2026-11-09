import Testing

@testable import VolumeAudio

/// Security audit M4.1b: a format change of the same output is now replaced gracefully, so the
/// old tap keeps rendering for the cross-fade after the format already changed. The IOProc must
/// stay in bounds whatever buffers it now receives.
@Suite("Security M4.1b: old tap rendering after a format change")
struct SecurityM41bRenderTests {
  /// Output goes from stereo to mono while the tap still delivers stereo: no overrun, the kill
  /// switch is raised, and the samples are copied unchanged (unity, not the fade) until the old
  /// tap is stopped at the end of the cross-fade.
  @Test func channelChangeDuringTheFadeStaysInBoundsAndCopiesUnchanged() {
    let state = RealtimeTapState(initialGain: 0.2, target: 0.2, step: 0.001)
    state.setTarget(0)  // fading out next to the new tap
    let source = [Float](repeating: 0.5, count: 64)
    let input = BufferListFixture(buffers: [(2, source, 64)])
    let output = BufferListFixture(buffers: [(1, [], 32)])
    state.render(input: input.list, output: output.list)
    #expect(output.guardSamples(0, capacity: 32) == [-9, -9, -9, -9], "no overrun")
    #expect(state.hasFault)
    #expect(output.samples(0, count: 32).allSatisfy { $0 == 0.5 }, "unity copy, not faded")
  }

  /// Buffers shrink or grow (new rate, new IO size) while fading: never past either capacity.
  @Test func bufferSizeChangesDuringTheFadeStayInBounds() {
    for (inCap, outCap) in [(64, 16), (16, 64), (1, 64), (64, 1), (3, 5)] {
      let state = RealtimeTapState(initialGain: 0.6, target: 0, step: 0.01)
      let input = BufferListFixture(
        buffers: [(2, [Float](repeating: 1, count: inCap), inCap)])
      let output = BufferListFixture(buffers: [(2, [], outCap)])
      state.render(input: input.list, output: output.list)
      #expect(output.guardSamples(0, capacity: outCap) == [-9, -9, -9, -9], "\(inCap)/\(outCap)")
      #expect(output.samples(0, count: outCap).allSatisfy { $0 <= 0.6 }, "never louder")
    }
  }
}
