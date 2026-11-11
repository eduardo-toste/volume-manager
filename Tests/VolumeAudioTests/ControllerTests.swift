import Dispatch
import Testing
import VolumeCore

@testable import VolumeAudio

private func app(_ id: String = "app.one", pids: [Int32] = [10, 11]) -> ControlledApp {
  ControlledApp(id: id, bundleID: id, pids: pids)
}

private func desired(
  _ app: ControlledApp = app(), gain: Float = 0.5, muted: Bool = false, device: String = "SPK"
) -> DesiredAppAudio {
  DesiredAppAudio(app: app, gain: gain, muted: muted, targetDeviceUID: device)
}

private struct Rig {
  let engine = FakeTapEngine()
  let clock = FakeClock()
  let controller: CoreAudioAppController

  init() {
    controller = CoreAudioAppController(engine: engine, clock: clock, policy: WatchdogPolicy())
    engine.setDevice("SPK")
    engine.setDevice("PODS", rate: 24_000, id: 2)
  }

  /// Runs `ticks` watchdog ticks, giving the controller time to react to each.
  func tick(_ ticks: Int = 1) async {
    for _ in 0..<ticks {
      #expect(await eventually { clock.sleeperCount > 0 || engine.live.isEmpty })
      clock.advance(by: .milliseconds(500))
      for _ in 0..<50 { await Task.yield() }
    }
  }
}

@Suite("CoreAudioAppController reconciliation (fakes)", .timeLimit(.minutes(1)))
struct ControllerReconcileTests {
  @Test func createsOneTapPerAppWithTheWholeGroup() async {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired()])
    #expect(rig.engine.created.count == 1)
    let request = rig.engine.created[0].request
    #expect(request.pids == [10, 11])
    #expect(request.targetGain == 0.5)
    #expect(request.initialGain == request.targetGain)
    #expect(request.device.uid == "SPK")
  }

  @Test func isIdempotent() async {
    let rig = Rig()
    for _ in 0..<5 { await rig.controller.reconcile(desired: [desired()]) }
    #expect(rig.engine.created.count == 1)
    #expect(rig.engine.live.count == 1)
  }

  @Test func volumeAndMuteOnlyMoveTheTarget() async {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired(gain: 0.5)])
    await rig.controller.reconcile(desired: [desired(gain: 0.2)])
    await rig.controller.reconcile(desired: [desired(gain: 0.2, muted: true)])
    await rig.controller.reconcile(desired: [desired(gain: 0.9)])
    #expect(rig.engine.created.count == 1)
    #expect(rig.engine.created[0].targets == [0.5, 0.2, 0, 0.9])
  }

  @Test func appLeavingTheListIsDestroyedAndOthersStay() async {
    let rig = Rig()
    let other = app("app.two", pids: [20])
    await rig.controller.reconcile(desired: [desired(), desired(other)])
    #expect(rig.engine.live.count == 2)
    await rig.controller.reconcile(desired: [desired(other)])
    #expect(rig.engine.live.map(\.request.app.id) == ["app.two"])
    await rig.controller.reconcile(desired: [])
    #expect(rig.engine.live.isEmpty)
  }

  @Test func newHelperProcessRebuildsWithACrossfade() async throws {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired(app(pids: [10]))])
    let first = rig.engine.created[0]
    let task = Task { await rig.controller.reconcile(desired: [desired(app(pids: [10, 12]))]) }
    try #require(await eventually { rig.engine.created.count == 2 })
    let second = rig.engine.created[1]
    #expect(second.request.pids == [10, 12])
    #expect(second.request.initialGain == 0)
    #expect(second.isStopped == false)
    try #require(await eventually { first.targets.last == 0 })
    #expect(first.isStopped == false)
    try #require(await eventually { rig.clock.sleeperCount > 0 })
    rig.clock.advance(by: .milliseconds(100))
    await task.value
    #expect(first.isStopped)
    #expect(rig.engine.live.count == 1)
  }

  @Test func deviceChangeRecreatesButGainChangeDoesNot() async throws {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired(device: "SPK")])
    let task = Task { await rig.controller.reconcile(desired: [desired(device: "PODS")]) }
    try #require(await eventually { rig.engine.created.count == 2 })
    try #require(await eventually { rig.clock.sleeperCount > 0 })
    rig.clock.advance(by: .milliseconds(100))
    await task.value
    #expect(rig.engine.created[1].request.device.uid == "PODS")
    #expect(rig.engine.live.count == 1)
  }

  /// SPEC 4.7: a new format of the same output fades the old tap out and the new one in from 0;
  /// the old tap is never destroyed before the new one exists (no moment at full volume).
  @Test func deviceFormatChangeFadesOutAndInInsteadOfCutting() async throws {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired()])
    let first = rig.engine.created[0]
    rig.engine.setDevice("SPK", rate: 96_000)
    let task = Task { await rig.controller.reconcile(desired: [desired()]) }
    try #require(await eventually { rig.engine.created.count == 2 })
    let second = rig.engine.created[1]
    #expect(second.request.device.layout.sampleRate == 96_000)
    #expect(second.request.initialGain == 0, "fades in from silence")
    #expect(second.request.targetGain == 0.5)
    try #require(await eventually { first.targets.last == 0 })
    #expect(first.isStopped == false, "still alive while it fades out")
    try #require(await eventually { rig.clock.sleeperCount > 0 })
    rig.clock.advance(by: .milliseconds(100))
    await task.value
    #expect(first.isStopped)
    #expect(rig.engine.live.count == 1)
  }

  /// If the new format cannot be tapped, the old tap goes too: the app plays natively again.
  @Test func deviceFormatChangeThatFailsLeavesNoTap() async {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired()])
    rig.engine.setDevice("SPK", rate: 96_000)
    rig.engine.failNext(.incompatibleFormat(.bufferShape))
    await rig.controller.reconcile(desired: [desired()])
    #expect(rig.engine.live.isEmpty)
  }

  @Test func formatChangeEventReappliesTheLastDesiredState() async {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired()])
    rig.engine.setDevice("SPK", rate: 44_100)
    rig.engine.emit(.deviceFormatChanged(uid: "SPK"))
    #expect(await eventually { rig.engine.created.count == 2 })
    #expect(await eventually { rig.clock.sleeperCount > 0 })
    rig.clock.advance(by: .milliseconds(100))
    #expect(await eventually { rig.engine.live.count == 1 })
  }

  @Test func serviceRestartRebuildsEverything() async {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired()])
    rig.engine.emit(.serviceRestarted)
    #expect(await eventually { rig.engine.created.count == 2 })
    // The old tap is stopped once; the real `stop()` leaves dead or foreign IDs alone (M-2).
    #expect(rig.engine.created[0].stopCalls == 1)
    #expect(rig.engine.live.count == 1)
  }

  // M6: wake from sleep and fast user switching rebuild the taps (SPEC 8).

  @Test func wakeOrSessionResumeRebuildsEveryTapOnce() async {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired(), desired(app("app.two", pids: [20]))])
    #expect(rig.engine.created.count == 2)
    await rig.controller.systemResumed()
    #expect(rig.engine.created.count == 4)
    #expect(rig.engine.created.prefix(2).allSatisfy { $0.stopCalls == 1 })
    #expect(rig.engine.live.count == 2)
    #expect(rig.controller.killList.count == 2)
    await rig.controller.restoreAll()
    #expect(rig.engine.live.isEmpty)
  }

  @Test func resumeWithoutTapsOrAfterARestoreCreatesNothing() async {
    let rig = Rig()
    await rig.controller.systemResumed()
    #expect(rig.engine.created.isEmpty)
    await rig.controller.reconcile(desired: [desired()])
    await rig.controller.restoreAll()
    await rig.controller.systemResumed()
    #expect(rig.engine.live.isEmpty, "a restored (panic) state is not undone by waking up")
  }

  @Test func resumeDoesNotRetryAnAppThatFailed() async {
    let rig = Rig()
    rig.engine.failNext(.coreAudio(AudioError(status: -1, context: "boom")))
    await rig.controller.reconcile(desired: [desired()])
    rig.engine.failNext(nil)
    await rig.controller.systemResumed()
    #expect(rig.engine.created.isEmpty, "only the user may retry (SPEC 4.6)")
  }

  @Test func unpluggingAndRepluggingTheHeadphonesLeavesNoOrphanTap() async {
    let rig = Rig()
    let onPods = desired(device: "PODS")
    await rig.controller.reconcile(desired: [onPods])
    #expect(rig.engine.live.count == 1)
    // Unplugged: the device is gone, the tap is destroyed at once (the app plays natively).
    rig.engine.removeDevice("PODS")
    await rig.controller.reconcile(desired: [onPods])
    #expect(rig.engine.live.isEmpty)
    // They come back: the next reconcile builds the tap on them again.
    rig.engine.setDevice("PODS", rate: 24_000, id: 2)
    await rig.controller.reconcile(desired: [onPods])
    #expect(await eventually { rig.engine.live.count == 1 })
    #expect(rig.engine.live.first?.request.device.uid == "PODS")
  }

  @Test func missingDeviceDestroysTheTapAndReportsWithoutLatching() async {
    let rig = Rig()
    let failures = rig.controller.failures()
    await rig.controller.reconcile(desired: [desired(device: "PODS")])
    rig.engine.removeDevice("PODS")
    await rig.controller.reconcile(desired: [desired(device: "PODS")])
    #expect(rig.engine.live.isEmpty)
    var iterator = failures.makeAsyncIterator()
    #expect(await iterator.next() == AppAudioFailure(appID: "app.one", reason: .deviceUnavailable))
    rig.engine.setDevice("PODS", rate: 24_000, id: 2)
    await rig.controller.reconcile(desired: [desired(device: "PODS")])
    #expect(rig.engine.live.count == 1)
  }

  @Test func appWithNoValidProcessGetsNoTap() async {
    let rig = Rig()
    rig.engine.setConfirm { _ in [] }
    await rig.controller.reconcile(desired: [desired()])
    #expect(rig.engine.created.isEmpty)
  }

  @Test func onlyConfirmedPIDsAreTapped() async {
    let rig = Rig()
    rig.engine.setConfirm { $0.pids.filter { $0 == 11 } }
    await rig.controller.reconcile(desired: [desired()])
    #expect(rig.engine.created.first?.request.pids == [11])
  }

  @Test func creationFailureFailsOpenAndIsNotRetriedInALoop() async {
    let rig = Rig()
    let failures = rig.controller.failures()
    rig.engine.failNext(.coreAudio(AudioError(status: -1, context: "boom")))
    await rig.controller.reconcile(desired: [desired()])
    await rig.controller.reconcile(desired: [desired(gain: 0.3)])
    await rig.controller.reconcile(desired: [desired(gain: 0.4)])
    #expect(rig.engine.created.isEmpty)
    #expect(rig.engine.enteredCount == 1)
    var iterator = failures.makeAsyncIterator()
    #expect(await iterator.next() == AppAudioFailure(appID: "app.one", reason: .creationFailed))
    // Only a user action (the app leaves the list, or an explicit retry) allows a new try.
    rig.engine.failNext(nil)
    await rig.controller.retry(appID: "app.one")
    await rig.controller.reconcile(desired: [desired()])
    #expect(rig.engine.live.count == 1)
  }

  @Test func incompatibleFormatIsReportedAndNothingStays() async {
    let rig = Rig()
    let failures = rig.controller.failures()
    rig.engine.failNext(.incompatibleFormat(.bufferShape))
    await rig.controller.reconcile(desired: [desired()])
    var iterator = failures.makeAsyncIterator()
    #expect(
      await iterator.next() == AppAudioFailure(appID: "app.one", reason: .incompatibleFormat))
    #expect(rig.engine.live.isEmpty)
  }

  @Test func leavingTheListClearsTheFailureLatch() async {
    let rig = Rig()
    rig.engine.failNext(.coreAudio(AudioError(status: -1, context: "boom")))
    await rig.controller.reconcile(desired: [desired()])
    rig.engine.failNext(nil)
    await rig.controller.reconcile(desired: [])
    await rig.controller.reconcile(desired: [desired()])
    #expect(rig.engine.live.count == 1)
  }
}

@Suite("CoreAudioAppController watchdog (fake clock)", .timeLimit(.minutes(1)))
struct ControllerWatchdogTests {
  @Test func noTimerExistsWithoutTaps() async {
    let rig = Rig()
    await rig.controller.reconcile(desired: [])
    for _ in 0..<50 { await Task.yield() }
    #expect(rig.clock.sleeperCount == 0)
    await rig.controller.reconcile(desired: [desired()])
    #expect(await eventually { rig.clock.sleeperCount == 1 })
    await rig.controller.reconcile(desired: [])
    await rig.tick()
    #expect(await eventually { rig.clock.sleeperCount == 0 })
  }

  @Test func stalledTapIsDestroyedAfterTwoSeconds() async {
    let rig = Rig()
    let failures = rig.controller.failures()
    await rig.controller.reconcile(desired: [desired()])
    let handle = rig.engine.created[0]
    handle.deliver(frames: 100, signal: true)
    await rig.tick(3)
    #expect(handle.isStopped == false)
    await rig.tick(2)
    #expect(await eventually { handle.isStopped })
    var iterator = failures.makeAsyncIterator()
    #expect(await iterator.next() == AppAudioFailure(appID: "app.one", reason: .noAudioFrames))
    // No retry in a loop.
    await rig.controller.reconcile(desired: [desired()])
    #expect(rig.engine.created.count == 1)
  }

  /// Round 5b (120 s since M5.3): zeros for `silenceLimit` while the app plays ask for a
  /// permission check (once) and keep the tap; the decision is the domain's (SPEC 4.6).
  @Test func silenceWhileTheAppPlaysAsksForOneCheckAndKeepsTheTap() async {
    let rig = Rig()
    let failures = rig.controller.failures()
    await rig.controller.reconcile(desired: [desired()])
    let handle = rig.engine.created[0]
    let silence = WatchdogPolicy().ticks(for: WatchdogPolicy().silenceLimit)
    for _ in 0..<(silence + 2) {
      handle.deliver(frames: 24_000, signal: false)
      await rig.tick()
    }
    #expect(handle.isStopped == false)
    var iterator = failures.makeAsyncIterator()
    #expect(await iterator.next() == AppAudioFailure(appID: "app.one", reason: .onlySilence))
    // Signal, then silence again: one more check for the new silent period.
    handle.deliver(frames: 24_000, signal: true)
    await rig.tick()
    for _ in 0..<(silence + 2) {
      handle.deliver(frames: 24_000, signal: false)
      await rig.tick()
    }
    #expect(await iterator.next() == AppAudioFailure(appID: "app.one", reason: .onlySilence))
    #expect(handle.isStopped == false)
    #expect(rig.engine.created.count == 1)
  }

  @Test func healthyTapSurvivesAndSilenceWhileIdleIsFine() async {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired()])
    let handle = rig.engine.created[0]
    for _ in 0..<6 {
      handle.deliver(frames: 24_000, signal: true)
      await rig.tick()
    }
    rig.engine.setRunning(false)
    for _ in 0..<12 {
      handle.deliver(frames: 24_000, signal: false)
      await rig.tick()
    }
    #expect(handle.isStopped == false)
  }

  @Test func kernelKillSwitchDestroysTheTap() async {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired()])
    let handle = rig.engine.created[0]
    handle.deliver(frames: 10, signal: true)
    handle.raiseFault()
    await rig.tick()
    #expect(await eventually { handle.isStopped })
  }
}

@Suite("CoreAudioAppController restoreAll", .timeLimit(.minutes(1)))
struct ControllerRestoreTests {
  @Test func destroysEverythingAndForgetsTheDesiredState() async {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired(), desired(app("app.two", pids: [20]))])
    await rig.controller.restoreAll()
    #expect(rig.engine.live.isEmpty)
    // An environment change must not resurrect what the user restored.
    rig.engine.emit(.deviceFormatChanged(uid: "SPK"))
    for _ in 0..<100 { await Task.yield() }
    #expect(rig.engine.live.isEmpty)
    await rig.tick()
    #expect(await eventually { rig.clock.sleeperCount == 0 })
  }

  @Test func winsOverAReconcileThatIsStillInsideCoreAudio() async {
    let rig = Rig()
    let other = app("app.two", pids: [20])
    await rig.controller.reconcile(desired: [desired(other)])
    let gate = DispatchSemaphore(value: 0)
    rig.engine.blockCreation(gate)
    let slow = Task { await rig.controller.reconcile(desired: [desired(other), desired()]) }
    #expect(await eventually { rig.engine.enteredCount == 2 })
    // The old reconcile is stuck in a blocking Core Audio call. restoreAll must not wait for it
    // to destroy what exists.
    let restore = Task { await rig.controller.restoreAll() }
    #expect(await eventually { rig.engine.created.first?.isStopped == true })
    // Let the stuck call return: what it builds must be destroyed at once, never kept.
    gate.signal()
    await slow.value
    await restore.value
    #expect(rig.engine.live.isEmpty)
    #expect(rig.engine.created.count == 1)
  }

  @Test func reconcileIssuedBeforeButRunAfterIsDropped() async {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired()])
    await rig.controller.restoreAll()
    await rig.controller.reconcile(desired: [desired()])
    #expect(rig.engine.live.count == 1)
  }
}

@Suite("restoreAll ordering and identity", .timeLimit(.minutes(1)))
struct ControllerOrderingTests {
  @Test func aReconcileIssuedAfterRestoreSurvivesALateCleanup() async {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired()])
    let old = rig.engine.created[0]
    // Reproduces the reordering: the generation moved and the old taps were stopped, but the
    // actor ran a newer reconcile before the restore's own cleanup.
    let newGeneration = rig.controller.generation.advance()
    rig.controller.killList.stopAll()
    await rig.controller.reconcile(desired: [desired(gain: 0.3)])
    await rig.controller.finishRestore(newGeneration)
    #expect(old.isStopped)
    #expect(rig.engine.live.count == 1)
    #expect(rig.engine.live[0].request.targetGain == 0.3)
    #expect(await rig.controller.diagnostics().count == 1)
  }

  @Test func pidOrderDoesNotMatter() async {
    #expect(ControlledApp(id: "a", bundleID: nil, pids: [12, 3, 7]).pids == [3, 7, 12])
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired(app(pids: [10, 11]))])
    await rig.controller.reconcile(desired: [desired(app(pids: [11, 10]))])
    #expect(rig.engine.created.count == 1)
  }

  @Test func lastTapRemovedCancelsTheTimerAtOnce() async {
    let rig = Rig()
    await rig.controller.reconcile(desired: [desired()])
    #expect(await eventually { rig.clock.sleeperCount == 1 })
    await rig.controller.reconcile(desired: [])
    #expect(await eventually { rig.clock.sleeperCount == 0 })
  }
}
