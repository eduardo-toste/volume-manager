import Synchronization
import Testing
import VolumeCore

@testable import VolumeAudio

/// The controller's events, shared with the listening task.
private final class EventLog: Sendable {
  let list = Mutex<[AppAudioFailure]>([])
}

/// M5.3 (SPEC 4.6): the silence guard waits 120 s of output time, the stall guard gives a new
/// tap 5 s to start, and an app that plays again with its tap kept is announced (F1).
@Suite("M5.3 watchdog (fake clock)", .timeLimit(.minutes(1)))
struct M53WatchdogTests {
  private let policy = WatchdogPolicy()
  private let engine = FakeTapEngine()
  private let clock = FakeClock()
  private let controller: CoreAudioAppController
  private let events = EventLog()
  private let call = DesiredAppAudio(
    app: ControlledApp(id: "voice.call", bundleID: "voice.call", pids: [10]), gain: 1,
    muted: false, targetDeviceUID: "SPK")

  init() {
    engine.setDevice("SPK")
    controller = CoreAudioAppController(engine: engine, clock: clock, policy: policy)
  }

  /// Collects every event of the controller in the background.
  private func listen() -> Task<Void, Never> {
    let stream = controller.failures()
    let events = events
    return Task {
      for await event in stream { events.list.withLock { $0.append(event) } }
    }
  }

  private func reasons() -> [AppAudioFailure.Reason] { events.list.withLock { $0.map(\.reason) } }

  /// One watchdog tick; `frames` and `signal` are what the IOProc delivered meanwhile.
  private func tick(frames: UInt64 = 480, signal: Bool = false) async {
    engine.created.last?.deliver(frames: frames, signal: signal)
    #expect(await eventually { clock.sleeperCount > 0 || engine.live.isEmpty })
    clock.advance(by: policy.tick)
    for _ in 0..<20 { await Task.yield() }
  }

  /// A voice call where nobody talks: 119.5 s of zeros never asks for a check; 120 s asks for
  /// exactly one. The tap is never rebuilt.
  @Test func aSilentCallIsCheckedOnlyAfterOneHundredTwentySeconds() async {
    let listener = listen()
    await controller.reconcile(desired: [call])
    await tick(signal: true)
    #expect(policy.silenceLimit == .seconds(120))
    let silence = policy.ticks(for: policy.silenceLimit)
    for _ in 0..<(silence - 1) { await tick() }  // 119.5 s
    for _ in 0..<20 { await Task.yield() }
    #expect(!reasons().contains(.onlySilence), "no check before 120 s")
    #expect(engine.created.count == 1)
    await tick()  // 120 s
    #expect(await eventually { reasons().filter { $0 == .onlySilence }.count == 1 })
    for _ in 0..<10 { await tick() }
    #expect(reasons().filter { $0 == .onlySilence }.count == 1, "exactly one")
    #expect(engine.created.count == 1)
    #expect(engine.live.count == 1, "the tap is kept")
    await controller.restoreAll()
    listener.cancel()
  }

  /// Output on and off every 1 to 3 s for 60 s: the tap and its aggregate are never rebuilt,
  /// no check is asked, and each change is announced so the domain re-reads the processes.
  @Test func playingOnAndOffForAMinuteKeepsTheSameTap() async {
    let listener = listen()
    await controller.reconcile(desired: [call])
    var elapsed: Duration = .zero
    var running = true
    var period = 0
    while elapsed < .seconds(60) {
      let length = [2, 6, 4][period % 3]  // ticks: 1 s, 3 s, 2 s
      for _ in 0..<length {
        await tick(signal: running && period % 2 == 0)
        elapsed += policy.tick
      }
      running.toggle()
      engine.setRunning(running)
      period += 1
      await controller.reconcile(desired: [call])
    }
    await tick()
    #expect(engine.created.count == 1, "never recreated")
    #expect(engine.live.count == 1)
    #expect(!reasons().contains(.onlySilence))
    #expect(!reasons().contains(.noAudioFrames))
    #expect(reasons().contains(.startedPlaying), "F1: playing again is announced")
    #expect(reasons().contains(.stoppedPlaying))
    await controller.restoreAll()
    listener.cancel()
  }

  /// F1: with the tap kept after a pause, the app playing again is announced once.
  @Test func playingAgainWithTheTapKeptIsAnnounced() async {
    let listener = listen()
    await controller.reconcile(desired: [call])
    await tick(signal: true)
    engine.setRunning(false)
    await tick()
    #expect(await eventually { reasons() == [.stoppedPlaying] })
    engine.setRunning(true)
    await tick(signal: true)
    #expect(await eventually { reasons() == [.stoppedPlaying, .startedPlaying] })
    await tick(signal: true)
    #expect(reasons() == [.stoppedPlaying, .startedPlaying], "once per change")
    await controller.restoreAll()
    listener.cancel()
  }

  /// C1: a device slow to wake up (Bluetooth) delivers no frame for 4.5 s: not a failure.
  /// No frame at all for 5 s is.
  @Test func aSlowTapIsNotAFailureBeforeFiveSeconds() async {
    let listener = listen()
    await controller.reconcile(desired: [call])
    let start = policy.ticks(for: policy.startLimit)
    for _ in 0..<(start - 1) { await tick(frames: 0) }
    #expect(engine.live.count == 1, "still waiting at 4.5 s")
    await tick(frames: 512)
    for _ in 0..<(policy.ticks(for: policy.stallLimit) - 1) { await tick(frames: 512) }
    #expect(engine.live.count == 1, "running normally after a slow start")
    await controller.reconcile(desired: [])
    await controller.reconcile(desired: [call])
    for _ in 0..<start { await tick(frames: 0) }
    #expect(await eventually { reasons().contains(.noAudioFrames) }, "no frame in 5 s fails")
    #expect(await eventually { engine.live.isEmpty }, "fail open: original sound returns")
    await controller.restoreAll()
    listener.cancel()
  }
}
