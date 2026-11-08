import CoreAudio
import Foundation
import Testing
import VolumeCore

@testable import VolumeAudio

private func qaDesired(_ pids: [Int32]) -> DesiredAppAudio {
  DesiredAppAudio(
    app: ControlledApp(id: "app", bundleID: "app", pids: pids), gain: 0.5, muted: false,
    targetDeviceUID: "SPK")
}

@Suite("QA M2.1: coreaudiod restart (M-2)")
struct QAServiceRestartM21Tests {
  private func rig() -> (FakeTapEngine, FakeClock, CoreAudioAppController) {
    let engine = FakeTapEngine()
    engine.setDevice("SPK")
    let clock = FakeClock()
    return (
      engine, clock, CoreAudioAppController(engine: engine, clock: clock, policy: WatchdogPolicy())
    )
  }

  /// The restart arrives while the old tap fades out: neither the old nor the new handle may be
  /// stopped (their IDs are dead); the app ends with exactly one working tap.
  @Test func restartDuringCrossfadeNeverStopsWithDeadIDs() async {
    let (engine, clock, controller) = rig()
    await controller.reconcile(desired: [qaDesired([10])])
    let first = engine.created[0]
    let task = Task { await controller.reconcile(desired: [qaDesired([10, 11])]) }
    #expect(await eventually { engine.created.count == 2 && clock.sleeperCount >= 2 })
    #expect(engine.created.count == 2)
    engine.emit(.serviceRestarted)
    #expect(await eventually { engine.created.count == 3 })
    for _ in 0..<50 { await Task.yield() }
    clock.advance(by: .milliseconds(50))  // past the 40 ms crossfade, before the 500 ms watchdog
    await task.value
    #expect(engine.created[0].isAbandoned && engine.created[0].stopCalls == 0)
    #expect(engine.created[1].isAbandoned && engine.created[1].stopCalls == 0)
    #expect(first === engine.created[0])
    #expect(engine.live.count == 1)  // the rebuilt tap, never left without a path (4.6)
    #expect(controller.killList.count == 1)
    await controller.restoreAll()
    #expect(engine.live.isEmpty)
    #expect(engine.created.prefix(2).allSatisfy { $0.stopCalls == 0 })
  }

  @Test func repeatedRestartsDoNotAccumulateOrLoop() async {
    let (engine, _, controller) = rig()
    await controller.reconcile(desired: [qaDesired([10])])
    for round in 1...5 {
      engine.emit(.serviceRestarted)
      #expect(await eventually { engine.created.count == round + 1 })
      #expect(engine.live.count == 1)
      #expect(controller.killList.count == 1)
    }
    #expect(engine.created.dropLast().allSatisfy { $0.isAbandoned && $0.stopCalls == 0 })
    await controller.restoreAll()
    #expect(engine.live.isEmpty)
  }

  @Test func restartWithNoTapsDoesNothingHarmful() async {
    let (engine, _, controller) = rig()
    engine.emit(.serviceRestarted)
    for _ in 0..<100 { await Task.yield() }
    #expect(engine.created.isEmpty)
    await controller.restoreAll()
  }
}

@Suite("QA M2.1: access probe never taps globally (B-5)")
struct QAProbeM21Tests {
  @Test func noTargetMeansNoTapAndNoGlobalFallback() {
    // Fake catalog is not injectable; with an empty candidate list the probe must still never
    // produce `.denied` unless a real other process refused a real tap. Here we only assert the
    // pure decision helpers keep "no target" away from `.denied`.
    #expect(SystemAudioAccessProbe.chooseTarget(among: [], isPlaying: { _ in true }) == nil)
    #expect(SystemAudioAccessProbe(catalog: ProcessCatalog()).probe(target: nil) == false)
  }

  @Test func sourceContainsNoGlobalTap() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = root.appendingPathComponent("Sources/VolumeAudio")
    for file in try FileManager.default.contentsOfDirectory(atPath: dir.path)
    where file.hasSuffix(".swift") {
      let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
      #expect(!text.contains("GlobalTap"), "\(file)")
    }
  }

  @Test func stageIsSetOnlyByCreateTap() {
    #expect(AudioError.unsupported("x").stage == .other)
    #expect(AudioError.unsupported("x", stage: .createTap).stage == .createTap)
    #expect(AudioError(status: 0, context: "create process tap").stage == .other)
  }
}

@Suite("QA M2.1: device UID resolution (B-2)")
struct QADeviceUIDM21Tests {
  private func entry(_ id: UInt32, _ raw: String) -> DeviceUIDEntry {
    DeviceUIDEntry(id: id, rawUID: raw)
  }

  @Test func exactBeatsSanitizedEvenWhenTheSanitizedOneComesFirstAndIsDuplicated() {
    let list = [entry(1, "ab\u{200B}"), entry(2, "ab\u{FEFF}"), entry(3, "ab")]
    #expect(DeviceCatalog.resolve(uid: "ab", in: list)?.id == 3)
  }

  @Test func ambiguousSanitizedUIDIsRefusedNotGuessed() {
    let list = [entry(1, "ab\u{200B}"), entry(2, "ab\u{FEFF}")]
    #expect(DeviceCatalog.resolve(uid: "ab", in: list) == nil)
  }

  @Test func rawUIDSurvivesInTheMatchedEntry() {
    let raw = "BT\u{202E}-1"
    let found = DeviceCatalog.resolve(uid: TextSanitizer.clean(raw), in: [entry(9, raw)])
    #expect(found?.rawUID == raw)
  }
}
