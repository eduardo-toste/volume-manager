import CoreAudio
import Foundation
import Testing
import VolumeCore

@testable import VolumeAudio

/// Adversarial checks of the M2.1 fixes (security review, docs/reports/m2.1-security.md).
@Suite("Security M2.1: restart window and UID lookup", .timeLimit(.minutes(1)))
struct SecurityM21Tests {
  private func desired() -> DesiredAppAudio {
    DesiredAppAudio(
      app: ControlledApp(id: "app", bundleID: "app", pids: [10]), gain: 0.5, muted: false,
      targetDeviceUID: "SPK")
  }

  /// Finding S21-B1: `coreaudiod` restarted, and a `reconcile` built a tap with the new (valid)
  /// IDs before the restart event reached the controller. The event must not orphan that tap:
  /// it is stopped (the real `stop()` checks each object's identity first, so dead or foreign
  /// IDs are left alone) and the tap is rebuilt.
  @Test func aTapBuiltAfterTheRestartButBeforeTheEventIsStoppedNotOrphaned() async {
    let engine = FakeTapEngine()
    engine.setDevice("SPK")
    let controller = CoreAudioAppController(
      engine: engine, clock: FakeClock(), policy: WatchdogPolicy())
    // The restart already happened; this tap uses the new, valid objects.
    await controller.reconcile(desired: [desired()])
    let builtAfterRestart = engine.created[0]
    engine.emit(.serviceRestarted)
    #expect(await eventually { engine.created.count == 2 })
    await controller.restoreAll()
    #expect(builtAfterRestart.stopCalls == 1)
    #expect(engine.live.isEmpty)
    #expect(engine.created[1].stopCalls >= 1)
  }

  /// Finding S21-B3 (residual of B-2): when the real device's raw UID is changed by sanitizing,
  /// another device whose raw UID equals the sanitized text wins by exact match.
  @Test func anExactLookalikeBeatsARealDeviceWhoseUIDNeededSanitizing() {
    let real = DeviceUIDEntry(id: 1, rawUID: "Speaker\u{200B}")
    let lookalike = DeviceUIDEntry(id: 2, rawUID: "Speaker")
    #expect(TextSanitizer.clean(real.rawUID) == "Speaker")
    #expect(DeviceCatalog.resolve(uid: "Speaker", in: [real, lookalike]) == lookalike)
  }
}
