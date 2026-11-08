import Testing

@testable import VolumeCore

@MainActor
@Suite("Control failures (SPEC 4.6)")
struct ControlFailureTests {
  let h = MixerHarness()
  private let spotify = "com.spotify.client"

  private func startSpotifyAt50() {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: spotify)
  }

  @Test func failureMarksTheListedAppOnly() {
    startSpotifyAt50()
    h.store.controlFailed("com.unknown.app")
    #expect(h.store.failedAppIDs.isEmpty)
    h.store.controlFailed(spotify)
    #expect(h.store.failedAppIDs == [spotify])
  }

  @Test func userActionOnAFailedAppRetriesBeforeReconciling() async {
    startSpotifyAt50()
    h.store.controlFailed(spotify)
    h.store.setVolume(0.4, for: spotify)
    await h.settle()
    #expect(h.store.failedAppIDs.isEmpty)
    let calls = h.controller.calls
    let retry = calls.lastIndex(of: .retry(spotify))
    let reconcile = calls.lastIndex { if case .reconcile = $0 { true } else { false } }
    #expect(retry != nil)
    #expect(reconcile != nil)
    if let retry, let reconcile { #expect(retry < reconcile) }
  }

  @Test func retryAllClearsFailuresAndReconcilesAgain() async {
    startSpotifyAt50()
    await h.settle()
    let before = h.controller.reconcileCalls.count
    h.store.controlFailed(spotify)
    h.store.retryAll()
    await h.settle()
    #expect(h.store.failedAppIDs.isEmpty)
    #expect(h.controller.calls.contains(.retryAll))
    #expect(h.controller.reconcileCalls.count == before + 1)
  }

  @Test func failureIsForgottenWhenTheAppDisappears() {
    startSpotifyAt50()
    h.store.controlFailed(spotify)
    h.store.handle(.processes([]))
    #expect(h.store.failedAppIDs.isEmpty)
  }

  @Test func panicClearsFailures() {
    startSpotifyAt50()
    h.store.controlFailed(spotify)
    h.store.restoreOriginalAudio()
    #expect(h.store.failedAppIDs.isEmpty)
  }
}
