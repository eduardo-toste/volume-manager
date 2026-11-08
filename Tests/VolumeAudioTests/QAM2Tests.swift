import CoreAudio
import Dispatch
import Foundation
import Synchronization
import Testing
import VolumeCore

@testable import VolumeAudio

// QA M2: additional edge and acceptance tests. No hardware, no sound.

private func qaApp(_ id: String = "qa.one", pids: [Int32] = [10, 11]) -> ControlledApp {
  ControlledApp(id: id, bundleID: id, pids: pids)
}

private func qaDesired(
  _ app: ControlledApp = qaApp(), gain: Float = 0.5, muted: Bool = false, device: String = "SPK"
) -> DesiredAppAudio {
  DesiredAppAudio(app: app, gain: gain, muted: muted, targetDeviceUID: device)
}

private struct QARig {
  let engine = FakeTapEngine()
  let clock = FakeClock()
  let controller: CoreAudioAppController

  init() {
    controller = CoreAudioAppController(engine: engine, clock: clock, policy: WatchdogPolicy())
    engine.setDevice("SPK")
    engine.setDevice("PODS", rate: 24_000, id: 2)
  }

  func tick(_ ticks: Int = 1) async {
    for _ in 0..<ticks {
      _ = await eventually { clock.sleeperCount > 0 }
      clock.advance(by: .milliseconds(500))
      // The watchdog has handled this tick once it sleeps again (or nothing is left to watch);
      // a fixed number of yields is not enough when the test runs alone.
      _ = await eventually { clock.sleeperCount > 0 || engine.live.isEmpty }
    }
  }
}

// MARK: Never leave an app muted (rule 9, SPEC 4.6)

@Suite("QA M2: fail open")
struct QAFailOpenTests {
  @Test func stallGuardFiresExactlyAtTwoSeconds() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired()])
    let tap = rig.engine.created[0]
    tap.deliver(frames: 100, signal: true)
    await rig.tick(1)  // frames advanced
    await rig.tick(3)  // 3 ticks of no progress = 1.5 s
    #expect(tap.isStopped == false)
    await rig.tick(1)  // 2.0 s
    #expect(tap.isStopped)
  }

  /// Round 5b: a browser keeping a silent stream open, with the permission granted, asks for
  /// exactly one check during the whole silent period; the tap is never destroyed or rebuilt.
  @Test func continuousSilenceAsksForExactlyOneCheck() async {
    let rig = QARig()
    let failures = rig.controller.failures()
    await rig.controller.reconcile(desired: [qaDesired()])
    let tap = rig.engine.created[0]
    for _ in 0..<40 {
      tap.deliver(frames: 100, signal: false)
      await rig.tick(1)
      await rig.controller.reconcile(desired: [qaDesired()])
    }
    #expect(tap.isStopped == false)
    #expect(rig.engine.created.count == 1)
    await rig.controller.restoreAll()
    let events = await Self.collect(failures)
    #expect(events == [AppAudioFailure(appID: "qa.one", reason: .onlySilence)])
  }

  @Test func inconclusiveCheckIsRetriedNoMoreThanEveryThirtySeconds() async {
    let rig = QARig()
    let failures = rig.controller.failures()
    await rig.controller.reconcile(desired: [qaDesired()])
    let tap = rig.engine.created[0]
    for _ in 0..<4 {
      tap.deliver(frames: 100, signal: false)
      await rig.tick(1)
    }
    await rig.controller.silenceChecked(appID: "qa.one")
    for _ in 0..<59 {
      tap.deliver(frames: 100, signal: false)
      await rig.tick(1)
    }
    await rig.controller.restoreAll()
    #expect(await Self.collect(failures).count == 1, "nothing more before 30 s")
  }

  /// Events already emitted, without waiting for more.
  private static func collect(_ stream: AsyncStream<AppAudioFailure>) async -> [AppAudioFailure] {
    var events: [AppAudioFailure] = []
    let task = Task {
      var collected: [AppAudioFailure] = []
      for await event in stream { collected.append(event) }
      return collected
    }
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    events = await task.value
    return events
  }

  @Test func killSwitchActsOnTheNextTick() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired()])
    let tap = rig.engine.created[0]
    tap.deliver(frames: 100, signal: true)
    tap.raiseFault()
    await rig.tick(1)
    #expect(tap.isStopped)
  }

  @Test(arguments: [
    TapError.incompatibleFormat(.channelCount(tap: 2, output: 6)),
    TapError.incompatibleFormat(.notFloat32),
    TapError.incompatibleFormat(.bufferShape),
    TapError.coreAudio(AudioError(status: -1, context: "tap ok, aggregate failed")),
    TapError.coreAudio(AudioError(status: -2, context: "aggregate ok, IOProc failed")),
    TapError.coreAudio(AudioError(status: -3, context: "start failed")),
  ])
  func everyCreationFailureLeavesNothingAndIsNotRetried(error: TapError) async {
    let rig = QARig()
    rig.engine.failNext(error)
    var events: [AppAudioFailure] = []
    let stream = rig.controller.failures()
    let collector = Task { for await item in stream { events.append(item) } }
    for _ in 0..<10 { await rig.controller.reconcile(desired: [qaDesired()]) }
    #expect(rig.engine.live.isEmpty)
    #expect(rig.engine.enteredCount == 1)
    #expect(await rig.controller.diagnostics().isEmpty)
    collector.cancel()
  }

  @Test func failedReplacementDestroysTheOldTapToo() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired()])
    rig.engine.failNext(.coreAudio(AudioError(status: -1, context: "new tap fails")))
    await rig.controller.reconcile(desired: [qaDesired(device: "PODS")])
    #expect(rig.engine.live.isEmpty)  // original sound is back
  }

  @Test func failedGracefulReplacementDoesNotLeaveAHalfStateOnNextReconcile() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired()])
    rig.engine.failNext(.coreAudio(AudioError(status: -1, context: "x")))
    await rig.controller.reconcile(desired: [qaDesired(device: "PODS")])
    rig.engine.failNext(nil)
    await rig.controller.reconcile(desired: [qaDesired(device: "PODS")])
    #expect(rig.engine.live.isEmpty)  // latched: user action required
    await rig.controller.retry(appID: "qa.one")
    await rig.controller.reconcile(desired: [qaDesired(device: "PODS")])
    #expect(rig.engine.live.count == 1)
  }

  @Test func restoreAllTwiceAndConcurrentlyIsHarmless() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired(), qaDesired(qaApp("qa.two", pids: [3]))])
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 { group.addTask { await rig.controller.restoreAll() } }
    }
    #expect(rig.engine.live.isEmpty)
    await rig.controller.restoreAll()
    #expect(await rig.controller.diagnostics().isEmpty)
  }

  @Test func reconcileAfterRestoreAllSurvivesAnotherRestoreAllBookkeeping() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired()])
    await rig.controller.restoreAll()
    await rig.controller.reconcile(desired: [qaDesired()])
    #expect(rig.engine.live.count == 1)
    // Same generation: nothing may delete the new tap behind the caller's back.
    await rig.tick(2)
    #expect(rig.engine.live.count == 1)
  }

  @Test func restoreAllClearsTheFailureLatchSoTheUserCanTryAgain() async {
    let rig = QARig()
    rig.engine.failNext(.coreAudio(AudioError(status: -1, context: "x")))
    await rig.controller.reconcile(desired: [qaDesired()])
    rig.engine.failNext(nil)
    await rig.controller.restoreAll()
    await rig.controller.reconcile(desired: [qaDesired()])
    #expect(rig.engine.live.count == 1)
  }

  @Test func restoreAllDuringACrossfadeStopsBothTaps() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired()])
    let reconcile = Task {
      await rig.controller.reconcile(desired: [qaDesired(qaApp(pids: [10, 11, 12]))])
    }
    #expect(await eventually { rig.engine.created.count == 2 })
    await rig.controller.restoreAll()
    rig.clock.advance(by: .milliseconds(100))
    await reconcile.value
    #expect(rig.engine.live.isEmpty)
  }

  @Test func watchdogHasNoTimerWhenTheLastTapIsRemoved() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired()])
    _ = await eventually { rig.clock.sleeperCount > 0 }
    await rig.controller.reconcile(desired: [])
    for _ in 0..<50 { await Task.yield() }
    // SPEC 4.6/12.4: the check exists only while taps exist. (Finding: it lingers until the
    // next tick.)
    #expect(rig.clock.sleeperCount == 0)
  }

  @Test func watchdogEndsAfterTapsAreGoneAndNeverRestartsByItself() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired()])
    await rig.controller.reconcile(desired: [])
    await rig.tick(1)
    for _ in 0..<50 { await Task.yield() }
    #expect(rig.clock.sleeperCount == 0)
  }
}

// MARK: Reconciliation idempotence

@Suite("QA M2: reconciliation")
struct QAReconcileTests {
  @Test func differentOrderOfTheSamePIDsDoesNotRebuild() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired(qaApp(pids: [10, 11]))])
    // A rebuild would sleep on the fake clock for the crossfade: advance it so the test ends.
    let task = Task { await rig.controller.reconcile(desired: [qaDesired(qaApp(pids: [11, 10]))]) }
    for _ in 0..<20 {
      for _ in 0..<50 { await Task.yield() }
      rig.clock.advance(by: .milliseconds(100))
    }
    await task.value
    #expect(rig.engine.created.count == 1)
  }

  @Test func duplicateEntriesForOneAppCreateOneTap() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired(), qaDesired(gain: 0.2)])
    #expect(rig.engine.created.count == 1)
  }

  @Test func gainIsClampedAndNaNMeansUnity() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired(gain: .nan)])
    await rig.controller.reconcile(desired: [qaDesired(gain: 7)])
    await rig.controller.reconcile(desired: [qaDesired(gain: -3)])
    await rig.controller.reconcile(desired: [qaDesired(gain: 0.3, muted: true)])
    #expect(rig.engine.created[0].targets == [1, 1, 0, 0])
  }

  @Test func newTapStartsAtItsTargetGainAndHardReplacementToo() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired(gain: 0.2)])
    #expect(rig.engine.created[0].request.initialGain == 0.2)
    rig.engine.setDevice("SPK", rate: 96_000, id: 1)  // format changed
    await rig.controller.reconcile(desired: [qaDesired(gain: 0.2)])
    #expect(rig.engine.created.count == 2)
    #expect(rig.engine.created[0].isStopped)
    #expect(rig.engine.created[1].request.initialGain == 0.2)
  }

  @Test func routeChangeCrossfadesThenStopsTheOldOne() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired(gain: 0.4)])
    let wanted = qaDesired(gain: 0.4, device: "PODS")
    let task = Task { await rig.controller.reconcile(desired: [wanted]) }
    #expect(await eventually { rig.clock.sleeperCount > 0 && rig.engine.created.count == 2 })
    #expect(rig.engine.created[1].request.initialGain == 0)
    #expect(rig.engine.created[0].targets.last == 0)
    #expect(rig.engine.created[0].isStopped == false)  // still fading
    rig.clock.advance(by: .milliseconds(40))
    await task.value
    #expect(rig.engine.created[0].isStopped)
    #expect(rig.engine.live.count == 1)
  }

  @Test func noTapIsCreatedForADeviceThatDoesNotExist() async {
    let rig = QARig()
    await rig.controller.reconcile(desired: [qaDesired(device: "GONE")])
    #expect(rig.engine.enteredCount == 0)
  }

  @Test func deinitStopsEveryTap() async {
    let engine = FakeTapEngine()
    engine.setDevice("SPK")
    var controller: CoreAudioAppController? = CoreAudioAppController(
      engine: engine, clock: FakeClock(), policy: WatchdogPolicy())
    await controller?.reconcile(desired: [qaDesired()])
    #expect(engine.live.count == 1)
    controller = nil
    #expect(await eventually { engine.live.isEmpty })
  }
}

// MARK: Real-time render: bounds, quality

private func randomFloats(_ count: Int, seed: UInt64) -> [Float] {
  var state = seed
  return (0..<count).map { _ in
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Float(bitPattern: UInt32(truncatingIfNeeded: state >> 16))
  }
}

@Suite("QA M2: render bounds and quality")
struct QARenderTests {
  @Test func unityIsBitExactForEveryBitPatternAcrossManyCycles() {
    let state = RealtimeTapState(initialGain: 1, target: 1, step: 0.001)
    let source = randomFloats(2 * 480, seed: 7)
    for _ in 0..<20 {
      let input = BufferListFixture(buffers: [(2, source, 960)])
      let output = BufferListFixture(buffers: [(2, [], 960)])
      state.render(input: input.list, output: output.list)
      let out = output.samples(0, count: 960)
      #expect(zip(out, source).allSatisfy { $0.bitPattern == $1.bitPattern })
    }
  }

  @Test func capacityNotMultipleOfAFrameNeverOverruns() {
    for extra in 1..<8 {
      let state = RealtimeTapState(initialGain: 1, target: 0.5, step: 0.01)
      let input = BufferListFixture(buffers: [(2, [Float](repeating: 1, count: 64), 64)])
      let output = BufferListFixture(buffers: [(2, [], 17)])
      state.render(input: input.list, output: output.list)
      #expect(output.guardSamples(0, capacity: 17) == [-9, -9, -9, -9], "extra \(extra)")
    }
  }

  @Test func absurdChannelCountsAndOffsetsAreSafe() {
    let source = [Float](repeating: 0.5, count: 16)
    for offset in [Int.min, -1, 5, Int.max] {
      let state = RealtimeTapState(initialGain: 1, target: 1, step: 0.001)
      state.setInputOffset(offset)
      let input = BufferListFixture(buffers: [(2, source, 16)])
      let output = BufferListFixture(buffers: [(2, [], 16)])
      state.render(input: input.list, output: output.list)
      #expect(output.guardSamples(0, capacity: 16) == [-9, -9, -9, -9])
      #expect(state.hasFault)
    }
    let state = RealtimeTapState(initialGain: 1, target: 1, step: 0.001)
    let input = BufferListFixture(buffers: [(Int(UInt32.max), source, 16)])
    let output = BufferListFixture(buffers: [(Int(UInt32.max), [], 16)])
    state.render(input: input.list, output: output.list)
    #expect(output.guardSamples(0, capacity: 16) == [-9, -9, -9, -9])
  }

  @Test func zeroBuffersAndZeroChannelsDoNotCrash() {
    let state = RealtimeTapState(initialGain: 1, target: 1, step: 0.001)
    let none = BufferListFixture(buffers: [])
    let output = BufferListFixture(buffers: [(2, [], 8)])
    state.render(input: none.list, output: output.list)
    state.render(input: output.list, output: none.list)
    let zero = BufferListFixture(buffers: [(0, [1, 1, 1, 1], 4)])
    state.render(input: zero.list, output: output.list)
    #expect(output.guardSamples(0, capacity: 8) == [-9, -9, -9, -9])
  }

  @Test func exactGainAfterTheRampIsSampleTimesGain() {
    let g: Float = 0.3
    let state = RealtimeTapState(initialGain: 1, target: g, step: 0.01)
    let source = randomFloats(2 * 2000, seed: 11).map { Float($0.bitPattern & 0x3FFF_FFFF) / 1e9 }
    let input = BufferListFixture(buffers: [(2, source, source.count)])
    let output = BufferListFixture(buffers: [(2, [], source.count)])
    state.render(input: input.list, output: output.list)
    let out = output.samples(0, count: source.count)
    let tail = source.indices.suffix(2000)
    #expect(tail.allSatisfy { out[$0] == source[$0] * g })
    #expect(state.currentGain == g)
  }

  @Test func gainNeverExceedsUnity() {
    let state = RealtimeTapState(initialGain: 0, target: 5, step: 0.01)
    #expect(state.target == 1)
    state.setTarget(.infinity)
    #expect(state.target == 1)
    state.setTarget(-4)
    #expect(state.target == 0)
    state.setTarget(.nan)
    #expect(state.target == 1)  // never silence by accident
  }

  @Test func crossfadeOfTwoTapsHasNoStepAndKeepsLevel() {
    let rate = 48_000.0
    let step = GainKernel.rampStep(sampleRate: rate)
    let g: Float = 0.6
    let old = RealtimeTapState(initialGain: g, target: g, step: step)
    let new = RealtimeTapState(initialGain: 0, target: g, step: step)
    old.setTarget(0)
    let frames = 2400
    let source = [Float](repeating: 1, count: frames * 2)
    let inOld = BufferListFixture(buffers: [(2, source, source.count)])
    let inNew = BufferListFixture(buffers: [(2, source, source.count)])
    let outOld = BufferListFixture(buffers: [(2, [], source.count)])
    let outNew = BufferListFixture(buffers: [(2, [], source.count)])
    old.render(input: inOld.list, output: outOld.list)
    new.render(input: inNew.list, output: outNew.list)
    let a = outOld.samples(0, count: source.count)
    let b = outNew.samples(0, count: source.count)
    var worstLevel: Float = 0
    var worstJump: Float = 0
    var previous = a[0] + b[0]
    for index in stride(from: 0, to: source.count, by: 2) {
      let sum = a[index] + b[index]
      worstLevel = max(worstLevel, abs(sum - g))
      worstJump = max(worstJump, abs(sum - previous))
      previous = sum
    }
    #expect(worstLevel < 0.002)
    #expect(worstJump < step * 2)
    #expect(old.currentGain == 0)
    #expect(new.currentGain == g)
  }

  @Test func newTapStartsAtUnityAndDescendsMonotonically() {
    let step = GainKernel.rampStep(sampleRate: 48_000)
    let state = RealtimeTapState(initialGain: 1, target: 0.25, step: step)
    let source = [Float](repeating: 1, count: 2 * 1500)
    let input = BufferListFixture(buffers: [(2, source, source.count)])
    let output = BufferListFixture(buffers: [(2, [], source.count)])
    state.render(input: input.list, output: output.list)
    let out = output.samples(0, count: source.count)
    #expect(out[0] > 0.99)  // no hole at the start
    var previous: Float = 1
    for index in stride(from: 0, to: out.count, by: 2) {
      #expect(out[index] <= previous)
      #expect(out[index] == out[index + 1])
      previous = out[index]
    }
    #expect(out.last == 0.25)
  }

  @Test func rampStepMatchesTwentyMillisecondsAtCommonRates() {
    for rate in [44_100.0, 48_000, 96_000, 192_000] {
      let frames = 1 / Double(GainKernel.rampStep(sampleRate: rate))
      #expect(abs(frames / rate - 0.020) < 0.0005)
    }
  }

  @Test func negativeZeroIsNotSignalButSubnormalIs() {
    let state = RealtimeTapState(initialGain: 1, target: 1, step: 0.001)
    let zeros = BufferListFixture(buffers: [(2, [-0.0, 0, -0.0, 0], 4)])
    let out = BufferListFixture(buffers: [(2, [], 4)])
    state.render(input: zeros.list, output: out.list)
    #expect(state.hasEverSeenSignal == false)
    let tiny = BufferListFixture(buffers: [(2, [Float.leastNonzeroMagnitude, 0, 0, 0], 4)])
    state.render(input: tiny.list, output: out.list)
    #expect(state.hasEverSeenSignal)
  }

  @Test func formatPolicyRejectsMoreThanTwoChannelsBeforeAnyTapExists() {
    #expect(throws: FormatMismatch.self) {
      try FormatPolicy.validateOutput(StreamLayout(sampleRate: 48_000, channels: 6))
    }
    #expect(throws: FormatMismatch.self) {
      try FormatPolicy.validateOutput(StreamLayout(sampleRate: 48_000, channels: 0))
    }
  }
}

// MARK: Hardware (own silent player only)

// Part of the serialized "Core Audio hardware" suite, so no other test creates aggregates
// while these compare the device list.
extension HardwareTests {
  private func aggregates() -> Set<String> {
    Set(AudioDiagnostics.deviceUIDs().filter { $0.hasPrefix(DeviceCatalog.aggregateUIDPrefix) })
  }

  @Test func sessionStartWithUnsupportedChannelsCreatesNothing() async throws {
    guard let player = await SilentPlayer() else { return }
    defer { player.stop() }
    let catalog = ProcessCatalog()
    guard let object = catalog.objectID(forPID: player.pid),
      let speaker = DeviceCatalog.outputDevices().first
    else { return }
    let before = aggregates()
    let signature = DeviceSignature(
      id: speaker.id, uid: speaker.uid, rawUID: speaker.uid,
      layout: StreamLayout(sampleRate: 48_000, channels: 6))
    let request = TapRequest(
      app: ControlledApp(id: "pid:\(player.pid)", bundleID: nil, pids: [player.pid]),
      processes: [ConfirmedProcess(pid: player.pid, objectID: object)], device: signature,
      initialGain: 1, targetGain: 0.5)
    #expect(throws: TapError.self) {
      _ = try CoreAudioTapSession.start(
        request, queue: DispatchQueue(label: "qa"), notify: { _ in },
        isCancelled: { false })
    }
    try await Task.sleep(for: .milliseconds(500))
    #expect(aggregates() == before)
  }

  @Test func sessionStartWithABogusOutputUIDDestroysTapAndAggregate() async throws {
    guard let player = await SilentPlayer() else { return }
    defer { player.stop() }
    let catalog = ProcessCatalog()
    guard let object = catalog.objectID(forPID: player.pid),
      let speaker = DeviceCatalog.outputDevices().first
    else { return }
    let before = aggregates()
    let signature = DeviceSignature(
      id: speaker.id, uid: "qa.bogus.device.uid", rawUID: "qa.bogus.device.uid",
      layout: StreamLayout(sampleRate: 48_000, channels: 2))
    let request = TapRequest(
      app: ControlledApp(id: "pid:\(player.pid)", bundleID: nil, pids: [player.pid]),
      processes: [ConfirmedProcess(pid: player.pid, objectID: object)], device: signature,
      initialGain: 1, targetGain: 0.5)
    var threw = false
    do {
      let session = try CoreAudioTapSession.start(
        request, queue: DispatchQueue(label: "qa"), notify: { _ in },
        isCancelled: { false })
      session.stop()
    } catch { threw = true }
    _ = threw
    try await Task.sleep(for: .milliseconds(800))
    #expect(aggregates() == before)
  }

  @Test func cancelledBeforeTheAggregateLeavesNothing() async throws {
    guard let player = await SilentPlayer() else { return }
    defer { player.stop() }
    let catalog = ProcessCatalog()
    guard let object = catalog.objectID(forPID: player.pid),
      let speaker = DeviceCatalog.outputDevices().first,
      let signature = DeviceCatalog.signature(forUID: speaker.uid)
    else { return }
    let before = aggregates()
    let request = TapRequest(
      app: ControlledApp(id: "pid:\(player.pid)", bundleID: nil, pids: [player.pid]),
      processes: [ConfirmedProcess(pid: player.pid, objectID: object)], device: signature,
      initialGain: 1, targetGain: 0.5)
    for _ in 0..<20 {
      let cancel = ProbeCounter()
      _ = try? CoreAudioTapSession.start(
        request, queue: DispatchQueue(label: "qa"), notify: { _ in },
        isCancelled: { cancel.next() >= 2 })
    }
    try await Task.sleep(for: .milliseconds(800))
    #expect(aggregates() == before)
  }

  @Test func pipelineStageFailuresAreCleanedUp() async throws {
    let before = aggregates()
    let pipeline = TapPipeline()
    #expect(throws: AudioError.self) {
      try pipeline.startIO(proc: signalProbeIOProc, client: nil)  // no aggregate yet
    }
    #expect(throws: AudioError.self) {
      _ = try pipeline.createAggregate(["bogus": 1])  // invalid description
    }
    pipeline.teardown()
    pipeline.teardown()
    try await Task.sleep(for: .milliseconds(300))
    #expect(aggregates() == before)
  }
}

final class ProbeCounter: Sendable {
  private let count = Mutex(0)
  func next() -> Int {
    count.withLock { value in
      value += 1
      return value
    }
  }
}
