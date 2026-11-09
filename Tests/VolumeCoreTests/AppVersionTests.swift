import Testing

@testable import VolumeCore

@Suite("AppVersion", .timeLimit(.minutes(1)))
struct AppVersionTests {
  @Test func parsesValidVersion() throws {
    let version = try #require(AppVersion("1.2.3"))
    #expect(version == AppVersion(major: 1, minor: 2, patch: 3))
    #expect(version.description == "1.2.3")
  }

  @Test(arguments: ["", "1", "1.2", "1.2.3.4", "a.b.c", "1.-2.3", "1..3", "1.2.3 ", "١.٢.٣"])
  func rejectsInvalidVersion(text: String) {
    #expect(AppVersion(text) == nil)
  }

  @Test func ordersByComponents() throws {
    let low = try #require(AppVersion("1.9.9"))
    let high = try #require(AppVersion("1.10.0"))
    #expect(low < high)
  }

  @Test func identityMatchesSpec() {
    #expect(AppIdentity.bundleIdentifier == "com.volumemanager.app")
    #expect(AppIdentity.logSubsystem == AppIdentity.bundleIdentifier)
  }
}
