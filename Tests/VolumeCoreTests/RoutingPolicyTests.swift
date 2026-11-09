import Testing

@testable import VolumeCore

@Suite("RoutingPolicy", .timeLimit(.minutes(1)))
struct RoutingPolicyTests {
  let speakers = OutputDevice(id: 1, uid: "speakers", name: "Speakers", kind: .builtIn)
  let airpods = OutputDevice(id: 2, uid: "airpods", name: "AirPods", kind: .bluetooth)

  @Test func usesPreferredDeviceWhenPresent() {
    let route = RoutingPolicy.resolve(
      preferredUID: "airpods", devices: [speakers, airpods], defaultUID: "speakers")
    #expect(route == EffectiveRoute(deviceUID: "airpods", usesSystemDefault: false))
  }

  @Test func fallsBackToDefaultWhenPreferredIsMissing() {
    let route = RoutingPolicy.resolve(
      preferredUID: "airpods", devices: [speakers], defaultUID: "speakers")
    #expect(route == EffectiveRoute(deviceUID: "speakers", usesSystemDefault: true))
    #expect(RoutingPolicy.isPreferredDeviceMissing(preferredUID: "airpods", devices: [speakers]))
  }

  @Test func routeComesBackWhenTheDeviceReappears() {
    let gone = RoutingPolicy.resolve(
      preferredUID: "airpods", devices: [speakers], defaultUID: "speakers")
    let back = RoutingPolicy.resolve(
      preferredUID: "airpods", devices: [speakers, airpods], defaultUID: "speakers")
    #expect(gone?.usesSystemDefault == true)
    #expect(back?.deviceUID == "airpods")
  }

  @Test func preferredEqualToDefaultCountsAsDefault() {
    let route = RoutingPolicy.resolve(
      preferredUID: "speakers", devices: [speakers], defaultUID: "speakers")
    #expect(route?.usesSystemDefault == true)
  }

  @Test func noPreferenceFollowsTheDefault() {
    let route = RoutingPolicy.resolve(
      preferredUID: nil, devices: [speakers], defaultUID: "speakers")
    #expect(route == EffectiveRoute(deviceUID: "speakers", usesSystemDefault: true))
    #expect(!RoutingPolicy.isPreferredDeviceMissing(preferredUID: nil, devices: []))
  }

  @Test func unknownDefaultYieldsNoRouteUnlessPreferredExists() {
    #expect(RoutingPolicy.resolve(preferredUID: nil, devices: [], defaultUID: nil) == nil)
    #expect(RoutingPolicy.resolve(preferredUID: "airpods", devices: [], defaultUID: nil) == nil)
    let route = RoutingPolicy.resolve(preferredUID: "airpods", devices: [airpods], defaultUID: nil)
    #expect(route?.deviceUID == "airpods")
  }
}
