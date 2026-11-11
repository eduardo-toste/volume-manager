import Synchronization
import Testing
import VolumeCore

@testable import VolumeAudio

/// The controller's events, shared with the listening task.
private final class SecurityEventLog: Sendable {
  let list = Mutex<[AppAudioFailure]>([])
}

/// Security review M5.3 (S53-A1, fixed): the 120 s of silence were counted per tap, so a tap
/// that was rebuilt (the app paused longer than the 15 s linger, a process joined the group,
/// the output changed) started again from zero and a revoked permission could leave an app
/// mute without any deadline (rule 9, SPEC 4.6). The count is now one for the whole
/// controller and survives rebuilds: the check comes within ~121 s of muted output time.
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
  /// domain) and plays again: the second episode reaches 120 s of muted output and asks for
  /// the check; nothing is asked before.
  @Test func rebuiltTapsAfterARevocationAreChecked() async {
    let listener = listen()
    await controller.reconcile(desired: [app])
    await tick(signal: true)  // real sound, then the permission is revoked: zeros only
    let silence = policy.ticks(for: policy.silenceLimit)
    let episode = policy.ticks(for: .seconds(100))
    for _ in 0..<episode { await tick() }
    await controller.reconcile(desired: [])  // linger expired: tap destroyed
    await controller.reconcile(desired: [app])  // plays again: a new tap, zeros
    #expect(engine.created.count == 2, "one new tap per play episode")
    for _ in 0..<(silence - episode - 1) { await tick() }  // 119.5 s of muted output
    for _ in 0..<20 { await Task.yield() }
    #expect(silenceReports() == 0, "nothing before 120 s")
    await tick()  // 120 s of muted output, across two taps
    #expect(await eventually { silenceReports() == 1 }, "checked within ~121 s (S53-A1)")
    await controller.restoreAll()
    listener.cancel()
  }

  /// The same with no pause at all: a process that joins the group every 60 s (a browser
  /// spawning an audio helper) rebuilds the tap, which no longer restarts the count.
  @Test func aProcessThatJoinsKeepsTheSilenceCount() async {
    let listener = listen()
    await controller.reconcile(desired: [app])
    await tick(signal: true)
    let minute = policy.ticks(for: .seconds(60))
    var pids: [Int32] = [10]
    for round in 0..<4 {
      for _ in 0..<minute { await tick() }
      for _ in 0..<20 { await Task.yield() }
      // `minute` ticks after the first sound tick: the limit falls at the end of round 1.
      if round == 0 { #expect(silenceReports() == 0, "60 s: nothing yet") }
      if round == 1 { #expect(await eventually { silenceReports() == 1 }, "~120 s: checked") }
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
    // 240 s of muted output: the first check at 120 s, then at most one every 30 s while the
    // silence lasts (this rig never answers, so the report stays latched).
    #expect(silenceReports() == 1, "checked within ~121 s despite the rebuilds (S53-A1)")
    #expect(
      events.list.withLock { $0.first { $0.reason == .onlySilence }?.appID } == "chat.app")
    await controller.restoreAll()
    listener.cancel()
  }
}
