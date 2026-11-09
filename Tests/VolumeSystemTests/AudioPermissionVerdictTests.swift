import Foundation
import Synchronization
import Testing
import VolumeCore

@testable import VolumeSystem

private final class VerdictProbe: AudioAccessProbe {
  private let verdict = Mutex(AudioAccessVerdict.indeterminate)
  func set(_ value: AudioAccessVerdict) { verdict.withLock { $0 = value } }
  func probe() -> Bool { true }
  func verify(idleTargetAllowed: Bool) async -> AudioAccessVerdict { verdict.withLock { $0 } }
}

@Suite("AudioPermissionService with signal verdicts (SPEC 4.6)", .timeLimit(.minutes(1)))
struct AudioPermissionVerdictTests {
  @Test func verdictsMapToStatuses() async {
    let probe = VerdictProbe()
    let service = AudioPermissionService(probe: probe)
    probe.set(.denied)
    #expect(await service.request() == .denied)
    probe.set(.granted)
    #expect(await service.request() == .granted)
  }

  /// The service reports each check; the monitor keeps what was known (S41-B4).
  @Test func indeterminateIsReportedAndTheMonitorKeepsWhatWasKnown() async {
    let probe = VerdictProbe()
    let service = AudioPermissionService(probe: probe)
    #expect(await service.request() == .notDetermined)
    probe.set(.indeterminate)
    #expect(await service.request() == .notDetermined)
    let monitor = await PermissionMonitor(service: service)
    probe.set(.denied)
    #expect(await monitor.refresh(onlyIfDenied: false) == .denied)
    probe.set(.indeterminate)
    #expect(await monitor.refresh(onlyIfDenied: false) == .notDetermined)
    #expect(await monitor.status == .denied)
  }

  @Test func probesWithoutAVerifyOverrideStillWork() async {
    struct Legacy: AudioAccessProbe {
      let result: Bool
      func probe() -> Bool { result }
    }
    #expect(await Legacy(result: true).verify(idleTargetAllowed: false) == .granted)
    #expect(await Legacy(result: false).verify(idleTargetAllowed: true) == .denied)
  }
}
