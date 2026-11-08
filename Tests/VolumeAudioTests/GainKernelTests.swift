import Foundation
import Testing

@testable import VolumeAudio

/// Test signals. They exist only in test code (SPEC 12.8.2) and are never played.
enum TestSignal {
  static func sine(frames: Int, channels: Int, amplitude: Float = 0.8) -> [Float] {
    (0..<frames * channels).map { index in
      let frame = Double(index / channels)
      let phase: Double = 2 * Double.pi * 997 * frame / 48_000
      return amplitude * Float(sin(phase))
    }
  }

  static func noise(count: Int, seed: UInt64 = 42) -> [Float] {
    var state = seed
    return (0..<count).map { _ in
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
    }
  }
}

func run(
  _ input: [Float], channels: Int, target: Float, current: Float, step: Float = 0.001
) -> (output: [Float], ramp: GainRamp, signal: Bool) {
  var output = [Float](repeating: -7, count: input.count)
  var ramp = GainRamp(current: current, step: step)
  let signal = input.withUnsafeBufferPointer { source in
    output.withUnsafeMutableBufferPointer { destination in
      GainKernel.process(
        input: source.baseAddress ?? UnsafePointer(bitPattern: 4)!,
        output: destination.baseAddress ?? UnsafeMutablePointer(bitPattern: 4)!,
        frames: input.count / max(channels, 1), channels: channels, target: target, ramp: &ramp)
    }
  }
  return (output, ramp, signal)
}

@Suite("GainKernel (real kernel, no hardware)")
struct GainKernelTests {
  @Test(arguments: [1, 2, 6])
  func nullTestAtUnityIsBitExact(channels: Int) {
    let signals: [[Float]] = [
      TestSignal.sine(frames: 4800, channels: channels),
      TestSignal.noise(count: 4800 * channels),
      [Float](repeating: 0, count: 4800 * channels),
    ]
    for input in signals {
      let result = run(input, channels: channels, target: 1, current: 1)
      #expect(result.output.map(\.bitPattern) == input.map(\.bitPattern))
    }
  }

  @Test func unityKeepsSpecialValuesBitForBit() {
    let input: [Float] = [
      -0.0, .leastNonzeroMagnitude, .nan, .infinity, -1, 1, 0.5, Float(bitPattern: 0x1234),
    ]
    let result = run(input, channels: 2, target: 1, current: 1)
    #expect(result.output.map(\.bitPattern) == input.map(\.bitPattern))
  }

  @Test(arguments: [Float(0.5), 0.25, 0.1, 0.8])
  func steadyGainIsSampleTimesGain(gain: Float) {
    let input = TestSignal.noise(count: 2 * 4800)
    let result = run(input, channels: 2, target: gain, current: gain)
    for (out, source) in zip(result.output, input) { #expect(out == source * gain) }
  }

  @Test func steadyZeroWritesExactZeros() {
    let input: [Float] = [1, .nan, .infinity, -1]
    let result = run(input, channels: 2, target: 0, current: 0)
    #expect(result.output.allSatisfy { $0 == 0 })
  }

  @Test func rampHasNoStepsAndEndsExactlyOnTarget() {
    let step = GainKernel.rampStep(sampleRate: 48_000)
    let input = [Float](repeating: 1, count: 2 * 4800)
    let down = run(input, channels: 2, target: 0.3, current: 1, step: step)
    // With constant input of 1 the output is the gain itself.
    var previous: Float = 1
    for frame in 0..<4800 {
      let left = down.output[frame * 2]
      #expect(left == down.output[frame * 2 + 1])
      #expect(abs(left - previous) <= step * 1.0001)
      #expect(left <= previous)
      previous = left
    }
    #expect(down.ramp.current == 0.3)
    #expect(down.output.last == 0.3)
    let up = run(input, channels: 2, target: 0.9, current: 0.2, step: step)
    #expect(up.ramp.current == 0.9)
    #expect(zip(up.output, up.output.dropFirst()).allSatisfy { $0 <= $1 })
  }

  @Test func fullScaleRampLastsAboutTwentyMilliseconds() {
    let step = GainKernel.rampStep(sampleRate: 48_000)
    let frames = Int((0.020 * 48_000).rounded())
    #expect(abs(Float(frames) * step - 1) < 0.01)
    let input = [Float](repeating: 1, count: frames + 10)
    let result = run(input, channels: 1, target: 0, current: 1, step: step)
    #expect(result.output[frames - 1] < step * 2)
    #expect(result.output.last == 0)
  }

  @Test func rampContinuesAcrossBuffers() {
    let step: Float = 0.01
    let input = [Float](repeating: 1, count: 30)
    var ramp = GainRamp(current: 1, step: step)
    var joined: [Float] = []
    for _ in 0..<3 {
      var out = [Float](repeating: 0, count: 10)
      input.withUnsafeBufferPointer { source in
        out.withUnsafeMutableBufferPointer { destination in
          if let s = source.baseAddress, let d = destination.baseAddress {
            GainKernel.process(
              input: s, output: d, frames: 10, channels: 1, target: 0.5, ramp: &ramp)
          }
        }
      }
      joined += out
    }
    let whole = run(input, channels: 1, target: 0.5, current: 1, step: step)
    #expect(joined == whole.output)
  }

  @Test func targetChangeMidRampIsContinuous() {
    let input = [Float](repeating: 1, count: 100)
    var ramp = GainRamp(current: 1, step: 0.01)
    var first = [Float](repeating: 0, count: 50)
    var second = [Float](repeating: 0, count: 50)
    input.withUnsafeBufferPointer { source in
      first.withUnsafeMutableBufferPointer { destination in
        if let s = source.baseAddress, let d = destination.baseAddress {
          GainKernel.process(input: s, output: d, frames: 50, channels: 1, target: 0.2, ramp: &ramp)
        }
      }
      second.withUnsafeMutableBufferPointer { destination in
        if let s = source.baseAddress, let d = destination.baseAddress {
          GainKernel.process(input: s, output: d, frames: 50, channels: 1, target: 0.9, ramp: &ramp)
        }
      }
    }
    #expect(abs(second[0] - first[49]) <= 0.0101)
    #expect(ramp.current == 0.9)
  }

  @Test func emptyAndTinyBuffers() {
    #expect(run([], channels: 2, target: 0.5, current: 1).signal == false)
    let one = run([0.5, -0.5], channels: 2, target: 1, current: 1)
    #expect(one.output == [0.5, -0.5])
    var ramp = GainRamp(current: 0.7, step: 0.1)
    let none = GainKernel.process(
      input: UnsafePointer(bitPattern: 4)!, output: UnsafeMutablePointer(bitPattern: 4)!,
      frames: 0, channels: 2, target: 0.1, ramp: &ramp)
    #expect(none == false)
    #expect(ramp.current == 0.7)
    let zeroChannels = run([1, 2], channels: 0, target: 0.5, current: 0.5)
    #expect(zeroChannels.signal == false)
  }

  @Test func signalFlagIsBinaryAndIndependentOfGain() {
    #expect(run([0, 0, 0, 0], channels: 2, target: 1, current: 1).signal == false)
    #expect(run([0, -0.0, 0, 0], channels: 2, target: 1, current: 1).signal == false)
    #expect(run([0, 0, 0, 1e-30], channels: 2, target: 0, current: 0).signal == true)
  }

  @Test func nanTargetKeepsTheCurrentGain() {
    let result = run([1, 1], channels: 1, target: .nan, current: 0.5)
    #expect(result.output == [0.5, 0.5])
    #expect(result.ramp.current == 0.5)
  }

  @Test func zeroStepJumpsToTargetInsteadOfStalling() {
    let result = run([1, 1, 1], channels: 1, target: 0.25, current: 1, step: 0)
    #expect(result.output == [0.25, 0.25, 0.25])
  }

  @Test func rampStepIsSafeForNonsenseRates() {
    #expect(GainKernel.rampStep(sampleRate: 0) > 0)
    #expect(GainKernel.rampStep(sampleRate: .nan) > 0)
    #expect(GainKernel.rampStep(sampleRate: 96_000) < GainKernel.rampStep(sampleRate: 48_000))
  }
}

/// No clicks: a large gain drop never changes the gain by more than one ramp step per frame,
/// across buffer boundaries and when the target changes in the middle of a ramp (SPEC 12.8.2).
@Suite("Gain ramp continuity")
struct GainRampContinuityTests {
  private let step = GainKernel.rampStep(sampleRate: 48_000)

  /// Runs `targets` (one per buffer, with the buffer sizes in `sizes`) over a constant input
  /// of 1, so the output is the gain itself, and returns every frame's gain.
  private func gains(start: Float, sizes: [Int], targets: [Float]) -> [Float] {
    var ramp = GainRamp(current: start, step: step)
    var all: [Float] = []
    for (size, target) in zip(sizes, targets) {
      let input = [Float](repeating: 1, count: size)
      var output = [Float](repeating: 0, count: size)
      input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
          _ = GainKernel.process(
            input: source.baseAddress!, output: destination.baseAddress!, frames: size,
            channels: 1, target: target, ramp: &ramp)
        }
      }
      all += output
    }
    return all
  }

  private func maxJump(_ values: [Float], from first: Float) -> Float {
    var previous = first
    var worst: Float = 0
    for value in values {
      worst = max(worst, abs(value - previous))
      previous = value
    }
    return worst
  }

  @Test func dropFromFullTo1PercentIsContinuousAcrossSmallBuffers() {
    let out = gains(
      start: 1, sizes: Array(repeating: 64, count: 30), targets: Array(repeating: 0.01, count: 30))
    #expect(maxJump(out, from: 1) <= step * 1.001)
    #expect(out.last == 0.01)
  }

  @Test func targetChangingMidRampStaysContinuous() {
    let sizes = [100, 37, 256, 5, 480, 64, 64]
    let targets: [Float] = [0.01, 0.9, 0.0, 0.5, 0.01, 1, 0.2]
    let out = gains(start: 1, sizes: sizes, targets: targets)
    #expect(maxJump(out, from: 1) <= step * 1.001)
  }

  @Test func aTapThatStartsAtItsTargetHasNoJumpAtItsFirstSample() {
    let out = gains(start: 0.1, sizes: [128], targets: [0.1])
    #expect(maxJump(out, from: 0.1) == 0)
  }
}
