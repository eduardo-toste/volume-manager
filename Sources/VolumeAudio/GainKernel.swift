/// Ramp position of the gain, owned by the audio thread.
struct GainRamp: Sendable, Equatable {
  /// Gain applied to the last sample processed.
  var current: Float
  /// Largest change of gain per frame.
  var step: Float
}

/// The only processing the app does to audio: `sample × gain` in Float32, with a short ramp
/// (SPEC 4.2, 4.7). Pure code on raw pointers: no allocation, locks, logging or ARC, so it is
/// safe on the real-time thread and testable without hardware.
enum GainKernel {
  /// Length of a full-scale gain change.
  static let rampDuration = 0.020

  /// Gain change per frame so that 0 to 1 takes `rampDuration` at `sampleRate`.
  static func rampStep(sampleRate: Double) -> Float {
    guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 768_000 else {
      return Float(1 / (rampDuration * 48_000))
    }
    return Float(1 / (rampDuration * sampleRate))
  }

  /// Writes `input × gain` into `output` for `frames` interleaved frames of `channels` samples.
  ///
  /// The gain moves from `ramp.current` towards `target` by at most `ramp.step` per frame and
  /// stops exactly on `target`; `ramp.current` is updated. At a steady gain of 1 the samples
  /// are copied bit for bit; at a steady 0 the output is written as zeros. `input` and
  /// `output` must not overlap.
  ///
  /// - Returns: `true` if any input sample was not an absolute zero (used by the silence
  ///   guard; nothing about the content is kept).
  @discardableResult
  static func process(
    input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frames: Int, channels: Int,
    target: Float, ramp: inout GainRamp
  ) -> Bool {
    guard frames > 0, channels > 0 else { return false }
    let total = frames &* channels
    var signal: UInt32 = 0
    for index in 0..<total { signal |= input[index].bitPattern & 0x7FFF_FFFF }

    let goal = target.isNaN ? ramp.current : target
    var gain = ramp.current
    let step = ramp.step > 0 ? ramp.step : Float.infinity
    var frame = 0
    while frame < frames && gain != goal {
      gain = gain < goal ? min(gain + step, goal) : max(gain - step, goal)
      let base = frame &* channels
      for channel in 0..<channels { output[base &+ channel] = input[base &+ channel] * gain }
      frame &+= 1
    }
    let done = frame &* channels
    if done < total {
      let rest = total &- done
      if gain == 1 {
        (output + done).update(from: input + done, count: rest)
      } else if gain == 0 {
        (output + done).update(repeating: 0, count: rest)
      } else {
        for index in done..<total { output[index] = input[index] * gain }
      }
    }
    ramp.current = gain
    return signal != 0
  }
}
