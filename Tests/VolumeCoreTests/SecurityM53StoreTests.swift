import Synchronization
import Testing

@testable import VolumeCore

/// Behaves like `SystemAudioAccessProbe.verify`: it listens with `try? await sleep`, so a
/// cancelled check stops listening at once, hears nothing and concludes "denied" while the
/// target still plays. A check that listens to the end hears the (real) sound: "granted".
private final class CancellableProbeService: PermissionService, Sendable {
  private let state = Mutex((requests: 0, cancelled: 0))
  var requests: Int { state.withLock { $0.requests } }
  var cancelled: Int { state.withLock { $0.cancelled } }

  func request(userAction: Bool) async -> AudioPermissionStatus {
    state.withLock { $0.requests += 1 }
    try? await Task.sleep(for: .milliseconds(300))
    if Task.isCancelled {
      state.withLock { $0.cancelled += 1 }
      return .denied
    }
    return .granted
  }

  func openPrivacySettings() {}
}

/// Security re-review M5.3 (S53R-B1, fixed): `startCheck` used to cancel the check in flight,
/// and the real probe turned a cancelled listening window into "denied". Checks are now queued,
/// never cancelled, and a cancelled "denied" counts as inconclusive.
@MainActor
@Suite("Security M5.3 re-review: cancelled permission checks", .timeLimit(.minutes(1)))
struct SecurityM53StoreTests {
  /// The permission is granted and Spotify plays real sound. The user clicks "Permitir…" and,
  /// while its 500 ms check listens, reopens the popover: the click's check is not cancelled,
  /// hears the sound and stores the mark; no false "sem permissão".
  @Test func reopeningThePopoverDuringPermitirShowsNoFalseDenial() async {
    let service = CancellableProbeService()
    let permission = PermissionMonitor(service: service, status: .notDetermined)
    let preferences = InMemoryPreferencesStore([:])
    let clock = FakeClock()
    let settings = SettingsModel(store: preferences, clock: clock, build: "1")
    let info = FakeAppInfoProvider()
    info.setApp(
      "/Applications/Spotify.app", name: "Spotify", bundleID: "com.spotify.client")
    let store = MixerStore(
      audioSystem: FakeAudioSystem(), controller: SpyAppAudioController(), appInfo: info,
      settings: settings, safety: SafetyPolicy(store: preferences, clock: clock), clock: clock,
      permission: permission)
    store.handle(
      .devices([OutputDevice(id: 1, uid: "speakers", name: "Alto-falantes", kind: .builtIn)]))
    store.handle(.defaultOutput(uid: "speakers"))
    store.handle(
      .processes([
        AudioProcessInfo(
          pid: 1, executablePath: "/Applications/Spotify.app/Contents/MacOS/Spotify",
          isRunningOutput: true)
      ]))
    #expect(store.showsPermissionNotice, "never confirmed: notice (SPEC 3.2 case 1)")

    store.allowAccess()  // "Permitir…": check of the click, listening
    #expect(await eventually { service.requests >= 1 })
    store.popoverOpened()  // the user closes and reopens the popover meanwhile
    await store.settle()
    for _ in 0..<50 { await Task.yield() }

    #expect(service.cancelled == 0, "the click's check was not cancelled")
    #expect(permission.status == .granted)
    #expect(!store.showsPermissionNotice, "no false 'sem permissão'")
    #expect(settings.audioPermissionConfirmed)
  }

  /// Defense: a check whose task is cancelled while it listens (quitting, for example) never
  /// becomes a denial in the monitor.
  @Test func aCancelledCheckIsNotADenial() async {
    let service = CancellableProbeService()
    let permission = PermissionMonitor(service: service, status: .granted)
    let task = Task { await permission.refresh(onlyIfDenied: false) }
    #expect(await eventually { service.requests == 1 })
    task.cancel()
    let result = await task.value
    #expect(service.cancelled == 1)
    #expect(result == .notDetermined)
    #expect(permission.status == .granted, "the last known status is kept")
  }
}
