import Foundation
import Testing

@testable import VolumeCore

/// QA M4 round 3: the permission mark and the gate before taps, with hostile input.
@MainActor
@Suite("QA M4: permission mark and gate")
struct QAM4Round3Tests {
  private let spotify = "com.spotify.client"

  @Test func malformedMarkIsNeverTrue() {
    let values: [Any] = [
      "yes", 1, 2, 0, "true", [true], ["a": 1], Data([1]), 1.5, NSNull(),
    ]
    for value in values {
      let h = MixerHarness(preferences: ["audioPermissionConfirmed": value])
      #expect(!h.settings.audioPermissionConfirmed, "\(value)")
    }
  }

  @Test func realBooleanMarkIsRead() {
    let h = MixerHarness(preferences: ["audioPermissionConfirmed": true])
    #expect(h.settings.audioPermissionConfirmed)
  }

  @Test func malformedMarkNeverVerifiesAtLaunch() async {
    let h = MixerHarness(
      preferences: [
        "audioPermissionConfirmed": "yes",
        "rememberedApps": [spotify: ["volume": 0.4, "muted": false]],
      ], permission: .notDetermined)
    h.access.answer = .granted
    h.start([h.process("Spotify", pid: 1, playing: true)])
    await h.settle()
    #expect(h.access.requests == 0)
    #expect(h.controller.neverTapped)
  }

  @Test func retryAllWhileNotGrantedCreatesNoTap() async {
    let h = MixerHarness(permission: .denied)
    h.access.answer = .denied
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    h.store.retryAll()
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    await h.settle()
    #expect(h.controller.neverTapped)
  }

  @Test func muteAfterDeniedDoesNotMuteAnything() async {
    let h = MixerHarness(permission: .notDetermined)
    h.access.answer = .denied
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.toggleMute(spotify)
    await h.settle()
    #expect(h.controller.neverTapped)
    #expect(h.permission.isDenied)
  }

  @Test func panicAfterGrantStillAllowsTheNextUserTap() async {
    let h = MixerHarness(permission: .granted)
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.restoreOriginalAudio()
    await h.settle()
    h.store.setVolume(0.5, for: spotify)
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.map(\.app.id) == [spotify])
  }
}
