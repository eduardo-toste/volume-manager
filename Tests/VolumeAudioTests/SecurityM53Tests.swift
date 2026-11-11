import Synchronization
import Testing
import VolumeCore

@testable import VolumeAudio

/// The controller's events, shared with the listening task.
private final class SecurityEventLog: Sendable {
  let list = Mutex<[AppAudioFailure]>([])
}

/// Security review M5.3 (S53-A1): the 120 s of silence are counted per tap, not per app. A tap
/// that is rebuilt (the app paused longer than the 15 s linger, a process joined the group, the
/// output changed) starts again from zero. After a revocation that delivers only zeros, an app
/// whose play episodes are shorter than 120 s of output time is never checked: mute without
/// any deadline (rule 9, SPEC 4.6).
@Suite("Security M5.3 silence guard across tap rebuilds", .timeLimit(.minutes(2)))
struct SecurityM53Tests {
  private let policy = WatchdogPolicy()
  private let engine = FakeTapEngine()
  private let clock = FakeClock()
  private let controller: CoreAudioAppController
  private let events = SecurityEventLog()
  private let app = DesiredAppAudio(
    app: ControlledApp(id: "chat.app", bundleID: "chat.app", pids: [10]), gain: 1,
    muted: false, targetDeviceUID: "SPK")

  init() {
    engine.setDevice("SPK")
    controller = CoreAudioAppController(engine: engine, clock: clock, policy: policy)
  }

  private func listen() -> Task<Void, Never> {
    let stream = controller.failures()
    let events = events
    return Task {
      for await event in stream { events.list.withLock { $0.append(event) } }
    }
  }

  private func silenceReports() -> Int {
    events.list.withLock { list in
      list.filter { $0.reason == .onlySilence || $0.reason == .stillSilent }.count
    }
  }

  private func tick(frames: UInt64 = 480, signal: Bool = false) async {
    engine.created.last?.deliver(frames: frames, signal: signal)
    #expect(await eventually { clock.sleeperCount > 0 || engine.live.isEmpty })
    clock.advance(by: policy.tick)
    for _ in 0..<20 { await Task.yield() }
  }

  /// Revocation, then the app plays 100 s, pauses longer than the linger (tap destroyed by the
  /// domain), plays 100 s again, four times: 400 s of muted output and no permission check.
  @Test func rebuiltTapsAfterARevocationAreNeverChecked() async {
    let listener = listen()
    await controller.reconcile(desired: [app])
    await tick(signal: true)  // real sound, then the permission is revoked: zeros only
    let episode = policy.ticks(for: .seconds(100))
    for round in 0..<4 {
      if round > 0 {
        await controller.reconcile(desired: [])  // linger expired: tap destroyed
        await controller.reconcile(desired: [app])  // plays again: a new tap, zeros
      }
      for _ in 0..<episode { await tick() }
    }
    for _ in 0..<20 { await Task.yield() }
    #expect(engine.created.count == 4, "one new tap per play episode")
    #expect(silenceReports() == 0, "400 s of mute, never a permission check (S53-A1)")
    #expect(engine.live.count == 1, "the app is still tapped and mute")
    // Control: the same tap kept for 120 s more does ask (the guard works within one tap).
    for _ in 0..<(policy.ticks(for: policy.silenceLimit) - episode) { await tick() }
    #expect(await eventually { silenceReports() == 1 }, "control: one tap reaches 120 s")
    await controller.restoreAll()
    listener.cancel()
  }

  /// The same with no pause at all: a process that joins the group every 60 s (a browser
  /// spawning an audio helper) rebuilds the tap, which also restarts the count.
  @Test func aProcessThatJoinsRestartsTheSilenceCount() async {
    let listener = listen()
    await controller.reconcile(desired: [app])
    await tick(signal: true)
    let minute = policy.ticks(for: .seconds(60))
    var pids: [Int32] = [10]
    for _ in 0..<4 {
      for _ in 0..<minute { await tick() }
      pids.append(Int32(pids.count + 10))
      let grown = DesiredAppAudio(
        app: ControlledApp(id: "chat.app", bundleID: "chat.app", pids: pids), gain: 1,
        muted: false, targetDeviceUID: "SPK")
      let done = Mutex(false)
      let replace = Task {
        await controller.reconcile(desired: [grown])
        done.withLock { $0 = true }
      }
      // The cross-fade sleeps on the fake clock.
      var turns = 0
      while !done.withLock({ $0 }) && turns < 200 {
        for _ in 0..<20 { await Task.yield() }
        clock.advance(by: policy.crossfade)
        turns += 1
      }
      await replace.value
    }
    for _ in 0..<20 { await Task.yield() }
    #expect(engine.created.count == 5)
    #expect(silenceReports() == 0, "240 s of continuous mute output, never checked (S53-A1)")
    await controller.restoreAll()
    listener.cancel()
  }
}
