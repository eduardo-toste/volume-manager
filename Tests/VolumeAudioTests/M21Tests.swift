import CoreAudio
import Foundation
import Testing
import VolumeCore

@testable import VolumeAudio

private func entry(_ id: UInt32, _ raw: String) -> DeviceUIDEntry {
  DeviceUIDEntry(id: id, rawUID: raw)
}

@Suite("M2.1: device UID lookup (B-2)")
struct DeviceUIDResolutionTests {
  @Test func exactMatchWinsOverASanitizedLookalikeThatComesFirst() {
    let list = [entry(1, "ab\u{200B}"), entry(2, "ab")]
    #expect(DeviceCatalog.resolve(uid: "ab", in: list)?.id == 2)
  }

  @Test func sanitizedMatchIsUsedWhenUnique() {
    let list = [entry(1, "x"), entry(2, "a  b\u{200B}")]
    let found = DeviceCatalog.resolve(uid: "a b", in: list)
    #expect(found?.id == 2)
    #expect(found?.rawUID == "a  b\u{200B}")  // the raw UID is what Core Audio must receive
  }

  @Test func uidsThatCollideAfterSanitizingAreRefused() {
    let list = [entry(1, "a\u{200B}b"), entry(2, "a\u{202E}b")]
    #expect(DeviceCatalog.resolve(uid: "ab", in: list) == nil)
  }

  @Test func unknownUIDIsNotFound() {
    #expect(DeviceCatalog.resolve(uid: "zzz", in: [entry(1, "a")]) == nil)
    #expect(DeviceCatalog.resolve(uid: "a", in: []) == nil)
  }

  @Test func signatureKeepsTheRawUIDApartFromTheDomainOne() {
    let layout = StreamLayout(sampleRate: 48_000, channels: 2)
    let signature = DeviceSignature(id: 1, uid: "u", rawUID: "u\u{200B}", layout: layout)
    #expect(signature.uid == "u")
    #expect(signature.rawUID == "u\u{200B}")
  }
}

@Suite("M2.1: access probe (B-5, B-8)")
struct AccessProbeM21Tests {
  @Test func noOtherAudioProcessMeansNoTapAtAll() {
    #expect(SystemAudioAccessProbe.chooseTarget(among: [], isPlaying: { _ in true }) == nil)
    #expect(SystemAudioAccessProbe(catalog: ProcessCatalog()).probe(target: nil) == false)
  }

  @Test func prefersAPlayingProcessThenAnyOther() {
    #expect(SystemAudioAccessProbe.chooseTarget(among: [5, 6, 7], isPlaying: { $0 == 6 }) == 6)
    #expect(SystemAudioAccessProbe.chooseTarget(among: [5, 6], isPlaying: { _ in false }) == 5)
  }

  @Test func theVerdictAfterAFailureDependsOnTheStageNotOnTheText() {
    let refused = AudioError(status: 1, context: "anything at all", stage: .createTap)
    let later = AudioError(status: 1, context: "create process tap (misleading text)")
    #expect(SystemAudioAccessProbe.verdictAfterFailure(refused) == .denied)
    #expect(SystemAudioAccessProbe.verdictAfterFailure(later) == .indeterminate)
    #expect(AudioError(status: 1, context: "x").stage == .other)
  }
}

@Suite("M2.1: PID is converted to an object once (B-4)")
struct ObjectResolvedOnceTests {
  @Test func theTapRequestCarriesTheObjectsOfTheConfirmedProcesses() async {
    let engine = FakeTapEngine()
    engine.setDevice("SPK")
    let controller = CoreAudioAppController(
      engine: engine, clock: FakeClock(), policy: WatchdogPolicy())
    let app = ControlledApp(id: "a", bundleID: "a", pids: [10, 11])
    engine.setConfirm { _ in [11] }
    await controller.reconcile(
      desired: [DesiredAppAudio(app: app, gain: 0.5, muted: false, targetDeviceUID: "SPK")])
    let request = engine.created.first?.request
    #expect(request?.pids == [11])
    #expect(request?.objectIDs == [1_011])
    await controller.restoreAll()
  }

  @Test func aRequestWithoutObjectsIsProcessGone() {
    let engine = CoreAudioTapEngine(
      catalog: ProcessCatalog(), identity: RejectAllIdentity())
    let request = TapRequest(
      app: ControlledApp(id: "a", bundleID: nil, pids: [1]), processes: [],
      device: DeviceSignature(
        id: 1, uid: "u", rawUID: "u", layout: StreamLayout(sampleRate: 48_000, channels: 2)),
      initialGain: 1, targetGain: 1)
    #expect(throws: TapError.processGone) {
      _ = try engine.makeSession(request, isCancelled: { false })
    }
  }

  @Test func processesThatFailTheIdentityCheckAreNotConfirmed() {
    let engine = CoreAudioTapEngine(catalog: ProcessCatalog(), identity: RejectAllIdentity())
    let own = getpid()
    #expect(
      engine.confirmedProcesses(for: ControlledApp(id: "x", bundleID: nil, pids: [own, 999_999]))
        .isEmpty)
  }
}

private struct RejectAllIdentity: ProcessIdentityChecking {
  func confirm(pid: Int32, belongsTo app: ControlledApp) -> Bool { false }
}

@Suite("M2.1: coreaudiod restart forgets instead of destroying (M-2)")
struct ServiceRestartTests {
  private func desired(_ id: String) -> DesiredAppAudio {
    DesiredAppAudio(
      app: ControlledApp(id: id, bundleID: id, pids: [10]), gain: 0.5, muted: false,
      targetDeviceUID: "SPK")
  }

  @Test func everyTapIsAbandonedNeverStoppedThenRebuilt() async {
    let engine = FakeTapEngine()
    engine.setDevice("SPK")
    let controller = CoreAudioAppController(
      engine: engine, clock: FakeClock(), policy: WatchdogPolicy())
    await controller.reconcile(desired: [desired("a"), desired("b")])
    #expect(engine.created.count == 2)
    engine.emit(.serviceRestarted)
    #expect(await eventually { engine.created.count == 4 })
    let old = Array(engine.created.prefix(2))
    #expect(old.allSatisfy { $0.isAbandoned && $0.stopCalls == 0 })
    #expect(engine.live.count == 2)
    await controller.restoreAll()
    // restoreAll only stops the new taps; the forgotten ones are no longer reachable.
    #expect(old.allSatisfy { $0.stopCalls == 0 })
    #expect(engine.live.isEmpty)
  }

  @Test func theKillListNoLongerHoldsAbandonedTaps() async {
    let engine = FakeTapEngine()
    engine.setDevice("SPK")
    let controller = CoreAudioAppController(
      engine: engine, clock: FakeClock(), policy: WatchdogPolicy())
    await controller.reconcile(desired: [desired("a")])
    #expect(controller.killList.count == 1)
    engine.emit(.serviceRestarted)
    #expect(await eventually { engine.created.count == 2 })
    #expect(controller.killList.count == 1)  // only the rebuilt tap
    #expect(engine.created[0].stopCalls == 0)
    await controller.restoreAll()
    #expect(engine.created[0].stopCalls == 0)
    #expect(engine.created[1].stopCalls >= 1)
  }

  @Test(.requiresAudioHardware, .tags(.audioHardware))
  func pipelineAbandonLeavesTheRealObjectAlive() throws {
    let pipeline = TapPipeline()
    let uid = DeviceCatalog.aggregateUIDPrefix + UUID().uuidString
    let aggregate: AudioObjectID
    do {
      aggregate = try pipeline.createAggregate([
        kAudioAggregateDeviceNameKey: "Volume test aggregate",
        kAudioAggregateDeviceUIDKey: uid,
        kAudioAggregateDeviceIsPrivateKey: true,
      ])
    } catch { return }
    let before = AudioDiagnostics.deviceUIDs().filter { $0 == uid }
    pipeline.abandon()
    pipeline.teardown()  // must now be a no-op
    let after = AudioDiagnostics.deviceUIDs().filter { $0 == uid }
    #expect(before.count == after.count)
    #expect(AudioHardwareDestroyAggregateDevice(aggregate) == noErr)  // manual cleanup
  }
}
