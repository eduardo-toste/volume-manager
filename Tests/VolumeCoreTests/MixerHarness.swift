@testable import VolumeCore

/// Wires a `MixerStore` to the test doubles.
@MainActor
struct MixerHarness {
  let clock = FakeClock()
  let system = FakeAudioSystem()
  let controller = SpyAppAudioController()
  let info = FakeAppInfoProvider()
  let preferences: InMemoryPreferencesStore
  let settings: SettingsModel
  let safety: SafetyPolicy
  let store: MixerStore
  let permission: PermissionMonitor
  let access = ScriptedPermissionService()

  static let speakers = OutputDevice(id: 1, uid: "speakers", name: "Alto-falantes", kind: .builtIn)
  static let airpods = OutputDevice(id: 2, uid: "airpods", name: "AirPods Pro", kind: .bluetooth)

  init(
    preferences initial: [String: Any] = [:], beginSafety: Bool = false,
    permission status: AudioPermissionStatus = .granted
  ) {
    var initial = initial
    // A stored permission mark is only auto-verified after a clean exit (SPEC 4.6): by default
    // the previous session of a harness that has the mark ended cleanly.
    var cleanStart = false
    if initial["audioPermissionConfirmed"] as? Bool == true, initial["safety.sessionStarted"] == nil
    {
      initial["safety.sessionStarted"] = true
      initial["safety.cleanExit"] = true
      cleanStart = true
    }
    // The mark was confirmed by this same build (see SettingsModel).
    if initial["audioPermissionConfirmed"] != nil, initial["audioPermissionBuild"] == nil {
      initial["audioPermissionBuild"] = "1"
    }
    permission = PermissionMonitor(service: access, status: status)
    preferences = InMemoryPreferencesStore(initial)
    settings = SettingsModel(store: preferences, clock: clock, build: "1")
    safety = SafetyPolicy(store: preferences, clock: clock)
    if beginSafety || cleanStart { safety.beginSession() }
    // Ends the harness session at once, which also drops the stable-session timer.
    if cleanStart { safety.markCleanExit() }
    store = MixerStore(
      audioSystem: system, controller: controller, appInfo: info, settings: settings,
      safety: safety, clock: clock, permission: permission)
    for (name, bundleID) in [
      ("Spotify", "com.spotify.client"), ("Safari", "com.apple.Safari"),
      ("Música", "com.apple.Music"), ("Zoom", "us.zoom.xos"),
    ] {
      info.setApp("/Applications/\(name).app", name: name, bundleID: bundleID)
    }
  }

  /// Process of the app called `name` (one of the four registered above).
  func process(_ name: String, pid: Int32, playing: Bool, inCall: Bool = false)
    -> AudioProcessInfo
  {
    AudioProcessInfo(
      pid: pid, executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
      isRunningOutput: playing, isRunningInput: inCall)
  }

  /// Starts with both devices, speakers as default, and the given processes.
  func start(_ processes: [AudioProcessInfo]) {
    store.handle(.devices([Self.speakers, Self.airpods]))
    store.handle(.defaultOutput(uid: "speakers"))
    store.handle(.processes(processes))
  }

  /// Waits for queued calls to services.
  func settle() async { await store.settle() }
}
