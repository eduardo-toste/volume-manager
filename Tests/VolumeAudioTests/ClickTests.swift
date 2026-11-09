import Testing
import VolumeCore

@testable import VolumeAudio

// Round 4 of M4.1: the user heard clicks while moving volume sliders, and the log showed the
// IO being stopped every 1 to 3 seconds. A volume change on an app that already has a tap
// must only move the gain (`setTarget`): no tap, aggregate or IOProc is created or destroyed.

private func clickApp(pids: [Int32] = [10, 11]) -> ControlledApp {
  ControlledApp(id: "app.one", bundleID: "app.one", pids: pids)
}

private func clickDesired(gain: Float, muted: Bool = false, pids: [Int32] = [10, 11])
  -> DesiredAppAudio
{
  DesiredAppAudio(app: clickApp(pids: pids), gain: gain, muted: muted, targetDeviceUID: "SPK")
}

@Suite("Volume changes never restart the audio (fakes)", .timeLimit(.minutes(1)))
struct VolumeChangeClickTests {
  private let engine = FakeTapEngine()
  private let clock = FakeClock()
  private let controller: CoreAudioAppController

  init() {
    controller = CoreAudioAppController(engine: engine, clock: clock, policy: WatchdogPolicy())
    engine.setDevice("SPK")
  }

  @Test func manyVolumeAndMuteChangesOnlyMoveTheGain() async {
    await controller.reconcile(desired: [clickDesired(gain: 0.5)])
    for step in 1...60 {
      let gain = Float(step % 20) / 20
      await controller.reconcile(desired: [clickDesired(gain: gain, muted: step % 15 == 0)])
    }
    #expect(engine.created.count == 1, "one tap for the whole session")
    #expect(engine.created[0].stopCalls == 0, "never destroyed")
    #expect(engine.created[0].targets.count == 61, "every change reached the gain")
  }

  @Test func aProcessThatEndsKeepsTheRunningTap() async {
    await controller.reconcile(desired: [clickDesired(gain: 0.5, pids: [10, 11, 12])])
    await controller.reconcile(desired: [clickDesired(gain: 0.4, pids: [10, 12])])
    await controller.reconcile(desired: [clickDesired(gain: 0.3, pids: [10])])
    #expect(engine.created.count == 1)
    #expect(engine.created[0].stopCalls == 0)
    #expect(engine.created[0].targets.last == 0.3)
  }

  @Test func aProcessThatJoinsStillGetsANewTap() async throws {
    await controller.reconcile(desired: [clickDesired(gain: 0.5, pids: [10])])
    let controller = controller
    let joined = Task {
      await controller.reconcile(desired: [clickDesired(gain: 0.5, pids: [10, 11])])
    }
    try #require(await eventually { engine.created.count == 2 })
    #expect(engine.created[1].request.pids == [10, 11])
    try #require(await eventually { clock.sleeperCount > 0 })
    clock.advance(by: WatchdogPolicy().crossfade)
    await joined.value
  }

  @Test func plannerKeepsTheTapWhenOnlyProcessesAreGone() {
    let device = DeviceSignature(
      id: 1, uid: "SPK", rawUID: "SPK", layout: StreamLayout(sampleRate: 48_000, channels: 2))
    let old = SessionKey(pids: [1, 2], deviceUID: "SPK", device: device, serviceGeneration: 0)
    let fewer = SessionKey(pids: [2], deviceUID: "SPK", device: device, serviceGeneration: 0)
    let more = SessionKey(pids: [1, 2, 3], deviceUID: "SPK", device: device, serviceGeneration: 0)
    let restarted = SessionKey(pids: [2], deviceUID: "SPK", device: device, serviceGeneration: 1)
    #expect(ReconcilePlanner.plan(current: old, wanted: fewer) == .update)
    #expect(ReconcilePlanner.plan(current: old, wanted: more) == .replaceGracefully)
    #expect(ReconcilePlanner.plan(current: old, wanted: restarted) == .replaceHard)
  }
}
