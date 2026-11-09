import Testing

@testable import VolumeCore

@Suite("VolumeCurve", .timeLimit(.minutes(1)))
struct VolumeCurveTests {
  @Test func endpointsAreExact() {
    #expect(VolumeCurve.gain(forVolume: 0) == 0)
    #expect(VolumeCurve.gain(forVolume: 1) == 1)
  }

  @Test func isMonotonicallyIncreasing() {
    var previous: Float = -1
    for step in 0...1000 {
      let gain = VolumeCurve.gain(forVolume: Double(step) / 1000)
      #expect(gain >= previous)
      #expect(gain >= 0 && gain <= 1)
      previous = gain
    }
  }

  @Test func isPerceptualNotLinear() {
    #expect(VolumeCurve.gain(forVolume: 0.5) == 0.25)
  }

  @Test(arguments: [Double.nan, .infinity, -.infinity, -3, 7, 1.0000001, -0.0000001])
  func hostileInputsAreClampedSafely(volume: Double) {
    let gain = VolumeCurve.gain(forVolume: volume)
    #expect(gain.isFinite && gain >= 0 && gain <= 1)
  }

  @Test func nanNeverMutes() {
    #expect(VolumeCurve.clampedVolume(.nan) == 1)
    #expect(VolumeCurve.gain(forVolume: .nan) == 1)
    #expect(VolumeCurve.clampedVolume(.infinity) == 1)
    #expect(VolumeCurve.clampedVolume(-.infinity) == 0)
    #expect(VolumeCurve.clampedVolume(-2) == 0)
    #expect(VolumeCurve.clampedVolume(0.4) == 0.4)
  }
}
