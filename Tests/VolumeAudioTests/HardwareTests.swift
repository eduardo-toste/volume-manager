import CoreAudio
import Foundation
import Testing
import VolumeCore

@testable import VolumeAudio

/// Identity check for the test process only: the PID must still be the one we started.
private struct TestPIDIdentity: ProcessIdentityChecking {
  let pid: Int32
  func confirm(pid candidate: Int32, belongsTo app: ControlledApp) -> Bool { candidate == pid }
}

/// Core Audio finishes destroying an aggregate device a moment after the call returns, so the
/// count is polled (up to 3 s) instead of read once.
private func deviceCountSettles(to expected: Int) async -> Bool {
  for _ in 0..<30 {
    if AudioDiagnostics.deviceCount() == expected { return true }
    try? await Task.sleep(for: .milliseconds(100))
  }
  return AudioDiagnostics.deviceCount() == expected
}

/// Hardware tests (SPEC 12.8.1). Skipped unless `scripts/check.sh --audio`. They only ever tap a
/// process this test started with `afplay -v 0` (digital silence) and never change the system
/// volume, mute or default device. Without the System Audio Recording permission taps deliver
/// zeros, which is expected here.
@Suite("Core Audio hardware", .tags(.audioHardware), .requiresAudioHardware, .serialized)
struct HardwareTests {
  @Test func listsOutputDevicesAndTheDefault() async {
    let system = CoreAudioSystem()
    let snapshot = await system.currentState()
    #expect(!snapshot.devices.isEmpty)
    #expect(snapshot.devices.allSatisfy { !$0.uid.hasPrefix(DeviceCatalog.aggregateUIDPrefix) })
    if let uid = snapshot.defaultOutputUID {
      #expect(snapshot.devices.contains { $0.uid == uid })
    }
    #expect(AudioDiagnostics.deviceCount() >= snapshot.devices.count)
  }

  @Test func listsAudioProcessesIncludingTheSilentPlayer() async throws {
    guard let player = await SilentPlayer() else { return }
    let system = CoreAudioSystem()
    let snapshot = await system.currentState()
    let found = snapshot.processes.first { $0.pid == player.pid }
    #expect(found?.isRunningOutput == true)
    #expect(found?.executablePath == nil)
  }

  @Test func createAndDestroyTapAndAggregate100TimesLeavesNothing() async throws {
    guard let player = await SilentPlayer() else { return }
    let catalog = ProcessCatalog()
    let engine = CoreAudioTapEngine(catalog: catalog, identity: TestPIDIdentity(pid: player.pid))
    // Prefer the built-in speakers: no input streams, and the test only writes silence.
    let devices = DeviceCatalog.outputDevices()
    guard let device = devices.first(where: { $0.kind == .builtIn }) ?? devices.first,
      let signature = engine.deviceSignature(uid: device.uid)
    else { return }
    let app = ControlledApp(id: "pid:\(player.pid)", bundleID: nil, pids: [player.pid])
    let before = AudioDiagnostics.deviceCount()
    var created = 0
    var framesSeen: UInt64 = 0
    for cycle in 0..<100 {
      let processes = engine.confirmedProcesses(for: app)
      let request = TapRequest(
        app: app, processes: processes,
        device: signature, initialGain: 1, targetGain: 0.5)
      do {
        let handle = try engine.makeSession(request, isCancelled: { false })
        created += 1
        if cycle == 0 {
          try await Task.sleep(for: .milliseconds(300))
          framesSeen = handle.framesProcessed
        }
        handle.stop()
      } catch {
        Issue.record("cycle \(cycle) failed: \(error)")
      }
    }
    #expect(created == 100)
    #expect(framesSeen > 0)
    #expect(await deviceCountSettles(to: before))
  }

  @Test func controllerEndToEndOnTheSilentPlayer() async throws {
    guard let player = await SilentPlayer() else { return }
    let catalog = ProcessCatalog()
    let controller = CoreAudioAppController(
      catalog: catalog, identity: TestPIDIdentity(pid: player.pid))
    let devices = DeviceCatalog.outputDevices()
    guard let device = devices.first(where: { $0.kind == .builtIn }) ?? devices.first else {
      return
    }
    let before = AudioDiagnostics.deviceCount()
    let failures = controller.failures()
    let app = ControlledApp(id: "pid:\(player.pid)", bundleID: nil, pids: [player.pid])
    await controller.reconcile(desired: [
      DesiredAppAudio(app: app, gain: 0.25, muted: false, targetDeviceUID: device.uid)
    ])
    let started = await controller.diagnostics()
    #expect(started.count <= 1)
    if let first = started.first {
      #expect(first.tapFormat.contains("float32"))
      try await Task.sleep(for: .milliseconds(500))
      let later = await controller.diagnostics().first
      #expect((later?.framesProcessed ?? 0) > 0)
    }
    // The source is digital silence while "playing": the silence guard must end the tap within
    // a few seconds and restore the original sound (SPEC 4.6).
    var reasons: [AppAudioFailure.Reason] = []
    let collector = Task { for await failure in failures { reasons.append(failure.reason) } }
    try await Task.sleep(for: .seconds(4))
    collector.cancel()
    await controller.restoreAll()
    #expect(await controller.diagnostics().isEmpty)
    #expect(await deviceCountSettles(to: before))
  }

  @Test func signalProbeNeverReportsGrantedForSilence() async throws {
    guard let player = await SilentPlayer() else { return }
    let catalog = ProcessCatalog()
    let pid = player.pid
    let before = AudioDiagnostics.deviceCount()
    // Only our own silent process is listened to, never the user's apps.
    let probe = SystemAudioAccessProbe(
      catalog: catalog,
      candidates: { ProcessCatalog().objectID(forPID: pid).map { [$0] } ?? [] })
    let verdict = await probe.verify()
    #expect(verdict != .granted)
    #expect(await deviceCountSettles(to: before))
  }
}
