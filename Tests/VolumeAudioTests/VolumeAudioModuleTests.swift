import Testing

@testable import VolumeAudio

@Suite("VolumeAudio", .timeLimit(.minutes(1)))
struct VolumeAudioModuleTests {
  @Test func logCategoryIsStable() {
    #expect(VolumeAudioModule.logCategory == "audio")
  }

  @Test(.tags(.audioHardware), .requiresAudioHardware)
  func hardwareGateOnlyRunsWhenRequested() {
    // Placeholder for Core Audio integration tests (M2+); must stay silent (SPEC 12.8.1).
    #expect(Bool(true))
  }
}
