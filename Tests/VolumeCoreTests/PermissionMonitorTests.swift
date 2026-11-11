import Synchronization
import Testing

@testable import VolumeCore

@MainActor
@Suite("PermissionMonitor", .timeLimit(.minutes(1)))
struct PermissionMonitorTests {
  private let service = ScriptedPermissionService()

  @Test func startsUndecidedAndNeverDenied() {
    let monitor = PermissionMonitor(service: service, onGranted: {})
    #expect(monitor.status == .notDetermined)
    #expect(monitor.status != .denied)
  }

  @Test func openingThePopoverDoesNotCheckWhileUndecidedOrGranted() async {
    let monitor = PermissionMonitor(service: service, onGranted: {})
    await monitor.refresh(onlyIfDenied: true)
    #expect(service.requests == 0)
    service.answer = .granted
    await monitor.refresh(onlyIfDenied: false)
    await monitor.refresh(onlyIfDenied: true)
    #expect(service.requests == 1)
  }

  @Test func silenceThatTheCheckConfirmsMarksDenied() async {
    let monitor = PermissionMonitor(service: service, onGranted: {})
    service.answer = .denied
    await monitor.refresh(onlyIfDenied: false)
    #expect(monitor.status == .denied)
  }

  @Test func indeterminateCheckIsNotDenied() async {
    let monitor = PermissionMonitor(service: service, onGranted: {})
    service.answer = .notDetermined
    await monitor.refresh(onlyIfDenied: false)
    #expect(monitor.status != .denied)
  }

  @Test func grantAfterDenialRunsOnGrantedOnce() async {
    var count = 0
    let monitor = PermissionMonitor(service: service, onGranted: { count += 1 })
    service.answer = .denied
    await monitor.refresh(onlyIfDenied: false)
    service.answer = .granted
    await monitor.refresh(onlyIfDenied: true)
    await monitor.refresh(onlyIfDenied: true)
    #expect(monitor.status == .granted)
    #expect(count == 1)
  }

  @Test func stillDeniedKeepsCheckingOnEachOpen() async {
    let monitor = PermissionMonitor(service: service, onGranted: {})
    service.answer = .denied
    await monitor.refresh(onlyIfDenied: false)
    await monitor.refresh(onlyIfDenied: true)
    #expect(service.requests == 2)
    #expect(monitor.status == .denied)
  }

  @Test func opensThePrivacyPane() {
    let monitor = PermissionMonitor(service: service, onGranted: {})
    monitor.openPrivacySettings()
    #expect(service.opened == 1)
  }
}
