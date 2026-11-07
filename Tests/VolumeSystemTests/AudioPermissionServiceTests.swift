import Foundation
import Testing
import VolumeAudio
import VolumeCore

@testable import VolumeSystem

private final class FakeProbe: AudioAccessProbe, @unchecked Sendable {
  private let lock = NSLock()
  private var result: Bool
  private var calls = 0
  init(result: Bool) { self.result = result }
  var callCount: Int { lock.withLock { calls } }
  func set(_ value: Bool) { lock.withLock { result = value } }
  func probe() -> Bool {
    lock.withLock {
      calls += 1
      return result
    }
  }
}

private final class URLBox: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [URL] = []
  func add(_ url: URL) { lock.withLock { urls.append(url) } }
  var all: [URL] { lock.withLock { urls } }
}

@Suite("AudioPermissionService")
struct AudioPermissionServiceTests {
  @Test func currentStatusNeverProbes() async {
    let probe = FakeProbe(result: true)
    let service = AudioPermissionService(probe: probe)
    #expect(await service.currentStatus() == .notDetermined)
    #expect(probe.callCount == 0)
  }

  @Test func requestMapsProbeResult() async {
    let probe = FakeProbe(result: true)
    let service = AudioPermissionService(probe: probe)
    #expect(await service.request() == .granted)
    #expect(await service.currentStatus() == .granted)
    probe.set(false)
    #expect(await service.request() == .denied)
    #expect(await service.currentStatus() == .denied)
    probe.set(true)
    #expect(await service.request() == .granted)
  }

  @Test func opensTheFixedPrivacyURL() {
    let box = URLBox()
    let service = AudioPermissionService(probe: FakeProbe(result: true), openURL: { box.add($0) })
    service.openPrivacySettings()
    #expect(
      box.all.map(\.absoluteString) == [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
      ])
  }

  /// Creates and destroys a real test tap. May show the system prompt, so it never runs by
  /// default (`scripts/check.sh --audio` only). No sound: no IOProc and no aggregate device.
  @Test(.tags(.audioHardware), .requiresAudioHardware)
  func realProbeDoesNotCrash() {
    _ = SystemAudioAccessProbe().probe()
  }
}
