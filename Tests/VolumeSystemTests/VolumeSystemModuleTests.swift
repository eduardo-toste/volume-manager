import Testing

@testable import VolumeSystem

@Suite("VolumeSystem", .timeLimit(.minutes(1)))
struct VolumeSystemModuleTests {
  @Test func logCategoryIsStable() {
    #expect(VolumeSystemModule.logCategory == "system")
  }
}
