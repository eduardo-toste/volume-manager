import Foundation
import Synchronization
import Testing
import VolumeCore

@testable import VolumeSystem

private final class VerdictProbe: AudioAccessProbe {
  private let verdict = Mutex(AudioAccessVerdict.indeterminate)
  func set(_ value: AudioAccessVerdict) { verdict.withLock { $0 = value } }
  func probe() -> Bool { true }
  func verify() async -> AudioAccessVerdict { verdict.withLock { $0 } }
}

@Suite("AudioPermissionService with signal verdicts (SPEC 4.6)")
struct AudioPermissionVerdictTests {
  @Test func verdictsMapToStatuses() async {
    let probe = VerdictProbe()
    let service = AudioPermissionService(probe: probe)
    probe.set(.denied)
    #expect(await service.request() == .denied)
    probe.set(.granted)
    #expect(await service.request() == .granted)
  }

  @Test func indeterminateKeepsWhatWasKnown() async {
    let probe = VerdictProbe()
    let service = AudioPermissionService(probe: probe)
    #expect(await service.request() == .notDetermined)
    probe.set(.denied)
    _ = await service.request()
    probe.set(.indeterminate)
    #expect(await service.request() == .denied)
  }

  @Test func probesWithoutAVerifyOverrideStillWork() async {
    struct Legacy: AudioAccessProbe {
      let result: Bool
      func probe() -> Bool { result }
    }
    #expect(await Legacy(result: true).verify() == .granted)
    #expect(await Legacy(result: false).verify() == .denied)
  }
}
