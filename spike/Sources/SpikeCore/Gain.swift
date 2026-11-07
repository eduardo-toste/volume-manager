/// Gain math shared by the control path and the real-time IOProc.
public enum Gain {
    /// Perceptual curve: `gain = v^2`, input clamped to 0...1 (NaN -> 1, the safe "no change" value).
    public static func perceptual(_ volume: Float) -> Float {
        guard !volume.isNaN else { return 1 }
        let v = min(max(volume, 0), 1)
        return v * v
    }

    /// Per-frame gain increment so a full 0->1 move takes `rampSeconds`.
    public static func rampStep(sampleRate: Double, rampSeconds: Double = 0.020) -> Float {
        let frames = max(sampleRate * rampSeconds, 1)
        return Float(1.0 / frames)
    }

    /// Moves `current` toward `target` by at most `step`. Allocation-free; safe in the IOProc.
    @inlinable
    @inline(__always)
    public static func next(current: Float, target: Float, step: Float) -> Float {
        if current < target { return min(current + step, target) }
        if current > target { return max(current - step, target) }
        return current
    }
}
