import Synchronization
import Testing
import VolumeCore

@testable import VolumeSystem

private final class ScriptedProbe: AudioAccessProbe {
  private let verdict = Mutex(AudioAccessVerdict.indeterminate)
  func set(_ value: AudioAccessVerdict) { verdict.withLock { $0 = value } }
  func probe() -> Bool { true }
  func verify(idleTargetAllowed: Bool) async -> AudioAccessVerdict { verdict.withLock { $0 } }
}

/// QA M4: the popover's `PermissionMonitor` on top of the real `AudioPermissionService`.
@MainActor
@Suite("QA M4: permission flow end to end (fake probe)", .timeLimit(.minutes(1)))
struct QAM4PermissionFlowTests {
  @Test func deniedIsNotCancelledByAnIndeterminateRecheck() async {
    let probe = ScriptedProbe()
    let monitor = PermissionMonitor(
      service: AudioPermissionService(probe: probe, openURL: { _ in }), onGranted: {})
    probe.set(.denied)
    await monitor.refresh(onlyIfDenied: false)
    #expect(monitor.status == .denied)
    probe.set(.indeterminate)
    await monitor.refresh(onlyIfDenied: true)
    #expect(
      monitor.status == .denied, "nothing playing must not hide the notice nor invent a grant")
  }

  @Test func indeterminateNeverBecomesDenied() async {
    let probe = ScriptedProbe()
    let monitor = PermissionMonitor(
      service: AudioPermissionService(probe: probe, openURL: { _ in }), onGranted: {})
    await monitor.refresh(onlyIfDenied: false)
    #expect(monitor.status != .denied)
    #expect(monitor.status == .notDetermined)
  }

  @Test func grantedLaterRetriesOnceAndLeavesTheNotice() async {
    let probe = ScriptedProbe()
    var retries = 0
    let monitor = PermissionMonitor(
      service: AudioPermissionService(probe: probe, openURL: { _ in }),
      onGranted: { retries += 1 })
    probe.set(.denied)
    await monitor.refresh(onlyIfDenied: false)
    probe.set(.granted)
    await monitor.refresh(onlyIfDenied: true)
    await monitor.refresh(onlyIfDenied: true)
    #expect(monitor.status != .denied)
    #expect(retries == 1)
  }

  @Test func overlappingChecksRunOneProbe() async {
    let probe = ScriptedProbe()
    let monitor = PermissionMonitor(
      service: AudioPermissionService(probe: probe, openURL: { _ in }), onGranted: {})
    probe.set(.denied)
    async let first = monitor.refresh(onlyIfDenied: false)
    async let second = monitor.refresh(onlyIfDenied: false)
    let results = await [first, second]
    #expect(monitor.status == .denied)
    #expect(results.contains(nil), "the overlapping call ran no check")
    #expect(results.contains(.denied))
  }
}
