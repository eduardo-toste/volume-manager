import Testing

@testable import VolumeAudio

@Suite("Access probe with nothing playing", .timeLimit(.minutes(1)))
struct AccessProbeIdleTests {
  /// With the test seam and no candidates the probe concludes nothing and never reaches a
  /// process of the user (the real idle listening is covered by the hardware test).
  @Test func noCandidatesIsIndeterminateWithoutTouchingAnyProcess() async {
    let probe = SystemAudioAccessProbe(catalog: ProcessCatalog(), candidates: { [] })
    #expect(await probe.verify(idleTargetAllowed: true) == .indeterminate)
    #expect(await probe.verify(idleTargetAllowed: false) == .indeterminate)
  }
}
