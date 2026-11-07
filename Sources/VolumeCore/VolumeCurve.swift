/// Maps the slider position to the gain applied to samples.
///
/// The curve is `gain = volume²`: perceptual (quieter positions change loudness gently), exact
/// at the ends (0 maps to 0, 1 maps to exactly 1, so a 100% slider is bit-transparent) and
/// strictly increasing. Chosen over a dB mapping because it needs no special case for silence.
public enum VolumeCurve {
  /// Makes any input a usable volume in `0...1`. NaN becomes 1 (never mute by accident);
  /// infinities and out-of-range values are clamped.
  public static func clampedVolume(_ volume: Double) -> Double {
    guard !volume.isNaN else { return 1 }
    return min(max(volume, 0), 1)
  }

  /// Gain (multiplier of the samples, `0...1`) for a slider position.
  public static func gain(forVolume volume: Double) -> Float {
    let clamped = clampedVolume(volume)
    return Float(clamped * clamped)
  }
}
