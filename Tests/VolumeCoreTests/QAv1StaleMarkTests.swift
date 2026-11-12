import Testing

@testable import VolumeCore

/// v1.0.0 review: a permission mark written by a development build with the SAME `CFBundleVersion`
/// as the release survives an ad hoc reinstall (new cdhash, TCC forgot the grant). The audio must stay
/// safe in that case (the visible notice is a known gap, S53-B2, see the review report).
@MainActor
@Suite("QA v1: stale mark with the same build number", .timeLimit(.minutes(1)))
struct QAv1StaleMarkTests {
  private let sameBuildMark: [String: Any] = [
    "audioPermissionConfirmed": true, "audioPermissionBuild": "1",
    "rememberedApps": ["com.spotify.client": ["volume": 0.4, "muted": false]],
  ]

  /// Never mute: whatever the check says, the app is not tapped and keeps its original sound.
  @Test func realDenialWithSameBuildMarkNeverTapsOrMutes() async {
    let h = MixerHarness(preferences: sameBuildMark, permission: .notDetermined)
    h.access.answer = .denied
    h.start([h.process("Spotify", pid: 1, playing: true)])
    await h.settle()
    h.store.popoverOpened()
    await h.settle()
    #expect(h.controller.neverTapped || h.controller.reconcileCalls.allSatisfy { $0.isEmpty })
  }
}
