import Testing

@testable import VolumeCore

/// QA M4.1: coalesced writes (master volume and reconcile) never lose the last value and keep
/// the order retry -> reconcile.
@MainActor
@Suite("QA M4.1: coalescing")
struct QAM41Tests {
  private let spotify = "com.spotify.client"

  @Test func masterWriterRestartsAfterItEnds() async {
    let h = MixerHarness()
    h.store.setMasterVolume(0.3)
    await h.settle()
    h.store.setMasterVolume(0.5)
    await h.settle()
    h.store.setMasterVolume(0.5)
    await h.settle()
    #expect(h.system.calls == [.masterVolume(0.3), .masterVolume(0.5), .masterVolume(0.5)])
  }

  @Test func masterLastValueAlwaysReachesTheSystemAfterAnyBurst() async {
    let h = MixerHarness()
    for round in 0..<20 {
      let values = (0...round % 7).map { Double($0 + round) / 40 }
      for value in values { h.store.setMasterVolume(value) }
      await h.settle()
      guard case .masterVolume(let last)? = h.system.calls.last else {
        Issue.record("no write")
        return
      }
      #expect(last == VolumeCurve.clampedVolume(values.last ?? 0))
    }
  }

  @Test func echoesAreFollowedAgainAfterTheLastWriteEnded() async {
    let h = MixerHarness()
    h.store.setMasterVolume(0.8)
    await h.settle()
    h.store.handle(.master(MasterOutputState(volume: 0.8, isMuted: true)))
    #expect(h.store.masterVolume == 0.8)
    #expect(h.store.masterMuted, "mute is never ignored")
  }

  @Test func retryRunsBeforeTheReconcileThatFollowsIt() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 10, playing: true)])
    await h.settle()
    h.store.controlFailed(spotify)
    h.store.setVolume(0.4, for: spotify)
    h.store.setVolume(0.3, for: spotify)
    await h.settle()
    let calls = h.controller.calls
    let retryIndex = calls.firstIndex(of: .retry(spotify))
    let lastReconcile = calls.lastIndex { if case .reconcile = $0 { true } else { false } }
    #expect(retryIndex != nil)
    #expect(retryIndex.flatMap { r in lastReconcile.map { r < $0 } } == true)
    #expect(h.controller.reconcileCalls.last?.first?.gain == VolumeCurve.gain(forVolume: 0.3))
  }

  @Test func retryAllTwiceStillEndsWithTheNewestDesiredAudio() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 10, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    await h.settle()
    h.store.retryAll()
    h.store.retryAll()
    h.store.setVolume(0.2, for: spotify)
    h.store.retryAll()
    await h.settle()
    let calls = h.controller.calls
    #expect(calls.filter { $0 == .retryAll }.count == 3)
    #expect(h.controller.reconcileCalls.last?.first?.gain == VolumeCurve.gain(forVolume: 0.2))
    if case .retryAll? = calls.last { Issue.record("a retry came after the last reconcile") }
  }

  @Test func burstWhileNotGrantedNeverTaps() async {
    let h = MixerHarness(permission: .denied)
    h.start([h.process("Spotify", pid: 10, playing: true)])
    for step in 1...5 { h.store.setVolume(Double(step) / 10, for: spotify) }
    await h.settle()
    #expect(h.controller.neverTapped)
  }
}
