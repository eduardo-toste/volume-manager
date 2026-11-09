import Testing

@testable import VolumeCore

/// SPEC 4.6: no user tap exists before a signal check confirmed the permission this session.
@MainActor
@Suite("Permission gate before taps", .timeLimit(.minutes(1)))
struct AccessGateTests {
  private let spotify = "com.spotify.client"
  private let remembered: [String: Any] = [
    "rememberedApps": ["com.spotify.client": ["volume": 0.4, "muted": false]]
  ]

  private func harness(_ status: AudioPermissionStatus = .notDetermined) -> MixerHarness {
    MixerHarness(preferences: remembered, permission: status)
  }

  @Test func launchWithRememberedVolumesNeverCreatesATapOrAsksForPermission() async {
    let h = harness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    await h.settle()
    #expect(h.store.rows.first?.state.volume == 0.4)
    #expect(h.controller.neverTapped)
    #expect(h.access.requests == 0)
  }

  @Test func indeterminateCheckCreatesNoTapAndStaysPending() async {
    let h = harness()
    h.access.answer = .notDetermined
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    await h.settle()
    #expect(h.controller.neverTapped)
    #expect(h.access.requests == 1)
    h.store.setVolume(0.3, for: spotify)
    await h.settle()
    #expect(h.access.requests == 2)
    #expect(h.controller.neverTapped)
    #expect(!h.permission.isDenied)
  }

  @Test func confirmedPermissionCreatesTheTapOnTheNextAction() async {
    let h = harness()
    h.access.answer = .granted
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    await h.settle()
    #expect(h.permission.status == .granted)
    #expect(h.controller.reconcileCalls.last?.map(\.app.id) == [spotify])
    #expect(h.controller.calls.contains(.retryAll))
  }

  @Test func deniedShowsTheStateAndCreatesNoTap() async {
    let h = harness()
    h.access.answer = .denied
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    await h.settle()
    #expect(h.permission.isDenied)
    #expect(h.controller.neverTapped)
  }

  @Test func grantedLaterRetriesAndReconciles() async {
    let h = harness(.denied)
    h.access.answer = .denied
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    await h.settle()
    #expect(h.controller.neverTapped)
    h.access.answer = .granted
    await h.permission.refresh(onlyIfDenied: true)
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.map(\.app.id) == [spotify])
  }

  @Test func appsAtDefaultNeverTriggerTheCheck() async {
    let h = harness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setMasterVolume(0.5)
    await h.settle()
    #expect(h.access.requests == 0)
  }
}

@MainActor
@Suite("Permission verified at launch after a past confirmation", .timeLimit(.minutes(1)))
struct LaunchVerificationTests {
  private let marked: [String: Any] = [
    "audioPermissionConfirmed": true,
    "rememberedApps": ["com.spotify.client": ["volume": 0.4, "muted": false]],
  ]

  @Test func markPlusRememberedPlayingAppVerifiesAndAppliesWithoutAction() async {
    let h = MixerHarness(preferences: marked, permission: .notDetermined)
    h.access.answer = .granted
    h.start([h.process("Spotify", pid: 1, playing: true)])
    await h.settle()
    #expect(h.access.requests == 1)
    #expect(h.controller.reconcileCalls.last?.map(\.app.id) == ["com.spotify.client"])
    #expect(h.settings.audioPermissionConfirmed)
  }

  @Test func noMarkMeansNoVerificationWithoutUserAction() async {
    var prefs = marked
    prefs["audioPermissionConfirmed"] = nil
    let h = MixerHarness(preferences: prefs, permission: .notDetermined)
    h.access.answer = .granted
    h.start([h.process("Spotify", pid: 1, playing: true)])
    await h.settle()
    #expect(h.access.requests == 0)
    #expect(h.controller.neverTapped)
  }

  @Test func rememberedAppNotPlayingDoesNotVerify() async {
    let h = MixerHarness(preferences: marked, permission: .notDetermined)
    h.start([h.process("Spotify", pid: 1, playing: false)])
    await h.settle()
    #expect(h.access.requests == 0)
  }

  @Test func deniedClearsTheMarkAndCreatesNoTap() async {
    let h = MixerHarness(preferences: marked, permission: .notDetermined)
    h.access.answer = .denied
    h.start([h.process("Spotify", pid: 1, playing: true)])
    await h.settle()
    #expect(!h.settings.audioPermissionConfirmed)
    #expect(h.permission.isDenied)
    #expect(h.controller.neverTapped)
  }

  @Test func indeterminateStaysPendingAndRetriesOnNextReconciliation() async {
    let h = MixerHarness(preferences: marked, permission: .notDetermined)
    h.access.answer = .notDetermined
    h.start([h.process("Spotify", pid: 1, playing: true)])
    await h.settle()
    #expect(h.settings.audioPermissionConfirmed)
    h.access.answer = .granted
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.map(\.app.id) == ["com.spotify.client"])
  }

  /// S41-B4: panic has one lock (taps suspended until the user acts); the permission mark is
  /// about the permission, so it stays.
  @Test func panicSuspendsTheTapsAndKeepsTheMark() async {
    let h = MixerHarness(preferences: marked, permission: .granted)
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.restoreOriginalAudio()
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.isEmpty == true)
    #expect(h.settings.audioPermissionConfirmed)
  }
}
