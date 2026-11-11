import Testing
import VolumeCore

@testable import VolumeAudio

/// Security audit M4.1: adversarial proofs for the silence guard and the reconcile planner,
/// updated in round 6 to prove the fixes.
@Suite("Security M4.1", .timeLimit(.minutes(1)))
struct SecurityM41Tests {
  private let policy = WatchdogPolicy()

  /// S41-A1 (fixed): a "granted" is never trusted forever. While only zeros arrive, after each
  /// check the silence is reported again within 30 s (plus the tick), never later.
  @Test func silenceIsCheckedAgainAtMostEveryThirtySecondsWhileItLasts() {
    var health = SessionHealth(policy: policy)
    var frames: UInt64 = 0
    var reportTicks: [Int] = []
    // 10 minutes at one tick every 500 ms.
    for tick in 0..<1_200 {
      frames += 24_000
      if health.evaluate(frames: frames, sawSignal: false, appRunning: true, fault: false)
        == .silent
      {
        reportTicks.append(tick)
        health.retryLater()  // the check ran (any result)
      }
    }
    let gaps = zip(reportTicks.dropFirst(), reportTicks).map { $0 - $1 }
    let silence = policy.ticks(for: policy.silenceLimit)
    let retry = policy.ticks(for: policy.recheckAfter)
    #expect(reportTicks.first == silence - 1, "first check after 120 s (M5.3)")
    #expect(gaps.allSatisfy { $0 == retry }, "every 30 s")
    #expect(reportTicks.count == 1 + (1_199 - (silence - 1)) / retry)
  }

  /// S41-A1 at controller level: silence checked as granted, then the permission is revoked
  /// (the tap keeps giving zeros): within ~32 s a new check is asked; the store's "denied"
  /// then removes every tap (`SecurityM41StoreTests`).
  @Test func aGrantedSilenceIsAskedAgainWithinThirtyTwoSeconds() async {
    let engine = FakeTapEngine()
    let clock = FakeClock()
    engine.setDevice("SPK")
    let controller = CoreAudioAppController(engine: engine, clock: clock, policy: policy)
    let failures = controller.failures()
    let app = ControlledApp(id: "browser", bundleID: "browser", pids: [10])
    await controller.reconcile(
      desired: [DesiredAppAudio(app: app, gain: 1, muted: false, targetDeviceUID: "SPK")])
    let handle = engine.created[0]
    var iterator = failures.makeAsyncIterator()
    func silentTicks(_ count: Int) async {
      for _ in 0..<count {
        handle.deliver(frames: 24_000, signal: false)
        #expect(await eventually { clock.sleeperCount > 0 })
        clock.advance(by: .milliseconds(500))
        for _ in 0..<50 { await Task.yield() }
      }
    }
    await silentTicks(policy.ticks(for: policy.silenceLimit))
    #expect(await iterator.next() == AppAudioFailure(appID: "browser", reason: .onlySilence))
    await controller.silenceChecked(appID: "browser")  // answered "granted"
    await silentTicks(64)  // 32 s
    #expect(await iterator.next() == AppAudioFailure(appID: "browser", reason: .stillSilent))
    #expect(handle.isStopped == false)
    await controller.reconcile(desired: [])
  }

  /// S41-M1 (a): real sound on another tap proves the permission works: a silent tap then asks
  /// for no check at all.
  @Test func silenceBesideATapWithSoundAsksForNoCheck() async {
    let engine = FakeTapEngine()
    let clock = FakeClock()
    engine.setDevice("SPK")
    let controller = CoreAudioAppController(engine: engine, clock: clock, policy: policy)
    let failures = controller.failures()
    func item(_ id: String, _ pid: Int32) -> DesiredAppAudio {
      DesiredAppAudio(
        app: ControlledApp(id: id, bundleID: id, pids: [pid]), gain: 1, muted: false,
        targetDeviceUID: "SPK")
    }
    await controller.reconcile(desired: [item("browser", 10), item("music", 20)])
    let browser = engine.created[0]
    let music = engine.created[1]
    for _ in 0..<20 {
      browser.deliver(frames: 24_000, signal: false)
      music.deliver(frames: 24_000, signal: true)
      #expect(await eventually { clock.sleeperCount > 0 })
      clock.advance(by: .milliseconds(500))
      for _ in 0..<50 { await Task.yield() }
    }
    await controller.reconcile(desired: [])
    let collector = Task {
      var reasons: [AppAudioFailure.Reason] = []
      for await event in failures { reasons.append(event.reason) }
      return reasons
    }
    try? await Task.sleep(for: .milliseconds(50))
    collector.cancel()
    #expect(await collector.value.contains(.onlySilence) == false)
  }

  /// S41-M2: the app pausing is noticed by the watchdog (our own aggregate keeps the device
  /// running), so the domain re-reads the processes and the tap goes after the linger period.
  @Test func anAppThatStopsPlayingIsReportedOnce() async {
    let engine = FakeTapEngine()
    let clock = FakeClock()
    engine.setDevice("SPK")
    let controller = CoreAudioAppController(engine: engine, clock: clock, policy: policy)
    let failures = controller.failures()
    let app = ControlledApp(id: "music", bundleID: "music", pids: [20])
    await controller.reconcile(
      desired: [DesiredAppAudio(app: app, gain: 0.5, muted: false, targetDeviceUID: "SPK")])
    let handle = engine.created[0]
    engine.setRunning(false)
    for _ in 0..<3 {
      handle.deliver(frames: 24_000, signal: false)
      #expect(await eventually { clock.sleeperCount > 0 })
      clock.advance(by: .milliseconds(500))
      for _ in 0..<50 { await Task.yield() }
    }
    var iterator = failures.makeAsyncIterator()
    #expect(await iterator.next() == AppAudioFailure(appID: "music", reason: .stoppedPlaying))
    #expect(handle.isStopped == false, "the domain decides when the tap goes")
    await controller.reconcile(desired: [])
  }

  /// S41-B1 (fixed): `.update` for "only processes gone" stores the new key, so a PID that
  /// comes back (reused by a new process of the same app) gets a new tap that covers it.
  @Test func pidThatComesBackAfterAnUpdateIsRetapped() async throws {
    let engine = FakeTapEngine()
    let clock = FakeClock()
    engine.setDevice("SPK")
    let controller = CoreAudioAppController(engine: engine, clock: clock, policy: policy)
    func want(_ pids: [Int32]) -> [DesiredAppAudio] {
      [
        DesiredAppAudio(
          app: ControlledApp(id: "app", bundleID: "app", pids: pids), gain: 0.3, muted: false,
          targetDeviceUID: "SPK")
      ]
    }
    await controller.reconcile(desired: want([10, 11]))
    await controller.reconcile(desired: want([10]))
    #expect(engine.created.count == 1, "a process that left keeps the tap")
    let back = Task { await controller.reconcile(desired: want([10, 11])) }
    try #require(await eventually { engine.created.count == 2 })
    #expect(engine.created[1].request.pids == [10, 11])
    try #require(await eventually { clock.sleeperCount > 0 })
    clock.advance(by: policy.crossfade)
    await back.value
    await controller.reconcile(desired: [])
  }

  /// S41-M1: the probe's decision for "a process plays, only zeros arrived" is still denied
  /// (it is also what a revoked permission gives); the store treats it as ambiguous: taps out
  /// at once, nothing stored, checked again (`SecurityM41StoreTests`).
  @Test func silentStreamAsTheOnlyPlayerIsDecidedAsDenied() {
    #expect(AccessDecision.verdict(sawSignal: false, stillPlaying: true) == .denied)
  }
}
