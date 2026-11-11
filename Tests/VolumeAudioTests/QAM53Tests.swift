import Synchronization
import Testing
import VolumeCore

@testable import VolumeAudio

private final class QALog: Sendable {
  let list = Mutex<[AppAudioFailure]>([])
}

/// QA M5.3: the Discord call scenarios of the bug report, on the controller with a fake clock.
@Suite("QA M5.3: voice call scenarios (fake clock)", .timeLimit(.minutes(2)))
struct QAM53CallTests {
  private let policy = WatchdogPolicy()
  private let engine = FakeTapEngine()
  private let clock = FakeClock()
  private let controller: CoreAudioAppController
  private let log = QALog()

  init() {
    engine.setDevice("SPK")
    controller = CoreAudioAppController(engine: engine, clock: clock, policy: policy)
  }

  private func desired(_ id: String, pid: Int32) -> DesiredAppAudio {
    DesiredAppAudio(
      app: ControlledApp(id: id, bundleID: id, pids: [pid]), gain: 1, muted: false,
      targetDeviceUID: "SPK")
  }

  private func listen() -> Task<Void, Never> {
    let stream = controller.failures()
    let log = log
    return Task { for await event in stream { log.list.withLock { $0.append(event) } } }
  }

  private func count(_ reason: AppAudioFailure.Reason) -> Int {
    log.list.withLock { $0.filter { $0.reason == reason }.count }
  }

  /// One tick; `signals[i]` is what tap `i` heard.
  private func tick(_ signals: [Bool]) async {
    for (index, handle) in engine.created.enumerated() where index < signals.count {
      handle.deliver(frames: 480, signal: signals[index])
    }
    #expect(await eventually { clock.sleeperCount > 0 || engine.live.isEmpty })
    clock.advance(by: policy.tick)
    for _ in 0..<20 { await Task.yield() }
  }

  /// Ten minutes of a call: silences of 5 to 110 s between bursts of speech. The tap is never
  /// rebuilt and no permission check is ever asked.
  @Test func tenMinuteCallWithSilencesUnderTheLimitAsksNothing() async {
    let listener = listen()
    await controller.reconcile(desired: [desired("discord", pid: 10)])
    var elapsed: Duration = .zero
    var silences = [5, 110, 30, 119, 60, 8, 90, 110, 45].makeIterator()
    while elapsed < .seconds(600) {
      await tick([true])  // speech
      elapsed += policy.tick
      guard let silence = silences.next() else { continue }
      for _ in 0..<(silence * 2) {
        await tick([false])
        elapsed += policy.tick
      }
    }
    #expect(count(.onlySilence) == 0 && count(.stillSilent) == 0)
    #expect(count(.noAudioFrames) == 0)
    #expect(engine.created.count == 1, "the tap is never recreated")
    #expect(engine.live.count == 1)
    await controller.restoreAll()
    listener.cancel()
  }

  /// Output on and off during the silence: only the output time counts and a pause never
  /// resets it, so a revoked permission with an app that plays on and off is still found.
  @Test func pausesDoNotDelayTheCheckBeyondTheOutputTime() async {
    let listener = listen()
    await controller.reconcile(desired: [desired("discord", pid: 10)])
    await tick([true])
    var runningTime: Duration = .zero
    var wall: Duration = .zero
    var running = true
    var step = 0
    while count(.onlySilence) == 0 && wall < .seconds(2000) {
      if step % 8 == 0 {
        running.toggle()
        engine.setRunning(running)
      }
      step += 1
      await tick([false])
      wall += policy.tick
      if running { runningTime += policy.tick }
    }
    #expect(count(.onlySilence) == 1)
    #expect(runningTime >= .seconds(119) && runningTime <= .seconds(121), "\(runningTime)")
    #expect(engine.live.count == 1, "the tap is kept until the domain decides")
    await controller.restoreAll()
    listener.cancel()
  }

  /// Discord alone is quiet and a browser tap is silent too: the silent one is never reported
  /// while the other tap delivers real sound; nothing is rebuilt.
  @Test func aSilentBrowserBesideACallWithSoundAsksNothing() async {
    let listener = listen()
    await controller.reconcile(desired: [desired("discord", pid: 10), desired("browser", pid: 20)])
    for _ in 0..<1_200 { await tick([true, false]) }  // 10 min
    #expect(count(.onlySilence) == 0 && count(.stillSilent) == 0)
    #expect(engine.created.count == 2)
    #expect(engine.live.count == 2)
    await controller.restoreAll()
    listener.cancel()
  }

  /// Fail open of the stall guard stays: a tap that starts and then stops delivering frames is
  /// destroyed after 2 s, a silent but flowing tap is not.
  @Test func stalledTapStillFailsOpenAfterTwoSecondsButSilentFlowingDoesNot() async {
    let listener = listen()
    await controller.reconcile(desired: [desired("discord", pid: 10)])
    await tick([true])
    for _ in 0..<200 { await tick([false]) }
    #expect(engine.live.count == 1, "silence with frames flowing is not a stall")
    for _ in 0..<policy.ticks(for: policy.stallLimit) {
      engine.created[0].deliver(frames: 0, signal: false)
      #expect(await eventually { clock.sleeperCount > 0 || engine.live.isEmpty })
      clock.advance(by: policy.tick)
      for _ in 0..<20 { await Task.yield() }
    }
    #expect(await eventually { engine.live.isEmpty }, "no sound lost: tap destroyed")
    #expect(await eventually { count(.noAudioFrames) == 1 })
    listener.cancel()
  }
}
