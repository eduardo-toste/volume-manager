import Testing

@testable import VolumeSystem

@Suite("VolumeSystem")
struct VolumeSystemModuleTests {
  @Test func logCategoryIsStable() {
    #expect(VolumeSystemModule.logCategory == "system")
  }
}
