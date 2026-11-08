import Testing
import VolumeCore

@testable import VolumeAudio

/// Security audit M4.1: adversarial proofs for the silence guard and the reconcile planner.
/// They document current behaviour that the audit report classifies; they pass today.
@Suite("Security M4.1")
struct SecurityM41Tests {
  private let policy = WatchdogPolicy()

  /// S41-A1: after one `.silent` report answered "granted", the latch never reports again
  /// while only zeros arrive, however long. If the permission is revoked in that window, the
  /// tap (`mutedWhenTapped`) keeps the app mute and nothing asks for a new check.
  @Test func latchedSilenceNeverAsksAgainEvenAfterTenMinutesOfZeros() {
    var health = SessionHealth(policy: policy)
    var frames: UInt64 = 0
    var reports = 0
    // 10 minutes at one tick every 500 ms.
    for _ in 0..<1_200 {
      frames += 24_000
      if health.evaluate(frames: frames, sawSignal: false, appRunning: true, fault: false)
        == .silent
      {
        reports += 1
      }
    }
    #expect(reports == 1)
  }

  /// S41-A1 at controller level: the tap stays alive and only one event is emitted.
  @Test func controllerKeepsALatchedSilentTapAndEmitsOnce() async {
    let engine = FakeTapEngine()
    let clock = FakeClock()
    engine.setDevice("SPK")
    let controller = CoreAudioAppController(engine: engine, clock: clock, policy: policy)
    let failures = controller.failures()
    let app = ControlledApp(id: "browser", bundleID: "browser", pids: [10])
    await controller.reconcile(
      desired: [DesiredAppAudio(app: app, gain: 1, muted: false, targetDeviceUID: "SPK")])
    let handle = engine.created[0]
    for _ in 0..<120 {
      handle.deliver(frames: 24_000, signal: false)
      _ = await eventually { clock.sleeperCount > 0 }
      clock.advance(by: .milliseconds(500))
      for _ in 0..<50 { await Task.yield() }
    }
    #expect(handle.isStopped == false)
    var iterator = failures.makeAsyncIterator()
    #expect(await iterator.next() == AppAudioFailure(appID: "browser", reason: .onlySilence))
    await controller.reconcile(desired: [])
  }

  /// S41-B1: `.update` for "only processes gone" keeps the old key, so a PID that comes back
  /// (reused by a new process of the same app) is treated as already covered: no new tap.
  @Test func pidThatComesBackAfterAnUpdateIsNotRetapped() async {
    let engine = FakeTapEngine()
    engine.setDevice("SPK")
    let controller = CoreAudioAppController(
      engine: engine, clock: FakeClock(), policy: policy)
    func want(_ pids: [Int32]) -> [DesiredAppAudio] {
      [
        DesiredAppAudio(
          app: ControlledApp(id: "app", bundleID: "app", pids: pids), gain: 0.3, muted: false,
          targetDeviceUID: "SPK")
      ]
    }
    await controller.reconcile(desired: want([10, 11]))
    await controller.reconcile(desired: want([10]))
    await controller.reconcile(desired: want([10, 11]))
    #expect(engine.created.count == 1, "the process now behind PID 11 is not in any tap")
    await controller.reconcile(desired: [])
  }

  /// S41-M1: the real probe's decision for "a process plays, only zeros arrived" is denied,
  /// which is also what a browser with an open silent stream (and nothing else playing) gives.
  @Test func silentStreamAsTheOnlyPlayerIsDecidedAsDenied() {
    #expect(AccessDecision.verdict(sawSignal: false, stillPlaying: true) == .denied)
  }
}
